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
import LabGL
import simd

public extension Akari.LabFXEngine
{
  /// what the light probes bake from besides the scene
  struct Probes
  {
    var overrides: [Akari.LightProbes.Override] = []
    var overrideRevision: UInt64 = .max

    /// probe identity without the transform, used as the key for the probe layout bake
    var structuralRevision: UInt64 = 0

    /// the material, color and emissive atlases the probe capture samples
    var materials: (material: GLuint, color: GLuint, emissive: GLuint, constants: GLuint) = (0, 0, 0, 0)

    /// how many cube faces the probe capture draws per frame
    var captureViews: Int = 24

    /// the automatic volume last baked, kept while the scene still fits inside it
    var automaticBox: (min: SIMD3<Float>, max: SIMD3<Float>)?
  }

  /// advances the light probe bake and binds the probes for the deferred resolve
  func updateLightProbes(renderParam: Pixar.HdAkariRenderParam, camera: Akari.Camera, settings: RenderSettings)
  {
    let captures = geometry.probeCaptures
    guard
      !captures.isEmpty,
      let sceneBounds,
      let scene = renderParam.GetScene()
    else { return }

    // a transform in progress keeps the last bake and pauses any bake underway, both catch up once it ends
    if isEditing
    {
      if lightProbes.isReady { bindLightProbes() }
      return
    }

    let revision = scene.ProbeRevision()
    if revision != probes.overrideRevision
    {
      probes.overrideRevision = revision

      let (overrides, structural) = Self.lightProbeOverrides(scene)
      probes.overrides = overrides
      probes.structuralRevision = structural
    }

    var overrides = probes.overrides
    var structural = probes.structuralRevision
    var automatic: [Akari.LightProbes.Override] = []
    if overrides.isEmpty, let volume = automaticProbeVolume(camera: camera, sceneBounds: sceneBounds)
    {
      automatic.append(volume)
    }

    automatic += automaticGlassProbes(besides: overrides.filter(\.isSphere).count)
    for probe in automatic
    {
      structural = (structural ^ (probe.isSphere ? 1 : 0)) &* 0x100_0000_01B3
      for bits in [probe.min, probe.max].flatMap({ [$0.x, $0.y, $0.z] }).map({ UInt64($0.bitPattern) })
      {
        structural = (structural ^ bits) &* 0x100_0000_01B3
      }
    }
    overrides += automatic

    // with no probes in view the sky lights the scene and the last bake stays for when they come back
    lightProbes.inView = !overrides.isEmpty
    guard lightProbes.inView else { return }

    var probeSettings = settings.probes
    let frameBudget = 1 / Double(max(settings.targetFrameRate, 1))
    let gpuTime = labgl.lastFrameGPUTime()
    let hasRoom = gpuTime > 0 && gpuTime < frameBudget * 0.6
    if loadsInBackground
    {
      let limit = max(isPlaying ? probeSettings.captureViewsPerFrame / 4 : probeSettings.captureViewsPerFrame, 4)
      probeSettings.captureViewsPerFrame = adaptCaptureViews(overBudget: gpuTime > frameBudget * 0.9, hasRoom: hasRoom, limit: limit)
    }

    // sun directions the animation needs are only baked ahead while the view is idle
    lightProbes.bakesAhead = !loadsInBackground || (!isPlaying && hasRoom)

    var lighting = Akari.LightProbes.Lighting(
      sunDirection: worldSpaceSunDirection(settings.light),
      sunHeight: effectiveSunHeight(settings.light),
      zUp: stageIsZUp,
      iblEnabled: settings.features.contains(.imageBasedLighting),
      sunColor: sunColor(iblEnabled: settings.features.contains(.imageBasedLighting)),
      environment: environment.bakedRevision,
      // intensity rounded to an eighth of a stop so flicker doesn't relight every probe
      lights: pointLights.shadowed.filter(\.probes).flatMap
      {
        [SIMD4($0.position, exp2((log2(max($0.intensity, 1e-6)) * 8).rounded() / 8)), SIMD4($0.color, $0.radius)]
      }
    )
    lighting.skyTint = probeSkyTint

    let ready = lightProbes.update(captures: captures,
                                   sceneBounds: sceneBounds,
                                   overrides: overrides,
                                   overrideRevision: structural,
                                   upAxis: stageIsZUp ? 2 : 1,
                                   materials: probes.materials,
                                   environment: runtime.texture(.envCube, named: .envCube),
                                   lighting: lighting,
                                   settings: probeSettings)

    // until the first bake finishes the resolve lights the scene by the sky alone
    guard ready
    else
    {
      setVector(.probeGridMin, SIMD4(lightProbes.layout.gridMin, 0))
      setVector(.probeGridMax, SIMD4(lightProbes.layout.gridMax, 0))
      return
    }

    bindLightProbes()
  }

