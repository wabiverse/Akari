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

extension Akari.LightProbes
{
  static let captureMSL = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertIn
    {
      float4 a_position [[attribute(0)]];
      float4 a_color    [[attribute(1)]];
      float2 a_texcoord [[attribute(2)]];
      float3 a_normal   [[attribute(3)]];
    };
    struct VertOut
    {
      float4 position [[position]];
      float3 normal;
      float2 uv;
    };
    struct FragOut
    {
      float4 albedo   [[color(0)]];
      float4 normal   [[color(1)]];
      float4 emission [[color(2)]];
    };
    struct U { float4 u_mode; };
    struct LabGLBuiltins
    {
      float4x4 u_modelview;
      float4x4 u_projection;
      float4x4 u_modelviewProjection;
      float3x3 u_normalMatrix;
    };
    struct AtlasTexture
    {
      texture2d<float> t [[texture(0)]];
    };

    vertex VertOut vert_main(VertIn in [[stage_in]],
                             constant LabGLBuiltins& B [[buffer(3)]])
    {
      VertOut out;
      out.position = B.u_modelviewProjection * in.a_position;
      out.normal = in.a_normal;
      out.uv = in.a_texcoord;
      return out;
    }

    vertex VertOut vert_indirect_main(VertIn in [[stage_in]],
                                      constant float4x4* viewsXf [[buffer(1)]],
                                      constant float4x4& model [[buffer(4)]])
    {
      VertOut out;
      out.position = (viewsXf[0] * model) * in.a_position;
      out.normal = (model * float4(in.a_normal, 0.0)).xyz;
      out.uv = in.a_texcoord;
      return out;
    }

    vertex VertOut vert_amplified_main(VertIn in [[stage_in]],
                                       constant float4x4* viewsXf [[buffer(1)]],
                                       ushort ampId [[amplification_id]])
    {
      VertOut out;
      out.position = viewsXf[ampId] * in.a_position;
      out.normal = in.a_normal;
      out.uv = in.a_texcoord;
      return out;
    }

    vertex VertOut vert_amplified_indirect_main(VertIn in [[stage_in]],
                                                constant float4x4* viewsXf [[buffer(1)]],
                                                constant float4x4& model [[buffer(4)]],
                                                ushort ampId [[amplification_id]])
    {
      VertOut out;
      out.position = (viewsXf[ampId] * model) * in.a_position;
      out.normal = (model * float4(in.a_normal, 0.0)).xyz;
      out.uv = in.a_texcoord;
      return out;
    }

    fragment FragOut frag_main(VertOut in [[stage_in]],
                               bool front [[front_facing]],
                               constant U& u [[buffer(2)]],
                               constant AtlasTexture& material [[buffer(0)]],
                               constant AtlasTexture& color [[buffer(1)]],
                               constant AtlasTexture& emissive [[buffer(4)]])
    {
      constexpr sampler smp(filter::linear, mip_filter::linear, address::clamp_to_edge);
      float4 mat = material.t.sample(smp, in.uv);
      if (mat.a > 0.0 && mat.b < mat.a) discard_fragment();
      FragOut out;
      if (u.u_mode.x > 0.5)
      {
        out.albedo = float4(in.position.z);
        out.normal = float4(0.0);
        out.emission = float4(0.0);
        return out;
      }
      float len = length(in.normal);
      out.albedo = float4(color.t.sample(smp, in.uv).rgb, front ? 1.0 : -1.0);
      out.normal = float4(len > 1e-8 ? in.normal / len : float3(0.0, 1.0, 0.0), in.position.z);
      out.emission = float4(emissive.t.sample(smp, in.uv).rgb, mat.g);
      return out;
    }
    """

  static let clearMSL = """
    #include <metal_stdlib>
    using namespace metal;
    struct U { float4 u_value; };
    kernel void compute_main(constant U& u [[buffer(0)]],
                             texture2d<float, access::write> o [[texture(0)]],
                             uint2 gid [[thread_position_in_grid]])
    {
      if (gid.x >= o.get_width() || gid.y >= o.get_height()) return;
      o.write(u.u_value, gid);
    }
    """

  private static let common = """
    #include <metal_stdlib>
    using namespace metal;

