/* -----------------------------------------------------------------
 * :: :  A  K  A  R  I  :                                         ::
 * -----------------------------------------------------------------
 * Redistribution  and  use  in  source  and  binary  forms, with or
 * without  modification,  are permitted provided that the following
 * conditions are met:
 *
 * 1. Redistributions of source code must retain the above copyright
 *    notice, this list of conditions and the following disclaimer.
 *
 * 2. Redistributions  in  binary  form  must  reproduce  the  above
 *    copyright  notice,  this  list of conditions and the following
 *    disclaimer   in   the  documentation  and/or  other  materials
 *    provided with the distribution.
 *
 * 3. Neither the name of  the copyright holder nor the names of its
 *    contributors  may  be  used  to  endorse  or  promote products
 *    derived  from  this  software  without  specific prior written
 *    permission.
 *
 * THIS   SOFTWARE   IS   PROVIDED  BY  THE  COPYRIGHT  HOLDERS  AND
 * CONTRIBUTORS  "AS  IS"  AND  ANY  EXPRESS  OR IMPLIED WARRANTIES,
 * INCLUDING,   BUT  NOT  LIMITED  TO,  THE  IMPLIED  WARRANTIES  OF
 * MERCHANTABILITY   AND   FITNESS  FOR  A  PARTICULAR  PURPOSE  ARE
 * DISCLAIMED.   IN   NO   EVENT   SHALL  THE  COPYRIGHT  HOLDER  OR
 * CONTRIBUTORS  BE  LIABLE  FOR  ANY  DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL,  EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 * LIMITED  TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF
 * USE,  DATA,  OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED
 * AND  ON  ANY  THEORY  OF  LIABILITY,  WHETHER IN CONTRACT, STRICT
 * LIABILITY, OR TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
 * ANY  WAY  OUT OF THE USE OF THIS SOFTWARE, EVEN IF ADVISED OF THE
 * POSSIBILITY OF SUCH DAMAGE.
 *
 *                               Copyright (C) 2026 Wabi Foundation.
 *                                              All rights reserved.
 * -----------------------------------------------------------------
 *  . x x x . o o o . x x x . : : : .    o  x  o    . : : : .
 * ----------------------------------------------------------------- */

import AkariCore
import Foundation
import simd

extension Akari.LabFXEngine
{
  /// a glowing mesh that lights the scene.
  struct MeshLight
  {
    /// the topology the outline was traced on and its point indices in order
    var topologyRevision: UInt64
    var loop: [Int]
    /// a closed shell glows out of both sides of its rim
    var closed: Bool
    /// the material constants row its glow comes from, nil for a textured glow
    var row: Int?
    /// the light as of the mesh's last change
    var light: Akari.Lux.PointLight
    /// its world bounds, an authored light inside them makes the mesh that light's fixture
    var lower: SIMD3<Float>
    var upper: SIMD3<Float>
  }

  /// keeps a changed mesh's light in step with it, a mesh that stops glowing stops lighting
  func updateMeshLight(_ mesh: Akari.Geom.Recorder.RawMesh)
  {
    let count = mesh.points.size(), triangles = mesh.tris.size()
    guard mesh.emitter, mesh.emission.max() > 0, mesh.instances.isEmpty, mesh.worldMatrix.count == 16, count > 2, triangles > 0
    else
    {
      pointLights.meshLights[mesh.key] = nil
      return
    }

    let m = mesh.worldMatrix
    let world = (0 ..< count).map
    { i in
      let p = mesh.points[i]
      let x = p[0], y = p[1], z = p[2]
      return SIMD3<Float>(m[0] * x + m[4] * y + m[8] * z + m[12],
                          m[1] * x + m[5] * y + m[9] * z + m[13],
                          m[2] * x + m[6] * y + m[10] * z + m[14])
    }

    let tris = (0 ..< triangles).map { i in (Int(mesh.tris[i][0]), Int(mesh.tris[i][1]), Int(mesh.tris[i][2])) }
      .filter { $0.0 < count && $0.1 < count && $0.2 < count }

    // the area the surface glows over and the side it faces
    var area: Float = 0
    var facing = SIMD3<Float>.zero
    for (a, b, c) in tris
    {
      let n = simd_cross(world[b] - world[a], world[c] - world[a])
      area += simd_length(n) * 0.5
      facing += mesh.flipWinding ? -n : n
    }

    let lower = world.reduce(world[0], pointwiseMin), upper = world.reduce(world[0], pointwiseMax)
    let cached = pointLights.meshLights[mesh.key].flatMap { $0.topologyRevision == mesh.topologyRevision ? ($0.loop, $0.closed) : nil }
    let (loop, closed) = cached ?? Self.outline(world, tris)

    var light = Akari.Lux.PointLight(position: (lower + upper) * 0.5, color: mesh.emission, intensity: 1,
                                     radius: (area / (4 * .pi)).squareRoot(),
                                     diffuse: mesh.lightLobes.x, specular: mesh.lightLobes.y)
    light.cameraVisible = false

    // a round glowing mesh has no rim and lights as the sphere of its area, exact for a ball
    if loop.count >= 3
    {
      shapeOutline(&light, loop.map { world[$0] }, facing: facing, twoSided: closed || !mesh.singleSided)
    }

    // an untextured material's uv is minus one past its constants row
    let u = mesh.uvs.size() > 0 ? mesh.uvs[0][0] : 0
    pointLights.meshLights[mesh.key] = MeshLight(topologyRevision: mesh.topologyRevision, loop: loop, closed: closed,
                                                 row: u < 0 ? Int(-u + 0.5) - 1 : nil, light: light, lower: lower, upper: upper)
  }

