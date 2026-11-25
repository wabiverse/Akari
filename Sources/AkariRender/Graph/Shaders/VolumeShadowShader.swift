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
  /// drawn by the `volume shadow` pass.
  struct VolumeShadowShader: FullscreenShader
  {
    let name = "volume-shadow"

    var uniforms: [Declaration]
    {
      Samplers.volumeDensity
      Uniforms.volumeWorldFromTexture
      Uniforms.volumeTextureFromWorld
      Uniforms.volumeParams
      Uniforms.volumeSun
      Uniforms.zUp
    }

    let fragmentGLSL = #"""
      void main()
      {
        ivec2 px = ivec2(gl_FragCoord.xy);
        int slice = (px.y / 128) * 16 + px.x / 128;
        vec3 uvw = (vec3(vec2(px % 128), float(slice)) + 0.5) / 128.0;
        vec3 world = (u_volumeWorldFromTexture * vec4(uvw, 1.0)).xyz;
        vec3 up = mix(vec3(0.0, 1.0, 0.0), vec3(0.0, 0.0, 1.0), u_zUp);
        vec2 depth = vec2(volumeOpticalDepth(u_volumeDensity, u_volumeTextureFromWorld, world, normalize(u_volumeSun.xyz), u_volumeParams, 64),
                          volumeOpticalDepth(u_volumeDensity, u_volumeTextureFromWorld, world, up, u_volumeParams, 24));
        o_volumeShadow_texture = vec4(depth, 0.0, 1.0);
      }
      """#

    let fragmentMSL = #"""
      \#(ShaderLibrary.volumeMSL)

      //@main
      {
        int2 px = int2(gl_FragCoord.xy);
        int slice = (px.y / 128) * 16 + px.x / 128;
        float3 uvw = (float3(float2(px % 128), float(slice)) + 0.5) / 128.0;
        float3 world = (u_volumeWorldFromTexture * float4(uvw, 1.0)).xyz;
        float3 up = mix(float3(0.0, 1.0, 0.0), float3(0.0, 0.0, 1.0), u_zUp);
        float2 depth = float2(volumeOpticalDepth(u_volumeDensity, u_volumeDensity_smp, u_volumeTextureFromWorld, world,
                                                 normalize(u_volumeSun.xyz), u_volumeParams, 64),
                              volumeOpticalDepth(u_volumeDensity, u_volumeDensity_smp, u_volumeTextureFromWorld, world,
                                                 up, u_volumeParams, 24));
        o_volumeShadow_texture = float4(depth, 0.0, 1.0);
      }
      """#
  }
}
