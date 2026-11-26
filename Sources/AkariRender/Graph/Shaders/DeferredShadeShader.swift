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
  /// drawn by the `resolve` pass.
  struct DeferredShadeShader: FullscreenShader
  {
    let name = "deferred-shade"

    var uniforms: [Declaration]
    {
      Uniforms.iblTint
      Sampler(PlanetCloudMapBuffer.planetCloudMap)
      Sampler(GBuffer.normal)
      Sampler(GBuffer.position)
      Sampler(GBuffer.diffuse)
      Sampler(GBuffer.material)
      Sampler(GBuffer.specular)
      Sampler(EnvCubeBuffer.envCube, .samplerCube)
      Sampler(PrefilteredBuffer.prefiltered, .samplerCube)
      Sampler(IrradianceBuffer.irradiance, .samplerCube)
      Sampler(DfgBuffer.dfg)
      Samplers.domeMap
      Samplers.shadowAtlas
      Samplers.shadowData
      Samplers.shadowPagetable
      Uniforms.view
      Uniforms.iblEnabled
      Uniforms.domeEnabled
      Uniforms.domeFromWorld
      Uniforms.domeColor
      Uniforms.domeSun
      Uniforms.sunOverride
      Uniforms.viewShading
      Uniforms.viewGrid
      Uniforms.invProj
      Uniforms.sunHeight
      Uniforms.zUp
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
      Samplers.pointLightData
      Samplers.ltcMatrix
      Samplers.ltcAmplitude
      Uniforms.pointLightPosIntensity0
      Uniforms.pointLightPosIntensity1
      Uniforms.pointLightPosIntensity2
      Uniforms.pointLightPosIntensity3
      Uniforms.pointLightColorRadius0
      Uniforms.pointLightColorRadius1
      Uniforms.pointLightColorRadius2
      Uniforms.pointLightColorRadius3
      Sampler(SsgiAccumBuffer.ssgiAccum)
      Sampler(SsgiAccumBuffer.ssgiSpecAccum)
      Sampler(SsgiAccumBuffer.ssgiBentAccum)
      Sampler(SsgiPrepBuffer.ssgiDepth)
      Sampler(SsgiPrepBuffer.ssgiNormal)
      Uniforms.ssgi
      Sampler(PointShadowBuffer.pointShadow0)
      Sampler(PointShadowBuffer.pointShadow1)
      Sampler(PointShadowBuffer.pointShadow2)
      Sampler(PointShadowBuffer.pointShadow3)
      Sampler(PointShadowRawBuffer.pointShadowGuide)
      Sampler(VolumeIntegratedBuffer.volumeIntegrated)
      Uniforms.volume
      Uniforms.volumeRange
      Sampler(SsrAccumBuffer.ssrAccum)
      Sampler(SsrBuffer.ssrGuide)
      Sampler(SunShadowSoftBuffer.sunShadowSoft)
      Sampler(GlassCausticAccumBuffer.glassSunCausticAccum)
      Sampler(GlassCausticAccumBuffer.glassLocalCausticAccum)
      Uniforms.glass
      Uniforms.ssr
      Uniforms.halfScale
      Uniforms.horizonScan
      Samplers.probeVolume
      Samplers.probeSphere
      Samplers.probeInfo
      Uniforms.probeGridMin
      Uniforms.probeGridMax
      Uniforms.probeGridSize
      Sampler(AtmosTransmittanceBuffer.atmosTransmittance)
      Sampler(AtmosAerialBuffer.atmosAerial)
      Samplers.primStyle
      Uniforms.atmosphere
      Uniforms.atmosRayleigh
      Uniforms.atmosMie
      Uniforms.atmosMieExtra
      Uniforms.atmosOzone
      Uniforms.atmosGround
      Uniforms.atmosCamera
      Uniforms.atmosSun
      Uniforms.atmosFrame
      Uniforms.atmosPlanetFromWorld
      Uniforms.planet
      Uniforms.planetTerrain
      Uniforms.planetOcean
      Uniforms.planetClouds
      Uniforms.planetCity
      Uniforms.planetCloudShape
      Uniforms.planetPaletteA
      Uniforms.planetPaletteB
      Uniforms.planetLook
      Uniforms.planetStyle
      Uniforms.frameIndex
    }

    let fragmentGLSL = #"""
      const float PI = 3.14159265358979;
      const float LIGHT_INTENSITY = 3.0;
      const float MOON_INTENSITY = 0.12;

      vec3 F_Schlick(vec3 f0, float VoH)
      {
        float f = pow(1.0 - VoH, 5.0);
        return f + f0 * (1.0 - f);
      }

      float D_GGX(float roughness, float NoH)
      {
        float a = NoH * roughness;
        float k = min(roughness / (1.0 - NoH * NoH + a * a), 453.5);
        return k * k * (1.0 / PI);
      }

      float V_SmithGGXCorrelatedFast(float roughness, float NoV, float NoL)
      {
        return 0.5 / mix(2.0 * NoL * NoV, NoL + NoV, roughness);
      }

      vec3 toSkySpace(vec3 v)
      {
        return mix(v, vec3(v.x, v.z, -v.y), u_zUp);
      }

      vec4 pointLightPosIntensity(int i)
      {
        vec4 v = u_pointLightPosIntensity0;
        if (i == 1)      v = u_pointLightPosIntensity1;
        else if (i == 2) v = u_pointLightPosIntensity2;
        else if (i == 3) v = u_pointLightPosIntensity3;
        return v;
      }

      vec4 pointLightColorRadius(int i)
      {
        vec4 v = u_pointLightColorRadius0;
        if (i == 1)      v = u_pointLightColorRadius1;
        else if (i == 2) v = u_pointLightColorRadius2;
        else if (i == 3) v = u_pointLightColorRadius3;
        return v;
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

      // interreflection returns some of the light occlusion removed, more so on bright surfaces.
      vec3 multiBounce(float visibility, vec3 albedo)
      {
        vec3 a = 2.0404 * albedo - 0.3324;
        vec3 b = -4.7951 * albedo + 0.6417;
        vec3 c = 2.7552 * albedo + 0.6903;
        return max(vec3(visibility), ((visibility * a + b) * visibility + c) * visibility);
      }

      vec3 finiteColor(vec3 c)
      {
        bvec3 bad = equal(floatBitsToUint(c) & 0x7F800000u, uvec3(0x7F800000u));
        return mix(clamp(c, 0.0, 65000.0), vec3(0.0), bad);
      }

      vec4 volumeBoundary(int b, vec2 f, vec2 grid, vec2 atlasSize)
      {
        if (b == 0) return vec4(0.0, 0.0, 0.0, 1.0);
        vec2 origin = vec2(float((b - 1) % 8), float((b - 1) / 8)) * grid;
        return texture(u_volumeIntegrated_texture, (origin + f) / atlasSize);
      }

      vec4 volumeFog(vec2 fragCoord, float viewDepth)
      {
        if (u_volume.z < 0.5) return vec4(0.0, 0.0, 0.0, 1.0);
        vec2 atlasSize = vec2(textureSize(u_volumeIntegrated_texture, 0));
        vec2 grid = u_volumeRange.zw;
        vec2 f = clamp(fragCoord / (8.0 * u_halfScale.xy), vec2(0.5), grid - 0.5);
        float u = sqrt(clamp((viewDepth - u_volumeRange.x) / (u_volumeRange.y - u_volumeRange.x), 0.0, 1.0)) * 64.0;
        int b = min(int(u), 63);
        return mix(volumeBoundary(b, f, grid, atlasSize), volumeBoundary(b + 1, f, grid, atlasSize), u - float(b));
      }

      vec4 ssgiUpsample(sampler2D accum, ivec2 pixel, vec3 posEye, vec3 normalEye)
      {
        if (u_ssgi.z < 0.5) return vec4(0.0, 0.0, 0.0, 1.0);
        ivec2 halfSize = textureSize(accum, 0);
        vec2 hc = (vec2(pixel) + 0.5) / u_halfScale.xy - 0.5;
        ivec2 base = ivec2(floor(hc));
        vec2 f = hc - vec2(base);
        vec4 sum = vec4(0.0);
        float weight = 0.0;
        for (int i = 0; i < 4; ++i) {
          ivec2 o = ivec2(i & 1, i >> 1);
          ivec2 h = clamp(base + o, ivec2(0), halfSize - 1);
          float bilinear = (o.x == 1 ? f.x : 1.0 - f.x) * (o.y == 1 ? f.y : 1.0 - f.y);
          float dz = abs(texelFetch(u_ssgiDepth_texture, h, 0).x - posEye.z);
          float w = bilinear * exp(-dz / max(0.02 * abs(posEye.z), 1e-3))
                  * pow(max(dot(texelFetch(u_ssgiNormal_texture, h, 0).xyz, normalEye), 0.0), 8.0) + 1e-4 * bilinear;
          sum += texelFetch(accum, h, 0) * w;
          weight += w;
        }
        return sum / weight;
      }

      mat4 pointShadowUpsample(ivec2 pixel, vec3 posEye, vec3 normalEye)
      {
        if (u_punctualShadowEnabled < 0.5) return mat4(vec4(1.0), vec4(1.0), vec4(1.0), vec4(1.0));
        ivec2 halfSize = textureSize(u_pointShadow0_texture, 0);
        vec2 hc = (vec2(pixel) + 0.5) / u_halfScale.xy - 0.5;
        ivec2 base = ivec2(floor(hc));
        vec2 f = hc - vec2(base);
        mat4 sum = mat4(0.0);
        float weight = 0.0;
        for (int i = 0; i < 4; ++i) {
          ivec2 o = ivec2(i & 1, i >> 1);
          ivec2 h = clamp(base + o, ivec2(0), halfSize - 1);
          vec4 guide = texelFetch(u_pointShadowGuide_texture, h, 0);
          float bilinear = (o.x == 1 ? f.x : 1.0 - f.x) * (o.y == 1 ? f.y : 1.0 - f.y);
          float w = bilinear * exp(-abs(guide.w - posEye.z) / max(0.02 * abs(posEye.z), 1e-3))
                  * pow(max(dot(guide.xyz, normalEye), 0.0), 8.0) + 1e-4 * bilinear;
          sum += mat4(texelFetch(u_pointShadow0_texture, h, 0), texelFetch(u_pointShadow1_texture, h, 0),
                      texelFetch(u_pointShadow2_texture, h, 0), texelFetch(u_pointShadow3_texture, h, 0)) * w;
          weight += w;
        }
        return sum * (1.0 / weight);
      }

      vec4 ssrUpsample(ivec2 pixel, vec3 posEye, vec3 normalEye, float roughness)
      {
        if (u_ssr.z < 0.5) return vec4(0.0);
        ivec2 halfSize = textureSize(u_ssrAccum_texture, 0);
        vec2 hc = (vec2(pixel) + 0.5) / u_halfScale.xy - 0.5;
        ivec2 base = ivec2(floor(hc));

        // a mirror keeps the plain bilinear footprint, a glossy lobe widens it so the leftover grain melts into the blur it already has
        float radius = mix(1.0, 2.0, clamp(roughness * 5.0, 0.0, 1.0));
        vec4 sum = vec4(0.0);
        float weight = 0.0;
        for (int i = 0; i < 16; ++i) {
          ivec2 o = ivec2(i & 3, i >> 2) - 1;
          ivec2 h = clamp(base + o, ivec2(0), halfSize - 1);
          vec4 guide = texelFetch(u_ssrGuide_texture, h, 0);
          vec2 d = abs(vec2(base + o) - hc) / radius;
          float tent = max(1.0 - d.x, 0.0) * max(1.0 - d.y, 0.0);

          // looser than an exact match so a pixel blends its texels rather than snapping to one in blocks
          float w = tent * exp(-abs(guide.w - posEye.z) / max(0.04 * abs(posEye.z), 1e-3))
                  * pow(max(dot(guide.xyz, normalEye), 0.0), 4.0);
          sum += texelFetch(u_ssrAccum_texture, h, 0) * w;
          weight += w;
        }
        if (weight < 1e-4 || sum.a < 1e-4) return vec4(0.0);
        return vec4(sum.rgb / sum.a, sum.a / weight * clamp(weight * 10.0, 0.0, 1.0));
      }

      vec3 pointLightRadiance(vec3 worldPos, vec3 N, vec3 V, float NoV,
                              float roughness, vec3 f0, vec3 diffuseColor, mat4 shadows)
      {
        vec3 color = vec3(0.0);
        int count = int(min(u_pointLightCount, 64.0));
        for (int i = 0; i < count; ++i) {
          vec4 posIntensity = texelFetch(u_pointLightData, ivec2(0, i), 0);
          vec4 colorRadius = texelFetch(u_pointLightData, ivec2(1, i), 0);
          vec2 lobes = texelFetch(u_pointLightData, ivec2(2, i), 0).xy;

          vec3 toLight = posIntensity.xyz - worldPos;
          float distSq = max(dot(toLight, toLight), colorRadius.w * colorRadius.w);
          if (distSq > colorRadius.w * colorRadius.w * posIntensity.w
                        * max(colorRadius.x, max(colorRadius.y, colorRadius.z)) * 1000.0) continue;
          vec3 L = normalize(toLight);
          float cosTheta = dot(N, L);
          float sinSigmaSqr = min(colorRadius.w * colorRadius.w / distSq, 0.9999);
          float irradiance = sphereIrradiance(cosTheta, sinSigmaSqr);
          if (irradiance <= 0.0) continue;

          float NoL = max(cosTheta, 0.0);
          vec3 R = reflect(-V, N);
          vec3 centerToRay = dot(toLight, R) * R - toLight;
          vec3 Ls = normalize(toLight + centerToRay
                              * clamp(colorRadius.w / max(length(centerToRay), 1e-6), 0.0, 1.0));
          float NoLs = max(dot(N, Ls), 0.0);
          float widened = clamp(roughness + colorRadius.w / (2.0 * sqrt(distSq)), 0.0, 1.0);
          float normalization = (roughness / widened) * (roughness / widened);

          vec3 H = normalize(V + Ls);
          float NoH = max(dot(N, H), 0.0);
          float LoH = max(dot(Ls, H), 0.0);
          float D = D_GGX(roughness, NoH);
          float Vis = V_SmithGGXCorrelatedFast(roughness, NoV, max(NoLs, 1e-4));
          vec3 F = F_Schlick(f0, LoH);

          vec3 kD = vec3(1.0) - F;
          vec3 Fr = D * Vis * F * (PI * sinSigmaSqr * NoLs * normalization);
          vec3 Fd = (kD * diffuseColor / PI) * irradiance;

          color += (Fd * lobes.x + Fr * lobes.y) * colorRadius.xyz * posIntensity.w * (i < int(u_shadowedPointLightCount) ? shadows[i >> 2][i & 3] : 1.0);
        }
        return color;
      }

      void main()
      {
        ivec2 gbufferPixel = ivec2(gl_FragCoord.xy);
        vec4 normalSample = texelFetch(u_normal_texture, gbufferPixel, 0);
        vec3 normalEye = normalSample.xyz;
        vec3 posEye = texelFetch(u_position_texture, gbufferPixel, 0).xyz;
        vec3 diffuse = texelFetch(u_diffuse_texture, gbufferPixel, 0).xyz;
        vec2 materialSample = texelFetch(u_material_texture, gbufferPixel, 0).rg;

        mat4 invViewFull = inverse(u_view);
        mat3 invView = mat3(invViewFull);
        vec3 worldPos = (invViewFull * vec4(posEye, 1.0)).xyz;

        if (u_viewShading.x > 1.5) {
          vec3 n = normalize(normalEye);
          float studio = 0.25 + 0.6 * clamp(dot(n, normalize(vec3(-0.35, 0.55, 0.75))), 0.0, 1.0)
                       + 0.25 * clamp(dot(n, normalize(vec3(0.6, -0.15, 0.5))), 0.0, 1.0);
          vec3 shade = u_viewShading.x > 2.5 ? vec3(u_viewShading.z) : vec3(0.8 * studio);
          o_final_texture = vec4(normalSample.a < 0.5 ? vec3(u_viewShading.y) : shade, 1.0);
          return;
        }

        if (normalSample.a < 0.5) {
          if (u_iblEnabled > 0.5) {
            vec4 e = u_invProj * vec4(var.texCoord * 2.0 - 1.0, -1.0, 1.0);
            vec3 worldDir = normalize(invView * (e.xyz / e.w));
            vec3 sky = texture(u_envCube_texture, toSkySpace(worldDir)).rgb * u_iblTint.rgb;
            if (u_viewShading.x > 0.5) sky = textureLod(u_prefiltered_texture, toSkySpace(worldDir), 3.0).rgb * u_iblTint.rgb;
            else if (u_domeEnabled > 0.0) {
              vec3 d = normalize(mat3(u_domeFromWorld) * worldDir);
              vec2 uv = vec2((atan(d.z, d.x) + 0.5 * PI) / (2.0 * PI), acos(clamp(d.y, -1.0, 1.0)) / PI);
              sky = mix(sky, textureLod(u_domeMap, vec2(fract(uv.x), uv.y), 0.0).rgb * u_domeColor.rgb, u_domeEnabled);
            }
            vec4 fog = volumeFog(gl_FragCoord.xy, u_volumeRange.y);
            o_final_texture = vec4(sky * fog.a + fog.rgb, 1.0);
          } else {
            o_final_texture = vec4(diffuse, 1.0);
          }
          return;
        }

        vec3 N = normalize(invView * normalEye);
        vec3 V = normalize(invView * (-posEye));
        float NoV = max(dot(N, V), 1e-4);

        float perceptualRoughness = clamp(materialSample.r, 0.045, 1.0);
        float roughness = perceptualRoughness * perceptualRoughness;
        float metallic = clamp(materialSample.g, 0.0, 1.0);
        vec3 baseColor = diffuse;

        // what the surface reflects facing the eye, from its index of refraction or its specular color
        vec3 specular = texelFetch(u_specular_texture, gbufferPixel, 0).rgb;
        vec3 f0 = mix(specular, baseColor, metallic);
        vec3 diffuseColor = baseColor * (1.0 - metallic);

        vec3 L = normalize(u_sunDirection.xyz);
        float nightFade = smoothstep(-0.3, 0.05, sunHeight);

        vec2 noisePixel = gl_FragCoord.xy + 5.588238 * float(frameIndex % 64);
        float noise = fract(52.9829189 * fract(dot(noisePixel, vec2(0.06711056, 0.00583715))));
        float noiseB = fract(52.9829189 * fract(dot(noisePixel.yx, vec2(0.06711056, 0.00583715))));

        vec3 color = vec3(0.0);
        float cosTheta = dot(N, L);
        float sinSigma = sin(u_sunDirection.w);
        float sinSigmaSqr = max(sinSigma * sinSigma, 1e-7);
        float sunIrradiance = sphereIrradiance(cosTheta, sinSigmaSqr) / (PI * sinSigmaSqr);
        if (sunIrradiance > 0.0) {
          float NoL = max(cosTheta, 0.0);
          float tanSigma = tan(u_sunDirection.w);
          vec3 R = reflect(-V, N);
          vec3 centerToRay = dot(L, R) * R - L;
          vec3 Ls = normalize(L + centerToRay * clamp(tanSigma / max(length(centerToRay), 1e-6), 0.0, 1.0));
          float NoLs = max(dot(N, Ls), 0.0);
          float widened = clamp(roughness + 0.5 * tanSigma, 0.0, 1.0);
          float normalization = (roughness / widened) * (roughness / widened);

          vec3 H = normalize(V + Ls);
          float NoH = max(dot(N, H), 0.0);
          float LoH = max(dot(Ls, H), 0.0);
          float D = D_GGX(roughness, NoH);

          float Vis = V_SmithGGXCorrelatedFast(roughness, NoV, max(NoLs, 1e-4));
          vec3 F = F_Schlick(f0, LoH);

          vec3 kD = vec3(1.0) - F;
          vec3 Fr = D * Vis * F * NoLs * normalization;
          vec3 Fd = (kD * diffuseColor / PI) * sunIrradiance;

          vec3 skyL = toSkySpace(L);
          vec3 dayColor = mix(texture(u_envCube_texture, skyL).rgb * u_iblTint.rgb, vec3(1.0), clamp(sunHeight, 0.0, 1.0));
          vec3 nightColor = mix(texture(u_envCube_texture, skyL).rgb * u_iblTint.rgb, vec3(0.95, 0.95, 1.00), clamp(-sunHeight, 0.0, 1.0));
          vec3 dynamicSky = mix(nightColor * MOON_INTENSITY, dayColor * LIGHT_INTENSITY, nightFade);

          float shadow = texelFetch(u_sunShadowSoft_texture, gbufferPixel, 0).r;

          color += (Fd + Fr) * mix(mix(dynamicSky, u_domeSun.rgb, u_domeEnabled) * u_iblEnabled, u_sunOverride.rgb, u_sunOverride.w) * shadow;
        }

        color += pointLightRadiance(worldPos, N, V, NoV, roughness, f0, diffuseColor,
                                    pointShadowUpsample(gbufferPixel, posEye, normalEye));

        vec2 dfgTexel = 0.5 / vec2(textureSize(u_dfg_texture, 0));
        vec3 dfg = texture(u_dfg_texture, clamp(vec2(NoV, perceptualRoughness), dfgTexel, 1.0 - dfgTexel)).rgb;
        vec3 E = f0 * dfg.x + dfg.y;
        vec3 energyCompensation = 1.0 + f0 * (1.0 / max(dfg.x + dfg.y, 1e-4) - 1.0);

        vec3 r = reflect(-V, N);
        r = mix(r, N, roughness * roughness);

        float lod = 5.0 * perceptualRoughness;
        lod = clamp(lod, 0.0, 5.0);

        vec3 prefilteredRadiance = textureLod(u_prefiltered_texture, toSkySpace(r), lod).rgb * u_iblTint.rgb;

        vec4 gi = ssgiUpsample(u_ssgiAccum_texture, gbufferPixel, posEye, normalEye);
        float specularOcclusion = clamp(pow(NoV + gi.a, exp2(-16.0 * roughness - 1.0)) - 1.0 + gi.a, 0.0, 1.0);
        vec3 irradiance = texture(u_irradiance_texture, toSkySpace(N)).rgb * u_iblTint.rgb;
        vec3 Fd = diffuseColor * irradiance * multiBounce(gi.a, diffuseColor) * (1.0 - E);

        vec4 reflection = ssrUpsample(gbufferPixel, posEye, normalEye, perceptualRoughness);
        vec3 traced = mix(prefilteredRadiance * specularOcclusion * u_iblEnabled, reflection.rgb, reflection.a);
        vec4 horizon = ssgiUpsample(u_ssgiSpecAccum_texture, gbufferPixel, posEye, normalEye);
        float horizonMix = u_horizonScan.y * clamp((perceptualRoughness - u_horizonScan.x) / 0.2, 0.0, 1.0);
        vec3 Fr = E * energyCompensation
                * mix(traced, horizon.rgb + prefilteredRadiance * horizon.a * u_iblEnabled, horizonMix);

        color += Fd * u_iblEnabled + Fr + diffuseColor * gi.rgb * (1.0 - E);

        color += vec3(texelFetch(u_material_texture, gbufferPixel, 0).ba,
                      texelFetch(u_diffuse_texture, gbufferPixel, 0).w);

        vec4 fog = volumeFog(gl_FragCoord.xy, -posEye.z);
        color = color * fog.a + fog.rgb;

        o_final_texture = vec4(finiteColor(color), 1.0);
      }
      """#

    let fragmentMSL = #"""
      \#(ShaderLibrary.atmosphereMSL)
      \#(ShaderLibrary.styleMSL)
      constexpr constant float PI = 3.14159265358979;
      constexpr constant float LIGHT_INTENSITY = 3.0;
      constexpr constant float MOON_INTENSITY = 0.12;

      float3 F_Schlick(float3 f0, float VoH)
      {
        float f = pow(1.0 - VoH, 5.0);
        return f + f0 * (1.0 - f);
      }

      float D_GGX(float roughness, float NoH)
      {
        float a = NoH * roughness;
        float k = min(roughness / (1.0 - NoH * NoH + a * a), 453.5);
        return k * k * (1.0 / PI);
      }

      float V_SmithGGXCorrelatedFast(float roughness, float NoV, float NoL)
      {
        return 0.5 / mix(2.0 * NoL * NoV, NoL + NoV, roughness);
      }

      float3 toSkySpace(float3 v, float zUp)
      {
        return mix(v, float3(v.x, v.z, -v.y), zUp);
      }

      float4 pointLightPosIntensity(int i, constant Uniforms& u)
      {
        float4 v = u.u_pointLightPosIntensity0;
        if (i == 1)      v = u.u_pointLightPosIntensity1;
        else if (i == 2) v = u.u_pointLightPosIntensity2;
        else if (i == 3) v = u.u_pointLightPosIntensity3;
        return v;
      }

      float4 pointLightColorRadius(int i, constant Uniforms& u)
      {
        float4 v = u.u_pointLightColorRadius0;
        if (i == 1)      v = u.u_pointLightColorRadius1;
        else if (i == 2) v = u.u_pointLightColorRadius2;
        else if (i == 3) v = u.u_pointLightColorRadius3;
        return v;
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

      // interreflection returns some of the light occlusion removed, more so on bright surfaces.
      float3 multiBounce(float visibility, float3 albedo)
      {
        float3 a = 2.0404 * albedo - 0.3324;
        float3 b = -4.7951 * albedo + 0.6417;
        float3 c = 2.7552 * albedo + 0.6903;
        return max(float3(visibility), ((visibility * a + b) * visibility + c) * visibility);
      }

      float3 finiteColor(float3 c)
      {
        bool3 bad = (as_type<uint3>(c) & 0x7F800000u) == 0x7F800000u;
        return select(clamp(c, 0.0, 65000.0), float3(0.0), bad);
      }

      float4 volumeBoundary(int b, float2 f, float2 grid, float2 atlasSize,
                            texture2d<float> integrated, sampler integratedSmp)
      {
        if (b == 0) return float4(0.0, 0.0, 0.0, 1.0);
        float2 origin = float2(float((b - 1) % 8), float((b - 1) / 8)) * grid;
        return integrated.sample(integratedSmp, (origin + f) / atlasSize);
      }

      float4 volumeFog(float2 fragCoord, float viewDepth,
                       texture2d<float> integrated, sampler integratedSmp, constant Uniforms& u)
      {
        if (u.u_volume.z < 0.5) return float4(0.0, 0.0, 0.0, 1.0);
        float2 atlasSize = float2(integrated.get_width(), integrated.get_height());
        float2 grid = u.u_volumeRange.zw;
        float2 f = clamp(fragCoord / (8.0 * u.u_halfScale.xy), float2(0.5), grid - 0.5);
        float t = sqrt(saturate((viewDepth - u.u_volumeRange.x) / (u.u_volumeRange.y - u.u_volumeRange.x))) * 64.0;
        int b = min(int(t), 63);
        return mix(volumeBoundary(b, f, grid, atlasSize, integrated, integratedSmp),
                   volumeBoundary(b + 1, f, grid, atlasSize, integrated, integratedSmp), t - float(b));
      }

      float4 ssgiUpsample(uint2 pixel, float3 posEye, float3 normalEye,
                          texture2d<float> accum, texture2d<float> depth, texture2d<float> normal,
                          constant Uniforms& u)
      {
        if (u.u_ssgi.z < 0.5) return float4(0.0, 0.0, 0.0, 1.0);
        int2 halfSize = int2(accum.get_width(), accum.get_height());
        float2 hc = (float2(pixel) + 0.5) / u.u_halfScale.xy - 0.5;
        int2 base = int2(floor(hc));
        float2 f = hc - float2(base);
        float4 sum = float4(0.0);
        float weight = 0.0;
        for (int i = 0; i < 4; ++i) {
          int2 o = int2(i & 1, i >> 1);
          uint2 h = uint2(clamp(base + o, int2(0), halfSize - 1));
          float bilinear = (o.x == 1 ? f.x : 1.0 - f.x) * (o.y == 1 ? f.y : 1.0 - f.y);
          float dz = abs(depth.read(h).x - posEye.z);
          float w = bilinear * exp(-dz / max(0.02 * abs(posEye.z), 1e-3))
                  * pow(max(dot(normal.read(h).xyz, normalEye), 0.0), 8.0) + 1e-4 * bilinear;
          sum += accum.read(h) * w;
          weight += w;
        }
        return sum / weight;
      }

      float4x4 pointShadowUpsample(uint2 pixel, float3 posEye, float3 normalEye,
                                   texture2d<float> shadows0, texture2d<float> shadows1,
                                   texture2d<float> shadows2, texture2d<float> shadows3,
                                   texture2d<float> guides, constant Uniforms& u)
      {
        if (u.u_punctualShadowEnabled < 0.5) return float4x4(float4(1.0), float4(1.0), float4(1.0), float4(1.0));
        int2 halfSize = int2(shadows0.get_width(), shadows0.get_height());
        float2 hc = (float2(pixel) + 0.5) / u.u_halfScale.xy - 0.5;
        int2 base = int2(floor(hc));
        float2 f = hc - float2(base);
        float4x4 sum = float4x4(0.0);
        float weight = 0.0;
        for (int i = 0; i < 4; ++i) {
          int2 o = int2(i & 1, i >> 1);
          uint2 h = uint2(clamp(base + o, int2(0), halfSize - 1));
          float4 guide = guides.read(h);
          float bilinear = (o.x == 1 ? f.x : 1.0 - f.x) * (o.y == 1 ? f.y : 1.0 - f.y);
          float w = bilinear * exp(-abs(guide.w - posEye.z) / max(0.02 * abs(posEye.z), 1e-3))
                  * pow(max(dot(guide.xyz, normalEye), 0.0), 8.0) + 1e-4 * bilinear;
          sum += float4x4(shadows0.read(h), shadows1.read(h), shadows2.read(h), shadows3.read(h)) * w;
          weight += w;
        }
        return sum * (1.0 / weight);
      }

      float4 ssrUpsample(uint2 pixel, float3 posEye, float3 normalEye, float roughness,
                         texture2d<float> radianceTex, texture2d<float> guideTex, constant Uniforms& u)
      {
        if (u.u_ssr.z < 0.5) return float4(0.0);
        int2 halfSize = int2(radianceTex.get_width(), radianceTex.get_height());
        float2 hc = (float2(pixel) + 0.5) / u.u_halfScale.xy - 0.5;
        int2 base = int2(floor(hc));

        // a mirror keeps the plain bilinear footprint, a glossy lobe widens it so the leftover grain melts into the blur it already has
        float radius = mix(1.0, 2.0, saturate(roughness * 5.0));
        float4 sum = float4(0.0);
        float weight = 0.0;
        for (int i = 0; i < 16; ++i) {
          int2 o = int2(i & 3, i >> 2) - 1;
          uint2 h = uint2(clamp(base + o, int2(0), halfSize - 1));
          float4 guide = guideTex.read(h);
          float2 d = abs(float2(base + o) - hc) / radius;
          float tent = max(1.0 - d.x, 0.0) * max(1.0 - d.y, 0.0);

          // looser than an exact match so a pixel blends its texels rather than snapping to one in blocks
          float w = tent * exp(-abs(guide.w - posEye.z) / max(0.04 * abs(posEye.z), 1e-3))
                  * pow(max(dot(guide.xyz, normalEye), 0.0), 4.0);
          sum += radianceTex.read(h) * w;
          weight += w;
        }
        if (weight < 1e-4 || sum.a < 1e-4) return float4(0.0);
        return float4(sum.rgb / sum.a, sum.a / weight * saturate(weight * 10.0));
      }

      \#(ShaderLibrary.probeVolumeMSL)

      \#(ShaderLibrary.probeSphereMSL)

      float3 probeSphereRadiance(float3 worldPos, float3 R, float perceptualRoughness, float3 fallback,
                                 texture2d<float> atlas, sampler smp, texture2d<float> info,
                                 constant Uniforms& u)
      {
        int count = int(u.u_probeGridMax.w);
        float lod = saturate(perceptualRoughness) * 4.0;
        int mip = min(int(lod), 3);
        float blend = lod - float(mip);
        float3 result = fallback;
        for (int i = 0; i < count; ++i) {
          float4 sphere = info.read(uint2(i, 0));
          float3 d = worldPos - sphere.xyz;
          float dist = length(d);
          if (dist >= sphere.w) continue;
          float w = saturate((sphere.w - dist) / (0.2 * sphere.w)) * info.read(uint2(i, 1)).x;
          if (w <= 0.0) continue;
          float b = dot(d, R);
          float hit = -b + sqrt(max(b * b - dot(d, d) + sphere.w * sphere.w, 0.0));
          float3 dir = normalize(mix(normalize(d + R * hit), R, perceptualRoughness * perceptualRoughness));
          float3 radiance = mix(probeSphereMip(atlas, smp, i, mip, dir),
                                probeSphereMip(atlas, smp, i, mip + 1, dir), blend);
          result = mix(result, radiance, w);
        }
        return result;
      }

      // one edge of lambert's polygon integral, the arc between two directions weighted by how it leans over the normal
      float lambertEdge(float3 a, float3 b, float3 N)
      {
        a = normalize(a);
        b = normalize(b);
        float3 c = cross(a, b);
        float lc = length(c);
        return lc > 1e-7 ? acos(clamp(dot(a, b), -1.0, 1.0)) * dot(N, c) / lc : 0.0;
      }

      // adds a clipped polygon's next vertex to its running edge integral, the horizon being the z = 0 plane
      void polygonStep(float3 a, float3 b, thread float3& first, thread float3& last, thread bool& started, thread float& sum)
      {
        if (a.z >= 0.0) {
          if (started) sum += lambertEdge(last, a, float3(0.0, 0.0, 1.0)); else first = a;
          last = a;
          started = true;
        }
        if ((a.z >= 0.0) != (b.z >= 0.0)) {
          float3 c = a + (b - a) * (a.z / (a.z - b.z));
          if (started) sum += lambertEdge(last, c, float3(0.0, 0.0, 1.0)); else first = c;
          last = c;
          started = true;
        }
      }

      float3 pointLightRadiance(float3 worldPos, float3 N, float3 V, float NoV,
                                float roughness, float3 f0, float3 diffuseColor,
                                float4x4 shadows, texture2d<float> lightData,
                                texture2d<float> ltcMatrix, sampler ltcMatrixSmp,
                                texture2d<float> ltcAmplitude, sampler ltcAmplitudeSmp, constant Uniforms& u)
      {
        float3 color = float3(0.0);
        int count = int(min(u.u_pointLightCount, 64.0));

        // heitz's linearly transformed cosine turning this roughness and view's ggx lobe into a clamped cosine, for area light highlights
        float2 ltcUv = float2(sqrt(roughness), sqrt(1.0 - NoV)) * (63.0 / 64.0) + 0.5 / 64.0;
        float4 ltcM = ltcMatrix.sample(ltcMatrixSmp, ltcUv);
        float2 ltcA = ltcAmplitude.sample(ltcAmplitudeSmp, ltcUv).xy;
        float3 T1 = V - N * dot(V, N);
        T1 = dot(T1, T1) > 1e-10 ? normalize(T1) : normalize(cross(N, abs(N.z) < 0.9 ? float3(0.0, 0.0, 1.0) : float3(1.0, 0.0, 0.0)));
        float3x3 ltcInverse = float3x3(float3(ltcM.x, 0.0, ltcM.y), float3(0.0, 1.0, 0.0), float3(ltcM.z, 0.0, ltcM.w))
                            * transpose(float3x3(T1, cross(N, T1), N));
        float3 ltcGain = f0 * (ltcA.x - ltcA.y) + ltcA.y;
        for (int i = 0; i < count; ++i) {
          float4 posIntensity = lightData.read(uint2(0, i));
          float4 colorRadius = lightData.read(uint2(1, i));
          float2 lobes = lightData.read(uint2(2, i)).xy;
          float4 tube = lightData.read(uint2(3, i));

          float3 toLight = posIntensity.xyz - worldPos;
          float distSq = max(dot(toLight, toLight), colorRadius.w * colorRadius.w);
          float reach = colorRadius.w * colorRadius.w * posIntensity.w * max(colorRadius.x, max(colorRadius.y, colorRadius.z)) * 1000.0;
          if (distSq > reach) continue;
          float window = 1.0 - (distSq / reach) * (distSq / reach);
          window *= window;
          float3 L = normalize(toLight);
          float cosTheta = dot(N, L);
          float3 R = reflect(-V, N);
          float radius = colorRadius.w;
          float sinSigmaSqr = min(radius * radius / distSq, 0.9999);
          float irradiance = 0.0;
          float lineEnergy = 0.0;
          float facing = 1.0;
          float3 areaSpecular = float3(-1.0);
          if (tube.w > 0.0) {
            // picott's line integral over the part of the tube above the horizon, karis's closest point for the highlight.
            float3 l0 = toLight - tube.xyz, l1 = toLight + tube.xyz;
            float n0 = dot(N, l0), n1 = dot(N, l1);
            if (n0 < 0.0 && n1 > 0.0) l0 += (l1 - l0) * (n0 / (n0 - n1));
            else if (n1 < 0.0 && n0 > 0.0) l1 += (l0 - l1) * (n1 / (n1 - n0));
            float len0 = length(l0), len1 = length(l1);
            float3 ld = l1 - l0;
            if (max(n0, n1) > 0.0) {
              irradiance = min(2.0 * tube.w * length(ld) * (max(dot(N, l0), 0.0) / max(len0, 1e-6) + max(dot(N, l1), 0.0) / max(len1, 1e-6))
                               / max(len0 * len1 + dot(l0, l1), tube.w * tube.w), PI);
            }
            float3 full = 2.0 * tube.xyz;
            float rd = dot(R, full);
            float t = saturate((dot(R, toLight - tube.xyz) * rd - dot(toLight - tube.xyz, full)) / max(dot(full, full) - rd * rd, 1e-6));
            toLight = toLight - tube.xyz + full * t;
            distSq = max(dot(toLight, toLight), tube.w * tube.w);
            radius = tube.w;
            sinSigmaSqr = min(radius * radius / distSq, 0.9999);
            lineEnergy = 2.0 * length(full) / (PI * tube.w);
          } else if (tube.w < 0.0) {
            // lambert's exact polygon integral over the rect clipped to the horizon, the closest point to the reflection for the fresnel.
            float3 hx = tube.xyz, hy = lightData.read(uint2(4, i)).xyz;
            float4 shape = lightData.read(uint2(5, i));

            // a double sided glowing mesh lights from its back as it does from its front
            if (dot(cross(hx, hy), toLight) <= 0.0) {
              if (shape.z < 0.5) continue;
              hx = -hx;
            }
            // the diffuse integral in the shading frame and the highlight's in the cosine's, both clipped to their horizon
            float3x3 shading = transpose(float3x3(T1, cross(N, T1), N));
            float sum = 0.0, specularSum = 0.0;
            float3 first = float3(0.0), last = float3(0.0), specularFirst = float3(0.0), specularLast = float3(0.0);
            bool started = false, specularStarted = false;
            if (tube.w < -1.5) {
              // a glowing mesh lights a point exactly as its outline does
              int points = int(shape.y);
              for (int k = 0; k < points; ++k) {
                float3 a = lightData.read(uint2(6 + k, i)).xyz - worldPos;
                float3 b = lightData.read(uint2(6 + (k + 1) % points, i)).xyz - worldPos;
                polygonStep(shading * a, shading * b, first, last, started, sum);
                polygonStep(ltcInverse * a, ltcInverse * b, specularFirst, specularLast, specularStarted, specularSum);
              }
            } else {
              float3 corners[4] = { toLight - hx - hy, toLight + hx - hy, toLight + hx + hy, toLight - hx + hy };
              for (int k = 0; k < 4; ++k) {
                float3 a = corners[k], b = corners[(k + 1) & 3];
                polygonStep(shading * a, shading * b, first, last, started, sum);
                polygonStep(ltcInverse * a, ltcInverse * b, specularFirst, specularLast, specularStarted, specularSum);
              }
            }
            if (started) sum += lambertEdge(last, first, float3(0.0, 0.0, 1.0));
            if (specularStarted) specularSum += lambertEdge(specularLast, specularFirst, float3(0.0, 0.0, 1.0));
            irradiance = 0.5 * abs(sum);
            areaSpecular = ltcGain * (0.5 * abs(specularSum) / PI);
            float3 nL = normalize(cross(hx, hy));
            facing = saturate(dot(nL, normalize(toLight)));
            float rn = dot(nL, R);
            float3 hit = rn > 1e-4 ? R * (dot(nL, toLight) / rn) - toLight : R - nL * rn;
            toLight += hx * clamp(dot(hit, hx) / max(dot(hx, hx), 1e-12), -1.0, 1.0)
                     + hy * clamp(dot(hit, hy) / max(dot(hy, hy), 1e-12), -1.0, 1.0);
            distSq = max(dot(toLight, toLight), 1e-8);
            radius = sqrt(4.0 * length(hx) * length(hy) / PI);
            sinSigmaSqr = min(radius * radius / distSq, 0.9999);
          } else {
            irradiance = sphereIrradiance(cosTheta, sinSigmaSqr);
          }
          if (irradiance <= 0.0) continue;

          float NoL = max(cosTheta, 0.0);
          float3 centerToRay = dot(toLight, R) * R - toLight;
          float3 Ls = normalize(toLight + centerToRay
                                * clamp(radius / max(length(centerToRay), 1e-6), 0.0, 1.0));
          float NoLs = max(dot(N, Ls), 0.0);
          float widened = clamp(roughness + radius / (2.0 * sqrt(distSq)), 0.0, 1.0);
          float normalization = (roughness / widened) * (roughness / widened);
          float along = widened / (widened + length(tube.xyz) / sqrt(distSq));
          normalization *= 1.0 + lineEnergy * along * along;

          float3 H = normalize(V + Ls);
          float NoH = max(dot(N, H), 0.0);
          float LoH = max(dot(Ls, H), 0.0);
          float D = D_GGX(roughness, NoH);
          float Vis = V_SmithGGXCorrelatedFast(roughness, NoV, max(NoLs, 1e-4));
          float3 F = F_Schlick(f0, LoH);

          float3 kD = float3(1.0) - F;
          float3 Fr = D * Vis * F * (PI * sinSigmaSqr * NoLs * normalization * facing);
          float3 Fd = (kD * diffuseColor / PI) * irradiance;

          // a rect or glowing mesh highlights with the exact ggx integral over its polygon, the rest with the closest point
          if (areaSpecular.x >= 0.0) Fr = areaSpecular;

          color += (Fd * lobes.x + Fr * lobes.y) * colorRadius.xyz * posIntensity.w * window * (i < int(u.u_shadowedPointLightCount) ? shadows[i >> 2][i & 3] : 1.0);
        }
        return color;
      }

      //@main
      {
        uint2 gbufferPixel = uint2(gl_FragCoord.xy);
        float4 normalSample = u_normal_texture.read(gbufferPixel);
        float3 normalEye = normalSample.xyz;
        float3 posEye = u_position_texture.read(gbufferPixel).xyz;
        float3 diffuse = u_diffuse_texture.read(gbufferPixel).xyz;
        float2 materialSample = u_material_texture.read(gbufferPixel).rg;

        float3x3 invView = float3x3(
          float3(u_view[0][0], u_view[1][0], u_view[2][0]),
          float3(u_view[0][1], u_view[1][1], u_view[2][1]),
          float3(u_view[0][2], u_view[1][2], u_view[2][2])
        );

        float3 worldPos = invView * (posEye - float3(u_view[3][0], u_view[3][1], u_view[3][2]));

        if (normalSample.a < 0.5) {
          if (u_iblEnabled > 0.5) {
            float4 e = u_invProj * float4(var.texCoord * 2.0 - 1.0, -1.0, 1.0);
            float3 worldDir = normalize(invView * (e.xyz / e.w));
            float3 sky = texture(u_envCube_texture, toSkySpace(worldDir, u_zUp)).rgb * u_iblTint.rgb;
            if (u_viewShading.x > 0.5) sky = textureLod(u_prefiltered_texture, toSkySpace(worldDir, u_zUp), 3.0).rgb * u_iblTint.rgb;
            else if (u_domeEnabled > 0.0) {
              float3x3 rot = float3x3(u_domeFromWorld[0].xyz, u_domeFromWorld[1].xyz, u_domeFromWorld[2].xyz);
              float3 d = normalize(rot * worldDir);
              float2 uv = float2((atan2(d.z, d.x) + 0.5 * PI) / (2.0 * PI), acos(clamp(d.y, -1.0, 1.0)) / PI);
              sky = mix(sky, textureLod(u_domeMap, float2(fract(uv.x), uv.y), 0.0).rgb * u_domeColor.rgb, u_domeEnabled);
            }
            float4 fog = volumeFog(gl_FragCoord.xy, u_volumeRange.y,
                                   u_volumeIntegrated_texture, u_volumeIntegrated_texture_smp, _u);
            o_final_texture = float4(sky * fog.a + fog.rgb, 1.0);
          } else {
            o_final_texture = float4(diffuse, 1.0);
          }
        } else {
          float3 N = normalize(invView * normalEye);
          float3 V = normalize(invView * (-posEye));
          float NoV = max(dot(N, V), 1e-4);

          float perceptualRoughness = saturate(max(materialSample.r, 0.045));
          float roughness = perceptualRoughness * perceptualRoughness;
          float metallic = saturate(materialSample.g);
          float3 baseColor = diffuse;

          // what the surface reflects facing the eye, from its index of refraction or its specular color
          float3 specular = u_specular_texture.read(gbufferPixel).rgb;
          float3 f0 = mix(specular, baseColor, metallic);
          float3 diffuseColor = baseColor * (1.0 - metallic);

          float3 L = normalize(u_sunDirection.xyz);
          float nightFade = smoothstep(-0.3, 0.05, sunHeight);

          float2 noisePixel = gl_FragCoord.xy + 5.588238 * float(frameIndex % 64);
          float noise = fract(52.9829189 * fract(dot(noisePixel, float2(0.06711056, 0.00583715))));
          float noiseB = fract(52.9829189 * fract(dot(noisePixel.yx, float2(0.06711056, 0.00583715))));

          float3 color = float3(0.0);
          float3 sunLight = float3(0.0);
          float3 sunShadow = float3(1.0);
          float cosTheta = dot(N, L);
          float sinSigma = sin(u_sunDirection.w);
          float sinSigmaSqr = max(sinSigma * sinSigma, 1e-7);
          float sunIrradiance = sphereIrradiance(cosTheta, sinSigmaSqr) / (PI * sinSigmaSqr);

          // the caustics come back up to this pixel from the four nearest at its depth, softened and blended at their own size
          float3 sunCaustic = float3(0.0), localCaustic = float3(0.0);
          bool wantSunCaustic = u_glass.x > 0.5 && sunIrradiance > 0.0;
          if (wantSunCaustic || u_glass.y > 0.5) {
            float2 causticSize = float2(u_glassSunCausticAccum_texture.get_width(), u_glassSunCausticAccum_texture.get_height());
            float2 gbufferSize = float2(u_position_texture.get_width(), u_position_texture.get_height());
            float2 at = (float2(gbufferPixel) + 0.5) * causticSize / gbufferSize - 0.5;
            int2 base = int2(floor(at));
            float2 f = at - floor(at);
            float depth = log2(max(-posEye.z, 1e-4));
            float total = 0.0;
            for (int k = 0; k < 4; ++k) {
              int2 o = int2(k & 1, k >> 1);
              uint2 q = uint2(clamp(base + o, int2(0), int2(causticSize) - 1));
              float4 s = u_glassSunCausticAccum_texture.read(q);
              float w = (o.x == 1 ? f.x : 1.0 - f.x) * (o.y == 1 ? f.y : 1.0 - f.y) * exp(-abs(s.a - depth) * 40.0) + 1e-6;
              sunCaustic += s.rgb * w;
              localCaustic += u_glassLocalCausticAccum_texture.read(q).rgb * w;
              total += w;
            }
            sunCaustic = wantSunCaustic ? sunCaustic / total : float3(0.0);
            localCaustic = u_glass.y > 0.5 ? localCaustic / total : float3(0.0);
          }
          if (sunIrradiance > 0.0) {
            float NoL = max(cosTheta, 0.0);
            float tanSigma = tan(u_sunDirection.w);
            float3 R = reflect(-V, N);
            float3 centerToRay = dot(L, R) * R - L;
            float3 Ls = normalize(L + centerToRay * clamp(tanSigma / max(length(centerToRay), 1e-6), 0.0, 1.0));
            float NoLs = max(dot(N, Ls), 0.0);
            float widened = clamp(roughness + 0.5 * tanSigma, 0.0, 1.0);
            float normalization = (roughness / widened) * (roughness / widened);

            float3 H = normalize(V + Ls);
            float NoH = max(dot(N, H), 0.0);
            float LoH = max(dot(Ls, H), 0.0);
            float D = D_GGX(roughness, NoH);

            float Vis = V_SmithGGXCorrelatedFast(roughness, NoV, max(NoLs, 1e-4));
            float3 F = F_Schlick(f0, LoH);

            float3 kD = float3(1.0) - F;
            float3 Fr = D * Vis * F * NoLs * normalization;
            float3 Fd = (kD * diffuseColor / PI) * sunIrradiance;

            float3 skyL = toSkySpace(L, u_zUp);
            float3 dayColor = mix(texture(u_envCube_texture, skyL).rgb * u_iblTint.rgb, float3(1.0), saturate(sunHeight));
            float3 nightColor = mix(texture(u_envCube_texture, skyL).rgb * u_iblTint.rgb, float3(0.95, 0.95, 1.00), saturate(-sunHeight));
            float3 dynamicSky = mix(nightColor * MOON_INTENSITY, dayColor * LIGHT_INTENSITY, nightFade);

            float shadow = u_sunShadowSoft_texture.read(gbufferPixel).r;

            float3 sunColor = mix(mix(dynamicSky, u_domeSun.rgb, u_domeEnabled) * u_iblEnabled, u_sunOverride.rgb, u_sunOverride.w);
            if (u_atmosphere.x > 0.5) {
              Atmosphere atm = makeAtmosphere(u_atmosphere, u_atmosRayleigh, u_atmosMie, u_atmosMieExtra, u_atmosOzone, u_atmosGround);
              float3 p = u_atmosCamera.xyz + invView * posEye * u_atmosFrame.x;
              float r = length(p);
              AtmosphereSurface surface;
              surface.planetFromWorld = float3x3(u_atmosPlanetFromWorld[0].xyz, u_atmosPlanetFromWorld[1].xyz, u_atmosPlanetFromWorld[2].xyz);
              surface.zUp = u_zUp;
              surface.planet = makePlanet(u_planet, u_planetTerrain, u_planetOcean, u_planetClouds, u_planetCity, u_planetCloudShape, u_planetPaletteA, u_planetPaletteB, u_planetLook, u_planetStyle);
              sunColor = u_atmosSun.rgb * atmosphereSunTransmittance(atm, r, dot(p, L) / r,
                                                                     u_atmosTransmittance_texture, u_atmosTransmittance_texture_smp)
                       * atmosphereCloudShadow(atm, surface, p, L, u_planetCloudMap_texture, u_planetCloudMap_texture_smp);
            }

            // the shadow already holds what glass between here and the sun takes away, and the caustics bring some back.
            float3 lit = float3(shadow) + sunCaustic;
            color += (Fd + Fr) * sunColor * lit;
            sunLight = sunColor;
            sunShadow = lit;
          }

          float3 pointLit = pointLightRadiance(worldPos, N, V, NoV, roughness, f0, diffuseColor,
                                               pointShadowUpsample(gbufferPixel, posEye, normalEye, u_pointShadow0_texture,
                                                                   u_pointShadow1_texture, u_pointShadow2_texture,
                                                                   u_pointShadow3_texture, u_pointShadowGuide_texture, _u),
                                               u_pointLightData, u_ltcMatrix, u_ltcMatrix_smp,
                                               u_ltcAmplitude, u_ltcAmplitude_smp, _u);
          color += pointLit;

          // every local light's caustics arrive added up as irradiance, its glass shadow already in its point shadow.
          color += diffuseColor / PI * localCaustic;

          float2 dfgTexel = 0.5 / float2(u_dfg_texture.get_width(), u_dfg_texture.get_height());
          float3 dfg = texture(u_dfg_texture, clamp(float2(NoV, perceptualRoughness), dfgTexel, 1.0 - dfgTexel)).rgb;
          float3 E = f0 * dfg.x + dfg.y;
          float3 energyCompensation = 1.0 + f0 * (1.0 / max(dfg.x + dfg.y, 1e-4) - 1.0);

          float3 r = reflect(-V, N);
          r = mix(r, N, roughness * roughness);

          float lod = 5.0 * perceptualRoughness;
          lod = clamp(lod, 0.0, 5.0);

          float3 prefilteredRadiance = textureLod(u_prefiltered_texture, toSkySpace(r, u_zUp), lod).rgb * u_iblTint.rgb * u_iblEnabled;
          prefilteredRadiance = probeSphereRadiance(worldPos, r, perceptualRoughness, prefilteredRadiance,
                                                    u_probe_sphere, u_probe_sphere_smp, u_probe_info, _u);

          float4 gi = ssgiUpsample(gbufferPixel, posEye, normalEye, u_ssgiAccum_texture,
                                   u_ssgiDepth_texture, u_ssgiNormal_texture, _u);
          float specularOcclusion = clamp(pow(NoV + gi.a, exp2(-16.0 * roughness - 1.0)) - 1.0 + gi.a, 0.0, 1.0);

          // sample ambient light along the bent normal, the most open direction around the surface.
          float3 bentEye = ssgiUpsample(gbufferPixel, posEye, normalEye, u_ssgiBentAccum_texture,
                                        u_ssgiDepth_texture, u_ssgiNormal_texture, _u).xyz;
          float3 bentN = dot(bentEye, bentEye) > 0.25 ? normalize(invView * bentEye) : N;
          float3 irradiance = texture(u_irradiance_texture, toSkySpace(bentN, u_zUp)).rgb * u_iblTint.rgb * u_iblEnabled;
          irradiance = probeVolumeIrradiance(worldPos, bentN, irradiance, u_probe_volume, _u);
          float3 Fd = diffuseColor * irradiance * multiBounce(gi.a, diffuseColor) * (1.0 - E);

          float4 reflection = ssrUpsample(gbufferPixel, posEye, normalEye, perceptualRoughness,
                                          u_ssrAccum_texture, u_ssrGuide_texture, _u);
          float3 traced = mix(prefilteredRadiance * specularOcclusion, reflection.rgb, reflection.a);
          float4 horizon = ssgiUpsample(gbufferPixel, posEye, normalEye, u_ssgiSpecAccum_texture,
                                        u_ssgiDepth_texture, u_ssgiNormal_texture, _u);
          float horizonMix = u_horizonScan.y * saturate((perceptualRoughness - u_horizonScan.x) / 0.2);
          float3 Fr = E * energyCompensation
                    * mix(traced, horizon.rgb + prefilteredRadiance * horizon.a, horizonMix);

          color += Fd + Fr + diffuseColor * gi.rgb * (1.0 - E);

          float primId = u_position_texture.read(gbufferPixel).w;
          float4 style0 = styleTexel(u_primStyle, primId, 0);
          float4 style1 = styleTexel(u_primStyle, primId, 1);
          float inside = styleInside(style1, style0.w, worldPos);
          float shadingModel = mix(max(style0.x - 1.0, 0.0), style0.x, inside);
          if (shadingModel < 4.999) {
            float NoLs = saturate(dot(N, L));
            float shininess = clamp(2.0 / max(roughness * roughness, 1e-3) - 2.0, 4.0, 1024.0);
            float3 Hs = normalize(V + L);
            float3 highlight = sunLight * NoLs * pow(saturate(dot(N, Hs)), shininess) * (shininess + 8.0) / (8.0 * PI)
                             * mix(float3(0.3), baseColor, metallic);
            float3 lambert = baseColor / PI * sunLight * NoLs + baseColor * irradiance * 0.6 + pointLit;
            float3 radiosity = baseColor / PI * sunLight * NoLs * sunShadow + Fd + diffuseColor * gi.rgb * (1.0 - E)
                             + highlight * sunShadow + pointLit;
            float3 models[6] = { float3(0.0), lambert, lambert, lambert + highlight, radiosity, color };
            int lo = int(floor(shadingModel));
            color = mix(models[lo], models[min(lo + 1, 5)], shadingModel - float(lo));
          }
          if (style0.z > 0.5) color *= style1.w < 0.0 ? 0.0 : inside;

          color += float3(u_material_texture.read(gbufferPixel).ba, u_diffuse_texture.read(gbufferPixel).w);
          if (style1.w > 1e-3) {
            float4 style3 = styleTexel(u_primStyle, primId, 3);
            float ring = (distance(worldPos, style1.xyz) - style1.w) / max(style0.w, 1e-3);
            color += style3.rgb * style3.w * exp(-ring * ring) * step(shadingModel, 4.999);
          }

          if (u_atmosphere.x > 0.5) {
            float2 screenUv = gl_FragCoord.xy / float2(u_normal_texture.get_width(), u_normal_texture.get_height());
            float4 aerial = atmosphereAerial(u_atmosAerial_texture, u_atmosAerial_texture_smp, screenUv,
                                             length(posEye) * u_atmosFrame.x, u_atmosphere.w);
            color = color * aerial.a + aerial.rgb * u_atmosSun.rgb * u_atmosSun.w;
          }

          float4 fog = volumeFog(gl_FragCoord.xy, -posEye.z,
                                 u_volumeIntegrated_texture, u_volumeIntegrated_texture_smp, _u);
          color = color * fog.a + fog.rgb;

          o_final_texture = float4(finiteColor(color), 1.0);
        }
        if (u_viewShading.x > 1.5) {
          float3 n = normalize(normalEye);
          float studio = 0.25 + 0.6 * saturate(dot(n, normalize(float3(-0.35, 0.55, 0.75))))
                       + 0.25 * saturate(dot(n, normalize(float3(0.6, -0.15, 0.5))));
          float3 shade = u_viewShading.x > 2.5 ? float3(u_viewShading.z) : float3(0.8 * studio);
          o_final_texture = float4(normalSample.a < 0.5 ? float3(u_viewShading.y) : shade, 1.0);
        }
      }
      """#
  }
}
