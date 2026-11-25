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
  /// drawn by the `ssgi prep` pass
  struct SsgiPrepShader: FullscreenShader
  {
    let name = "ssgi-prep"

    var uniforms: [Declaration]
    {
      Sampler(GBuffer.position)
      Sampler(GBuffer.normal)
      Sampler(GBuffer.material)
      Sampler(HistoryBuffer.history)
      Uniforms.view
      Uniforms.prevViewProj
      Uniforms.taa
      Uniforms.ssgi
      Uniforms.halfScale
    }

    let fragmentGLSL = #"""
      vec3 finiteColor(vec3 c)
      {
        bvec3 bad = equal(floatBitsToUint(c) & 0x7F800000u, uvec3(0x7F800000u));
        return mix(clamp(c, 0.0, 65000.0), vec3(0.0), bad);
      }

      void main()
      {
        ivec2 fullSize = textureSize(u_position_texture, 0);
        ivec2 fp = min(ivec2(floor(gl_FragCoord.xy) * u_halfScale.xy), fullSize - 1);
        vec4 n = texelFetch(u_normal_texture, fp, 0);
        if (u_ssgi.z < 0.5 || n.a < 0.5) {
          o_ssgiDepth_texture = vec4(0.0);
          o_ssgiNormal_texture = vec4(0.0);
          o_ssgiRadiance_texture = vec4(0.0);
          return;
        }

        vec3 P = texelFetch(u_position_texture, fp, 0).xyz;
        vec2 uv = (vec2(fp) + 0.5) / vec2(fullSize);
        vec4 prevClip = u_prevViewProj * (inverse(u_view) * vec4(P, 1.0));
        vec2 prevUV = u_taa.x > 0.5 && prevClip.w > 0.0 ? prevClip.xy / prevClip.w * 0.5 + 0.5 : uv;

        vec3 radiance = finiteColor(texture(u_history_texture, clamp(prevUV, 0.0, 1.0)).rgb);
        radiance *= min(1.0, 16.0 / max(max(radiance.r, max(radiance.g, radiance.b)), 1e-4));

        o_ssgiDepth_texture = vec4(P.z, 0.0, 0.0, 0.0);
        o_ssgiNormal_texture = vec4(normalize(n.xyz), texelFetch(u_material_texture, fp, 0).r);
        o_ssgiRadiance_texture = vec4(radiance, 1.0);
      }
      """#

    let fragmentMSL = #"""
      float3 finiteColor(float3 c)
      {
        bool3 bad = (as_type<uint3>(c) & 0x7F800000u) == 0x7F800000u;
        return select(clamp(c, 0.0, 65000.0), float3(0.0), bad);
      }

      //@main
      {
        int2 fullSize = int2(u_position_texture.get_width(), u_position_texture.get_height());
        uint2 fp = uint2(min(int2(floor(gl_FragCoord.xy) * u_halfScale.xy), fullSize - 1));
        float4 n = u_normal_texture.read(fp);
        if (u_ssgi.z < 0.5 || n.a < 0.5) {
          o_ssgiDepth_texture = float4(0.0);
          o_ssgiNormal_texture = float4(0.0);
          o_ssgiRadiance_texture = float4(0.0);
        } else {
          float3 P = u_position_texture.read(fp).xyz;
          float2 uv = (float2(fp) + 0.5) / float2(fullSize);
          float3x3 invRot = float3x3(
            float3(u_view[0][0], u_view[1][0], u_view[2][0]),
            float3(u_view[0][1], u_view[1][1], u_view[2][1]),
            float3(u_view[0][2], u_view[1][2], u_view[2][2])
          );

          float3 world = invRot * (P - float3(u_view[3][0], u_view[3][1], u_view[3][2]));
          float4 prevClip = u_prevViewProj * float4(world, 1.0);
          float2 prevUV = u_taa.x > 0.5 && prevClip.w > 0.0 ? prevClip.xy / prevClip.w * 0.5 + 0.5 : uv;

          float3 radiance = finiteColor(texture(u_history_texture, clamp(prevUV, 0.0, 1.0)).rgb);
          radiance *= min(1.0, 16.0 / max(max(radiance.r, max(radiance.g, radiance.b)), 1e-4));

          o_ssgiDepth_texture = float4(P.z, 0.0, 0.0, 0.0);
          o_ssgiNormal_texture = float4(normalize(n.xyz), u_material_texture.read(fp).r);
          o_ssgiRadiance_texture = float4(radiance, 1.0);
        }
      }
      """#
  }
}
