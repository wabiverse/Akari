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
  /// drawn by the `aov` pass.
  struct AovShader: FullscreenShader
  {
    let name = "aov"

    var uniforms: [Declaration]
    {
      Sampler(GBuffer.position)
      Sampler(GBuffer.normal)
      Uniforms.aovProjection
      Uniforms.renderScale
    }

    let fragmentGLSL = #"""
      void main()
      {
        ivec2 pixel = ivec2(gl_FragCoord.xy * u_renderScale.xy);
        vec4 p = texelFetch(u_position_texture, pixel, 0);
        bool hit = texelFetch(u_normal_texture, pixel, 0).a >= 0.5;
        float ndc = (u_aovProjection.x * p.z + u_aovProjection.y) / max(-p.z, 1e-6);
        o_aovPrimId_texture = ivec4(hit ? int(round(p.w)) : -1);
        o_aovInstanceId_texture = ivec4(-1);
        o_aovDepth_texture = vec4(hit ? clamp(ndc * 0.5 + 0.5, 0.0, 0.999999) : 1.0);
      }
      """#

    let fragmentMSL = #"""
      //@main
      {
        uint2 pixel = uint2(gl_FragCoord.xy * u_renderScale.xy);
        float4 p = u_position_texture.read(pixel);
        bool hit = u_normal_texture.read(pixel).a >= 0.5;
        float ndc = (u_aovProjection.x * p.z + u_aovProjection.y) / max(-p.z, 1e-6);
        o_aovPrimId_texture = int4(hit ? int(round(p.w)) : -1);
        o_aovInstanceId_texture = int4(-1);
        o_aovDepth_texture = float4(hit ? clamp(ndc * 0.5 + 0.5, 0.0, 0.999999) : 1.0);
      }
      """#
  }
}