    struct U
    {
      float4x4 u_sunMatrix;
      float4 u_sun;
      float4 u_sky;
      float4 u_sunMap;
      float4 u_gridMin;
      float4 u_gridMax;
      float4 u_gridSize;
      float4 u_lightPos0;
      float4 u_lightPos1;
      float4 u_lightPos2;
      float4 u_lightPos3;
      float4 u_lightColor0;
      float4 u_lightColor1;
      float4 u_lightColor2;
      float4 u_lightColor3;
      float4 u_params;
    };

    constant float PI = 3.14159265358979;
    constant int VOLUME_FACE = \(volumeFace);
    constant int SPHERE_FACE = \(sphereFace);
    constant int ATLAS_WIDTH = \(atlasWidth);
    constant int VOLUME_HEIGHT = \(volumeRegionHeight);
    constant int OCT_RES = \(octResolution);
    constant int SH_PER_ROW = \(shProbesPerRow);

    float3 toSkySpace(float3 v, float zUp)
    {
      return mix(v, float3(v.x, v.z, -v.y), zUp);
    }

    void faceBasis(int face, thread float3& f, thread float3& up)
    {
      switch (face)
      {
        case 0: f = float3(1.0, 0.0, 0.0); up = float3(0.0, 1.0, 0.0); break;
        case 1: f = float3(-1.0, 0.0, 0.0); up = float3(0.0, 1.0, 0.0); break;
        case 2: f = float3(0.0, 1.0, 0.0); up = float3(0.0, 0.0, -1.0); break;
        case 3: f = float3(0.0, -1.0, 0.0); up = float3(0.0, 0.0, 1.0); break;
        case 4: f = float3(0.0, 0.0, 1.0); up = float3(0.0, 1.0, 0.0); break;
        default: f = float3(0.0, 0.0, -1.0); up = float3(0.0, 1.0, 0.0); break;
      }
    }

    float3 faceDirection(int face, float2 ndc)
    {
      float3 f, up;
      faceBasis(face, f, up);
      return normalize(f + cross(f, up) * ndc.x + up * ndc.y);
    }

    void cubeFace(float3 d, thread int& face, thread float2& ndc)
    {
      float3 a = abs(d);
      if (a.x >= a.y && a.x >= a.z) face = d.x > 0.0 ? 0 : 1;
      else if (a.y >= a.z) face = d.y > 0.0 ? 2 : 3;
      else face = d.z > 0.0 ? 4 : 5;
      float3 f, up;
      faceBasis(face, f, up);
      ndc = float2(dot(d, cross(f, up)), dot(d, up)) / dot(d, f);
    }

    int2 faceOrigin(int view, int volumeCount)
    {
      if (view / 6 < volumeCount)
      {
        int perRow = ATLAS_WIDTH / VOLUME_FACE;
        return int2((view % perRow) * VOLUME_FACE, (view / perRow) * VOLUME_FACE);
      }
      int tile = view - volumeCount * 6;
      int perRow = ATLAS_WIDTH / SPHERE_FACE;
      return int2((tile % perRow) * SPHERE_FACE, VOLUME_HEIGHT + (tile / perRow) * SPHERE_FACE);
    }

    float3 gridCell(constant U& u)
    {
      int3 dims = int3(u.u_gridSize.xyz);
      return (u.u_gridMax.xyz - u.u_gridMin.xyz) / float3(max(dims - 1, int3(1)));
    }

    float3 gridProbe(int index, constant U& u)
    {
      int3 dims = int3(u.u_gridSize.xyz);
      int3 c = int3(index % dims.x, (index / dims.x) % dims.y, index / (dims.x * dims.y));
      return u.u_gridMin.xyz + float3(c) * gridCell(u);
    }

    float2 octEncode(float3 d)
    {
      d /= abs(d.x) + abs(d.y) + abs(d.z);
      float2 p = d.xy;
      if (d.z < 0.0) p = (1.0 - abs(d.yx)) * select(float2(-1.0), float2(1.0), d.xy >= 0.0);
      return p;
    }

