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
  /// drawn by the `depth of field tiles 8` pass.
  struct DofTileCocShader: FullscreenShader
  {
    let name = "dof-tile-coc"

    var uniforms: [Declaration]
    {
      Sampler(DofDepthBuffer.dofDepth)
      Uniforms.dof
    }

    let fragmentGLSL = #"""
      void main()
      {
        o_dofTile8_texture = vec4(0.0);
      }
      """#

    let fragmentMSL = #"""
      \#(ShaderLibrary.postMSL)

      //@main
      {
        int2 size = int2(u_dofDepth_texture.get_width(), u_dofDepth_texture.get_height());
        int2 lo = int2(floor(gl_FragCoord.xy)) * 8;
        float3 range = float3(0.0, 1e4, 0.0);

        // fixed bounds let the reads go out together, a tile past the edge reads its own last texels again.
        for (int y = 0; y < 8; ++y) {
          for (int x = 0; x < 8; ++x) {
            float z = u_dofDepth_texture.read(uint2(min(lo + int2(x, y), size - 1))).r;
            float c = postCoc(z, u_dof);
            range = float3(z > u_dof.y ? max(range.x, c) : range.x, min(range.y, c), z > u_dof.y ? range.z : max(range.z, c));
          }
        }

        o_dofTile8_texture = float4(range, 0.0);
      }
      """#
  }
}
