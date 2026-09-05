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

public extension Akari
{
  /// Uploads the shared material + color texture atlases to the GPU.
  final class MaterialAtlas
  {
    private var materialTexture: GLuint = 0
    private var colorTexture: GLuint = 0

    public init() {}

    /// Reuploads when the atlas is dirty, returns both
    /// texture names (0 until the first upload).
    public func uploadIfNeeded(_ atlas: Pixar.HdAkariTextureAtlas) -> (material: GLuint, color: GLuint)
    {
      if atlas.ConsumeDirty()
      {
        let width = GLsizei(atlas.Width())
        let height = GLsizei(atlas.Height())
        if let pixels = atlas.PixelData()
        {
          upload(&materialTexture, pixels: pixels, width: width, height: height)
        }
        if let colorPixels = atlas.ColorPixelData()
        {
          upload(&colorTexture, pixels: colorPixels, width: width, height: height)
        }
      }
      return (materialTexture, colorTexture)
    }

    /// Uploads a texture atlas's pixels to `texture`.
    private func upload(_ texture: inout GLuint, pixels: UnsafePointer<UInt8>,
                        width: Int32, height: Int32)
    {
      if texture == 0
      {
        var tex: GLuint = 0
        gl.genTextures(count: 1, textures: &tex)
        texture = tex

        gl.bindTexture(target: GL_TEXTURE_2D, texture: texture)
        gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_MIN_FILTER, param: GL_LINEAR_MIPMAP_LINEAR)
        gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_MAG_FILTER, param: GL_LINEAR)
        gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_WRAP_S, param: GL_CLAMP_TO_EDGE)
        gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_WRAP_T, param: GL_CLAMP_TO_EDGE)
        gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_MAX_LEVEL, param: GLint(3))
      }
      else
      {
        gl.bindTexture(target: GL_TEXTURE_2D, texture: texture)
      }

      gl.texImage2D(target: GL_TEXTURE_2D, level: 0, internalFormat: GL_RGBA,
                    width: width, height: height, border: 0,
                    format: GLenum(GL_RGBA), type: GL_UNSIGNED_BYTE,
                    pixels: pixels)
      gl.generateMipmap(GL_TEXTURE_2D)
    }
  }
}
