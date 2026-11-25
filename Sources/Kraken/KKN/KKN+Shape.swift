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

import Foundation
import simd

extension Kraken
{
  /// what the add mesh menu adds
  enum AddKind: String, CaseIterable
  {
    case plane, cube, circle, uvsphere, icosphere, cylinder, cone, torus, grid, point, sun, spot, area, tube, dome, camera, empty

    static let meshes: [AddKind] = [.plane, .cube, .circle, .uvsphere, .icosphere, .cylinder, .cone, .torus, .grid]
    static let lights: [AddKind] = [.point, .sun, .spot, .area, .tube, .dome]

    /// the name the added prim starts from.
    var name: String
    {
      switch self
      {
        case .uvsphere: "Sphere"
        case .tube: "CylinderLight"
        case .dome: "DomeLight"
        default: rawValue.capitalized
      }
    }

    var label: String
    {
      switch self
      {
        case .uvsphere: "UV Sphere"
        case .icosphere: "Ico Sphere"
        case .tube: "Cylinder"
        case .dome: "Dome"
        default: name
      }
    }
  }

  /// add mesh options with sizes in meters
  struct AddOptions: Equatable, Sendable
  {
    /// circles, cylinders, cones and spheres
    var radius: Float = 1
    /// cylinders and cones along z
    var depth: Float = 2
    /// cubes, planes and grids edge to edge
    var size: Float = 2
    /// around circles, cylinders, cones and uv spheres
    var vertices = 32
    /// down a uv sphere
    var rings = 16
    /// ico sphere subdivisions
    var subdivisions = 2
    /// grid cuts
    var cuts = 10
    /// torus ring and tube radii and their segments
    var majorRadius: Float = 1
    var minorRadius: Float = 0.25
    var majorSegments = 48
    var minorSegments = 12

    static let standard = AddOptions()
  }

  /// add mesh primitives about the origin, z up, faces wound outward
  struct PrimitiveShape
  {
    var points: [SIMD3<Float>] = []
    var faces: [[Int]] = []

    static func named(_ kind: AddKind, _ options: AddOptions = .standard) -> PrimitiveShape
    {
      var s = PrimitiveShape()
      let o = options
      let n = max(o.vertices, 3)
      let origin: (SIMD3<Float>) -> SIMD3<Float> = { _ in .zero }
      let below: (SIMD3<Float>) -> SIMD3<Float> = { SIMD3($0.x, $0.y, $0.z - 1) }
      switch kind
      {
        case .plane:
          s = grid(1, 2)
          s.orient(below)
        case .grid:
          s = grid(max(o.cuts, 1), 2)
          s.orient(below)
        case .circle:
          s.faces.append(ngon(s.ring(n, 1, 0), n))
          s.orient(below)
        case .cube:
          s.points = (0 ..< 8).map { SIMD3($0 & 1 != 0 ? 1 : -1, $0 & 2 != 0 ? 1 : -1, $0 & 4 != 0 ? 1 : -1) }
          s.faces = [[4, 5, 7, 6], [0, 2, 3, 1], [1, 3, 7, 5], [2, 0, 4, 6], [3, 2, 6, 7], [0, 1, 5, 4]]
          s.orient(origin)
        case .uvsphere:
          let segments = n, rings = max(o.rings, 3)
          s.points.append(SIMD3(0, 0, 1))
          for i in 1 ..< rings
          {
            let theta = Float.pi * Float(i) / Float(rings)
            _ = s.ring(segments, sin(theta), cos(theta))
          }

          s.points.append(SIMD3(0, 0, -1))
          let bottom = s.points.count - 1
          for j in 0 ..< segments
          {
            let k = (j + 1) % segments
            s.faces.append([0, 1 + j, 1 + k])
            for i in 0 ..< rings - 2
            {
              s.faces.append([1 + i * segments + j, 1 + (i + 1) * segments + j, 1 + (i + 1) * segments + k, 1 + i * segments + k])
            }

            s.faces.append([1 + (rings - 2) * segments + j, bottom, 1 + (rings - 2) * segments + k])
          }

          s.orient(origin)
        case .icosphere:
          s = icosphere(max(o.subdivisions, 1))
          s.orient(origin)
        case .cylinder, .cone:
          let base = s.ring(n, 1, -1)
          s.faces.append(ngon(base, n))
          if kind == .cylinder
          {
            let top = s.ring(n, 1, 1)
            s.faces.append(ngon(top, n))
            for j in 0 ..< n { s.faces.append([base + j, base + (j + 1) % n, top + (j + 1) % n, top + j]) }
          }
          else
          {
            s.points.append(SIMD3(0, 0, 1))
            let tip = s.points.count - 1
            for j in 0 ..< n { s.faces.append([base + j, base + (j + 1) % n, tip]) }
          }

          s.orient(origin)
        case .torus:
          let major = max(o.majorSegments, 3), minor = max(o.minorSegments, 3)
          for i in 0 ..< major
          {
            let phi = 2 * Float.pi * Float(i) / Float(major)
            for j in 0 ..< minor
            {
              let theta = 2 * Float.pi * Float(j) / Float(minor)
              let r = o.majorRadius + o.minorRadius * cos(theta)
              s.points.append(SIMD3(r * cos(phi), r * sin(phi), o.minorRadius * sin(theta)))
            }
          }

          for i in 0 ..< major
          {
            for j in 0 ..< minor
            {
              let i1 = (i + 1) % major, j1 = (j + 1) % minor
              s.faces.append([i * minor + j, i1 * minor + j, i1 * minor + j1, i * minor + j1])
            }
          }

          s.orient
          { c in
            let flat = SIMD3(c.x, c.y, 0)
            return simd_length(flat) > 1e-6 ? simd_normalize(flat) : flat
          }
        default:
          break
      }

      // the shapes are made two units across then sized to the options
      let scale: SIMD3<Float>
      switch kind
      {
        case .plane, .grid, .cube: scale = SIMD3(repeating: o.size / 2)
        case .circle, .uvsphere, .icosphere: scale = SIMD3(repeating: o.radius)
        case .cylinder, .cone: scale = SIMD3(o.radius, o.radius, o.depth / 2)
        default: scale = SIMD3(repeating: 1)
      }

      if scale != SIMD3(repeating: 1) { s.points = s.points.map { $0 * scale } }
      return s
    }

