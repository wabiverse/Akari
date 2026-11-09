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
import HdAkari
import LabGL
import simd

public extension Akari.LabFXEngine
{
  /// What the light probes bake from besides the scene.
  struct Probes
  {
    var overrides: [Akari.LightProbes.Override] = []
    var overrideRevision: UInt64 = .max
    /// Probe identity without the transform, keys the probe layout bake.
    var structuralRevision: UInt64 = 0
    /// The material, color and emissive atlases the probe capture samples.
    var materials: (material: GLuint, color: GLuint, emissive: GLuint, constants: GLuint) = (0, 0, 0, 0)
  }

  /// Advances the light probe bake and binds the probes for the deferred resolve.
  func updateLightProbes(renderParam: Pixar.HdAkariRenderParam, camera: Akari.Camera, settings: RenderSettings)
  {
    let captures = geometry.shadowCaptures
    guard
      !captures.isEmpty,
      let sceneBounds,
      let scene = renderParam.GetScene()
    else { return }

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
    if overrides.isEmpty, let volume = landscapeProbeVolume(camera: camera, sceneBounds: sceneBounds)
    {
      overrides = [volume]
      for bits in [volume.min, volume.max].flatMap({ [$0.x, $0.y, $0.z] }).map({ UInt64($0.bitPattern) })
      {
        structural = (structural ^ bits) &* 0x100_0000_01B3
      }
    }
    // no authored probes in view, the sky lights it, and the last ones stay baked for when they're back.
    lightProbes.inView = !overrides.isEmpty
    guard lightProbes.inView else { return }
    // playback keeps going while they bake, a quarter as many views a frame.
    var probeSettings = settings.probes
    if isPlaying { probeSettings.captureViewsPerFrame = max(probeSettings.captureViewsPerFrame / 4, 6) }

    var lighting = Akari.LightProbes.Lighting(
      sunDirection: worldSpaceSunDirection(settings.light),
      sunHeight: effectiveSunHeight(settings.light),
      zUp: stageIsZUp,
      iblEnabled: settings.features.contains(.imageBasedLighting),
      sunColor: sunColor(iblEnabled: settings.features.contains(.imageBasedLighting)),
      environment: environment.revision,
      // a light that moves every frame would relight every probe every frame,
      // so intensity is kept to an eighth of a stop so flicker doesn't relight
      // them either.
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
    guard ready else { return }

    let layout = lightProbes.layout
    setSampler(.probeVolume, lightProbes.volumeSH)
    setSampler(.probeSphere, lightProbes.sphereAtlas)
    setSampler(.probeInfo, lightProbes.sphereInfo)
    setVector(.probeGridMin, SIMD4(layout.gridMin, layout.volumeCount > 0 ? 1 : 0))
    setVector(.probeGridMax, SIMD4(layout.gridMax, Float(layout.spheres.count)))
    setVector(.probeGridSize, SIMD4(SIMD3<Float>(layout.dims), layout.normalBias))
  }

  /// A "landscape" (a kilometer or more across) with no probes of its own gets, in a final render, a volume around the view,
  /// so geometry casts shadows on the meshes under it, anything beyond that geometry gets lit by the sky.
  func landscapeProbeVolume(camera: Akari.Camera, sceneBounds: (min: SIMD3<Float>, max: SIMD3<Float>)) -> Akari.LightProbes.Override?
  {
    let extent = sceneBounds.max - sceneBounds.min
    guard
      !loadsInBackground,
      ProcessInfo.processInfo.environment["AKARI_LANDSCAPE_PROBES"] != "0",
      (extent * extent).sum().squareRoot() >= camera.world(meters: 1000)
    else { return nil }
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

  /// The authored probes as world space boxes, with a revision for the
  /// probe identities and local bounds that ignores the transform.
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

      let mat = Pixar.GfMatrix4f(probe.transform)
      guard let mPtr = mat.GetArray() else { return nil }
      let world = Akari.Matrix4(Array(UnsafeBufferPointer(start: mPtr, count: 16)))

      let lo = SIMD3(probe.minX, probe.minY, probe.minZ)
      let hi = SIMD3(probe.maxX, probe.maxY, probe.maxZ)
      var boxMin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
      var boxMax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
      for corner in 0 ..< 8
      {
        let p = SIMD3(corner & 1 == 0 ? lo.x : hi.x,
                      corner & 2 == 0 ? lo.y : hi.y,
                      corner & 4 == 0 ? lo.z : hi.z)
        let w = world.transform(p)
        boxMin = Akari.Math.min(boxMin, w)
        boxMax = Akari.Math.max(boxMax, w)
      }

      return Akari.LightProbes.Override(min: boxMin,
                                        max: boxMax,
                                        isSphere: probe.isSphere,
                                        resolution: SIMD3(probe.resolutionX, probe.resolutionY, probe.resolutionZ))
    }

    return (overrides, structural)
  }
}
