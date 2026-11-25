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
  /// drawn by the `volume scatter` pass.
  struct VolumeScatterShader: FullscreenShader
  {
    let name = "volume-scatter"

    var uniforms: [Declaration]
    {
      Uniforms.iblTint
      Sampler(EnvCubeBuffer.envCube, .samplerCube)
      Sampler(IrradianceBuffer.irradiance, .samplerCube)
      Uniforms.iblEnabled
      Samplers.shadowAtlas
      Samplers.shadowData
      Samplers.shadowPagetable
      Samplers.froxelDepth
      Samplers.froxelHistory
      Uniforms.view
      Uniforms.proj
      Uniforms.invProj
      Uniforms.sunHeight
      Uniforms.zUp
      Uniforms.domeEnabled
      Uniforms.domeSun
      Uniforms.sunOverride
      Uniforms.sunDirection
      Uniforms.shadowEnabled
      Uniforms.shadowLevelCount
      Uniforms.shadowBias
      Uniforms.eyeToLightRotation
      Uniforms.directionalRefOffset
      Uniforms.shadowLodRange
      Uniforms.punctualShadowEnabled
      Uniforms.pointLightCount
      Uniforms.shadowedPointLightCount
      Uniforms.pointLightPosIntensity0
      Uniforms.pointLightPosIntensity1
      Uniforms.pointLightPosIntensity2
      Uniforms.pointLightPosIntensity3
      Uniforms.pointLightColorRadius0
      Uniforms.pointLightColorRadius1
      Uniforms.pointLightColorRadius2
      Uniforms.pointLightColorRadius3
      Uniforms.volume
      Uniforms.volumeRange
      Uniforms.volumeSunLevelBias
      Uniforms.volumePrevViewProj
      Uniforms.volumeHistory
      Uniforms.volumeNoise
      Uniforms.volumeFlow
      Uniforms.volumeLayer
      Samplers.fogDisturbers
      Samplers.fogSim
      Uniforms.volumeLook
      Uniforms.fogSimMin
      Uniforms.fogSimMax
      Samplers.pointLightData
      Uniforms.frameIndex
    }

    let fragmentGLSL = #"""
      const float PI = 3.14159265358979;
      const float LIGHT_INTENSITY = 3.0;
      const float MOON_INTENSITY = 0.12;

      vec3 toSkySpace(vec3 v)
      {
        return mix(v, vec3(v.x, v.z, -v.y), u_zUp);
      }

      float phaseHG(float cosTheta, float g)
      {
        float d = 1.0 + g * g - 2.0 * g * cosTheta;
        return (1.0 - g * g) / (4.0 * PI * d * sqrt(d));
      }

      float frustumExitDistance(vec3 posEye, vec3 dirEye)
      {
        vec4 c = u_proj * vec4(posEye, 1.0);
        vec4 d = u_proj * vec4(dirEye, 0.0);
        vec3 a0 = c.www - c.xyz, b0 = d.www - d.xyz;
        vec3 a1 = c.www + c.xyz, b1 = d.www + d.xyz;
        float t = 1e20;
        for (int i = 0; i < 3; ++i) {
          if (b0[i] < 0.0) t = min(t, max(a0[i], 0.0) / -b0[i]);
          if (b1[i] < 0.0) t = min(t, max(a1[i], 0.0) / -b1[i]);
        }
        return t;
      }

      float volumeTransmittance(float distance)
      {
        return u_volume.w > 0.5 ? exp(-u_volume.x * distance) : 1.0;
      }

      vec3 volumeWorldLight(vec3 rayDir)
      {
        vec3 ahead = texture(u_irradiance_texture, toSkySpace(rayDir)).rgb * u_iblTint.rgb;
        vec3 behind = texture(u_irradiance_texture, toSkySpace(-rayDir)).rgb * u_iblTint.rgb;
        return max(0.5 * (ahead + behind) + 0.75 * u_volume.y * (ahead - behind), vec3(0.0)) * u_iblEnabled;
      }

      float volumeSunShadow(vec3 posEye)
      {
        if (u_shadowEnabled < 0.5) return 1.0;
        vec3 lightRel = (u_eyeToLightRotation * vec4(posEye, 0.0)).xyz;
        vec3 delta = lightRel - u_directionalRefOffset.xyz;
        int lodMin = int(u_shadowLodRange.x);
        float lod = u_shadowLodRange.z > 0.5
          ? log2(length(delta) * (32.0 / (32.0 - 1.0001)) * 2.0)
          : length(delta.xy) * (32.0 / (32.0 - 2.5001)) / exp2(float(lodMin - 1)) + float(lodMin - 1);
        int levelCount = int(u_shadowLevelCount);
        int first = clamp(int(ceil(lod + u_shadowLodRange.w)), lodMin, int(u_shadowLodRange.y)) - lodMin;
        for (int i = max(min(first + int(u_volumeSunLevelBias), levelCount - 1), 0); i < levelCount; ++i) {
          vec4 slotOffset = texelFetch(u_shadow_data, ivec2(4, 96 + i), 0);
          float radius = exp2(u_shadowLodRange.x + float(i)) * 0.5;
          vec2 tileFloat = ((lightRel.xy + slotOffset.yz) / radius * 0.5 + 0.5) * 32.0;
          if (any(lessThan(tileFloat, vec2(0.0))) || any(greaterThanEqual(tileFloat, vec2(32.0)))) continue;
          ivec2 tile = ivec2(tileFloat);
          vec4 page = texelFetch(u_shadow_pagetable, ivec2(tile.y * 32 + tile.x, int(slotOffset.x)), 0);
          if (page.z < 0.5) continue;
          vec3 levelDepth = texelFetch(u_shadow_data, ivec2(5, 96 + i), 0).xyz;
          float compareDepth = ((lightRel.z + levelDepth.x) * levelDepth.y + levelDepth.z) * 0.5 + 0.5 - u_shadowBias.x;
          vec2 frac = fract(tileFloat);
          uint v = texelFetch(u_shadow_atlas, ivec3(int(page.y) * 256 + int(frac.x * 256.0),
                                                    int(frac.y * 256.0), int(page.x)), 0).r;
          return v == 0xFFFFFFFFu || compareDepth <= uintBitsToFloat(v) ? 1.0 : 0.0;
        }
        return 1.0;
      }

      float volumePointShadow(int lightIdx, vec3 lL, int startLod)
      {
        if (u_punctualShadowEnabled < 0.5) return 1.0;
        vec3 aL = abs(lL);
        int face = aL.x > aL.y && aL.x > aL.z ? (lL.x > 0.0 ? 1 : 2)
                 : aL.y > aL.x && aL.y > aL.z ? (lL.y > 0.0 ? 3 : 4) : (lL.z > 0.0 ? 5 : 0);
        vec3 fL = lL;
        if (face == 1) fL = vec3(-lL.y, lL.z, -lL.x);
        else if (face == 2) fL = vec3(lL.y, lL.z, lL.x);
        else if (face == 3) fL = vec3(lL.x, lL.z, -lL.y);
        else if (face == 4) fL = vec3(-lL.x, lL.z, lL.y);
        else if (face == 5) fL = vec3(lL.x, -lL.y, -lL.z);
        float z = max(abs(fL.z), 1e-6);
        int tilemapIndex = lightIdx * 6 + face;
        vec2 nearFar = texelFetch(u_shadow_data, ivec2(5, tilemapIndex), 0).xy;
        vec2 uv = clamp(fL.xy / z * 0.5 + 0.5, 0.0, 0.999999);
        for (int i = 0; i <= 5; ++i) {
          int lod = i <= startLod ? startLod - i : i;
          int size = 32 >> lod;
          int base = (4096 - (4096 >> (2 * lod))) / 3;
          vec2 tileFloat = uv * float(size);
          ivec2 tile = ivec2(tileFloat);
          vec4 page = texelFetch(u_shadow_pagetable, ivec2(base + tile.y * size + tile.x, tilemapIndex), 0);
          if (page.z < 0.5) continue;
          float zb = max(z - 4.0 * z / float(size * 256), nearFar.x);
          float tapDepth = nearFar.y * (zb - nearFar.x) / ((nearFar.y - nearFar.x) * zb);
          vec2 frac = tileFloat - vec2(tile);
          uint v = texelFetch(u_shadow_atlas, ivec3(int(page.y) * 256 + int(frac.x * 256.0),
                                                    int(frac.y * 256.0), int(page.x)), 0).r;
          return v == 0xFFFFFFFFu || tapDepth <= uintBitsToFloat(v) ? 1.0 : 0.0;
        }
        return 1.0;
      }

      vec3 froxelEye(vec2 uv, float t)
      {
        vec4 e = u_invProj * vec4(uv * 2.0 - 1.0, -1.0, 1.0);
        vec3 dirEye = e.xyz / e.w;
        return dirEye * (mix(u_volumeRange.x, u_volumeRange.y, t * t) / max(-dirEye.z, 1e-6));
      }

      vec4 volumeHistory(vec3 worldPos, ivec2 grid)
      {
        vec4 c = u_volumePrevViewProj * vec4(worldPos, 1.0);
        if (u_volumeHistory < 0.5 || c.w <= u_volumeRange.x) return vec4(0.0);
        vec3 f = vec3((c.xy / c.w * 0.5 + 0.5) * vec2(grid),
                      sqrt((c.w - u_volumeRange.x) / (u_volumeRange.y - u_volumeRange.x)) * 64.0) - 0.5;
        if (any(lessThan(f, vec3(-0.5))) || any(greaterThan(f, vec3(vec2(grid), 64.0) - 0.5))) return vec4(0.0);
        ivec3 i0 = ivec3(floor(f));
        vec3 w = f - vec3(i0);
        vec4 sum = vec4(0.0);
        for (int k = 0; k < 8; ++k) {
          ivec3 o = ivec3(k & 1, (k >> 1) & 1, k >> 2);
          ivec3 p = clamp(i0 + o, ivec3(0), ivec3(grid - 1, 63));
          vec4 v = texelFetch(u_froxelHistory, ivec2(p.z % 8, p.z / 8) * grid + p.xy, 0);
          vec3 ow = mix(1.0 - w, w, vec3(o));
          sum += vec4(v.rgb, 1.0) * (ow.x * ow.y * ow.z * step(v.a, 1.0));
        }
        return sum;
      }

      void main()
      {
        ivec2 a = ivec2(gl_FragCoord.xy);
        ivec2 grid = ivec2(u_volumeRange.zw);
        ivec2 sliceXY = a / max(grid, ivec2(1));
        int s = sliceXY.y * 8 + sliceXY.x;
        if (u_volume.z < 0.5 || sliceXY.x >= 8 || s >= 64) {
          o_volumeScatter_texture = vec4(0.0, 0.0, 0.0, 1.0);
          return;
        }
        ivec2 froxel = a - sliceXY * grid;
        float t0 = float(s) / 64.0, t1 = float(s + 1) / 64.0;
        if (mix(u_volumeRange.x, u_volumeRange.y, t0 * t0) > texelFetch(u_froxelDepth, froxel, 0).x) {
          o_volumeScatter_texture = vec4(0.0, 0.0, 0.0, 2.0);
          return;
        }
        float noise = fract(52.9829189 * fract(dot(vec2(a), vec2(0.06711056, 0.00583715))));
        vec3 jitter = fract(float(frameIndex % 64) * vec3(0.7548777, 0.5698403, 0.6180340) + noise);
        vec3 posEye = froxelEye((vec2(froxel) + jitter.xy) / vec2(grid), (float(s) + jitter.z) / 64.0);
        float depth = -posEye.z;
        mat3 invRot = transpose(mat3(u_view));
        vec3 worldPos = invRot * (posEye - u_view[3].xyz);
        vec3 rayDir = normalize(invRot * posEye);
        float froxelFootprint = 2.0 / max(u_proj[1][1] * float(grid.y), 1e-6) * depth;

        vec3 L = normalize(u_sunDirection.xyz);
        float nightFade = smoothstep(-0.3, 0.05, sunHeight);
        vec3 skyL = texture(u_envCube_texture, toSkySpace(L)).rgb * u_iblTint.rgb;
        vec3 dayColor = mix(skyL, vec3(1.0), clamp(sunHeight, 0.0, 1.0));
        vec3 nightColor = mix(skyL, vec3(0.95, 0.95, 1.00), clamp(-sunHeight, 0.0, 1.0));
        vec3 sun = mix(mix(mix(nightColor * MOON_INTENSITY, dayColor * LIGHT_INTENSITY, nightFade), u_domeSun.rgb, u_domeEnabled) * u_iblEnabled, u_sunOverride.rgb, u_sunOverride.w);
        vec3 light = sun * phaseHG(dot(L, rayDir), u_volume.y) * volumeSunShadow(posEye)
                   * volumeTransmittance(frustumExitDistance(posEye, mat3(u_view) * L))
                   + volumeWorldLight(rayDir);

        int count = int(min(u_pointLightCount, 4.0));
        for (int i = 0; i < count; ++i) {
          vec4 posIntensity = i == 0 ? u_pointLightPosIntensity0 : i == 1 ? u_pointLightPosIntensity1
                            : i == 2 ? u_pointLightPosIntensity2 : u_pointLightPosIntensity3;
          vec4 colorRadius = i == 0 ? u_pointLightColorRadius0 : i == 1 ? u_pointLightColorRadius1
                           : i == 2 ? u_pointLightColorRadius2 : u_pointLightColorRadius3;
          vec3 toLight = posIntensity.xyz - worldPos;
          float dSqr = dot(toLight, toLight);
          float d = sqrt(dSqr);
          float rSqr = colorRadius.w * colorRadius.w;
          float spread = max(rSqr, 0.25 * froxelFootprint * froxelFootprint);
          float falloff = 2.0 / max(dSqr + spread + d * sqrt(dSqr + spread), 1e-12);
          vec3 aL = abs(toLight);
          float faceDistance = max(max(aL.x, aL.y), aL.z);
          float ratio = clamp(2.0 * 1.4142135 / 8192.0 / max(froxelFootprint / max(faceDistance, 1e-6), 1e-8), 1e-8, 1.0);
          int startLod = int(clamp(-log2(ratio), 0.0, 5.0));
          light += colorRadius.xyz * posIntensity.w * PI * rSqr * falloff
                 * phaseHG(dot(toLight / max(d, 1e-6), rayDir), u_volume.y)
                 * volumePointShadow(i, -toLight, startLod)
                 * volumeTransmittance(d);
        }
        vec3 centerEye = froxelEye((vec2(froxel) + 0.5) / vec2(grid), (float(s) + 0.5) / 64.0);
        vec4 history = volumeHistory(invRot * (centerEye - u_view[3].xyz), grid);
        light = mix(history.rgb / max(history.a, 1e-4), light, mix(1.0, 0.1, history.a));

        float stretch = length(posEye) / depth * (u_volumeRange.y - u_volumeRange.x);
        float slab = exp(-u_volume.x * (t1 * t1 - t0 * t0) * stretch);
        o_volumeScatter_texture = vec4(light, slab);
      }
      """#

    let fragmentMSL = #"""
      constexpr constant float PI = 3.14159265358979;
      constexpr constant float LIGHT_INTENSITY = 3.0;
      constexpr constant float MOON_INTENSITY = 0.12;

      float phaseHG(float cosTheta, float g)
      {
        float d = 1.0 + g * g - 2.0 * g * cosTheta;
        return (1.0 - g * g) / (4.0 * PI * d * sqrt(d));
      }

      float frustumExitDistance(float3 posEye, float3 dirEye, constant Uniforms& u)
      {
        float4 c = u.u_proj * float4(posEye, 1.0);
        float4 d = u.u_proj * float4(dirEye, 0.0);
        float3 a0 = c.www - c.xyz, b0 = d.www - d.xyz;
        float3 a1 = c.www + c.xyz, b1 = d.www + d.xyz;
        float t = 1e20;
        for (int i = 0; i < 3; ++i) {
          if (b0[i] < 0.0) t = min(t, max(a0[i], 0.0) / -b0[i]);
          if (b1[i] < 0.0) t = min(t, max(a1[i], 0.0) / -b1[i]);
        }
        return t;
      }

      float volumeTransmittance(float distance, constant Uniforms& u)
      {
        return u.u_volume.w > 0.5 ? exp(-u.u_volume.x * distance) : 1.0;
      }

      float volumeSunShadow(float3 posEye, texture2d_array<uint> atlasTex, texture2d<float> dataTex,
                            texture2d<float> pageTableTex, constant Uniforms& u)
      {
        if (u.u_shadowEnabled < 0.5) return 1.0;
        float3 lightRel = (u.u_eyeToLightRotation * float4(posEye, 0.0)).xyz;
        float3 delta = lightRel - u.u_directionalRefOffset.xyz;
        int lodMin = int(u.u_shadowLodRange.x);
        float lod = u.u_shadowLodRange.z > 0.5
          ? log2(length(delta) * (32.0 / (32.0 - 1.0001)) * 2.0)
          : length(delta.xy) * (32.0 / (32.0 - 2.5001)) / exp2(float(lodMin - 1)) + float(lodMin - 1);
        int levelCount = int(u.u_shadowLevelCount);
        int first = clamp(int(ceil(lod + u.u_shadowLodRange.w)), lodMin, int(u.u_shadowLodRange.y)) - lodMin;
        for (int i = max(min(first + int(u.u_volumeSunLevelBias), levelCount - 1), 0); i < levelCount; ++i) {
          float4 slotOffset = dataTex.read(uint2(4, 96 + i));
          float radius = exp2(u.u_shadowLodRange.x + float(i)) * 0.5;
          float2 tileFloat = ((lightRel.xy + slotOffset.yz) / radius * 0.5 + 0.5) * 32.0;
          if (any(tileFloat < float2(0.0)) || any(tileFloat >= float2(32.0))) continue;
          int2 tile = int2(tileFloat);
          float4 page = pageTableTex.read(uint2(tile.y * 32 + tile.x, int(slotOffset.x)));
          if (page.z < 0.5) continue;
          float3 levelDepth = dataTex.read(uint2(5, 96 + i)).xyz;
          float compareDepth = ((lightRel.z + levelDepth.x) * levelDepth.y + levelDepth.z) * 0.5 + 0.5 - u.u_shadowBias.x;
          float2 frac = fract(tileFloat);
          uint v = atlasTex.read(uint2(uint(page.y) * 256u + uint(frac.x * 256.0), uint(frac.y * 256.0)),
                                 uint(page.x)).r;
          return v == 0xFFFFFFFFu || compareDepth <= as_type<float>(v) ? 1.0 : 0.0;
        }
        return 1.0;
      }

      float volumePointShadow(int lightIdx, float3 lL, int startLod, texture2d_array<uint> atlasTex,
                              texture2d<float> dataTex, texture2d<float> pageTableTex, constant Uniforms& u)
      {
        if (u.u_punctualShadowEnabled < 0.5) return 1.0;
        float3 aL = abs(lL);
        int face = aL.x > aL.y && aL.x > aL.z ? (lL.x > 0.0 ? 1 : 2)
                 : aL.y > aL.x && aL.y > aL.z ? (lL.y > 0.0 ? 3 : 4) : (lL.z > 0.0 ? 5 : 0);
        float3 fL = lL;
        if (face == 1) fL = float3(-lL.y, lL.z, -lL.x);
        else if (face == 2) fL = float3(lL.y, lL.z, lL.x);
        else if (face == 3) fL = float3(lL.x, lL.z, -lL.y);
        else if (face == 4) fL = float3(-lL.x, lL.z, lL.y);
        else if (face == 5) fL = float3(lL.x, -lL.y, -lL.z);
        float z = max(abs(fL.z), 1e-6);
        int tilemapIndex = lightIdx * 6 + face;
        float2 nearFar = dataTex.read(uint2(5, tilemapIndex)).xy;
        float2 uv = clamp(fL.xy / z * 0.5 + 0.5, 0.0, 0.999999);
        for (int i = 0; i <= 5; ++i) {
          int lod = i <= startLod ? startLod - i : i;
          int size = 32 >> lod;
          int base = (4096 - (4096 >> (2 * lod))) / 3;
          float2 tileFloat = uv * float(size);
          int2 tile = int2(tileFloat);
          float4 page = pageTableTex.read(uint2(base + tile.y * size + tile.x, tilemapIndex));
          if (page.z < 0.5) continue;
          float zb = max(z - 4.0 * z / float(size * 256), nearFar.x);
          float tapDepth = nearFar.y * (zb - nearFar.x) / ((nearFar.y - nearFar.x) * zb);
          float2 frac = tileFloat - float2(tile);
          uint v = atlasTex.read(uint2(uint(page.y) * 256u + uint(frac.x * 256.0), uint(frac.y * 256.0)),
                                 uint(page.x)).r;
          return v == 0xFFFFFFFFu || tapDepth <= as_type<float>(v) ? 1.0 : 0.0;
        }
        return 1.0;
      }

      float3 froxelEye(float2 uv, float t, constant Uniforms& u)
      {
        float4 e = u.u_invProj * float4(uv * 2.0 - 1.0, -1.0, 1.0);
        float3 dirEye = e.xyz / e.w;
        return dirEye * (mix(u.u_volumeRange.x, u.u_volumeRange.y, t * t) / max(-dirEye.z, 1e-6));
      }

      float4 volumeHistory(float3 worldPos, int2 grid, texture2d<float> scatterTex, constant Uniforms& u)
      {
        float4 c = u.u_volumePrevViewProj * float4(worldPos, 1.0);
        if (u.u_volumeHistory < 0.5 || c.w <= u.u_volumeRange.x) return float4(0.0);
        float3 f = float3((c.xy / c.w * 0.5 + 0.5) * float2(grid),
                          sqrt((c.w - u.u_volumeRange.x) / (u.u_volumeRange.y - u.u_volumeRange.x)) * 64.0) - 0.5;
        if (any(f < float3(-0.5)) || any(f > float3(float2(grid), 64.0) - 0.5)) return float4(0.0);
        int3 i0 = int3(floor(f));
        float3 w = f - float3(i0);
        float4 sum = float4(0.0);
        for (int k = 0; k < 8; ++k) {
          int3 o = int3(k & 1, (k >> 1) & 1, k >> 2);
          int3 p = clamp(i0 + o, int3(0), int3(grid - 1, 63));
          float4 v = scatterTex.read(uint2(int2(p.z % 8, p.z / 8) * grid + p.xy));
          float3 ow = mix(1.0 - w, w, float3(o));
          sum += float4(v.rgb, 1.0) * (ow.x * ow.y * ow.z * step(v.a, 1.0));
        }
        return sum;
      }

      \#(ShaderLibrary.fogMSL)

      //@main
      {
        int2 a = int2(gl_FragCoord.xy);
        int2 grid = max(int2(u_volumeRange.zw), int2(1));
        int2 sliceXY = a / grid;
        int s = sliceXY.y * 8 + sliceXY.x;
        int2 froxel = a - sliceXY * grid;
        float t0 = float(s) / 64.0, t1 = float(s + 1) / 64.0;
        if (u_volume.z < 0.5 || sliceXY.x >= 8 || s >= 64) {
          o_volumeScatter_texture = float4(0.0, 0.0, 0.0, 1.0);
        } else if (mix(u_volumeRange.x, u_volumeRange.y, t0 * t0) > u_froxelDepth.read(uint2(froxel)).x) {
          o_volumeScatter_texture = float4(0.0, 0.0, 0.0, 2.0);
        } else {
          float noise = fract(52.9829189 * fract(dot(float2(a), float2(0.06711056, 0.00583715))));
          float3 jitter = fract(float(frameIndex % 64) * float3(0.7548777, 0.5698403, 0.6180340) + noise);
          float3 posEye = froxelEye((float2(froxel) + jitter.xy) / float2(grid), (float(s) + jitter.z) / 64.0, _u);
          float depth = -posEye.z;
          float3x3 invView = float3x3(
            float3(u_view[0][0], u_view[1][0], u_view[2][0]),
            float3(u_view[0][1], u_view[1][1], u_view[2][1]),
            float3(u_view[0][2], u_view[1][2], u_view[2][2])
          );
          float3 worldPos = invView * (posEye - float3(u_view[3][0], u_view[3][1], u_view[3][2]));
          float3 rayDir = normalize(invView * posEye);
          float froxelFootprint = 2.0 / max(u_proj[1][1] * float(grid.y), 1e-6) * depth;

          float3 L = normalize(u_sunDirection.xyz);
          float nightFade = smoothstep(-0.3, 0.05, sunHeight);
          float3 skyDir = mix(L, float3(L.x, L.z, -L.y), u_zUp);
          float3 skyL = texture(u_envCube_texture, skyDir).rgb * u_iblTint.rgb;
          float3 dayColor = mix(skyL, float3(1.0), saturate(sunHeight));
          float3 nightColor = mix(skyL, float3(0.95, 0.95, 1.00), saturate(-sunHeight));
          float3 sun = mix(mix(mix(nightColor * MOON_INTENSITY, dayColor * LIGHT_INTENSITY, nightFade), u_domeSun.rgb, u_domeEnabled) * u_iblEnabled, u_sunOverride.rgb, u_sunOverride.w);
          float3x3 viewRot = float3x3(u_view[0].xyz, u_view[1].xyz, u_view[2].xyz);
          float3 light = sun * u_volumeLook.y * phaseHG(dot(L, rayDir), u_volume.y)
                       * volumeSunShadow(posEye, u_shadow_atlas, u_shadow_data, u_shadow_pagetable, _u)
                       * volumeTransmittance(frustumExitDistance(posEye, viewRot * L, _u), _u);

          float3 worldAhead = texture(u_irradiance_texture, mix(rayDir, float3(rayDir.x, rayDir.z, -rayDir.y), u_zUp)).rgb * u_iblTint.rgb;
          float3 worldBehind = texture(u_irradiance_texture, mix(-rayDir, float3(-rayDir.x, -rayDir.z, rayDir.y), u_zUp)).rgb * u_iblTint.rgb;
          light += max(0.5 * (worldAhead + worldBehind) + 0.75 * u_volume.y * (worldAhead - worldBehind), float3(0.0))
                 * u_iblEnabled * u_volumeLook.x;

          int count = int(min(u_pointLightCount, 4.0));
          for (int i = 0; i < count; ++i) {
            float4 posIntensity = i == 0 ? u_pointLightPosIntensity0 : i == 1 ? u_pointLightPosIntensity1
                                : i == 2 ? u_pointLightPosIntensity2 : u_pointLightPosIntensity3;
            float4 colorRadius = i == 0 ? u_pointLightColorRadius0 : i == 1 ? u_pointLightColorRadius1
                               : i == 2 ? u_pointLightColorRadius2 : u_pointLightColorRadius3;
            float3 toCenter = posIntensity.xyz - worldPos;
            float3 toLight = toCenter;
            float4 tube = u_pointLightData.read(uint2(3, i));

            // a tube lights from its nearest point, so a blade casts a sheath of light rather than a ball.
            if (tube.w > 0.0) toLight -= tube.xyz * clamp(dot(-toCenter, tube.xyz) / max(dot(tube.xyz, tube.xyz), 1e-12), -1.0, 1.0);
            float dSqr = dot(toLight, toLight);
            float d = sqrt(dSqr);
            float rSqr = colorRadius.w * colorRadius.w;
            float spread = max(rSqr, 0.25 * froxelFootprint * froxelFootprint);
            float falloff = 2.0 / max(dSqr + spread + d * sqrt(dSqr + spread), 1e-12);
            float3 aL = abs(toLight);
            float faceDistance = max(max(aL.x, aL.y), aL.z);
            float ratio = clamp(2.0 * 1.4142135 / 8192.0 / max(froxelFootprint / max(faceDistance, 1e-6), 1e-8), 1e-8, 1.0);
            int startLod = int(clamp(-log2(ratio), 0.0, 5.0));

            // a light kept from the camera lights the fog around it, but not the hot core that reads as its shape.
            float shown = u_pointLightData.read(uint2(5, i)).x > 0.5 ? 1.0
                        : smoothstep(2.0 * colorRadius.w, 2.0 * colorRadius.w + max(3.0 * colorRadius.w, 0.6), d);
            light += shown * colorRadius.xyz * posIntensity.w * PI * rSqr * falloff

                   // a strong forward lobe for the rims and shafts toward the light, a little back scatter.
                   * mix(phaseHG(dot(toLight / max(d, 1e-6), rayDir), u_volume.y), phaseHG(dot(toLight / max(d, 1e-6), rayDir), -0.3), 0.2)
                   * volumePointShadow(i, -toCenter, startLod, u_shadow_atlas, u_shadow_data, u_shadow_pagetable, _u)
                   * volumeTransmittance(d, _u);
          }
          float3 centerEye = froxelEye((float2(froxel) + 0.5) / float2(grid), (float(s) + 0.5) / 64.0, _u);
          float3 centerWorld = invView * (centerEye - float3(u_view[3][0], u_view[3][1], u_view[3][2]));
          float4 history = volumeHistory(centerWorld, grid, u_froxelHistory, _u);
          light = mix(history.rgb / max(history.a, 1e-4), light, mix(1.0, 0.1, history.a));

          float stretch = length(posEye) / depth * (u_volumeRange.y - u_volumeRange.x);
          float local = fogDensity(worldPos, u_volume.x, u_volumeNoise, u_volumeFlow, u_volumeLayer, u_zUp, u_fogDisturbers,
                                     u_fogSim, u_fogSim_smp, u_fogSimMin, u_fogSimMax);
          float slab = exp(-local * (t1 * t1 - t0 * t0) * stretch);
          o_volumeScatter_texture = float4(light, slab);
        }
      }
      """#
  }
}
