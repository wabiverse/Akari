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
  /// Tags the shadow pages this frame's G-buffer and froxels sample.
  ///
  /// - Parameters:
  ///   - camera: the view the G-buffer was just rendered from.
  ///   - settings: the frame's render settings.
  func markShadowPageUsage(camera: Akari.Camera, settings: RenderSettings)
  {
    guard settings.features.contains(.shadowMaps) else { return }

    let posTex = runtime.texture("gbuffer", named: "position")
    guard posTex != 0 else { return }

    shadowAtlas.markPageUsage(gbufferPosition: posTex,
                              camera: camera,
                              screenWidth: lastWidth,
                              screenHeight: lastHeight,
                              settings: settings.light.shadow,
                              lights: syncedPointLights,
                              sceneRevision: lastGeometryRevision,
                              casterBounds: casterBounds,
                              casterKeys: casterKeys,
                              volume: volumetrics.froxels)
  }

  /// Fits the sun cascades into the shadow atlas and redraws whichever
  /// tiles went stale, then binds them for the deferred resolve.
  ///
  /// - Parameters:
  ///   - renderParam: hydra render param.
  ///   - camera: the view the cascades are fitted to.
  ///   - settings: the frame's render settings.
  ///   - frameIndex: per frame counter, drives atlas eviction.
  func renderShadows(renderParam: Pixar.HdAkariRenderParam,
                     camera: Akari.Camera,
                     settings: RenderSettings,
                     frameIndex: UInt64)
  {
    shadowsReady = false
    guard
      let captureBuffer,
      let sceneBounds,
      renderParam.GetScene() != nil
    else { return }

    let shadow = settings.light.shadow
    let diagonal = sceneBounds.max - sceneBounds.min
    let punctualFarDistance = max((diagonal * diagonal).sum().squareRoot(), 1)
    let views = shadowAtlas.render(capture: captureBuffer,
                                   camera: camera,
                                   lightDirection: worldSpaceSunDirection(settings.light),
                                   sceneBounds: sceneBounds,
                                   casterBounds: casterBounds,
                                   sceneRevision: lastGeometryRevision,
                                   frameIndex: frameIndex,
                                   settings: shadow,
                                   lights: syncedPointLights,
                                   punctualFarDistance: punctualFarDistance)
    bindShadowViews(views, settings: shadow)
    shadowsReady = true

    // the atlas draws left the light's matrices on the stack,
    // so put the camera back before the captured replay.
    gl.matrixMode(GL_PROJECTION)
    gl.loadMatrix(Akari.Matrix4.reversedDepth(camera.projection).m)
    gl.matrixMode(GL_MODELVIEW)
    gl.loadMatrix(camera.view.m)
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