  /// points the deferred resolve at the baked probes
  private func bindLightProbes()
  {
    let layout = lightProbes.layout
    setSampler(.probeVolume, lightProbes.volumeSH)
    setSampler(.probeSphere, lightProbes.sphereAtlas)
    setSampler(.probeInfo, lightProbes.sphereInfo)
    setVector(.probeGridMin, SIMD4(layout.gridMin, layout.volumeCount > 0 ? 1 : 0))
    setVector(.probeGridMax, SIMD4(layout.gridMax, Float(layout.spheres.count)))
    setVector(.probeGridSize, SIMD4(SIMD3<Float>(layout.dims), layout.normalBias))
  }

  /// halves the probe faces drawn per frame when a frame runs long and grows them back while there is room
  private func adaptCaptureViews(overBudget: Bool, hasRoom: Bool, limit: Int) -> Int
  {
    if overBudget
    {
      probes.captureViews = max(probes.captureViews / 2, 4)
    }
    else if hasRoom
    {
      probes.captureViews += max(probes.captureViews / 4, 1)
    }

    probes.captureViews = min(probes.captureViews, limit)
    return probes.captureViews
  }

  /// a sphere probe at the middle of each glass object, for what the view through the glass can't see, the glass itself left out
  func automaticGlassProbes(besides authored: Int) -> [Akari.LightProbes.Override]
  {
    let room = Akari.LightProbes.maxSphereProbes - authored
    guard room > 0 else { return [] }

    return geometry.deformer.glassBounds.prefix(room).map
    { bounds in
      // snapped to a sixteenth of the glass's size so glass that drifts a little keeps its probe instead of rebaking
      let extent = bounds.max - bounds.min
      let snap = max(extent.max() / 16, 1e-3)
      let center = ((bounds.min + bounds.max) * 0.5 / snap).rounded(.toNearestOrAwayFromZero) * snap
      let radius = (extent.max() * 0.5 / snap).rounded(.up) * snap
      return Akari.LightProbes.Override(min: center - radius, max: center + radius, isSphere: true)
    }
  }

