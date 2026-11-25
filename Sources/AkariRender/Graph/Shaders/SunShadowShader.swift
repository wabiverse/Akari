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
  /// drawn by the `sun shadow` pass.
  struct SunShadowShader: FullscreenShader
  {
    let name = "sun-shadow"

    var uniforms: [Declaration]
    {
      Sampler(GBuffer.position)
      Sampler(GBuffer.normal)
      Samplers.shadowAtlas
      Samplers.shadowData
      Samplers.shadowPagetable
      Uniforms.view
      Uniforms.sunDirection
      Uniforms.shadowEnabled
      Uniforms.shadowLevelCount
      Uniforms.shadowBias
      Uniforms.eyeToLightRotation
      Uniforms.directionalRefOffset
      Uniforms.shadowLodRange
      Uniforms.proj
      Uniforms.viewGrid
      Uniforms.frameIndex
      Sampler(GlassNearBuffer.glassNear)
      Sampler(GlassNearBuffer.glassNearNormal)
      Samplers.glassLights
    }

    let fragmentGLSL = #"""
      \#(ShaderLibrary.sunShadowGLSL)

      // screen space contact shadow toward the sun, 0 when something on screen blocks it.
      float contactShadow(vec3 posEye, vec3 lightEye, float spread, float noise)
      {
        float metre = max(u_viewGrid.y, 1e-6);
        float rayLength = 0.25 * metre;
        ivec2 size = textureSize(u_position_texture, 0);
        float occlusion = 0.0;
        for (int i = 1; i <= 12; ++i) {
          vec3 p = posEye + lightEye * (rayLength * (float(i) - noise) / 12.0);
          vec4 clip = u_proj * vec4(p, 1.0);
          if (clip.w <= 0.0) break;
          vec2 uv = clip.xy / clip.w * 0.5 + 0.5;
          if (any(lessThan(uv, vec2(0.0))) || any(greaterThanEqual(uv, vec2(1.0)))) break;
          ivec2 pixel = ivec2(uv * vec2(size));
          if (texelFetch(u_normal_texture, pixel, 0).a < 0.5) continue;
          float depthGap = texelFetch(u_position_texture, pixel, 0).z - p.z;
          float bias = 0.002 * abs(p.z);
          float thickness = max(0.03 * metre, 0.02 * abs(p.z));

          // a blocker deeper inside the light's cone covers more of the light.
          float cone = max(spread * rayLength * (float(i) - noise) / 12.0, bias);
          if (depthGap > bias && depthGap < thickness) occlusion = max(occlusion, clamp((depthGap - bias) / cone, 0.0, 1.0));
        }
        return 1.0 - occlusion;
      }

      // sun visibility this frame with penumbra rays turned by per frame noise for the temporal pass, 0 facing away from the sun
      void main()
      {
        ivec2 pixel = ivec2(gl_FragCoord.xy);
        vec4 normalSample = texelFetch(u_normal_texture, pixel, 0);
        if (normalSample.a < 0.5) {
          o_sunShadowRaw_texture = vec4(1.0);
          return;
        }
        vec3 normalEye = normalSample.xyz;
        vec3 posEye = texelFetch(u_position_texture, pixel, 0).xyz;
        vec3 N = normalize(transpose(mat3(u_view)) * normalEye);
        float cosTheta = dot(N, normalize(u_sunDirection.xyz));
        if (cosTheta <= -sin(u_sunDirection.w)) {
          o_sunShadowRaw_texture = vec4(0.0);
          return;
        }
        vec2 noisePixel = gl_FragCoord.xy + 5.588238 * float(frameIndex % 64);
        float noise = fract(52.9829189 * fract(dot(noisePixel, vec2(0.06711056, 0.00583715))));
        float noiseB = fract(52.9829189 * fract(dot(noisePixel.yx, vec2(0.06711056, 0.00583715))));
        float blocker;
        float visibility = directionalShadow(posEye, normalEye, max(cosTheta, 0.0), vec2(noise, noiseB), blocker);
        if (visibility > 0.0) {
          vec3 lightEye = normalize(mat3(u_view) * normalize(u_sunDirection.xyz));
          visibility *= contactShadow(posEye + normalEye * (0.002 * abs(posEye.z)), lightEye, tan(u_sunDirection.w), noise);
        }

        // soft edge width on screen from the blocker distance and the sun's apparent size.
        float spread = blocker > 0.0 ? tan(u_sunDirection.w) * blocker * u_proj[1][1]
                                       * float(textureSize(u_position_texture, 0).y) / (2.0 * abs(posEye.z)) : 0.0;
        o_sunShadowRaw_texture = vec4(visibility, min(spread, 48.0), 0.0, 0.0);
      }
      """#

    let fragmentMSL = #"""
      \#(ShaderLibrary.sunShadowMSL)

      // screen space contact shadow toward the sun, 0 when something on screen blocks it.
      float contactShadow(float3 posEye, float3 lightEye, float spread, float noise,
                          texture2d<float> positionTex, texture2d<float> normalTex, constant Uniforms& u)
      {
        float metre = max(u.u_viewGrid.y, 1e-6);
        float rayLength = 0.25 * metre;
        float2 size = float2(positionTex.get_width(), positionTex.get_height());
        float occlusion = 0.0;
        for (int i = 1; i <= 12; ++i) {
          float3 p = posEye + lightEye * (rayLength * (float(i) - noise) / 12.0);
          float4 clip = u.u_proj * float4(p, 1.0);
          if (clip.w <= 0.0) break;
          float2 uv = clip.xy / clip.w * 0.5 + 0.5;
          if (any(uv < float2(0.0)) || any(uv >= float2(1.0))) break;
          uint2 pixel = uint2(uv * size);
          if (normalTex.read(pixel).a < 0.5) continue;
          float depthGap = positionTex.read(pixel).z - p.z;
          float bias = 0.002 * abs(p.z);
          float thickness = max(0.03 * metre, 0.02 * abs(p.z));

          // a blocker deeper inside the light's cone covers more of the light.
          float cone = max(spread * rayLength * (float(i) - noise) / 12.0, bias);
          if (depthGap > bias && depthGap < thickness) occlusion = max(occlusion, saturate((depthGap - bias) / cone));
        }
        return 1.0 - occlusion;
      }

      \#(ShaderLibrary.glassLightMSL)

      //@main
      {
        uint2 pixel = uint2(gl_FragCoord.xy);
        float4 normalSample = u_normal_texture.read(pixel);
        if (normalSample.a < 0.5) {
          o_sunShadowRaw_texture = float4(1.0);
        } else {
          float3 normalEye = normalSample.xyz;
          float3 posEye = u_position_texture.read(pixel).xyz;
          float3x3 invView = transpose(float3x3(u_view[0].xyz, u_view[1].xyz, u_view[2].xyz));
          float3 N = normalize(invView * normalEye);
          float cosTheta = dot(N, normalize(u_sunDirection.xyz));
          if (cosTheta <= -sin(u_sunDirection.w)) {
            o_sunShadowRaw_texture = float4(0.0);
          } else {
            float2 noisePixel = gl_FragCoord.xy + 5.588238 * float(frameIndex % 64);
            float noise = fract(52.9829189 * fract(dot(noisePixel, float2(0.06711056, 0.00583715))));
            float noiseB = fract(52.9829189 * fract(dot(noisePixel.yx, float2(0.06711056, 0.00583715))));
            float blocker;
            float visibility = directionalShadow(posEye, normalEye, max(cosTheta, 0.0), float2(noise, noiseB),
                                                 u_shadow_atlas, u_shadow_atlas_smp,
                                                 u_shadow_data, u_shadow_pagetable, _u, blocker);
            if (visibility > 0.0) {
              float3 lightEye = normalize((u_view * float4(normalize(u_sunDirection.xyz), 0.0)).xyz);
              visibility *= contactShadow(posEye + normalEye * (0.002 * abs(posEye.z)), lightEye, tan(u_sunDirection.w), noise,
                                          u_position_texture, u_normal_texture, _u);
            }

            // glass between here and the sun blocks it too, so its shadow filters and blends like the opaque ones.
            float3 worldPos = invView * (posEye - u_view[3].xyz);
            float behind;
            float glass = glassVisible(worldPos, \#(GlassAtlas.sunTile), u_glassLights, u_glassNear_texture,
                                       u_glassNearNormal_texture, noise, behind);
            visibility *= glass;
            if (glass < 1.0 && blocker <= 0.0) blocker = behind;

            // soft edge width on screen from the blocker distance and the sun's apparent size.
            float spread = blocker > 0.0 ? tan(u_sunDirection.w) * blocker * u_proj[1][1]
                                           * float(u_position_texture.get_height()) / (2.0 * abs(posEye.z)) : 0.0;
            o_sunShadowRaw_texture = float4(visibility, min(spread, 48.0), 0.0, 0.0);
          }
        }
      }
      """#
  }
}
