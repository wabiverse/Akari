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
  /// drawn by the `outline edge` pass
  struct OutlineEdgeShader: FullscreenShader
  {
    let name = "outline-edge"

    var uniforms: [Declaration]
    {
      Sampler(OutlineMaskBuffer.outlineMask)
    }

    let fragmentGLSL = #"""
      void main()
      {
        ivec2 pixel = ivec2(gl_FragCoord.xy);
        ivec2 size = textureSize(u_outlineMask_texture, 0);
        ivec2 offsets[4] = ivec2[4](ivec2(1, 0), ivec2(-1, 0), ivec2(0, 1), ivec2(0, -1));

        // edges follow the selection's own silhouette, hidden parts too, and the composite hides what's behind something
        vec2 mask = texelFetch(u_outlineMask_texture, pixel, 0).rg;
        float label = abs(mask.r);
        bool edge = false;
        for (int i = 0; i < 4; ++i) {
          ivec2 q = clamp(pixel + offsets[i], ivec2(0), size - 1);
          edge = edge || abs(texelFetch(u_outlineMask_texture, q, 0).r) != label;
        }

        // y passes the selected surface's depth along to the composite
        o_outlineEdge_texture = vec4(label > 0.0 && edge ? 1.0 : 0.0, mask.g, 0.0, 0.0);
      }
      """#

    let fragmentMSL = #"""
      //@main
      {
        int2 pixel = int2(gl_FragCoord.xy);
        int2 size = int2(u_outlineMask_texture.get_width(), u_outlineMask_texture.get_height());
        const int2 offsets[4] = { int2(1, 0), int2(-1, 0), int2(0, 1), int2(0, -1) };

        // edges follow the selection's own silhouette, hidden parts too, and the composite hides what's behind something
        float2 mask = u_outlineMask_texture.read(uint2(pixel)).rg;
        float label = abs(mask.r);
        bool edge = false;
        for (int i = 0; i < 4; ++i) {
          uint2 q = uint2(clamp(pixel + offsets[i], int2(0), size - 1));
          edge = edge || abs(u_outlineMask_texture.read(q).r) != label;
        }

        // y passes the selected surface's depth along to the composite
        o_outlineEdge_texture = float4(label > 0.0 && edge ? 1.0 : 0.0, mask.g, 0.0, 0.0);
      }
      """#
  }
}
