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
  /// drawn by the `atmosphere env` pass.
  struct AtmosphereEnvShader: ShaderProgram
  {
    let name = "atmosphere-env"

    var uniforms: [Declaration]
    {
      Sampler(PlanetCloudMapBuffer.planetCloudMap)
      Sampler(DomeBuffer.dome)
      Sampler(AtmosTransmittanceBuffer.atmosTransmittance)
      Sampler(AtmosMultiScatterBuffer.atmosMultiScatter)
      Sampler(AtmosMultiScatterBuffer.atmosIrradiance)
      Sampler(AtmosSkyViewBuffer.atmosSkyView)
      Uniforms.domeFromSky
      Uniforms.domeColor
      Uniforms.domeEnabled
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
      Uniforms.atmosCamera
      Uniforms.atmosSun
      Uniforms.atmosFrame
      Uniforms.sunDirection
      Uniforms.zUp
      Uniforms.planetCloudMarchSteps
      Uniforms.atmosphere
      Uniforms.atmosRayleigh
      Uniforms.atmosMie
      Uniforms.atmosMieExtra
      Uniforms.atmosOzone
      Uniforms.atmosGround
    }

    var stages: [Stage]
    {
      Stage(.compute, glsl: computeGLSL, msl: computeMSL)
    }

    let computeGLSL = #"""
      \#(ShaderLibrary.atmosphereGLSL)
      vec3 cubeFaceDir(vec2 uv, int face)
      {
        float u = uv.x * 2.0 - 1.0;
        float v = uv.y * 2.0 - 1.0;
        if (face == 0) return normalize(vec3( 1.0, -v, -u));
        if (face == 1) return normalize(vec3(-1.0, -v,  u));
        if (face == 2) return normalize(vec3( u,  1.0, -v));
        if (face == 3) return normalize(vec3( u, -1.0,  v));
        if (face == 4) return normalize(vec3( u, -v,  1.0));
        return normalize(vec3(-u, -v, -1.0));
      }

      void main()
      {
        ivec3 gid = ivec3(gl_GlobalInvocationID);
        ivec2 size = imageSize(o_envCube_texture);
        if (gid.x >= size.x || gid.y >= size.y || gid.z >= 6) return;
        Atmosphere a = makeAtmosphere(u_atmosphere, u_atmosRayleigh, u_atmosMie, u_atmosMieExtra, u_atmosOzone, u_atmosGround);
        vec3 dir = cubeFaceDir((vec2(gid.xy) + 0.5) / vec2(size), gid.z);
        vec3 world = mix(dir, vec3(dir.x, -dir.z, dir.y), u_zUp);
        AtmosphereSurface surface = AtmosphereSurface(mat3(u_atmosPlanetFromWorld), u_zUp, 0.0, 0.0, 0.0, 1.5707963 / float(size.x),
                                                      makePlanet(u_planet, u_planetTerrain, u_planetOcean, u_planetClouds, u_planetCity, u_planetCloudShape, u_planetPaletteA, u_planetPaletteB));
        vec3 T;
        vec3 c = atmosphereRadiance(a, normalize(u_atmosCamera.xyz), u_atmosCamera.w, world, normalize(u_sunDirection.xyz),
                                    u_atmosSun.rgb, u_atmosSun.w, true, surface, T,
                                    u_atmosTransmittance_texture, u_atmosMultiScatter_texture, u_atmosIrradiance_texture,
                                    u_atmosSkyView_texture, u_atmosTransmittance_texture, u_atmosTransmittance_texture);
        if (u_domeEnabled > 0.5) {
          vec3 d = normalize(mat3(u_domeFromSky) * dir);
          c += textureLod(u_dome_texture, atmosphereLatLong(d), 0.0).rgb * u_domeColor.rgb * T;
        }
        imageStore(o_envCube_texture, ivec3(gid.xy, gid.z), vec4(c, 1.0));
      }
      """#

    let computeMSL = #"""
      \#(ShaderLibrary.atmosphereMSL)
      float3 cubeFaceDir(float2 uv, int face)
      {
        float u = uv.x * 2.0 - 1.0;
        float v = uv.y * 2.0 - 1.0;
        if (face == 0) return normalize(float3( 1.0, -v, -u));
        if (face == 1) return normalize(float3(-1.0, -v,  u));
        if (face == 2) return normalize(float3( u,  1.0,  v));
        if (face == 3) return normalize(float3( u, -1.0, -v));
        if (face == 4) return normalize(float3( u, -v,  1.0));
        return normalize(float3(-u, -v, -1.0));
      }

      //@main
      {
        uint2 size = uint2(o_envCube_texture.get_width(), o_envCube_texture.get_height());
        if (gid.x >= size.x || gid.y >= size.y || gid.z >= 6) return;
        Atmosphere a = makeAtmosphere(u_atmosphere, u_atmosRayleigh, u_atmosMie, u_atmosMieExtra, u_atmosOzone, u_atmosGround);
        float3 dir = cubeFaceDir((float2(gid.xy) + 0.5) / float2(size), int(gid.z));
        float3 world = mix(dir, float3(dir.x, -dir.z, dir.y), u_zUp);
        AtmosphereSurface surface;
        surface.planetFromWorld = float3x3(u_atmosPlanetFromWorld[0].xyz, u_atmosPlanetFromWorld[1].xyz, u_atmosPlanetFromWorld[2].xyz);
        surface.zUp = u_zUp;
        surface.hasGround = 0.0;
        surface.hasNight = 0.0;
        surface.nightIntensity = 0.0;
        surface.pixelAngle = 1.5707963 / float(size.x);
        surface.planet = makePlanet(u_planet, u_planetTerrain, u_planetOcean, u_planetClouds, u_planetCity, u_planetCloudShape, u_planetPaletteA, u_planetPaletteB, u_planetLook, u_planetStyle);
        float3 T;
        float3 c = atmosphereRadiance(a, normalize(u_atmosCamera.xyz), u_atmosCamera.w, world, normalize(u_sunDirection.xyz),
                                      u_atmosSun.rgb, u_atmosSun.w, true, surface, T,
                                      u_atmosTransmittance_texture, u_atmosTransmittance_texture_smp,
                                      u_atmosMultiScatter_texture, u_atmosMultiScatter_texture_smp,
                                      u_atmosIrradiance_texture, u_atmosIrradiance_texture_smp,
                                      u_atmosSkyView_texture, u_atmosSkyView_texture_smp,
                                      u_atmosTransmittance_texture, u_atmosTransmittance_texture_smp,
                                      u_atmosTransmittance_texture, u_atmosTransmittance_texture_smp,
                                     u_planetCloudMap_texture, u_planetCloudMap_texture_smp, int(u_planetCloudMarchSteps));
        if (u_domeEnabled > 0.5) {
          float3x3 rot = float3x3(u_domeFromSky[0].xyz, u_domeFromSky[1].xyz, u_domeFromSky[2].xyz);
          c += textureLod(u_dome_texture, atmosphereLatLong(normalize(rot * dir)), 0.0).rgb * u_domeColor.rgb * T;
        }
        o_envCube_texture.write(half4(half3(min(c, float3(60000.0))), 1.0h), ushort2(gid.xy), ushort(gid.z));
      }
      """#
  }
}
