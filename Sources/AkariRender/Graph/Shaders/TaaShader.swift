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
  /// drawn by the `taa` pass.
  struct TaaShader: FullscreenShader
  {
    let name = "taa"

    var uniforms: [Declaration]
    {
      Sampler(ColorBuffer.`final`)
      Sampler(HistoryBuffer.history)
      Sampler(GBuffer.position)
      Sampler(GBuffer.normal)
      Sampler(GBuffer.velocity)
      Uniforms.view
      Uniforms.invProj
      Uniforms.prevViewProj
      Uniforms.currViewProj
      Uniforms.taa
      Uniforms.taaJitter
    }

    let fragmentGLSL = #"""
      vec3 rgbToYCoCg(vec3 c)
      {
        return vec3(0.25 * c.r + 0.5 * c.g + 0.25 * c.b, 0.5 * c.r - 0.5 * c.b, -0.25 * c.r + 0.5 * c.g - 0.25 * c.b);
      }

      vec3 yCoCgToRgb(vec3 c)
      {
        return vec3(c.x + c.y - c.z, c.x + c.z, c.x - c.y - c.z);
      }

      vec3 finiteColor(vec3 c)
      {
        bvec3 bad = equal(floatBitsToUint(c) & 0x7F800000u, uvec3(0x7F800000u));
        return mix(clamp(c, 0.0, 65000.0), vec3(0.0), bad);
      }

      vec3 historyCatmullRom(vec2 uv, vec2 size)
      {
        vec2 samplePos = uv * size;
        vec2 texPos1 = floor(samplePos - 0.5) + 0.5;
        vec2 f = samplePos - texPos1;
        vec2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
        vec2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
        vec2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
        vec2 w3 = f * f * (-0.5 + 0.5 * f);
        vec2 w12 = w1 + w2;
        vec2 texPos0 = (texPos1 - 1.0) / size;
        vec2 texPos3 = (texPos1 + 2.0) / size;
        vec2 texPos12 = (texPos1 + w2 / w12) / size;
        vec3 result = texture(u_history_texture, vec2(texPos0.x, texPos12.y)).rgb * w0.x * w12.y
                    + texture(u_history_texture, vec2(texPos12.x, texPos0.y)).rgb * w12.x * w0.y
                    + texture(u_history_texture, texPos12).rgb * w12.x * w12.y
                    + texture(u_history_texture, vec2(texPos3.x, texPos12.y)).rgb * w3.x * w12.y
                    + texture(u_history_texture, vec2(texPos12.x, texPos3.y)).rgb * w12.x * w3.y;
        float weight = w0.x * w12.y + w12.x * w0.y + w12.x * w12.y + w3.x * w12.y + w12.x * w3.y;
        return finiteColor(result / weight);
      }

      vec3 downsampleInput(vec2 lowPos, ivec2 size, float s)
      {
        float sigma = 0.5 * s;
        int r = int(ceil(1.5 * s));
        ivec2 c = ivec2(floor(lowPos));
        vec3 sum = vec3(0.0);
        float wsum = 0.0;
        for (int y = -3; y <= 3; ++y) {
          for (int x = -3; x <= 3; ++x) {
            if (abs(x) > r || abs(y) > r) continue;
            ivec2 p = c + ivec2(x, y);
            vec2 d = vec2(p) + 0.5 - u_taaJitter.xy - lowPos;
            float w = exp(-dot(d, d) / (2.0 * sigma * sigma));
            sum += texelFetch(u_final_texture, clamp(p, ivec2(0), size - 1), 0).rgb * w;
            wsum += w;
          }
        }
        return sum / max(wsum, 1e-6);
      }

      void main()
      {
        ivec2 outSize = textureSize(u_history_texture, 0);
        ivec2 size = textureSize(u_final_texture, 0);
        vec2 uv = (gl_FragCoord.xy) / vec2(outSize);
        vec2 lowPos = uv * vec2(size);
        ivec2 pixel = clamp(ivec2(lowPos), ivec2(0), size - 1);
        bool downsample = size.x > outSize.x;
        vec3 current = downsample ? downsampleInput(lowPos, size, float(size.x) / float(outSize.x))
                                  : texelFetch(u_final_texture, pixel, 0).rgb;
        if (u_taa.x < 0.5) {
          o_final_texture = vec4(downsample ? current : texture(u_final_texture, uv).rgb, 1.0);
          return;
        }

        vec3 m1 = vec3(0.0), m2 = vec3(0.0);
        for (int y = -1; y <= 1; ++y) {
          for (int x = -1; x <= 1; ++x) {
            vec3 c = rgbToYCoCg(texelFetch(u_final_texture, clamp(pixel + ivec2(x, y), ivec2(0), size - 1), 0).rgb);
            m1 += c;
            m2 += c * c;
          }
        }
        vec3 mean = m1 / 9.0;
        vec3 sigma = sqrt(max(m2 / 9.0 - mean * mean, 0.0));
        vec3 boxMin = mean - 1.25 * sigma;
        vec3 boxMax = mean + 1.25 * sigma;

        vec3 posEye = texelFetch(u_position_texture, pixel, 0).xyz;
        if (texelFetch(u_normal_texture, pixel, 0).a < 0.5) {
          vec2 ndc = uv * 2.0 - 1.0;
          vec4 e = u_invProj * vec4(ndc, -1.0, 1.0);
          posEye = e.xyz / e.w;
        }
        vec4 world = inverse(u_view) * vec4(posEye, 1.0);
        vec4 prevClip = u_prevViewProj * world;
        vec4 currClip = u_currViewProj * world;
        vec2 motion = (prevClip.xy / prevClip.w - currClip.xy / currClip.w) * 0.5;
        if (texelFetch(u_normal_texture, pixel, 0).a >= 0.5) motion = texelFetch(u_velocity_texture, pixel, 0).xy;
        vec2 prevUV = uv + motion;
        bool offscreen = prevClip.w <= 0.0 || any(lessThan(prevUV, vec2(0.0))) || any(greaterThan(prevUV, vec2(1.0)));

        vec2 d = (lowPos - (vec2(pixel) + 0.5 - u_taaJitter.xy)) * vec2(outSize) / vec2(size);
        float closeness = exp(-2.0 * dot(d, d));
        vec3 cur = rgbToYCoCg(current);
        vec3 history = clamp(rgbToYCoCg(historyCatmullRom(clamp(prevUV, 0.0, 1.0), vec2(outSize))), boxMin, boxMax);
        float upscale = float(outSize.x * outSize.y) / float(size.x * size.y);
        float alpha = (u_taa.y > 0.5 || offscreen) ? 1.0 : min(1.0, u_taa.z * upscale * closeness);
        float wc = alpha / (1.0 + cur.x);
        float wh = (1.0 - alpha) / (1.0 + history.x);
        o_final_texture = vec4(yCoCgToRgb((cur * wc + history * wh) / (wc + wh)), 1.0);
      }
      """#

    let fragmentMSL = #"""
      float3 rgbToYCoCg(float3 c)
      {
        return float3(0.25 * c.r + 0.5 * c.g + 0.25 * c.b, 0.5 * c.r - 0.5 * c.b, -0.25 * c.r + 0.5 * c.g - 0.25 * c.b);
      }

      float3 yCoCgToRgb(float3 c)
      {
        return float3(c.x + c.y - c.z, c.x + c.z, c.x - c.y - c.z);
      }

      float3 finiteColor(float3 c)
      {
        bool3 bad = (as_type<uint3>(c) & 0x7F800000u) == 0x7F800000u;
        return select(clamp(c, 0.0, 65000.0), float3(0.0), bad);
      }

      float3 historyCatmullRom(texture2d<float> history, sampler smp, float2 uv, float2 size)
      {
        float2 samplePos = uv * size;
        float2 texPos1 = floor(samplePos - 0.5) + 0.5;
        float2 f = samplePos - texPos1;
        float2 w0 = f * (-0.5 + f * (1.0 - 0.5 * f));
        float2 w1 = 1.0 + f * f * (-2.5 + 1.5 * f);
        float2 w2 = f * (0.5 + f * (2.0 - 1.5 * f));
        float2 w3 = f * f * (-0.5 + 0.5 * f);
        float2 w12 = w1 + w2;
        float2 texPos0 = (texPos1 - 1.0) / size;
        float2 texPos3 = (texPos1 + 2.0) / size;
        float2 texPos12 = (texPos1 + w2 / w12) / size;
        float3 result = history.sample(smp, float2(texPos0.x, texPos12.y)).rgb * w0.x * w12.y
                      + history.sample(smp, float2(texPos12.x, texPos0.y)).rgb * w12.x * w0.y
                      + history.sample(smp, texPos12).rgb * w12.x * w12.y
                      + history.sample(smp, float2(texPos3.x, texPos12.y)).rgb * w3.x * w12.y
                      + history.sample(smp, float2(texPos12.x, texPos3.y)).rgb * w12.x * w3.y;
        float weight = w0.x * w12.y + w12.x * w0.y + w12.x * w12.y + w3.x * w12.y + w12.x * w3.y;
        return finiteColor(result / weight);
      }

      float3 downsampleInput(texture2d<float> tex, float2 lowPos, int2 size, float s, float2 jitter)
      {
        float sigma = 0.5 * s;
        int r = int(ceil(1.5 * s));
        int2 c = int2(floor(lowPos));
        float3 sum = float3(0.0);
        float wsum = 0.0;
        for (int y = -3; y <= 3; ++y) {
          for (int x = -3; x <= 3; ++x) {
            if (abs(x) > r || abs(y) > r) continue;
            int2 p = c + int2(x, y);
            float2 d = float2(p) + 0.5 - jitter - lowPos;
            float w = exp(-dot(d, d) / (2.0 * sigma * sigma));
            sum += tex.read(uint2(clamp(p, int2(0), size - 1))).rgb * w;
            wsum += w;
          }
        }
        return sum / max(wsum, 1e-6);
      }

      //@main
      {
        int2 outSize = int2(u_history_texture.get_width(), u_history_texture.get_height());
        int2 size = int2(u_final_texture.get_width(), u_final_texture.get_height());
        float2 uv = gl_FragCoord.xy / float2(outSize);
        float2 lowPos = uv * float2(size);
        int2 pixel = clamp(int2(lowPos), int2(0), size - 1);
        bool downsample = size.x > outSize.x;
        float3 current = downsample ? downsampleInput(u_final_texture, lowPos, size, float(size.x) / float(outSize.x),
                                                      u_taaJitter.xy)
                                    : u_final_texture.read(uint2(pixel)).rgb;
        if (u_taa.x < 0.5) {
          o_final_texture = float4(downsample ? current : u_final_texture.sample(u_final_texture_smp, uv).rgb, 1.0);
        } else {
          float3 m1 = float3(0.0), m2 = float3(0.0);
          for (int y = -1; y <= 1; ++y) {
            for (int x = -1; x <= 1; ++x) {
              float3 c = rgbToYCoCg(u_final_texture.read(uint2(clamp(pixel + int2(x, y), int2(0), size - 1))).rgb);
              m1 += c;
              m2 += c * c;
            }
          }
          float3 mean = m1 / 9.0;
          float3 sigma = sqrt(max(m2 / 9.0 - mean * mean, 0.0));
          float3 boxMin = mean - 1.25 * sigma;
          float3 boxMax = mean + 1.25 * sigma;

          float3 posEye = u_position_texture.read(uint2(pixel)).xyz;
          if (u_normal_texture.read(uint2(pixel)).a < 0.5) {
            float2 ndc = uv * 2.0 - 1.0;
            float4 e = u_invProj * float4(ndc, -1.0, 1.0);
            posEye = normalize(e.xyz / e.w) * 1e7;
          }
          float3x3 invView = float3x3(
            float3(u_view[0][0], u_view[1][0], u_view[2][0]),
            float3(u_view[0][1], u_view[1][1], u_view[2][1]),
            float3(u_view[0][2], u_view[1][2], u_view[2][2])
          );
          float3 world = invView * (posEye - float3(u_view[3][0], u_view[3][1], u_view[3][2]));
          float4 prevClip = u_prevViewProj * float4(world, 1.0);
          float4 currClip = u_currViewProj * float4(world, 1.0);
          float2 motion = (prevClip.xy / prevClip.w - currClip.xy / currClip.w) * 0.5;
          if (u_normal_texture.read(uint2(pixel)).a >= 0.5) motion = u_velocity_texture.read(uint2(pixel)).xy;
          if (u_taa.w > 0.5) motion = float2(0.0);
          float2 prevUV = uv + motion;
          bool offscreen = prevClip.w <= 0.0 || any(prevUV < float2(0.0)) || any(prevUV > float2(1.0));

          float2 d = (lowPos - (float2(pixel) + 0.5 - u_taaJitter.xy)) * float2(outSize) / float2(size);
          float closeness = exp(-2.0 * dot(d, d));
          float3 cur = rgbToYCoCg(current);
          float3 history = rgbToYCoCg(historyCatmullRom(u_history_texture, u_history_texture_smp,
                                                        clamp(prevUV, 0.0, 1.0), float2(outSize)));
          if (u_taa.w < 0.5) history = clamp(history, boxMin, boxMax);
          float upscale = float(outSize.x * outSize.y) / float(size.x * size.y);
          float alpha = (u_taa.y > 0.5 || offscreen) ? 1.0 : min(1.0, u_taa.z * upscale * closeness);
          float wc = alpha / (1.0 + cur.x);
          float wh = (1.0 - alpha) / (1.0 + history.x);
          o_final_texture = float4(yCoCgToRgb((cur * wc + history * wh) / (wc + wh)), 1.0);
        }
      }
      """#
  }
}
