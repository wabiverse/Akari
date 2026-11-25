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
  static let fogMSL = #"""
    float fogHash(float3 p)
    {
      p = fract(p * 0.3183099 + 0.1);
      p *= 17.0;
      return fract(p.x * p.y * p.z * (p.x + p.y + p.z));
    }

    float fogNoise(float3 x)
    {
      float3 i = floor(x), f = x - i;
      f = f * f * (3.0 - 2.0 * f);
      return mix(mix(mix(fogHash(i), fogHash(i + float3(1, 0, 0)), f.x),
                     mix(fogHash(i + float3(0, 1, 0)), fogHash(i + float3(1, 1, 0)), f.x), f.y),
                 mix(mix(fogHash(i + float3(0, 0, 1)), fogHash(i + float3(1, 0, 1)), f.x),
                     mix(fogHash(i + float3(0, 1, 1)), fogHash(i + float3(1, 1, 1)), f.x), f.y), f.z);
    }

    float fogFbm(float3 p, int octaves)
    {
      float sum = 0.0, amplitude = 0.5, norm = 0.0;
      for (int i = 0; i < octaves; ++i) {
        sum += fogNoise(p) * amplitude;
        norm += amplitude;
        amplitude *= 0.5;
        p = float3x3(float3(0.0, 0.8, 0.6), float3(-0.8, 0.36, -0.48), float3(-0.6, -0.48, 0.64)) * p * 2.03;
      }
      return sum / norm;
    }

    /// the fog's density at `world`, an even haze and a floor layer broken into wind blown wisps, parted and dragged by the disturbers
    float fogDensity(float3 world, float base, float4 noise, float4 flow, float4 layer, float zUp, texture2d<float> disturbers,
                     texture3d<float> sim, sampler simSmp, float4 simMin, float4 simMax)
    {
      if (simMin.w > 0.5) {
        float3 uvw = (world - simMin.xyz) / max(simMax.xyz - simMin.xyz, float3(1e-4));
        if (zUp < 0.5) uvw = uvw.xzy;
        if (all(uvw >= 0.0) && all(uvw <= 1.0)) {
          // the simulated fog is drawn per pixel by its own march, here only the haze is left.
          return layer.z;
        }
      }

      float3 up = zUp > 0.5 ? float3(0.0, 0.0, 1.0) : float3(0.0, 1.0, 0.0);
      float height = dot(world, up) - layer.x;
      float profile = layer.y > 0.0 ? exp(-max(height, 0.0) / layer.y) : 1.0;

      float keep = 1.0;
      float3 drag = float3(0.0);
      int count = int(layer.w);
      for (int i = 0; i < count; ++i) {
        float4 pr = disturbers.read(uint2(0, i));
        float3 v = disturbers.read(uint2(1, i)).xyz;
        float3 d = world - pr.xyz;
        float dist = length(d);
        float r = max(pr.w, 1e-3);

        keep *= mix(1.0, smoothstep(0.35 * r, 1.1 * r, dist), saturate(0.4 + length(v) * 0.5));
        float speed = length(v);
        if (speed > 1e-3) {
          float3 dir = v / speed;
          float behind = saturate(-dot(d, dir) / (3.0 * r) + 0.4);
          float wake = exp(-dot(d, d) / (4.0 * r * r)) * behind;

          // the fog is dragged along and rolled about the axis across the motion, curling behind it.
          float3 axis = normalize(cross(dir, up) + float3(1e-5, 0.0, 0.0));
          drag += (v * 0.25 + cross(axis, d) * (speed * 0.6 / r)) * wake * 0.5;
        }
      }

      float density = base * profile;
      if (noise.x > 0.0 && density > 0.0) {
        float t = flow.w;

        float3 q = (world - drag - flow.xyz * t) / max(noise.y, 1e-4);
        float churn = 0.6 + 1.6 * noise.w;
        float3 slow = q * 0.45 + float3(0.0, 0.0, t * (0.05 + 0.25 * noise.w));
        float3 warp = float3(fogFbm(slow, 3), fogFbm(slow + float3(5.2, 1.3, 7.1), 3), fogFbm(slow + float3(2.8, 9.4, 3.3), 3)) * 2.0 - 1.0;
        q += warp * churn;

        // ridged so the fog gathers into rolling sheets and tendrils with clear air between, along fbm's middle isosurface
        float n = fogFbm(q, int(noise.z));
        float sheet = saturate(1.0 - abs(n - 0.5) * 10.0);
        float wisps = sheet * sheet * 3.2 + smoothstep(0.56, 0.68, n) * 1.2;
        density *= mix(1.0, wisps, noise.x);
      }

      return (density + layer.z) * keep;
    }
    """#
}
