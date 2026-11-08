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
import HdAkari
import HydraKit
import LabFX
import LabGL
import simd

extension Akari.LabFXEngine
{
  /// Each heavy instance set's prototypes again at coarser levels, a quarter of the triangles each,
  /// every instance drawing the one its size on screen needs, picked on the GPU each frame. A set's
  /// prototypes switch levels together a cluster at a time, cells of its bounds, at the pixels the
  /// cluster's triangles cover as finely as the screen shows, so a prototype spread over a field
  /// coarsens where it's far, a prototype with fewer levels drawing its coarsest past where it ends.
  static func instanceLevels(_ meshes: [(mesh: Akari.Geom.Recorder.RawMesh, triangles: Int)],
                             camera: RecordCamera? = nil)
    -> (meshes: [(mesh: Akari.Geom.Recorder.RawMesh, triangles: Int)], detail: Float)
  {
    let chains = meshes.map { levelChain($0.mesh, $0.triangles) }
    let spheres = meshes.map { boundingSphere($0.mesh) }
    let sets = instanceSets(meshes, spheres: spheres)

    var clusters: [UInt64: [SIMD3<Int32>: InstanceCluster]] = [:]
    var cellOf: [UInt64: [Int: SIMD3<Int32>]] = [:]
    for (key, set) in sets
    {
      let top = set.members.reduce(0) { $0 + chains[$1][0] }
      guard top * set.count >= levelledSetTriangles else { continue }
      var (cells, cellsOf) = gatherClusters(set, chains: chains, spheres: spheres)
      for (at, var cluster) in cells
      {
        thin(&cluster, meshes: meshes, chains: chains, spheres: spheres)
        cells[at] = cluster
      }

      clusters[key] = cells
      cellOf[key] = cellsOf
    }

    let detail = camera.map { instanceDetail($0, meshes: meshes, sets: sets, chains: chains, clusters: clusters) } ?? 1
    let levelled = levelledCopies(meshes, clusters: clusters, cellOf: cellOf)
    return (levelled, detail)
  }

  typealias InstanceSet = (count: Int, members: [Int], lo: SIMD3<Float>, hi: SIMD3<Float>)

  /// A cell of prototypes in an instance set, switching levels together.
  struct InstanceCluster
  {
    var triangles: [Int]
    var lo: SIMD3<Float>
    var hi: SIMD3<Float>
    var members: [Int] = []
    /// Pixels each level stops at, the finest's at infinity.
    var bands: [Float] = []
    /// Per member and level, the triangles it keeps and how much it grows, nil when pruned.
    var levels: [Int: [(triangles: Int, grow: Float)?]] = [:]
  }

  /// The triangle counts a prototype simplifies through, a quarter each, kept whole when its uvs can't follow.
  private static func levelChain(_ mesh: Akari.Geom.Recorder.RawMesh, _ top: Int) -> [Int]
  {
    guard mesh.uvs.size() <= 1 || mesh.uvs.size() == mesh.tris.size() * 3 || mesh.uvs.size() == mesh.points.size() else { return [top] }
    var levels = [top]
    while levels.count < instanceLevelCount
    {
      let next = levels[levels.count - 1] / 4
      guard next >= minimumLevelTriangles else { break }
      levels.append(1 << (Int.bitWidth - 1 - next.leadingZeroBitCount))
    }

    return levels
  }

  /// Every instance set with its prototypes and their bounds.
  private static func instanceSets(_ meshes: [(mesh: Akari.Geom.Recorder.RawMesh, triangles: Int)],
                                   spheres: [(center: SIMD3<Float>, radius: Float)]) -> [UInt64: InstanceSet]
  {
    var sets: [UInt64: InstanceSet] = [:]
    for (index, (mesh, _)) in meshes.enumerated()
    {
      let sphere = spheres[index]
      for draw in mesh.instanceDraws
      {
        var entry = sets[draw.key] ?? (draw.count, [], sphere.center - sphere.radius, sphere.center + sphere.radius)
        entry.members.append(index)
        entry.lo = simd_min(entry.lo, sphere.center - sphere.radius)
        entry.hi = simd_max(entry.hi, sphere.center + sphere.radius)
        sets[draw.key] = entry
      }
    }

    return sets
  }

