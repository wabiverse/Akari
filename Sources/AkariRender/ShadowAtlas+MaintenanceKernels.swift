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
  /// float -> ordered int.
  static let orderedIntGLSL = """
    int floatToOrderedInt(float v)
    {
      int i = floatBitsToInt(v);
      return (i < 0) ? (0x7FFFFFFF - i) : i;
    }
    float orderedIntToFloat(int i)
    {
      return intBitsToFloat((i < 0) ? (0x7FFFFFFF - i) : i);
    }
    """

  static let orderedIntMSL = """
    static inline int floatToOrderedInt(float v)
    {
      int i = as_type<int>(v);
      return (i < 0) ? (0x7FFFFFFF - i) : i;
    }
    static inline float orderedIntToFloat(int i)
    {
      return as_type<float>((i < 0) ? (0x7FFFFFFF - i) : i);
    }
    """

  static let clipmapClearGLSL = """
    #version 430
    layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
    layout(std430, binding = 0) buffer Clip { int tilemaps_clip[]; };
    void main()
    {
      uint i = gl_GlobalInvocationID.x;
      if (i >= \(maxTilemaps)u) return;
      tilemaps_clip[i * 2 + 0] = 0x7F7FFFFF;
      tilemaps_clip[i * 2 + 1] = -0x7F7FFFFF - 1;
    }
    """

  static let clipmapClearMSL = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void compute_main(device int* tilemaps_clip [[buffer(1)]],
                             uint3 gid [[thread_position_in_grid]])
    {
      uint i = gid.x;
      if (i >= \(maxTilemaps)u) return;
      tilemaps_clip[i * 2 + 0] = 0x7F7FFFFF;
      tilemaps_clip[i * 2 + 1] = -0x7F7FFFFF - 1;
    }
    """

  /// One thread per caster.
  static let tilemapBoundsBody = """
      int caster = int(gid);
      if (caster >= u_casterCount) return;
      vec3 lo = vec3(caster_bounds[caster * 6 + 0],
                     caster_bounds[caster * 6 + 1],
                     caster_bounds[caster * 6 + 2]);
      vec3 hi = vec3(caster_bounds[caster * 6 + 3],
                     caster_bounds[caster * 6 + 4],
                     caster_bounds[caster * 6 + 5]);
      float zmin = 1e30, zmax = -1e30;
      for (int c = 0; c < 8; ++c)
      {
        vec3 p = vec3((c & 1) != 0 ? hi.x : lo.x,
                      (c & 2) != 0 ? hi.y : lo.y,
                      (c & 4) != 0 ? hi.z : lo.z);
        float z = -(u_lightZ.x * p.x + u_lightZ.y * p.y + u_lightZ.z * p.z);
        zmin = min(zmin, z);
        zmax = max(zmax, z);
      }
      zmin -= abs(zmin) * 0.01;
      zmax += abs(zmax) * 0.01;
    """

  static let tilemapBoundsGLSL = """
    #version 430
    layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
    layout(std430, binding = 0) buffer Bounds { float caster_bounds[]; };
    layout(std430, binding = 1) buffer Clip { int tilemaps_clip[]; };
    uniform int u_casterCount;
    uniform int u_slotCount;
    uniform vec3 u_lightZ;
    \(orderedIntGLSL)
    void main()
    {
      uint gid = gl_GlobalInvocationID.x;
      \(tilemapBoundsBody)
      for (int i = 0; i < u_slotCount; ++i)
      {
        int slot = \(directionalTilemapBase) + i;
        atomicMin(tilemaps_clip[slot * 2 + 0], floatToOrderedInt(zmin));
        atomicMax(tilemaps_clip[slot * 2 + 1], floatToOrderedInt(zmax));
      }
    }
    """

  static let tilemapBoundsMSL = """
    #include <metal_stdlib>
    using namespace metal;
    #define vec3 float3
    struct U { int u_casterCount; int u_slotCount; float3 u_lightZ; };
    \(orderedIntMSL)
    kernel void compute_main(constant U& u [[buffer(0)]],
                             device float* caster_bounds [[buffer(1)]],
                             device atomic_int* tilemaps_clip [[buffer(2)]],
                             uint3 gid3 [[thread_position_in_grid]])
    {
      uint gid = gid3.x;
      int u_casterCount = u.u_casterCount;
      float3 u_lightZ = u.u_lightZ;
      \(tilemapBoundsBody)
      for (int i = 0; i < u.u_slotCount; ++i)
      {
        int slot = \(directionalTilemapBase) + i;
        atomic_fetch_min_explicit(&tilemaps_clip[slot * 2 + 0],
                                  floatToOrderedInt(zmin), memory_order_relaxed);
        atomic_fetch_max_explicit(&tilemaps_clip[slot * 2 + 1],
                                  floatToOrderedInt(zmax), memory_order_relaxed);
      }
    }
    """

  static let tagUpdateBody = """
      int caster = int(gid) % u_casterCount;
      int level = int(gid) / u_casterCount;
      if (level >= u_slotCount) return;
      int lp = level * \(levelParamsStride);
      if (level_params[lp + 15] == 0.0) return;
      float invTile = 1.0 / level_params[lp + 12];

      vec3 lo = vec3(caster_bounds[caster * 6 + 0],
                     caster_bounds[caster * 6 + 1],
                     caster_bounds[caster * 6 + 2]);
      vec3 hi = vec3(caster_bounds[caster * 6 + 3],
                     caster_bounds[caster * 6 + 4],
                     caster_bounds[caster * 6 + 5]);
      vec2 tmin = vec2(1e30), tmax = vec2(-1e30);
      for (int c = 0; c < 8; ++c)
      {
        vec3 p = vec3((c & 1) != 0 ? hi.x : lo.x,
                      (c & 2) != 0 ? hi.y : lo.y,
                      (c & 4) != 0 ? hi.z : lo.z);
        vec3 d = p - u_cameraWorld;
        float lx = u_lightX.x * d.x + u_lightX.y * d.y + u_lightX.z * d.z
                 + level_params[lp + 9];
        float ly = u_lightY.x * d.x + u_lightY.y * d.y + u_lightY.z * d.z
                 + level_params[lp + 10];
        vec2 t = vec2(lx, ly) * invTile + vec2(\(Float(tilemapRes) / 2));
        tmin = min(tmin, t);
        tmax = max(tmax, t);
      }
      ivec2 lo_tile = ivec2(floor(tmin)) - ivec2(1);
      ivec2 hi_tile = ivec2(ceil(tmax)) + ivec2(1);
      lo_tile = max(lo_tile, ivec2(0));
      hi_tile = min(hi_tile, ivec2(\(tilemapRes - 1)));
      if (any(greaterThan(lo_tile, hi_tile))) return;
      int base = (\(directionalTilemapBase) + level) * \(tilesPerTilemap);
    """

  static let tagUpdateGLSL = """
    #version 430
    layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
    layout(std430, binding = 0) buffer Bounds { float caster_bounds[]; };
    layout(std430, binding = 1) buffer LevelParams { float level_params[]; };
    layout(std430, binding = 2) buffer Tiles { uint tiles_buf[]; };
    uniform int u_casterCount;
    uniform int u_slotCount;
    uniform vec3 u_lightX;
    uniform vec3 u_lightY;
    uniform vec3 u_cameraWorld;
    void main()
    {
      uint gid = gl_GlobalInvocationID.x;
      \(tagUpdateBody)
      for (int y = lo_tile.y; y <= hi_tile.y; ++y)
      {
        for (int x = lo_tile.x; x <= hi_tile.x; ++x)
        {
          atomicOr(tiles_buf[base + y * \(tilemapRes) + x], \(flagDynamicUpdate)u);
        }
      }
    }
    """

  static let tagUpdateMSL = """
    #include <metal_stdlib>
    using namespace metal;
    #define vec2 float2
    #define vec3 float3
    #define ivec2 int2
    #define any(x) metal::any(x)
    #define greaterThan(a, b) ((a) > (b))
    struct U
    {
      int u_casterCount; int u_slotCount;
      float3 u_lightX; float3 u_lightY; float3 u_cameraWorld;
    };
    kernel void compute_main(constant U& u [[buffer(0)]],
                             device float* caster_bounds [[buffer(1)]],
                             device float* level_params [[buffer(2)]],
                             device atomic_uint* tiles_buf [[buffer(3)]],
                             uint3 gid3 [[thread_position_in_grid]])
    {
      uint gid = gid3.x;
      int u_casterCount = u.u_casterCount;
      int u_slotCount = u.u_slotCount;
      float3 u_lightX = u.u_lightX;
      float3 u_lightY = u.u_lightY;
      float3 u_cameraWorld = u.u_cameraWorld;
      \(tagUpdateBody)
      for (int y = lo_tile.y; y <= hi_tile.y; ++y)
      {
        for (int x = lo_tile.x; x <= hi_tile.x; ++x)
        {
          atomic_fetch_or_explicit(&tiles_buf[base + y * \(tilemapRes) + x],
                                   \(flagDynamicUpdate)u, memory_order_relaxed);
        }
      }
    }
    """

  /// Marks the point light tiles a moved box covers in every LOD, one thread
  /// per box, light and cube face. A box straddling a face's plane covers all of it.
  static let tagUpdatePunctualBody = """
      if (int(gid) >= u_boxCount * u_lightCount * 6) return;
      int face = int(gid) % 6;
      int light = (int(gid) / 6) % u_lightCount;
      int box = int(gid) / (6 * u_lightCount);
      vec3 lo = vec3(boxes[box * 6 + 0], boxes[box * 6 + 1], boxes[box * 6 + 2]);
      vec3 hi = vec3(boxes[box * 6 + 3], boxes[box * 6 + 4], boxes[box * 6 + 5]);
      vec3 center = lightPosition(light);

      vec2 uvMin = vec2(1e30), uvMax = vec2(-1e30);
      bool front = false, behind = false;
      for (int c = 0; c < 8; ++c)
      {
        vec3 p = vec3((c & 1) != 0 ? hi.x : lo.x,
                      (c & 2) != 0 ? hi.y : lo.y,
                      (c & 4) != 0 ? hi.z : lo.z);
        vec3 fL = akpFaceLocal(face, p - center);
        float d = -fL.z;
        if (d <= 1e-4) { behind = true; continue; }
        front = true;
        vec2 uv = fL.xy / d * 0.5 + 0.5;
        uvMin = min(uvMin, uv);
        uvMax = max(uvMax, uv);
      }
      if (!front) return;
      if (behind) { uvMin = vec2(0.0); uvMax = vec2(1.0); }
      if (uvMax.x < 0.0 || uvMax.y < 0.0 || uvMin.x > 1.0 || uvMin.y > 1.0) return;
      uvMin = clamp(uvMin, vec2(0.0), vec2(1.0));
      uvMax = clamp(uvMax, vec2(0.0), vec2(1.0));

      int base = (light * 6 + face) * \(tilesPerTilemap);
      for (int lod = 0; lod <= \(lodMax); ++lod)
      {
        int size = \(tilemapRes) >> lod;
        ivec2 t0 = max(ivec2(floor(uvMin * float(size))) - ivec2(1), ivec2(0));
        ivec2 t1 = min(ivec2(floor(uvMax * float(size))) + ivec2(1), ivec2(size - 1));
        for (int y = t0.y; y <= t1.y; ++y)
        {
          for (int x = t0.x; x <= t1.x; ++x)
          {
            TAG_TILE(base + akpTileOffset(ivec2(x, y), lod));
          }
        }
      }
    """

  static let tagUpdatePunctualGLSL = """
    #version 430
    layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
    layout(std430, binding = 0) buffer Boxes { float boxes[]; };
    layout(std430, binding = 1) buffer Tiles { uint tiles_buf[]; };
    uniform int u_boxCount;
    uniform int u_lightCount;
    uniform vec4 u_lightPos0;
    uniform vec4 u_lightPos1;
    uniform vec4 u_lightPos2;
    uniform vec4 u_lightPos3;
    \(tagUsagePunctualCommon)
    vec3 lightPosition(int i)
    {
      return (i == 0 ? u_lightPos0 : i == 1 ? u_lightPos1 : i == 2 ? u_lightPos2 : u_lightPos3).xyz;
    }
    #define TAG_TILE(i) atomicOr(tiles_buf[i], \(flagDynamicUpdate)u)
    void main()
    {
      uint gid = gl_GlobalInvocationID.x;
      \(tagUpdatePunctualBody)
    }
    """

  static let tagUpdatePunctualMSL = """
    #include <metal_stdlib>
    using namespace metal;
    #define vec2 float2
    #define vec3 float3
    #define ivec2 int2
    \(tagUsagePunctualMSLCommon)
    struct U { int boxCount; int lightCount; float4 lightPos[4]; };
    #define TAG_TILE(i) atomic_fetch_or_explicit(&tiles_buf[i], \(flagDynamicUpdate)u, memory_order_relaxed)
    #define lightPosition(i) u.lightPos[i].xyz
    kernel void compute_main(constant U& u [[buffer(0)]],
                             device const float* boxes [[buffer(1)]],
                             device atomic_uint* tiles_buf [[buffer(2)]],
                             uint3 gid3 [[thread_position_in_grid]])
    {
      uint gid = gid3.x;
      int u_boxCount = u.boxCount;
      int u_lightCount = u.lightCount;
      \(tagUpdatePunctualBody)
    }
    """

  /// LOD update tag pushed down the mip chain.
  static let tagPropagateBody = """
      int slot = int(gid_z);
      int x = int(gid_x);
      int y = int(gid_y);
      int base = slot * \(tilesPerTilemap);
      uint tile = tiles_buf[base + y * \(tilemapRes) + x];
      uint bits = tile & \(flagDoUpdate | flagDynamicUpdate)u;
      if (bits == 0u) return;
      int offset = \(tilemapRes * tilemapRes);
      int size = \(tilemapRes);
    """

  static let tagPropagateGLSL = """
    #version 430
    layout(local_size_x = \(tilemapRes), local_size_y = \(tilemapRes), local_size_z = 1) in;
    layout(std430, binding = 0) buffer Tiles { uint tiles_buf[]; };
    void main()
    {
      uint gid_x = gl_GlobalInvocationID.x;
      uint gid_y = gl_GlobalInvocationID.y;
      uint gid_z = gl_GlobalInvocationID.z;
      \(tagPropagateBody)
      for (int lod = 1; lod <= \(lodMax); ++lod)
      {
        size >>= 1;
        atomicOr(tiles_buf[base + offset + (y >> lod) * size + (x >> lod)], bits);
        offset += size * size;
      }
    }
    """

  static let tagPropagateMSL = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void compute_main(device atomic_uint* tiles_atomic [[buffer(1)]],
                             device uint* tiles_buf [[buffer(2)]],
                             uint3 gid [[thread_position_in_grid]])
    {
      uint gid_x = gid.x, gid_y = gid.y, gid_z = gid.z;
      \(tagPropagateBody)
      for (int lod = 1; lod <= \(lodMax); ++lod)
      {
        size >>= 1;
        atomic_fetch_or_explicit(&tiles_atomic[base + offset + (y >> lod) * size + (x >> lod)],
                                 bits, memory_order_relaxed);
        offset += size * size;
      }
    }
    """

  static let buildRenderViewsBody = """
      int view = int(gid);
      if (view == 0)
      {
        clear_args[0] = \(pageResolution / 16)u;
        clear_args[1] = \(pageResolution / 16)u;
        clear_args[2] = 0u;
        clear_args_static[0] = \(pageResolution / 16)u;
        clear_args_static[1] = \(pageResolution / 16)u;
        clear_args_static[2] = 0u;
      }
      if (view >= \(maxViews)) return;
      uint resident = \(flagIsUsed | flagIsAllocated)u;
      int slot, base, count, side;
      if (view < \(maxDirectionalTilemaps))
      {
        slot = slot_of_view[view];
        base = slot * \(tilesPerTilemap);
        side = \(tilemapRes);
        count = side * side;
      }
      else
      {
        int pv = view - \(punctualViewBase);
        int lod = pv % \(lodCount);
        int size = \(tilemapRes);
        base = (pv / \(lodCount)) * \(tilesPerTilemap);
        for (int l = 0; l < lod; ++l) { base += size * size; size >>= 1; }
        slot = pv / \(lodCount);
        side = size;
        count = size * size;
      }
      int x0 = side, y0 = side, x1 = -1, y1 = -1;
      int sx0 = side, sy0 = side, sx1 = -1, sy1 = -1;
      if (slot >= 0)
      {
        for (int i = 0; i < count; ++i)
        {
          uint packed = tiles_buf[base + i];
          if ((packed & resident) != resident || (packed & \(flagDoUpdate | flagDynamicUpdate)u) == 0u) continue;
          int x = i % side, y = i / side;
          x0 = min(x0, x); y0 = min(y0, y); x1 = max(x1, x); y1 = max(y1, y);
          if ((packed & \(flagDoUpdate)u) == 0u) continue;
          sx0 = min(sx0, x); sy0 = min(sy0, y); sx1 = max(sx1, x); sy1 = max(sy1, y);
        }
      }
      bool dirty = x1 >= 0;
      render_view[view] = dirty ? uint(view < \(maxDirectionalTilemaps) ? slot : view) : 0xFFFFFFFFu;
      render_rect[view] = dirty ? uint(x0 | (y0 << 5) | (x1 << 10) | (y1 << 15) | (1 << 20)) : 0u;
      render_rect_static[view] = sx1 >= 0 ? uint(sx0 | (sy0 << 5) | (sx1 << 10) | (sy1 << 15) | (1 << 20)) : 0u;
    """

  static let buildRenderViewsGLSL = """
    #version 430
    layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
    layout(std430, binding = 0) buffer Tiles { uint tiles_buf[]; };
    layout(std430, binding = 1) buffer SlotOfView { int slot_of_view[]; };
    layout(std430, binding = 2) buffer RenderView { uint render_view[]; };
    layout(std430, binding = 3) buffer ClearArgs { uint clear_args[]; };
    layout(std430, binding = 4) buffer RenderRect { uint render_rect[]; };
    layout(std430, binding = 5) buffer RenderRectStatic { uint render_rect_static[]; };
    layout(std430, binding = 6) buffer ClearArgsStatic { uint clear_args_static[]; };
    void main()
    {
      uint gid = gl_GlobalInvocationID.x;
      \(buildRenderViewsBody)
    }
    """

  static let buildRenderViewsMSL = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void compute_main(device uint* tiles_buf [[buffer(1)]],
                             device int* slot_of_view [[buffer(2)]],
                             device uint* render_view [[buffer(3)]],
                             device uint* clear_args [[buffer(4)]],
                             device uint* render_rect [[buffer(5)]],
                             device uint* render_rect_static [[buffer(6)]],
                             device uint* clear_args_static [[buffer(7)]],
                             uint3 gid3 [[thread_position_in_grid]])
    {
      uint gid = gid3.x;
      \(buildRenderViewsBody)
    }
    """

  static let buildClearListBody = """
      int entry = int(gid);
      if (entry >= \(maxViews * tilemapRes * tilemapRes)) return;
      uint page = render_map[entry];
      if (page == 0xFFFFFFFFu) return;
    """

  static let buildClearListGLSL = """
    #version 430
    layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
    layout(std430, binding = 0) buffer RenderMap { uint render_map[]; };
    layout(std430, binding = 1) buffer ClearList { uint clear_list[]; };
    layout(std430, binding = 2) buffer Args { uint args[]; };
    void main()
    {
      uint gid = gl_GlobalInvocationID.x;
      \(buildClearListBody)
      uint slot = atomicAdd(args[2], 1u);
      if (slot < \(maxPage)) { clear_list[slot] = page; }
    }
    """

  static let buildClearListMSL = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void compute_main(device uint* render_map [[buffer(1)]],
                             device uint* clear_list [[buffer(2)]],
                             device atomic_uint* args [[buffer(3)]],
                             uint3 gid3 [[thread_position_in_grid]])
    {
      uint gid = gid3.x;
      \(buildClearListBody)
      uint slot = atomic_fetch_add_explicit(&args[2], 1u, memory_order_relaxed);
      if (slot < \(maxPage)) { clear_list[slot] = page; }
    }
    """

  static let renderMapClearGLSL = """
    #version 430
    layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
    layout(std430, binding = 0) buffer RenderMap { uint render_map[]; };
    void main() { render_map[gl_GlobalInvocationID.x] = 0xFFFFFFFFu; }
    """

  static let renderMapClearMSL = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void compute_main(device uint* render_map [[buffer(1)]],
                             uint3 gid [[thread_position_in_grid]])
    {
      render_map[gid.x] = 0xFFFFFFFFu;
    }
    """
}
