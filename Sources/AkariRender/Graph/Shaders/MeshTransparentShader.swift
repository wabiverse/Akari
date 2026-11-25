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
  /// drawn by the `transparent` pass
  struct MeshTransparentShader: ShaderProgram
  {
    /// every transparent surface, or only those behind the nearest glass
    enum Layer: Sendable
    {
      case all, behind
    }

    var layer: Layer = .all

    var name: String { layer == .all ? "mesh-transparent" : "mesh-transparent-behind" }

    var uniforms: [Declaration]
    {
      Uniforms.iblTint
      Samplers.materialAtlas
      Samplers.colorAtlas
      Samplers.normalAtlas
      Samplers.emissiveAtlas
      Samplers.materialConstants
      Samplers.primStyle
      Sampler(GBuffer.position)
      Sampler(GBuffer.normal)
      Sampler(PrefilteredBuffer.prefiltered, .samplerCube)
      Sampler(IrradianceBuffer.irradiance, .samplerCube)
      Uniforms.prevViewProj
      Uniforms.currViewProj
      Uniforms.view
      Uniforms.sunDirection
      Uniforms.sunOverride
      Uniforms.iblEnabled
      Uniforms.zUp
      Uniforms.transparency
      Uniforms.frameIndex
      Uniforms.pointLightCount
      Samplers.pointLightData
      Sampler(EnvCubeBuffer.envCube, .samplerCube)
      Uniforms.domeEnabled
      Uniforms.domeSun
      Uniforms.sunHeight
      if layer == .behind { Sampler(GlassFrontBuffer.glassFront) }
    }

    var varyings: [Declaration]
    {
      Varying<SIMD3<Float>>("posEye")
      Varying<SIMD3<Float>>("normalEye")
      Varying<SIMD2<Float>>("uv")
      Varying<Float>("primId")
      Varying<SIMD4<Float>>("currClip")
      Varying<SIMD4<Float>>("prevClip")
      Varying<SIMD3<Float>>("posWorld")
      Varying<SIMD3<Float>>("bary")
      Varying<Float>("assembled")
      Varying<SIMD4<Float>>("vcolor")
      Varying<Float>("tri")
    }

    var stages: [Stage]
    {
      Stage(.vertex, glsl: vertexGLSL, msl: vertexMSL)
      {
        Attribute<SIMD4<Float>>("a_position", .position)
        Attribute<SIMD4<Float>>("a_color", .color)
        Attribute<SIMD3<Float>>("a_normal", .normal)
        Attribute<SIMD2<Float>>("a_uv", .texcoord)
        Attribute<Float>("a_pad", .pad)
      }
      Stage(.fragment, glsl: ShaderLibrary.metalOnly, msl: fragmentMSL)
    }

    let vertexGLSL = #"""
      void main()
      {
        vec4 ep = u_modelview * vec4(a_position.xyz, 1.0);
        var.posEye = ep.xyz;
        var.normalEye = normalize(u_normalMatrix * a_normal);
        var.uv = a_uv;
        var.primId = a_color.r;
        var.currClip = u_currViewProj * vec4(a_position.xyz, 1.0);
        var.prevClip = u_prevViewProj * vec4(a_color.yzw, 1.0);
        var.posWorld = a_position.xyz;
        var.tri = a_pad;

        float hidden = floor(a_position.w / 8.0);
        float cornerCode = a_position.w - hidden * 8.0;
        float corner = floor(cornerCode * 0.5);
        var.assembled = clamp(cornerCode - corner * 2.0, 0.0, 1.0);
        var.bary = corner < 0.5 ? vec3(1.0, 0.0, 0.0) : corner < 1.5 ? vec3(0.0, 1.0, 0.0) : vec3(0.0, 0.0, 1.0);

        float packed = a_uv.x < 0.0 ? a_uv.y - 1.0 : -1.0;
        var.vcolor = packed >= 0.0 ? vec4(floor(packed / 65536.0), mod(floor(packed / 256.0), 256.0), mod(packed, 256.0), 255.0) / 255.0
                                   : vec4(0.0);

        gl_Position = u_modelviewProjection * vec4(a_position.xyz, 1.0);
      }
      """#

    let vertexMSL = #"""
      //@main
      {
        float4 objPos = float4(a_position.xyz, 1.0);
        float4 worldPos = u_instance * objPos;
        float4 ep = u_modelview * objPos;
        var.posEye = ep.xyz;
        var.normalEye = normalize(u_normalMatrix * a_normal);
        var.uv = a_uv;
        var.primId = a_color.r;
        var.currClip = u_currViewProj * worldPos;
        var.prevClip = u_prevViewProj * (u_instance * float4(a_color.yzw, 1.0));
        var.posWorld = worldPos.xyz;
        var.tri = a_pad;

        float hidden = floor(a_position.w / 8.0);
        float cornerCode = a_position.w - hidden * 8.0;
        float corner = floor(cornerCode * 0.5);
        var.assembled = saturate(cornerCode - corner * 2.0);
        var.bary = corner < 0.5 ? float3(1.0, 0.0, 0.0) : corner < 1.5 ? float3(0.0, 1.0, 0.0) : float3(0.0, 0.0, 1.0);

        float packed = a_uv.x < 0.0 ? a_uv.y - 1.0 : -1.0;
        var.vcolor = packed >= 0.0 ? float4(floor(packed / 65536.0), fmod(floor(packed / 256.0), 256.0), fmod(packed, 256.0), 255.0) / 255.0
                                   : float4(0.0);

        gl_Position = u_modelviewProjection * objPos;
      }
      """#

    var fragmentMSL: String
    {
      #"""
      \#(ShaderLibrary.styleMSL)

      //@main
      {
        if (styleTexel(u_primStyle, var.primId, 4).y < 0.5) discard_fragment();

        int row = int(-var.uv.x + 0.5) - 1;
        float4 mat = texture(u_material_atlas, var.uv);
        float3 albedo = texture(u_color_atlas, var.uv).rgb;
        float3 emission = float3(0.0);
        if (row >= 0) {
          // 128 material rows share a scanline, see `MaterialAtlas.constantsRowsPerLine`
          uint line = uint(row) >> 7u;
          uint base = uint(row & 127) * 4u;
          float4 c0 = u_materialConstants.read(uint2(base, line));
          float4 c1 = u_materialConstants.read(uint2(base + 1u, line));
          emission = u_materialConstants.read(uint2(base + 2u, line)).rgb;
          mat = float4(c1.r, c1.g, c0.a, c1.b);
          albedo = c0.rgb;
        }

        if (var.vcolor.w > 0.5) albedo *= var.vcolor.rgb;
        if (mat.a > 0.0 || mat.b >= 0.98) discard_fragment();

        uint2 px = uint2(gl_FragCoord.xy);
        if (u_normal_texture.read(px).a >= 0.5 && var.posEye.z < u_position_texture.read(px).z - 1e-4 * abs(var.posEye.z)) discard_fragment();
        \#(layer == .behind ? Self.behindTest : "")

        float3x3 invView = float3x3(
          float3(u_view[0][0], u_view[1][0], u_view[2][0]),
          float3(u_view[0][1], u_view[1][1], u_view[2][1]),
          float3(u_view[0][2], u_view[1][2], u_view[2][2])
        );

        float3 Ne = normalize(var.normalEye);
        float3 Ve = normalize(-var.posEye);
        bool back = dot(Ne, Ve) < 0.0;
        if (back) Ne = -Ne;
        float3 N = invView * Ne;
        float3 V = invView * Ve;

        float3 L = normalize(u_sunDirection.xyz);
        float NoV = saturate(dot(N, V));
        float alpha = saturate(mat.b);
        float roughness = max(mat.r * mat.r, 0.002);
        float f0 = pow((u_transparency.y - 1.0) / (u_transparency.y + 1.0), 2.0);
        float F = f0 + (1.0 - f0) * pow(1.0 - NoV, 5.0);

        // the same sun the lighting pass shades with, from the sky, the dome or an override, none when the scene has no sun
        float3 skyAtSun = u_envCube_texture.sample(u_envCube_texture_smp, mix(L, float3(L.x, L.z, -L.y), u_zUp), level(0.0)).rgb * u_iblTint.rgb;
        float3 dayColor = mix(skyAtSun, float3(1.0), saturate(sunHeight));
        float3 nightColor = mix(skyAtSun, float3(0.95, 0.95, 1.0), saturate(-sunHeight));
        float3 dynamicSky = mix(nightColor * 0.12, dayColor * 3.0, smoothstep(-0.3, 0.05, sunHeight));
        float3 sun = mix(mix(dynamicSky, u_domeSun.rgb, u_domeEnabled) * u_iblEnabled, u_sunOverride.rgb, u_sunOverride.w);

        float3 R = reflect(-V, N);
        float3 sky = mix(R, float3(R.x, R.z, -R.y), u_zUp);
        float3 reflection = u_prefiltered_texture.sample(u_prefiltered_texture_smp, sky, level(mat.r * 5.0)).rgb * u_iblTint.rgb * u_iblEnabled * F;

        float3 H = normalize(V + L);
        float NoH = saturate(dot(N, H));
        float a2 = roughness * roughness;
        float d = NoH * NoH * (a2 - 1.0) + 1.0;
        float NoL = dot(N, L);
        reflection += sun * saturate(NoL) * F * a2 / (3.14159265 * d * d) * 0.25 / max(NoV * saturate(NoL), 0.05);

        // each light's highlight off the outside of the glass, aimed at the nearest point on the light and widened by its size
        int lights = back ? 0 : int(min(u_pointLightCount, 64.0));
        for (int i = 0; i < lights; ++i) {
          float4 posIntensity = u_pointLightData.read(uint2(0, i));
          float4 colorRadius = u_pointLightData.read(uint2(1, i));
          float specular = u_pointLightData.read(uint2(2, i)).y;
          float4 tube = u_pointLightData.read(uint2(3, i));
          float3 toLight = posIntensity.xyz - var.posWorld;
          float distSq = max(dot(toLight, toLight), colorRadius.w * colorRadius.w);
          float reach = colorRadius.w * colorRadius.w * posIntensity.w * max(colorRadius.x, max(colorRadius.y, colorRadius.z)) * 1000.0;
          if (distSq > reach || specular <= 0.0) continue;

          float window = 1.0 - (distSq / reach) * (distSq / reach);
          float radius = colorRadius.w;
          float lineEnergy = 0.0;
          float facing = 1.0;

          if (tube.w > 0.0) {
            float3 full = 2.0 * tube.xyz;
            float rd = dot(R, full);
            float t = saturate((dot(R, toLight - tube.xyz) * rd - dot(toLight - tube.xyz, full)) / max(dot(full, full) - rd * rd, 1e-6));
            toLight = toLight - tube.xyz + full * t;
            distSq = max(dot(toLight, toLight), tube.w * tube.w);
            radius = tube.w;
            lineEnergy = 2.0 * length(full) / (3.14159265 * tube.w);
          } else if (tube.w < 0.0) {
            float3 hx = tube.xyz, hy = u_pointLightData.read(uint2(4, i)).xyz;
            if (dot(cross(hx, hy), toLight) <= 0.0) continue;
            float3 nL = normalize(cross(hx, hy));
            facing = saturate(dot(nL, normalize(toLight)));
            float rn = dot(nL, R);
            float3 hit = rn > 1e-4 ? R * (dot(nL, toLight) / rn) - toLight : R - nL * rn;
            toLight += hx * clamp(dot(hit, hx) / max(dot(hx, hx), 1e-12), -1.0, 1.0)
                     + hy * clamp(dot(hit, hy) / max(dot(hy, hy), 1e-12), -1.0, 1.0);
            distSq = max(dot(toLight, toLight), 1e-8);
            radius = sqrt(4.0 * length(hx) * length(hy) / 3.14159265);
          }

          float sinSigmaSqr = min(radius * radius / distSq, 0.9999);
          float3 centerToRay = dot(toLight, R) * R - toLight;
          float3 Ls = normalize(toLight + centerToRay * saturate(radius / max(length(centerToRay), 1e-6)));
          float NoLs = dot(N, Ls);
          if (NoLs <= 0.0) continue;

          float3 Hs = normalize(V + Ls);
          float NoHs = saturate(dot(N, Hs));
          float widened = saturate(roughness + radius / (2.0 * sqrt(distSq)));
          float normalization = (roughness / widened) * (roughness / widened);
          float along = widened / (widened + length(tube.w > 0.0 ? tube.xyz : float3(0.0)) / sqrt(distSq));
          normalization *= 1.0 + lineEnergy * along * along;
          float aw2 = widened * widened;
          float dw = NoHs * NoHs * (aw2 - 1.0) + 1.0;
          float D = aw2 / (3.14159265 * dw * dw) * normalization;

          reflection += colorRadius.rgb * posIntensity.w * specular * window * window
                      * F * D * 0.25 / max(NoV * NoLs, 0.05) * 3.14159265 * sinSigmaSqr * NoLs * facing;
        }

        float3 Ns = mix(N, float3(N.x, N.z, -N.y), u_zUp);
        float3 irradiance = u_irradiance_texture.sample(u_irradiance_texture_smp, Ns, level(0.0)).rgb * u_iblTint.rgb * u_iblEnabled;
        float3 diffuse = albedo * (irradiance + sun / 3.14159265 * (saturate(NoL) + u_transparency.z * saturate(-NoL))) + emission;

        float depth = max(-var.posEye.z * u_transparency.x, 1e-3);
        float w = alpha * clamp(0.03 / (1e-5 + pow(depth / 200.0, 4.0)), 1e-2, 3e3);

        // the far side is only seen bent through the near side, so it adds just the light it absorbs and no surface of its own
        float3 transmit = (1.0 - alpha) * (back ? 1.0 : 1.0 - F) * mix(float3(1.0), albedo, saturate(1.0 - alpha));
        float3 refracted = refract(-Ve, Ne, 1.0 / u_transparency.y);
        float2 offset = (refracted.xy + Ve.xy) * (1.0 - alpha) * 2.0 * u_transparency.w / max(-var.posEye.z, 1e-4);
        float wo = (1.0 - alpha) * w + 1e-3;

        \#(layer == .all ? Self.allOutputs : Self.behindOutputs)
      }
      """#
    }

    // only what lies behind the nearest glass and is not that glass itself
    private static let behindTest = "float4 nearestGlass = u_glassFront_texture.read(px); if (nearestGlass.w < 0.5 || abs(nearestGlass.w - (var.primId + 1.0)) < 0.5 || var.posEye.z > nearestGlass.z - 1e-4 * abs(var.posEye.z)) discard_fragment();"

    private static let allOutputs = #"""
        o_tColor_texture = back ? float4(0.0) : float4(diffuse * alpha * w, alpha * w);
        o_tReflect_texture = back ? float4(0.0) : float4(reflection * (1.0 - alpha * 0.5), 0.0);
        o_tTransmit_texture = float4(-log(max(transmit, float3(1e-4))), -log(max(1.0 - alpha, 1e-4)));
        o_tOffset_texture = float4(offset * wo, back ? -var.posEye.z : var.posEye.z, wo);
        o_tDepth_texture = float4(1.0 / max(-var.posEye.z, 1e-2), 1.0, 0.0, 0.0);

        float2 tMotion = (var.prevClip.xy / var.prevClip.w - var.currClip.xy / var.currClip.w) * 0.5;
        bool tUsable = var.prevClip.w > 1e-6 && all(isfinite(tMotion));
        float tCover = saturate(alpha + dot(emission, float3(0.1)));
        o_tVelocity_texture = float4((tUsable ? clamp(tMotion, float2(-1.0), float2(1.0)) : float2(0.0)) * tCover, 0.0, tCover);
        """#

    private static let behindOutputs = #"""
        o_bColor_texture = back ? float4(0.0) : float4(diffuse * alpha * w, alpha * w);
        o_bReflect_texture = back ? float4(0.0) : float4(reflection * (1.0 - alpha * 0.5), 0.0);
        o_bTransmit_texture = float4(-log(max(transmit, float3(1e-4))), -log(max(1.0 - alpha, 1e-4)));
        """#
  }
}