    float3 octDirection(float2 p)
    {
      if (p.x > 1.0) { p.x = 2.0 - p.x; p.y = -p.y; }
      else if (p.x < -1.0) { p.x = -2.0 - p.x; p.y = -p.y; }
      if (p.y > 1.0) { p.y = 2.0 - p.y; p.x = -p.x; }
      else if (p.y < -1.0) { p.y = -2.0 - p.y; p.x = -p.x; }
      float3 d = float3(p, 1.0 - abs(p.x) - abs(p.y));
      if (d.z < 0.0) d.xy = (1.0 - abs(p.yx)) * select(float2(-1.0), float2(1.0), p >= 0.0);
      return normalize(d);
    }

    int2 octOrigin(int sphere, int mip)
    {
      int2 tile = int2((sphere % \(octTilesPerRow)) * \(octTile.x), (sphere / \(octTilesPerRow)) * \(octTile.y));
      switch (mip)
      {
        case 0: return tile;
        case 1: return tile + int2(OCT_RES + 2, 0);
        case 2: return tile + int2(OCT_RES + 2, OCT_RES / 2 + 2);
        case 3: return tile + int2(OCT_RES + 2, OCT_RES / 2 + OCT_RES / 4 + 4);
        default: return tile + int2(OCT_RES + 2, OCT_RES / 2 + OCT_RES / 4 + OCT_RES / 8 + 6);
      }
    }

    float sphereIrradiance(float cosTheta, float sinSigmaSqr)
    {
      if (cosTheta * cosTheta > sinSigmaSqr) return PI * sinSigmaSqr * max(cosTheta, 0.0);
      float sinTheta = sqrt(max(1.0 - cosTheta * cosTheta, 1e-6));
      float x = sqrt(1.0 / sinSigmaSqr - 1.0);
      float y = clamp(-x * (cosTheta / sinTheta), -1.0, 1.0);
      float sinThetaSqrtY = sinTheta * sqrt(1.0 - y * y);
      return max((cosTheta * acos(y) - x * sinThetaSqrtY) * sinSigmaSqr + atan(sinThetaSqrtY / x), 0.0);
    }

    float4 lightPos(int i, constant U& u)
    {
      return i == 0 ? u.u_lightPos0 : i == 1 ? u.u_lightPos1 : i == 2 ? u.u_lightPos2 : u.u_lightPos3;
    }

    float4 lightColor(int i, constant U& u)
    {
      return i == 0 ? u.u_lightColor0 : i == 1 ? u.u_lightColor1 : i == 2 ? u.u_lightColor2 : u.u_lightColor3;
    }

    float3 volumeIrradiance(float3 x, float3 N, texture2d<float> sh, constant U& u)
    {
      int3 dims = int3(u.u_gridSize.xyz);
      float3 cell = gridCell(u);
      float3 g = clamp((x + N * u.u_gridSize.w - u.u_gridMin.xyz) / cell, float3(0.0), float3(dims - 1));
      int3 base = min(int3(floor(g)), max(dims - 2, int3(0)));
      float3 f = g - float3(base);
      float3 l0 = float3(0.0), lx = float3(0.0), ly = float3(0.0), lz = float3(0.0);
      float weight = 0.0;
      for (int i = 0; i < 8; ++i)
      {
        int3 o = int3(i & 1, (i >> 1) & 1, i >> 2);
        int3 c = min(base + o, dims - 1);
        float3 w3 = mix(1.0 - f, f, float3(o));
        int index = c.x + dims.x * (c.y + dims.y * c.z);
        uint2 t = uint2((index % SH_PER_ROW) * 4, index / SH_PER_ROW);
        float4 c0 = sh.read(t);
        float3 toProbe = u.u_gridMin.xyz + float3(c) * cell - x;
        float facing = dot(toProbe, N) * rsqrt(max(dot(toProbe, toProbe), 1e-12)) * 0.5 + 0.5;
        float w = w3.x * w3.y * w3.z * (facing * facing + 0.05) * max(c0.a, 1e-3);
        l0 += c0.rgb * w;
        lx += sh.read(t + uint2(1, 0)).rgb * w;
        ly += sh.read(t + uint2(2, 0)).rgb * w;
        lz += sh.read(t + uint2(3, 0)).rgb * w;
        weight += w;
      }
      float3 irradiance = 0.282095 * l0 + 0.325735 * (lx * N.x + ly * N.y + lz * N.z);
      return max(irradiance / max(weight, 1e-8), float3(0.0));
    }

