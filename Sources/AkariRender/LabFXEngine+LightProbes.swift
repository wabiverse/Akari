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
  /// Advances the light probe bake and binds the probes for the deferred resolve.
  ///
  /// - Parameters:
  ///   - renderParam: hydra render param.
  ///   - settings: the frame's render settings.
  func updateLightProbes(renderParam: Pixar.HdAkariRenderParam, settings: RenderSettings)
  {
    guard
      let captureBuffer,
      let sceneBounds,
      let scene = renderParam.GetScene()
    else { return }

    let revision = scene.ProbeRevision()
    if revision != probeOverrideRevision
    {
      probeOverrideRevision = revision
      let (overrides, structural) = Self.lightProbeOverrides(scene)
      probeOverrides = overrides
      probeStructuralRevision = structural
    }

    let lighting = Akari.LightProbes.Lighting(
      sunDirection: worldSpaceSunDirection(settings.light),
      sunHeight: settings.light.sunHeight,
      zUp: stageIsZUp,
      iblEnabled: settings.features.contains(.imageBasedLighting),
      lights: syncedPointLights.flatMap
      {
        [SIMD4($0.position, $0.intensity), SIMD4($0.color, $0.radius)]
      }
    )

    let ready = lightProbes.update(capture: captureBuffer,
                                   sceneBounds: sceneBounds,
                                   overrides: probeOverrides,
                                   overrideRevision: probeStructuralRevision,
                                   upAxis: stageIsZUp ? 2 : 1,
                                   materials: probeMaterials,
                                   environment: runtime.texture("envCube", named: "envCube"),
                                   lighting: lighting,
                                   settings: settings.probes)
    guard ready else { return }

    let layout = lightProbes.layout
    setSampler("u_probe_volume", lightProbes.volumeSH)
    setSampler("u_probe_sphere", lightProbes.sphereAtlas)
    setSampler("u_probe_info", lightProbes.sphereInfo)
    setVector("u_probeGridMin", SIMD4(layout.gridMin, 1))
    setVector("u_probeGridMax", SIMD4(layout.gridMax, Float(layout.spheres.count)))
    setVector("u_probeGridSize", SIMD4(SIMD3<Float>(layout.dims), layout.normalBias))
  }

  /// The authored probes as world space boxes, with a revision for the
  /// probe identities and local bounds that ignores the transform.
  private static func lightProbeOverrides(_ scene: Pixar.HdAkariScene) -> (overrides: [Akari.LightProbes.Override], structural: UInt64)
  {
    let probes = scene.ProbeSnapshot()
    var structural = UInt64(probes.count)

    let overrides: [Akari.LightProbes.Override] = probes.compactMap
    { probe in
      structural = (structural ^ (probe.isSphere ? 1 : 0)) &* 0x100000001b3
      for bits in [UInt64(probe.minX.bitPattern), UInt64(probe.minY.bitPattern),
                   UInt64(probe.minZ.bitPattern), UInt64(probe.maxX.bitPattern),
                   UInt64(probe.maxY.bitPattern), UInt64(probe.maxZ.bitPattern),
                   UInt64(probe.resolutionX),
                   UInt64(probe.resolutionY),
                   UInt64(probe.resolutionZ)]
      {
        structural = (structural ^ bits) &* 0x100000001b3
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
        boxMin = simd_min(boxMin, w)
        boxMax = simd_max(boxMax, w)
      }

      return Akari.LightProbes.Override(min: boxMin,
                                        max: boxMax,
                                        isSphere: probe.isSphere,
                                        resolution: SIMD3(probe.resolutionX, probe.resolutionY, probe.resolutionZ))
    }

    return (overrides, structural)
  }
}
