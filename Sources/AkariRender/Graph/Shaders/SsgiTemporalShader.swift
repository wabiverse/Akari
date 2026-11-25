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
  /// drawn by the `ssgi temporal` pass.
  struct SsgiTemporalShader: FullscreenShader
  {
    let name = "ssgi-temporal"

    var uniforms: [Declaration]
    {
      Sampler(SsgiBuffer.ssgiRaw)
      Sampler(SsgiBuffer.ssgiSpecRaw)
      Sampler(SsgiBuffer.ssgiBentRaw)
      Sampler(SsgiHistoryBuffer.ssgiHistory)
      Sampler(SsgiHistoryBuffer.ssgiSpecHistory)
      Sampler(SsgiHistoryBuffer.ssgiBentHistory)
      Sampler(SsgiPrepBuffer.ssgiDepth)
      Sampler(SsgiPrepBuffer.ssgiNormal)
      Uniforms.view
      Uniforms.proj
      Uniforms.prevViewProj
      Uniforms.currViewProj
      Uniforms.taa
      Uniforms.ssgi
      Uniforms.ssgiSize
    }

    let fragmentGLSL = #"""
      vec3 finiteColor(vec3 c)
      {
        bvec3 bad = equal(floatBitsToUint(c) & 0x7F800000u, uvec3(0x7F800000u));
        return mix(clamp(c, 0.0, 65000.0), vec3(0.0), bad);
      }

      vec3 viewPosition(vec2 uv, float z)
      {
        vec2 ndc = uv * 2.0 - 1.0;
        float w = u_proj[2][3] * z + u_proj[3][3];
        return vec3((ndc.x * w - u_proj[2][0] * z - u_proj[3][0]) / u_proj[0][0],
                    (ndc.y * w - u_proj[2][1] * z - u_proj[3][1]) / u_proj[1][1], z);
      }

      void main()
      {
        ivec2 hp = ivec2(gl_FragCoord.xy);
        ivec2 halfSize = textureSize(u_ssgiRaw_texture, 0);
        float zc = texelFetch(u_ssgiDepth_texture, hp, 0).x;
        if (u_ssgi.z < 0.5 || zc >= 0.0) {
          o_ssgiAccum_texture = vec4(0.0, 0.0, 0.0, 1.0);
          o_ssgiSpecAccum_texture = vec4(0.0, 0.0, 0.0, 1.0);
          o_ssgiBentAccum_texture = vec4(0.0);
          return;
        }
        vec3 pc = viewPosition((vec2(hp * 2) + 0.5) * u_ssgiSize.zw, zc);
        vec3 nc = texelFetch(u_ssgiNormal_texture, hp, 0).xyz;
        float planeScale = 1.0 / max(0.01 * abs(zc), 1e-3);
        vec4 m1 = vec4(0.0), m2 = vec4(0.0), s1 = vec4(0.0), s2 = vec4(0.0);
        float wsum = 0.0;
        for (int y = -1; y <= 1; ++y) {
          for (int x = -1; x <= 1; ++x) {
            ivec2 h = clamp(hp + ivec2(x, y) * 2, ivec2(0), halfSize - 1);
            float zs = texelFetch(u_ssgiDepth_texture, h, 0).x;
            if (zs >= 0.0) continue;
            vec3 ps = viewPosition((vec2(h * 2) + 0.5) * u_ssgiSize.zw, zs);
            float plane = abs(dot(nc, ps - pc)) * planeScale;
            float w = exp(-plane) * pow(max(dot(nc, texelFetch(u_ssgiNormal_texture, h, 0).xyz), 0.0), 8.0);
            vec4 c = texelFetch(u_ssgiRaw_texture, h, 0);
            vec4 cs = texelFetch(u_ssgiSpecRaw_texture, h, 0);
            m1 += c * w;
            m2 += c * c * w;
            s1 += cs * w;
            s2 += cs * cs * w;
            wsum += w;
          }
        }
        vec4 mean = m1 / max(wsum, 1e-4);
        vec4 sigma = sqrt(max(m2 / max(wsum, 1e-4) - mean * mean, 0.0));
        vec4 specMean = s1 / max(wsum, 1e-4);
        vec4 specSigma = sqrt(max(s2 / max(wsum, 1e-4) - specMean * specMean, 0.0));
        vec4 current = mean;
        if (u_taa.x < 0.5) {
          o_ssgiAccum_texture = current;
          o_ssgiSpecAccum_texture = specMean;
          o_ssgiBentAccum_texture = texelFetch(u_ssgiBentRaw_texture, hp, 0);
          return;
        }
        vec4 world = inverse(u_view) * vec4(pc, 1.0);
        vec4 prevClip = u_prevViewProj * world;
        vec4 currClip = u_currViewProj * world;
        vec2 prevUV = (vec2(hp) + 0.5) / vec2(halfSize)
                    + (prevClip.xy / prevClip.w - currClip.xy / currClip.w) * 0.5;
        bool offscreen = prevClip.w <= 0.0 || any(lessThan(prevUV, vec2(0.0))) || any(greaterThan(prevUV, vec2(1.0)));
        vec4 history = texture(u_ssgiHistory_texture, clamp(prevUV, 0.0, 1.0));
        history = clamp(vec4(finiteColor(history.rgb), finiteColor(history.aaa).x),
                        mean - 1.5 * sigma, mean + 1.5 * sigma);
        vec4 specHistory = texture(u_ssgiSpecHistory_texture, clamp(prevUV, 0.0, 1.0));
        specHistory = clamp(vec4(finiteColor(specHistory.rgb), finiteColor(specHistory.aaa).x),
                            specMean - 1.5 * specSigma, specMean + 1.5 * specSigma);
        float blend = (u_taa.y > 0.5 || u_ssgi.w > 0.5 || offscreen) ? 1.0 : 0.1;
        o_ssgiAccum_texture = mix(history, current, blend);
        o_ssgiSpecAccum_texture = mix(specHistory, specMean, blend);
        o_ssgiBentAccum_texture = texelFetch(u_ssgiBentRaw_texture, hp, 0);
      }
      """#

    let fragmentMSL = #"""
      float3 finiteColor(float3 c)
      {
        bool3 bad = (as_type<uint3>(c) & 0x7F800000u) == 0x7F800000u;
        return select(clamp(c, 0.0, 65000.0), float3(0.0), bad);
      }

      float3 viewPosition(float2 uv, float z, float4x4 proj)
      {
        float2 ndc = uv * 2.0 - 1.0;
        float w = proj[2][3] * z + proj[3][3];
        return float3((ndc.x * w - proj[2][0] * z - proj[3][0]) / proj[0][0],
                      (ndc.y * w - proj[2][1] * z - proj[3][1]) / proj[1][1], z);
      }

      //@main
      {
        int2 hp = int2(gl_FragCoord.xy);
        int2 halfSize = int2(u_ssgiRaw_texture.get_width(), u_ssgiRaw_texture.get_height());
        float zc = u_ssgiDepth_texture.read(uint2(hp)).x;
        if (u_ssgi.z < 0.5 || zc >= 0.0) {
          o_ssgiAccum_texture = float4(0.0, 0.0, 0.0, 1.0);
          o_ssgiSpecAccum_texture = float4(0.0, 0.0, 0.0, 1.0);
          o_ssgiBentAccum_texture = float4(0.0);
        } else {
          float3 pc = viewPosition((float2(hp * 2) + 0.5) * u_ssgiSize.zw, zc, u_proj);
          float3 nc = u_ssgiNormal_texture.read(uint2(hp)).xyz;
          float planeScale = 1.0 / max(0.01 * abs(zc), 1e-3);
          float4 m1 = float4(0.0), m2 = float4(0.0), s1 = float4(0.0), s2 = float4(0.0), b1 = float4(0.0);
          float wsum = 0.0;
          for (int y = -1; y <= 1; ++y) {
            for (int x = -1; x <= 1; ++x) {
              int2 h = clamp(hp + int2(x, y) * 2, int2(0), halfSize - 1);
              float zs = u_ssgiDepth_texture.read(uint2(h)).x;
              if (zs >= 0.0) continue;
              float3 ps = viewPosition((float2(h * 2) + 0.5) * u_ssgiSize.zw, zs, u_proj);
              float plane = abs(dot(nc, ps - pc)) * planeScale;
              float w = exp(-plane) * pow(max(dot(nc, u_ssgiNormal_texture.read(uint2(h)).xyz), 0.0), 8.0);
              float4 c = u_ssgiRaw_texture.read(uint2(h));
              float4 cs = u_ssgiSpecRaw_texture.read(uint2(h));
              m1 += c * w;
              m2 += c * c * w;
              s1 += cs * w;
              s2 += cs * cs * w;
              b1 += u_ssgiBentRaw_texture.read(uint2(h)) * w;
              wsum += w;
            }
          }
          float4 mean = m1 / max(wsum, 1e-4);
          float4 sigma = sqrt(max(m2 / max(wsum, 1e-4) - mean * mean, 0.0));
          float4 specMean = s1 / max(wsum, 1e-4);
          float4 specSigma = sqrt(max(s2 / max(wsum, 1e-4) - specMean * specMean, 0.0));
          float4 bentMean = b1 / max(wsum, 1e-4);
          float4 current = mean;
          if (u_taa.x < 0.5) {
            o_ssgiAccum_texture = current;
            o_ssgiSpecAccum_texture = specMean;
            o_ssgiBentAccum_texture = bentMean;
          } else {
            float3x3 invRot = float3x3(
              float3(u_view[0][0], u_view[1][0], u_view[2][0]),
              float3(u_view[0][1], u_view[1][1], u_view[2][1]),
              float3(u_view[0][2], u_view[1][2], u_view[2][2])
            );
            float3 world = invRot * (pc - float3(u_view[3][0], u_view[3][1], u_view[3][2]));
            float4 prevClip = u_prevViewProj * float4(world, 1.0);
            float4 currClip = u_currViewProj * float4(world, 1.0);
            float2 prevUV = (float2(hp) + 0.5) / float2(halfSize)
                          + (prevClip.xy / prevClip.w - currClip.xy / currClip.w) * 0.5;
            bool offscreen = prevClip.w <= 0.0 || any(prevUV < float2(0.0)) || any(prevUV > float2(1.0));
            float4 history = texture(u_ssgiHistory_texture, clamp(prevUV, 0.0, 1.0));
            history = clamp(float4(finiteColor(history.rgb), finiteColor(history.aaa).x),
                            mean - 1.5 * sigma, mean + 1.5 * sigma);
            float4 specHistory = texture(u_ssgiSpecHistory_texture, clamp(prevUV, 0.0, 1.0));
            specHistory = clamp(float4(finiteColor(specHistory.rgb), finiteColor(specHistory.aaa).x),
                                specMean - 1.5 * specSigma, specMean + 1.5 * specSigma);
            float blend = (u_taa.y > 0.5 || u_ssgi.w > 0.5 || offscreen) ? 1.0 : 0.1;
            o_ssgiAccum_texture = mix(history, current, blend);
            o_ssgiSpecAccum_texture = mix(specHistory, specMean, blend);
            o_ssgiBentAccum_texture = mix(texture(u_ssgiBentHistory_texture, clamp(prevUV, 0.0, 1.0)), bentMean, blend);
          }
        }
      }
      """#
  }
}
