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
  /// drawn by the `outline span` pass
  struct OutlineSpanShader: FullscreenShader
  {
    let name = "outline-span"

    var uniforms: [Declaration]
    {
      Sampler(OutlineEdgeBuffer.outlineEdge)
      Uniforms.outline
    }

    let fragmentGLSL = #"""
      void main()
      {
        // horizontal part of the distance to the nearest edge, along with that edge's depth
        ivec2 pixel = ivec2(gl_FragCoord.xy);
        int width = textureSize(u_outlineEdge_texture, 0).x;
        int radius = int(ceil(max(u_outline.w, 1.0) * 0.5 + 1.0));
        float best = 1024.0;
        float depth = 0.0;
        for (int dx = -radius; dx <= radius; ++dx) {
          int x = pixel.x + dx;
          if (x < 0 || x >= width) continue;
          vec2 edge = texelFetch(u_outlineEdge_texture, ivec2(x, pixel.y), 0).rg;
          if (edge.r > 0.5 && float(abs(dx)) < best) {
            best = float(abs(dx));
            depth = edge.g;
          }
        }

        o_outlineSpan_texture = vec4(best, depth, 0.0, 0.0);
      }
      """#

    let fragmentMSL = #"""
      //@main
      {
        // horizontal part of the distance to the nearest edge, along with that edge's depth
        int2 pixel = int2(gl_FragCoord.xy);
        int width = int(u_outlineEdge_texture.get_width());
        int radius = int(ceil(max(u_outline.w, 1.0) * 0.5 + 1.0));
        float best = 1024.0;
        float depth = 0.0;
        for (int dx = -radius; dx <= radius; ++dx) {
          int x = pixel.x + dx;
          if (x < 0 || x >= width) continue;
          float2 edge = u_outlineEdge_texture.read(uint2(x, pixel.y)).rg;
          if (edge.r > 0.5 && float(abs(dx)) < best) {
            best = float(abs(dx));
            depth = edge.g;
          }
        }

        o_outlineSpan_texture = float4(best, depth, 0.0, 0.0);
      }
      """#
  }
}
