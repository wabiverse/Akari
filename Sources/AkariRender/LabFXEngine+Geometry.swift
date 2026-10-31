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
  /// The scene split into meshes that have animated and the rest, each
  /// in its own capture, so animated frames only rerecord what moves.
  struct SceneGeometry
  {
    var staticCapture: LabGLCaptureBuffer?
    /// The static meshes unwelded, which the shadows and probes draw faster.
    var staticShadowCapture: LabGLCaptureBuffer?
    /// Too many static triangles to unweld them all, the shadows draw `staticCapture`.
    var staticShadowShared = false
    /// Static instanced prototypes, each drawn once per instance set.
    var staticInstancedCapture: LabGLCaptureBuffer?
    var dynamicCapture: LabGLCaptureBuffer?
    let staticRecorder = Akari.Geom.Recorder(keepsTopology: false)
    /// Keeps the instanced prototypes caches apart from the static meshes.
    let instancedRecorder = Akari.Geom.Recorder(keepsTopology: false)
    /// Lays the animated meshes out once and deforms them on the GPU per frame.
    let deformer = Akari.Geom.Deformer()

    /// Every visible mesh, by path key, kept current from the scene's drained changes.
    var meshes: [UInt64: Akari.Geom.Recorder.RawMesh] = [:]
    /// Instance sets by key, so the meshes of one prototype share one copy.
    var instanceSets: [UInt64: [Float]] = [:]
    /// Each cached mesh's prim id, to pick meshes out without copying them.
    var primIds: [UInt64: Int32] = [:]
    /// Per mesh, a key of its data and transform.
    var changes: [UInt64: UInt64] = [:]
    /// Meshes that changed after they first appeared. They stay dynamic, a pause
    /// demoting them would rerecord the static capture and rebuild them on the way back.
    var animated: Set<UInt64> = []
    /// Animated meshes the scene took away, kept laid out but not drawn.
    var hidden: Set<UInt64> = []
    /// Mesh key to the keys of its per instance fallback copies.
    var expansions: [UInt64: [UInt64]] = [:]
    /// Prims with stylized shading or assembly, drawn through the deformer for their per corner vertices.
    var styled: Set<Int32> = []
    /// Prims the transparency pass draws, always deformer drawn.
    var transparent: Set<Int32> = []
    var emitters: Set<Int32> = []
    var opacity: [Int32: Float] = [:]
    var restyled = false
    var records = 0
    var recordedAt = Date.distantPast
    /// The unique triangles the last record could hold.
    var recordBudget = 0
    /// What the static and instanced captures last recorded.
    var staticKey: UInt64 = 0
    var instancedKey: UInt64 = 0
    /// The unique triangles the static captures last recorded.
    var recordedTriangles = 0
    /// The view the static captures were last chosen for.
    var camera: RecordCamera?
    /// Simplified meshes by content and triangle count, kept while they're drawn.
    var details: [UInt64: Detail] = [:]
    /// The viewport's eye, and when it last moved, to choose again once it settles somewhere new.
    var lastEye = SIMD3<Float>(repeating: .nan)
    var lastForward = SIMD3<Float>(repeating: .nan)
    var eyeMoved = Date.distantPast
    var reframe = false

    var staticBatch = BatchSummary()
    var instancedBatch = BatchSummary()
    var dynamicBatch = BatchSummary()
    var cameraCull = CameraCull()
    /// The instanced capture's instances were culled to the camera this frame.
    var instancesCulled = false

    /// The non empty captures, static first.
    var captures: [LabGLCaptureBuffer]
    {
      [staticBatch.isEmpty ? nil : staticCapture,
       instancedBatch.isEmpty ? nil : staticInstancedCapture,
       dynamicBatch.isEmpty ? nil : dynamicCapture].compactMap(\.self)
    }

    var staticShadow: LabGLCaptureBuffer?
    {
      staticShadowShared ? staticCapture : staticShadowCapture
    }

    var shadowCaptures: [LabGLCaptureBuffer]
    {
      [staticBatch.isEmpty ? nil : staticShadow,
       instancedBatch.isEmpty ? nil : staticInstancedCapture,
       dynamicBatch.isEmpty ? nil : dynamicCapture].compactMap(\.self)
    }
  }

  /// The view the static captures are chosen for.
  struct RecordCamera
  {
    var planes: [SIMD4<Float>]
    var eye: SIMD3<Float>
    var pixelScale: Float
    /// The viewport's view, its half angle widened by `margin`.
    var forward: SIMD3<Float>
    var cone: Float
    static let margin: Float = 20 * .pi / 180

    init(view: Akari.Matrix4, projection: Akari.Matrix4, height: Int, frustum: Bool)
    {
      let m = (projection * view).simd
      func row(_ i: Int) -> SIMD4<Float>
      {
        SIMD4(m.columns.0[i], m.columns.1[i], m.columns.2[i], m.columns.3[i])
      }
      planes = !frustum ? [] : [row(3) + row(0), row(3) - row(0), row(3) + row(1), row(3) - row(1), row(3)].map
      {
        $0 / max(simd_length(SIMD3($0.x, $0.y, $0.z)), 1e-12)
      }
      eye = view.inverse().transform(.zero)
      pixelScale = abs(projection.simd.columns.1.y) * Float(max(height, 1)) / 2
      forward = simd_normalize(view.inverse().transform(SIMD3(0, 0, -1)) - eye)
      let tanX = 1 / max(abs(projection.simd.columns.0.x), 1e-6), tanY = 1 / max(abs(projection.simd.columns.1.y), 1e-6)
      cone = frustum ? .pi : min(atan((tanX * tanX + tanY * tanY).squareRoot()) + Self.margin, .pi)
    }

    /// The radius in pixels a sphere covers, zero when it's out of view or under half a pixel.
    func pixels(center: SIMD3<Float>, radius: Float) -> Float
    {
      for p in planes where simd_dot(SIMD3(p.x, p.y, p.z), center) + p.w < -radius
      {
        return 0
      }
      let distance = max(simd_distance(center, eye), 1e-4)
      var px = radius * pixelScale / distance
      if cone < .pi, acos(min(max(simd_dot(center - eye, forward) / distance, -1), 1)) - asin(min(radius / distance, 1)) > cone
      {
        px /= 3
      }
      return px < 0.5 ? 0 : px
    }
  }

  /// A mesh simplified to the screen it covers.
  struct Detail
  {
    var points: Pixar.VtVec3fArray
    var tris: Pixar.VtVec3iArray
    var uvs: Pixar.VtVec2fArray
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
      let staticShadowCapture = labgl.captureCreate(),
      let staticInstancedCapture = labgl.captureCreate(),
      let dynamicCapture = labgl.captureCreate()
    else { return false }

    geometry.staticCapture = staticCapture
    geometry.staticShadowCapture = staticShadowCapture
    geometry.staticInstancedCapture = staticInstancedCapture
    geometry.dynamicCapture = dynamicCapture
    runtime.setMeshCapture("mesh-static", buffer: staticCapture)
    let userdata = Unmanaged.passUnretained(self).toOpaque()
    runtime.setPassCallback("draw-dynamic-geometry", callback: akariDynamicGeometryCallback, userdata: userdata)
    runtime.setPassCallback("draw-static-instanced-geometry",
                            callback: akariStaticInstancedGeometryCallback, userdata: userdata)
    return true
  }

  func destroyCaptures()
  {
    for capture in [geometry.staticCapture, geometry.staticShadowCapture,
                    geometry.staticInstancedCapture, geometry.dynamicCapture].compactMap(\.self)
    {
      labgl.captureDestroy(capture)
    }
    geometry = SceneGeometry()
  }

  /// Deforms the dynamic meshes on the GPU, and rerecords
  /// the static ones only when which meshes are static changed.
  func recordCaptures(changed: [Akari.Geom.Recorder.RawMesh], removed: [UInt64])
  {
    guard
      let staticCapture = geometry.staticCapture,
      let dynamicCapture = geometry.dynamicCapture
    else { return }

    geometry.records += 1
    geometry.recordedAt = Date()
    var staticDirty = geometry.records == 1 || geometry.reframe
    geometry.reframe = false
    var dynamicDirty = geometry.deformer.relayout

    var removed = removed
    var changed = changed

    // a meshes old per instance fallbacks go with it whenever it
    // changes or leaves, the fresh copies if still needed, are
    // added below.
    for key in Array(removed)
    {
      if let copies = geometry.expansions.removeValue(forKey: key) { removed += copies }
    }
    for mesh in changed
    {
      if let copies = geometry.expansions.removeValue(forKey: mesh.key) { removed += copies }
    }

    // the deformer has no instance path, so an instanced mesh that is
    // transparent, styled, skinned or animated falls back to one raw
    // mesh per instance. the rest draw as one prototype with GPU
    // instancing.
    changed = changed.flatMap
    { mesh -> [Akari.Geom.Recorder.RawMesh] in
      guard !mesh.instances.isEmpty else { return [mesh] }
      let seen = geometry.changes[mesh.key]
      let animates = geometry.animated.contains(mesh.key)
        || (seen != nil && seen != Self.changeKey(mesh))
      let instancedFallback = mesh.transparent || mesh.skinInfluencesPerPoint > 0
        || geometry.styled.contains(mesh.primId) || animates
      guard instancedFallback else { return [mesh] }

      // the prototype itself must not also draw at its root transform.
      if geometry.meshes.removeValue(forKey: mesh.key) != nil
      {
        geometry.primIds[mesh.key] = nil
        geometry.changes[mesh.key] = nil
        if geometry.animated.remove(mesh.key) != nil { dynamicDirty = true }
        else { staticDirty = true }
      }
      let copies = Self.expandInstances(mesh)
      geometry.expansions[mesh.key] = copies.map(\.key)
      return copies
    }

    // a large flat transparent sheet is water, which the composite shades as a plane.
    if removed.contains(where: waterKeys.contains)
    {
      water = nil
      waterKeys.subtract(removed)
    }
    changed = changed.filter
    { mesh in
      guard mesh.transparent, let plane = waterPlane(mesh) else { return true }
      waterKeys.insert(mesh.key)
      // the most finely modeled sheet is the one by the shore, where its level shows.
      if let water
      {
        self.water = plane.detail > water.detail ? plane : water
        self.water?.lo = pointwiseMin(water.lo, plane.lo)
        self.water?.hi = pointwiseMax(water.hi, plane.hi)
      }
      else
      {
        water = plane
      }
      return false
    }

    // the transparency pass draws every triangle its given, which we can cheat for water.
    changed = changed.map
    { mesh in
      guard mesh.transparent, mesh.tris.size() > Self.maxTransparentTriangles else { return mesh }
      var points = Pixar.VtVec3fArray(), tris = Pixar.VtVec3iArray(), uvs = Pixar.VtVec2fArray()
      guard Pixar.HdAkariDecimate(mesh.points, mesh.tris, mesh.uvs, Self.maxTransparentTriangles,
                                  &points, &tris, &uvs) else { return mesh }
      var simplified = mesh
      simplified.points = points
      simplified.tris = tris
      simplified.uvs = uvs
      return simplified
    }

    for key in removed
    {
      if geometry.animated.contains(key), geometry.meshes[key] != nil
      {
        geometry.primIds[key] = nil
        if geometry.hidden.insert(key).inserted { dynamicDirty = true }
        continue
      }
      guard geometry.meshes.removeValue(forKey: key) != nil else { continue }
      geometry.primIds[key] = nil
      geometry.changes[key] = nil
      staticDirty = true
    }

    if geometry.restyled
    {
      geometry.restyled = false
      dynamicDirty = true
      for (key, mesh) in geometry.meshes where geometry.styled.contains(mesh.primId) && !geometry.animated.contains(key)
      {
        geometry.animated.insert(key)
        staticDirty = true
      }
    }

    for mesh in changed
    {
      if mesh.transparent { geometry.transparent.insert(mesh.primId) } else { geometry.transparent.remove(mesh.primId) }
      if mesh.emitter { geometry.emitters.insert(mesh.primId) } else { geometry.emitters.remove(mesh.primId) }
      geometry.opacity[mesh.primId] = mesh.transparent ? mesh.opacity : nil
      let key = Self.changeKey(mesh)
      let isNew = geometry.meshes.updateValue(mesh, forKey: mesh.key) == nil
      if geometry.hidden.remove(mesh.key) != nil { dynamicDirty = true }
      geometry.primIds[mesh.key] = mesh.primId
      let last = geometry.changes.updateValue(key, forKey: mesh.key)
      if geometry.animated.contains(mesh.key)
      {
        dynamicDirty = true
      }
      else if mesh.skinInfluencesPerPoint > 0 || geometry.styled.contains(mesh.primId) || mesh.transparent
      {
        // GPU skinned meshes only ever exist deformed.
        geometry.animated.insert(mesh.key)
        dynamicDirty = true
        if !isNew { staticDirty = true }
      }
      else if isNew
      {
        // new meshes start static, so loading
        // a scene isn't one long animation.
        staticDirty = true
      }
      else if last != key
      {
        geometry.animated.insert(mesh.key)
        staticDirty = true
        dynamicDirty = true
      }
    }

    if staticDirty
    {
      let staticMeshes = geometry.meshes.values.filter { !geometry.animated.contains($0.key) }
      let (unique, duplicates) = Self.instanceDuplicates(staticMeshes.filter(\.instances.isEmpty))
      let budget = uniqueTriangleBudget()
      geometry.recordBudget = budget.regular + budget.prototypes
      let camera = geometry.camera
      let screen = unique.map { Self.screenPixels($0, camera: camera) }
      let regular = Self.budgetGeometry(unique, budget: budget.regular, area: screen)
      var details: [UInt64: Detail] = [:]
      let regularMeshes = Self.applyDetail(regular, cache: geometry.details, into: &details)
      let instancedPrototypes = staticMeshes.filter { !$0.instances.isEmpty } + duplicates
      let binned = Self.binInstances(instancedPrototypes, budget: budget.prototypes, camera: camera)
      let instancedMeshes = Self.applyDetail(binned, cache: geometry.details, into: &details)
      geometry.details = details
      geometry.recordedTriangles = (regularMeshes + instancedMeshes).reduce(0) { $0 + $1.tris.size() }
      let inUse = Set(geometry.meshes.values.map(\.instancesKey))
      geometry.instanceSets = geometry.instanceSets.filter { inUse.contains($0.key) }

      // the camera moving on rarely changes what's chosen, a capture choosing the same isn't rebuilt.
      let staticKey = Self.recordKey(regularMeshes), instancedKey = Self.recordKey(instancedMeshes)
      var recordsStatic = staticKey != geometry.staticKey
      var recordsInstanced = instancedKey != geometry.instancedKey || geometry.staticInstancedCapture == nil
      // the face table only grows while one capture rebuilds alone, both rebuilding start it over.
      if recordsStatic != recordsInstanced, ptex.faces.count > 4 * (geometry.recordedTriangles + 1)
      {
        recordsStatic = true
        recordsInstanced = true
      }
      if recordsStatic && recordsInstanced { ptex.faces.reset() }
      if recordsStatic || recordsInstanced { Akari.Geom.GeometryCache.shared.beginRecord() }
      if recordsStatic
      {
        geometry.staticKey = staticKey
        geometry.staticShadowShared = geometry.recordedTriangles > Self.unweldedShadowTriangles
        if geometry.staticShadowShared, let shadow = geometry.staticShadowCapture { labgl.captureClear(shadow) }
        geometry.staticBatch = recordBatch(regularMeshes, into: staticCapture,
                                           expandedInto: geometry.staticShadowShared ? nil : geometry.staticShadowCapture,
                                           recorder: geometry.staticRecorder)
      }
      if recordsInstanced, let capture = geometry.staticInstancedCapture
      {
        geometry.instancedKey = instancedKey
        geometry.instancedBatch = recordBatch(instancedMeshes, into: capture,
                                              recorder: geometry.instancedRecorder,
                                              instanced: true)
      }
    }
    if !dynamicDirty
    {
      geometry.deformer.settle()
    }
    else
    {
      let dynamicMeshes = geometry.animated.compactMap { geometry.meshes[$0] }
      let shownMeshes = geometry.hidden.isEmpty ? dynamicMeshes : dynamicMeshes.filter { !geometry.hidden.contains($0.key) }
      if geometry.deformer.needsRebuild(dynamicMeshes)
      {
        geometry.deformer.rebuild(dynamicMeshes, into: dynamicCapture)
      }
      let deformed = geometry.deformer.update(shownMeshes)
      geometry.dynamicBatch = BatchSummary(bounds: deformed.bounds, casterBounds: deformed.casterBounds,
                                           casterKeys: deformed.casterKeys)
    }

    let batches = [geometry.staticBatch, geometry.instancedBatch, geometry.dynamicBatch]
    var bounds: (min: SIMD3<Float>, max: SIMD3<Float>)?
    for next in batches.compactMap(\.bounds)
    {
      bounds = bounds.map { (min: pointwiseMin($0.min, next.min), max: pointwiseMax($0.max, next.max)) } ?? next
    }
    // building and simplifying leave gigabytes of freed scratch the allocator would otherwise keep.
    malloc_zone_pressure_relief(nil, 0)
    sceneBounds = bounds
    casterBounds = batches.flatMap(\.casterBounds)
    casterKeys = batches.flatMap(\.casterKeys)
  }

  func recordBatch(_ meshes: [Akari.Geom.Recorder.RawMesh],
                   into capture: LabGLCaptureBuffer,
                   expandedInto expanded: LabGLCaptureBuffer? = nil,
                   recorder: Akari.Geom.Recorder,
                   reusing others: [Akari.Geom.Recorder] = [],
                   instanced: Bool = false) -> BatchSummary
  {
    labgl.captureClear(capture)
    if let expanded { labgl.captureClear(expanded) }
    // instanced prototypes sharing a set sit next to each other, so their draws merge into one per run of the set.
    let keyed: [(mesh: Akari.Geom.Recorder.RawMesh, set: UInt64, morton: UInt64)] = meshes.map
    { mesh in
      (mesh, instanced ? mesh.instanceDraws.first?.key ?? 0 : 0, Self.mortonKey(mesh))
    }
    let sorted = keyed.sorted { $0.set != $1.set ? $0.set < $1.set : $0.morton < $1.morton }.map(\.mesh)
    var summary = BatchSummary()
    var preamble = true
    recorder.record(sorted, reusing: others)
    { items in
      // instanced captures keep the prototypes object space vertices, the matrices move them, so they can't be unwelded like the static ones.
      if let expanded { _ = record(items, into: expanded, expands: !instanced, instanced: instanced, preamble: preamble) }
      let chunk = record(items, into: capture, expands: false, instanced: instanced, preamble: preamble, ptexFaces: ptex.faces)
      preamble = false
      if let next = chunk.bounds
      {
        summary.bounds = summary.bounds.map { (min: pointwiseMin($0.min, next.min), max: pointwiseMax($0.max, next.max)) } ?? next
      }
      summary.casterBounds += chunk.casterBounds
      summary.casterKeys += chunk.casterKeys
    }
    return summary
  }

  /// Records one chunk of a batch, its draw state only ahead of the first,
  /// so the capture stays a run of draws the indirect playback can replay.
  private func record(_ items: [Akari.Geom.Recorder.Item], into capture: LabGLCaptureBuffer,
                      expands: Bool, instanced: Bool = false, preamble: Bool = true,
                      ptexFaces: Akari.Geom.PtexFaces? = nil) -> BatchSummary
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

    let largestVerts = items.reduce(0) { max($0, expands ? $1.indices.count : $1.verts.count / 8) }
    let largestIndices = items.reduce(0) { max($0, $1.indices.count) }
    let batch = Akari.Geom.Batch(vertexCount: items.reduce(0) { $0 + $1.verts.count / 8 },
                                 indexCount: items.reduce(0) { $0 + $1.indices.count },
                                 largestVertexCount: largestVerts,
                                 largestIndexCount: largestIndices,
                                 expands: expands, instanced: instanced, ptexFaces: ptexFaces)
    for item in items
    {
      if instanced
      {
        batch.appendInstanced(localVerts: item.verts, localIndices: item.indices,
                              worldMatrix: item.worldMatrix, normalMatrix: item.normalMatrix,
                              draws: item.instanceDraws,
                              primId: item.primId, key: Self.casterKey(item), ptexFaces: item.ptexFaces)
      }
      else
      {
        item.worldMatrix.withUnsafeBufferPointer
        { buf in
          batch.append(localVerts: item.verts, localIndices: item.indices,
                       worldMatrix: buf.baseAddress!, normalMatrix: item.normalMatrix,
                       primId: item.primId, key: Self.casterKey(item), ptexFaces: item.ptexFaces)
        }
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

  fileprivate func drawStaticInstancedGeometry()
  {
    guard !geometry.instancedBatch.isEmpty, let capture = geometry.staticInstancedCapture else { return }
    if geometry.instancesCulled { labgl.capturePlaybackInstancesCulled(capture, slot: 0) }
    else { labgl.capturePlayback(capture) }
  }

  /// Changes whenever the item moves or deforms, for the shadows' moved caster test.
  private static func casterKey(_ item: Akari.Geom.Recorder.Item) -> UInt64
  {
    var key = (14_695_981_039_346_656_037 ^ item.dataRevision) &* 1_099_511_628_211
    for value in item.worldMatrix
    {
      key = (key ^ UInt64(value.bitPattern)) &* 1_099_511_628_211
    }
    for draw in item.instanceDraws
    {
      key = (key ^ draw.key) &* 1_099_511_628_211
      key = (key ^ UInt64(draw.count)) &* 1_099_511_628_211
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
    mix(mesh.instancesKey)
    return key
  }

  /// Merges instanced prototypes whose object space geometry, material and
  /// own transform hash the same into one prototype, drawn once per each
  /// instance set.
  private static func binInstances(_ meshes: [Akari.Geom.Recorder.RawMesh], budget: Int,
                                   camera: RecordCamera?)
    -> [(mesh: Akari.Geom.Recorder.RawMesh, triangles: Int)]
  {
    var slots: [UInt64: Int] = [:]
    var binned: [Akari.Geom.Recorder.RawMesh] = []
    for mesh in meshes.sorted(by: { $0.key < $1.key })
    {
      let draw = Akari.Geom.Recorder.InstanceDraw(key: mesh.instancesKey, transforms: mesh.instances,
                                                  count: mesh.instances.count / 16, livePrototype: mesh.livePrototype)
      let key = mesh.contentKey == 0 ? mesh.key : geometryKey(mesh)
      if let slot = slots[key]
      {
        if !binned[slot].instanceDraws.contains(where: { $0.key == draw.key }) { binned[slot].instanceDraws.append(draw) }
        continue
      }
      var prototype = mesh
      if mesh.contentKey != 0
      {
        // named by its content, so its cached build survives whichever mesh represents it.
        prototype.id = "content:\(key)"
        prototype.dataRevision = key
        prototype.topologyRevision = key
      }
      prototype.instanceDraws = [draw]
      slots[key] = binned.count
      binned.append(prototype)
    }
    guard let camera
    else
    {
      return budgetInstances(budgetGeometry(binned, budget: budget, area: binned.map { screenPixels($0, camera: nil) }))
    }
    let (visible, area) = cullInstances(binned, camera: camera)
    return budgetInstances(budgetGeometry(visible, budget: budget, area: area))
  }

  /// A meshes bounding sphere, under its own transform.
  private static func boundingSphere(_ mesh: Akari.Geom.Recorder.RawMesh) -> (center: SIMD3<Float>, radius: Float)
  {
    var b = [Float](repeating: 0, count: 6)
    b.withUnsafeMutableBufferPointer { Pixar.HdAkariPointsBounds(mesh.points, $0.baseAddress!) }
    let m = mesh.worldMatrix
    let local = SIMD3(b[0] + b[3], b[1] + b[4], b[2] + b[5]) * 0.5
    let center = SIMD3(m[0] * local.x + m[4] * local.y + m[8] * local.z + m[12],
                       m[1] * local.x + m[5] * local.y + m[9] * local.z + m[13],
                       m[2] * local.x + m[6] * local.y + m[10] * local.z + m[14])
    return (center, simd_length(SIMD3(b[3] - b[0], b[4] - b[1], b[5] - b[2])) * 0.5 * maxScale(m, 0))
  }

  private static func maxScale(_ m: [Float], _ o: Int) -> Float
  {
    max((m[o] * m[o] + m[o + 1] * m[o + 1] + m[o + 2] * m[o + 2]).squareRoot(),
        (m[o + 4] * m[o + 4] + m[o + 5] * m[o + 5] + m[o + 6] * m[o + 6]).squareRoot(),
        (m[o + 8] * m[o + 8] + m[o + 9] * m[o + 9] + m[o + 10] * m[o + 10]).squareRoot())
  }

  /// The screen a mesh drawn once covers, in pixels, and the most of it any one instance does,
  /// without a camera its size and no level of detail.
  private static func screenPixels(_ mesh: Akari.Geom.Recorder.RawMesh, camera: RecordCamera?)
    -> (total: Double, largest: Double?)
  {
    let sphere = boundingSphere(mesh)
    guard let camera else { return (Double(sphere.radius * sphere.radius), nil) }
    let px = Double(camera.pixels(center: sphere.center, radius: sphere.radius))
    return (Double.pi * px * px, Double.pi * px * px)
  }

  /// Keeps each set's instances the camera sees, largest on screen first, against a sphere around
  /// every prototype drawn with it, so a draw that takes only part of a set keeps what matters most.
  /// Each prototype is worth the screen its set covers, scaled to its own size, per triangle.
  private static func cullInstances(_ meshes: [Akari.Geom.Recorder.RawMesh], camera: RecordCamera)
    -> (meshes: [Akari.Geom.Recorder.RawMesh], area: [(total: Double, largest: Double?)])
  {
    let spheres = meshes.map(boundingSphere)
    var bounds: [UInt64: (lo: SIMD3<Float>, hi: SIMD3<Float>)] = [:]
    var transforms: [UInt64: [Float]] = [:]
    for (mesh, sphere) in zip(meshes, spheres)
    {
      for draw in mesh.instanceDraws where draw.livePrototype == nil
      {
        let lo = sphere.center - sphere.radius, hi = sphere.center + sphere.radius
        let entry = bounds[draw.key] ?? (lo, hi)
        bounds[draw.key] = (simd_min(entry.lo, lo), simd_max(entry.hi, hi))
        transforms[draw.key] = draw.transforms
      }
    }

    var culled: [UInt64: Akari.Geom.Recorder.InstanceDraw] = [:]
    var area: [UInt64: (pixels: Double, largest: Double, radius: Float)] = [:]
    for (key, box) in bounds
    {
      guard let xf = transforms[key] else { continue }
      let center = (box.lo + box.hi) * 0.5, radius = simd_length(box.hi - box.lo) * 0.5
      var seen: [(index: Int, pixels: Float)] = []
      for i in 0 ..< xf.count / 16
      {
        let o = i * 16
        let c = SIMD3(xf[o] * center.x + xf[o + 4] * center.y + xf[o + 8] * center.z + xf[o + 12],
                      xf[o + 1] * center.x + xf[o + 5] * center.y + xf[o + 9] * center.z + xf[o + 13],
                      xf[o + 2] * center.x + xf[o + 6] * center.y + xf[o + 10] * center.z + xf[o + 14])
        let px = camera.pixels(center: c, radius: radius * maxScale(xf, o))
        if px > 0 { seen.append((i, px)) }
      }
      guard !seen.isEmpty else { continue }
      seen.sort { $0.pixels > $1.pixels }
      var kept = [Float](repeating: 0, count: seen.count * 16)
      for (slot, instance) in seen.enumerated()
      {
        for k in 0 ..< 16
        {
          kept[slot * 16 + k] = xf[instance.index * 16 + k]
        }
      }
      culled[key] = Akari.Geom.Recorder.InstanceDraw(key: (key ^ 0x9E37_79B9_7F4A_7C15) &* 1_099_511_628_211,
                                                     transforms: kept, count: seen.count)
      area[key] = (seen.reduce(0) { $0 + Double.pi * Double($1.pixels * $1.pixels) },
                   Double.pi * Double(seen[0].pixels * seen[0].pixels), radius)
    }

    var visible: [Akari.Geom.Recorder.RawMesh] = []
    var screen: [(total: Double, largest: Double?)] = []
    for (mesh, sphere) in zip(meshes, spheres)
    {
      var mesh = mesh
      var total = 0.0, largest = 0.0
      mesh.instanceDraws = mesh.instanceDraws.compactMap
      { draw in
        if draw.livePrototype != nil
        {
          total = .greatestFiniteMagnitude
          largest = .greatestFiniteMagnitude
          return draw
        }
        guard
          let kept = culled[draw.key],
          let covered = area[draw.key]
        else { return nil }
        
        let share = Double(sphere.radius / max(covered.radius, 1e-6))
        total += covered.pixels * share * share
        largest = max(largest, covered.largest * share * share)
        return kept
      }
      guard !mesh.instanceDraws.isEmpty else { continue }
      visible.append(mesh)
      screen.append((total, largest))
    }
    return (visible, screen)
  }

  /// A prototype's content and the transform its vertices are recorded under.
  private static func geometryKey(_ mesh: Akari.Geom.Recorder.RawMesh) -> UInt64
  {
    var key = mesh.contentKey
    for value in mesh.worldMatrix
    {
      key = (key ^ UInt64(value.bitPattern)) &* 1_099_511_628_211
    }
    return (key ^ (mesh.flipWinding ? 1 : 0)) &* 1_099_511_628_211
  }

  private static func hashFloats(_ values: [Float]) -> UInt64
  {
    var key: UInt64 = 14_695_981_039_346_656_037
    for value in values
    {
      key = (key ^ UInt64(value.bitPattern)) &* 1_099_511_628_211
    }
    return key
  }

  private static func environmentBudget(_ name: String, _ fallback: Int) -> Int
  {
    if let value = ProcessInfo.processInfo.environment[name], let budget = Int(value), budget > 0
    {
      return budget
    }
    return fallback
  }

  /// The unique triangles this machine can hold, at about 150 bytes each
  /// once built, uploaded and drawn, against 65% of its memory less what
  /// the process already holds besides the geometry recorded last time,
  /// and the size the frame itself takes after recording.
  ///
  /// Where buffers map files the triangles live on the disk instead, held
  /// only to what it can fit, and on a discrete GPU to its memory.
  private func uniqueTriangleBudget() -> (regular: Int, prototypes: Int)
  {
    var gpuBudget: UInt64 = 0, gpuAllocated: UInt64 = 0
    gl.gpuMemory(budget: &gpuBudget, allocated: &gpuAllocated)
    let mapsFiles = gl.buffersMapFiles() != 0
    if mapsFiles, let disk = Akari.Geom.GeometryCache.shared.freeDisk
    {
      return split(Int(disk) / 256 + geometry.recordedTriangles)
    }
    if !mapsFiles, gpuBudget > 0
    {
      return split((Int(gpuBudget) * 9 / 10 - Int(gpuAllocated)) / 150 + geometry.recordedTriangles)
    }
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
    return split((target - footprint) / 150 + geometry.recordedTriangles)
  }

  /// Order independent, a reframe ranks the same meshes differently.
  private static func recordKey(_ meshes: [Akari.Geom.Recorder.RawMesh]) -> UInt64
  {
    meshes.reduce(UInt64(meshes.count))
    { sum, mesh in
      var key: UInt64 = 14_695_981_039_346_656_037
      let values = [mesh.key, mesh.dataRevision, UInt64(mesh.tris.size()), mesh.instancesKey]
        + mesh.instanceDraws.flatMap { [$0.key, UInt64($0.count)] }
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
    return Double(budget.regular + budget.prototypes) > Double(geometry.recordBudget) * 1.25
  }

  /// The most triangles the instanced draws rasterize a frame,
  /// each draw taking an even sample of its set when they'd
  /// exceed it.
  private static var drawnTriangleBudget: Int
  {
    environmentBudget("AKARI_DRAWN_TRIANGLE_BUDGET", 32_000_000)
  }

  /// Recorded triangles past which the shadows stop drawing an
  /// unwelded copy of the static meshes.
  private static var unweldedShadowTriangles: Int
  {
    environmentBudget("AKARI_UNWELDED_SHADOW_TRIANGLES", 1_000_000)
  }

  /// The most triangles one transparent mesh brings to the transparency pass.
  private static let maxTransparentTriangles = 524_288

  /// Triangles a set of identical static meshes would duplicate before they draw as instances.
  private static var duplicateTriangles: Int
  {
    environmentBudget("AKARI_DUPLICATE_TRIANGLES", 262_144)
  }

  /// One triangle per this many pixels a mesh covers is as fine as the screen shows it.
  private static let pixelsPerTriangle = 2.0
  /// The coarse level a large shape keeps first, enough for its silhouette, and how much
  /// screen it covers to be one.
  private static let silhouettePixelsPerTriangle = 16.0
  private static let silhouetteMinimumPixels = 16384.0

  /// Every large shape in view first gets the coarse level its outline needs, what's left
  /// of `budget` then goes to the meshes covering the most screen per triangle, as many as
  /// the screen shows. Levels are powers of two, so they're reused. Ties go to the stable
  /// path hash, so the same scene records the same subset.
  private static func budgetGeometry(_ meshes: [Akari.Geom.Recorder.RawMesh], budget: Int,
                                     area: [(total: Double, largest: Double?)])
    -> [(mesh: Akari.Geom.Recorder.RawMesh, triangles: Int)]
  {
    func level(_ mesh: Akari.Geom.Recorder.RawMesh, _ area: (total: Double, largest: Double?), _ pixels: Double) -> Int
    {
      let full = mesh.tris.size()
      guard let largest = area.largest, mesh.uvs.size() <= 1 || mesh.uvs.size() == full * 3 else { return full }
      let wanted = max(64, Int(min(largest / pixels, Double(Int32.max))))
      return min(full, 1 << (Int.bitWidth - (wanted - 1).leadingZeroBitCount))
    }
    let triangles = zip(meshes, area).map { level($0, $1, pixelsPerTriangle) }
    let silhouettes = zip(meshes, area).map
    { mesh, area in
      let once = mesh.instanceDraws.reduce(0) { $0 + $1.count } <= 1
      return once && (area.largest ?? 0) >= silhouetteMinimumPixels ? level(mesh, area, silhouettePixelsPerTriangle) : 0
    }
    let ranked = meshes.indices.sorted
    { lhs, rhs in
      let left = area[lhs].total / Double(max(triangles[lhs], 1))
      let right = area[rhs].total / Double(max(triangles[rhs], 1))
      return left != right ? left > right : meshes[lhs].key < meshes[rhs].key
    }

    var chosen = [Int](repeating: 0, count: meshes.count)
    var keptTriangles = 0
    for index in ranked where keptTriangles + silhouettes[index] <= budget
    {
      chosen[index] = silhouettes[index]
      keptTriangles += silhouettes[index]
    }
    for index in ranked where keptTriangles + triangles[index] - chosen[index] <= budget
    {
      keptTriangles += triangles[index] - chosen[index]
      chosen[index] = triangles[index]
    }
    return ranked.filter { chosen[$0] > 0 }.map { (meshes[$0], chosen[$0]) }
  }

  /// Simplifies each mesh to its triangle count, reusing what `cache`
  /// holds, in parallel, and gathers every level drawn into `details`.
  private static func applyDetail(_ meshes: [(mesh: Akari.Geom.Recorder.RawMesh, triangles: Int)],
                                  cache: [UInt64: Detail], into details: inout [UInt64: Detail])
    -> [Akari.Geom.Recorder.RawMesh]
  {
    func detailKey(_ mesh: Akari.Geom.Recorder.RawMesh, _ triangles: Int) -> UInt64
    {
      ((mesh.contentKey == 0 ? mesh.key : mesh.contentKey) ^ UInt64(triangles)) &* 1_099_511_628_211
    }
    // a simplified meshes triangles arent its faces, it draws in its map's average color.
    let meshes = meshes.map
    { entry -> (mesh: Akari.Geom.Recorder.RawMesh, triangles: Int) in
      guard entry.triangles < entry.mesh.tris.size(), !entry.mesh.triangleFaces.empty() else { return entry }
      var mesh = entry.mesh
      mesh.triangleFaces = Pixar.VtIntArray()
      mesh.faceRes = Pixar.VtIntArray()
      return (mesh, entry.triangles)
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
        if Pixar.HdAkariDecimate(entry.mesh.points, entry.mesh.tris, entry.mesh.uvs, entry.triangles,
                                 &points, &tris, &uvs)
        {
          box.buffer[i] = Detail(points: points, tris: tris, uvs: uvs)
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

  /// Trims every instance set to the largest triangle count per set that keeps the frame within
  /// `drawnTriangleBudget`, each keeping at least one instance. A set's draws share its count,
  /// so every part of a prototype drawn from it comes and goes together, and the sets order makes
  /// the instances kept an even sample.
  private static func budgetInstances(_ meshes: [(mesh: Akari.Geom.Recorder.RawMesh, triangles: Int)])
    -> [(mesh: Akari.Geom.Recorder.RawMesh, triangles: Int)]
  {
    var sets: [UInt64: (triangles: Int, count: Int)] = [:]
    for (mesh, triangles) in meshes
    {
      for draw in mesh.instanceDraws
      {
        let entry = sets[draw.key] ?? (0, draw.count)
        sets[draw.key] = (entry.triangles + max(triangles, 1), entry.count)
      }
    }
    let budget = drawnTriangleBudget
    let total = sets.values.reduce(0) { $0 + $1.triangles * $1.count }
    guard total > budget else { return meshes }

    func drawn(_ cap: Int) -> Int
    {
      sets.values.reduce(0) { $0 + $1.triangles * min($1.count, max(1, cap / $1.triangles)) }
    }
    var lo = 0, hi = sets.values.reduce(0) { max($0, $1.triangles * $1.count) }
    while lo < hi
    {
      let mid = (lo + hi + 1) / 2
      if drawn(mid) <= budget { lo = mid } else { hi = mid - 1 }
    }
    let counts = sets.mapValues { min($0.count, max(1, lo / $0.triangles)) }
    return meshes.map
    { entry in
      var mesh = entry.mesh
      for d in mesh.instanceDraws.indices
      {
        mesh.instanceDraws[d].count = counts[mesh.instanceDraws[d].key] ?? mesh.instanceDraws[d].count
      }
      return (mesh, entry.triangles)
    }
  }

  /// Splits off sets of identical static meshes, the same content under different transforms,
  /// heavy enough to be worth drawing as one instanced prototype, recorded once in object space,
  /// each copy's transform an instance. Instances share their prototype's prim id, so picking one
  /// reports the first.
  private static func instanceDuplicates(_ meshes: [Akari.Geom.Recorder.RawMesh]) -> (regular: [Akari.Geom.Recorder.RawMesh], instanced: [Akari.Geom.Recorder.RawMesh])
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
      prototype.instances = sorted.flatMap { meshes[$0].worldMatrix }
      prototype.instancesKey = hashFloats(prototype.instances)
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
  private static func mortonKey(_ mesh: Akari.Geom.Recorder.RawMesh) -> UInt64
  {
    if let draw = mesh.instanceDraws.first, draw.transforms.count >= 16
    {
      return mortonKey(Array(draw.transforms[0 ..< 16]))
    }
    return mortonKey(mesh.worldMatrix)
  }

  /// Morton code of a matrix's translation.
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

/// `Runtime.setPassCallback` takes a plain C function pointer.
private func akariStaticInstancedGeometryCallback(_ userdata: UnsafeMutableRawPointer?, _: Int32, _: Int32)
{
  guard let userdata else { return }
  Unmanaged<Akari.LabFXEngine>.fromOpaque(userdata).takeUnretainedValue().drawStaticInstancedGeometry()
}
