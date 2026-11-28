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
  /// sets the tonemap state, exposure, gamma, view transform and the dithering frame seed
  public func setTonemap(exposure: Float,
                         gamma: Float,
                         viewTransform: Akari.Color.ViewTransform,
                         look: Akari.Color.Look,
                         frameIndex: UInt64)
  {
    setFloat(.exposure, exposure)
    setFloat(.gamma, gamma)
    setInt(.frameIndex, Int32(frameIndex & 0xFFFF))
    bindAgXLook(viewTransform == .agx ? look : nil)

    if viewTransform.uniform != lastTonemap
    {
      lastTonemap = viewTransform.uniform
      runtime.setPassTonemap(.tonemap, tonemap: viewTransform.uniform)
    }
  }

  /// runs the deferred graph, outlines the selection, presents and wraps the color, prim id and depth into the aovs hydra uses
  public func present(target: Akari.GPU.HydraTarget, projection: Akari.Matrix4, hgi: Pixar.HgiMetal)
  {
    guard let windowHandle else { return }

    ensureShadowBindings()

    if ssgi.thisFrame != ssgi.passesActive
    {
      setPasses(Self.ssgiPassNames, active: ssgi.thisFrame)
      ssgi.passesActive = ssgi.thisFrame
    }

    if ssr.thisFrame != ssr.passesActive
    {
      setPasses(Self.ssrPassNames, active: ssr.thisFrame)
      ssr.passesActive = ssr.thisFrame
    }

    runtime.setPassActive(.ssgiPrep, active: ssgi.thisFrame || ssr.thisFrame)

    syncVolumetrics()
    syncMotionBlur()
    syncPost()
    setVector(.aovProjection, SIMD4(projection[2, 2], projection[3, 2], 0, 0))

    prepareUpscale()
    syncPtex()

    if environment.iblNeedsBake { setIBLPasses(active: true) }
    runtime.render()
    finishAtmosphereFrame()

    // the ibl only needs to bake once
    if environment.iblNeedsBake
    {
      setIBLPasses(active: false)
      environment.dfgNeedsBake = false
      environment.iblNeedsBake = false
      environment.bakedRevision = environment.revision
    }

    labgl.present(windowHandle)

    // hand the graph's final color, id and depth textures to the aovs through hgi
    let outputs = [
      (target.color, outlinedTexture),
      (target.primId, runtime.texture(.aov, named: .aovPrimId)),
      (target.instanceId, runtime.texture(.aov, named: .aovInstanceId)),
      (target.depth, runtime.texture(.aov, named: .aovDepth))
    ]

    for case let (renderBuffer?, texture) in outputs where texture != 0
    {
      let native = lglGetTextureNativeHandle(texture)
      guard native != 0 else { continue }

      #if canImport(HgiMetal)
        Pixar.AkariRenderBufferSetExternalTexture(renderBuffer, hgi, native)
      #else
        print("Hydra lacks support for using an external texture...")
      #endif
    }
  }
}