  /// A set's prototypes gathered into cells of its bounds, and the cell each one fell in.
  private static func gatherClusters(_ set: InstanceSet, chains: [[Int]], spheres: [(center: SIMD3<Float>, radius: Float)])
    -> ([SIMD3<Int32>: InstanceCluster], [Int: SIMD3<Int32>])
  {
    let cell = max(simd_reduce_max(set.hi - set.lo) / Float(clusterCells), 1e-6)
    var cells: [SIMD3<Int32>: InstanceCluster] = [:]
    var cellsOf: [Int: SIMD3<Int32>] = [:]
    for index in set.members
    {
      let sphere = spheres[index], levels = chains[index]
      let at = SIMD3<Int32>(((sphere.center - set.lo) / cell).rounded(.down).clamped(lowerBound: .zero,
                                                                                      upperBound: SIMD3(repeating: Float(clusterCells - 1))))
      var cluster = cells[at] ?? InstanceCluster(triangles: [Int](repeating: 0, count: instanceLevelCount),
                                                 lo: sphere.center - sphere.radius, hi: sphere.center + sphere.radius)
      for k in 0 ..< instanceLevelCount
      {
        cluster.triangles[k] += levels[min(k, levels.count - 1)]
      }

      cluster.lo = simd_min(cluster.lo, sphere.center - sphere.radius)
      cluster.hi = simd_max(cluster.hi, sphere.center + sphere.radius)
      cluster.members.append(index)
      cells[at] = cluster
      cellsOf[index] = at
    }

    return (cells, cellsOf)
  }

  /// Each coarser level of a cluster, its small parts thinned and its large ones simplified.
  private static func thin(_ cluster: inout InstanceCluster, meshes: [(mesh: Akari.Geom.Recorder.RawMesh, triangles: Int)],
                           chains: [[Int]], spheres: [(center: SIMD3<Float>, radius: Float)])
  {
    // parts too small to simplify thin out instead, an even sample of them kept and grown by the area they stand for.
    // only parts small against their cluster thin out, the large ones simplify.
    let radius = simd_length(cluster.hi - cluster.lo) * 0.5
    let order = cluster.members.sorted { meshes[$0].mesh.key &* 0x9E37_79B9_7F4A_7C15 < meshes[$1].mesh.key &* 0x9E37_79B9_7F4A_7C15 }
    let small = order.map { spheres[$0].radius * smallPartRatio <= radius }
    for index in order { cluster.levels[index] = [(chains[index][0], 1)] }
    for k in 1 ..< instanceLevelCount
    {
      let simplified = order.map { chains[$0][min(k, chains[$0].count - 1)] }
      let large = zip(simplified, small).reduce(0) { $0 + ($1.1 ? 0 : $1.0) }
      let total = simplified.reduce(0, +) - large
      let target = max((cluster.triangles[0] >> (2 * k)) - large, minimumLevelTriangles)
      var kept = 0
      var keeps = small.map { !$0 }
      for (slot, triangles) in simplified.enumerated() where small[slot] && (kept == 0 || kept + triangles <= target)
      {
        keeps[slot] = true
        kept += triangles
      }

      let grow = kept < total ? Float(min((Double(total) / Double(max(kept, 1))).squareRoot(), 3)) : 1
      for (slot, index) in order.enumerated()
      {
        cluster.levels[index]?.append(keeps[slot] ? (simplified[slot], small[slot] ? grow : 1) : nil)
      }

      cluster.triangles[k] = kept + large
    }

    cluster.bands = [.infinity] + cluster.triangles.dropFirst().map { Float((Double($0) * instancePixelsPerTriangle / .pi).squareRoot()) } + [0]
  }

