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
  /// drawn by the `atmosphere background` pass.
  struct AtmosphereBackgroundShader: FullscreenShader
  {
    let name = "atmosphere-background"

    var uniforms: [Declaration]
    {
      Sampler(PlanetCloudMapBuffer.planetCloudMap)
      Sampler(GBuffer.normal)
      Sampler(AtmosTransmittanceBuffer.atmosTransmittance)
      Sampler(AtmosMultiScatterBuffer.atmosMultiScatter)
      Sampler(AtmosMultiScatterBuffer.atmosIrradiance)
      Sampler(AtmosSkyViewBuffer.atmosSkyView)
      Sampler(VolumeIntegratedBuffer.volumeIntegrated)
      Samplers.domeMap
      Samplers.atmosGroundMap
      Samplers.atmosNightMap
      Uniforms.view
      Uniforms.invProj
      Uniforms.iblEnabled
      Uniforms.domeEnabled
      Uniforms.domeFromWorld
      Uniforms.domeColor
      Uniforms.zUp
      Uniforms.sunDirection
      Uniforms.volume
      Uniforms.volumeRange
      Uniforms.halfScale
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
      Uniforms.planetCloudMarchSteps
    }

    let fragmentGLSL = #"""
      \#(ShaderLibrary.atmosphereGLSL)
      vec4 volumeBoundary(int b, vec2 f, vec2 grid, vec2 atlasSize)
      {
        if (b == 0) return vec4(0.0, 0.0, 0.0, 1.0);
        vec2 origin = vec2(float((b - 1) % 8), float((b - 1) / 8)) * grid;
        return texture(u_volumeIntegrated_texture, (origin + f) / atlasSize);
      }

      void main()
      {
        if (texelFetch(u_normal_texture, ivec2(gl_FragCoord.xy), 0).a >= 0.5 || u_iblEnabled < 0.5) discard;
        vec4 e = u_invProj * vec4(var.texCoord * 2.0 - 1.0, -1.0, 1.0);
        vec3 worldDir = normalize(transpose(mat3(u_view)) * (e.xyz / e.w));
        vec3 stars = vec3(0.0);
        if (u_domeEnabled > 0.5) {
          vec3 d = normalize(mat3(u_domeFromWorld) * worldDir);
          stars = textureLod(u_domeMap, atmosphereLatLong(d), 0.0).rgb * u_domeColor.rgb;
        }
        Atmosphere a = makeAtmosphere(u_atmosphere, u_atmosRayleigh, u_atmosMie, u_atmosMieExtra, u_atmosOzone, u_atmosGround);
        AtmosphereSurface surface = AtmosphereSurface(mat3(u_atmosPlanetFromWorld), u_zUp, u_atmosFrame.y, u_atmosFrame.z, u_atmosFrame.w,
                                                      2.0 * abs(u_invProj[1][1]) / float(textureSize(u_normal_texture, 0).y),
                                                      makePlanet(u_planet, u_planetTerrain, u_planetOcean, u_planetClouds, u_planetCity, u_planetCloudShape, u_planetPaletteA, u_planetPaletteB));
        vec3 L = normalize(u_sunDirection.xyz);
        vec3 T;
        vec3 sky = atmosphereRadiance(a, normalize(u_atmosCamera.xyz), u_atmosCamera.w, worldDir, L, u_atmosSun.rgb, u_atmosSun.w,
                                      true, surface, T, u_atmosTransmittance_texture, u_atmosMultiScatter_texture,
                                      u_atmosIrradiance_texture, u_atmosSkyView_texture, u_atmosGroundMap, u_atmosNightMap);
        sky += (stars + atmosphereSunDisk(worldDir, L, u_atmosSun.rgb, u_sunDirection.w)) * T;
        vec4 fog = vec4(0.0, 0.0, 0.0, 1.0);
        if (u_volume.z > 0.5) {
          vec2 atlasSize = vec2(textureSize(u_volumeIntegrated_texture, 0));
          vec2 f = clamp(gl_FragCoord.xy / (8.0 * u_halfScale.xy), vec2(0.5), u_volumeRange.zw - 0.5);
          fog = volumeBoundary(64, f, u_volumeRange.zw, atlasSize);
        }
        o_final_texture = vec4(min(sky * fog.a + fog.rgb, vec3(60000.0)), 1.0);
      }
      """#

    let fragmentMSL = #"""
      \#(ShaderLibrary.atmosphereMSL)
      float4 volumeBoundary(int b, float2 f, float2 grid, float2 atlasSize, texture2d<float> integrated, sampler smp)
      {
        if (b == 0) return float4(0.0, 0.0, 0.0, 1.0);
        float2 origin = float2(float((b - 1) % 8), float((b - 1) / 8)) * grid;
        return integrated.sample(smp, (origin + f) / atlasSize);
      }

      //@main
      {
        if (u_normal_texture.read(uint2(gl_FragCoord.xy)).a >= 0.5 || u_iblEnabled < 0.5) discard_fragment();
        float4 e = u_invProj * float4(var.texCoord * 2.0 - 1.0, -1.0, 1.0);
        float3x3 invView = float3x3(
          float3(u_view[0][0], u_view[1][0], u_view[2][0]),
          float3(u_view[0][1], u_view[1][1], u_view[2][1]),
          float3(u_view[0][2], u_view[1][2], u_view[2][2])
        );
        float3 worldDir = normalize(invView * (e.xyz / e.w));
        float3 stars = float3(0.0);
        if (u_domeEnabled > 0.5) {
          float3x3 rot = float3x3(u_domeFromWorld[0].xyz, u_domeFromWorld[1].xyz, u_domeFromWorld[2].xyz);
          stars = textureLod(u_domeMap, atmosphereLatLong(normalize(rot * worldDir)), 0.0).rgb * u_domeColor.rgb;
        }
        Atmosphere a = makeAtmosphere(u_atmosphere, u_atmosRayleigh, u_atmosMie, u_atmosMieExtra, u_atmosOzone, u_atmosGround);
        AtmosphereSurface surface;
        surface.planetFromWorld = float3x3(u_atmosPlanetFromWorld[0].xyz, u_atmosPlanetFromWorld[1].xyz, u_atmosPlanetFromWorld[2].xyz);
        surface.zUp = u_zUp;
        surface.hasGround = u_atmosFrame.y;
        surface.hasNight = u_atmosFrame.z;
        surface.nightIntensity = u_atmosFrame.w;
        surface.pixelAngle = 2.0 * abs(u_invProj[1][1]) / float(u_normal_texture.get_height());
        surface.planet = makePlanet(u_planet, u_planetTerrain, u_planetOcean, u_planetClouds, u_planetCity, u_planetCloudShape, u_planetPaletteA, u_planetPaletteB, u_planetLook, u_planetStyle);
        float3 L = normalize(u_sunDirection.xyz);
        float3 T;
        float3 sky = atmosphereRadiance(a, normalize(u_atmosCamera.xyz), u_atmosCamera.w, worldDir, L, u_atmosSun.rgb, u_atmosSun.w,
                                        true, surface, T,
                                        u_atmosTransmittance_texture, u_atmosTransmittance_texture_smp,
                                        u_atmosMultiScatter_texture, u_atmosMultiScatter_texture_smp,
                                        u_atmosIrradiance_texture, u_atmosIrradiance_texture_smp,
                                        u_atmosSkyView_texture, u_atmosSkyView_texture_smp,
                                        u_atmosGroundMap, u_atmosGroundMap_smp,
                                        u_atmosNightMap, u_atmosNightMap_smp,
                                     u_planetCloudMap_texture, u_planetCloudMap_texture_smp, int(u_planetCloudMarchSteps));
        sky += (stars + atmosphereSunDisk(worldDir, L, u_atmosSun.rgb, u_sunDirection.w)) * T;
        float4 fog = float4(0.0, 0.0, 0.0, 1.0);
        if (u_volume.z > 0.5) {
          float2 atlasSize = float2(u_volumeIntegrated_texture.get_width(), u_volumeIntegrated_texture.get_height());
          float2 f = clamp(gl_FragCoord.xy / (8.0 * u_halfScale.xy), float2(0.5), u_volumeRange.zw - 0.5);
          fog = volumeBoundary(64, f, u_volumeRange.zw, atlasSize, u_volumeIntegrated_texture, u_volumeIntegrated_texture_smp);
        }
        o_final_texture = float4(min(sky * fog.a + fog.rgb, float3(60000.0)), 1.0);
      }
      """#
  }
}
