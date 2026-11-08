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
  /// The unique triangles this machine can hold, at about 150 bytes each
  /// once built, uploaded and drawn, against 65% of its memory less what
  /// the process already holds besides the geometry recorded last time,
  /// and the size the frame itself takes after recording.
  ///
  /// Where buffers map files the triangles live on the disk instead, held
  /// to what it or memory can fit, and on a discrete GPU to its memory.
  func uniqueTriangleBudget() -> (regular: Int, prototypes: Int)
  {
    var gpuBudget: UInt64 = 0, gpuAllocated: UInt64 = 0
    gl.gpuMemory(budget: &gpuBudget, allocated: &gpuAllocated)
    let mapsFiles = gl.buffersMapFiles() != 0
    if !mapsFiles, gpuBudget > 0
    {
      return split((Int(gpuBudget) * 9 / 10 - Int(gpuAllocated)) / 150 + geometry.record.triangles)
    }

    // a disk short of room holds its copies in memory instead, so it never holds fewer than memory would.
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
    // the Ptex cache is a fixed size on top of the scene, the triangles don't make room for it.
    let footprint = (result == KERN_SUCCESS ? Int(info.phys_footprint) : 0) - ptex.allocated
    let target = Int(Double(ProcessInfo.processInfo.physicalMemory) * 0.65) - 1536 << 20
    return split(max((target - footprint) / 150, disk) + geometry.record.triangles)
  }

  /// Order independent, a reframe ranks the same meshes differently.
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

  /// Whether memory has freed up well past what the last record was held to
  /// from its initial load is gone. A budget held to the disk or GPU memory
  /// never counted the initial load.
  func triangleBudgetGrew() -> Bool
  {
    var gpuBudget: UInt64 = 0, gpuAllocated: UInt64 = 0
    gl.gpuMemory(budget: &gpuBudget, allocated: &gpuAllocated)
    let mapsFiles = gl.buffersMapFiles() != 0
    if mapsFiles ? Akari.Geom.GeometryCache.shared.freeDisk != nil : gpuBudget > 0 { return false }
    let budget = uniqueTriangleBudget()
    return Double(budget.regular + budget.prototypes) > Double(geometry.record.budget) * 1.25
  }

  /// Recorded triangles past which the shadows stop drawing an
  /// unwelded copy of the static meshes.
  static var unweldedShadowTriangles: Int
  {
    environmentBudget("AKARI_UNWELDED_SHADOW_TRIANGLES", 1_000_000)
  }

  /// The most triangles one transparent mesh brings to the transparency pass.
  static let maxTransparentTriangles = 524_288

  /// Triangles a set of identical static meshes would duplicate before they draw as instances.
  static var duplicateTriangles: Int
  {
    environmentBudget("AKARI_DUPLICATE_TRIANGLES", 262_144)
  }

  /// One triangle per this many pixels a mesh covers is as fine as the screen shows it.
  private static let pixelsPerTriangle = 2.0
  /// An instance's level is measured against its bounding disk, which its visible triangles cover a
  /// fraction of, so it takes more of the disk per triangle to keep them from going sub pixel.
  static let instancePixelsPerTriangle = 12.0
  /// The coarse level a large shape keeps first, enough for its silhouette, and how much
  /// screen it covers to be one.
  private static let silhouettePixelsPerTriangle = 16.0
  private static let silhouetteMinimumPixels = 16384.0

  /// Every large shape in view keeps the coarse level its outline needs, past `budget` if it
  /// has to, what's left then goes to the meshes covering the most screen per triangle, as
  /// many as the screen shows. Levels are powers of two, so they're reused. Ties go to the stable
  /// path hash, so the same scene records the same subset.
  static func budgetGeometry(_ meshes: [Akari.Geom.Recorder.RawMesh], budget: Int,
                                     area: [(total: Double, largest: Double?)])
    -> [(mesh: Akari.Geom.Recorder.RawMesh, triangles: Int)]
  {
    func level(_ mesh: Akari.Geom.Recorder.RawMesh, _ area: (total: Double, largest: Double?), _ pixels: Double) -> Int
    {
      let full = mesh.tris.size()
      guard let largest = area.largest, mesh.uvs.size() <= 1 || mesh.uvs.size() == full * 3 || mesh.uvs.size() == mesh.points.size() else { return full }
      let wanted = max(64, Int(min(largest / pixels, Double(Int32.max))))
      return min(full, 1 << (Int.bitWidth - (wanted - 1).leadingZeroBitCount))
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

  /// Simplifies each mesh to its triangle count, reusing what `cache`
  /// holds, in parallel, and gathers every level drawn into `details`.
  static func applyDetail(_ meshes: [(mesh: Akari.Geom.Recorder.RawMesh, triangles: Int)],
                                  cache: [UInt64: Detail], into details: inout [UInt64: Detail])
    -> [Akari.Geom.Recorder.RawMesh]
  {
    func detailKey(_ mesh: Akari.Geom.Recorder.RawMesh, _ triangles: Int) -> UInt64
    {
      ((mesh.contentKey == 0 ? mesh.key : mesh.contentKey) ^ UInt64(triangles)) &* 1_099_511_628_211
    }

    var pending: [(index: Int, key: UInt64)] = []
    for (index, entry) in meshes.enumerated() where entry.triangles < entry.mesh.tris.size()
    {
      let key = detailKey(entry.mesh, entry.triangles)
      if let found = cache[key] ?? details[key] { details[key] = found } else { pending.append((index, key)) }
    }

    var built = [Detail?](repeating: nil, count: pending.count)
    built.withUnsafeMutableBufferPointer
    { buffer in
      let box = DetailBox(buffer: buffer, meshes: meshes, pending: pending)
      DispatchQueue.concurrentPerform(iterations: pending.count)
      { i in
        let entry = box.meshes[box.pending[i].index]
        var points = Pixar.VtVec3fArray(), tris = Pixar.VtVec3iArray(), uvs = Pixar.VtVec2fArray()
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
      // a pruned mesh's triangles are some of its own, a clustered one's aren't its faces, it draws in its map's average color.
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

  /// Passes the meshes and results into `concurrentPerform`'s closure.
  private struct DetailBox: @unchecked Sendable
  {
    let buffer: UnsafeMutableBufferPointer<Detail?>
    let meshes: [(mesh: Akari.Geom.Recorder.RawMesh, triangles: Int)]
    let pending: [(index: Int, key: UInt64)]
  }
}
