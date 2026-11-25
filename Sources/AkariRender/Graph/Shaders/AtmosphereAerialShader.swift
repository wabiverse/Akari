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
  /// drawn by the `atmosphere aerial` pass.
  struct AtmosphereAerialShader: FullscreenShader
  {
    let name = "atmosphere-aerial"

    var uniforms: [Declaration]
    {
      Sampler(AtmosTransmittanceBuffer.atmosTransmittance)
      Sampler(AtmosMultiScatterBuffer.atmosMultiScatter)
      Uniforms.view
      Uniforms.invProj
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
        ivec2 px = ivec2(gl_FragCoord.xy);
        int slice = (px.y / 32) * 8 + px.x / 32;
        vec2 local = (vec2(px % 32) + 0.5) / 32.0;
        vec4 e = u_invProj * vec4(local * 2.0 - 1.0, -1.0, 1.0);
        vec3 d = normalize(transpose(mat3(u_view)) * (e.xyz / e.w));
        float f = (float(slice) + 0.5) / 32.0;
        float h = max(u_atmosCamera.w, 1e-3);
        AtmosphereScatter sc = atmosphereIntegrate(a, normalize(u_atmosCamera.xyz) * (a.bottom + h), d, normalize(u_sunDirection.xyz),
                                                   u_atmosphere.w * f * f, clamp(slice + 1, 4, 24), false, false, true,
                                                   u_atmosTransmittance_texture, u_atmosMultiScatter_texture);
        o_atmosAerial_texture = vec4(sc.L, dot(sc.T, vec3(1.0 / 3.0)));
      }
      """#

    let fragmentMSL = #"""
      \#(ShaderLibrary.atmosphereMSL)

      //@main
      {
        Atmosphere a = makeAtmosphere(u_atmosphere, u_atmosRayleigh, u_atmosMie, u_atmosMieExtra, u_atmosOzone, u_atmosGround);
        int2 px = int2(gl_FragCoord.xy);
        int slice = (px.y / 32) * 8 + px.x / 32;
        float2 local = (float2(px % 32) + 0.5) / 32.0;
        float4 e = u_invProj * float4(local * 2.0 - 1.0, -1.0, 1.0);
        float3x3 invView = float3x3(
          float3(u_view[0][0], u_view[1][0], u_view[2][0]),
          float3(u_view[0][1], u_view[1][1], u_view[2][1]),
          float3(u_view[0][2], u_view[1][2], u_view[2][2])
        );
        float3 d = normalize(invView * (e.xyz / e.w));
        float f = (float(slice) + 0.5) / 32.0;
        float h = max(u_atmosCamera.w, 1e-3);
        AtmosphereScatter sc = atmosphereIntegrate(a, normalize(u_atmosCamera.xyz) * (a.bottom + h), d, normalize(u_sunDirection.xyz),
                                                   u_atmosphere.w * f * f, clamp(slice + 1, 4, 24), false, false, true,
                                                   u_atmosTransmittance_texture, u_atmosTransmittance_texture_smp,
                                                   u_atmosMultiScatter_texture, u_atmosMultiScatter_texture_smp);
        o_atmosAerial_texture = float4(sc.L, dot(sc.T, float3(1.0 / 3.0)));
      }
      """#
  }
}
