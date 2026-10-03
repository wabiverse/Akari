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
import LabFX
import LabGL
import OpenUSDKit

extension Akari.LabFXEngine
{
  /// The scene split into meshes that have animated and the rest, each
  /// in its own capture, so animated frames only rerecord what moves.
  struct SceneGeometry
  {
    var staticCapture: LabGLCaptureBuffer?
    var dynamicCapture: LabGLCaptureBuffer?
    let staticRecorder = Akari.Geom.Recorder(keepsTopology: false)
    /// Lays the animated meshes out once and deforms them on the GPU per frame.
    let deformer = Akari.Geom.Deformer()

    /// Per mesh, a key of its data and transform, and the record it last changed on.
    var changes: [UInt64: (key: UInt64, record: Int)] = [:]
    /// Meshes that changed after they first appeared. They stay dynamic, a pause
    /// demoting them would rerecord the static capture and rebuild them on the way back.
    var animated: Set<UInt64> = []
    var records = 0
    var staticIDs: Set<UInt64> = []
    var dynamicIDs: Set<UInt64> = []

    var staticBatch = BatchSummary()
    var dynamicBatch = BatchSummary()
    var cameraCull = CameraCull()

    /// The non empty captures, static first.
    var captures: [LabGLCaptureBuffer]
    {
      [staticBatch.isEmpty ? nil : staticCapture,
       dynamicBatch.isEmpty ? nil : dynamicCapture].compactMap(\.self)
    }
  }

  /// What a recorded batch leaves behind for bounds and shadow casters.
  struct BatchSummary
  {
    var bounds: (min: SIMD3<Float>, max: SIMD3<Float>)?
    var casterBounds: [Float] = []
    var casterKeys: [UInt64] = []

    var isEmpty: Bool
    {
      bounds == nil
    }
  }

  func createCaptures() -> Bool
  {
    guard
      let staticCapture = labgl.captureCreate(),
      let dynamicCapture = labgl.captureCreate()
    else { return false }

    geometry.staticCapture = staticCapture
    geometry.dynamicCapture = dynamicCapture
    runtime.setMeshCapture("mesh", buffer: staticCapture)
    runtime.setPassCallback("draw-dynamic-geometry", callback: akariDynamicGeometryCallback,
                            userdata: Unmanaged.passUnretained(self).toOpaque())
    return true
  }

  func destroyCaptures()
  {
    for capture in [geometry.staticCapture, geometry.dynamicCapture].compactMap(\.self)
    {
      labgl.captureDestroy(capture)
    }
    geometry = SceneGeometry()
  }

  /// Deforms the dynamic meshes on the GPU, and rerecords
  /// the static ones only when which meshes are static changed.
  func recordCaptures(_ meshes: [Akari.Geom.Recorder.RawMesh])
  {
    guard
      let staticCapture = geometry.staticCapture,
      let dynamicCapture = geometry.dynamicCapture
    else { return }

    geometry.records += 1
    let record = geometry.records

    var staticMeshes: [Akari.Geom.Recorder.RawMesh] = []
    var dynamicMeshes: [Akari.Geom.Recorder.RawMesh] = []
    var staticIDs = Set<UInt64>(minimumCapacity: meshes.count)
    var dynamicIDs = Set<UInt64>()
    var dynamicChanged = false

    for mesh in meshes
    {
      let key = Self.changeKey(mesh)
      let changedOn: Int
      if let last = geometry.changes[mesh.key]
      {
        changedOn = last.key == key ? last.record : record
        if changedOn == record { geometry.animated.insert(mesh.key) }
      }
      else
      {
        // new meshes start static, so loading
        // a scene isn't one long animation.
        changedOn = 0
      }
      geometry.changes[mesh.key] = (key, changedOn)

      if geometry.animated.contains(mesh.key)
      {
        dynamicMeshes.append(mesh)
        dynamicIDs.insert(mesh.key)
        dynamicChanged = dynamicChanged || changedOn == record
      }
      else
      {
        staticMeshes.append(mesh)
        staticIDs.insert(mesh.key)
      }
    }
    if geometry.changes.count > meshes.count
    {
      let live = staticIDs.union(dynamicIDs)
      geometry.changes = geometry.changes.filter { live.contains($0.key) }
      geometry.animated.formIntersection(live)
    }

    if staticIDs != geometry.staticIDs || record == 1
    {
      geometry.staticIDs = staticIDs
      geometry.staticBatch = recordBatch(staticMeshes, into: staticCapture, recorder: geometry.staticRecorder)
    }
    if dynamicIDs != geometry.dynamicIDs || dynamicChanged
    {
      geometry.dynamicIDs = dynamicIDs
      if geometry.deformer.needsRebuild(dynamicMeshes)
      {
        geometry.deformer.rebuild(dynamicMeshes, into: dynamicCapture)
      }
      let deformed = geometry.deformer.update(dynamicMeshes)
      geometry.dynamicBatch = BatchSummary(bounds: deformed.bounds, casterBounds: deformed.casterBounds,
                                           casterKeys: deformed.casterKeys)
    }

    let batches = [geometry.staticBatch, geometry.dynamicBatch]
    var bounds: (min: SIMD3<Float>, max: SIMD3<Float>)?
    for next in batches.compactMap(\.bounds)
    {
      bounds = bounds.map { (min: pointwiseMin($0.min, next.min), max: pointwiseMax($0.max, next.max)) } ?? next
    }
    sceneBounds = bounds
    casterBounds = batches.flatMap(\.casterBounds)
    casterKeys = batches.flatMap(\.casterKeys)
  }

