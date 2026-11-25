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
  /// drawn by the ssr temporal pass, the resolved reflection blended over time with history that belongs to the same surface
  struct SsrTemporalShader: FullscreenShader
  {
    let name = "ssr-temporal"

    var uniforms: [Declaration]
    {
      Sampler(SsrResolveBuffer.ssrResolved)
      Sampler(SsrBuffer.ssrGuide)
      Sampler(SsrBuffer.ssrMotion)
      Sampler(SsrHistoryBuffer.ssrHistory)
      Sampler(SsrHistoryBuffer.ssrGuideHistory)
      Sampler(SsrHistoryBuffer.ssrMotionHistory)
      Sampler(GBuffer.position)
      Sampler(GBuffer.material)
      Sampler(GBuffer.velocity)
      Uniforms.view
      Uniforms.prevViewProj
      Uniforms.currViewProj
      Uniforms.taa
      Uniforms.ssr
      Uniforms.halfScale
    }

    let fragmentGLSL = #"""
      vec4 finiteColor4(vec4 c)
      {
        bvec4 bad = equal(floatBitsToUint(c) & 0x7F800000u, uvec4(0x7F800000u));
        return mix(clamp(c, 0.0, 65000.0), vec4(0.0), bad);
      }

      void main()
      {
        ivec2 hp = ivec2(gl_FragCoord.xy);
        ivec2 halfSize = textureSize(u_ssrResolved_texture, 0);
        vec4 gc = texelFetch(u_ssrGuide_texture, hp, 0);
        o_ssrMotionMemory_texture = vec4(0.0);
        if (u_ssr.z < 0.5 || gc.xyz == vec3(0.0)) {
          o_ssrAccum_texture = vec4(0.0);
          return;
        }
        ivec2 fullSize = textureSize(u_material_texture, 0);
        ivec2 fp = min(ivec2(vec2(hp) * u_halfScale.xy), fullSize - 1);
        float depthScale = 1.0 / max(0.01 * abs(gc.w), 1e-3);
        vec4 current = finiteColor4(texelFetch(u_ssrResolved_texture, hp, 0));
        vec4 m1 = vec4(0.0), m2 = vec4(0.0);
        float wsum = 0.0, moving = 0.0, flowWeight = 0.0;
        vec2 flowSum = vec2(0.0);
        for (int y = -1; y <= 1; ++y) {
          for (int x = -1; x <= 1; ++x) {
            ivec2 h = clamp(hp + ivec2(x, y), ivec2(0), halfSize - 1);
            vec4 gs = texelFetch(u_ssrGuide_texture, h, 0);
            if (gs.xyz == vec3(0.0)) continue;
            float w = exp(-abs(gs.w - gc.w) * depthScale) * pow(max(dot(gc.xyz, gs.xyz), 0.0), 8.0);
            vec4 c = finiteColor4(texelFetch(u_ssrResolved_texture, h, 0));
            m1 += c * w;
            m2 += c * c * w;
            wsum += w;
            vec4 motion = texelFetch(u_ssrMotion_texture, h, 0);
            moving += motion.z * w;
            if (motion.w > 0.0) { flowSum += motion.xy * w; flowWeight += w; }
          }
        }

        // averaged rather than the largest, since on a rough floor only some rays land on the moving object and a max turns that into speckle
        moving /= max(wsum, 1e-4);
        vec4 mean = m1 / max(wsum, 1e-4);
        vec4 sigma = sqrt(max(m2 / max(wsum, 1e-4) - mean * mean, 0.0));
        if (u_taa.x < 0.5) {
          o_ssrAccum_texture = current;
          return;
        }
        vec2 uv = (vec2(hp) + 0.5) / vec2(halfSize);
        vec2 surfaceUV = uv + texelFetch(u_velocity_texture, fp, 0).xy;
        vec2 prevUV = flowWeight > 0.0 ? uv + flowSum / flowWeight : surfaceUV;
        bool offscreen = any(lessThan(prevUV, vec2(0.0))) || any(greaterThan(prevUV, vec2(1.0)));
        vec4 prevGuide = texelFetch(u_ssrGuideHistory_texture, clamp(ivec2(surfaceUV * vec2(halfSize)), ivec2(0), halfSize - 1), 0);
        bool revealed = prevGuide.xyz == vec3(0.0) || abs(prevGuide.w - gc.w) > 0.04 * abs(gc.w) + 0.02 || dot(prevGuide.xyz, gc.xyz) < 0.8;
        float memory = max(moving, 0.6 * texture(u_ssrMotionHistory_texture, clamp(prevUV, 0.0, 1.0)).r);
        o_ssrMotionMemory_texture = vec4(memory, 0.0, 0.0, 0.0);
        float settle = clamp(memory / 2.0, 0.0, 1.0);

        // the farther the history had to be carried to line up, the less exactly it lines up, so a fast camera bounds it tighter
        float carried = clamp(length((prevUV - uv) * vec2(halfSize)) / 6.0, 0.0, 1.0);
        float distrust = max(settle, carried);
        float gamma = mix(2.0, 0.75, distrust);
        vec4 history = clamp(finiteColor4(texture(u_ssrHistory_texture, clamp(prevUV, 0.0, 1.0))), mean - gamma * sigma, mean + gamma * sigma);

        // with little history to lean on, the neighbourhood's average stands in for the lone noisy sample
        current = mix(current, mean, (offscreen || revealed) ? 1.0 : 0.25 * settle);
        float alpha = (u_taa.y > 0.5 || u_ssr.w > 0.5 || offscreen || revealed) ? 1.0 : max(clamp(u_taa.z, 0.05, 0.1), max(0.12 * settle, 0.2 * carried));
        o_ssrAccum_texture = mix(history, current, alpha);
      }
      """#

    let fragmentMSL = #"""
      float4 finiteColor4(float4 c)
      {
        bool4 bad = (as_type<uint4>(c) & 0x7F800000u) == 0x7F800000u;
        return select(clamp(c, 0.0, 65000.0), float4(0.0), bad);
      }

      //@main
      {
        int2 hp = int2(gl_FragCoord.xy);
        int2 halfSize = int2(u_ssrResolved_texture.get_width(), u_ssrResolved_texture.get_height());
        float4 gc = u_ssrGuide_texture.read(uint2(hp));
        o_ssrMotionMemory_texture = float4(0.0);
        if (u_ssr.z < 0.5 || all(gc.xyz == float3(0.0))) {
          o_ssrAccum_texture = float4(0.0);
        } else {
          int2 fullSize = int2(u_material_texture.get_width(), u_material_texture.get_height());
          uint2 fp = uint2(min(int2(float2(hp) * u_halfScale.xy), fullSize - 1));
          float depthScale = 1.0 / max(0.01 * abs(gc.w), 1e-3);
          float4 current = finiteColor4(u_ssrResolved_texture.read(uint2(hp)));

          // the resolved neighbourhood is quiet enough to bound the history tightly
          float4 m1 = float4(0.0), m2 = float4(0.0);
          float wsum = 0.0, moving = 0.0, flowWeight = 0.0;
          float2 flowSum = float2(0.0);
          for (int y = -1; y <= 1; ++y) {
            for (int x = -1; x <= 1; ++x) {
              uint2 h = uint2(clamp(hp + int2(x, y), int2(0), halfSize - 1));
              float4 gs = u_ssrGuide_texture.read(h);
              if (all(gs.xyz == float3(0.0))) continue;
              float w = exp(-abs(gs.w - gc.w) * depthScale) * pow(max(dot(gc.xyz, gs.xyz), 0.0), 8.0);
              float4 c = finiteColor4(u_ssrResolved_texture.read(h));
              m1 += c * w;
              m2 += c * c * w;
              wsum += w;
              float4 motion = u_ssrMotion_texture.read(h);
              moving += motion.z * w;
              if (motion.w > 0.0) { flowSum += motion.xy * w; flowWeight += w; }
            }
          }

          // averaged rather than the largest, since on a rough floor only some rays land on the moving object and a max turns that into speckle
          moving /= max(wsum, 1e-4);
          float4 mean = m1 / max(wsum, 1e-4);
          float4 sigma = sqrt(max(m2 / max(wsum, 1e-4) - mean * mean, 0.0));

          if (u_taa.x < 0.5) {
            o_ssrAccum_texture = current;
          } else {
            float2 uv = (float2(hp) + 0.5) / float2(halfSize);
            float2 surfaceUV = uv + u_velocity_texture.read(fp).xy;

            // the trace already found where each ray's mirrored image was last frame, through the camera and the reflected object's own motion
            float2 prevUV = flowWeight > 0.0 ? uv + flowSum / flowWeight : surfaceUV;
            bool offscreen = any(prevUV < float2(0.0)) || any(prevUV > float2(1.0));

            // a surface that was not here last frame just came into view, so whatever reflected there before is not its history
            float4 prevGuide = u_ssrGuideHistory_texture.read(uint2(clamp(int2(surfaceUV * float2(halfSize)), int2(0), halfSize - 1)));
            bool revealed = all(prevGuide.xyz == float3(0.0)) || abs(prevGuide.w - gc.w) > 0.04 * abs(gc.w) + 0.02
                         || dot(prevGuide.xyz, gc.xyz) < 0.8;

            // where what it reflects moves, or moved over the last few frames, the history is trusted less and bounded tighter
            float memory = max(moving, 0.6 * texture(u_ssrMotionHistory_texture, clamp(prevUV, 0.0, 1.0)).r);
            o_ssrMotionMemory_texture = float4(memory, 0.0, 0.0, 0.0);
            float settle = saturate(memory / 2.0);

            // the farther the history had to be carried to line up, the less exactly it lines up, so a fast camera bounds it tighter
            float carried = saturate(length((prevUV - uv) * float2(halfSize)) / 6.0);
            float distrust = max(settle, carried);

            // a still reflection is bounded loosely so ten frames of rays actually average instead of chasing each frame's noise
            float gamma = mix(2.0, 0.75, distrust);
            float4 history = clamp(finiteColor4(texture(u_ssrHistory_texture, clamp(prevUV, 0.0, 1.0))),
                                   mean - gamma * sigma, mean + gamma * sigma);

            // with little history to lean on, the neighbourhood's average stands in for the lone noisy sample
            current = mix(current, mean, (offscreen || revealed) ? 1.0 : 0.25 * settle);

            // the main resolve shortens its history whenever the camera moves, but reflections follow their own motion here so they keep ten frames
            float alpha = (u_taa.y > 0.5 || u_ssr.w > 0.5 || offscreen || revealed) ? 1.0 : max(clamp(u_taa.z, 0.05, 0.1), max(0.12 * settle, 0.2 * carried));
            o_ssrAccum_texture = mix(history, current, alpha);
          }
        }
      }
      """#
  }
}
