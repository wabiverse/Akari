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
  /// drawn by the `atmosphere multiscatter` pass.
  struct AtmosphereMultiscatterShader: FullscreenShader
  {
    let name = "atmosphere-multiscatter"

    var uniforms: [Declaration]
    {
      Sampler(AtmosTransmittanceBuffer.atmosTransmittance)
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
        vec2 uv = gl_FragCoord.xy / 32.0;
        float mu = uv.x * 2.0 - 1.0;
        float r = mix(a.bottom, a.top, uv.y);
        vec3 sun = vec3(sqrt(max(1.0 - mu * mu, 0.0)), mu, 0.0);
        vec3 L = vec3(0.0), fms = vec3(0.0), E = vec3(0.0);
        for (int i = 0; i < 8; ++i) {
          for (int j = 0; j < 8; ++j) {
            float theta = 2.0 * ATMOS_PI * (float(i) + 0.5) / 8.0;
            float phi = acos(1.0 - 2.0 * (float(j) + 0.5) / 8.0);
            vec3 d = vec3(cos(theta) * sin(phi), cos(phi), sin(theta) * sin(phi));
            AtmosphereScatter sc = atmosphereIntegrate(a, vec3(0.0, r, 0.0), d, sun, 1e9, 20, true, true, false,
                                                       u_atmosTransmittance_texture, u_atmosTransmittance_texture);
            L += sc.L;
            fms += sc.multiScatterAs1;
            E += sc.L * max(d.y, 0.0);
          }
        }
        vec3 boost = 1.0 / max(1.0 - fms / 64.0, vec3(1e-3));
        o_atmosMultiScatter_texture = vec4(L / 64.0 * boost, 1.0);
        o_atmosIrradiance_texture = vec4(E * (4.0 * ATMOS_PI / 64.0) * boost, 1.0);
      }
      """#

    let fragmentMSL = #"""
      \#(ShaderLibrary.atmosphereMSL)

      //@main
      {
        Atmosphere a = makeAtmosphere(u_atmosphere, u_atmosRayleigh, u_atmosMie, u_atmosMieExtra, u_atmosOzone, u_atmosGround);
        float2 uv = gl_FragCoord.xy / 32.0;
        float mu = uv.x * 2.0 - 1.0;
        float r = mix(a.bottom, a.top, uv.y);
        float3 sun = float3(sqrt(max(1.0 - mu * mu, 0.0)), mu, 0.0);
        float3 L = float3(0.0), fms = float3(0.0), E = float3(0.0);
        for (int i = 0; i < 8; ++i) {
          for (int j = 0; j < 8; ++j) {
            float theta = 2.0 * ATMOS_PI * (float(i) + 0.5) / 8.0;
            float phi = acos(1.0 - 2.0 * (float(j) + 0.5) / 8.0);
            float3 d = float3(cos(theta) * sin(phi), cos(phi), sin(theta) * sin(phi));
            AtmosphereScatter sc = atmosphereIntegrate(a, float3(0.0, r, 0.0), d, sun, 1e9, 20, true, true, false,
                                                       u_atmosTransmittance_texture, u_atmosTransmittance_texture_smp,
                                                       u_atmosTransmittance_texture, u_atmosTransmittance_texture_smp);
            L += sc.L;
            fms += sc.multiScatterAs1;
            E += sc.L * max(d.y, 0.0);
          }
        }
        float3 boost = 1.0 / max(1.0 - fms / 64.0, float3(1e-3));
        o_atmosMultiScatter_texture = float4(L / 64.0 * boost, 1.0);
        o_atmosIrradiance_texture = float4(E * (4.0 * ATMOS_PI / 64.0) * boost, 1.0);
      }
      """#
  }
}