    float sunVisibility(float3 x, float3 N, texture2d<float> sunMap, constant U& u)
    {
      float4 c = u.u_sunMatrix * float4(x + N * (u.u_sunMap.y * 1.5), 1.0);
      float2 uv = c.xy * 0.5 + 0.5;
      if (any(uv <= 0.0) || any(uv >= 1.0)) return 1.0;
      int res = int(u.u_sunMap.x);
      int2 center = int2(uv * float(res));
      float bias = u.u_sunMap.y * 2.0 * u.u_sunMap.z;
      float lit = 0.0;
      for (int k = 0; k < 9; ++k)
      {
        int2 t = clamp(center + int2(k % 3 - 1, k / 3 - 1), int2(0), int2(res - 1));
        lit += c.z + bias >= sunMap.read(uint2(t)).x ? 1.0 : 0.0;
      }
      return lit / 9.0;
    }

    float3 shadeHit(float3 origin, float3 dir, float2 ndc, float4 a, float4 n, float4 e,
                    texturecube<float> env, sampler envSmp, texture2d<float> sunMap,
                    texture2d<float> sh, constant U& u, float skyLod)
    {
      if (a.w == 0.0) return env.sample(envSmp, toSkySpace(dir, u.u_sky.x), level(skyLod)).rgb * u.u_sky.y;
      if (a.w < 0.0) return float3(0.0);
      float t = u.u_sky.z / max(n.w, 1e-8) * length(float3(ndc, 1.0));
      float3 x = origin + dir * t;
      float3 N = normalize(n.xyz);
      float metallic = saturate(e.a);
      float3 diffuseColor = a.rgb * (1.0 - metallic);
      float3 irradiance = float3(0.0);

      float3 L = normalize(u.u_sun.xyz);
      float NoL = dot(N, L);
      if (NoL > 0.0)
      {
        float sunHeight = u.u_sun.w;
        float nightFade = smoothstep(-0.3, 0.05, sunHeight);
        float3 skyL = env.sample(envSmp, toSkySpace(L, u.u_sky.x), level(0.0)).rgb;
        float3 dayColor = mix(skyL, float3(1.0), saturate(sunHeight));
        float3 nightColor = mix(skyL, float3(0.95, 0.95, 1.0), saturate(-sunHeight));
        float3 dynamicSky = mix(nightColor * 0.12, dayColor * 3.0, nightFade);
        irradiance += dynamicSky * NoL * sunVisibility(x, N, sunMap, u);
      }

      int count = int(u.u_params.x);
      for (int i = 0; i < count; ++i)
      {
        float4 posIntensity = lightPos(i, u);
        float4 colorRadius = lightColor(i, u);
        float3 toLight = posIntensity.xyz - x;
        float distSq = max(dot(toLight, toLight), colorRadius.w * colorRadius.w);
        float sinSigmaSqr = min(colorRadius.w * colorRadius.w / distSq, 0.9999);
        irradiance += colorRadius.rgb * posIntensity.w
                    * sphereIrradiance(dot(N, toLight * rsqrt(distSq)), sinSigmaSqr);
      }

      float3 indirect = volumeIrradiance(x, N, sh, u);
      float3 radiance = diffuseColor / PI * irradiance + (diffuseColor + a.rgb * metallic) * indirect + e.rgb;
      return all(isfinite(radiance)) ? radiance : float3(0.0);
    }
    """

  static let projectMSL = common + """