  /// The camera's own pixels pick each level, coarser as far as it takes the instances in view to fit the drawn budget.
  private static func instanceDetail(_ camera: RecordCamera, meshes: [(mesh: Akari.Geom.Recorder.RawMesh, triangles: Int)],
                                     sets: [UInt64: InstanceSet], chains: [[Int]],
                                     clusters: [UInt64: [SIMD3<Int32>: InstanceCluster]]) -> Float
  {
    var transforms: [UInt64: Akari.Geom.Matrices] = [:]
    for (mesh, _) in meshes
    {
      for d in mesh.instanceDraws where transforms[d.key] == nil { transforms[d.key] = d.transforms }
    }

    var fixed = 0
    var pixels: [Float] = []
    var refs: [Int32] = []
    var levels: [(bands: [Float], triangles: [Int])] = []
    for (key, set) in sets
    {
      guard let xf = transforms[key], xf.count >= set.count * 16 else { continue }
      let top = set.members.reduce(0) { $0 + chains[$1][0] }
      let cells = clusters[key].map { Array($0.values) } ?? []
      let first = levels.count
      levels += cells.map { ($0.bands, $0.triangles) }
      let bounds = cells.isEmpty ? [(set.lo, set.hi)] : cells.map { ($0.lo, $0.hi) }
      for i in 0 ..< set.count
      {
        let o = i * 16
        for (c, (lo, hi)) in bounds.enumerated()
        {
          let l = (lo + hi) * 0.5
          let center = SIMD3(xf[o] * l.x + xf[o + 4] * l.y + xf[o + 8] * l.z + xf[o + 12],
                             xf[o + 1] * l.x + xf[o + 5] * l.y + xf[o + 9] * l.z + xf[o + 13],
                             xf[o + 2] * l.x + xf[o + 6] * l.y + xf[o + 10] * l.z + xf[o + 14])
          let r = simd_length(hi - lo) * 0.5 * maxScale(xf, o)
          guard camera.pixels(center: center, radius: r) > 0 else { continue }
          guard !cells.isEmpty else { fixed += top; continue }
          let d = simd_distance(center, camera.eye)
          pixels.append(d > r ? camera.pixelScale * r / d : .infinity)
          refs.append(Int32(first + c))
        }
      }
    }

    func drawn(_ scale: Float) -> Int
    {
      var total = fixed
      for (px, ref) in zip(pixels, refs)
      {
        let level = levels[Int(ref)]
        guard px >= instanceMinPixels else { continue }
        var k = 0
        while k + 1 < instanceLevelCount && px * scale < level.bands[k + 1] { k += 1 }
        total += level.triangles[k]
      }

      return total
    }

    let budget = drawnTriangleBudget
    guard drawn(1) > budget else { return 1 }
    var lo: Float = 1e-4, hi: Float = 1
    for _ in 0 ..< 24
    {
      let mid = (lo * hi).squareRoot()
      if drawn(mid) <= budget { lo = mid } else { hi = mid }
    }

    return lo
  }

