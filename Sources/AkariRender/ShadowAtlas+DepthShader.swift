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

extension Akari.ShadowAtlas
{
  static let depthVertexGLSL = """
    #version 330 core
    layout(location = 0) in vec4 a_position;
    uniform mat4 u_modelviewProjection;
    void main()
    {
      gl_Position = u_modelviewProjection * a_position;
    }
    """

  static let depthFragmentGLSL = """
    #version 330 core
    void main() {}
    """

  static let depthMSL = """
    #include <metal_stdlib>
    using namespace metal;

    struct VertIn
    {
      float4 a_position [[attribute(0)]];
      float4 a_color    [[attribute(1)]];
      float2 a_texcoord [[attribute(2)]];
      float3 a_normal   [[attribute(3)]];
    };
    struct VertOut
    {
      float4 position [[position]];
      uint   view [[user(akari_view)]];
      float  clip [[clip_distance]] [4];
    };
    struct FragIn
    {
      float4 position [[position]];
      uint   view [[user(akari_view)]];
    };
    struct U { int u_viewBase; };
    inline void clipToRect(thread VertOut& out, const device uint* render_rect, uint view)
    {
      uint rect = render_rect[view];
      if (rect == 0u) { out.clip[0] = out.clip[1] = out.clip[2] = out.clip[3] = -1.0; return; }
      float size = float(view >= \(punctualViewBase)u ? (\(tilemapRes)u >> ((view - \(punctualViewBase)u) % \(lodCount)u))
                                                      : \(tilemapRes)u);
      float w = out.position.w;
      float x0 = float(rect & 31u) / size * 2.0 - 1.0;
      float y0 = float((rect >> 5u) & 31u) / size * 2.0 - 1.0;
      float x1 = float(((rect >> 10u) & 31u) + 1u) / size * 2.0 - 1.0;
      float y1 = float(((rect >> 15u) & 31u) + 1u) / size * 2.0 - 1.0;
      out.clip[0] = out.position.x - x0 * w;
      out.clip[1] = x1 * w - out.position.x;
      out.clip[2] = out.position.y - y0 * w;
      out.clip[3] = y1 * w - out.position.y;
    }
    struct LabGLBuiltins
    {
      float4x4 u_modelview;
      float4x4 u_projection;
      float4x4 u_modelviewProjection;
      float3x3 u_normalMatrix;
    };
    vertex VertOut vert_main(VertIn in [[stage_in]],
                             constant U& u [[buffer(2)]],
                             constant LabGLBuiltins& B [[buffer(3)]])
    {
      VertOut out;
      out.position = B.u_modelviewProjection * in.a_position;
      out.position.z = (out.position.z + out.position.w) * 0.5;
      out.view = uint(u.u_viewBase);
      out.clip[0] = out.clip[1] = out.clip[2] = out.clip[3] = 1.0;
      return out;
    }

    vertex VertOut vert_amplified_main(VertIn in [[stage_in]],
                                       constant float4x4* viewsXf [[buffer(1)]],
                                       constant U& u [[buffer(2)]],
                                       constant LabGLBuiltins& B [[buffer(3)]],
                                       const device uint* render_rect [[buffer(5)]],
                                       ushort ampId [[amplification_id]])
    {
      VertOut out;
      out.position = viewsXf[ampId] * in.a_position;
      out.view = uint(u.u_viewBase) + uint(ampId);
      clipToRect(out, render_rect, out.view);
      out.position.z = (out.position.z + out.position.w) * 0.5;
      return out;
    }

    vertex VertOut vert_amplified_indirect_main(VertIn in [[stage_in]],
                                                constant float4x4* viewsXf [[buffer(1)]],
                                                constant U& u [[buffer(2)]],
                                                constant float4x4& model [[buffer(4)]],
                                                const device uint* render_rect [[buffer(5)]],
                                                const device float4x4* view_xf [[buffer(7)]],
                                                const device uint* instance_view [[buffer(8)]],
                                                ushort ampId [[amplification_id]],
                                                uint instance [[instance_id]])
    {
      VertOut out;
      if (u.u_viewBase < 0)
      {
        out.view = instance_view[instance];
        out.position = (view_xf[out.view] * model) * in.a_position;
        clipToRect(out, render_rect, out.view);
        float s = 1.0 / float(1u << ((out.view - \(punctualViewBase)u) % \(lodCount)u));
        out.position.xy = (out.position.xy + out.position.w) * s - out.position.w;
      }
      else
      {
        out.position = (viewsXf[ampId] * model) * in.a_position;
        out.view = uint(u.u_viewBase) + uint(ampId);
        clipToRect(out, render_rect, out.view);
      }
      out.position.z = (out.position.z + out.position.w) * 0.5;
      return out;
    }

    vertex VertOut vert_indirect_main(VertIn in [[stage_in]],
                                      constant float4x4* viewsXf [[buffer(1)]],
                                      constant U& u [[buffer(2)]],
                                      constant float4x4& model [[buffer(4)]])
    {
      VertOut out;
      out.position = (viewsXf[0] * model) * in.a_position;
      out.position.z = (out.position.z + out.position.w) * 0.5;
      out.view = uint(u.u_viewBase);
      out.clip[0] = out.clip[1] = out.clip[2] = out.clip[3] = 1.0;
      return out;
    }

    struct AtlasImages
    {
      texture2d_array<uint, access::read_write,
                      memory_coherence_device> atlas [[texture(0)]];
    };

    fragment void frag_main(FragIn in [[stage_in]],
                            const device uint* render_map [[buffer(0)]],
                            constant AtlasImages& images [[buffer(1)]],
                            const device int* slot_of_view [[buffer(4)]],
                            device atomic_uint* tiles_buf [[buffer(5)]])
    {
      int2 texel = int2(in.position.xy);
      int2 tile = texel >> \(pageShift);
      int view = int(in.view);
      int size = \(tilemapRes);
      int tileBase;
      if (view >= \(punctualViewBase))
      {
        int pv = view - \(punctualViewBase);
        tileBase = (pv / \(lodCount)) * \(tilesPerTilemap);
        for (int l = 0; l < pv % \(lodCount); ++l) { tileBase += size * size; size >>= 1; }
      }
      else
      {
        int slot = slot_of_view[view];
        if (slot < 0) return;
        tileBase = slot * \(tilesPerTilemap);
      }
      if (any(tile < int2(0)) || any(tile >= int2(size))) return;
      uint packed = render_map[view * \(tilemapRes * tilemapRes)
                               + tile.y * \(tilemapRes) + tile.x];
      if (packed == 0xFFFFFFFFu) return;
      int page = int(packed);
      uint2 out_texel = uint2(uint(page % \(pagesPerLayer)) * \(pageResolution)
                                + uint(texel.x & \(pageResolution - 1)),
                              uint(texel.y & \(pageResolution - 1)));
      images.atlas.atomic_fetch_min(out_texel, uint(page / \(pagesPerLayer)),
                                    as_type<uint>(in.position.z));
      atomic_fetch_or_explicit(&tiles_buf[tileBase + tile.y * size + tile.x],
                               \(flagIsRendered)u, memory_order_relaxed);
    }
    """
}
