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
  /// drawn by the `fog sim march` pass.
  struct FogSimMarchShader: FullscreenShader
  {
    let name = "fog-sim-march"

    var uniforms: [Declaration]
    {
      Sampler(GBuffer.position)
      Sampler(GBuffer.normal)
      Sampler(VolumeScatterBuffer.volumeScatter)
      Samplers.fogSim
      Samplers.fogSimVelocity
      Samplers.fogSimVisibility
      Uniforms.view
      Uniforms.proj
      Uniforms.invProj
      Uniforms.zUp
      Uniforms.volumeRange
      Uniforms.volumeNoise
      Uniforms.volumeFlow
      Uniforms.fogSimMin
      Uniforms.fogSimMax
      Uniforms.frameIndex
    }

    let fragmentGLSL = ShaderLibrary.metalOnly

    let fragmentMSL = #"""
      \#(ShaderLibrary.fogMSL)

      /// the froxel fog's scattered light at `posEye` per unit of density, smooth so the simulated detail rides on it
      float3 froxelLight(texture2d<float> scatter, sampler smp, float3 posEye, constant Uniforms& u)
      {
        float4 c = u.u_proj * float4(posEye, 1.0);
        float2 uv = c.xy / c.w * 0.5 + 0.5;
        float2 grid = max(u.u_volumeRange.zw, float2(1.0));

        float depth = -posEye.z;
        float slice = sqrt(saturate((depth - u.u_volumeRange.x) / max(u.u_volumeRange.y - u.u_volumeRange.x, 1e-4))) * 64.0 - 0.5;
        int s0 = int(clamp(floor(slice), 0.0, 63.0)), s1 = min(s0 + 1, 63);
        float f = saturate(slice - float(s0));

        float2 inTile = clamp(uv * grid, float2(0.5), grid - 0.5);
        float2 size = float2(scatter.get_width(), scatter.get_height());
        float4 a = scatter.sample(smp, (float2(float(s0 % 8), float(s0 / 8)) * grid + inTile) / size, level(0.0));
        float4 b = scatter.sample(smp, (float2(float(s1 % 8), float(s1 / 8)) * grid + inTile) / size, level(0.0));

        // a slice behind the surface holds no light, take the other.
        if (a.a > 1.5) a = b;
        if (b.a > 1.5) b = a;

        return mix(a.rgb, b.rgb, f);
      }

      //@main
      {
        if (u_fogSimMin.w < 0.5) discard_fragment();

        float4 e = u_invProj * float4(var.texCoord * 2.0 - 1.0, -1.0, 1.0);
        float3x3 invView = float3x3(
          float3(u_view[0][0], u_view[1][0], u_view[2][0]),
          float3(u_view[0][1], u_view[1][1], u_view[2][1]),
          float3(u_view[0][2], u_view[1][2], u_view[2][2])
        );
        float3 eye = invView * -float3(u_view[3][0], u_view[3][1], u_view[3][2]);
        float3 dir = normalize(invView * (e.xyz / e.w));

        uint2 px = min(uint2(gl_FragCoord.xy) * 2, uint2(u_position_texture.get_width(), u_position_texture.get_height()) - 1);
        float tMax = u_normal_texture.read(px).a >= 0.5 ? length(u_position_texture.read(px).xyz) : 1e30;

        float3 lo = u_fogSimMin.xyz, hi = u_fogSimMax.xyz;
        float3 inv = 1.0 / select(dir, float3(1e-9), abs(dir) < 1e-9);
        float3 ta = (lo - eye) * inv, tb = (hi - eye) * inv;
        float3 tn = min(ta, tb), tf = max(ta, tb);
        float t0 = max(max(max(tn.x, tn.y), tn.z), 0.0);
        float t1 = min(min(min(tf.x, tf.y), tf.z), tMax);
        if (t0 >= t1) discard_fragment();

        float cellSize = max(u_fogSimMax.w, 1e-3);
        float noise = fract(52.9829189 * fract(dot(gl_FragCoord.xy + 5.588238 * float(frameIndex % 64), float2(0.06711056, 0.00583715))));
        float3 extent = max(hi - lo, float3(1e-4));
        float3 L = float3(0.0);
        float T = 1.0;

        // steps are two and a half cells long near the eye and grow with distance as the fog shrinks on screen.
        float t = t0;
        for (int i = 0; i < 128 && t < t1; ++i) {
          float dt = min(cellSize * 2.5 * (1.0 + 0.04 * t), t1 - t);
          float3 p = eye + dir * (t + noise * dt);
          t += dt;
          float3 uvw = (p - lo) / extent;
          if (u_zUp < 0.5) uvw = uvw.xzy;
          float d = u_fogSim.sample(u_fogSim_smp, uvw, level(0.0)).r;
          if (d < 1e-4) continue;

          // detail finer than the grid rides the simulated flow in two phases half a period apart, neyret's advected textures
          if (u_volumeNoise.x > 0.0) {
            float3 v = u_fogSimVelocity.sample(u_fogSim_smp, uvw, level(0.0)).xyz;
            float period = 1.5;
            float scale = max(u_volumeNoise.y * 0.16, 1e-3);
            float detail = 0.0;
            for (int k = 0; k < 2; ++k) {
              float phase = fract(u_volumeFlow.w / period + 0.5 * float(k));
              float3 q = p - v * (phase * period) + float3(13.7, 4.1, 9.3) * floor(u_volumeFlow.w / period + 0.5 * float(k));
              detail += fogFbm(q / scale, 3) * (1.0 - abs(2.0 * phase - 1.0));
            }
            float wisp = saturate(1.0 - abs(detail - 0.5) * 3.2);
            d *= saturate(mix(1.0, 0.1 + 2.2 * wisp * wisp + 0.5 * detail, u_volumeNoise.x * saturate(1.2 - d * 0.6)));
          }

          float3 posEye = (u_view * float4(p, 1.0)).xyz;
          float3 light = froxelLight(u_volumeScatter_texture, u_volumeScatter_texture_smp, posEye, _u)
                       * u_fogSimVisibility.sample(u_fogSim_smp, uvw, level(0.0)).r;

          float stepT = exp(-d * dt);
          L += T * light * (1.0 - stepT);
          T *= stepT;
          if (T < 0.01) break;
        }

        if (T >= 0.999 || !all(isfinite(L)) || !isfinite(T)) discard_fragment();
        o_fogSimHalf_texture = float4(min(L, float3(60000.0)), 1.0 - T);
      }
      """#
  }
}
