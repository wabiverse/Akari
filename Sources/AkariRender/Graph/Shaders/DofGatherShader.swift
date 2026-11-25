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
  /// drawn by the `depth of field` pass.
  struct DofGatherShader: FullscreenShader
  {
    let name = "dof-gather"

    var uniforms: [Declaration]
    {
      Sampler(TaaBuffer.`final`)
      Sampler(DofDepthBuffer.dofDepth)
      Sampler(DofNeighborsBuffer.dofNeighborMax)
      Sampler(DofHalfBuffer.dofHalfColor)
      Sampler(DofHalfSourceBuffer.dofHalfSource)
      Uniforms.dof
    }

    let fragmentGLSL = #"""
      void main()
      {
        o_dofColor_texture = texelFetch(u_final_texture, ivec2(gl_FragCoord.xy), 0);
      }
      """#

    let fragmentMSL = #"""
      \#(ShaderLibrary.postMSL)

      //@main
      {
        float2 pixel = floor(gl_FragCoord.xy);
        float near = u_dofNeighborMax_texture.read(uint2(pixel / 48.0)).b;
        float z = u_dofDepth_texture.read(uint2(pixel)).r;

        // blurred pixels take the half resolution gather and in focus ones their own, crossfading between.
        float w = smoothstep(4.0, 8.0, postCoc(z, u_dof));
        float3 c = float3(0.0);
        if (w < 1.0) {
          c = postBokehSplit(u_final_texture, u_final_texture_smp, u_dofDepth_texture, u_dofHalfSource_texture, pixel + 0.5, u_dof, near, 1.5, 8.0);
        }
        if (w > 0.0) {
          c = mix(c, postUpsampleDepthAware(u_dofHalfColor_texture, u_dofDepth_texture, pixel, z), w);
        }

        o_dofColor_texture = float4(c, 1.0);
      }
      """#
  }
}
