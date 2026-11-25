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

extension Akari.RenderGraph.ShaderLibrary
{
  static let sunShadowGLSL = #"""
    /// the sun shadow lookup, its edge softened by 6 short rays the caller turns a little each frame
    int shadowLevelSlot(int i)
    {
      return int(texelFetch(u_shadow_data, ivec2(4, 96 + i), 0).x);
    }

    vec3 shadowLevelDepth(int i)
    {
      return texelFetch(u_shadow_data, ivec2(5, 96 + i), 0).xyz;
    }

    vec2 shadowLevelTileOffset(int i)
    {
      return texelFetch(u_shadow_data, ivec2(4, 96 + i), 0).yz;
    }

    int directionalLevelIndex(vec3 posEye)
    {
      bool isClipmap = u_shadowLodRange.z > 0.5;
      int lodMin = int(u_shadowLodRange.x);
      int lodMax = int(u_shadowLodRange.y);
      vec3 delta = (u_eyeToLightRotation * vec4(posEye, 0.0)).xyz - u_directionalRefOffset.xyz;
      float lod;
      if (isClipmap) {
        float narrowing = 32.0 / (32.0 - 1.0001);
        lod = log2(length(delta) * narrowing * 2.0);
      } else {
        float narrowing = 32.0 / (32.0 - 2.5001);
        float lodMinMinusOne = float(lodMin - 1);
        float lodMinHalfSize = exp2(lodMinMinusOne);
        lod = length(delta.xy) * narrowing / lodMinHalfSize + lodMinMinusOne;
      }
      lod += u_shadowLodRange.w;
      int level = clamp(int(ceil(lod)), lodMin, lodMax);
      return level - lodMin;
    }

    float directionalTap(vec2 tapTileFloat, ivec2 tile, vec4 pageInfo, int slot,
                         inout ivec2 cacheTile, inout vec4 cachePage)
    {
      ivec2 tapTile = clamp(ivec2(floor(tapTileFloat)), ivec2(0), ivec2(31));
      if (tapTile != cacheTile) {
        cachePage = tapTile == tile
            ? pageInfo
            : texelFetch(u_shadow_pagetable, ivec2(tapTile.y * 32 + tapTile.x, slot), 0);
        cacheTile = tapTile;
      }
      vec4 tapPage = cachePage;
      vec2 frac = fract(tapTileFloat);
      if (tapPage.z < 0.5) {
        tapPage = pageInfo;
        frac = clamp(tapTileFloat - vec2(tile), 0.0, 0.999999);
      }
      uint v = texelFetch(u_shadow_atlas, ivec3(int(tapPage.y) * 256 + int(frac.x * 256.0),
                                                int(frac.y * 256.0), int(tapPage.x)), 0).r;
      return v == 0xFFFFFFFFu ? 1.0 : uintBitsToFloat(v);
    }

