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
  /// blurs the sun shadow along one axis by each pixel's soft edge width.
  struct SunShadowBlurShader: FullscreenShader
  {
    let axis: BlurAxis

    var name: String { "sun-shadow-blur-\(axis.suffix)" }

    /// the accumulated shadow for the horizontal pass, the horizontal blur for the vertical one.
    var source: TextureRef { axis == .horizontal ? SunShadowAccumBuffer.sunShadowAccum.ref : SunShadowBlurBuffer.sunShadowBlurH.ref }

    var target: TextureRef { axis == .horizontal ? SunShadowBlurBuffer.sunShadowBlurH.ref : SunShadowSoftBuffer.sunShadowSoft.ref }

    /// the channel holding the soft edge width, which the horizontal pass hands on in green.
    var edge: String { axis == .horizontal ? "b" : "g" }

    var uniforms: [Declaration]
    {
      Sampler(source)
      Sampler(GBuffer.position)
      Sampler(GBuffer.normal)
    }

    /// the vertical pass writes the finished shadow, the horizontal one keeps the edge width for it.
    func result(_ vector: String) -> String
    {
      axis == .horizontal ? "\(vector)(sum / wsum, center.b, 0.0, 0.0)" : "\(vector)(sum / wsum)"
    }

    var fragmentGLSL: String
    {
      #"""
      // blurs the sun shadow along one axis by each pixel's soft edge width, stopping at depth and normal edges.
      void main()
      {
        ivec2 size = textureSize(\#(source.sampler), 0);
        ivec2 c = ivec2(gl_FragCoord.xy);
        vec4 center = texelFetch(\#(source.sampler), c, 0);
        vec4 nc = texelFetch(u_normal_texture, c, 0);
        float zc = texelFetch(u_position_texture, c, 0).z;
        float reach = 0.0;
        for (int k = -4; k <= 4; ++k) reach = max(reach, texelFetch(\#(source.sampler), clamp(c + ivec2(\#(axis.step)) * k * 8, ivec2(0), size - 1), 0).\#(edge));
        float sum = center.r, wsum = 1.0;
        if (nc.a >= 0.5 && reach > 0.75) {
          float step = max(reach / 12.0, 1.0);
          for (int k = -12; k <= 12; ++k) {
            if (k == 0) continue;
            float x = float(k) * step;
            ivec2 p = clamp(c + ivec2(\#(axis.step)) * int(round(x)), ivec2(0), size - 1);
            vec4 s = texelFetch(\#(source.sampler), p, 0);

            // neighboring shadowed pixels use the narrower edge so wide penumbras don't smear contact shadows.
            float r = center.\#(edge) > 0.0 && s.\#(edge) > 0.0 ? min(center.\#(edge), s.\#(edge)) : max(center.\#(edge), s.\#(edge));
            if (abs(x) > r) continue;
            vec4 n = texelFetch(u_normal_texture, p, 0);
            if (n.a < 0.5) continue;
            float zs = texelFetch(u_position_texture, p, 0).z;
            float w = (1.0 - abs(x) / (r + 1.0))
                    * exp(-abs(zs - zc) / max(0.03 * abs(zc), 1e-3))
                    * pow(max(dot(n.xyz, nc.xyz), 0.0), 4.0);
            sum += s.r * w;
            wsum += w;
          }
        }
        \#(target.output) = \#(result("vec4"));
      }
      """#
    }

    var fragmentMSL: String
    {
      #"""
      //@main
      {
        int2 size = int2(\#(source.sampler).get_width(), \#(source.sampler).get_height());
        int2 c = int2(gl_FragCoord.xy);
        float4 center = \#(source.sampler).read(uint2(c));
        float4 nc = u_normal_texture.read(uint2(c));
        float zc = u_position_texture.read(uint2(c)).z;
        float reach = 0.0;
        for (int k = -4; k <= 4; ++k) reach = max(reach, \#(source.sampler).read(uint2(clamp(c + int2(\#(axis.step)) * k * 8, int2(0), size - 1))).\#(edge));
        float sum = center.r, wsum = 1.0;
        if (nc.a >= 0.5 && reach > 0.75) {
          float step = max(reach / 12.0, 1.0);
          for (int k = -12; k <= 12; ++k) {
            if (k == 0) continue;
            float x = float(k) * step;
            int2 p = clamp(c + int2(\#(axis.step)) * int(round(x)), int2(0), size - 1);
            float4 s = \#(source.sampler).read(uint2(p));

            // neighboring shadowed pixels use the narrower edge so wide penumbras don't smear contact shadows.
            float r = center.\#(edge) > 0.0 && s.\#(edge) > 0.0 ? min(center.\#(edge), s.\#(edge)) : max(center.\#(edge), s.\#(edge));
            if (abs(x) > r) continue;
            float4 n = u_normal_texture.read(uint2(p));
            if (n.a < 0.5) continue;
            float zs = u_position_texture.read(uint2(p)).z;
            float w = (1.0 - abs(x) / (r + 1.0))
                    * exp(-abs(zs - zc) / max(0.03 * abs(zc), 1e-3))
                    * pow(max(dot(n.xyz, nc.xyz), 0.0), 4.0);
            sum += s.r * w;
            wsum += w;
          }
        }
        \#(target.output) = \#(result("float4"));
      }
      """#
    }
  }
}