  /// Each mesh once per triangle count and growth it draws at, with the sets and bands it draws in.
  private static func levelledCopies(_ meshes: [(mesh: Akari.Geom.Recorder.RawMesh, triangles: Int)],
                                     clusters: [UInt64: [SIMD3<Int32>: InstanceCluster]],
                                     cellOf: [UInt64: [Int: SIMD3<Int32>]]) -> [(mesh: Akari.Geom.Recorder.RawMesh, triangles: Int)]
  {
    var levelled: [(mesh: Akari.Geom.Recorder.RawMesh, triangles: Int)] = []
    for (index, (mesh, top)) in meshes.enumerated()
    {
      var copies: [SIMD2<UInt64>: (triangles: Int, grow: Float, draws: [Akari.Geom.Recorder.InstanceDraw])] = [:]
      var order: [SIMD2<UInt64>] = []
      func add(_ triangles: Int, _ grow: Float, _ draw: Akari.Geom.Recorder.InstanceDraw)
      {
        let key = SIMD2(UInt64(triangles), UInt64(grow.bitPattern))
        if copies[key] == nil { order.append(key) }
        copies[key, default: (triangles, grow, [])].draws.append(draw)
      }

      for draw in mesh.instanceDraws
      {
        guard let at = cellOf[draw.key]?[index], let cluster = clusters[draw.key]?[at],
              let states = cluster.levels[index]
        else
        {
          add(top, 1, draw)
          continue
        }

        var k = 0
        while k < states.count
        {
          var end = k
          while end + 1 < states.count, states[end + 1]?.triangles == states[k]?.triangles, states[end + 1]?.grow == states[k]?.grow { end += 1 }
          if let state = states[k]
          {
            var level = draw
            level.lod = SIMD2(cluster.bands[end + 1], cluster.bands[k])
            level.bounds = [cluster.lo.x, cluster.lo.y, cluster.lo.z, cluster.hi.x, cluster.hi.y, cluster.hi.z]
            add(state.triangles, state.grow, level)
          }

          k = end + 1
        }
      }

      for key in order
      {
        guard let entry = copies[key] else { continue }
        var copy = mesh
        copy.instanceDraws = entry.draws
        if entry.triangles != top || entry.grow != 1 { copy.id += "@\(entry.triangles)x\(entry.grow)" }
        if entry.grow != 1
        {
          let mix = UInt64(entry.grow.bitPattern) &* 0x9E37_79B9_7F4A_7C15
          copy.points = Pixar.HdAkariGrowPoints(copy.points, entry.grow)
          copy.key = (copy.key ^ mix) &* 1_099_511_628_211
          if copy.contentKey != 0 { copy.contentKey = (copy.contentKey ^ mix) &* 1_099_511_628_211 }
          copy.dataRevision ^= mix
          copy.topologyRevision ^= mix
        }

        levelled.append((copy, entry.triangles))
      }
    }

    return levelled
  }

  /// Cells across an instance set's bounds its prototypes cluster into to switch levels.
  private static let clusterCells = 8
  /// The most triangles the instances in view draw a frame, every one at the level its pixels pick
  /// when they fit, the levels picked coarser together when they don't.
  private static var drawnTriangleBudget: Int
  {
    environmentBudget("AKARI_DRAWN_TRIANGLE_BUDGET", 12_000_000)
  }

  /// A part this many times smaller than its cluster thins out at coarser levels, a larger one simplifies.
  private static let smallPartRatio: Float = 8

  /// Levels of detail an instance set records, and the fewest triangles a coarser one keeps.
  private static let instanceLevelCount = 6
  private static let minimumLevelTriangles = 8
  /// Triangles a set draws with every instance at its finest, past which it takes levels.
  private static var levelledSetTriangles: Int
  {
    environmentBudget("AKARI_LEVELLED_SET_TRIANGLES", 65536)
  }

  /// Splits off sets of identical static meshes, the same content under different transforms,
  /// heavy enough to be worth drawing as one instanced prototype, recorded once in object space,
  /// each copy's transform an instance. Instances share their prototype's prim id, so picking one
  /// reports the first.
  static func instanceDuplicates(_ meshes: [Akari.Geom.Recorder.RawMesh]) -> (regular: [Akari.Geom.Recorder.RawMesh], instanced: [Akari.Geom.Recorder.RawMesh])
  {
    var groups: [UInt64: [Int]] = [:]
    for (index, mesh) in meshes.enumerated() where mesh.contentKey != 0
    {
      groups[mesh.contentKey, default: []].append(index)
    }

    var duplicated = [Bool](repeating: false, count: meshes.count)
    var instanced: [Akari.Geom.Recorder.RawMesh] = []
    let identity: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
    for (contentKey, members) in groups where members.count > 1
    {
      guard (members.count - 1) * meshes[members[0]].tris.size() >= duplicateTriangles else { continue }
      let sorted = members.sorted { meshes[$0].key < meshes[$1].key }
      var prototype = meshes[sorted[0]]
      prototype.id = "duplicate:\(contentKey)"
      prototype.key = contentKey
      prototype.dataRevision = contentKey
      prototype.topologyRevision = contentKey
      prototype.worldMatrix = identity
      prototype.normalMatrix = [1, 0, 0, 0, 1, 0, 0, 0, 1]
      let floats = sorted.flatMap { meshes[$0].worldMatrix }
      prototype.instances = Akari.Geom.Matrices(floats)
      prototype.instancesKey = hashFloats(floats)
      for index in sorted
      {
        duplicated[index] = true
      }

      instanced.append(prototype)
    }

    return (zip(meshes, duplicated).compactMap { $1 ? nil : $0 }, instanced)
  }

