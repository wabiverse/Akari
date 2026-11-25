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
  /// halves one bloom level into the next, starting from the taa output.
  struct BloomDownShader: FullscreenShader
  {
    let level: Int

    var name: String { "bloom-down-\(level)" }

    /// the texture this level downsamples.
    var source: TextureRef { level == 0 ? TaaBuffer.final.ref : bloomDown[level - 1] }

    var target: TextureRef { bloomDown[level] }

    var uniforms: [Declaration]
    {
      if level == 0 { Uniforms.bloomFilter }
      Sampler(source)
    }

    var fragmentGLSL: String
    {
      #"""
      void main()
      {
        \#(target.output) = texture(\#(source.sampler), var.texCoord);
      }
      """#
    }

    /// the first level also keeps only the parts of the frame bright enough to bloom.
    var fragmentMSL: String
    {
      let downsample = "postDownsample(\(source.sampler), \(source.sampler)_smp, var.texCoord, \(level == 0))"
      guard level == 0
      else
      {
        return #"""
          \#(ShaderLibrary.postMSL)

          //@main
          {
            \#(target.output) = float4(\#(downsample), 1.0);
          }
          """#
      }

      return #"""
        \#(ShaderLibrary.postMSL)

        //@main
        {
          float3 c = min(\#(downsample), float3(u_bloomFilter.z));
          float bright = max(c.r, max(c.g, c.b));
          float knee = u_bloomFilter.x * u_bloomFilter.y + 1e-5;
          float soft = clamp(bright - u_bloomFilter.x + knee, 0.0, 2.0 * knee);
          c *= max(soft * soft / (4.0 * knee), bright - u_bloomFilter.x) / max(bright, 1e-5);
          \#(target.output) = float4(c, 1.0);
        }
        """#
    }
  }
}