  /// a probe volume for scenes without their own, covering the scene or following the view on large landscapes
  func automaticProbeVolume(camera: Akari.Camera, sceneBounds: (min: SIMD3<Float>, max: SIMD3<Float>)) -> Akari.LightProbes.Override?
  {
    guard ProcessInfo.processInfo.environment["AKARI_LANDSCAPE_PROBES"] != "0" else { return nil }

    // only still geometry places the volume so animation and edits do not relayout and rebake every probe
    let still = probeBounds()
    if still == nil, let held = probes.automaticBox
    {
      return Akari.LightProbes.Override(min: held.min, max: held.max, isSphere: false)
    }

    let sceneBounds = still ?? sceneBounds
    let extent = sceneBounds.max - sceneBounds.min
    guard (extent * extent).sum().squareRoot() >= camera.world(meters: 1000)
    else
    {
      let pad = Akari.Math.max(extent * 0.02, SIMD3(repeating: camera.world(meters: 0.05)))
      let lo = sceneBounds.min - pad, hi = sceneBounds.max + pad

      // the baked box stays while it still holds the scene and has not become far too big for it
      if let held = probes.automaticBox, all(held.min .<= lo), all(held.max .>= hi),
         all((hi - lo) .>= (held.max - held.min) * 0.75)
      {
        return Akari.LightProbes.Override(min: held.min, max: held.max, isSphere: false)
      }

      probes.automaticBox = (lo, hi)
      return Akari.LightProbes.Override(min: lo, max: hi, isSphere: false)
    }

    guard !loadsInBackground else { return nil }

    let up = stageIsZUp ? 2 : 1
    let half = camera.world(meters: 80), snap = half / 2

    let inverseView = camera.view.inverse()
    let eye = inverseView.transform(.zero)
    var ahead = inverseView.transform(SIMD3(0, 0, -1)) - eye
    ahead[up] = 0

    let length = (ahead * ahead).sum().squareRoot()
    var center = length > 1e-4 ? eye + ahead / length * half * 0.8 : eye
    center = (center / snap).rounded(.toNearestOrAwayFromZero) * snap

    var lo = center - half, hi = center + half
    lo[up] = ((eye[up] - camera.world(meters: 20)) / snap).rounded(.down) * snap
    hi[up] = ((eye[up] + camera.world(meters: 60)) / snap).rounded(.up) * snap
    lo = pointwiseMax(lo, sceneBounds.min)
    hi = pointwiseMin(hi, sceneBounds.max)
    guard all(hi - lo .> camera.world(meters: 1)) else { return nil }

    var resolution = SIMD3<Int32>(repeating: 13)
    resolution[up] = 6
    return Akari.LightProbes.Override(min: lo, max: hi, isSphere: false, resolution: resolution)
  }

  /// the bounds of the static and instanced geometry, the part of the scene that holds still
  private func probeBounds() -> (min: SIMD3<Float>, max: SIMD3<Float>)?
  {
    [geometry.staticBatch, geometry.instancedBatch].compactMap(\.bounds).reduce(nil)
    { bounds, next in
      bounds.map { (min: pointwiseMin($0.min, next.min), max: pointwiseMax($0.max, next.max)) } ?? next
    }
  }

  /// the authored probes as world boxes and a revision over their ids and local bounds that ignores the transform
  private static func lightProbeOverrides(_ scene: Pixar.HdAkariScene) -> (overrides: [Akari.LightProbes.Override], structural: UInt64)
  {
    let probes = scene.ProbeSnapshot()
    var structural = UInt64(probes.count)

    let overrides: [Akari.LightProbes.Override] = probes.compactMap
    { probe in
      structural = (structural ^ (probe.isSphere ? 1 : 0)) &* 0x100_0000_01B3
      for bits in [UInt64(probe.minX.bitPattern), UInt64(probe.minY.bitPattern),
                   UInt64(probe.minZ.bitPattern), UInt64(probe.maxX.bitPattern),
                   UInt64(probe.maxY.bitPattern), UInt64(probe.maxZ.bitPattern),
                   UInt64(probe.resolutionX),
                   UInt64(probe.resolutionY),
                   UInt64(probe.resolutionZ)]
      {
        structural = (structural ^ bits) &* 0x100_0000_01B3
      }

      let matrix = Pixar.GfMatrix4f(probe.transform)
      guard let elements = matrix.GetArray() else { return nil }
      let world = Akari.Matrix4(Array(UnsafeBufferPointer(start: elements, count: 16)))

      let lo = SIMD3(probe.minX, probe.minY, probe.minZ)
      let hi = SIMD3(probe.maxX, probe.maxY, probe.maxZ)
      var boxMin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
      var boxMax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
      for corner in 0 ..< 8
      {
        let local = SIMD3(corner & 1 == 0 ? lo.x : hi.x,
                          corner & 2 == 0 ? lo.y : hi.y,
                          corner & 4 == 0 ? lo.z : hi.z)
        let point = world.transform(local)
        boxMin = Akari.Math.min(boxMin, point)
        boxMax = Akari.Math.max(boxMax, point)
      }

      return Akari.LightProbes.Override(min: boxMin,
                                        max: boxMax,
                                        isSphere: probe.isSphere,
                                        resolution: SIMD3(probe.resolutionX, probe.resolutionY, probe.resolutionZ))
    }

    return (overrides, structural)
  }
}
