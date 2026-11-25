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

extension Akari.RenderGraph
{
  /// copies one texture into a pass's output, the way frames move between the taa stages.
  struct TaaCopyShader: FullscreenShader
  {
    /// what gets copied, which also names the shader.
    enum Source: String, Sendable
    {
      case taa, transparent, blurred, dof

      var texture: TextureRef
      {
        switch self
        {
          case .taa: TaaBuffer.final.ref
          case .transparent: TransparentResolvedBuffer.tResolved.ref
          case .blurred: MotionBlurBuffer.motionBlurred.ref
          case .dof: DofBuffer.dofColor.ref
        }
      }
    }

    let source: Source

    var name: String { source == .taa ? "taa-copy" : "taa-copy-\(source.rawValue)" }

    /// the taa copy fills the history, the others write the `final` texture of whichever buffer their pass outputs.
    var output: String { source == .taa ? HistoryBuffer.history.ref.output : "o_final_texture" }

    var uniforms: [Declaration]
    {
      Sampler(source.texture)
    }

    var fragmentGLSL: String
    {
      #"""
      void main()
      {
        \#(output) = texelFetch(\#(source.texture.sampler), ivec2(gl_FragCoord.xy), 0);
      }
      """#
    }

    var fragmentMSL: String
    {
      #"""
      //@main
      {
        \#(output) = \#(source.texture.sampler).read(uint2(gl_FragCoord.xy));
      }
      """#
    }
  }
}
