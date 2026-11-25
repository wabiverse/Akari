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
  /// where each level of the hiz atlas sits, the first level on the left half and coarser ones stacked down the right
  static let hizAtlasMSL = #"""
    constexpr constant int hizLevels = 5;

    int2 hizLevelSize(int level, int2 atlas)
    {
      return max(atlas >> level, int2(1));
    }

    int2 hizLevelOffset(int level, int2 atlas)
    {
      return level < 2 ? int2(0) : int2(atlas.x >> 1, (atlas.y >> 1) - (atlas.y >> (level - 1)));
    }

    /// the coarsest level this atlas has room for
    int hizTopLevel(int2 atlas)
    {
      int top = hizLevels;
      while (top > 1 && min(atlas.x >> top, atlas.y >> top) < 1) top -= 1;
      return top;
    }

    /// the closest eye distance under one cell, the half resolution depth itself at level zero
    float hizClosest(int level, int2 cell, int2 atlas, texture2d<float> hiz, texture2d<float> depth)
    {
      if (level < 1) {
        float z = depth.read(uint2(clamp(cell, int2(0), atlas - 1))).x;
        return z == 0.0 ? 1e30 : -z;
      }
      int2 size = hizLevelSize(level, atlas);
      return hiz.read(uint2(hizLevelOffset(level, atlas) + clamp(cell, int2(0), size - 1))).x;
    }

    /// how far along the ray the cell it stands in at t ends, in the same parameter the ray is walked by
    float hizCellExit(float2 s0, float2 d, float t, float2 size, float tMax)
    {
      float2 p = (s0 + d * t) * size;
      float2 v = d * size;
      float2 bound = floor(p) + step(float2(0.0), v);
      float2 dt = (bound - p) / v;
      float ahead = min(abs(v.x) > 1e-7 ? dt.x : 1e30, abs(v.y) > 1e-7 ? dt.y : 1e30);

      // a nudge past the edge, a thousandth of a cell, so the step after this one reads the cell on the other side
      return min(t + max(ahead, 0.0) + 1e-3 / max(length(v), 1e-6), tMax);
    }
    """#

  static let hizAtlasGLSL = #"""
    const int hizLevels = 5;

    ivec2 hizLevelSize(int level, ivec2 atlas)
    {
      return max(atlas >> level, ivec2(1));
    }

    ivec2 hizLevelOffset(int level, ivec2 atlas)
    {
      return level < 2 ? ivec2(0) : ivec2(atlas.x >> 1, (atlas.y >> 1) - (atlas.y >> (level - 1)));
    }

    int hizTopLevel(ivec2 atlas)
    {
      int top = hizLevels;
      while (top > 1 && min(atlas.x >> top, atlas.y >> top) < 1) top -= 1;
      return top;
    }

    float hizCellExit(vec2 s0, vec2 d, float t, vec2 size, float tMax)
    {
      vec2 p = (s0 + d * t) * size;
      vec2 v = d * size;
      vec2 bound = floor(p) + step(vec2(0.0), v);
      vec2 dt = (bound - p) / v;
      float ahead = min(abs(v.x) > 1e-7 ? dt.x : 1e30, abs(v.y) > 1e-7 ? dt.y : 1e30);

      // a nudge past the edge, a thousandth of a cell, so the step after this one reads the cell on the other side
      return min(t + max(ahead, 0.0) + 1e-3 / max(length(v), 1e-6), tMax);
    }
    """#
}