    // sun visibility, with the blocker distance in `blocker` or -1 when unshadowed
    float directionalShadow(vec3 posEye, vec3 normalEye, float NoL, vec2 noise, out float blocker)
    {
      blocker = -1.0;
      if (u_shadowEnabled < 0.5) return 1.0;

      int levelCount = int(u_shadowLevelCount);
      int i = directionalLevelIndex(posEye);
      if (i < 0) return 1.0;

      vec3 lightDelta = (u_eyeToLightRotation * vec4(posEye, 0.0)).xyz - u_directionalRefOffset.xyz;
      int lodMin = int(u_shadowLodRange.x);
      int lodMax = int(u_shadowLodRange.y);
      float scale = clamp(length(lightDelta) * 2.0, exp2(float(lodMin)), exp2(float(lodMax)));
      float sinTheta = sqrt(max(1.0 - NoL * NoL, 0.0));

      float levelSize;
      vec3 biasedPosEye;
      vec2 tileFloat;
      ivec2 tile;
      int slot;
      vec4 pageInfo = vec4(0.0);
      for (int k = 0; k < levelCount; ++k, ++i) {
        if (i >= levelCount) return 1.0;
        levelSize = exp2(u_shadowLodRange.x + float(i));
        float texelWorldSize = 1.41421356 / 8192.0 * levelSize;
        biasedPosEye = posEye + normalEye * (texelWorldSize * (sinTheta + u_shadowBias.y));
        float radius = levelSize * 0.5;
        vec3 lightRel = (u_eyeToLightRotation * vec4(biasedPosEye, 0.0)).xyz;
        vec2 lightXY = lightRel.xy + shadowLevelTileOffset(i);
        vec2 ndcXY = lightXY / radius;
        tileFloat = (ndcXY * 0.5 + 0.5) * 32.0;
        if (any(lessThan(tileFloat, vec2(0.0))) || any(greaterThanEqual(tileFloat, vec2(32.0)))) { continue; }
        tile = ivec2(tileFloat);
        slot = shadowLevelSlot(i);
        pageInfo = texelFetch(u_shadow_pagetable, ivec2(tile.y * 32 + tile.x, slot), 0);
        if (pageInfo.z > 0.5) break;
      }
      if (pageInfo.z < 0.5) return 1.0;

      vec3 lightRelZ = (u_eyeToLightRotation * vec4(biasedPosEye, 0.0)).xyz;
      vec3 levelDepth = shadowLevelDepth(i);
      float ndcZ = (lightRelZ.z + levelDepth.x) * levelDepth.y + levelDepth.z;
      float compareDepth = ndcZ * 0.5 + 0.5 - u_shadowBias.x;

      float tileTexelStep = 1.5 / 256.0 * clamp(scale * (32.0 / (32.0 - 1.0001)) / levelSize, 0.5, 1.0);

      float tileWorld = levelSize / 32.0;
      float tanHalf = tan(u_sunDirection.w);
      float depthPerWorld = abs(0.5 * levelDepth.y);
      float reach = 2.0 * tileWorld / max(tanHalf, 1e-3);
      float aa = tileTexelStep * tileWorld;
      vec3 normalLight = (u_eyeToLightRotation * vec4(normalEye, 0.0)).xyz;
      float nz = normalLight.z < 0.0 ? min(normalLight.z, -0.05) : max(normalLight.z, 0.05);
      vec2 planeSlope = normalLight.xy * (-0.5 * levelDepth.y / nz);

      float lit = 0.0;
      float blockerSum = 0.0, blockers = 0.0;
      ivec2 cacheTile = tile;
      vec4 cachePage = pageInfo;
      for (int r = 0; r < 6; ++r) {
        float phi = 6.2831853 * fract(noise.x + 0.618034 * float(r));
        vec2 disk = vec2(cos(phi), sin(phi)) * sqrt(fract(noise.y + 0.754877 * float(r)));
        float jitter = fract(noise.x + noise.y + 0.5698403 * float(r));
        float plane = dot(planeSlope, disk) * aa;
        float visible = 1.0;
        bool covered = false;
        for (int k = 0; k < 8; ++k) {
          float f = k == 0 ? 0.0 : (float(k) - 1.0 + jitter) / 7.0;
          float t = reach * f * f;
          float fNext = (float(k) + jitter) / 7.0;
          float span = k == 7 ? 1e30 : (reach * fNext * fNext - t) * depthPerWorld;
          vec2 offset = disk * (aa + tanHalf * t);
          float occluder = directionalTap(tileFloat + offset / tileWorld, tile, pageInfo, slot, cacheTile, cachePage);
          float behind = compareDepth + plane - t * depthPerWorld - occluder;
          float lift = compareDepth + dot(planeSlope, offset) - occluder;
          if ((behind > 0.0 && behind < span)
              || (covered && behind <= 0.0 && lift > (2.0 * aa + 0.05 * t) * depthPerWorld)) {
            visible = 0.0;
            blockerSum += t;
            blockers += 1.0;
            break;
          }
          covered = covered || behind >= span;
        }
        lit += visible;
      }

      if (blockers > 0.0) blocker = blockerSum / blockers;
      return lit / 6.0;
    }

    float directionalShadow(vec3 posEye, vec3 normalEye, float NoL, vec2 noise)
    {
      float blocker;
      return directionalShadow(posEye, normalEye, NoL, noise, blocker);
    }
    """#

  static let sunShadowMSL = #"""
    /// the sun shadow lookup, its edge softened by 6 short rays the caller turns a little each frame
    int shadowLevelSlot(int i, texture2d<float> dataTex)
    {
      return int(dataTex.read(uint2(4, 96 + i)).x);
    }

    float3 shadowLevelDepth(int i, texture2d<float> dataTex)
    {
      return dataTex.read(uint2(5, 96 + i)).xyz;
    }

