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

extension Akari.RenderGraph.ShaderLibrary
{
  static let styleMSL = #"""
    /// a prim's shading style, eight texels per prim and 512 prims a row, with the single sided flag in the x of texel 5
    float4 styleTexel(texture2d<float> styles, float primId, int k)
    {
      int id = int(primId + 0.5);
      int perRow = int(styles.get_width()) / 8;
      int row = id / max(perRow, 1);

      if (id < 0 || perRow < 1 || row >= int(styles.get_height())) {
        return k == 0 ? float4(5.0, 1.0, 0.0, 0.04) : k == 1 ? float4(0.0, 0.0, 0.0, -1.0) : float4(0.0);
      }
      return styles.read(uint2((id % perRow) * 8 + k, row));
    }

    /// how far `p` is inside the front sphere, 1 everywhere when there is no sphere
    float styleInside(float4 front, float band, float3 p)
    {
      if (front.w < 0.0) return 1.0;
      return 1.0 - smoothstep(front.w - max(band, 1e-4), front.w, distance(p, front.xyz));
    }

    /// the shading model at `p`
    float styleShadingModel(float4 s0, float4 front, float3 p)
    {
      return mix(max(s0.x - 1.0, 0.0), s0.x, styleInside(front, s0.w, p));
    }
    """#
}
