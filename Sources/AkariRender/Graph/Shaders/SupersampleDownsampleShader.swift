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
  /// drawn by the `downsample` pass.
  struct SupersampleDownsampleShader: FullscreenShader
  {
    let name = "supersample-downsample"

    var uniforms: [Declaration]
    {
      Sampler(SupersampleBuffer.supersample)
      Uniforms.supersampleScale
    }

    let fragmentGLSL = #"""
      void main()
      {
        vec2 size = vec2(textureSize(u_supersample_texture, 0));
        vec2 s = u_supersampleScale.xy;
        vec2 highPos = gl_FragCoord.xy * s;
        vec2 base = floor(highPos - 0.5) - 1.5;
        vec2 pos[3];
        vec2 weight[3];
        for (int k = 0; k < 3; ++k) {
          vec2 c = base + 2.0 * float(k);
          vec2 da = (c - highPos) / (0.5 * s);
          vec2 db = (c + 1.0 - highPos) / (0.5 * s);
          vec2 wa = exp(-0.5 * da * da);
          vec2 wb = exp(-0.5 * db * db);
          weight[k] = max(wa + wb, vec2(1e-8));
          pos[k] = c + wb / weight[k];
        }
        vec4 sum = vec4(0.0);
        float wsum = 0.0;
        for (int y = 0; y < 3; ++y) {
          for (int x = 0; x < 3; ++x) {
            float w = weight[x].x * weight[y].y;
            sum += texture(u_supersample_texture, vec2(pos[x].x, pos[y].y) / size) * w;
            wsum += w;
          }
        }
        o_final_texture = sum / wsum;
      }
      """#

    let fragmentMSL = #"""
      //@main
      {
        float2 size = float2(u_supersample_texture.get_width(), u_supersample_texture.get_height());
        float2 s = u_supersampleScale.xy;
        float2 highPos = gl_FragCoord.xy * s;
        float2 base = floor(highPos - 0.5) - 1.5;
        float2 pos[3];
        float2 weight[3];
        for (int k = 0; k < 3; ++k) {
          float2 c = base + 2.0 * float(k);
          float2 da = (c - highPos) / (0.5 * s);
          float2 db = (c + 1.0 - highPos) / (0.5 * s);
          float2 wa = exp(-0.5 * da * da);
          float2 wb = exp(-0.5 * db * db);
          weight[k] = max(wa + wb, float2(1e-8));
          pos[k] = c + wb / weight[k];
        }
        float4 sum = float4(0.0);
        float wsum = 0.0;
        for (int y = 0; y < 3; ++y) {
          for (int x = 0; x < 3; ++x) {
            float w = weight[x].x * weight[y].y;
            sum += u_supersample_texture.sample(u_supersample_texture_smp, float2(pos[x].x, pos[y].y) / size) * w;
            wsum += w;
          }
        }
        o_final_texture = sum / wsum;
      }
      """#
  }
}
