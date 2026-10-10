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
import LabFX
import LabGL

extension Akari.LabFXEngine
{
  /// What brings this frame's scene up to the target.
  enum UpscaleMode
  {
    /// The `taa` pass, which also downsamples a supersampled frame.
    case taa
    case temporal
    case spatial
    /// MetalFX temporal up to `supersampleScale`, then the `downsample` pass.
    case supersample
  }

  struct UpscaleTextures
  {
    var color: GLuint = 0
    var depth: GLuint = 0
    var velocity: GLuint = 0
    var output: GLuint = 0
  }

  /// Picks this frame's upscaler and turns its pass on.
  func configureUpscale(settings: RenderSettings)
  {
    if !upscaleRegistered
    {
      runtime.setPassCallback("metalfx-upscale", callback: akariUpscaleCallback,
                              userdata: Unmanaged.passUnretained(self).toOpaque())
      upscaleRegistered = true
    }

    upscaleMode = if settings.upscaler != .metalFX || renderScale > 1 || upscaleFailed || labgl.upscaleSupported() == 0
    {
      .taa
    }
    else if settings.features.contains(.temporalAA)
    {
      supersampleScale > 1 ? .supersample : .temporal
    }
    else
    {
      renderScale < 1 ? .spatial : .taa
    }
    runtime.setPassActive("taa", active: upscaleMode == .taa)
    runtime.setPassActive("upscale", active: upscaleMode == .temporal || upscaleMode == .spatial)
    runtime.setPassActive("upscale supersample", active: upscaleMode == .supersample)
    runtime.setPassActive("downsample", active: upscaleMode == .supersample)
  }

  /// The callback runs inside `runtime.render()`, so it can't look the textures up itself.
  func prepareUpscale()
  {
    guard upscaleMode != .taa else { return }
    upscaleTextures = UpscaleTextures(color: runtime.texture("color", named: "final"),
                                      depth: runtime.bufferDepth("gbuffer"),
                                      velocity: runtime.texture("gbuffer", named: "velocity"),
                                      output: upscaleMode == .supersample
                                        ? runtime.writeTexture("supersample", named: "supersample")
                                        : runtime.writeTexture("taa", named: "final"))
  }

  fileprivate func upscale()
  {
    let color = upscaleTextures.color
    let output = upscaleTextures.output
    switch upscaleMode
    {
      case .temporal, .supersample:
        // the velocity runs up in uv, MetalFX wants pixels running down.
        upscaleFailed = labgl.upscaleTemporal(color: color,
                                  depth: upscaleTextures.depth,
                                  motion: upscaleTextures.velocity,
                                  output: output,
                                  jitterX: taaJitter.x,
                                  jitterY: -taaJitter.y,
                                  motionScaleX: Float(renderWidth),
                                  motionScaleY: -Float(renderHeight),
                                  reversedDepth: 1,
                                  reset: temporalReset ? 1 : 0) == 0
      case .spatial:
        upscaleFailed = labgl.upscaleSpatial(color: color, output: output) == 0
      case .taa:
        break
    }
  }
}

/// `Runtime.setPassCallback` takes a plain C function pointer.
private func akariUpscaleCallback(_ userdata: UnsafeMutableRawPointer?, _: Int32, _: Int32)
{
  guard let userdata else { return }
  Unmanaged<Akari.LabFXEngine>.fromOpaque(userdata).takeUnretainedValue().upscale()
}
