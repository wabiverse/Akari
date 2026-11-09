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
  /// Rerecords the synced meshes that changed into the captures, the
  /// selected ones into the outline's, and sets the per frame view
  /// matrix (LabGL's geometry stage).
  public func recordGeometry(renderParam: Pixar.HdAkariRenderParam,
                             view: Akari.Matrix4,
                             projection: Akari.Matrix4,
                             unjitteredProjection: Akari.Matrix4,
                             selection: Akari.Selection?,
                             planetCloudMarchSteps: Int)
  {
    guard
      geometry.staticCapture != nil,
      let scene = renderParam.GetScene()
    else { return }

    updateOutline(selection, projection: unjitteredProjection, sceneProjection: projection)
    loadCamera(view: view, projection: projection)
    bindMaterialAtlas(renderParam)

    let eye = view.inverse().transform(.zero)
    syncEnvironment(scene, view: view, eye: eye, cloudMarchSteps: planetCloudMarchSteps)
    syncPointLights(scene, eye: eye)

    geometry.record.restyled = syncStyles(scene) || geometry.record.restyled
    geometry.deformer.eye = eye
    geometry.deformer.zUp = stageIsZUp
    updateReframe(view: view, projection: unjitteredProjection, eye: eye)
    // a viewport's first record waits for its size to settle, so it isn't chosen for a few pixels first.
    if loadsInBackground, geometry.record.count == 0, Date().timeIntervalSince(geometry.view.resized) < 0.15 { return }

    let (changed, removed) = drainMeshChanges(scene)
    lastGeometryRevision = scene.Revision()
    if !changed.isEmpty || !removed.isEmpty || geometry.record.count == 0 || geometry.record.restyled || geometry.view.reframe
      || geometry.view.reframing != nil
    {
      recordCaptures(changed: changed, removed: removed,
                     camera: RecordCamera(view: view, projection: unjitteredProjection, height: sizes.target.height,
                                          frustum: !loadsInBackground))
    }
    else
    {
      geometry.deformer.settle()
    }
    // the shadow maps cache static pages, so the flags meshes just brought have to be up before they're drawn.
    if geometry.flags.emitters != styles.emitters ||
       geometry.flags.transparent != styles.transparent ||
       geometry.flags.opacity != styles.opacity ||
       geometry.flags.solidShadow != styles.solidShadow
    {
      geometry.record.restyled = syncStyles(scene) || geometry.record.restyled
    }

    recordOutline(changed: changed, removed: removed)
  }

  private func loadCamera(view: Akari.Matrix4, projection: Akari.Matrix4)
  {
    gl.matrixMode(GL_PROJECTION)
    gl.loadMatrix(Akari.Matrix4.reversedDepth(projection).m)
    gl.matrixMode(GL_MODELVIEW)
    gl.loadMatrix(view.m)

    runtime.setViewMatrix(view.m)
  }

  /// Binds the shared roughness, metallic, opacity, color, normal and emissive atlases.
  private func bindMaterialAtlas(_ renderParam: Pixar.HdAkariRenderParam)
  {
    if let atlas = renderParam.GetTextureAtlas()
    {
      let (materialTex, colorTex, normalTex, emissiveTex) = materialAtlas.uploadIfNeeded(atlas)
      setSampler(.materialAtlas, materialTex)
      setSampler(.colorAtlas, colorTex)
      setSampler(.normalAtlas, normalTex)
      setSampler(.emissiveAtlas, emissiveTex)
      let constantsTex = materialAtlas.uploadConstants(atlas)
      setSampler(.materialConstants, constantsTex)
      probes.materials = (materialTex, colorTex, emissiveTex, constantsTex)
    }
  }

  /// The stage's dome, sun, atmosphere and volumes.
  private func syncEnvironment(_ scene: Pixar.HdAkariScene, view: Akari.Matrix4, eye: SIMD3<Float>, cloudMarchSteps: Int)
  {
    syncDome(scene)
    syncDistant(scene)

    setMatrix(.eyeToWorld, view.inverse())
    syncAtmosphere(scene, eye: eye, cloudMarchSteps: cloudMarchSteps)
    syncVolumes(scene)
  }

  /// Ranks the scene's lights by how much they light the view, hands the leaders the shadow slots
  /// and the main shadow maps, and keeps the rest as unshadowed point lights.
  private func syncPointLights(_ scene: Pixar.HdAkariScene, eye: SIMD3<Float>)
  {
    let snapshot = scene.LightSnapshot().filter { Pixar.HdAkariPathKey($0.id) != environment.rectSunKey }
    let domeSun = dome.flatMap { dome in dome.sun.map { ($0.irradiance * dome.color).max() } }
    let sunFloor = (environment.distantSun?.irradiance.max() ?? domeSun ?? 0) * 0.05
    let keys = snapshot.map { Pixar.HdAkariPathKey($0.id) }
    var lights = snapshot.map { pointLight($0, sunFloor: sunFloor) }
    trackMovedLights(keys: keys, lights: &lights)

    // the ones that light the view the most, by their irradiance at the camera
    // or at the animated geometry, whichever they light more.
    let subject = geometry.dynamicBatch.bounds.map { ($0.min + $0.max) * 0.5 }
    func irradiance(_ light: Akari.Lux.PointLight, at point: SIMD3<Float>) -> Float
    {
      let d = light.position - point
      let r2 = light.radius * light.radius
      return light.intensity * light.color.max() * r2 / max((d * d).sum(), r2)
    }

    func weight(_ light: Akari.Lux.PointLight) -> Float
    {
      max(irradiance(light, at: eye), subject.map { irradiance(light, at: $0) } ?? 0)
    }

    let heroes = heroLights(snapshot, keys: keys, lights: lights)
    let sorted = lights.indices.sorted
    {
      heroes.contains(keys[$0]) != heroes.contains(keys[$1]) ? heroes.contains(keys[$0]) : weight(lights[$0]) > weight(lights[$1])
    }

    // practicals (LEDs and the like) sit in their own fixture, so only lights
    // reaching past a meter cast shadows, and those take the first slots.
    let minShadowReach = 1 / stageMetersPerUnit
    let wanted = Set(sorted.filter { lights[$0].reach >= minShadowReach }
      .prefix(Akari.ShadowAtlas.maxPunctualLights).map { keys[$0] })
    let slots = assignShadowSlots(wanted, by: sorted.map { keys[$0] })
    let index = Dictionary(keys.indices.map { (keys[$0], $0) }, uniquingKeysWith: { first, _ in first })
    var weights: [LightKey: Float] = [:]
    for key in slots
    {
      if let i = index[key] { weights[key] = pointLights.importance[key] ?? weight(lights[i]) * Float(Self.importanceSamples) }
    }

    assignMainShadows(slots, weights: weights, heroes: heroes)
    pointLights.shadowed = slots.compactMap { index[$0].map { lights[$0] } }
    pointLights.lit = Array((pointLights.shadowed + sorted.filter { !wanted.contains(keys[$0]) }.map { lights[$0] })
      .prefix(Self.maxPointLights))
  }

  private func pointLight(_ light: Pixar.HdAkariLightData, sunFloor: Float) -> Akari.Lux.PointLight
  {
    let mat = Pixar.GfMatrix4f(light.transform)
    let (position, xAxis, yAxis): (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) = if let mPtr = mat.GetArray()
    {
      (SIMD3(mPtr[12], mPtr[13], mPtr[14]), SIMD3(mPtr[0], mPtr[1], mPtr[2]), SIMD3(mPtr[4], mPtr[5], mPtr[6]))
    }
    else
    {
      (.zero, .zero, .zero)
    }

    var point = Akari.Lux.PointLight(position: position,
                                     color: SIMD3(light.colorR, light.colorG, light.colorB),
                                     intensity: light.intensity * exp2(light.exposure),
                                     radius: light.radius,
                                     diffuse: light.diffuse,
                                     specular: light.specular,
                                     halfAxis: xAxis * light.length * 0.5,
                                     tubeRadius: light.tubeRadius)
    point.halfWidth = xAxis * light.width * 0.5
    point.halfHeight = yAxis * light.height * 0.5
    point.cameraVisible = light.cameraVisible
    point.probes = light.probes && light.tubeRadius <= 0
    // under a sun a lamp's shadow fades out where it gives 1/20th of the sun's light.
    point.shadowFloor = max(1e-3, sunFloor)
    return point
  }

  /// Remembers which lights have moved and how far since the last sync.
  private func trackMovedLights(keys: [LightKey], lights: inout [Akari.Lux.PointLight])
  {
    for (i, key) in keys.enumerated()
    {
      if let last = pointLights.positions[key], ((last - lights[i].position) * (last - lights[i].position)).sum() > 1e-8
      {
        pointLights.following.insert(key)
        lights[i].moved = ((lights[i].position - last) * (lights[i].position - last)).sum().squareRoot()
      }

      pointLights.positions[key] = lights[i].position
    }
  }

  /// The lights marked hero, plus the ones that have moved and reach an animated mesh, since they follow a character.
  private func heroLights(_ snapshot: [Pixar.HdAkariLightData], keys: [LightKey], lights: [Akari.Lux.PointLight]) -> Set<LightKey>
  {
    let animated = geometry.dynamicBatch.bounds
    return Set(snapshot.filter(\.hero).map { Pixar.HdAkariPathKey($0.id) }).union(zip(keys, lights).compactMap
    { key, light in
      guard pointLights.following.contains(key), let animated else { return nil }
      let gap = light.position - pointwiseMin(pointwiseMax(light.position, animated.min), animated.max)
      return (gap * gap).sum() < light.reach * light.reach ? key : nil
    })
  }

  /// A light keeps its slot while it stays shadowed, so reranking never hands its maps to another.
  private func assignShadowSlots(_ wanted: Set<LightKey>, by rank: [LightKey]) -> [LightKey]
  {
    var slots = pointLights.slots
    var slot = 0
    while slot < slots.count
    {
      if wanted.contains(slots[slot]) { slot += 1 } else { slots[slot] = slots[slots.count - 1]; slots.removeLast() }
    }

    slots += rank.filter { wanted.contains($0) && !slots.contains($0) }
    pointLights.slots = slots
    return slots
  }

  /// Heroes win outright, the rest by score, a light already main holding on
  /// with a bonus that starts high and settles, so assignments never flicker.
  private func assignMainShadows(_ slots: [LightKey], weights: [LightKey: Float], heroes: Set<LightKey>)
  {
    pointLights.syncs &+= 1
    for key in Array(pointLights.mainSince.keys) where !pointLights.mains.contains(key) || weights[key] == nil
    {
      pointLights.mainSince[key] = nil
    }

    func held(_ key: LightKey) -> Float
    {
      guard let since = pointLights.mainSince[key] else { return 1 }
      return 2 + 2 * exp(-Float(pointLights.syncs &- since) / 120)
    }

    let ranked = slots.sorted
    {
      heroes.contains($0) != heroes.contains($1)
        ? heroes.contains($0)
        : weights[$0, default: 0] * held($0) > weights[$1, default: 0] * held($1)
    }

    let mains = Set(ranked.prefix(Self.mainShadowLights))
    for key in mains where pointLights.mainSince[key] == nil
    {
      pointLights.mainSince[key] = pointLights.syncs
    }

    pointLights.mains = mains
    shadowAtlas.mainSlots = Set(slots.indices.filter { mains.contains(slots[$0]) })
  }

  /// The meshes Hydra changed since the last frame, and the path keys of the ones it removed or emptied.
  private func drainMeshChanges(_ scene: Pixar.HdAkariScene) -> (changed: [Akari.Geom.Recorder.RawMesh], removed: [UInt64])
  {
    let drained = scene.DrainMeshChanges()
    var changed: [Akari.Geom.Recorder.RawMesh] = []
    var removed = Array(drained.removed)
    changed.reserveCapacity(drained.updated.size())

    for mesh in drained.updated
    {
      if let raw = rawMesh(mesh)
      {
        changed.append(raw)
      }
      else
      {
        removed.append(Pixar.HdAkariPathKey(mesh.id))
      }
    }

    return (changed, removed)
  }

  /// A synced mesh as the recorder takes it, nil when it has nothing to draw.
  private func rawMesh(_ mesh: Pixar.HdAkariMeshData) -> Akari.Geom.Recorder.RawMesh?
  {
    let key = Pixar.HdAkariPathKey(mesh.id)
    let mat = Pixar.GfMatrix4f(mesh.transform)
    guard
      !mesh.points.empty(),
      !mesh.triangleIndices.empty(),
      let mPtr = mat.GetArray()
    else
    {
      return nil
    }

    let worldMatrix = Array(UnsafeBufferPointer(start: mPtr, count: 16))
    let normalMatrix = Akari.Matrix.normalMatrix3x3(mPtr)
    let flipWinding = Akari.Matrix.determinant3x3(mPtr) < 0

    var raw = Akari.Geom.Recorder.RawMesh(id: mesh.id.string,
                                          key: key,
                                          primId: mesh.primId,
                                          dataRevision: mesh.dataRevision,
                                          topologyRevision: mesh.topologyRevision,
                                          flipWinding: flipWinding,
                                          points: mesh.points,
                                          tris: mesh.triangleIndices,
                                          uvs: mesh.uvs,
                                          worldMatrix: worldMatrix,
                                          normalMatrix: normalMatrix,
                                          contentKey: mesh.contentKey)
    raw.transparent = mesh.transparent
    raw.emitter = mesh.emitter
    raw.shadowCutout = mesh.shadowCutout
    raw.opacity = mesh.opacity
    raw.smooth = mesh.smooth
    raw.color = SIMD3(mesh.displayColor[0], mesh.displayColor[1], mesh.displayColor[2])
    raw.roughness = mesh.roughness
    raw.triangleFaces = mesh.triangleFaces
    raw.faceRes = mesh.faceRes
    raw.ptexMap = Int32(mesh.ptexMap)
    let instanceCount = Int(mesh.instances.size())
    if instanceCount > 0
    {
      // every mesh under one prototype shares its set, copied once.
      raw.instancesKey = mesh.instancesKey
      if let shared = geometry.instanceSets[mesh.instancesKey], shared.count == instanceCount * 16
      {
        raw.instances = shared
      }
      else
      {
        raw.instances = Akari.Geom.Matrices(usd: mesh.instances)
        geometry.instanceSets[mesh.instancesKey] = raw.instances
      }

      if let live = Akari.LiveInstances.prototype(of: raw.id), live.slot.count == instanceCount { raw.livePrototype = live.path }
    }

    let joints = Int(Pixar.HdAkariSkinJointCount(mesh))
    if joints > 0
    {
      raw.skinInfluencesPerPoint = Int(mesh.skinInfluencesPerPoint)
      raw.skinInfluences = mesh.skinInfluences
      raw.skinRevision = mesh.skinRevision
      raw.skinPalette = [Float](repeating: 0, count: joints * 12)
      raw.skinBounds = [Float](repeating: 0, count: 6)
      raw.skinPalette.withUnsafeMutableBufferPointer
      { palette in
        raw.skinBounds.withUnsafeMutableBufferPointer { Pixar.HdAkariCopySkin(mesh, palette.baseAddress!, $0.baseAddress!) }
      }
    }

    return raw
  }

  /// Chooses the geometry again once the camera settles past the margin it was chosen for,
  /// once the view's size has changed what a pixel covers, or once a background load has grown
  /// what the scene can hold.
  private func updateReframe(view: Akari.Matrix4, projection: Akari.Matrix4, eye: SIMD3<Float>)
  {
    // past the margin it was chosen for or 1/30th of the scene from before.
    let forward = simd_normalize(view.inverse().transform(SIMD3(0, 0, -1)) - eye)
    let pixelScale = abs(projection.simd.columns.1.y) * Float(max(sizes.target.height, 1)) / 2
    if eye != geometry.view.lastEye || forward != geometry.view.lastForward || pixelScale != geometry.view.lastPixelScale
    {
      geometry.view.lastEye = eye
      geometry.view.lastForward = forward
      if pixelScale != geometry.view.lastPixelScale { geometry.view.resized = Date() }
      geometry.view.lastPixelScale = pixelScale
      geometry.view.eyeMoved = Date()
    }

    // a first frame drawn before the view reached its size chose for a few pixels.
    if loadsInBackground, let recorded = geometry.view.camera, let bounds = sceneBounds,
       simd_distance(eye, recorded.eye) > simd_length(bounds.max - bounds.min) * 0.03
       || simd_dot(forward, recorded.forward) < cos(RecordCamera.margin)
       || abs(log2(pixelScale / max(recorded.pixelScale, 1e-6))) > 0.25,
       Date().timeIntervalSince(geometry.view.eyeMoved) > 0.5
    {
      geometry.view.reframe = true
    }
    // a record during a load's peak held less than the scene can have once it settles.
    if loadsInBackground, geometry.record.count > 0, Date().timeIntervalSince(geometry.record.at) > 5,
       triangleBudgetGrew()
    {
      geometry.view.reframe = true
    }
  }

  /// Rasterizes the G-buffer now instead of waiting
  /// for `present()`'s final `runtime.render()`.
  public func renderGbufferEarly(wireframe: Bool = false)
  {
    guard windowHandle != nil else { return }

    ensureShadowBindings()

    // one encoder for the gbuffer, split only by the late cull's compute.
    runtime.beginPasses()
    defer { runtime.endPasses() }

    for pass in Self.gbufferPassNames
    {
      if wireframe { gl.polygonMode(face: GLenum(GL_FRONT_AND_BACK), mode: GLenum(pass == .clearGbuffer ? GL_FILL : GL_LINE)) }
      runtime.renderPass(pass)
      if pass == .geometry, encodeLateCull()
      {
        runtime.setMeshCaptureCulledSlot(.meshStatic, slot: Self.cameraLateCullSlot)
        runtime.renderPass(pass)
      }

      runtime.setPassActive(pass, active: false)
    }

    if wireframe { gl.polygonMode(face: GLenum(GL_FRONT_AND_BACK), mode: GLenum(GL_FILL)) }
  }
}
