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
  /// drawn by the `outline` pass
  struct OutlineCompositeShader: FullscreenShader
  {
    let name = "outline-composite"

    var uniforms: [Declaration]
    {
      Sampler(TonemapBuffer.tonemap)
      Sampler(OutlineSpanBuffer.outlineSpan)
      Sampler(OutlineMaskBuffer.outlineMask)
      Sampler(GBuffer.position)
      Sampler(GBuffer.normal)
      Samplers.outlineLabels
      Uniforms.outline
      Uniforms.outlineColor
      Uniforms.renderScale
      Uniforms.taaJitter
    }

    let fragmentGLSL = #"""
      void main()
      {
        ivec2 pixel = ivec2(gl_FragCoord.xy);
        int height = textureSize(u_outlineSpan_texture, 0).y;
        float halfWidth = max(u_outline.w, 1.0) * 0.5;
        int radius = int(ceil(halfWidth + 1.0));

        float best = 1048576.0;
        float depth = 0.0;
        for (int dy = -radius; dy <= radius; ++dy) {
          int y = pixel.y + dy;
          if (y < 0 || y >= height) continue;
          vec2 span = texelFetch(u_outlineSpan_texture, ivec2(pixel.x, y), 0).rg;
          float d = span.x * span.x + float(dy * dy);
          if (d < best) { best = d; depth = span.y; }
        }

        // a one pixel falloff on each side smooths the line's stair steps
        float coverage = 1.0 - smoothstep(halfWidth - 1.0, halfWidth + 1.0, sqrt(best));

        // hide the line where something unselected is in front of the edge it belongs to
        ivec2 gSize = textureSize(u_position_texture, 0);
        ivec2 g = clamp(ivec2(floor((vec2(pixel) + 0.5) * u_renderScale.xy + u_taaJitter.xy)), ivec2(0), gSize - 1);
        vec4 scene = texelFetch(u_position_texture, g, 0);
        int sceneId = int(round(scene.w));
        int width = int(u_outline.y);
        float sceneLabel = sceneId >= 0 && float(sceneId) < u_outline.z
          ? texelFetch(u_outlineLabels, ivec2(sceneId % width, sceneId / width), 0).r : 0.0;
        bool inFront = texelFetch(u_normal_texture, g, 0).a >= 0.5 && sceneLabel <= 0.0 &&
                       scene.z > depth + max(0.01 * abs(depth), 1e-3);
        if (inFront || texelFetch(u_outlineMask_texture, pixel, 0).r < 0.0) coverage = 0.0;

        vec4 color = texelFetch(u_tonemap_texture, pixel, 0);
        o_outline_texture = vec4(mix(color.rgb, u_outlineColor.rgb, coverage * u_outlineColor.a), color.a);
      }
      """#

    let fragmentMSL = #"""
      //@main
      {
        int2 pixel = int2(gl_FragCoord.xy);
        int height = int(u_outlineSpan_texture.get_height());
        float halfWidth = max(u_outline.w, 1.0) * 0.5;
        int radius = int(ceil(halfWidth + 1.0));

        float best = 1048576.0;
        float depth = 0.0;
        for (int dy = -radius; dy <= radius; ++dy) {
          int y = pixel.y + dy;
          if (y < 0 || y >= height) continue;
          float2 span = u_outlineSpan_texture.read(uint2(pixel.x, y)).rg;
          float d = span.x * span.x + float(dy * dy);
          if (d < best) { best = d; depth = span.y; }
        }

        // a one pixel falloff on each side smooths the line's stair steps
        float coverage = 1.0 - smoothstep(halfWidth - 1.0, halfWidth + 1.0, sqrt(best));

        // hide the line where something unselected is in front of the edge it belongs to
        if (coverage > 0.0) {
          int2 gSize = int2(u_position_texture.get_width(), u_position_texture.get_height());
          uint2 g = uint2(clamp(int2(floor((float2(pixel) + 0.5) * u_renderScale.xy + u_taaJitter.xy)), int2(0), gSize - 1));
          float4 scene = u_position_texture.read(g);
          int sceneId = int(round(scene.w));
          int width = int(u_outline.y);
          float sceneLabel = 0.0;
          if (sceneId >= 0 && float(sceneId) < u_outline.z) {
            sceneLabel = u_outlineLabels.read(uint2(sceneId % width, sceneId / width)).r;
          }
          bool inFront = u_normal_texture.read(g).a >= 0.5 && sceneLabel <= 0.0 &&
                         scene.z > depth + max(0.01 * abs(depth), 1e-3);
          if (inFront || u_outlineMask_texture.read(uint2(pixel)).r < 0.0) coverage = 0.0;
        }

        float4 color = u_tonemap_texture.read(uint2(pixel));
        o_outline_texture = float4(mix(color.rgb, u_outlineColor.rgb, coverage * u_outlineColor.a), color.a);
      }
      """#
  }
}
