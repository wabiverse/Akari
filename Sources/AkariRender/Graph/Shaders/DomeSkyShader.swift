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
  /// drawn by the `dome` pass.
  struct DomeSkyShader: ShaderProgram
  {
    let name = "dome-sky"

    var uniforms: [Declaration]
    {
      Sampler(DomeBuffer.dome)
      Uniforms.domeFromSky
      Uniforms.domeColor
    }

    var stages: [Stage]
    {
      Stage(.compute, glsl: computeGLSL, msl: computeMSL)
    }

    let computeGLSL = #"""
      const float PI = 3.14159265358979;

      vec3 cubeFaceDir(vec2 uv, int face)
      {
        float u = uv.x * 2.0 - 1.0;
        float v = uv.y * 2.0 - 1.0;
        if (face == 0) return normalize(vec3( 1.0, -v, -u));
        if (face == 1) return normalize(vec3(-1.0, -v,  u));
        if (face == 2) return normalize(vec3( u,  1.0, -v));
        if (face == 3) return normalize(vec3( u, -1.0,  v));
        if (face == 4) return normalize(vec3( u, -v,  1.0));
        return normalize(vec3(-u, -v, -1.0));
      }

      void main()
      {
        ivec3 gid = ivec3(gl_GlobalInvocationID);
        ivec2 size = imageSize(o_envCube_texture);
        if (gid.x >= size.x || gid.y >= size.y || gid.z >= 6) return;

        vec3 dir = cubeFaceDir((vec2(gid.xy) + 0.5) / vec2(size), gid.z);
        vec3 d = normalize(mat3(u_domeFromSky) * dir);

        vec2 uv = vec2((atan(d.z, d.x) + 0.5 * PI) / (2.0 * PI), acos(clamp(d.y, -1.0, 1.0)) / PI);
        vec3 c = textureLod(u_dome_texture, vec2(fract(uv.x), uv.y), 0.0).rgb * u_domeColor.rgb;
        imageStore(o_envCube_texture, ivec3(gid.xy, gid.z), vec4(c, 1.0));
      }
      """#

    let computeMSL = #"""
      constexpr constant float PI = 3.14159265358979;

      float3 cubeFaceDir(float2 uv, int face)
      {
        float u = uv.x * 2.0 - 1.0;
        float v = uv.y * 2.0 - 1.0;
        if (face == 0) return normalize(float3( 1.0, -v, -u));
        if (face == 1) return normalize(float3(-1.0, -v,  u));
        if (face == 2) return normalize(float3( u,  1.0,  v));
        if (face == 3) return normalize(float3( u, -1.0, -v));
        if (face == 4) return normalize(float3( u, -v,  1.0));
        return normalize(float3(-u, -v, -1.0));
      }

      //@main
      {
        uint2 size = uint2(o_envCube_texture.get_width(), o_envCube_texture.get_height());
        if (gid.x >= size.x || gid.y >= size.y || gid.z >= 6) return;

        float3 dir = cubeFaceDir((float2(gid.xy) + 0.5) / float2(size), int(gid.z));
        float3x3 rot = float3x3(u_domeFromSky[0].xyz, u_domeFromSky[1].xyz, u_domeFromSky[2].xyz);
        float3 d = normalize(rot * dir);

        float2 uv = float2((atan2(d.z, d.x) + 0.5 * PI) / (2.0 * PI), acos(clamp(d.y, -1.0, 1.0)) / PI);
        float3 c = textureLod(u_dome_texture, float2(fract(uv.x), uv.y), 0.0).rgb * u_domeColor.rgb;
        o_envCube_texture.write(half4(half3(c), 1.0h), ushort2(gid.xy), ushort(gid.z));
      }
      """#
  }
}
