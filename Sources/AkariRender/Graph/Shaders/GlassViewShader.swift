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
  /// drawn by the glass view passes, keeping the nearest or farthest glass so the transparent composite can trace through it
  struct GlassViewShader: ShaderProgram
  {
    /// the nearest glass and its far side, then the next glass behind it and that one's far side
    enum Side: String, Sendable
    {
      case front, back, behindFront, behindBack

      var isFar: Bool { self == .back || self == .behindBack }
    }

    let side: Side

    var name: String { "glass-view-\(side.rawValue)" }

    var uniforms: [Declaration]
    {
      Samplers.materialAtlas
      Samplers.colorAtlas
      Samplers.materialConstants
      Samplers.primStyle
      Sampler(GBuffer.position)
      Sampler(GBuffer.normal)
      if side == .back || side == .behindFront { Sampler(GlassFrontBuffer.glassFront) }
      if side == .behindBack { Sampler(GlassBehindFrontBuffer.glassBehindFront) }
    }

    var varyings: [Declaration]
    {
      Varying<SIMD3<Float>>("posEye")
      Varying<SIMD3<Float>>("normalEye")
      Varying<SIMD2<Float>>("uv")
      Varying<Float>("primId")
      Varying<SIMD4<Float>>("vcolor")
    }

    var stages: [Stage]
    {
      Stage(.vertex, glsl: ShaderLibrary.metalOnly, msl: vertexMSL)
      {
        Attribute<SIMD4<Float>>("a_position", .position)
        Attribute<SIMD4<Float>>("a_color", .color)
        Attribute<SIMD3<Float>>("a_normal", .normal)
        Attribute<SIMD2<Float>>("a_uv", .texcoord)
        Attribute<Float>("a_pad", .pad)
      }
      Stage(.fragment, glsl: ShaderLibrary.metalOnly, msl: fragmentMSL)
    }

    private var vertexMSL: String
    {
      #"""
      //@main
      {
        float4 objPos = float4(a_position.xyz, 1.0);
        var.posEye = (u_modelview * objPos).xyz;
        var.normalEye = normalize(u_normalMatrix * a_normal);
        var.uv = a_uv;
        var.primId = a_color.r;

        float packed = a_uv.x < 0.0 ? a_uv.y - 1.0 : -1.0;
        var.vcolor = packed >= 0.0 ? float4(floor(packed / 65536.0), fmod(floor(packed / 256.0), 256.0), fmod(packed, 256.0), 255.0) / 255.0
                                   : float4(0.0);

        gl_Position = u_modelviewProjection * objPos;
        \#(side.isFar ? "// flipping reversed depth keeps the farthest glass.\n  gl_Position.z = gl_Position.w - gl_Position.z;" : "")
      }
      """#
    }

    private var fragmentMSL: String
    {
      let (surface, normal) = outputs
      return #"""
        \#(ShaderLibrary.styleMSL)
        \#(ShaderLibrary.glassSurfaceMSL)

        //@main
        {
          // glass only, a glowing shell counts as light rather than glass.
          float4 flags = styleTexel(u_primStyle, var.primId, 4);
          if (flags.y < 0.5 || flags.z > 0.5) discard_fragment();

          float4 surface = glassSurface(var.uv, var.vcolor, u_material_atlas, u_material_atlas_smp,
                                        u_color_atlas, u_color_atlas_smp, u_materialConstants);
          if (surface.a < 0.0) discard_fragment();

          uint2 px = uint2(gl_FragCoord.xy);
          \#(side.isFar ? "" : "if (u_normal_texture.read(px).a >= 0.5 && var.posEye.z < u_position_texture.read(px).z - 1e-4 * abs(var.posEye.z)) discard_fragment();")

          \#(match)

          // the normal faces the camera at the front and away from it at the back.
          float3 n = normalize(var.normalEye);
          bool facing = dot(n, -var.posEye) > 0.0;
          if (facing != \#(side.isFar ? "false" : "true")) n = -n;

          // w holds which glass this is, one past its prim id so zero still means none
          \#(surface) = float4(var.posEye, var.primId + 1.0);
          \#(normal) = float4(n, 1.0);
        }
        """#
    }

    private var outputs: (surface: String, normal: String)
    {
      switch side
      {
      case .front: (GlassFrontBuffer.glassFront.ref.output, GlassFrontBuffer.glassFrontNormal.ref.output)
      case .back: (GlassBackBuffer.glassBack.ref.output, GlassBackBuffer.glassBackNormal.ref.output)
      case .behindFront: (GlassBehindFrontBuffer.glassBehindFront.ref.output, GlassBehindFrontBuffer.glassBehindFrontNormal.ref.output)
      case .behindBack: (GlassBehindBackBuffer.glassBehindBack.ref.output, GlassBehindBackBuffer.glassBehindBackNormal.ref.output)
      }
    }

    /// which glass each side keeps, so overlapping glass never pairs one object's near side with another's far side
    private var match: String
    {
      switch side
      {
      case .front:
        ""
      case .back:
        "if (abs(u_glassFront_texture.read(px).w - (var.primId + 1.0)) > 0.5) discard_fragment();"
      case .behindFront:
        "float nearest = u_glassFront_texture.read(px).w; if (nearest < 0.5 || abs(nearest - (var.primId + 1.0)) < 0.5) discard_fragment();"
      case .behindBack:
        "if (abs(u_glassBehindFront_texture.read(px).w - (var.primId + 1.0)) > 0.5) discard_fragment();"
      }
    }
  }
}