  /// The most copies an instanced mesh expands into for the paths
  /// that can't draw instances, its sets order keeps them an even
  /// sample.
  private static let maxExpandedInstances = 20000

  /// Copies an instanced mesh once per instance, giving each copy
  /// its own key and world transform, for the paths that can't
  /// draw instances.
  /// Instances a mesh small against its set measures its own screen through, the rest scale it.
  static let maxMeasuredInstances = 4096

  static func expandInstances(_ mesh: Akari.Geom.Recorder.RawMesh) -> [Akari.Geom.Recorder.RawMesh]
  {
    let count = min(mesh.instances.count / 16, maxExpandedInstances)
    var copies: [Akari.Geom.Recorder.RawMesh] = []
    copies.reserveCapacity(count)
    for instance in 0 ..< count
    {
      var copy = mesh
      copy.instances = []
      copy.instancesKey = 0
      // the instance applies after the mesh's own transform, both column major.
      let o = instance * 16
      var world = [Float](repeating: 0, count: 16)
      for c in 0 ..< 4
      {
        for r in 0 ..< 4
        {
          var sum: Float = 0
          for k in 0 ..< 4
          {
            sum += mesh.instances[o + k * 4 + r] * mesh.worldMatrix[c * 4 + k]
          }

          world[c * 4 + r] = sum
        }
      }

      copy.worldMatrix = world
      let (normal, mirrored) = copy.worldMatrix.withUnsafeBufferPointer
      {
        (Akari.Matrix.normalMatrix3x3($0.baseAddress!),
         Akari.Matrix.determinant3x3($0.baseAddress!) < 0)
      }

      copy.normalMatrix = normal
      copy.flipWinding = mirrored
      copy.id = "\(mesh.id)#\(instance)"
      copy.key = instanceKey(mesh.key, UInt64(instance))
      copies.append(copy)
    }

    return copies
  }

  /// A stable key per expanded instance, distinct from its prototypes.
  private static func instanceKey(_ key: UInt64, _ instance: UInt64) -> UInt64
  {
    var mixed = key
    for shift in stride(from: 0, through: 32, by: 16)
    {
      mixed = (mixed ^ ((instance >> UInt64(shift)) & 0xFFFF)) &* 1_099_511_628_211
    }

    return mixed
  }

  /// Morton code of a mesh's world position,
  /// quantized against a fixed grid (in meters).
  static func mortonKey(_ mesh: Akari.Geom.Recorder.RawMesh) -> UInt64
  {
    if let draw = mesh.instanceDraws.first, draw.transforms.count >= 16
    {
      return mortonKey(Array(draw.transforms[0 ..< 16]))
    }

    return mortonKey(mesh.worldMatrix)
  }

  /// Morton code of a matrix's translation.
  static func mortonKey(_ worldMatrix: [Float]) -> UInt64
  {
    func part(_ v: Float) -> UInt64
    {
      var x = UInt64(UInt32(bitPattern: Int32(max(-1_048_576, min(1_048_575, (v * 8).rounded())) + 1_048_576)) & 0x1FFFFF)
      x = (x | (x << 32)) & 0x1F_0000_0000_FFFF
      x = (x | (x << 16)) & 0x1F_0000_FF00_00FF
      x = (x | (x << 8)) & 0x100F_00F0_0F00_F00F
      x = (x | (x << 4)) & 0x10C3_0C30_C30C_30C3
      x = (x | (x << 2)) & 0x1249_2492_4924_9249
      return x
    }

    return part(worldMatrix[12]) | (part(worldMatrix[13]) << 1) | (part(worldMatrix[14]) << 2)
  }
}
