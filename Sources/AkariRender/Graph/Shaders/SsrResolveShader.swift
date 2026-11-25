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
  /// drawn by the ssr resolve pass, each pixel's reflection rebuilt from its own and its neighbours' rays weighed by its glossy lobe
  struct SsrResolveShader: FullscreenShader
  {
    let name = "ssr-resolve"

    var uniforms: [Declaration]
    {
      Sampler(SsrBuffer.ssrRadiance)
      Sampler(SsrBuffer.ssrGuide)
      Sampler(SsrBuffer.ssrRay)
      Sampler(GBuffer.position)
      Sampler(GBuffer.material)
      Uniforms.ssr
      Uniforms.halfScale
      Uniforms.frameIndex
    }

    let fragmentGLSL = #"""
      void main()
      {
        vec4 r = texelFetch(u_ssrRadiance_texture, ivec2(gl_FragCoord.xy), 0);
        o_ssrResolved_texture = vec4(r.rgb * r.a, r.a);
      }
      """#

    let fragmentMSL = #"""
      constexpr constant float PI = 3.14159265358979;

      float3 finiteColor(float3 c)
      {
        bool3 bad = (as_type<uint3>(c) & 0x7F800000u) == 0x7F800000u;
        return select(clamp(c, 0.0, 65000.0), float3(0.0), bad);
      }

      float luma(float3 c)
      {
        return dot(c, float3(0.2126, 0.7152, 0.0722));
      }

      //@main
      {
        int2 hp = int2(gl_FragCoord.xy);
        int2 halfSize = int2(u_ssrRadiance_texture.get_width(), u_ssrRadiance_texture.get_height());
        int2 fullSize = int2(u_position_texture.get_width(), u_position_texture.get_height());
        float4 gc = u_ssrGuide_texture.read(uint2(hp));
        float4 resolved = float4(0.0);
        if (u_ssr.z > 0.5 && any(gc.xyz != float3(0.0))) {
          uint2 fp = uint2(min(int2(float2(hp) * u_halfScale.xy), fullSize - 1));
          float roughness = clamp(u_material_texture.read(fp).r, 0.045, 1.0);
          float a2 = roughness * roughness * roughness * roughness;
          float3 N = gc.xyz;
          float3 V = normalize(-u_position_texture.read(fp).xyz);
          float NoV = max(dot(N, V), 1e-4);
          float G1 = 2.0 * NoV / (NoV + sqrt(a2 + (1.0 - a2) * NoV * NoV));
          float depthScale = 1.0 / max(0.01 * abs(gc.w), 1e-3);
          float noise = fract(52.9829189 * fract(dot(gl_FragCoord.xy + 5.588238 * float(frameIndex % 64), float2(0.06711056, 0.00583715))));

          // a rougher lobe borrows from a little farther, kept tight so the grain stays fine and the temporal pass can see it
          float radius = mix(1.0, 2.5, saturate(roughness * 1.4));
          float4 sum = float4(0.0);
          float wsum = 0.0;
          for (int i = 0; i < 9; ++i) {
            float r = i == 0 ? 0.0 : sqrt((float(i) - 0.5) / 8.0) * radius;
            float turn = float(i) * 2.3999632 + 6.2831853 * noise;
            int2 h = clamp(hp + int2(round(float2(cos(turn), sin(turn)) * r)), int2(0), halfSize - 1);
            float4 gs = u_ssrGuide_texture.read(uint2(h));
            float4 ray = u_ssrRay_texture.read(uint2(h));
            if (all(gs.xyz == float3(0.0)) || ray.w <= 0.0 || dot(N, ray.xyz) <= 0.0) continue;

            // how likely this pixel was to send that ray, over how likely its own pixel was
            float NoH = saturate(dot(N, normalize(V + ray.xyz)));
            float dd = NoH * NoH * (a2 - 1.0) + 1.0;
            float w = min(a2 / (PI * dd * dd) * G1 / (4.0 * NoV) / max(ray.w, 1e-4), 10.0);
            w *= exp(-abs(gs.w - gc.w) * depthScale) * pow(max(dot(gc.xyz, gs.xyz), 0.0), 8.0);

            // misses count too so coverage stays smooth, averaged with bright samples squashed so one lucky ray lights a speck not a blob
            float4 hit = u_ssrRadiance_texture.read(uint2(h));
            float3 c = finiteColor(hit.rgb) * hit.a;
            sum += w * float4(c / (1.0 + luma(c)), hit.a);
            wsum += w;
          }
          resolved = wsum > 1e-6 ? sum / wsum : float4(0.0);
          resolved.rgb /= max(1.0 - luma(resolved.rgb), 1e-3);
        }
        o_ssrResolved_texture = resolved;
      }
      """#
  }
}
