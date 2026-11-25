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
  /// blurs the four point light shadow layers along one axis, guided by depth
  struct PointShadowBlurShader: FullscreenShader
  {
    let axis: BlurAxis

    var name: String { "point-shadow-blur-\(axis.suffix)" }

    /// raw shadows feed the horizontal pass and the horizontal blur feeds the vertical one
    var layers: [TextureRef]
    {
      switch axis
      {
        case .horizontal: [PointShadowRawBuffer.pointShadowRaw0, .pointShadowRaw1, .pointShadowRaw2, .pointShadowRaw3].map(\.ref)
        case .vertical: PointShadowBlurBuffer.allCases.map(\.ref)
      }
    }

    var targets: [TextureRef]
    {
      switch axis
      {
        case .horizontal: PointShadowBlurBuffer.allCases.map(\.ref)
        case .vertical: PointShadowBuffer.allCases.map(\.ref)
      }
    }

    var uniforms: [Declaration]
    {
      for layer in layers { Sampler(layer) }
      Sampler(PointShadowRawBuffer.pointShadowGuide)
    }

    var fragmentGLSL: String
    {
      #"""
      void main()
      {
        ivec2 size = textureSize(u_pointShadowGuide_texture, 0);
        ivec2 c = ivec2(gl_FragCoord.xy);
        vec4 gc = texelFetch(u_pointShadowGuide_texture, c, 0);
        vec4 s0 = vec4(0.0), s1 = vec4(0.0), s2 = vec4(0.0), s3 = vec4(0.0);
        float wsum = 0.0;

        for (int k = -2; k <= 2; ++k) {
          ivec2 p = clamp(c + ivec2(\#(axis.step)) * k, ivec2(0), size - 1);
          vec4 g = texelFetch(u_pointShadowGuide_texture, p, 0);
          float w = exp(-float(k * k) / 4.5)
                  * exp(-abs(g.w - gc.w) / max(0.02 * abs(gc.w), 1e-3))
                  * pow(max(dot(g.xyz, gc.xyz), 0.0), 8.0) + (k == 0 ? 1e-4 : 0.0);
          if (!(w > 0.0)) w = k == 0 ? 1.0 : 0.0;

          s0 += texelFetch(\#(layers[0].sampler), p, 0) * w;
          s1 += texelFetch(\#(layers[1].sampler), p, 0) * w;
          s2 += texelFetch(\#(layers[2].sampler), p, 0) * w;
          s3 += texelFetch(\#(layers[3].sampler), p, 0) * w;
          wsum += w;
        }

        \#(targets[0].output) = s0 / wsum;
        \#(targets[1].output) = s1 / wsum;
        \#(targets[2].output) = s2 / wsum;
        \#(targets[3].output) = s3 / wsum;
      }
      """#
    }

    var fragmentMSL: String
    {
      #"""
      //@main
      {
        int2 size = int2(u_pointShadowGuide_texture.get_width(), u_pointShadowGuide_texture.get_height());
        int2 c = int2(gl_FragCoord.xy);
        float4 gc = u_pointShadowGuide_texture.read(uint2(c));
        float4 s0 = float4(0.0), s1 = float4(0.0), s2 = float4(0.0), s3 = float4(0.0);
        float wsum = 0.0;

        for (int k = -2; k <= 2; ++k) {
          int2 p = clamp(c + int2(\#(axis.step)) * k, int2(0), size - 1);
          float4 g = u_pointShadowGuide_texture.read(uint2(p));
          float w = exp(-float(k * k) / 4.5)
                  * exp(-abs(g.w - gc.w) / max(0.02 * abs(gc.w), 1e-3))
                  * pow(max(dot(g.xyz, gc.xyz), 0.0), 8.0) + (k == 0 ? 1e-4 : 0.0);
          if (!(w > 0.0)) w = k == 0 ? 1.0 : 0.0;

          s0 += \#(layers[0].sampler).read(uint2(p)) * w;
          s1 += \#(layers[1].sampler).read(uint2(p)) * w;
          s2 += \#(layers[2].sampler).read(uint2(p)) * w;
          s3 += \#(layers[3].sampler).read(uint2(p)) * w;
          wsum += w;
        }

        \#(targets[0].output) = s0 / wsum;
        \#(targets[1].output) = s1 / wsum;
        \#(targets[2].output) = s2 / wsum;
        \#(targets[3].output) = s3 / wsum;
      }
      """#
    }
  }
}
