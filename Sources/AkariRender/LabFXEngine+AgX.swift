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
import LabGL

extension Akari.LabFXEngine
{
  /// baked lut size and log shaper for the agx view with each look.
  static let agxLutSize = 65
  static let agxLutShaper = SIMD4<Float>(-12.47393, 12.5260688117 + 12.47393, 0, 0)

  /// hands the tonemap the lut for the look, or nil for the analytic agx curve.
  func bindAgXLook(_ look: Akari.Color.Look?)
  {
    guard let look, let lut = agxLut(look)
    else
    {
      setFloat(.agxLutSize, 0)
      return
    }

    setSampler(.agxLut, lut)
    setFloat(.agxLutSize, Float(Self.agxLutSize))
    setVector(.agxLutShaper, Self.agxLutShaper)
  }

  private func agxLut(_ look: Akari.Color.Look) -> GLuint?
  {
    if let lut = agxLooks[look] { return lut }

    let n = Self.agxLutSize
    guard
      let url = Bundle.akari.url(forResource: "AgX_\(look.rawValue)", withExtension: "lut"),
      let data = try? Data(contentsOf: url),
      data.count == n * n * n * 8
    else { return nil }

    var lut: GLuint = 0
    gl.genTextures(count: 1, textures: &lut)
    gl.bindTexture(target: GLenum(GL_TEXTURE_3D), texture: lut)
    data.withUnsafeBytes
    { bytes in
      gl.texImage3D(target: GLenum(GL_TEXTURE_3D), level: 0, internalFormat: GL_RGBA16F,
                    width: GLsizei(n), height: GLsizei(n), depth: GLsizei(n), border: 0,
                    format: GL_RGBA, type: GLenum(GL_HALF_FLOAT), pixels: bytes.baseAddress)
    }

    agxLooks[look] = lut
    return lut
  }
}

public extension Akari.RenderEngine
{
  /// adopts the view transform, look, exposure and gamma the stage was authored with, the defaults when it authors none
  func adoptColorManagement(of stage: UsdStage)
  {
    let info = Pixar.HdAkariInspectStage(stage)
    let defaults = Akari.Color.Pipeline()

    // a scene without color management starts from the defaults rather than keeping the last scene's
    var settings = settings
    settings.color.viewTransform = info.hasColorManagement
      ? Akari.Color.ViewTransform(transformName: String(info.viewTransform)) ?? defaults.viewTransform
      : defaults.viewTransform
    settings.color.look = info.hasColorManagement ? Akari.Color.Look(lookName: String(info.look)) ?? defaults.look : defaults.look
    settings.color.exposure = info.hasColorManagement ? Float(info.exposure) : defaults.exposure
    settings.color.gamma = info.hasColorManagement ? Float(info.gamma) : defaults.gamma

    self.settings = settings
  }
}
