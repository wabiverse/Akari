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
  /// What `choose` reads, snapshotted on the render thread.
  struct ChooseInputs: @unchecked Sendable
  {
    var meshes: [Akari.Geom.Recorder.RawMesh]
    var camera: RecordCamera?
    var budget: (regular: Int, prototypes: Int)
    var details: [UInt64: Detail]
    var staticKey: UInt64
    /// nil when there's no instanced capture yet.
    var instancedKey: UInt64?
    var faces: Int
    var expands: Bool
    var staticRecorder: Akari.Geom.Recorder
    var instancedRecorder: Akari.Geom.Recorder
    var ptexFaces: Akari.Geom.PtexFaces
  }

  /// What the static captures are chosen to draw and built ready to record, a capture keeping what it has nil.
  struct Chosen: @unchecked Sendable
  {
    var details: [UInt64: Detail]
    var recordBudget: Int
    var recordedTriangles: Int
    var staticKey: UInt64
    var instancedKey: UInt64
    var resetsFaces: Bool
    var staticShadowShared: Bool
    var instanceDetail: Float
    var regular: BuiltBatch?
    var instanced: BuiltBatch?
  }

  /// A reframe choosing and building off the render thread.
  final class Reframing: @unchecked Sendable
  {
    let done = DispatchGroup()
    var chosen: Chosen?
  }

  /// A batch's chunks sealed ready to record, each between its own capture start and stop.
  struct BuiltBatch: @unchecked Sendable
  {
    var chunks: [[Akari.Geom.Batch.Flush]] = []
    var expanded: [[Akari.Geom.Batch.Flush]] = []
    var summary = BatchSummary()
  }

  /// Chooses the static meshes and instanced prototypes the budget keeps for `camera`, and builds the
  /// captures whose choice changed, without touching GL, so it can run on any thread.
  static func choose(_ inputs: ChooseInputs) -> Chosen
  {
    let (unique, duplicates) = instanceDuplicates(inputs.meshes.filter(\.instances.isEmpty))
    let budget = inputs.budget
    let screen = unique.map { screenPixels($0, camera: inputs.camera) }
    let regular = budgetGeometry(unique, budget: budget.regular, area: screen)
    var details: [UInt64: Detail] = [:]
    let regularMeshes = applyDetail(regular, cache: inputs.details, into: &details)
    let instancedPrototypes = inputs.meshes.filter { !$0.instances.isEmpty } + duplicates
    var (binned, instanceDetail) = binInstances(instancedPrototypes, budget: budget.prototypes, camera: inputs.camera)
    let instancedMeshes = applyDetail(binned, cache: inputs.details, into: &details)
    let recordedTriangles = (regularMeshes + instancedMeshes).reduce(0) { $0 + $1.tris.size() }
    // the camera moving on rarely changes what's chosen, a capture choosing the same isn't rebuilt.
    let staticKey = recordKey(regularMeshes), instancedKey = recordKey(instancedMeshes)
    var recordsStatic = staticKey != inputs.staticKey
    var recordsInstanced = inputs.instancedKey.map { instancedKey != $0 } ?? true
    // the face table only grows while one capture rebuilds alone, both rebuilding start it over.
    if recordsStatic != recordsInstanced, inputs.faces > 4 * (recordedTriangles + 1)
    {
      recordsStatic = true
      recordsInstanced = true
    }

    if recordsStatic || recordsInstanced { Akari.Geom.GeometryCache.shared.beginRecord() }
    let staticShadowShared = recordedTriangles > unweldedShadowTriangles
    return Chosen(details: details, recordBudget: budget.regular + budget.prototypes,
                  recordedTriangles: recordedTriangles, staticKey: staticKey, instancedKey: instancedKey,
                  resetsFaces: recordsStatic && recordsInstanced, staticShadowShared: staticShadowShared,
                  instanceDetail: instanceDetail,
                  regular: !recordsStatic ? nil : buildBatch(regularMeshes, recorder: inputs.staticRecorder,
                                                             expands: inputs.expands && !staticShadowShared,
                                                             ptexFaces: inputs.ptexFaces),
                  instanced: !recordsInstanced ? nil : buildBatch(instancedMeshes, recorder: inputs.instancedRecorder,
                                                                  instanced: true, ptexFaces: inputs.ptexFaces))
  }

  /// Records what `choose` built into the static captures.
  func apply(_ chosen: Chosen)
  {
    guard let staticCapture = geometry.staticCapture else { return }
    geometry.record.rebuilds += 1
    geometry.record.rebuiltAt = Date()
    geometry.details = chosen.details
    geometry.record.budget = chosen.recordBudget
    geometry.record.triangles = chosen.recordedTriangles
    if chosen.resetsFaces { ptex.faces.reset() }
    if let regular = chosen.regular
    {
      geometry.record.staticKey = chosen.staticKey
      geometry.staticShadowShared = chosen.staticShadowShared
      if geometry.staticShadowShared, let shadow = geometry.staticShadowCapture { labgl.captureClear(shadow) }
      geometry.staticBatch = emitBatch(regular, into: staticCapture,
                                       expandedInto: geometry.staticShadowShared ? nil : geometry.staticShadowCapture)
    }

    if let instanced = chosen.instanced, let capture = geometry.staticInstancedCapture
    {
      geometry.record.instancedKey = chosen.instancedKey
      // a record's fit only moves the base the frame budget's scale works from, the detail drawn stays put.
      let previous = geometry.instanceLOD.detail
      geometry.instanceLOD.detail = chosen.instanceDetail
      if geometry.instanceLOD.fitted, previous > 0, chosen.instanceDetail > 0
      {
        dynamicResolution.geometryTarget *= previous / chosen.instanceDetail
        dynamicResolution.geometryScale *= previous / chosen.instanceDetail
      }

      geometry.instanceLOD.fitted = true
      geometry.instancedBatch = emitBatch(instanced, into: capture, instanced: true)
    }
  }

  func recordBatch(_ meshes: [Akari.Geom.Recorder.RawMesh],
                   into capture: LabGLCaptureBuffer,
                   expandedInto expanded: LabGLCaptureBuffer? = nil,
                   recorder: Akari.Geom.Recorder,
                   reusing others: [Akari.Geom.Recorder] = [],
                   instanced: Bool = false) -> BatchSummary
  {
    let built = Self.buildBatch(meshes, recorder: recorder, reusing: others, expands: expanded != nil,
                                instanced: instanced, ptexFaces: ptex.faces)
    return emitBatch(built, into: capture, expandedInto: expanded, instanced: instanced)
  }

  /// Builds and seals a batch's chunks, without touching GL.
  private static func buildBatch(_ meshes: [Akari.Geom.Recorder.RawMesh],
                                 recorder: Akari.Geom.Recorder,
                                 reusing others: [Akari.Geom.Recorder] = [],
                                 expands: Bool = false,
                                 instanced: Bool = false,
                                 ptexFaces: Akari.Geom.PtexFaces) -> BuiltBatch
  {
    // instanced prototypes sharing a set sit next to each other, so their draws merge into one per run of the set.
    let keyed: [(mesh: Akari.Geom.Recorder.RawMesh, set: UInt64, level: Float, cluster: UInt64, morton: UInt64)] = meshes.map
    { mesh in
      let draw = mesh.instanceDraws.first
      return (mesh, instanced ? draw?.key ?? 0 : 0, draw?.lod.y ?? 0, hashFloats(draw?.bounds ?? []), mortonKey(mesh))
    }

    let sorted = keyed.sorted
    {
      $0.set != $1.set ? $0.set < $1.set : $0.level != $1.level ? $0.level > $1.level
        : $0.cluster != $1.cluster ? $0.cluster < $1.cluster : $0.morton < $1.morton
    }.map(\.mesh)
    var built = BuiltBatch()
    recorder.record(sorted, reusing: others)
    { items in
      // instanced captures keep the prototypes object space vertices, the matrices move them, so they can't be unwelded like the static ones.
      if expands { built.expanded.append(build(items, expands: !instanced, instanced: instanced).flushes) }
      let chunk = build(items, expands: false, instanced: instanced, ptexFaces: ptexFaces)
      built.chunks.append(chunk.flushes)
      if let next = chunk.summary.bounds
      {
        built.summary.bounds = built.summary.bounds.map { (min: pointwiseMin($0.min, next.min), max: pointwiseMax($0.max, next.max)) } ?? next
      }

      built.summary.casterBounds += chunk.summary.casterBounds
      built.summary.casterKeys += chunk.summary.casterKeys
    }

    return built
  }

  /// Records a built batch into `capture`, and its unwelded copy into `expanded`.
  private func emitBatch(_ built: BuiltBatch, into capture: LabGLCaptureBuffer,
                         expandedInto expanded: LabGLCaptureBuffer? = nil, instanced: Bool = false) -> BatchSummary
  {
    labgl.captureClear(capture)
    if let expanded { labgl.captureClear(expanded) }
    for (index, flushes) in built.chunks.enumerated()
    {
      if let expanded, index < built.expanded.count
      {
        emit(built.expanded[index], into: expanded, instanced: instanced, preamble: index == 0, ptexFaces: nil)
      }

      emit(flushes, into: capture, instanced: instanced, preamble: index == 0, ptexFaces: ptex.faces)
    }

    return built.summary
  }

  /// Builds one chunk of a batch into sealed flushes.
  private static func build(_ items: [Akari.Geom.Recorder.Item], expands: Bool, instanced: Bool = false,
                            ptexFaces: Akari.Geom.PtexFaces? = nil) -> (flushes: [Akari.Geom.Batch.Flush], summary: BatchSummary)
  {
    let largestVerts = items.reduce(0) { max($0, expands ? $1.indices.count : $1.verts.count / 8) }
    let largestIndices = items.reduce(0) { max($0, $1.indices.count) }
    let batch = Akari.Geom.Batch(vertexCount: items.reduce(0) { $0 + $1.verts.count / 8 },
                                 indexCount: items.reduce(0) { $0 + $1.indices.count },
                                 largestVertexCount: largestVerts,
                                 largestIndexCount: largestIndices,
                                 expands: expands, instanced: instanced, ptexFaces: ptexFaces)
    batch.deferDraws()
    for item in items
    {
      if instanced
      {
        batch.appendInstanced(localVerts: item.verts, localIndices: item.indices,
                              worldMatrix: item.worldMatrix, normalMatrix: item.normalMatrix,
                              draws: item.instanceDraws,
                              primId: item.primId, key: casterKey(item), ptexFaces: item.ptexFaces)
      }
      else
      {
        item.worldMatrix.withUnsafeBufferPointer
        { buf in
          batch.append(localVerts: item.verts, localIndices: item.indices,
                       worldMatrix: buf.baseAddress!, normalMatrix: item.normalMatrix,
                       primId: item.primId, key: casterKey(item), ptexFaces: item.ptexFaces)
        }
      }
    }

    batch.draw()
    return (batch.flushes, BatchSummary(bounds: batch.worldBounds, casterBounds: batch.casterBounds, casterKeys: batch.casterKeys))
  }

  /// Records one chunk of a batch, its draw state only ahead of the first,
  /// so the capture stays a run of draws the indirect playback can replay.
  private func emit(_ flushes: [Akari.Geom.Batch.Flush], into capture: LabGLCaptureBuffer,
                    instanced: Bool, preamble: Bool, ptexFaces: Akari.Geom.PtexFaces?)
  {
    gl.bindTexture(target: GL_TEXTURE_2D, texture: 0)
    labgl.captureStart(capture)

    if preamble
    {
      gl.enable(GL_DEPTH_TEST)
      gl.depthFunc(GLenum(GL_GREATER))

      gl.disable(GL_CULL_FACE)
      gl.frontFace(GL_CCW)
    }

    for flush in flushes
    {
      Akari.Geom.Batch.record(flush, instanced: instanced, ptexFaces: ptexFaces)
    }

    labgl.captureStop()
  }
}
