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
  /// drawn by the `upscale sanitize` pass.
  struct UpscaleSanitizeShader: FullscreenShader
  {
    let name = "upscale-sanitize"

    var uniforms: [Declaration]
    {
      Sampler(ColorBuffer.`final`)
      Sampler(GBuffer.position)
      Sampler(GBuffer.normal)
      Sampler(GBuffer.velocity)
      Uniforms.view
      Uniforms.invProj
      Uniforms.prevViewProj
      Uniforms.currViewProj
    }

    let fragmentGLSL = #"""
      void main()
      {
        ivec2 p = ivec2(gl_FragCoord.xy);
        o_upscaleColor_texture = texelFetch(u_final_texture, p, 0);
        vec2 motion = texelFetch(u_velocity_texture, p, 0).xy;
        if (texelFetch(u_normal_texture, p, 0).a < 0.5) {
          vec4 e = u_invProj * vec4(gl_FragCoord.xy / vec2(textureSize(u_final_texture, 0)) * 2.0 - 1.0, -1.0, 1.0);
          vec3 posEye = normalize(e.xyz / e.w) * 1e7;
          vec4 world = inverse(u_view) * vec4(posEye, 1.0);
          vec4 prevClip = u_prevViewProj * world;
          vec4 currClip = u_currViewProj * world;
          motion = prevClip.w > 0.0 ? (prevClip.xy / prevClip.w - currClip.xy / currClip.w) * 0.5 : vec2(0.0);
        }
        bool finite = !any(isnan(motion)) && !any(isinf(motion));
        o_upscaleVelocity_texture = vec4(finite ? clamp(motion, -2.0, 2.0) : vec2(0.0), 0.0, 0.0);
      }
      """#

    let fragmentMSL = #"""
      //@main
      {
        // metalfx's neural pass fails on nan or inf, so it only ever sees finite bounded color
        float4 c = u_final_texture.read(uint2(gl_FragCoord.xy));
        o_upscaleColor_texture = float4(select(float3(0.0), clamp(c.rgb, float3(0.0), float3(65000.0)), isfinite(c.rgb)), 1.0);

        // the sky has no geometry to give it motion, metalfx would hold it still under a turning camera.
        uint2 p = uint2(gl_FragCoord.xy);
        float2 motion = u_velocity_texture.read(p).xy;
        if (u_normal_texture.read(p).a < 0.5) {
          float2 size = float2(u_final_texture.get_width(), u_final_texture.get_height());
          float4 e = u_invProj * float4(gl_FragCoord.xy / size * 2.0 - 1.0, -1.0, 1.0);
          float3 posEye = normalize(e.xyz / e.w) * 1e7;
          float3x3 invView = float3x3(
            float3(u_view[0][0], u_view[1][0], u_view[2][0]),
            float3(u_view[0][1], u_view[1][1], u_view[2][1]),
            float3(u_view[0][2], u_view[1][2], u_view[2][2])
          );
          float3 world = invView * (posEye - float3(u_view[3][0], u_view[3][1], u_view[3][2]));
          float4 prevClip = u_prevViewProj * float4(world, 1.0);
          float4 currClip = u_currViewProj * float4(world, 1.0);
          motion = prevClip.w > 0.0 ? (prevClip.xy / prevClip.w - currClip.xy / currClip.w) * 0.5 : float2(0.0);
        }

        // clamp motion too since metalfx scales it in half precision and large values overflow.
        o_upscaleVelocity_texture = float4(clamp(select(float2(0.0), motion, isfinite(motion)), -2.0, 2.0), 0.0, 0.0);
      }
      """#
  }
}
