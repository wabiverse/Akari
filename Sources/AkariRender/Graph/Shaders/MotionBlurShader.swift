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
  /// drawn by the `motion blur pre` and `motion blur` passes
  struct MotionBlurShader: FullscreenShader
  {
    let name = "motion-blur"

    var uniforms: [Declaration]
    {
      Sampler(TransparentAccumBuffer.tVelocity)
      Sampler(TaaBuffer.`final`)
      Sampler(GBuffer.velocity)
      Sampler(GBuffer.normal)
      Sampler(GBuffer.position)
      Sampler(MotionNeighborsBuffer.motionNeighborMax)
      Uniforms.view
      Uniforms.invProj
      Uniforms.prevViewProj
      Uniforms.currViewProj
      Uniforms.motionBlur
      Uniforms.motionSize
      Uniforms.frameIndex
    }

    let fragmentGLSL = #"""
      void main()
      {
        vec2 tile = floor(gl_FragCoord.xy * u_motionSize.zw * u_motionBlur.zw);
        vec2 vn = texelFetch(u_motionNeighborMax_texture, ivec2(tile), 0).xy;
        float noise = fract(52.9829189 * fract(dot(gl_FragCoord.xy + 5.588238 * float(frameIndex % 64), vec2(0.06711056, 0.00583715))));
        o_motionBlurred_texture = vec4(motionReconstruct(floor(gl_FragCoord.xy), vn, noise, u_final_texture, u_velocity_texture,
                                                         u_normal_texture, u_position_texture, u_view, u_invProj,
                                                         u_prevViewProj, u_currViewProj, u_motionBlur, u_motionSize.xy), 1.0);
      }
      """#

    let fragmentMSL = #"""
      \#(ShaderLibrary.motionBlurMSL)

      //@main
      {
        float2 tile = floor(gl_FragCoord.xy * u_motionSize.zw * u_motionBlur.zw);
        float2 vn = u_motionNeighborMax_texture.read(uint2(tile)).xy;
        float noise = fract(52.9829189 * fract(dot(gl_FragCoord.xy + 5.588238 * float(frameIndex % 64), float2(0.06711056, 0.00583715))));
        o_motionBlurred_texture = float4(motionReconstruct(floor(gl_FragCoord.xy), vn, noise, u_final_texture, u_final_texture_smp,
                                                           u_velocity_texture, u_normal_texture, u_position_texture, u_tVelocity_texture, u_view, u_invProj,
                                                           u_prevViewProj, u_currViewProj, u_motionBlur, u_motionSize.xy), 1.0);
      }
      """#
  }
}
