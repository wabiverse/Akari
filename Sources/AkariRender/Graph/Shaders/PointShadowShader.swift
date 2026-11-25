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
  /// drawn by the `point shadows` pass
  struct PointShadowShader: FullscreenShader
  {
    let name = "point-shadow"

    var uniforms: [Declaration]
    {
      Sampler(GBuffer.normal)
      Sampler(GBuffer.position)
      Samplers.shadowAtlas
      Samplers.shadowData
      Samplers.shadowPagetable
      Uniforms.view
      Uniforms.invProj
      Uniforms.proj
      Uniforms.viewGrid
      Uniforms.punctualShadowEnabled
      Uniforms.halfScale
      Uniforms.renderScale
      Uniforms.pointLightCount
      Uniforms.shadowedPointLightCount
      Samplers.pointLightData
      Uniforms.frameIndex
      Sampler(GlassNearBuffer.glassNear)
      Sampler(GlassNearBuffer.glassNearNormal)
      Samplers.glassLights
    }

    let fragmentGLSL = #"""
      vec4 pointLightPosIntensity(int i)
      {
        return texelFetch(u_pointLightData, ivec2(0, i), 0);
      }

      vec4 pointLightColorRadius(int i)
      {
        return texelFetch(u_pointLightData, ivec2(1, i), 0);
      }

      int punctualFaceIndex(vec3 lL)
      {
        vec3 aP = abs(lL);
        if (aP.x > aP.y && aP.x > aP.z) return lL.x > 0.0 ? 1 : 2;
        if (aP.y > aP.x && aP.y > aP.z) return lL.y > 0.0 ? 3 : 4;
        return lL.z > 0.0 ? 5 : 0;
      }

      vec3 punctualFaceLocal(int face, vec3 lL)
      {
        if (face == 1) return vec3(-lL.y, lL.z, -lL.x);
        if (face == 2) return vec3(lL.y, lL.z, lL.x);
        if (face == 3) return vec3(lL.x, lL.z, -lL.y);
        if (face == 4) return vec3(-lL.x, lL.z, lL.y);
        if (face == 5) return vec3(lL.x, -lL.y, -lL.z);
        return lL;
      }

      int punctualTileOffset(ivec2 tile, int lod)
      {
        int base = 0, size = 32;
        for (int l = 0; l < lod; l++) { base += size * size; size >>= 1; }
        return base + tile.y * size + tile.x;
      }

      float punctualLinearDepth(float depth01, vec2 nearFar)
      {
        return nearFar.x * nearFar.y / (nearFar.y - depth01 * (nearFar.y - nearFar.x));
      }

      vec2 punctualTap(vec3 lT, int lightIdx, int lod, vec2 nearFar, float biasWorld,
                       inout int cacheKey, inout vec4 cacheSlot)
      {
        int face = punctualFaceIndex(lT);
        vec3 fT = punctualFaceLocal(face, lT);
        float z = max(abs(fT.z), 1e-6);
        float zb = max(z - biasWorld, nearFar.x);
        float tapDepth = nearFar.y * (zb - nearFar.x) / ((nearFar.y - nearFar.x) * zb);
        int tilesPerSide = 32 >> lod;
        vec2 tileFloat = clamp(fT.xy / z * 0.5 + 0.5, 0.0, 0.999999) * float(tilesPerSide);
        ivec2 tile = ivec2(tileFloat);

        int key = face * 2048 + punctualTileOffset(tile, lod);
        if (key != cacheKey) {
          cacheSlot = texelFetch(u_shadow_pagetable, ivec2(key - face * 2048, lightIdx * 6 + face), 0);
          cacheKey = key;
        }
        vec4 slot = cacheSlot;
        if (slot.z < 0.5) return vec2(-1.0, tapDepth);

        vec2 frac = tileFloat - vec2(tile);
        uint v = texelFetch(u_shadow_atlas, ivec3(int(slot.y) * 256 + int(frac.x * 256.0),
                                                  int(frac.y * 256.0), int(slot.x)), 0).r;
        return vec2(v == 0xFFFFFFFFu ? 1.0 : uintBitsToFloat(v), tapDepth);
      }

      float punctualShadow(int lightIdx, vec3 worldPos, vec3 N, vec3 lightPos, float lightRadius, float NoL,
                           float noise, float filmFootprint, float lodBias, int tapCount)
      {
        if (u_punctualShadowEnabled < 0.5) return 1.0;
        vec3 lL = worldPos - lightPos;
        float distanceToLight = max(max(abs(lL.x), abs(lL.y)), abs(lL.z));
        if (distanceToLight < 1e-6) return 1.0;
        int face = punctualFaceIndex(lL);
        vec3 fL = punctualFaceLocal(face, lL);
        int tilemapIndex = lightIdx * 6 + face;
        float receiverZ = max(abs(fL.z), 1e-6);
        vec2 uvBase = clamp(fL.xy / receiverZ * 0.5 + 0.5, 0.0, 0.999999);
        vec2 nearFar = texelFetch(u_shadow_data, ivec2(5, tilemapIndex), 0).xy;

        float ratio = clamp(2.0 * 1.4142135 / 8192.0 / max(filmFootprint / distanceToLight, 1e-8), 1e-8, 1.0);
        int start = int(clamp(-log2(ratio) + 1.0 + lodBias, 0.0, 5.0));
        int lod = -1;
        int tilesPerSide = 32;
        int cacheKey = -1;
        vec4 cacheSlot = vec4(0.0);
        for (int i = 0; i <= 5; ++i) {
          int l = i <= start ? start - i : i;
          tilesPerSide = 32 >> l;
          ivec2 tile = clamp(ivec2(uvBase * float(tilesPerSide)), ivec2(0), ivec2(tilesPerSide - 1));
          cacheKey = face * 2048 + punctualTileOffset(tile, l);
          cacheSlot = texelFetch(u_shadow_pagetable, ivec2(cacheKey - face * 2048, tilemapIndex), 0);
          if (cacheSlot.z > 0.5) { lod = l; break; }
        }
        if (lod < 0) return 1.0;

        float worldPerTile = 2.0 * receiverZ / float(tilesPerSide);
        float texelWorld = worldPerTile / 256.0;
        lL += N * texelWorld * 1.5;
        float tanTheta = sqrt(max(1.0 - NoL * NoL, 0.0)) / max(NoL, 0.05);
        float biasWorld = texelWorld * (1.0 + min(tanTheta, 4.0));

        vec3 tangent = normalize(cross(N, abs(N.y) < 0.99 ? vec3(0.0, 1.0, 0.0) : vec3(1.0, 0.0, 0.0)));
        vec3 bitangent = cross(N, tangent);

        float blockerSum = 0.0;
        int blockers = 0;
        float searchRadius = clamp(lightRadius, texelWorld, worldPerTile);
        vec2 spiral = vec2(cos(noise * 6.2831853), sin(noise * 6.2831853));
        for (int i = 0; i < tapCount; ++i) {
          vec2 offset = spiral * sqrt((float(i) + 0.5) / float(tapCount)) * searchRadius;
          spiral = vec2(spiral.x * -0.73736887 - spiral.y * 0.67549029, spiral.x * 0.67549029 + spiral.y * -0.73736887);
          vec2 t = punctualTap(lL + tangent * offset.x + bitangent * offset.y, lightIdx, lod, nearFar, biasWorld,
                               cacheKey, cacheSlot);
          if (t.x >= 0.0 && t.x < t.y) { blockerSum += punctualLinearDepth(t.x, nearFar); blockers++; }
        }
        if (blockers == 0) return 1.0;

        float blockerZ = blockerSum / float(blockers);
        float penumbra = lightRadius * max(receiverZ - blockerZ, 0.0) / max(blockerZ, 1e-4);
        float filterRadius = clamp(penumbra, texelWorld, worldPerTile);
        if (blockers == tapCount && filterRadius <= searchRadius) return 0.0;

        float lit = 0.0;
        float taps = 0.0;
        spiral = vec2(cos(noise * 6.2831853), sin(noise * 6.2831853));
        for (int i = 0; i < tapCount; ++i) {
          vec2 offset = spiral * sqrt((float(i) + 0.5) / float(tapCount)) * filterRadius;
          spiral = vec2(spiral.x * -0.73736887 - spiral.y * 0.67549029, spiral.x * 0.67549029 + spiral.y * -0.73736887);
          vec2 t = punctualTap(lL + tangent * offset.x + bitangent * offset.y, lightIdx, lod, nearFar, biasWorld,
                               cacheKey, cacheSlot);
          if (t.x < 0.0) continue;
          lit += t.y <= t.x ? 1.0 : 0.0;
          taps += 1.0;
        }
        return taps > 0.0 ? lit / taps : 1.0;
      }

      // screen space contact shadow toward a light, 0 when something on screen blocks it
      float contactShadow(vec3 posEye, vec3 lightEye, float rayLength, float spread, float noise)
      {
        float metre = max(u_viewGrid.y, 1e-6);
        ivec2 size = textureSize(u_position_texture, 0);

        float occlusion = 0.0;
        for (int i = 1; i <= 8; ++i) {
          vec3 p = posEye + lightEye * (rayLength * (float(i) - noise) / 8.0);
          vec4 clip = u_proj * vec4(p, 1.0);
          if (clip.w <= 0.0) break;
          vec2 uv = clip.xy / clip.w * 0.5 + 0.5;
          if (any(lessThan(uv, vec2(0.0))) || any(greaterThanEqual(uv, vec2(1.0)))) break;
          ivec2 pixel = ivec2(uv * vec2(size));
          if (texelFetch(u_normal_texture, pixel, 0).a < 0.5) continue;
          float depthGap = texelFetch(u_position_texture, pixel, 0).z - p.z;
          float bias = 0.002 * abs(p.z);
          float thickness = max(0.03 * metre, 0.02 * abs(p.z));

          // a blocker deeper inside the light's cone covers more of the light
          float cone = max(spread * rayLength * (float(i) - noise) / 8.0, bias);
          if (depthGap > bias && depthGap < thickness) occlusion = max(occlusion, clamp((depthGap - bias) / cone, 0.0, 1.0));
        }
        return 1.0 - occlusion;
      }

      void main()
      {
        ivec2 fullSize = textureSize(u_position_texture, 0);
        ivec2 fp = min(ivec2(floor(gl_FragCoord.xy) * u_halfScale.xy), fullSize - 1);
        vec4 n = texelFetch(u_normal_texture, fp, 0);
        vec3 posEye = texelFetch(u_position_texture, fp, 0).xyz;
        o_pointShadowGuide_texture = vec4(normalize(n.xyz), posEye.z);

        o_pointShadowRaw0_texture = vec4(1.0);
        o_pointShadowRaw1_texture = vec4(1.0);
        o_pointShadowRaw2_texture = vec4(1.0);
        o_pointShadowRaw3_texture = vec4(1.0);
        if (n.a < 0.5 || u_punctualShadowEnabled < 0.5) return;

        mat4 invView = inverse(u_view);
        vec3 worldPos = (invView * vec4(posEye, 1.0)).xyz;
        vec3 N = normalize(mat3(invView) * n.xyz);

        vec2 noisePixel = gl_FragCoord.xy + 5.588238 * float(frameIndex % 64);
        float noise = fract(52.9829189 * fract(dot(noisePixel, vec2(0.06711056, 0.00583715))));
        float filmFootprint = abs(posEye.z) * 2.0 * u_invProj[1][1] / max(float(fullSize.y), float(fullSize.y) / max(u_renderScale.y, 1e-4));

        mat4 shadows = mat4(vec4(1.0), vec4(1.0), vec4(1.0), vec4(1.0));
        int count = int(min(u_shadowedPointLightCount, 16.0));

        // a secondary light's shadow only matters where it brings a fair share of the direct light
        float total = 0.0;
        for (int i = 0; i < count; ++i) {
          vec4 pi = pointLightPosIntensity(i);
          vec4 cr = pointLightColorRadius(i);
          vec3 tl = pi.xyz - worldPos;
          float dd = max(dot(tl, tl), cr.w * cr.w);
          total += pi.w * max(cr.x, max(cr.y, cr.z)) * cr.w * cr.w / dd * max(dot(N, tl * inversesqrt(dd)), 0.0);
        }
        for (int i = 0; i < count; ++i) {
          vec4 posIntensity = pointLightPosIntensity(i);
          vec4 colorRadius = pointLightColorRadius(i);
          vec3 toLight = posIntensity.xyz - worldPos;
          float d = length(toLight);
          vec4 tier = texelFetch(u_pointLightData, ivec2(2, i), 0);
          if (d * d > colorRadius.w * colorRadius.w * posIntensity.w
                      * max(colorRadius.x, max(colorRadius.y, colorRadius.z)) * (tier.w > 0.5 ? 1000.0 : 100.0)) continue;

          float NoL = dot(N, toLight / max(d, 1e-6));
          if (NoL < -colorRadius.w / max(d, 1e-6)) continue;
          float share = posIntensity.w * max(colorRadius.x, max(colorRadius.y, colorRadius.z)) * colorRadius.w * colorRadius.w
                      / max(d * d, colorRadius.w * colorRadius.w) * max(NoL, 0.0);
          if (tier.w < 0.5 && share < 0.04 * total) continue;

          shadows[i >> 2][i & 3] = punctualShadow(i, worldPos, N, posIntensity.xyz, colorRadius.w, max(NoL, 0.0),
                                                  noise, filmFootprint, tier.z, tier.w > 0.5 ? 6 : 4);
          if (shadows[i >> 2][i & 3] > 0.01) {
            float spread = colorRadius.w / sqrt(max(d * d - colorRadius.w * colorRadius.w, 1e-8));
            vec3 lightEye = normalize((u_view * vec4(toLight, 0.0)).xyz);
            vec3 startEye = posEye + normalize(n.xyz) * (0.002 * abs(posEye.z));
            shadows[i >> 2][i & 3] *= contactShadow(startEye, lightEye, min(0.25 * max(u_viewGrid.y, 1e-6), 0.5 * d), spread, noise);
          }
        }

        o_pointShadowRaw0_texture = shadows[0];
        o_pointShadowRaw1_texture = shadows[1];
        o_pointShadowRaw2_texture = shadows[2];
        o_pointShadowRaw3_texture = shadows[3];
      }
      """#

    let fragmentMSL = #"""
      int punctualFaceIndex(float3 lL)
      {
        float3 aP = abs(lL);
        if (aP.x > aP.y && aP.x > aP.z) return lL.x > 0.0 ? 1 : 2;
        if (aP.y > aP.x && aP.y > aP.z) return lL.y > 0.0 ? 3 : 4;
        return lL.z > 0.0 ? 5 : 0;
      }

      float3 punctualFaceLocal(int face, float3 lL)
      {
        if (face == 1) return float3(-lL.y, lL.z, -lL.x);
        if (face == 2) return float3(lL.y, lL.z, lL.x);
        if (face == 3) return float3(lL.x, lL.z, -lL.y);
        if (face == 4) return float3(-lL.x, lL.z, lL.y);
        if (face == 5) return float3(lL.x, -lL.y, -lL.z);
        return lL;
      }

      int punctualTileOffset(int2 tile, int lod)
      {
        int base = 0, size = 32;
        for (int l = 0; l < lod; l++) { base += size * size; size >>= 1; }
        return base + tile.y * size + tile.x;
      }

      float punctualLinearDepth(float depth01, float2 nearFar)
      {
        return nearFar.x * nearFar.y / (nearFar.y - depth01 * (nearFar.y - nearFar.x));
      }

      float2 punctualTap(float3 lT, int lightIdx, int lod, float2 nearFar, float biasWorld,
                         thread int& cacheKey, thread float4& cacheSlot,
                         texture2d_array<uint> atlasTex, texture2d<float> pageTableTex)
      {
        int face = punctualFaceIndex(lT);
        float3 fT = punctualFaceLocal(face, lT);
        float z = max(abs(fT.z), 1e-6);
        float zb = max(z - biasWorld, nearFar.x);
        float tapDepth = nearFar.y * (zb - nearFar.x) / ((nearFar.y - nearFar.x) * zb);
        int tilesPerSide = 32 >> lod;
        float2 tileFloat = clamp(fT.xy / z * 0.5 + 0.5, 0.0, 0.999999) * float(tilesPerSide);
        int2 tile = int2(tileFloat);

        int key = face * 2048 + punctualTileOffset(tile, lod);
        if (key != cacheKey) {
          cacheSlot = pageTableTex.read(uint2(key - face * 2048, lightIdx * 6 + face));
          cacheKey = key;
        }
        float4 slot = cacheSlot;
        if (slot.z < 0.5) return float2(-1.0, tapDepth);

        float2 frac = tileFloat - float2(tile);
        uint v = atlasTex.read(uint2(uint(slot.y) * 256u + uint(frac.x * 256.0),
                                     uint(frac.y * 256.0)), uint(slot.x)).r;
        return float2(v == 0xFFFFFFFFu ? 1.0 : as_type<float>(v), tapDepth);
      }

      float punctualShadow(int lightIdx, float3 worldPos, float3 N, float3 lightPos, float lightRadius, float NoL,
                           float noise, float filmFootprint, float lodBias, int tapCount,
                           texture2d_array<uint> atlasTex, sampler atlasSmp,
                           texture2d<float> dataTex, texture2d<float> pageTableTex,
                           constant Uniforms& u, float ignoreNear, float moved)
      {
        if (u.u_punctualShadowEnabled < 0.5) return 1.0;
        float3 lL = worldPos - lightPos;
        float distanceToLight = max(max(abs(lL.x), abs(lL.y)), abs(lL.z));
        if (distanceToLight < 1e-6) return 1.0;
        int face = punctualFaceIndex(lL);
        float3 fL = punctualFaceLocal(face, lL);
        int tilemapIndex = lightIdx * 6 + face;
        float receiverZ = max(abs(fL.z), 1e-6);
        float2 uvBase = clamp(fL.xy / receiverZ * 0.5 + 0.5, 0.0, 0.999999);
        float2 nearFar = dataTex.read(uint2(5, tilemapIndex)).xy;

        // a tube's own hilt and the hand holding it sit inside its length, where the map from its center would make a hard disc
        float nearCut = ignoreNear > nearFar.x ? nearFar.y * (ignoreNear - nearFar.x) / ((nearFar.y - nearFar.x) * ignoreNear) : -1.0;

        float ratio = clamp(2.0 * 1.4142135 / 8192.0 / max(filmFootprint / distanceToLight, 1e-8), 1e-8, 1.0);
        int start = int(clamp(-log2(ratio) + 1.0 + lodBias, 0.0, 5.0));
        int lod = -1;
        int tilesPerSide = 32;
        int cacheKey = -1;
        float4 cacheSlot = float4(0.0);
        for (int i = 0; i <= 5; ++i) {
          int l = i <= start ? start - i : i;
          tilesPerSide = 32 >> l;
          int2 tile = clamp(int2(uvBase * float(tilesPerSide)), int2(0), int2(tilesPerSide - 1));
          cacheKey = face * 2048 + punctualTileOffset(tile, l);
          cacheSlot = pageTableTex.read(uint2(cacheKey - face * 2048, tilemapIndex));
          if (cacheSlot.z > 0.5) { lod = l; break; }
        }
        if (lod < 0) return 1.0;

        float worldPerTile = 2.0 * receiverZ / float(tilesPerSide);
        float texelWorld = worldPerTile / 256.0;
        lL += N * texelWorld * 1.5;
        float tanTheta = sqrt(max(1.0 - NoL * NoL, 0.0)) / max(NoL, 0.05);

        // a moving light's pages can lag a frame behind, so the bias allows for how far it moved
        float biasWorld = texelWorld * (1.0 + min(tanTheta, 4.0)) + moved * 2.0;

        float3 tangent = normalize(cross(N, abs(N.y) < 0.99 ? float3(0.0, 1.0, 0.0) : float3(1.0, 0.0, 0.0)));
        float3 bitangent = cross(N, tangent);

        float blockerSum = 0.0;
        int blockers = 0;
        float searchRadius = clamp(lightRadius, texelWorld, worldPerTile);
        float2 spiral = float2(cos(noise * 6.2831853), sin(noise * 6.2831853));
        for (int i = 0; i < tapCount; ++i) {
          float2 offset = spiral * sqrt((float(i) + 0.5) / float(tapCount)) * searchRadius;
          spiral = float2(spiral.x * -0.73736887 - spiral.y * 0.67549029, spiral.x * 0.67549029 + spiral.y * -0.73736887);
          float2 t = punctualTap(lL + tangent * offset.x + bitangent * offset.y, lightIdx, lod, nearFar, biasWorld,
                                 cacheKey, cacheSlot, atlasTex, pageTableTex);
          if (t.x >= 0.0 && t.x < t.y && t.x > nearCut) { blockerSum += punctualLinearDepth(t.x, nearFar); blockers++; }
        }
        if (blockers == 0) return 1.0;

        float blockerZ = blockerSum / float(blockers);
        float penumbra = lightRadius * max(receiverZ - blockerZ, 0.0) / max(blockerZ, 1e-4);
        float filterRadius = clamp(penumbra, texelWorld, worldPerTile);
        if (blockers == tapCount && filterRadius <= searchRadius) return 0.0;

        float lit = 0.0;
        float taps = 0.0;
        spiral = float2(cos(noise * 6.2831853), sin(noise * 6.2831853));
        for (int i = 0; i < tapCount; ++i) {
          float2 offset = spiral * sqrt((float(i) + 0.5) / float(tapCount)) * filterRadius;
          spiral = float2(spiral.x * -0.73736887 - spiral.y * 0.67549029, spiral.x * 0.67549029 + spiral.y * -0.73736887);
          float2 t = punctualTap(lL + tangent * offset.x + bitangent * offset.y, lightIdx, lod, nearFar, biasWorld,
                                 cacheKey, cacheSlot, atlasTex, pageTableTex);
          if (t.x < 0.0) continue;
          lit += t.y <= t.x || t.x <= nearCut ? 1.0 : 0.0;
          taps += 1.0;
        }
        return taps > 0.0 ? lit / taps : 1.0;
      }

      // screen space contact shadow toward a light, 0 when something on screen blocks it
      float contactShadow(float3 posEye, float3 lightEye, float rayLength, float spread, float noise,
                          texture2d<float> positionTex, texture2d<float> normalTex, constant Uniforms& u)
      {
        float metre = max(u.u_viewGrid.y, 1e-6);
        float2 size = float2(positionTex.get_width(), positionTex.get_height());

        float occlusion = 0.0;
        for (int i = 1; i <= 8; ++i) {
          float3 p = posEye + lightEye * (rayLength * (float(i) - noise) / 8.0);
          float4 clip = u.u_proj * float4(p, 1.0);
          if (clip.w <= 0.0) break;
          float2 uv = clip.xy / clip.w * 0.5 + 0.5;
          if (any(uv < float2(0.0)) || any(uv >= float2(1.0))) break;
          uint2 pixel = uint2(uv * size);
          if (normalTex.read(pixel).a < 0.5) continue;
          float depthGap = positionTex.read(pixel).z - p.z;
          float bias = 0.002 * abs(p.z);
          float thickness = max(0.03 * metre, 0.02 * abs(p.z));

          // a blocker deeper inside the light's cone covers more of the light
          float cone = max(spread * rayLength * (float(i) - noise) / 8.0, bias);
          if (depthGap > bias && depthGap < thickness) occlusion = max(occlusion, saturate((depthGap - bias) / cone));
        }
        return 1.0 - occlusion;
      }

      \#(ShaderLibrary.glassLightMSL)

      //@main
      {
        int2 fullSize = int2(u_position_texture.get_width(), u_position_texture.get_height());
        uint2 fp = uint2(min(int2(floor(gl_FragCoord.xy) * u_halfScale.xy), fullSize - 1));
        float4 n = u_normal_texture.read(fp);
        float3 posEye = u_position_texture.read(fp).xyz;
        o_pointShadowGuide_texture = float4(normalize(n.xyz), posEye.z);

        o_pointShadowRaw0_texture = float4(1.0);
        o_pointShadowRaw1_texture = float4(1.0);
        o_pointShadowRaw2_texture = float4(1.0);
        o_pointShadowRaw3_texture = float4(1.0);
        if (n.a >= 0.5 && u_punctualShadowEnabled >= 0.5) {
          float3x3 invView = float3x3(
            float3(u_view[0][0], u_view[1][0], u_view[2][0]),
            float3(u_view[0][1], u_view[1][1], u_view[2][1]),
            float3(u_view[0][2], u_view[1][2], u_view[2][2])
          );

          float3 worldPos = invView * (posEye - float3(u_view[3][0], u_view[3][1], u_view[3][2]));
          float3 N = normalize(invView * n.xyz);

          float2 noisePixel = gl_FragCoord.xy + 5.588238 * float(frameIndex % 64);
          float noise = fract(52.9829189 * fract(dot(noisePixel, float2(0.06711056, 0.00583715))));
          float filmFootprint = abs(posEye.z) * 2.0 * u_invProj[1][1] / max(float(fullSize.y), float(fullSize.y) / max(u_renderScale.y, 1e-4));

          float4x4 shadows = float4x4(float4(1.0), float4(1.0), float4(1.0), float4(1.0));
          int count = int(min(u_shadowedPointLightCount, 16.0));

          // a secondary light's shadow only matters where it brings a fair share of the direct light
          float total = 0.0;
          for (int i = 0; i < count; ++i) {
            float4 pi = u_pointLightData.read(uint2(0, i));
            float4 cr = u_pointLightData.read(uint2(1, i));
            float3 tl = pi.xyz - worldPos;
            float dd = max(dot(tl, tl), cr.w * cr.w);
            total += pi.w * max(cr.x, max(cr.y, cr.z)) * cr.w * cr.w / dd * max(dot(N, tl * rsqrt(dd)), 0.0);
          }
          for (int i = 0; i < count; ++i) {
            float4 posIntensity = u_pointLightData.read(uint2(0, i));
            float4 colorRadius = u_pointLightData.read(uint2(1, i));
            float3 toLight = posIntensity.xyz - worldPos;
            float d = length(toLight);
            float4 tier = u_pointLightData.read(uint2(2, i));
            float range = colorRadius.w * colorRadius.w * posIntensity.w
                        * max(colorRadius.x, max(colorRadius.y, colorRadius.z)) * (tier.w > 0.5 ? 1000.0 : 100.0);
            if (d * d > range) continue;

            float NoL = dot(N, toLight / max(d, 1e-6));
            if (NoL < -colorRadius.w / max(d, 1e-6)) continue;
            float share = posIntensity.w * max(colorRadius.x, max(colorRadius.y, colorRadius.z)) * colorRadius.w * colorRadius.w
                        / max(d * d, colorRadius.w * colorRadius.w) * max(NoL, 0.0);
            if (tier.w < 0.5 && share < 0.02 * total) continue;

            // ease the shadow out toward where it stops being looked up so it has no hard edge
            float keep = (1.0 - smoothstep(0.5, 1.0, d * d / range))
                       * (tier.w > 0.5 ? 1.0 : smoothstep(0.02, 0.06, share / max(total, 1e-12)));
            float4 tube = u_pointLightData.read(uint2(3, i));

            shadows[i >> 2][i & 3] = punctualShadow(i, worldPos, N, posIntensity.xyz, colorRadius.w, max(NoL, 0.0),
                                                    noise, filmFootprint, tier.z, tier.w > 0.5 ? 6 : 4,
                                                    u_shadow_atlas, u_shadow_atlas_smp,
                                                    u_shadow_data, u_shadow_pagetable, _u,
                                                    tube.w > 0.0 ? length(tube.xyz) * 1.25 : 0.0,
                                                    u_pointLightData.read(uint2(4, i)).w);
            if (shadows[i >> 2][i & 3] > 0.01) {
              float spread = colorRadius.w / sqrt(max(d * d - colorRadius.w * colorRadius.w, 1e-8));
              float3 lightEye = normalize((u_view * float4(toLight, 0.0)).xyz);
              float3 startEye = posEye + normalize(n.xyz) * (0.002 * abs(posEye.z));
              shadows[i >> 2][i & 3] *= contactShadow(startEye, lightEye, min(0.25 * max(u_viewGrid.y, 1e-6), 0.5 * d), spread, noise,
                                                      u_position_texture, u_normal_texture, _u);
            }

            // glass between here and the light blocks it too, so its shadow filters and blends like opaque ones
            if (i < \#(GlassAtlas.localLights)) {
              float behind;
              shadows[i >> 2][i & 3] *= glassVisible(worldPos, \#(GlassAtlas.localTile(slot: 0)) + i, u_glassLights,
                                                     u_glassNear_texture, u_glassNearNormal_texture, noise, behind);
            }

            shadows[i >> 2][i & 3] = mix(1.0, shadows[i >> 2][i & 3], keep);

            // a tube's ends light past the terminator its center map sees, so only trust the map when facing the center
            if (tube.w > 0.0) shadows[i >> 2][i & 3] = max(shadows[i >> 2][i & 3], saturate(1.0 - NoL * 10.0));
          }

          o_pointShadowRaw0_texture = shadows[0];
          o_pointShadowRaw1_texture = shadows[1];
          o_pointShadowRaw2_texture = shadows[2];
          o_pointShadowRaw3_texture = shadows[3];
        }
      }
      """#
  }
}
