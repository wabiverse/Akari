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
  /// drawn by the `ssgi pyramid` pass
  struct SsgiPyramidShader: FullscreenShader
  {
    let name = "ssgi-pyramid"

    var uniforms: [Declaration]
    {
      Sampler(SsgiPrepBuffer.ssgiDepth)
      Sampler(SsgiPrepBuffer.ssgiNormal)
      Sampler(SsgiPrepBuffer.ssgiRadiance)
      Uniforms.ssgi
      Uniforms.ssgiSize
    }

    let fragmentGLSL = #"""
      void main()
      {
        ivec2 q = ivec2(gl_FragCoord.xy);
        ivec2 full = ivec2(u_ssgiSize.xy);
        ivec2 s1 = full >> 2, s2 = full >> 3, s3 = full >> 4;
        int level = 0;
        ivec2 p = q;
        if (q.x < s1.x && q.y < s1.y) { level = 1; }
        else if (q.x >= s1.x && q.x < s1.x + s2.x && q.y < s2.y) { level = 2; p = q - ivec2(s1.x, 0); }
        else if (q.x >= s1.x && q.x < s1.x + s3.x && q.y >= s2.y && q.y < s2.y + s3.y) { level = 3; p = q - ivec2(s1.x, s2.y); }

        o_ssgiPyramidDepth_texture = vec4(0.0);
        o_ssgiPyramidNormal_texture = vec4(0.0);
        o_ssgiPyramidRadiance_texture = vec4(0.0);
        if (level == 0 || u_ssgi.z < 0.5) return;

        ivec2 last = textureSize(u_ssgiDepth_texture, 0) - 1;
        int span = 1 << level;
        ivec2 base = p * span;
        float far = 0.0;
        for (int y = 0; y < span; ++y) {
          for (int x = 0; x < span; ++x) {
            float z = texelFetch(u_ssgiDepth_texture, min(base + ivec2(x, y), last), 0).x;
            if (z < 0.0) far = min(far, z);
          }
        }

        if (far >= 0.0) return;

        float effect = 0.75 * u_ssgi.x;
        float range = 0.615 * effect;
        float from = effect - range;
        float wsum = 0.0, zsum = 0.0;
        vec3 nsum = vec3(0.0), rsum = vec3(0.0);
        for (int y = 0; y < span; ++y) {
          for (int x = 0; x < span; ++x) {
            ivec2 t = min(base + ivec2(x, y), last);
            float z = texelFetch(u_ssgiDepth_texture, t, 0).x;
            if (z >= 0.0) continue;
            float w = clamp(1.0 - (z - far - from) / range, 0.0, 1.0);
            zsum += z * w;
            nsum += texelFetch(u_ssgiNormal_texture, t, 0).xyz * w;
            rsum += texelFetch(u_ssgiRadiance_texture, t, 0).rgb * w;
            wsum += w;
          }
        }

        o_ssgiPyramidDepth_texture = vec4(zsum / wsum, 0.0, 0.0, 0.0);
        o_ssgiPyramidNormal_texture = vec4(nsum / max(length(nsum), 1e-4), 0.0);
        o_ssgiPyramidRadiance_texture = vec4(rsum / wsum, 1.0);
      }
      """#

    let fragmentMSL = #"""
      //@main
      {
        int2 q = int2(gl_FragCoord.xy);
        int2 full = int2(u_ssgiSize.xy);
        int2 s1 = full >> 2, s2 = full >> 3, s3 = full >> 4;
        int level = 0;
        int2 p = q;
        if (q.x < s1.x && q.y < s1.y) { level = 1; }
        else if (q.x >= s1.x && q.x < s1.x + s2.x && q.y < s2.y) { level = 2; p = q - int2(s1.x, 0); }
        else if (q.x >= s1.x && q.x < s1.x + s3.x && q.y >= s2.y && q.y < s2.y + s3.y) { level = 3; p = q - int2(s1.x, s2.y); }

        o_ssgiPyramidDepth_texture = float4(0.0);
        o_ssgiPyramidNormal_texture = float4(0.0);
        o_ssgiPyramidRadiance_texture = float4(0.0);

        int2 last = int2(u_ssgiDepth_texture.get_width(), u_ssgiDepth_texture.get_height()) - 1;
        int span = level == 0 || u_ssgi.z < 0.5 ? 0 : 1 << level;
        int2 base = p * span;
        float far = 0.0;
        for (int y = 0; y < span; ++y) {
          for (int x = 0; x < span; ++x) {
            float z = u_ssgiDepth_texture.read(uint2(min(base + int2(x, y), last))).x;
            if (z < 0.0) far = min(far, z);
          }
        }
        if (far < 0.0) {
          float effect = 0.75 * u_ssgi.x;
          float range = 0.615 * effect;
          float from = effect - range;
          float wsum = 0.0, zsum = 0.0;
          float3 nsum = float3(0.0), rsum = float3(0.0);
          for (int y = 0; y < span; ++y) {
            for (int x = 0; x < span; ++x) {
              uint2 t = uint2(min(base + int2(x, y), last));
              float z = u_ssgiDepth_texture.read(t).x;
              if (z >= 0.0) continue;
              float w = clamp(1.0 - (z - far - from) / range, 0.0, 1.0);
              zsum += z * w;
              nsum += u_ssgiNormal_texture.read(t).xyz * w;
              rsum += u_ssgiRadiance_texture.read(t).rgb * w;
              wsum += w;
            }
          }

          o_ssgiPyramidDepth_texture = float4(zsum / wsum, 0.0, 0.0, 0.0);
          o_ssgiPyramidNormal_texture = float4(nsum / max(length(nsum), 1e-4), 0.0);
          o_ssgiPyramidRadiance_texture = float4(rsum / wsum, 1.0);
        }
      }
      """#
  }
}