    /// a polygon's area weighted normal.
    static func newell(_ points: [SIMD3<Float>], _ face: [Int]) -> SIMD3<Float>
    {
      var n = SIMD3<Float>.zero
      for i in face.indices
      {
        let a = points[face[i]], b = points[face[(i + 1) % face.count]]
        n += SIMD3((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y))
      }

      return n
    }

    private mutating func orient(_ reference: (SIMD3<Float>) -> SIMD3<Float>)
    {
      for f in faces.indices
      {
        let c = faces[f].reduce(SIMD3<Float>.zero) { $0 + points[$1] } / Float(faces[f].count)
        if simd_dot(Self.newell(points, faces[f]), c - reference(c)) < 0 { faces[f].reverse() }
      }
    }

    private mutating func ring(_ count: Int, _ radius: Float, _ z: Float) -> Int
    {
      let start = points.count
      for j in 0 ..< count
      {
        let a = 2 * Float.pi * Float(j) / Float(count)
        points.append(SIMD3(radius * cos(a), radius * sin(a), z))
      }

      return start
    }

    private static func ngon(_ start: Int, _ count: Int) -> [Int]
    {
      Array(start ..< start + count)
    }

    private static func grid(_ cuts: Int, _ size: Float) -> PrimitiveShape
    {
      var s = PrimitiveShape()
      for y in 0 ... cuts
      {
        for x in 0 ... cuts
        {
          s.points.append(SIMD3(size * (Float(x) / Float(cuts) - 0.5), size * (Float(y) / Float(cuts) - 0.5), 0))
        }
      }

      for y in 0 ..< cuts
      {
        for x in 0 ..< cuts
        {
          let a = y * (cuts + 1) + x
          s.faces.append([a, a + 1, a + cuts + 2, a + cuts + 1])
        }
      }

      return s
    }

    private static func icosphere(_ subdivisions: Int) -> PrimitiveShape
    {
      let t: Float = (1 + sqrt(5)) / 2
      var s = PrimitiveShape()
      s.points = [SIMD3(-1, t, 0), SIMD3(1, t, 0), SIMD3(-1, -t, 0), SIMD3(1, -t, 0), SIMD3(0, -1, t), SIMD3(0, 1, t),
                  SIMD3(0, -1, -t), SIMD3(0, 1, -t), SIMD3(t, 0, -1), SIMD3(t, 0, 1), SIMD3(-t, 0, -1), SIMD3(-t, 0, 1)]
      s.faces = [[0, 11, 5], [0, 5, 1], [0, 1, 7], [0, 7, 10], [0, 10, 11], [1, 5, 9], [5, 11, 4], [11, 10, 2], [10, 7, 6],
                 [7, 1, 8], [3, 9, 4], [3, 4, 2], [3, 2, 6], [3, 6, 8], [3, 8, 9], [4, 9, 5], [2, 4, 11], [6, 2, 10],
                 [8, 6, 7], [9, 8, 1]]
      for _ in 1 ..< max(subdivisions, 1)
      {
        var middles: [SIMD2<Int>: Int] = [:]
        func middle(_ a: Int, _ b: Int) -> Int
        {
          let key = SIMD2(min(a, b), max(a, b))
          if let m = middles[key] { return m }
          s.points.append((s.points[a] + s.points[b]) * 0.5)
          middles[key] = s.points.count - 1
          return s.points.count - 1
        }

        s.faces = s.faces.flatMap
        { f -> [[Int]] in
          let a = middle(f[0], f[1]), b = middle(f[1], f[2]), c = middle(f[2], f[0])
          return [[f[0], a, c], [f[1], b, a], [f[2], c, b], [a, b, c]]
        }
      }

      s.points = s.points.map { simd_normalize($0) }
      return s
    }
  }
}
