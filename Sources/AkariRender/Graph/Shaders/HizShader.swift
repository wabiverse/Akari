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
  /// drawn by the hiz pass, every level in one go, each texel the closest depth under it for the reflection trace
  struct HizShader: FullscreenShader
  {
    let name = "hiz"

    var uniforms: [Declaration]
    {
      Sampler(SsgiPrepBuffer.ssgiDepth)
    }

    var fragmentGLSL: String
    {
      #"""
      \#(ShaderLibrary.hizAtlasGLSL)

      void main()
      {
        ivec2 q = ivec2(gl_FragCoord.xy);
        ivec2 atlas = textureSize(u_ssgiDepth_texture, 0);
        int level = 0;
        ivec2 p = q;
        if (q.x < (atlas.x >> 1)) {
          if (q.y < (atlas.y >> 1)) level = 1;
        } else {
          for (int l = 2; l <= hizLevels; ++l) {
            ivec2 size = atlas >> l;
            ivec2 off = hizLevelOffset(l, atlas);
            if (all(greaterThanEqual(q, off)) && all(lessThan(q, off + size))) {
              level = l;
              p = q - off;
            }
          }
        }

        // a cell the atlas has no level for holds nothing, which the trace reads as empty
        float closest = 1e30;
        int span = level == 0 ? 0 : 1 << level;
        ivec2 base = p * span;
        ivec2 last = atlas - 1;
        for (int y = 0; y < span; ++y) {
          for (int x = 0; x < span; ++x) {
            float z = texelFetch(u_ssgiDepth_texture, min(base + ivec2(x, y), last), 0).x;
            closest = min(closest, z == 0.0 ? 1e30 : -z);
          }
        }
        o_hiz_texture = vec4(closest, 0.0, 0.0, 0.0);
      }
      """#
    }

    var fragmentMSL: String
    {
      #"""
      \#(ShaderLibrary.hizAtlasMSL)

      //@main
      {
        int2 q = int2(gl_FragCoord.xy);
        int2 atlas = int2(u_ssgiDepth_texture.get_width(), u_ssgiDepth_texture.get_height());
        int level = 0;
        int2 p = q;
        if (q.x < (atlas.x >> 1)) {
          if (q.y < (atlas.y >> 1)) level = 1;
        } else {
          for (int l = 2; l <= hizLevels; ++l) {
            int2 size = atlas >> l;
            int2 off = hizLevelOffset(l, atlas);
            if (all(q >= off) && all(q < off + size)) {
              level = l;
              p = q - off;
            }
          }
        }

        // a cell the atlas has no level for holds nothing, which the trace reads as empty
        float closest = 1e30;
        int span = level == 0 ? 0 : 1 << level;
        int2 base = p * span;
        int2 last = atlas - 1;
        for (int y = 0; y < span; ++y) {
          for (int x = 0; x < span; ++x) {
            float z = u_ssgiDepth_texture.read(uint2(min(base + int2(x, y), last))).x;
            closest = min(closest, z == 0.0 ? 1e30 : -z);
          }
        }
        o_hiz_texture = float4(closest, 0.0, 0.0, 0.0);
      }
      """#
    }
  }
}
