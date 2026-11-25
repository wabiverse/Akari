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
  /// drawn by the `bloom composite` pass.
  struct BloomCompositeShader: FullscreenShader
  {
    let name = "bloom-composite"

    var uniforms: [Declaration]
    {
      Sampler(BloomUp0Buffer.bloomUp0)
      Sampler(LensStreakBuffer.lensStreakB)
      Sampler(LensGhostsBuffer.lensGhosts)
      Uniforms.bloom
      Uniforms.bloomTint
    }

    let fragmentGLSL = #"""
      void main()
      {
        o_final_texture = vec4(0.0);
      }
      """#

    let fragmentMSL = #"""
      \#(ShaderLibrary.postMSL)

      //@main
      {
        float3 bloom = u_bloomUp0_texture.sample(u_bloomUp0_texture_smp, var.texCoord, level(0.0)).rgb / 5.0;
        bloom = mix(float3(dot(bloom, float3(0.2126, 0.7152, 0.0722))), bloom, u_bloomTint.w) * u_bloomTint.rgb;
        float3 streak = u_lensStreakB_texture.sample(u_lensStreakB_texture_smp, var.texCoord, level(0.0)).rgb;
        float3 ghosts = u_lensGhosts_texture.sample(u_lensGhosts_texture_smp, var.texCoord, level(0.0)).rgb;
        o_final_texture = float4(bloom * u_bloom.x + streak * float3(0.55, 0.75, 1.0) * u_bloom.y + ghosts * u_bloom.z, 1.0);
      }
      """#
  }
}
