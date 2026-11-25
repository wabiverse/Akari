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
  /// drawn by the `outline mask` pass
  struct OutlineMaskShader: ShaderProgram
  {
    let name = "outline-mask"

    var uniforms: [Declaration]
    {
      Samplers.materialAtlas
      Samplers.materialConstants
      Samplers.outlineLabels
      Sampler(GBuffer.position)
      Sampler(GBuffer.normal)
      Uniforms.outline
      Uniforms.renderScale
      Uniforms.taaJitter
    }

    var varyings: [Declaration]
    {
      Varying<SIMD3<Float>>("posEye")
      Varying<SIMD2<Float>>("uv")
      Varying<Float>("primId")
    }

    var stages: [Stage]
    {
      Stage(.vertex, glsl: vertexGLSL, msl: vertexMSL)
      {
        Attribute<SIMD3<Float>>("a_position", .position)
        Attribute<SIMD4<Float>>("a_color", .color)
        Attribute<SIMD2<Float>>("a_uv", .texcoord)
      }
      Stage(.fragment, glsl: fragmentGLSL, msl: fragmentMSL)
    }

    let vertexGLSL = #"""
      void main()
      {
        var.posEye = (u_modelview * vec4(a_position, 1.0)).xyz;
        var.uv = a_uv;
        var.primId = a_color.r;
        gl_Position = u_modelviewProjection * vec4(a_position, 1.0);
      }
      """#

    let vertexMSL = #"""
      //@main
      {
        float4 objPos = float4(a_position, 1.0);
        var.posEye = (u_modelview * objPos).xyz;
        var.uv = a_uv;
        var.primId = a_color.r;
        gl_Position = u_modelviewProjection * objPos;
      }
      """#

    let fragmentGLSL = #"""
      void main()
      {
        vec4 mat = texture(u_material_atlas, var.uv);
        int row = int(-var.uv.x + 0.5) - 1;
        if (row >= 0)
        {
          // 128 material rows share a scanline, see `MaterialAtlas.constantsRowsPerLine`
          int line = row >> 7;
          int base = (row & 127) * 4;
          mat = vec4(0.0, 0.0, texelFetch(u_materialConstants, ivec2(base, line), 0).a,
                     texelFetch(u_materialConstants, ivec2(base + 1, line), 0).b);
        }

        // only an alpha clip cuts the outline, glass and other see through surfaces still outline whole
        if (mat.a > 0.0 && mat.b < mat.a) discard;

        int width = int(u_outline.y);
        int id = int(round(var.primId));
        float label = id >= 0 && float(id) < u_outline.z
          ? texelFetch(u_outlineLabels, ivec2(id % width, id / width), 0).r : 0.0;
        if (label <= 0.0) discard;

        // finds this pixel in the jittered lower resolution gbuffer, an occluder in any of the four nearest texels counts as hidden
        ivec2 base = ivec2(floor(gl_FragCoord.xy * u_renderScale.xy + u_taaJitter.xy - 0.5));
        ivec2 size = textureSize(u_position_texture, 0);
        bool hidden = false;
        for (int i = 0; i < 4 && !hidden; ++i)
        {
          ivec2 pixel = clamp(base + ivec2(i & 1, i >> 1), ivec2(0), size - 1);
          vec4 scene = texelFetch(u_position_texture, pixel, 0);
          int sceneId = int(round(scene.w));
          float sceneLabel = sceneId >= 0 && float(sceneId) < u_outline.z
            ? texelFetch(u_outlineLabels, ivec2(sceneId % width, sceneId / width), 0).r : 0.0;
          hidden = texelFetch(u_normal_texture, pixel, 0).a >= 0.5 && sceneLabel <= 0.0 &&
                   scene.z > var.posEye.z + max(0.01 * abs(var.posEye.z), 1e-3);
        }

        // hidden pixels are marked negative and y keeps the selected surface's depth for the composite
        o_outlineMask_texture = vec4(hidden ? -label : label, var.posEye.z, 0.0, 0.0);
      }
      """#

    let fragmentMSL = #"""
      //@main
      {
        float4 mat = texture(u_material_atlas, var.uv);
        int row = int(-var.uv.x + 0.5) - 1;
        if (row >= 0)
        {
          // 128 material rows share a scanline, see `MaterialAtlas.constantsRowsPerLine`
          uint line = uint(row) >> 7u;
          uint base = uint(row & 127) * 4u;
          mat = float4(0.0, 0.0, u_materialConstants.read(uint2(base, line)).a,
                       u_materialConstants.read(uint2(base + 1u, line)).b);
        }

        // only an alpha clip cuts the outline, glass and other see through surfaces still outline whole
        if (mat.a > 0.0 && mat.b < mat.a) discard_fragment();

        int width = int(u_outline.y);
        int id = int(round(var.primId));
        float label = 0.0;
        if (id >= 0 && float(id) < u_outline.z) {
          label = u_outlineLabels.read(uint2(id % width, id / width)).r;
        }
        if (label <= 0.0) discard_fragment();

        // finds this pixel in the jittered lower resolution gbuffer, an occluder in any of the four nearest texels counts as hidden
        int2 base = int2(floor(gl_FragCoord.xy * u_renderScale.xy + u_taaJitter.xy - 0.5));
        int2 size = int2(u_position_texture.get_width(), u_position_texture.get_height());
        bool hidden = false;
        for (int i = 0; i < 4 && !hidden; ++i) {
          uint2 pixel = uint2(clamp(base + int2(i & 1, i >> 1), int2(0), size - 1));
          float4 scene = u_position_texture.read(pixel);
          int sceneId = int(round(scene.w));
          float sceneLabel = 0.0;
          if (sceneId >= 0 && float(sceneId) < u_outline.z) {
            sceneLabel = u_outlineLabels.read(uint2(sceneId % width, sceneId / width)).r;
          }
          hidden = u_normal_texture.read(pixel).a >= 0.5 && sceneLabel <= 0.0 &&
                   scene.z > var.posEye.z + max(0.01 * abs(var.posEye.z), 1e-3);
        }

        // hidden pixels are marked negative and y keeps the selected surface's depth for the composite
        o_outlineMask_texture = float4(hidden ? -label : label, var.posEye.z, 0.0, 0.0);
      }
      """#
  }
}
