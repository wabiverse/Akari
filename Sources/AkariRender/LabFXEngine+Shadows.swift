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

public extension Akari.LabFXEngine
{
  /// Fits the shadow views to this frame, then tags
  /// the pages its G-buffer and froxels sample.
  ///
  /// - Parameters:
  ///   - camera: the view the G-buffer was just rendered from.
  ///   - settings: the frame's render settings.
  func markShadowPageUsage(camera: Akari.Camera, settings: RenderSettings)
  {
    guard settings.features.contains(.shadowMaps) else { return }

    let posTex = runtime.texture("gbuffer", named: "position")
    guard
      posTex != 0,
      let sceneBounds
    else { return }

    shadowAtlas.markPageUsage(gbufferPosition: posTex,
                              camera: camera,
                              screenWidth: renderWidth,
                              screenHeight: renderHeight,
                              lightDirection: worldSpaceSunDirection(settings.light),
                              sceneBounds: sceneBounds,
                              settings: settings.light.shadow,
                              lights: syncedPointLights,
                              punctualFarDistance: Self.punctualFarDistance(sceneBounds),
                              sceneRevision: lastGeometryRevision,
                              casterBounds: casterBounds,
                              casterKeys: casterKeys,
                              staticGeneration: geometry.staticShadowCapture.map { labgl.captureGeneration($0) } ?? 0,
                              volume: volumetrics.froxels)
  }

  /// Redraws whichever tiles `markShadowPageUsage` found
  /// stale, then binds them for the deferred resolve.
  ///
  /// - Parameters:
  ///   - renderParam: hydra render param.
  ///   - camera: the view the cascades were fitted to.
  ///   - settings: the frame's render settings.
  ///   - frameIndex: per frame counter, drives atlas eviction.
  func renderShadows(renderParam: Pixar.HdAkariRenderParam,
                     camera: Akari.Camera,
                     settings: RenderSettings,
                     frameIndex: UInt64)
  {
    shadowsReady = false
    let staticCaptures = geometry.staticBatch.isEmpty ? [] : [geometry.staticShadowCapture].compactMap(\.self)
    // the deformed capture's draws move without a rerecord, so their bounds come along.
    var dynamicCaptures: [OpaquePointer] = []
    var dynamicDrawBounds: [[Float]?] = []
    if !geometry.dynamicBatch.isEmpty, let capture = geometry.deformer.shadowCapture ?? geometry.dynamicCapture
    {
      dynamicCaptures.append(capture)
      dynamicDrawBounds.append(geometry.dynamicBatch.casterBounds)
    }

    guard
      !staticCaptures.isEmpty || !dynamicCaptures.isEmpty,
      sceneBounds != nil,
      renderParam.GetScene() != nil
    else { return }

    let shadow = settings.light.shadow
    shadowAtlas.materialAtlas = probeMaterials.material
    let views = shadowAtlas.render(staticCaptures: staticCaptures,
                                   dynamicCaptures: dynamicCaptures,
                                   dynamicDrawBounds: dynamicDrawBounds,
                                   casterBounds: casterBounds)
    bindShadowViews(views, settings: shadow)
    shadowsReady = true

    // the atlas draws left the light's matrices on the stack,
    // so put the camera back before the captured replay.
    gl.matrixMode(GL_PROJECTION)
    gl.loadMatrix(Akari.Matrix4.reversedDepth(camera.projection).m)
    gl.matrixMode(GL_MODELVIEW)
    gl.loadMatrix(camera.view.m)
  }

  /// A power of two, so animated bounds don't move the cube far planes and restale them.
  private static func punctualFarDistance(_ bounds: (min: SIMD3<Float>, max: SIMD3<Float>)) -> Float
  {
    let diagonal = bounds.max - bounds.min
    return exp2(ceil(log2(max((diagonal * diagonal).sum().squareRoot(), 1))))
  }

  internal func ensureShadowBindings()
  {
    guard
      shadowAtlas.prepare(),
      shadowAtlas.atlas != boundShadowAtlas
    else { return }

    boundShadowAtlas = shadowAtlas.atlas
    setSampler("u_shadow_atlas", shadowAtlas.atlas)
    setSampler("u_shadow_data", shadowAtlas.data)
    setSampler("u_shadow_pagetable", shadowAtlas.pageTable)
  }

  private func bindShadowViews(_ views: [Akari.ShadowAtlas.View], settings: ShadowSettings)
  {
    ensureShadowBindings()
    setSampler("u_shadow_data", shadowAtlas.data)

    setFloat("u_shadowLevelCount", Float(views.count))
    setVector("u_shadowBias", SIMD4(settings.depthBias, settings.normalBias, 0, 0))

    let sun = shadowAtlas.sun
    setMatrix("u_eyeToLightRotation", sun.eyeToLightRotation)
    setVector("u_directionalRefOffset", SIMD4(sun.refOffset.x, sun.refOffset.y, sun.refOffset.z, 0))
    setVector("u_shadowLodRange", SIMD4(Float(sun.lodMin),
                                        Float(sun.lodMax),
                                        sun.isClipmap ? 1 : 0,
                                        sun.lodBias))
  }
}
