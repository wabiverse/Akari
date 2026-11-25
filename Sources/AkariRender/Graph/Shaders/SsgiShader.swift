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
  /// drawn by the `ssgi` pass
  struct SsgiShader: FullscreenShader
  {
    let name = "ssgi"

    var uniforms: [Declaration]
    {
      Sampler(SsgiPrepBuffer.ssgiDepth)
      Sampler(SsgiPrepBuffer.ssgiNormal)
      Sampler(SsgiPrepBuffer.ssgiRadiance)
      Sampler(SsgiPyramidBuffer.ssgiPyramidDepth)
      Sampler(SsgiPyramidBuffer.ssgiPyramidNormal)
      Sampler(SsgiPyramidBuffer.ssgiPyramidRadiance)
      Uniforms.proj
      Uniforms.ssgi
      Uniforms.ssgiSize
      Uniforms.frameIndex
    }

    let fragmentGLSL = #"""
      const float PI = 3.14159265358979;

      ivec2 ssgiPyramidOffset(int lod, ivec2 full)
      {
        return lod == 2 ? ivec2(full.x >> 2, 0) : lod == 3 ? ivec2(full.x >> 2, full.y >> 3) : ivec2(0);
      }

      float fastAcos(float x)
      {
        float r = (-0.156583 * abs(x) + 0.5 * PI) * sqrt(1.0 - abs(x));
        return x >= 0.0 ? r : PI - r;
      }

      vec3 viewPosition(vec2 uv, float z)
      {
        vec2 ndc = uv * 2.0 - 1.0;
        float w = u_proj[2][3] * z + u_proj[3][3];
        return vec3((ndc.x * w - u_proj[2][0] * z - u_proj[3][0]) / u_proj[0][0],
                    (ndc.y * w - u_proj[2][1] * z - u_proj[3][1]) / u_proj[1][1], z);
      }

      uint ssgiSectors(float lo, float hi)
      {
        uint start = uint(clamp(lo, 0.0, 1.0) * 32.0);
        uint count = uint(ceil(clamp(hi - lo, 0.0, 1.0) * 32.0));
        if (start >= 32u || count == 0u) return 0u;
        count = min(count, 32u - start);
        return (count >= 32u ? 0xFFFFFFFFu : ((1u << count) - 1u)) << start;
      }

      void main()
      {
        ivec2 hp = ivec2(gl_FragCoord.xy);
        ivec2 halfSize = textureSize(u_ssgiDepth_texture, 0);
        float zc = texelFetch(u_ssgiDepth_texture, hp, 0).x;
        if (u_ssgi.z < 0.5 || zc >= 0.0) {
          o_ssgiRaw_texture = vec4(0.0, 0.0, 0.0, 1.0);
          o_ssgiSpecRaw_texture = vec4(0.0, 0.0, 0.0, 1.0);
          o_ssgiBentRaw_texture = vec4(0.0);
          return;
        }

        vec2 uv = (vec2(hp * 2) + 0.5) * u_ssgiSize.zw;
        vec3 P = viewPosition(uv, zc);
        vec4 normalRoughness = texelFetch(u_ssgiNormal_texture, hp, 0);
        vec3 N = normalRoughness.xyz;
        vec3 V = normalize(-P);
        float alpha = clamp(normalRoughness.w, 0.045, 1.0);
        alpha *= alpha;
        vec3 Rd = normalize(mix(reflect(-V, N), N, alpha * alpha));

        vec2 noisePixel = gl_FragCoord.xy + 5.588238 * float(frameIndex % 64);
        float noise = fract(52.9829189 * fract(dot(noisePixel, vec2(0.06711056, 0.00583715))));
        vec2 scale = vec2(u_proj[0][0], u_proj[1][1]) * 0.5 * u_ssgi.x / max(-P.z, 1e-3);
        scale *= min(1.0, 0.25 / max(length(scale), 1e-6));

        vec3 lighting = vec3(0.0);
        float visibility = 0.0;
        vec3 specLighting = vec3(0.0);
        float specVisibility = 0.0;
        for (int slice = 0; slice < 2; ++slice) {
          float phi = (float(slice) + noise) * (PI / 2.0);
          vec2 omega = vec2(cos(phi), sin(phi));
          vec3 direction = vec3(omega, 0.0);
          vec3 ortho = normalize(direction - dot(direction, V) * V);
          vec3 axis = normalize(cross(direction, V));
          vec3 projN = N - axis * dot(N, axis);
          float n = sign(dot(ortho, projN)) * fastAcos(clamp(dot(projN, V) / max(length(projN), 1e-4), -1.0, 1.0));
          uint mask = 0u;

          vec3 projR = Rd - axis * dot(Rd, axis);
          float nr = sign(dot(ortho, projR)) * fastAcos(clamp(dot(projR, V) / max(length(projR), 1e-4), -1.0, 1.0));
          vec2 below = 0.5 + 0.5 * sin(clamp(vec2(n - 0.5 * PI, n + 0.5 * PI) - nr, -0.5 * PI, 0.5 * PI));
          uint belowR = ssgiSectors(0.0, below.x) | ssgiSectors(below.y, 1.0);
          uint maskR = belowR;
          vec3 specSlice = vec3(0.0);

          for (int side = 0; side < 2; ++side) {
            float s = side == 0 ? 1.0 : -1.0;
            for (int k = 0; k < 8; ++k) {
              float t = (float(k) + fract(noise + 0.618034 * float(k + side * 8))) / 8.0;
              vec2 suv = uv + s * omega * (scale * (t * t) + 2.0 * u_ssgiSize.zw);
              if (any(lessThan(suv, vec2(0.0))) || any(greaterThanEqual(suv, vec2(1.0)))) break;

              int lod = clamp(int(log2(max(length((suv - uv) * vec2(halfSize)), 1.0)) - 2.0), 0, 3);
              ivec2 full = ivec2(u_ssgiSize.xy);
              ivec2 sp = min(ivec2(suv * u_ssgiSize.xy) >> (lod + 1), (full >> (lod + 1)) - 1);
              if (lod == 0 && sp == hp) continue;
              ivec2 ap = sp + ssgiPyramidOffset(lod, full);
              float zs = lod == 0 ? texelFetch(u_ssgiDepth_texture, sp, 0).x
                                  : texelFetch(u_ssgiPyramidDepth_texture, ap, 0).x;
              if (zs >= 0.0) continue;
              vec2 suvc = (vec2(sp * (2 << lod)) + float(1 << lod) - 0.5) * u_ssgiSize.zw;

              vec3 delta = viewPosition(suvc, zs) - P;
              float dist = length(delta);
              if (dist < 1e-4) continue;
              vec3 h = delta / dist;
              vec3 back = normalize(delta - V * u_ssgi.y);
              vec2 angles = s * vec2(fastAcos(clamp(dot(h, V), -1.0, 1.0)), fastAcos(clamp(dot(back, V), -1.0, 1.0)));
              vec2 sectors = 0.5 + 0.5 * sin(clamp(angles - n, -0.5 * PI, 0.5 * PI));
              uint bits = ssgiSectors(min(sectors.x, sectors.y), max(sectors.x, sectors.y));
              uint fresh = bits & ~mask;
              mask |= bits;
              vec2 sectorsR = 0.5 + 0.5 * sin(clamp(angles - nr, -0.5 * PI, 0.5 * PI));
              uint freshR = ssgiSectors(min(sectorsR.x, sectorsR.y), max(sectorsR.x, sectorsR.y)) & ~maskR;
              maskR |= freshR;
              if (fresh == 0u && freshR == 0u) continue;

              vec3 ns = lod == 0 ? texelFetch(u_ssgiNormal_texture, sp, 0).xyz
                                 : texelFetch(u_ssgiPyramidNormal_texture, ap, 0).xyz;
              vec3 radiance = lod == 0 ? texelFetch(u_ssgiRadiance_texture, sp, 0).rgb
                                       : texelFetch(u_ssgiPyramidRadiance_texture, ap, 0).rgb;
              radiance *= clamp(dot(ns, -h) * 4.0, 0.0, 1.0);
              lighting += float(bitCount(fresh)) / 32.0 * radiance;
              specSlice += float(bitCount(freshR)) / 32.0 * radiance;
            }
          }

          visibility += 1.0 - float(bitCount(mask)) / 32.0;

          float validR = max(32.0 - float(bitCount(belowR)), 1.0);
          specLighting += specSlice * (32.0 / validR);
          specVisibility += (32.0 - float(bitCount(maskR))) / validR;
        }

        o_ssgiRaw_texture = vec4(lighting * 0.5, visibility * 0.5);
        o_ssgiSpecRaw_texture = vec4(specLighting * 0.5, specVisibility * 0.5);
        o_ssgiBentRaw_texture = vec4(N, 1.0);
      }
      """#

    let fragmentMSL = #"""
      constexpr constant float PI = 3.14159265358979;

      int2 ssgiPyramidOffset(int lod, int2 full)
      {
        return lod == 2 ? int2(full.x >> 2, 0) : lod == 3 ? int2(full.x >> 2, full.y >> 3) : int2(0);
      }

      float fastAcos(float x)
      {
        float r = (-0.156583 * abs(x) + 0.5 * PI) * sqrt(1.0 - abs(x));
        return x >= 0.0 ? r : PI - r;
      }

      float3 viewPosition(float2 uv, float z, float4x4 proj)
      {
        float2 ndc = uv * 2.0 - 1.0;
        float w = proj[2][3] * z + proj[3][3];
        return float3((ndc.x * w - proj[2][0] * z - proj[3][0]) / proj[0][0],
                      (ndc.y * w - proj[2][1] * z - proj[3][1]) / proj[1][1], z);
      }

      uint ssgiSectors(float lo, float hi)
      {
        uint start = uint(clamp(lo, 0.0, 1.0) * 32.0);
        uint count = uint(ceil(clamp(hi - lo, 0.0, 1.0) * 32.0));
        if (start >= 32u || count == 0u) return 0u;
        count = min(count, 32u - start);
        return (count >= 32u ? 0xFFFFFFFFu : ((1u << count) - 1u)) << start;
      }

      //@main
      {
        int2 hp = int2(gl_FragCoord.xy);
        int2 halfSize = int2(u_ssgiDepth_texture.get_width(), u_ssgiDepth_texture.get_height());
        float zc = u_ssgiDepth_texture.read(uint2(hp)).x;
        if (u_ssgi.z < 0.5 || zc >= 0.0) {
          o_ssgiRaw_texture = float4(0.0, 0.0, 0.0, 1.0);
          o_ssgiSpecRaw_texture = float4(0.0, 0.0, 0.0, 1.0);
          o_ssgiBentRaw_texture = float4(0.0);
        } else {
          float2 uv = (float2(hp * 2) + 0.5) * u_ssgiSize.zw;
          float3 P = viewPosition(uv, zc, u_proj);
          float4 normalRoughness = u_ssgiNormal_texture.read(uint2(hp));
          float3 N = normalRoughness.xyz;
          float3 V = normalize(-P);
          float alpha = clamp(normalRoughness.w, 0.045, 1.0);
          alpha *= alpha;
          float3 Rd = normalize(mix(reflect(-V, N), N, alpha * alpha));

          float2 noisePixel = gl_FragCoord.xy + 5.588238 * float(frameIndex % 64);
          float noise = fract(52.9829189 * fract(dot(noisePixel, float2(0.06711056, 0.00583715))));
          float2 scale = float2(u_proj[0][0], u_proj[1][1]) * 0.5 * u_ssgi.x / max(-P.z, 1e-3);
          scale *= min(1.0, 0.25 / max(length(scale), 1e-6));

          float3 lighting = float3(0.0);
          float visibility = 0.0;
          float3 specLighting = float3(0.0);
          float specVisibility = 0.0;
          float3 bent = float3(0.0);
          for (int slice = 0; slice < 2; ++slice) {
            float phi = (float(slice) + noise) * (PI / 2.0);
            float2 omega = float2(cos(phi), sin(phi));
            float3 direction = float3(omega, 0.0);
            float3 ortho = normalize(direction - dot(direction, V) * V);
            float3 axis = normalize(cross(direction, V));
            float3 projN = N - axis * dot(N, axis);
            float n = sign(dot(ortho, projN)) * fastAcos(clamp(dot(projN, V) / max(length(projN), 1e-4), -1.0, 1.0));
            uint mask = 0u;

            float3 projR = Rd - axis * dot(Rd, axis);
            float nr = sign(dot(ortho, projR)) * fastAcos(clamp(dot(projR, V) / max(length(projR), 1e-4), -1.0, 1.0));
            float2 below = 0.5 + 0.5 * sin(clamp(float2(n - 0.5 * PI, n + 0.5 * PI) - nr, -0.5 * PI, 0.5 * PI));
            uint belowR = ssgiSectors(0.0, below.x) | ssgiSectors(below.y, 1.0);
            uint maskR = belowR;
            float3 specSlice = float3(0.0);

            for (int side = 0; side < 2; ++side) {
              float s = side == 0 ? 1.0 : -1.0;
              for (int k = 0; k < 8; ++k) {
                float t = (float(k) + fract(noise + 0.618034 * float(k + side * 8))) / 8.0;
                float2 suv = uv + s * omega * (scale * (t * t) + 2.0 * u_ssgiSize.zw);
                if (any(suv < float2(0.0)) || any(suv >= float2(1.0))) break;

                int lod = clamp(int(log2(max(length((suv - uv) * float2(halfSize)), 1.0)) - 2.0), 0, 3);
                int2 full = int2(u_ssgiSize.xy);
                int2 sp = min(int2(suv * u_ssgiSize.xy) >> (lod + 1), (full >> (lod + 1)) - 1);
                if (lod == 0 && all(sp == hp)) continue;
                uint2 ap = uint2(sp + ssgiPyramidOffset(lod, full));
                float zs = lod == 0 ? u_ssgiDepth_texture.read(uint2(sp)).x
                                    : u_ssgiPyramidDepth_texture.read(ap).x;
                if (zs >= 0.0) continue;
                float2 suvc = (float2(sp * (2 << lod)) + float(1 << lod) - 0.5) * u_ssgiSize.zw;

                float3 delta = viewPosition(suvc, zs, u_proj) - P;
                float dist = length(delta);
                if (dist < 1e-4) continue;
                float3 h = delta / dist;
                float3 back = normalize(delta - V * u_ssgi.y);
                float2 angles = s * float2(fastAcos(clamp(dot(h, V), -1.0, 1.0)), fastAcos(clamp(dot(back, V), -1.0, 1.0)));
                float2 sectors = 0.5 + 0.5 * sin(clamp(angles - n, -0.5 * PI, 0.5 * PI));
                uint bits = ssgiSectors(min(sectors.x, sectors.y), max(sectors.x, sectors.y));
                uint fresh = bits & ~mask;
                mask |= bits;
                float2 sectorsR = 0.5 + 0.5 * sin(clamp(angles - nr, -0.5 * PI, 0.5 * PI));
                uint freshR = ssgiSectors(min(sectorsR.x, sectorsR.y), max(sectorsR.x, sectorsR.y)) & ~maskR;
                maskR |= freshR;
                if (fresh == 0u && freshR == 0u) continue;

                float3 ns = lod == 0 ? u_ssgiNormal_texture.read(uint2(sp)).xyz
                                     : u_ssgiPyramidNormal_texture.read(ap).xyz;
                float3 radiance = lod == 0 ? u_ssgiRadiance_texture.read(uint2(sp)).rgb
                                           : u_ssgiPyramidRadiance_texture.read(ap).rgb;
                radiance *= clamp(dot(ns, -h) * 4.0, 0.0, 1.0);
                lighting += float(popcount(fresh)) / 32.0 * radiance;
                specSlice += float(popcount(freshR)) / 32.0 * radiance;
              }
            }

            visibility += 1.0 - float(popcount(mask)) / 32.0;

            // average open direction in this slice, weighted by how open it is
            uint open = ~mask;
            float openCount = float(popcount(open));
            if (openCount > 0.0) {
              float sinSum = 0.0;
              for (uint bits = open; bits != 0u; bits &= bits - 1u) {
                sinSum += (2.0 * float(ctz(bits)) + 1.0) / 32.0 - 1.0;
              }
              float angle = n + asin(clamp(sinSum / openCount, -1.0, 1.0));
              bent += (openCount / 32.0) * (V * cos(angle) + ortho * sin(angle));
            }

            float validR = max(32.0 - float(popcount(belowR)), 1.0);
            specLighting += specSlice * (32.0 / validR);
            specVisibility += (32.0 - float(popcount(maskR))) / validR;
          }

          o_ssgiRaw_texture = float4(lighting * 0.5, visibility * 0.5);
          o_ssgiSpecRaw_texture = float4(specLighting * 0.5, specVisibility * 0.5);
          o_ssgiBentRaw_texture = float4(length(bent) > 1e-3 ? normalize(bent) : N, 1.0);
        }
      }
      """#
  }
}
