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
  /// drawn by the `grid overlay` pass.
  struct GridOverlayShader: FullscreenShader
  {
    let name = "grid-overlay"

    var uniforms: [Declaration]
    {
      Sampler(GBuffer.position)
      Sampler(GBuffer.normal)
      Sampler(TransparentResolvedBuffer.tSurface)
      Uniforms.view
      Uniforms.gridInvProj
      Uniforms.viewGrid
      Uniforms.zUp
      Uniforms.renderScale
      Uniforms.taaJitter
    }

    let fragmentGLSL = #"""
      float gridLine(vec2 g, vec2 w, float spacing)
      {
        vec2 line = abs(fract(g / spacing - 0.5) - 0.5) / (w / spacing);
        return 1.0 - min(min(line.x, line.y), 1.0);
      }

      void main()
      {
        if (u_viewGrid.x < 0.5) discard;

        mat3 invView = transpose(mat3(u_view));
        vec4 e = u_gridInvProj * vec4(var.texCoord * 2.0 - 1.0, -1.0, 1.0);
        vec3 dirEye = normalize(e.xyz / e.w);
        vec3 dir = invView * dirEye;
        vec3 eye = invView * -u_view[3].xyz;
        vec3 up = u_zUp > 0.5 ? vec3(0.0, 0.0, 1.0) : vec3(0.0, 1.0, 0.0);

        float facing = dot(dir, up);
        float t = abs(facing) > 1e-6 ? -dot(eye, up) / facing : -1.0;
        if (t <= 0.0) discard;

        vec3 p = eye + dir * t;
        vec2 plane = u_zUp > 0.5 ? p.xy : vec2(p.x, -p.z);
        vec2 w = max(fwidth(plane), vec2(1e-6));

        // geometry above or on the floor hides the grid, a height test with a pixel margin stays steady on coplanar surfaces
        ivec2 gSize = textureSize(u_position_texture, 0);
        ivec2 g = clamp(ivec2(floor(gl_FragCoord.xy * u_renderScale.xy + u_taaJitter.xy)), ivec2(0), gSize - 1);
        float side = dot(eye, up) < 0.0 ? -1.0 : 1.0;
        float margin = -max(w.x, w.y) * 0.5;
        if (texelFetch(u_normal_texture, g, 0).a >= 0.5)
        {
          vec3 surface = invView * texelFetch(u_position_texture, g, 0).xyz + eye;
          if (dot(surface, up) * side > margin) discard;
        }

        // glass never reaches the gbuffer, so without this the grid draws straight over it
        float through = 1.0;
        vec2 tSurface = texelFetch(u_tSurface_texture, g, 0).rg;
        if (tSurface.y > 0.0)
        {
          float depth = 1.0 / max(tSurface.x, 1e-20);
          vec3 surface = invView * (dirEye * (depth / max(-dirEye.z, 1e-6))) + eye;
          if (dot(surface, up) * side > margin) through = max(1.0 - tSurface.y, 0.0);
        }

        // squares are a unit wide and grow tenfold as they crowd together in the distance.
        float level = clamp(log10(max(w.x, w.y) * 14.0), 0.0, 8.0);
        float fine = pow(10.0, floor(level));
        float blend = fract(level);

        float minor = gridLine(plane, w, fine) * (1.0 - blend);
        float major = gridLine(plane, w, fine * 10.0);

        float xAxis = 1.0 - min(abs(plane.y) / w.y * 0.6, 1.0);
        float yAxis = 1.0 - min(abs(plane.x) / w.x * 0.6, 1.0);

        float height = max(abs(dot(eye, up)), u_viewGrid.y);
        float fade = (1.0 - smoothstep(0.0, 1.0, t / (height * 40.0))) * smoothstep(0.0, 0.3, abs(facing));

        vec4 color = vec4(vec3(0.35), max(minor * 0.25, major * 0.45));
        color = mix(color, vec4(0.85, 0.2, 0.25, 0.8), xAxis);
        color = mix(color, vec4(0.45, 0.75, 0.2, 0.8), yAxis);
        o_tonemap_texture = vec4(color.rgb, color.a * fade * through);
      }
      """#

    let fragmentMSL = #"""
      //@main
      {
        if (u_viewGrid.x < 0.5) discard_fragment();

        float3x3 invView = transpose(float3x3(u_view[0].xyz, u_view[1].xyz, u_view[2].xyz));
        float4 e = u_gridInvProj * float4(var.texCoord * 2.0 - 1.0, -1.0, 1.0);
        float3 dirEye = normalize(e.xyz / e.w);
        float3 dir = invView * dirEye;
        float3 eye = invView * -u_view[3].xyz;
        float3 up = u_zUp > 0.5 ? float3(0.0, 0.0, 1.0) : float3(0.0, 1.0, 0.0);

        float facing = dot(dir, up);
        float t = abs(facing) > 1e-6 ? -dot(eye, up) / facing : -1.0;
        if (t <= 0.0) discard_fragment();

        float3 p = eye + dir * t;
        float2 plane = u_zUp > 0.5 ? p.xy : float2(p.x, -p.z);
        float2 w = max(fwidth(plane), float2(1e-6));

        // geometry above or on the floor hides the grid, a height test with a pixel margin stays steady on coplanar surfaces
        int2 gSize = int2(u_position_texture.get_width(), u_position_texture.get_height());
        uint2 g = uint2(clamp(int2(floor(gl_FragCoord.xy * u_renderScale.xy + u_taaJitter.xy)), int2(0), gSize - 1));
        float side = dot(eye, up) < 0.0 ? -1.0 : 1.0;
        float margin = -max(w.x, w.y) * 0.5;
        if (u_normal_texture.read(g).a >= 0.5)
        {
          float3 surface = invView * u_position_texture.read(g).xyz + eye;
          if (dot(surface, up) * side > margin) discard_fragment();
        }

        // glass never reaches the gbuffer, so without this the grid draws straight over it
        float through = 1.0;
        float2 tSurface = u_tSurface_texture.read(g).rg;
        if (tSurface.y > 0.0)
        {
          float depth = 1.0 / max(tSurface.x, 1e-20);
          float3 surface = invView * (dirEye * (depth / max(-dirEye.z, 1e-6))) + eye;
          if (dot(surface, up) * side > margin) through = max(1.0 - tSurface.y, 0.0);
        }

        // squares are a unit wide and grow tenfold as they crowd together in the distance.
        float level = clamp(log10(max(w.x, w.y) * 14.0), 0.0, 8.0);
        float fine = pow(10.0, floor(level));
        float blend = fract(level);

        float2 fineLine = abs(fract(plane / fine - 0.5) - 0.5) / (w / fine);
        float2 coarseLine = abs(fract(plane / (fine * 10.0) - 0.5) - 0.5) / (w / (fine * 10.0));
        float minor = (1.0 - min(min(fineLine.x, fineLine.y), 1.0)) * (1.0 - blend);
        float major = 1.0 - min(min(coarseLine.x, coarseLine.y), 1.0);

        float xAxis = 1.0 - min(abs(plane.y) / w.y * 0.6, 1.0);
        float yAxis = 1.0 - min(abs(plane.x) / w.x * 0.6, 1.0);

        float height = max(abs(dot(eye, up)), u_viewGrid.y);
        float fade = (1.0 - smoothstep(0.0, 1.0, t / (height * 40.0))) * smoothstep(0.0, 0.3, abs(facing));

        float4 color = float4(float3(0.35), max(minor * 0.25, major * 0.45));
        color = mix(color, float4(0.85, 0.2, 0.25, 0.8), xAxis);
        color = mix(color, float4(0.45, 0.75, 0.2, 0.8), yAxis);
        o_tonemap_texture = float4(color.rgb, color.a * fade * through);
      }
      """#
  }
}
