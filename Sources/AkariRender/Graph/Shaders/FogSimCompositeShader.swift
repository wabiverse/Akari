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
  /// drawn by the `fog sim composite` pass.
  struct FogSimCompositeShader: FullscreenShader
  {
    let name = "fog-sim-composite"

    var uniforms: [Declaration]
    {
      Sampler(GBuffer.position)
      Sampler(GBuffer.normal)
      Sampler(FogSimHalfBuffer.fogSimHalf)
      Uniforms.fogSimMin
    }

    let fragmentGLSL = ShaderLibrary.metalOnly

    let fragmentMSL = #"""
      float fogSimViewDepth(texture2d<float> position, texture2d<float> normal, uint2 px)
      {
        return normal.read(px).a >= 0.5 ? length(position.read(px).xyz) : 1e30;
      }

      //@main
      {
        if (u_fogSimMin.w < 0.5) discard_fragment();

        uint2 gsize = uint2(u_position_texture.get_width(), u_position_texture.get_height());
        uint2 hsize = uint2(u_fogSimHalf_texture.get_width(), u_fogSimHalf_texture.get_height());
        uint2 px = uint2(gl_FragCoord.xy);
        float z = fogSimViewDepth(u_position_texture, u_normal_texture, px);

        // weigh the four half resolution texels by how close their depth is to this pixel's.
        float2 h = float2(px) * 0.5;
        uint2 h0 = uint2(floor(h));
        float2 f = h - floor(h);

        float4 sum = float4(0.0);
        float weight = 0.0;
        float4 nearest = float4(0.0);
        float closest = 1e30;
        for (uint k = 0; k < 4; ++k) {
          uint2 o = uint2(k & 1, k >> 1);
          uint2 hp = min(h0 + o, hsize - 1);
          float zs = fogSimViewDepth(u_position_texture, u_normal_texture, min(hp * 2, gsize - 1));
          float4 c = u_fogSimHalf_texture.read(hp);
          float rel = abs(zs - z) / max(min(zs, z), 1e-3);
          float w = (o.x ? f.x : 1.0 - f.x) * (o.y ? f.y : 1.0 - f.y) / (1e-3 + rel * rel * 400.0);
          sum += c * w;
          weight += w;
          if (rel < closest) { closest = rel; nearest = c; }
        }

        float4 c = weight > 1e-2 ? sum / weight : nearest;
        if (c.a < 1e-3) discard_fragment();
        o_final_texture = float4(c.rgb / c.a, c.a);
      }
      """#
  }
}
