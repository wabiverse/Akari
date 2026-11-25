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
  /// a glass surface's tint and opacity, read the way the transparent pass reads them.
  static let glassSurfaceMSL = #"""
    // the tint in rgb and opacity in a, negative where the surface isn't glass, is cut out or is opaque enough for the deferred passes
    float4 glassSurface(float2 uv, float4 vcolor, texture2d<float> materialAtlas, sampler materialSampler,
                        texture2d<float> colorAtlas, sampler colorSampler, texture2d<float> constants)
    {
      float4 mat = materialAtlas.sample(materialSampler, uv);
      float3 albedo = colorAtlas.sample(colorSampler, uv).rgb;

      int row = int(-uv.x + 0.5) - 1;
      if (row >= 0) {
        // 128 material rows share a scanline, see `MaterialAtlas.constantsRowsPerLine`.
        uint line = uint(row) >> 7u;
        uint base = uint(row & 127) * 4u;
        float4 c0 = constants.read(uint2(base, line));
        float4 c1 = constants.read(uint2(base + 1u, line));
        mat = float4(c1.r, c1.g, c0.a, c1.b);
        albedo = c0.rgb;
      }

      if (vcolor.w > 0.5) albedo *= vcolor.rgb;
      return float4(albedo, mat.a > 0.0 || mat.b >= 0.98 ? -1.0 : saturate(mat.b));
    }
    """#

  /// how much of a glass light's direct light reaches a point, read from the light's tile of the glass atlas.
  static var glassLightMSL: String
  {
    typealias Atlas = Akari.RenderGraph.GlassAtlas
    return #"""
      // what the glass blocks of a light's direct light, the caustic splats add the refracted share back
      float glassBlocks(float4 nearSample, float4 nearNormalSample, float distance)
      {
        return nearNormalSample.w > 0.5 && distance - nearSample.w > 1e-3 * max(abs(distance), 1.0) ? 1.0 : 0.0;
      }

      // `behind` is how far past the glass the point lies, 0 where no glass is in the way.
      float glassVisible(float3 worldPos, int tile, texture2d<float> lights,
                         texture2d<float> nearMap, texture2d<float> nearNormal, float noise, thread float& behind)
      {
        behind = 0.0;
        float4 settings = lights.read(uint2(4, tile));
        if (settings.x < 0.5) return 1.0;

        float4x4 toClip = float4x4(lights.read(uint2(0, tile)), lights.read(uint2(1, tile)),
                                   lights.read(uint2(2, tile)), lights.read(uint2(3, tile)));
        float4 light = lights.read(uint2(5, tile));
        float4 clip = toClip * float4(worldPos, 1.0);
        if (clip.w <= 1e-6 || any(abs(clip.xy / clip.w) >= float2(1.0))) return 1.0;

        // the tile's lower left texel and its size.
        float size = \#(Atlas.tile).0;
        float2 origin = float2(float(tile % \#(Atlas.columns)), float(tile / \#(Atlas.columns))) * size;
        float2 uv = clip.xy / clip.w * 0.5 + 0.5;
        float distance = light.w > 0.5 ? length(worldPos - light.xyz) : -dot(worldPos, light.xyz);
        uint2 center = uint2(origin + min(uv * size, size - 1.0));
        float4 nearest = nearMap.read(center);

        // a light with size softens what the glass blocks more the further behind it, like opaque shadows soften
        behind = nearNormal.read(center).w > 0.5 ? max(distance - nearest.w, 0.0) : 0.0;
        float soft = light.w > 0.5 ? behind * settings.y / max(distance - behind, 1e-3) : behind * settings.y;
        float ndcPerUnit = length(float3(toClip[0][0], toClip[1][0], toClip[2][0])) / clip.w;
        float texels = clamp(soft * ndcPerUnit * 0.5 * size, 1.0, 12.0);

        // a golden angle spiral inside the light's tile, turned by noise each frame so the temporal resolve smooths the edge
        float turn = 6.2831853 * noise;
        float blocked = 0.0;
        for (int i = 0; i < 12; ++i) {
          float r = sqrt((float(i) + 0.5) / 12.0) * texels;
          float a = float(i) * 2.3999632 + turn;
          uint2 t = uint2(origin + clamp(uv * size + float2(cos(a), sin(a)) * r, float2(0.0), float2(size - 1.0)));
          blocked += glassBlocks(nearMap.read(t), nearNormal.read(t), distance);
        }

        return 1.0 - blocked / 12.0;
      }
      """#
  }
}