    kernel void compute_main(constant U& u [[buffer(0)]],
                             texture2d<float, access::write> shOut [[texture(0)]],
                             texture2d<float, access::read_write> info [[texture(1)]],
                             texture2d<float> albedoTex [[texture(2)]],
                             texture2d<float> normalTex [[texture(3)]],
                             texture2d<float> emissionTex [[texture(4)]],
                             texturecube<float> env [[texture(5)]],
                             texture2d<float> sunMap [[texture(6)]],
                             texture2d<float> shIn [[texture(7)]],
                             sampler envSmp [[sampler(0)]],
                             uint group [[threadgroup_position_in_grid]],
                             uint tid [[thread_index_in_threadgroup]],
                             uint lane [[thread_index_in_simdgroup]],
                             uint simdIndex [[simdgroup_index_in_threadgroup]],
                             uint simdCount [[simdgroups_per_threadgroup]])
    {
      threadgroup float partial[32][14];
      int probe = int(group);
      int volumeCount = int(u.u_gridMin.w);
      bool isVolume = probe < volumeCount;
      int face = isVolume ? VOLUME_FACE : SPHERE_FACE;
      float3 origin = isVolume ? gridProbe(probe, u) : info.read(uint2(probe - volumeCount, 0)).xyz;
      float sums[14] = {};
      int faceTexels = face * face;
      for (int i = int(tid); i < 6 * faceTexels; i += 256)
      {
        int f = i / faceTexels;
        int j = i - f * faceTexels;
        int2 p = int2(j % face, j / face);
        float2 ndc = (float2(p) + 0.5) / float(face) * 2.0 - 1.0;
        uint2 texel = uint2(faceOrigin(probe * 6 + f, volumeCount) + p);
        float4 a = albedoTex.read(texel);
        float dw = 1.0 / pow(1.0 + dot(ndc, ndc), 1.5);
        sums[12] += dw;
        if (a.w < 0.0) sums[13] += dw;
        if (!isVolume) continue;
        float3 dir = faceDirection(f, ndc);
        float3 radiance = shadeHit(origin, dir, ndc, a, normalTex.read(texel), emissionTex.read(texel),
                                   env, envSmp, sunMap, shIn, u, 4.0);
        float3 y1 = 0.488603 * dir * dw;
        float3 l0 = radiance * (0.282095 * dw);
        sums[0] += l0.r; sums[1] += l0.g; sums[2] += l0.b;
        sums[3] += radiance.r * y1.x; sums[4] += radiance.g * y1.x; sums[5] += radiance.b * y1.x;
        sums[6] += radiance.r * y1.y; sums[7] += radiance.g * y1.y; sums[8] += radiance.b * y1.y;
        sums[9] += radiance.r * y1.z; sums[10] += radiance.g * y1.z; sums[11] += radiance.b * y1.z;
      }
      for (int k = 0; k < 14; ++k)
      {
        float s = simd_sum(sums[k]);
        if (lane == 0) partial[simdIndex][k] = s;
      }
      threadgroup_barrier(mem_flags::mem_threadgroup);
      if (tid != 0) return;
      float total[14] = {};
      for (uint s = 0; s < simdCount; ++s)
        for (int k = 0; k < 14; ++k) total[k] += partial[s][k];
      float norm = 4.0 * PI / max(total[12], 1e-8);
      float validity = 1.0 - smoothstep(0.05, 0.2, total[13] / max(total[12], 1e-8));
      if (isVolume)
      {
        uint2 t = uint2((probe % SH_PER_ROW) * 4, probe / SH_PER_ROW);
        shOut.write(float4(float3(total[0], total[1], total[2]) * norm, validity), t);
        shOut.write(float4(float3(total[3], total[4], total[5]) * norm, 0.0), t + uint2(1, 0));
        shOut.write(float4(float3(total[6], total[7], total[8]) * norm, 0.0), t + uint2(2, 0));
        shOut.write(float4(float3(total[9], total[10], total[11]) * norm, 0.0), t + uint2(3, 0));
      }
      else
      {
        info.write(float4(validity, 0.0, 0.0, 0.0), uint2(probe - volumeCount, 1));
      }
    }
    """

  static let sphereBaseMSL = common + """

