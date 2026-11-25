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
  /// the unique triangles this machine can hold at about 150 bytes each, from free memory, disk when buffers map files, or gpu memory
  func uniqueTriangleBudget() -> (regular: Int, prototypes: Int)
  {
    var gpuBudget: UInt64 = 0
    var gpuAllocated: UInt64 = 0
    gl.gpuMemory(budget: &gpuBudget, allocated: &gpuAllocated)

    let mapsFiles = gl.buffersMapFiles() != 0
    if !mapsFiles, gpuBudget > 0
    {
      return split((Int(gpuBudget) * 9 / 10 - Int(gpuAllocated)) / 150 + geometry.record.triangles)
    }

    // a disk short on room keeps its copies in memory, so it never holds fewer than memory would.
    let disk = mapsFiles ? Akari.Geom.GeometryCache.shared.freeDisk.map { Int($0) / 256 } ?? 0 : 0

    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info)
    {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count))
      {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }

    // the ptex cache is a fixed size on top of the scene, so the triangles do not make room for it.
    let footprint = (result == KERN_SUCCESS ? Int(info.phys_footprint) : 0) - ptex.allocated
    let target = Int(Double(ProcessInfo.processInfo.physicalMemory) * 0.65) - 1536 << 20

    return split(max((target - footprint) / 150, disk) + geometry.record.triangles)
  }

  /// order independent since a reframe can rank the same meshes differently.
  static func recordKey(_ meshes: [Akari.Geom.Recorder.RawMesh]) -> UInt64
  {
    meshes.reduce(UInt64(meshes.count))
    { sum, mesh in
      var key: UInt64 = 14_695_981_039_346_656_037
      let values = [mesh.key, mesh.dataRevision, UInt64(mesh.tris.size()), mesh.instancesKey]
        + mesh.instanceDraws.flatMap { [$0.key, UInt64($0.count), UInt64($0.lod.x.bitPattern) << 32 | UInt64($0.lod.y.bitPattern)] }

      for value in values
      {
        key = (key ^ value) &* 1_099_511_628_211
      }

      return sum &+ key
    }
  }

  private func split(_ triangles: Int) -> (regular: Int, prototypes: Int)
  {
    let triangles = max(1_000_000, triangles)

    return (Self.environmentBudget("AKARI_REGULAR_TRIANGLE_BUDGET", triangles / 3),
            Self.environmentBudget("AKARI_PROTOTYPE_TRIANGLE_BUDGET", triangles - triangles / 3))
  }

  /// whether memory freed up well past what the last record was held to, once its initial load is gone
  func triangleBudgetGrew() -> Bool
  {
    var gpuBudget: UInt64 = 0
    var gpuAllocated: UInt64 = 0
    gl.gpuMemory(budget: &gpuBudget, allocated: &gpuAllocated)

    let mapsFiles = gl.buffersMapFiles() != 0
    if mapsFiles ? Akari.Geom.GeometryCache.shared.freeDisk != nil : gpuBudget > 0 { return false }

    let budget = uniqueTriangleBudget()
    return Double(budget.regular + budget.prototypes) > Double(geometry.record.budget) * 1.25
  }

  /// recorded triangles past which the shadows stop drawing an unwelded copy of the static meshes.
  static var unweldedShadowTriangles: Int
  {
    environmentBudget("AKARI_UNWELDED_SHADOW_TRIANGLES", 1_000_000)
  }

  /// whether refined meshes cast shadows from their cages, turned off with `AKARI_COARSE_SHADOWS=0`.
  static var castsCoarseShadows: Bool
  {
    ProcessInfo.processInfo.environment["AKARI_COARSE_SHADOWS"] != "0"
  }

  /// the most triangles one transparent mesh brings to the transparency pass.
  static let maxTransparentTriangles = 524_288

  /// triangles a set of identical static meshes would duplicate before they draw as instances.
  static var duplicateTriangles: Int
  {
    environmentBudget("AKARI_DUPLICATE_TRIANGLES", 262_144)
  }

  /// one triangle per this many covered pixels is as fine as the screen can show.
  private static let pixelsPerTriangle = 2.0

  /// an instance level is measured against its bounding disk, which its triangles only partly cover, so it needs more pixels a triangle
  static let instancePixelsPerTriangle = 12.0

  /// the coarse level a large shape keeps first for its silhouette, and how much screen makes it large
  private static let silhouettePixelsPerTriangle = 16.0
  private static let silhouetteMinimumPixels = 16384.0

  /// every large shape in view keeps its outline level, the rest of the budget goes to the meshes covering the most screen per triangle
  static func budgetGeometry(_ meshes: [Akari.Geom.Recorder.RawMesh], budget: Int,
                                     area: [(total: Double, largest: Double?)])
    -> [(mesh: Akari.Geom.Recorder.RawMesh, triangles: Int)]
  {
    func level(_ mesh: Akari.Geom.Recorder.RawMesh, _ area: (total: Double, largest: Double?), _ pixels: Double) -> Int
    {
      let full = mesh.tris.size()
      let uvCount = mesh.uvs.size()
      guard let largest = area.largest, uvCount <= 1 || uvCount == full * 3 || uvCount == mesh.points.size() else { return full }

      let wanted = max(64, Int(min(largest / pixels, Double(Int32.max))))
      let picked = min(full, 1 << (Int.bitWidth - (wanted - 1).leadingZeroBitCount))

      // a refined mesh draws in full only when the screen can show at least half its triangles.
      guard mesh.hasCoarse else { return picked }

      return wanted * 2 >= full ? full : min(picked, mesh.coarseTris.size())
    }

    // a shape with a significant silhouette on screen draws in full, only the rest take levels.
    let triangles = zip(meshes, area).map
    { mesh, area in
      (area.largest ?? 0) >= silhouetteMinimumPixels ? mesh.tris.size() : level(mesh, area, pixelsPerTriangle)
    }

    let silhouettes = zip(meshes, area).map
    { mesh, area in
      (area.largest ?? 0) >= silhouetteMinimumPixels ? level(mesh, area, silhouettePixelsPerTriangle) : 0
    }

    let ranked = meshes.indices.sorted
    { lhs, rhs in
      let left = area[lhs].total / Double(max(triangles[lhs], 1))
      let right = area[rhs].total / Double(max(triangles[rhs], 1))
      return left != right ? left > right : meshes[lhs].key < meshes[rhs].key
    }

    var chosen = silhouettes
    var keptTriangles = silhouettes.reduce(0, +)

    for index in ranked where keptTriangles + triangles[index] - chosen[index] <= budget
    {
      keptTriangles += triangles[index] - chosen[index]
      chosen[index] = triangles[index]
    }

    return ranked.filter { chosen[$0] > 0 }.map { (meshes[$0], chosen[$0]) }
  }

  /// simplifies each mesh to its triangle count in parallel, reusing the cache, and gathers every drawn level into `details`
  static func applyDetail(_ meshes: [(mesh: Akari.Geom.Recorder.RawMesh, triangles: Int)],
                                  cache: [UInt64: Detail], into details: inout [UInt64: Detail])
    -> [Akari.Geom.Recorder.RawMesh]
  {
    func detailKey(_ mesh: Akari.Geom.Recorder.RawMesh, _ triangles: Int) -> UInt64
    {
      ((mesh.contentKey == 0 ? mesh.key : mesh.contentKey) ^ UInt64(triangles)) &* 1_099_511_628_211
    }

    // a refined mesh limited to the triangle count of its cage or fewer draws the cage instead.
    let meshes = meshes.map
    { entry in
      guard entry.triangles < entry.mesh.tris.size(), entry.triangles <= entry.mesh.coarseTris.size(),
            let coarse = entry.mesh.coarse
      else { return entry }

      return (mesh: coarse, triangles: min(entry.triangles, coarse.tris.size()))
    }

    var pending: [(index: Int, key: UInt64)] = []
    for (index, entry) in meshes.enumerated() where entry.triangles < entry.mesh.tris.size()
    {
      let key = detailKey(entry.mesh, entry.triangles)
      if let found = cache[key] ?? details[key]
      {
        details[key] = found
      }
      else
      {
        pending.append((index, key))
      }
    }

    var built = [Detail?](repeating: nil, count: pending.count)
    built.withUnsafeMutableBufferPointer
    { buffer in
      let box = DetailBox(buffer: buffer, meshes: meshes, pending: pending)
      DispatchQueue.concurrentPerform(iterations: pending.count)
      { i in
        let entry = box.meshes[box.pending[i].index]
        var points = Pixar.VtVec3fArray()
        var tris = Pixar.VtVec3iArray()
        var uvs = Pixar.VtVec2fArray()
        var sources = Pixar.VtIntArray()

        if Pixar.HdAkariDecimate(entry.mesh.points, entry.mesh.tris, entry.mesh.uvs, entry.triangles,
                                 &points, &tris, &uvs, &sources)
        {
          box.buffer[i] = Detail(points: points, tris: tris, uvs: uvs, sources: sources)
        }
      }
    }

    for (i, item) in pending.enumerated()
    {
      if let detail = built[i] { details[item.key] = detail }
    }

    return meshes.map
    { entry in
      var mesh = entry.mesh
      guard entry.triangles < mesh.tris.size(), let detail = details[detailKey(mesh, entry.triangles)] else { return mesh }

      let level = UInt64(entry.triangles) &* 0x9E37_79B9_7F4A_7C15
      mesh.points = detail.points
      mesh.tris = detail.tris
      mesh.uvs = detail.uvs

      // a pruned mesh keeps some of its own triangles and its face mapping, a clustered one draws in its map's average color
      if !detail.sources.empty(), mesh.triangleFaces.size() == entry.mesh.tris.size()
      {
        mesh.triangleFaces = Pixar.HdAkariSubsetInts(mesh.triangleFaces, detail.sources)
      }
      else
      {
        mesh.triangleFaces = Pixar.VtIntArray()
        mesh.faceRes = Pixar.VtIntArray()
      }

      if mesh.contentKey != 0 { mesh.contentKey = (mesh.contentKey ^ level) &* 1_099_511_628_211 }
      mesh.dataRevision ^= level
      mesh.topologyRevision ^= level

      return mesh
    }
  }

  /// carries the meshes and results into the `concurrentPerform` closure.
  private struct DetailBox: @unchecked Sendable
  {
    let buffer: UnsafeMutableBufferPointer<Detail?>
    let meshes: [(mesh: Akari.Geom.Recorder.RawMesh, triangles: Int)]
    let pending: [(index: Int, key: UInt64)]
  }
}