    float2 shadowLevelTileOffset(int i, texture2d<float> dataTex)
    {
      return dataTex.read(uint2(4, 96 + i)).yz;
    }

    int directionalLevelIndex(float3 posEye, constant Uniforms& u)
    {
      bool isClipmap = u.u_shadowLodRange.z > 0.5;
      int lodMin = int(u.u_shadowLodRange.x);
      int lodMax = int(u.u_shadowLodRange.y);
      float3 delta = (u.u_eyeToLightRotation * float4(posEye, 0.0)).xyz - u.u_directionalRefOffset.xyz;
      float lod;
      if (isClipmap) {
        float narrowing = 32.0 / (32.0 - 1.0001);
        lod = log2(length(delta) * narrowing * 2.0);
      } else {
        float narrowing = 32.0 / (32.0 - 2.5001);
        float lodMinMinusOne = float(lodMin - 1);
        float lodMinHalfSize = exp2(lodMinMinusOne);
        lod = length(delta.xy) * narrowing / lodMinHalfSize + lodMinMinusOne;
      }
      lod += u.u_shadowLodRange.w;
      int level = clamp(int(ceil(lod)), lodMin, lodMax);
      return level - lodMin;
    }

    float directionalTap(float2 tapTileFloat, int2 tile, float4 pageInfo, int slot,
                         thread int2& cacheTile, thread float4& cachePage,
                         texture2d_array<uint> atlasTex, texture2d<float> pageTableTex)
    {
      int2 tapTile = clamp(int2(floor(tapTileFloat)), int2(0), int2(31));
      if (any(tapTile != cacheTile)) {
        cachePage = all(tapTile == tile)
            ? pageInfo
            : pageTableTex.read(uint2(tapTile.y * 32 + tapTile.x, slot));
        cacheTile = tapTile;
      }
      float4 tapPage = cachePage;
      float2 frac = fract(tapTileFloat);
      if (tapPage.z < 0.5) {
        tapPage = pageInfo;
        frac = clamp(tapTileFloat - float2(tile), 0.0, 0.999999);
      }
      uint v = atlasTex.read(uint2(uint(tapPage.y) * 256u + uint(frac.x * 256.0), uint(frac.y * 256.0)),
                             uint(tapPage.x)).r;
      return v == 0xFFFFFFFFu ? 1.0 : as_type<float>(v);
    }