    kernel void compute_main(constant U& u [[buffer(0)]],
                             texture2d<float, access::write> atlas [[texture(0)]],
                             texture2d<float> info [[texture(1)]],
                             texture2d<float> albedoTex [[texture(2)]],
                             texture2d<float> normalTex [[texture(3)]],
                             texture2d<float> emissionTex [[texture(4)]],
                             texturecube<float> env [[texture(5)]],
                             texture2d<float> sunMap [[texture(6)]],
                             texture2d<float> sh [[texture(7)]],
                             sampler envSmp [[sampler(0)]],
                             uint3 gid [[thread_position_in_grid]])
    {
      if (gid.x >= uint(OCT_RES + 2) || gid.y >= uint(OCT_RES + 2)) return;
      int sphere = int(gid.z);
      int volumeCount = int(u.u_gridMin.w);
      float3 origin = info.read(uint2(sphere, 0)).xyz;
      float3 sum = float3(0.0);
      for (int k = 0; k < 4; ++k)
      {
        float2 q = float2(int2(gid.xy) - 1) + float2(k & 1, k >> 1) * 0.5 + 0.25;
        float3 d = octDirection(q / float(OCT_RES) * 2.0 - 1.0);
        int face;
        float2 ndc;
        cubeFace(d, face, ndc);
        int2 p = clamp(int2((ndc * 0.5 + 0.5) * float(SPHERE_FACE)), int2(0), int2(SPHERE_FACE - 1));
        float2 texelNdc = (float2(p) + 0.5) / float(SPHERE_FACE) * 2.0 - 1.0;
        uint2 texel = uint2(faceOrigin((volumeCount + sphere) * 6 + face, volumeCount) + p);
        sum += shadeHit(origin, faceDirection(face, texelNdc), texelNdc, albedoTex.read(texel),
                        normalTex.read(texel), emissionTex.read(texel), env, envSmp, sunMap, sh, u, 1.0);
      }
      atlas.write(float4(sum * 0.25, 1.0), uint2(octOrigin(sphere, 0) + int2(gid.xy)));
    }
    """

  static let sphereFilterMSL = common + """

    float3 sampleLevel(texture2d<float, access::read_write> atlas, int sphere, int mip, float3 d)
    {
      int res = OCT_RES >> mip;
      float2 pos = (octEncode(d) * 0.5 + 0.5) * float(res) + 0.5;
      int2 i0 = int2(floor(pos));
      float2 f = pos - float2(i0);
      int2 origin = octOrigin(sphere, mip);
      float3 s = float3(0.0);
      for (int k = 0; k < 4; ++k)
      {
        int2 o = int2(k & 1, k >> 1);
        int2 t = clamp(i0 + o, int2(0), int2(res + 1));
        float w = (o.x == 1 ? f.x : 1.0 - f.x) * (o.y == 1 ? f.y : 1.0 - f.y);
        s += atlas.read(uint2(origin + t)).rgb * w;
      }
      return s;
    }

    kernel void compute_main(constant U& u [[buffer(0)]],
                             texture2d<float, access::read_write> atlas [[texture(0)]],
                             uint3 gid [[thread_position_in_grid]])
    {
      int mip = int(u.u_params.y);
      int res = OCT_RES >> mip;
      if (gid.x >= uint(res + 2) || gid.y >= uint(res + 2)) return;
      int sphere = int(gid.z);
      float3 N = octDirection((float2(int2(gid.xy) - 1) + 0.5) / float(res) * 2.0 - 1.0);
      float rough = float(mip) / float(\(octLevels - 1));
      float roughPrev = float(mip - 1) / float(\(octLevels - 1));
      float a = rough * rough;
      float ap = roughPrev * roughPrev;
      float a2 = max(a * a - ap * ap, 1e-4);
      float3 helper = abs(N.z) < 0.999 ? float3(0.0, 0.0, 1.0) : float3(1.0, 0.0, 0.0);
      float3 T = normalize(cross(helper, N));
      float3 B = cross(N, T);
      float rotation = fract(52.9829189 * fract(dot(float2(gid.xy), float2(0.06711056, 0.00583715)))) * 2.0 * PI;
      float3 sum = float3(0.0);
      float weight = 0.0;
      for (uint i = 0; i < 32u; ++i)
      {
        float2 xi = float2(float(i) / 32.0, float(reverse_bits(i)) * 2.3283064365386963e-10);
        float phi = 2.0 * PI * xi.x + rotation;
        float cosTheta = sqrt((1.0 - xi.y) / (1.0 + (a2 - 1.0) * xi.y));
        float sinTheta = sqrt(max(1.0 - cosTheta * cosTheta, 0.0));
        float3 H = T * (sinTheta * cos(phi)) + B * (sinTheta * sin(phi)) + N * cosTheta;
        float3 L = 2.0 * dot(N, H) * H - N;
        float NoL = dot(N, L);
        if (NoL <= 0.0) continue;
        sum += sampleLevel(atlas, sphere, mip - 1, L) * NoL;
        weight += NoL;
      }
      atlas.write(float4(sum / max(weight, 1e-4), 1.0), uint2(octOrigin(sphere, mip) + int2(gid.xy)));
    }
    """
}
