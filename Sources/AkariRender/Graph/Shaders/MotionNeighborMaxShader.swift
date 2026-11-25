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
  /// drawn by the `motion neighbors pre` and `motion neighbors` passes
  struct MotionNeighborMaxShader: FullscreenShader
  {
    let name = "motion-neighbor-max"

    var uniforms: [Declaration]
    {
      Sampler(MotionTilesBuffer.motionTileMax)
    }

    let fragmentGLSL = #"""
      void main()
      {
        ivec2 size = textureSize(u_motionTileMax_texture, 0);
        ivec2 c = ivec2(gl_FragCoord.xy);
        vec2 best = vec2(0.0);
        for (int y = -1; y <= 1; ++y)
          for (int x = -1; x <= 1; ++x) {
            vec2 v = texelFetch(u_motionTileMax_texture, clamp(c + ivec2(x, y), ivec2(0), size - 1), 0).xy;
            if (dot(v, v) > dot(best, best)) best = v;
          }
        o_motionNeighborMax_texture = vec4(best, length(best), 0.0);
      }
      """#

    let fragmentMSL = #"""
      //@main
      {
        int2 size = int2(u_motionTileMax_texture.get_width(), u_motionTileMax_texture.get_height());
        int2 c = int2(gl_FragCoord.xy);
        float2 best = float2(0.0);
        for (int y = -1; y <= 1; ++y) {
          for (int x = -1; x <= 1; ++x) {
            float2 v = u_motionTileMax_texture.read(uint2(clamp(c + int2(x, y), int2(0), size - 1))).xy;
            if (dot(v, v) > dot(best, best)) best = v;
          }
        }
        o_motionNeighborMax_texture = float4(best, length(best), 0.0);
      }
      """#
  }
}