  /// the light's outline and the rect of the same area in its plane, emitting toward `facing`
  private func shapeOutline(_ light: inout Akari.Lux.PointLight, _ loop: [SIMD3<Float>], facing: SIMD3<Float>, twoSided: Bool)
  {
    let outline = Self.resample(loop, to: Akari.Lux.PointLight.maxOutlinePoints)
    let center = outline.reduce(.zero, +) / Float(outline.count)

    // newell's normal gives the outline's plane and twice its area
    var newell = SIMD3<Float>.zero
    for i in outline.indices
    {
      newell += simd_cross(outline[i] - center, outline[(i + 1) % outline.count] - center)
    }

    let span = simd_length(newell)
    guard span > 1e-12 else { return }

    var normal = newell / span
    if simd_dot(normal, facing) < 0 { normal = -normal }

    // the outline's long axis in its plane and how far it spreads along each
    let seed = abs(normal.x) < 0.9 ? SIMD3<Float>(1, 0, 0) : SIMD3<Float>(0, 1, 0)
    var u = simd_normalize(simd_cross(normal, seed)), v = simd_cross(normal, u)
    var uu: Float = 0, vv: Float = 0, uv: Float = 0
    for p in outline
    {
      let d = p - center
      uu += simd_dot(d, u) * simd_dot(d, u)
      vv += simd_dot(d, v) * simd_dot(d, v)
      uv += simd_dot(d, u) * simd_dot(d, v)
    }

    let angle = 0.5 * atan2(2 * uv, uu - vv)
    (u, v) = (u * cos(angle) + v * sin(angle), v * cos(angle) - u * sin(angle))
    let su = max(outline.map { abs(simd_dot($0 - center, u)) }.reduce(0, max), 1e-6)
    let sv = max(outline.map { abs(simd_dot($0 - center, v)) }.reduce(0, max), 1e-6)
    let scale = (span * 0.5 / (4 * su * sv)).squareRoot()

    // a rect emits away from the cross of its half axes
    var halfWidth = u * su * scale
    let halfHeight = v * sv * scale
    if simd_dot(simd_cross(halfWidth, halfHeight), normal) > 0 { halfWidth = -halfWidth }

    light.position = center
    light.outline = outline
    light.halfWidth = halfWidth
    light.halfHeight = halfHeight
    light.twoSided = twoSided
  }

  /// the outline a glowing mesh lights through, its open edge or a closed shell's rim, and whether it was closed
  static func outline(_ points: [SIMD3<Float>], _ tris: [(Int, Int, Int)]) -> (loop: [Int], closed: Bool)
  {
    let open = boundaryLoop(points, tris)
    if !open.isEmpty { return (open, false) }

    var spread = simd_float3x3(0)
    var total: Float = 0
    for (a, b, c) in tris
    {
      let n = simd_cross(points[b] - points[a], points[c] - points[a])
      let length = simd_length(n)
      guard length > 0 else { continue }

      let u = n / length
      spread += simd_float3x3(columns: (u * u.x, u * u.y, u * u.z)) * (length * 0.5)
      total += length * 0.5
    }

    var axis = SIMD3<Float>(1, 1, 1) / Float(3).squareRoot()
    for _ in 0 ..< 32
    {
      let next = spread * axis
      guard simd_length(next) > 0 else { break }
      axis = simd_normalize(next)
    }

    // a ball spreads its normals evenly and has no rim
    guard simd_dot(axis, spread * axis) > 0.5 * total else { return ([], true) }

    let front = tris.filter { simd_dot(simd_cross(points[$0.1] - points[$0.0], points[$0.2] - points[$0.0]), axis) > 0 }
    return (boundaryLoop(points, front), true)
  }

