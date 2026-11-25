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
  /// drawn by the `sun shadow temporal` pass.
  struct SunShadowTemporalShader: FullscreenShader
  {
    let name = "sun-shadow-temporal"

    var uniforms: [Declaration]
    {
      Sampler(SunShadowRawBuffer.sunShadowRaw)
      Sampler(SunShadowHistoryBuffer.sunShadowHistory)
      Sampler(GBuffer.position)
      Sampler(GBuffer.normal)
      Sampler(GBuffer.velocity)
      Uniforms.taa
    }

    let fragmentGLSL = #"""
      // blends the noisy sun visibility over frames along each pixel's motion, clamped against smearing and reset where hidden surfaces appear
      void main()
      {
        ivec2 pixel = ivec2(gl_FragCoord.xy);
        ivec2 size = textureSize(u_sunShadowRaw_texture, 0);
        float current = texelFetch(u_sunShadowRaw_texture, pixel, 0).r;
        float depth = log2(max(-texelFetch(u_position_texture, pixel, 0).z, 1e-4));
        if (texelFetch(u_normal_texture, pixel, 0).a < 0.5 || u_taa.x < 0.5) {
          o_sunShadowAccum_texture = vec4(current, depth, texelFetch(u_sunShadowRaw_texture, pixel, 0).g, 0.0);
          return;
        }
        float lo = current, hi = current, nearest = depth, farthest = depth;
        for (int y = -1; y <= 1; ++y) {
          for (int x = -1; x <= 1; ++x) {
            ivec2 q = clamp(pixel + ivec2(x, y), ivec2(0), size - 1);
            if (texelFetch(u_normal_texture, q, 0).a < 0.5) continue;
            float s = texelFetch(u_sunShadowRaw_texture, q, 0).r;
            lo = min(lo, s);
            hi = max(hi, s);
            float d = log2(max(-texelFetch(u_position_texture, q, 0).z, 1e-4));
            nearest = min(nearest, d);
            farthest = max(farthest, d);
          }
        }
        vec2 uv = (vec2(pixel) + 0.5) / vec2(size);
        bool shutter = u_taa.w > 0.5;
        vec2 prevUV = uv + (shutter ? vec2(0.0) : texelFetch(u_velocity_texture, pixel, 0).xy);
        bool offscreen = any(lessThan(prevUV, vec2(0.0))) || any(greaterThan(prevUV, vec2(1.0)));
        vec2 history = texture(u_sunShadowHistory_texture, clamp(prevUV, 0.0, 1.0)).rg;

        // use the nearest texel's depth, since a blend across an edge matches neither surface.
        float historyDepth = texelFetch(u_sunShadowHistory_texture,
                                       clamp(ivec2(prevUV * vec2(size)), ivec2(0), size - 1), 0).g;

        // edge on surfaces span more depth than the jitter, so any history depth within the neighbors' range is accepted
        bool uncovered = !shutter && !(historyDepth > nearest - 0.03 && historyDepth < farthest + 0.03);

        // a rebuilt or unwritten history holds garbage, so only keep visibility between 0 and 1.
        bool unusable = !(history.r >= 0.0 && history.r <= 1.0);
        float alpha = (u_taa.y > 0.5 || offscreen || uncovered || unusable) ? 1.0 : max(u_taa.z, 0.05);
        float kept = unusable ? current : clamp(history.r, lo, hi);
        float spread = texelFetch(u_sunShadowRaw_texture, pixel, 0).g;
        float keptSpread = unusable ? spread : texture(u_sunShadowHistory_texture, clamp(prevUV, 0.0, 1.0)).b;
        o_sunShadowAccum_texture = vec4(clamp(mix(kept, current, alpha), 0.0, 1.0), depth, mix(keptSpread, spread, alpha), 0.0);
      }
      """#

    let fragmentMSL = #"""
      //@main
      {
        int2 pixel = int2(gl_FragCoord.xy);
        int2 size = int2(u_sunShadowRaw_texture.get_width(), u_sunShadowRaw_texture.get_height());
        float current = u_sunShadowRaw_texture.read(uint2(pixel)).r;
        float depth = log2(max(-u_position_texture.read(uint2(pixel)).z, 1e-4));
        if (u_normal_texture.read(uint2(pixel)).a < 0.5 || u_taa.x < 0.5) {
          o_sunShadowAccum_texture = float4(current, depth, u_sunShadowRaw_texture.read(uint2(pixel)).g, 0.0);
        } else {
          float lo = current, hi = current, nearest = depth, farthest = depth;
          for (int y = -1; y <= 1; ++y) {
            for (int x = -1; x <= 1; ++x) {
              uint2 q = uint2(clamp(pixel + int2(x, y), int2(0), size - 1));
              if (u_normal_texture.read(q).a < 0.5) continue;
              float s = u_sunShadowRaw_texture.read(q).r;
              lo = min(lo, s);
              hi = max(hi, s);
              float d = log2(max(-u_position_texture.read(q).z, 1e-4));
              nearest = min(nearest, d);
              farthest = max(farthest, d);
            }
          }
          float2 uv = (float2(pixel) + 0.5) / float2(size);
          bool shutter = u_taa.w > 0.5;
          float2 prevUV = uv + (shutter ? float2(0.0) : u_velocity_texture.read(uint2(pixel)).xy);
          bool offscreen = any(prevUV < float2(0.0)) || any(prevUV > float2(1.0));
          float2 history = texture(u_sunShadowHistory_texture, clamp(prevUV, 0.0, 1.0)).rg;

          // use the nearest texel's depth, since a blend across an edge matches neither surface.
          float historyDepth = u_sunShadowHistory_texture.read(uint2(clamp(int2(prevUV * float2(size)), int2(0), size - 1))).g;

          // edge on surfaces span more depth than the jitter, so any history depth within the neighbors' range is accepted
          bool uncovered = !shutter && !(historyDepth > nearest - 0.03 && historyDepth < farthest + 0.03);

          // a rebuilt or unwritten history holds garbage, so only keep visibility between 0 and 1.
          bool unusable = !(history.r >= 0.0 && history.r <= 1.0);
          float alpha = (u_taa.y > 0.5 || offscreen || uncovered || unusable) ? 1.0 : max(u_taa.z, 0.05);
          float kept = unusable ? current : clamp(history.r, lo, hi);
          float spread = u_sunShadowRaw_texture.read(uint2(pixel)).g;
          float keptSpread = unusable ? spread : texture(u_sunShadowHistory_texture, clamp(prevUV, 0.0, 1.0)).b;
          o_sunShadowAccum_texture = float4(saturate(mix(kept, current, alpha)), depth, mix(keptSpread, spread, alpha), 0.0);
        }
      }
      """#
  }
}
