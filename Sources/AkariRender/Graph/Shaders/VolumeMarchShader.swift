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
  /// drawn by the `volume march` pass.
  struct VolumeMarchShader: FullscreenShader
  {
    let name = "volume-march"

    var uniforms: [Declaration]
    {
      Uniforms.iblTint
      Sampler(GBuffer.position)
      Sampler(GBuffer.normal)
      Sampler(VolumeShadowBuffer.volumeShadow)
      Sampler(IrradianceBuffer.irradiance, .samplerCube)
      Sampler(AtmosAerialBuffer.atmosAerial)
      Samplers.volumeDensity
      Uniforms.view
      Uniforms.invProj
      Uniforms.volumeTextureFromWorld
      Uniforms.volumeParams
      Uniforms.volumeAlbedo
      Uniforms.volumeSun
      Uniforms.sunOverride
      Uniforms.iblEnabled
      Uniforms.zUp
      Uniforms.atmosphere
      Uniforms.atmosSun
      Uniforms.atmosFrame
      Samplers.pointLightData
      Uniforms.pointLightCount
      Uniforms.frameIndex
    }

    let fragmentGLSL = #"""
      void main()
      {
        vec4 e = u_invProj * vec4(var.texCoord * 2.0 - 1.0, -1.0, 1.0);
        mat3 invView = transpose(mat3(u_view));
        vec3 eye = invView * -u_view[3].xyz;
        vec3 dir = normalize(invView * (e.xyz / e.w));
        ivec2 px = ivec2(gl_FragCoord.xy);
        float tMax = texelFetch(u_normal_texture, px, 0).a >= 0.5 ? length(texelFetch(u_position_texture, px, 0).xyz) : 1e30;
        float noise = fract(52.9829189 * fract(dot(gl_FragCoord.xy + 5.588238 * float(frameIndex % 64), vec2(0.06711056, 0.00583715))));
        vec3 sun = mix(vec3(3.0), u_sunOverride.rgb, u_sunOverride.w);
        vec3 up = mix(vec3(0.0, 1.0, 0.0), vec3(0.0, 0.0, 1.0), u_zUp);
        vec3 sky = texture(u_irradiance_texture, mix(up, vec3(up.x, up.z, -up.y), u_zUp)).rgb * u_iblTint.rgb * u_iblEnabled;
        vec4 r = volumeMarch(u_volumeDensity, u_volumeShadow_texture, u_volumeTextureFromWorld, eye, dir, tMax, noise,
                             u_volumeParams, u_volumeAlbedo.rgb, normalize(u_volumeSun.xyz), sun, sky);
        if (r.w >= 0.9999) discard;
        o_final_texture = vec4(r.rgb / max(1.0 - r.w, 1e-4), 1.0 - r.w);
      }
      """#

    let fragmentMSL = #"""
      \#(ShaderLibrary.volumeMSL)
      \#(ShaderLibrary.atmosphereMSL)

      //@main
      {
        float4 e = u_invProj * float4(var.texCoord * 2.0 - 1.0, -1.0, 1.0);
        float3x3 invView = float3x3(
          float3(u_view[0][0], u_view[1][0], u_view[2][0]),
          float3(u_view[0][1], u_view[1][1], u_view[2][1]),
          float3(u_view[0][2], u_view[1][2], u_view[2][2])
        );
        float3 eye = invView * -float3(u_view[3][0], u_view[3][1], u_view[3][2]);
        float3 dir = normalize(invView * (e.xyz / e.w));
        uint2 px = uint2(gl_FragCoord.xy);
        float tMax = u_normal_texture.read(px).a >= 0.5 ? length(u_position_texture.read(px).xyz) : 1e30;
        float noise = fract(volumeHash(int3(int2(gl_FragCoord.xy), 0)) + 0.6180339887 * float(frameIndex % 1024));
        float3 sun = mix(float3(3.0), u_sunOverride.rgb, u_sunOverride.w);
        float3 up = mix(float3(0.0, 1.0, 0.0), float3(0.0, 0.0, 1.0), u_zUp);
        float3 sky = texture(u_irradiance_texture, mix(up, float3(up.x, up.z, -up.y), u_zUp)).rgb * u_iblTint.rgb * u_iblEnabled;
        float tFirst;
        float4 r = volumeMarch(u_volumeDensity, u_volumeDensity_smp, u_volumeShadow_texture, u_volumeShadow_texture_smp,
                               u_volumeTextureFromWorld, eye, dir, tMax, noise, u_volumeParams, u_volumeAlbedo.rgb,
                               normalize(u_volumeSun.xyz), sun, sky, u_pointLightData, int(u_pointLightCount), tFirst);
        if (r.w >= 0.9999) discard_fragment();
        float3 L = r.rgb;
        if (u_atmosphere.x > 0.5) {
          float2 screenUv = gl_FragCoord.xy / float2(u_normal_texture.get_width(), u_normal_texture.get_height());
          float4 aerial = atmosphereAerial(u_atmosAerial_texture, u_atmosAerial_texture_smp, screenUv,
                                           tFirst * u_atmosFrame.x, u_atmosphere.w);
          L = L * aerial.a + (1.0 - r.w) * aerial.rgb * u_atmosSun.rgb * u_atmosSun.w;
        }
        o_final_texture = float4(min(L / max(1.0 - r.w, 1e-4), float3(60000.0)), 1.0 - r.w);
      }
      """#
  }
}
