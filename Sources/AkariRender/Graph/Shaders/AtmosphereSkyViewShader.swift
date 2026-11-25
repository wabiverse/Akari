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
  /// drawn by the `atmosphere sky view` pass.
  struct AtmosphereSkyViewShader: FullscreenShader
  {
    let name = "atmosphere-sky-view"

    var uniforms: [Declaration]
    {
      Sampler(AtmosTransmittanceBuffer.atmosTransmittance)
      Sampler(AtmosMultiScatterBuffer.atmosMultiScatter)
      Uniforms.atmosCamera
      Uniforms.sunDirection
      Uniforms.atmosphere
      Uniforms.atmosRayleigh
      Uniforms.atmosMie
      Uniforms.atmosMieExtra
      Uniforms.atmosOzone
      Uniforms.atmosGround
    }

    let fragmentGLSL = #"""
      \#(ShaderLibrary.atmosphereGLSL)
      void main()
      {
        Atmosphere a = makeAtmosphere(u_atmosphere, u_atmosRayleigh, u_atmosMie, u_atmosMieExtra, u_atmosOzone, u_atmosGround);
        vec2 uv = gl_FragCoord.xy / vec2(192.0, 108.0);
        float h = max(u_atmosCamera.w, 1e-3);
        float viewZenith, sunAzimuth;
        atmosphereSkyViewDirection(a, h, uv, viewZenith, sunAzimuth);
        float muSun = dot(normalize(u_atmosCamera.xyz), normalize(u_sunDirection.xyz));
        vec3 sun = vec3(sqrt(max(1.0 - muSun * muSun, 0.0)), muSun, 0.0);
        float sinZenith = sqrt(max(1.0 - viewZenith * viewZenith, 0.0));
        vec3 d = vec3(sinZenith * sunAzimuth, viewZenith, sinZenith * sqrt(max(1.0 - sunAzimuth * sunAzimuth, 0.0)));
        AtmosphereScatter sc = atmosphereIntegrate(a, vec3(0.0, a.bottom + h, 0.0), d, sun, 1e9, 30, false, false, true,
                                                   u_atmosTransmittance_texture, u_atmosMultiScatter_texture);
        o_atmosSkyView_texture = vec4(sc.L, 1.0);
      }
      """#

    let fragmentMSL = #"""
      \#(ShaderLibrary.atmosphereMSL)

      //@main
      {
        Atmosphere a = makeAtmosphere(u_atmosphere, u_atmosRayleigh, u_atmosMie, u_atmosMieExtra, u_atmosOzone, u_atmosGround);
        float2 uv = gl_FragCoord.xy / float2(192.0, 108.0);
        float h = max(u_atmosCamera.w, 1e-3);
        float viewZenith, sunAzimuth;
        atmosphereSkyViewDirection(a, h, uv, viewZenith, sunAzimuth);
        float muSun = dot(normalize(u_atmosCamera.xyz), normalize(u_sunDirection.xyz));
        float3 sun = float3(sqrt(max(1.0 - muSun * muSun, 0.0)), muSun, 0.0);
        float sinZenith = sqrt(max(1.0 - viewZenith * viewZenith, 0.0));
        float3 d = float3(sinZenith * sunAzimuth, viewZenith, sinZenith * sqrt(max(1.0 - sunAzimuth * sunAzimuth, 0.0)));
        AtmosphereScatter sc = atmosphereIntegrate(a, float3(0.0, a.bottom + h, 0.0), d, sun, 1e9, 30, false, false, true,
                                                   u_atmosTransmittance_texture, u_atmosTransmittance_texture_smp,
                                                   u_atmosMultiScatter_texture, u_atmosMultiScatter_texture_smp);
        o_atmosSkyView_texture = float4(sc.L, 1.0);
      }
      """#
  }
}