  /// the longest loop of edges only one triangle uses, after welding points that share a place
  static func boundaryLoop(_ points: [SIMD3<Float>], _ tris: [(Int, Int, Int)]) -> [Int]
  {
    guard !tris.isEmpty else { return [] }
    let lower = points.reduce(points[0], pointwiseMin), upper = points.reduce(points[0], pointwiseMax)
    let cell = max(simd_length(upper - lower) * 1e-5, 1e-9)

    var welded = [Int](repeating: 0, count: points.count)
    var seen: [SIMD3<Int32>: Int] = [:]
    for (i, p) in points.enumerated()
    {
      let q = SIMD3<Int32>(Int32((p.x - lower.x) / cell), Int32((p.y - lower.y) / cell), Int32((p.z - lower.z) / cell))
      if let first = seen[q] { welded[i] = first } else { seen[q] = i; welded[i] = i }
    }

    var uses: [UInt64: Int] = [:]
    func key(_ a: Int, _ b: Int) -> UInt64 { UInt64(min(a, b)) << 32 | UInt64(max(a, b)) }
    let edges = tris.flatMap
    { t -> [(Int, Int)] in
      let a = welded[t.0], b = welded[t.1], c = welded[t.2]
      return a == b || b == c || c == a ? [] : [(a, b), (b, c), (c, a)]
    }

    for (a, b) in edges
    {
      uses[key(a, b), default: 0] += 1
    }

    var next: [Int: [Int]] = [:]
    for (a, b) in edges where uses[key(a, b)] == 1
    {
      next[a, default: []].append(b)
    }

    // walk each boundary loop and keep the one around the most
    var best: [Int] = [], bestLength: Float = 0
    var unused = next
    while let start = unused.keys.first
    {
      var loop = [start], length: Float = 0, at = start
      while let ends = unused[at], let to = ends.first
      {
        unused[at] = ends.count > 1 ? Array(ends.dropFirst()) : nil
        length += simd_distance(points[at], points[to])
        if to == start { break }
        loop.append(to)
        at = to
      }

      unused[at] = nil
      if length > bestLength, loop.count >= 3 { (best, bestLength) = (loop, length) }
    }

    return best
  }

  /// evenly spaced points around a closed loop, the loop itself when it already has few enough
  static func resample(_ loop: [SIMD3<Float>], to limit: Int) -> [SIMD3<Float>]
  {
    guard loop.count > limit else { return loop }

    let lengths = loop.indices.map { simd_distance(loop[$0], loop[($0 + 1) % loop.count]) }
    let total = lengths.reduce(0, +)
    guard total > 0 else { return Array(loop.prefix(limit)) }

    var out: [SIMD3<Float>] = []
    var edge = 0, walked: Float = 0
    for k in 0 ..< limit
    {
      let target = total * Float(k) / Float(limit)
      while edge < loop.count - 1, walked + lengths[edge] < target
      {
        walked += lengths[edge]
        edge += 1
      }

      let t = lengths[edge] > 0 ? (target - walked) / lengths[edge] : 0
      out.append(simd_mix(loop[edge], loop[(edge + 1) % loop.count], SIMD3(repeating: t)))
    }

    return out
  }

  /// the glowing meshes that light the scene, leaving out fixtures with an authored light inside
  func meshLightList(around authored: [Akari.Lux.PointLight]) -> [(key: LightKey, light: Akari.Lux.PointLight)]
  {
    pointLights.meshLights.compactMap
    { key, mesh in
      let pad = (mesh.upper - mesh.lower) * 0.01
      let fixture = authored.contains
      {
        all($0.position .>= mesh.lower - pad) && all($0.position .<= mesh.upper + pad)
      }

      return fixture ? nil : (key, mesh.light)
    }
    .sorted { $0.key < $1.key }
  }
}
