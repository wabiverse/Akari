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
  /// drawn by the `motion tiles pre 8` and `motion tiles 8` passes
  struct MotionTile8Shader: FullscreenShader
  {
    let name = "motion-tile-8"

    var uniforms: [Declaration]
    {
      Sampler(TransparentAccumBuffer.tVelocity)
      Sampler(GBuffer.velocity)
      Sampler(GBuffer.normal)
      Uniforms.view
      Uniforms.invProj
      Uniforms.prevViewProj
      Uniforms.currViewProj
      Uniforms.motionBlur
      Uniforms.motionSize
    }

    let fragmentGLSL = #"""
      void main()
      {
        ivec2 gsize = textureSize(u_velocity_texture, 0);
        vec2 gscale = vec2(gsize) * u_motionSize.zw;
        ivec2 lo = ivec2(floor(floor(gl_FragCoord.xy) * 8.0 * gscale));
        ivec2 hi = min(ivec2(ceil((floor(gl_FragCoord.xy) + 1.0) * 8.0 * gscale)), gsize);
        vec2 best = vec2(0.0);
        for (int y = lo.y; y < hi.y; ++y)
          for (int x = lo.x; x < hi.x; ++x) {
            vec2 v = motionPixels(ivec2(x, y), u_velocity_texture, u_normal_texture, u_view, u_invProj,
                                  u_prevViewProj, u_currViewProj, u_motionBlur, u_motionSize.xy);
            if (dot(v, v) > dot(best, best)) best = v;
          }
        o_motionTile8_texture = vec4(best, length(best), 0.0);
      }
      """#

    let fragmentMSL = #"""
      \#(ShaderLibrary.motionBlurMSL)

      //@main
      {
        int2 gsize = int2(u_velocity_texture.get_width(), u_velocity_texture.get_height());
        float2 gscale = float2(gsize) * u_motionSize.zw;
        int2 lo = int2(floor(floor(gl_FragCoord.xy) * 8.0 * gscale));
        int2 hi = min(int2(ceil((floor(gl_FragCoord.xy) + 1.0) * 8.0 * gscale)), gsize);
        float2 best = float2(0.0);
        for (int y = lo.y; y < hi.y; ++y) {
          for (int x = lo.x; x < hi.x; ++x) {
            float2 v = motionPixels(int2(x, y), u_velocity_texture, u_normal_texture, u_tVelocity_texture, u_view, u_invProj,
                                    u_prevViewProj, u_currViewProj, u_motionBlur, u_motionSize.xy);
            if (dot(v, v) > dot(best, best)) best = v;
          }
        }
        o_motionTile8_texture = float4(best, length(best), 0.0);
      }
      """#
  }
}