  func recordBatch(_ meshes: [Akari.Geom.Recorder.RawMesh],
                   into capture: LabGLCaptureBuffer,
                   recorder: Akari.Geom.Recorder,
                   reusing others: [Akari.Geom.Recorder] = []) -> BatchSummary
  {
    labgl.captureClear(capture)
    let sorted = meshes.sorted { Self.mortonKey($0.worldMatrix) < Self.mortonKey($1.worldMatrix) }
    let items = recorder.record(sorted, reusing: others)
    guard !items.isEmpty else { return BatchSummary() }

    gl.bindTexture(target: GL_TEXTURE_2D, texture: 0)
    labgl.captureStart(capture)

    gl.enable(GL_DEPTH_TEST)
    gl.depthFunc(GLenum(GL_GREATER))

    gl.enable(GL_CULL_FACE)
    gl.cullFace(GL_BACK)
    gl.frontFace(GL_CCW)

    let batch = Akari.Geom.Batch(estimatedTriangles: meshes.reduce(0) { $0 + $1.tris.size() })
    for item in items
    {
      item.worldMatrix.withUnsafeBufferPointer
      { buf in
        batch.append(localVerts: item.verts, localIndices: item.indices,
                     worldMatrix: buf.baseAddress!, normalMatrix: item.normalMatrix,
                     primId: item.primId, key: Self.casterKey(item))
      }
    }
    batch.draw()
    labgl.captureStop()

    return BatchSummary(bounds: batch.worldBounds, casterBounds: batch.casterBounds, casterKeys: batch.casterKeys)
  }

  fileprivate func drawDynamicGeometry()
  {
    guard !geometry.dynamicBatch.isEmpty, let dynamicCapture = geometry.dynamicCapture else { return }
    labgl_capturePlaybackIndirect(dynamicCapture)
  }

  /// Changes whenever the item moves or deforms, for the shadows' moved caster test.
  private static func casterKey(_ item: Akari.Geom.Recorder.Item) -> UInt64
  {
    var key = (14_695_981_039_346_656_037 ^ item.dataRevision) &* 1_099_511_628_211
    for value in item.worldMatrix
    {
      key = (key ^ UInt64(value.bitPattern)) &* 1_099_511_628_211
    }
    return key
  }

  /// Hash of what a mesh looks like in the world, changes whenever it animates.
  private static func changeKey(_ mesh: Akari.Geom.Recorder.RawMesh) -> UInt64
  {
    var key: UInt64 = 14_695_981_039_346_656_037
    func mix(_ bits: UInt64)
    {
      key = (key ^ bits) &* 1_099_511_628_211
    }
    mix(mesh.dataRevision)
    mix(mesh.flipWinding ? 1 : 0)
    for value in mesh.worldMatrix
    {
      mix(UInt64(value.bitPattern))
    }
    return key
  }

  /// Morton code of a mesh's world position,
  /// quantized against a fixed grid (in meters).
  private static func mortonKey(_ worldMatrix: [Float]) -> UInt64
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

/// `Runtime.setPassCallback` takes a plain C function pointer.
private func akariDynamicGeometryCallback(_ userdata: UnsafeMutableRawPointer?, _: Int32, _: Int32)
{
  guard let userdata else { return }
  Unmanaged<Akari.LabFXEngine>.fromOpaque(userdata).takeUnretainedValue().drawDynamicGeometry()
}
