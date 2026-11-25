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
  /// a sphere probe's radiance along a world direction, read from its octahedral tile in the sphere atlas
  static let probeSphereMSL = #"""
    static float2 probeOctEncode(float3 d)
    {
      d /= abs(d.x) + abs(d.y) + abs(d.z);
      float2 p = d.xy;
      if (d.z < 0.0) p = (1.0 - abs(d.yx)) * select(float2(-1.0), float2(1.0), d.xy >= 0.0);
      return p * 0.5 + 0.5;
    }

    static float3 probeSphereMip(texture2d<float> atlas, sampler smp, int sphere, int mip, float3 d)
    {
      float res = float(128 >> mip);
      float2 tile = float2(float((sphere % 4) * 196), float((sphere / 4) * 130));
      float2 offset = mip == 0 ? float2(0.0)
                    : float2(130.0, mip == 1 ? 0.0 : mip == 2 ? 66.0 : mip == 3 ? 100.0 : 118.0);
      float2 texel = tile + offset + probeOctEncode(d) * res + 1.0;
      return atlas.sample(smp, texel / float2(atlas.get_width(), atlas.get_height()), level(0.0)).rgb;
    }
    """#

  /// the irradiance volume's light at a point and normal, blended toward a fallback where the point leaves the volume
  static let probeVolumeMSL = #"""
    float3 probeVolumeIrradiance(float3 worldPos, float3 N, float3 fallback,
                                 texture2d<float> sh, constant Uniforms& u)
    {
      if (u.u_probeGridMin.w < 0.5) return fallback;
      int3 dims = int3(u.u_probeGridSize.xyz);
      float3 cell = (u.u_probeGridMax.xyz - u.u_probeGridMin.xyz) / float3(max(dims - 1, int3(1)));
      float3 g = (worldPos + N * u.u_probeGridSize.w - u.u_probeGridMin.xyz) / cell;
      float3 outside = max(max(-g, g - float3(dims - 1)), float3(0.0));
      float fade = saturate(1.0 - max(outside.x, max(outside.y, outside.z)));
      if (fade <= 0.0) return fallback;
      g = clamp(g, float3(0.0), float3(dims - 1));
      int3 base = min(int3(floor(g)), max(dims - 2, int3(0)));
      float3 f = g - float3(base);
      float3 l0 = float3(0.0), lx = float3(0.0), ly = float3(0.0), lz = float3(0.0);
      float weight = 0.0;
      for (int i = 0; i < 8; ++i) {
        int3 o = int3(i & 1, (i >> 1) & 1, i >> 2);
        int3 c = min(base + o, dims - 1);
        float3 w3 = mix(1.0 - f, f, float3(o));
        int index = c.x + dims.x * (c.y + dims.y * c.z);
        uint2 t = uint2((index % 256) * 4, index / 256);
        float4 c0 = sh.read(t);
        float3 toProbe = u.u_probeGridMin.xyz + float3(c) * cell - worldPos;
        float facing = dot(toProbe, N) * rsqrt(max(dot(toProbe, toProbe), 1e-12)) * 0.5 + 0.5;
        float trilinear = w3.x * w3.y * w3.z;

        // buried probes carry their neighbors' light, so they blend in at a quarter weight rather than snapping at cell edges
        float w = trilinear * (facing * facing + 0.05) * (0.25 + 0.75 * c0.a);
        l0 += c0.rgb * w;
        lx += sh.read(t + uint2(1, 0)).rgb * w;
        ly += sh.read(t + uint2(2, 0)).rgb * w;
        lz += sh.read(t + uint2(3, 0)).rgb * w;
        weight += w;
      }
      float3 irradiance = max((0.282095 * l0 + 0.325735 * (lx * N.x + ly * N.y + lz * N.z)) / max(weight, 1e-8), float3(0.0));
      return mix(fallback, irradiance, fade);
    }
    """#
}