    /// sun visibility, with the blocker distance in `blocker` or -1 when unshadowed
    float directionalShadow(float3 posEye, float3 normalEye, float NoL, float2 noise,
                            texture2d_array<uint> atlasTex, sampler atlasSmp,
                            texture2d<float> dataTex,
                            texture2d<float> pageTableTex,
                            constant Uniforms& u, thread float& blocker)
    {
      blocker = -1.0;
      if (u.u_shadowEnabled < 0.5) return 1.0;

      int levelCount = int(u.u_shadowLevelCount);
      int i = directionalLevelIndex(posEye, u);
      if (i < 0) return 1.0;

      float3 lightDelta = (u.u_eyeToLightRotation * float4(posEye, 0.0)).xyz - u.u_directionalRefOffset.xyz;
      int lodMin = int(u.u_shadowLodRange.x);
      int lodMax = int(u.u_shadowLodRange.y);
      float scale = clamp(length(lightDelta) * 2.0, exp2(float(lodMin)), exp2(float(lodMax)));
      float sinTheta = sqrt(max(1.0 - NoL * NoL, 0.0));

      float levelSize;
      float3 biasedPosEye;
      float2 tileFloat;
      int2 tile;
      int slot;
      float4 pageInfo = float4(0.0);
      for (int k = 0; k < levelCount; ++k, ++i) {
        if (i >= levelCount) return 1.0;
        levelSize = exp2(u.u_shadowLodRange.x + float(i));
        float texelWorldSize = 1.41421356 / 8192.0 * levelSize;
        biasedPosEye = posEye + normalEye * (texelWorldSize * (sinTheta + u.u_shadowBias.y));
        float radius = levelSize * 0.5;
        float3 lightRel = (u.u_eyeToLightRotation * float4(biasedPosEye, 0.0)).xyz;
        float2 lightXY = lightRel.xy + shadowLevelTileOffset(i, dataTex);
        float2 ndcXY = lightXY / radius;
        tileFloat = (ndcXY * 0.5 + 0.5) * 32.0;
        if (any(tileFloat < float2(0.0)) || any(tileFloat >= float2(32.0))) { continue; }
        tile = int2(tileFloat);
        slot = shadowLevelSlot(i, dataTex);
        pageInfo = pageTableTex.read(uint2(tile.y * 32 + tile.x, slot));
        if (pageInfo.z > 0.5) break;
      }
      if (pageInfo.z < 0.5) return 1.0;

      float3 lightRelZ = (u.u_eyeToLightRotation * float4(biasedPosEye, 0.0)).xyz;
      float3 levelDepth = shadowLevelDepth(i, dataTex);
      float ndcZ = (lightRelZ.z + levelDepth.x) * levelDepth.y + levelDepth.z;
      float compareDepth = ndcZ * 0.5 + 0.5 - u.u_shadowBias.x;

      float tileTexelStep = 1.5 / 256.0 * clamp(scale * (32.0 / (32.0 - 1.0001)) / levelSize, 0.5, 1.0);

      float tileWorld = levelSize / 32.0;
      float tanHalf = tan(u.u_sunDirection.w);
      float depthPerWorld = abs(0.5 * levelDepth.y);
      float reach = 2.0 * tileWorld / max(tanHalf, 1e-3);
      float aa = tileTexelStep * tileWorld;
      float3 normalLight = (u.u_eyeToLightRotation * float4(normalEye, 0.0)).xyz;
      float nz = normalLight.z < 0.0 ? min(normalLight.z, -0.05) : max(normalLight.z, 0.05);
      float2 planeSlope = normalLight.xy * (-0.5 * levelDepth.y / nz);

      float lit = 0.0;
      float blockerSum = 0.0, blockers = 0.0;
      int2 cacheTile = tile;
      float4 cachePage = pageInfo;
      int clearRays = 0, hardRays = 0;
      for (int r = 0; r < 6; ++r) {
        // a pixel group stops after two rays only when every ray saw nothing or hit at once, a group near an edge traces all six
        if (r == 2) {
          if (simd_all(clearRays == 2)) return 1.0;
          if (simd_all(hardRays == 2)) { blocker = 0.0; return 0.0; }
        }
        float phi = 6.2831853 * fract(noise.x + 0.618034 * float(r));
        float2 disk = float2(cos(phi), sin(phi)) * sqrt(fract(noise.y + 0.754877 * float(r)));
        float jitter = fract(noise.x + noise.y + 0.5698403 * float(r));
        float plane = dot(planeSlope, disk) * aa;
        float visible = 1.0;
        bool covered = false;
        bool firstTap = false;
        for (int k = 0; k < 8; ++k) {
          float f = k == 0 ? 0.0 : (float(k) - 1.0 + jitter) / 7.0;
          float t = reach * f * f;
          float fNext = (float(k) + jitter) / 7.0;
          float span = k == 7 ? 1e30 : (reach * fNext * fNext - t) * depthPerWorld;
          float2 offset = disk * (aa + tanHalf * t);
          float occluder = directionalTap(tileFloat + offset / tileWorld, tile, pageInfo, slot, cacheTile, cachePage,
                                          atlasTex, pageTableTex);
          float behind = compareDepth + plane - t * depthPerWorld - occluder;
          float lift = compareDepth + dot(planeSlope, offset) - occluder;
          if ((behind > 0.0 && behind < span)
              || (covered && behind <= 0.0 && lift > (2.0 * aa + 0.05 * t) * depthPerWorld)) {
            visible = 0.0;
            blockerSum += t;
            blockers += 1.0;
            firstTap = k == 0;
            break;
          }
          covered = covered || behind >= span;
        }
        lit += visible;
        if (visible > 0.5 && !covered) clearRays += 1;
        if (visible < 0.5 && firstTap) hardRays += 1;
      }

      if (blockers > 0.0) blocker = blockerSum / blockers;
      return lit / 6.0;
    }

    float directionalShadow(float3 posEye, float3 normalEye, float NoL, float2 noise,
                            texture2d_array<uint> atlasTex, sampler atlasSmp,
                            texture2d<float> dataTex,
                            texture2d<float> pageTableTex,
                            constant Uniforms& u)
    {
      float blocker;
      return directionalShadow(posEye, normalEye, NoL, noise, atlasTex, atlasSmp, dataTex, pageTableTex, u, blocker);
    }
    """#
}
