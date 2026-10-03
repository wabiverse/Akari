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
  static let beginFrameGLSL = """
    #version 430
    layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
    layout(std430, binding = 0) buffer Tiles { uint tiles_buf[]; };
    uniform int u_dirty;
    void main()
    {
      uint i = gl_GlobalInvocationID.x;
      if (i >= \(maxTiles)u) return;
      uint d = tiles_buf[i];
      if ((d & \(flagIsRendered)u) != 0u) { d &= ~(\(flagDoUpdate | flagIsRendered | flagDynamicUpdate)u); }
      d &= ~0x80000000u;
      if (i < \(maxPunctualTilemaps * tilesPerTilemap)u)
      {
        int tilemapIndex = int(i / \(tilesPerTilemap)u);
        bool dirty = ((uint(u_dirty) >> uint(tilemapIndex)) & 1u) != 0u;
        if (dirty && (d & (0x10000000u | 0x08000000u)) != 0u) d |= 0x20000000u;
      }
      tiles_buf[i] = d;
    }
    """

  static let beginFrameMSL = """
    #include <metal_stdlib>
    using namespace metal;
    struct U { int dirty; };
    kernel void compute_main(constant U& u [[buffer(0)]],
                             device uint* tiles_buf [[buffer(1)]],
                             uint i [[thread_position_in_grid]])
    {
      if (i >= \(maxTiles)u) return;
      uint d = tiles_buf[i];
      if ((d & \(flagIsRendered)u) != 0u) { d &= ~(\(flagDoUpdate | flagIsRendered | flagDynamicUpdate)u); }
      d &= ~0x80000000u;
      if (i < \(maxPunctualTilemaps * tilesPerTilemap)u)
      {
        int tilemapIndex = int(i / \(tilesPerTilemap)u);
        bool dirty = ((uint(u.dirty) >> uint(tilemapIndex)) & 1u) != 0u;
        if (dirty && (d & (0x10000000u | 0x08000000u)) != 0u) d |= 0x20000000u;
      }
      tiles_buf[i] = d;
    }
    """

  static let dilateUsageDirectionalGLSL = """
    #version 430
    layout(local_size_x = \(tilemapRes), local_size_y = \(tilemapRes), local_size_z = 1) in;
    layout(std430, binding = 0) buffer Tiles { uint tiles_buf[]; };
    shared uint used_local[\(tilemapRes * tilemapRes)];
    void main()
    {
      int tilemapBase = (\(maxPunctualTilemaps) + int(gl_WorkGroupID.x)) * \(tilesPerTilemap);
      ivec2 co = ivec2(gl_LocalInvocationID.xy);
      int local = co.y * \(tilemapRes) + co.x;
      uint packed = tiles_buf[tilemapBase + local];
      used_local[local] = packed & 0x80000000u;
      barrier();
      if (used_local[local] != 0u) return;
      for (int dy = -1; dy <= 1; ++dy)
      for (int dx = -1; dx <= 1; ++dx)
      {
        ivec2 n = co + ivec2(dx, dy);
        if (any(lessThan(n, ivec2(0))) || any(greaterThanEqual(n, ivec2(\(tilemapRes))))) continue;
        if (used_local[n.y * \(tilemapRes) + n.x] != 0u)
        {
          tiles_buf[tilemapBase + local] = packed | 0x80000000u;
          return;
        }
      }
    }
    """

  static let dilateUsageDirectionalMSL = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void compute_main(device uint* tiles_buf [[buffer(1)]],
                             uint2 tilemap_id [[threadgroup_position_in_grid]],
                             uint2 co_u [[thread_position_in_threadgroup]])
    {
      threadgroup uint used_local[\(tilemapRes * tilemapRes)];
      int tilemapBase = (\(maxPunctualTilemaps) + int(tilemap_id.x)) * \(tilesPerTilemap);
      int2 co = int2(co_u);
      int local = co.y * \(tilemapRes) + co.x;
      uint packed = tiles_buf[tilemapBase + local];
      used_local[local] = packed & 0x80000000u;
      threadgroup_barrier(mem_flags::mem_threadgroup);
      if (used_local[local] != 0u) return;
      for (int dy = -1; dy <= 1; ++dy)
      for (int dx = -1; dx <= 1; ++dx)
      {
        int2 n = co + int2(dx, dy);
        if (any(n < int2(0)) || any(n >= int2(\(tilemapRes)))) continue;
        if (used_local[n.y * \(tilemapRes) + n.x] != 0u)
        {
          tiles_buf[tilemapBase + local] = packed | 0x80000000u;
          return;
        }
      }
    }
    """

  /// For punctual shadows of the directional dilate, at every LOD.
  static let dilateUsagePunctualGLSL = """
    #version 430
    layout(local_size_x = \(tilemapRes), local_size_y = \(tilemapRes), local_size_z = 1) in;
    layout(std430, binding = 0) buffer Tiles { uint tiles_buf[]; };
    shared uint used_local[\(tilemapRes * tilemapRes)];
    void main()
    {
      int tilemapBase = int(gl_WorkGroupID.x) * \(tilesPerTilemap);
      ivec2 co = ivec2(gl_LocalInvocationID.xy);
      int lodBase = 0;
      for (int lod = 0; lod <= \(lodMax); ++lod)
      {
        int size = \(tilemapRes) >> lod;
        bool inside = co.x < size && co.y < size;
        int local = co.y * size + co.x;
        uint packed = inside ? tiles_buf[tilemapBase + lodBase + local] : 0u;
        if (inside) used_local[local] = packed & 0x80000000u;
        barrier();
        if (inside && (packed & 0x80000000u) == 0u)
        {
          bool near = false;
          for (int dy = -1; dy <= 1; ++dy)
          for (int dx = -1; dx <= 1; ++dx)
          {
            ivec2 n = co + ivec2(dx, dy);
            if (all(greaterThanEqual(n, ivec2(0))) && all(lessThan(n, ivec2(size))))
              near = near || used_local[n.y * size + n.x] != 0u;
          }
          if (near) tiles_buf[tilemapBase + lodBase + local] = packed | 0x80000000u;
        }
        barrier();
        lodBase += size * size;
      }
    }
    """

  static let dilateUsagePunctualMSL = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void compute_main(device uint* tiles_buf [[buffer(1)]],
                             uint2 tilemap_id [[threadgroup_position_in_grid]],
                             uint2 co_u [[thread_position_in_threadgroup]])
    {
      threadgroup uint used_local[\(tilemapRes * tilemapRes)];
      int tilemapBase = int(tilemap_id.x) * \(tilesPerTilemap);
      int2 co = int2(co_u);
      int lodBase = 0;
      for (int lod = 0; lod <= \(lodMax); ++lod)
      {
        int size = \(tilemapRes) >> lod;
        bool inside = co.x < size && co.y < size;
        int local = co.y * size + co.x;
        uint packed = inside ? tiles_buf[tilemapBase + lodBase + local] : 0u;
        if (inside) used_local[local] = packed & 0x80000000u;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (inside && (packed & 0x80000000u) == 0u)
        {
          bool near = false;
          for (int dy = -1; dy <= 1; ++dy)
          for (int dx = -1; dx <= 1; ++dx)
          {
            int2 n = co + int2(dx, dy);
            if (all(n >= int2(0)) && all(n < int2(size)))
              near = near || used_local[n.y * size + n.x] != 0u;
          }
          if (near) tiles_buf[tilemapBase + lodBase + local] = packed | 0x80000000u;
        }
        threadgroup_barrier(mem_flags::mem_threadgroup);
        lodBase += size * size;
      }
    }
    """

  static let tilemapShiftGLSL = """
    #version 430
    layout(local_size_x = \(tilemapRes), local_size_y = \(tilemapRes), local_size_z = 1) in;
    layout(std430, binding = 0) buffer Tiles { uint tiles_buf[]; };
    layout(std430, binding = 1) buffer PagesCached { uvec2 pages_cached_buf[]; };
    layout(std430, binding = 2) buffer GridShift { ivec2 grid_shift_buf[]; };
    \(commonGLSL)
    void main()
    {
      int offset = int(gl_WorkGroupID.x);
      int tilemapBase = (\(maxPunctualTilemaps) + offset) * \(tilesPerTilemap);

      ivec2 tile_co = ivec2(gl_LocalInvocationID.xy);
      ivec2 shift = clamp(grid_shift_buf[offset], ivec2(-\(tilemapRes)), ivec2(\(tilemapRes)));
      ivec2 tile_shifted = tile_co + shift;
      bool out_of_range = any(lessThan(tile_shifted, ivec2(0))) ||
                          any(greaterThanEqual(tile_shifted, ivec2(\(tilemapRes))));
      ivec2 tile_wrapped = (tile_shifted + ivec2(\(tilemapRes))) % \(tilemapRes);

      int tile_load = tilemapBase + tile_wrapped.y * \(tilemapRes) + tile_wrapped.x;
      Tile tile = shadow_tile_unpack(tiles_buf[tile_load]);
      if (out_of_range) { tile.do_update = true; }
      uint packed = shadow_tile_pack(tile);
      uint cache_index = tile.cache_index;
      bool is_cached = tile.is_cached;

      barrier();

      int tile_store = tilemapBase + tile_co.y * \(tilemapRes) + tile_co.x;
      if ((tile_load != tile_store) && is_cached)
      {
        pages_cached_buf[cache_index].y = uint(tile_store);
      }
      tiles_buf[tile_store] = packed;
    }
    """

  static let tilemapShiftMSL = """
    #include <metal_stdlib>
    using namespace metal;
    \(commonMSL)
    kernel void compute_main(device uint* tiles_buf [[buffer(1)]],
                             device uint2* pages_cached_buf [[buffer(2)]],
                             device int2* grid_shift_buf [[buffer(3)]],
                             uint2 tilemap_id [[threadgroup_position_in_grid]],
                             uint2 tile_co_u [[thread_position_in_threadgroup]])
    {
      int offset = int(tilemap_id.x);
      int tilemapBase = (\(maxPunctualTilemaps) + offset) * \(tilesPerTilemap);
      int2 tile_co = int2(tile_co_u);

      int2 shift = clamp(grid_shift_buf[offset], int2(-\(tilemapRes)), int2(\(tilemapRes)));
      int2 tile_shifted = tile_co + shift;
      bool out_of_range = any(tile_shifted < int2(0)) || any(tile_shifted >= int2(\(tilemapRes)));
      int2 tile_wrapped = (tile_shifted + int2(\(tilemapRes))) % \(tilemapRes);

      int tile_load = tilemapBase + tile_wrapped.y * \(tilemapRes) + tile_wrapped.x;
      Tile tile = shadow_tile_unpack(tiles_buf[tile_load]);
      if (out_of_range) { tile.do_update = true; }
      uint packed = shadow_tile_pack(tile);
      uint cache_index = tile.cache_index;
      bool is_cached = tile.is_cached;

      threadgroup_barrier(mem_flags::mem_device);

      int tile_store = tilemapBase + tile_co.y * \(tilemapRes) + tile_co.x;
      if ((tile_load != tile_store) && is_cached)
      {
        pages_cached_buf[cache_index].y = uint(tile_store);
      }
      tiles_buf[tile_store] = packed;
    }
    """

  /// Per screen pixel, per active light.
  static let tagUsagePunctualCommon = """
    int akpFaceIndex(vec3 lL)
    {
      vec3 aP = abs(lL);
      if (aP.x > aP.y && aP.x > aP.z) return lL.x > 0.0 ? 1 : 2;
      if (aP.y > aP.x && aP.y > aP.z) return lL.y > 0.0 ? 3 : 4;
      return lL.z > 0.0 ? 5 : 0;
    }
    vec3 akpFaceLocal(int face, vec3 lL)
    {
      if (face == 1) return vec3(-lL.y, lL.z, -lL.x);
      if (face == 2) return vec3(lL.y, lL.z, lL.x);
      if (face == 3) return vec3(lL.x, lL.z, -lL.y);
      if (face == 4) return vec3(-lL.x, lL.z, lL.y);
      if (face == 5) return vec3(lL.x, -lL.y, -lL.z);
      return lL;
    }
    int akpTileOffset(ivec2 tile, int lod)
    {
      int base = 0, size = \(tilemapRes);
      for (int l = 0; l < lod; l++) { base += size * size; size >>= 1; }
      return base + tile.y * size + tile.x;
    }
    """

  static let tagUsagePunctualGLSL = """
    #version 430
    layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
    layout(std430, binding = 0) buffer Tiles { uint tiles_buf[]; };
    layout(binding = 0) uniform sampler2D u_position;
    uniform mat4 u_invView;
    uniform vec4 u_lightPosRadius0;
    uniform vec4 u_lightPosRadius1;
    uniform vec4 u_lightPosRadius2;
    uniform vec4 u_lightPosRadius3;
    uniform vec4 u_params;
    \(tagUsagePunctualCommon)
    void akpTag(vec3 worldPos, float distToCamera, int lightIdx, vec4 posRadius)
    {
      vec3 lL = worldPos - posRadius.xyz;
      float distanceToLight = max(max(abs(lL.x), abs(lL.y)), abs(lL.z));
      if (distanceToLight < 1e-6) return;
      if (length(lL) > posRadius.w) return;
      int face = akpFaceIndex(lL);
      vec3 fL = akpFaceLocal(face, lL);
      float shadowPixelRadius = (2.0 * 1.4142135) / float(\(shadowMapMaxRes));
      float footprint = max(u_params.x * distToCamera, 1e-6) / distanceToLight;
      float ratio = clamp(shadowPixelRadius / max(footprint, 1e-8), 0.0, 1.0);
      int level = int(clamp(-log2(max(ratio, 1e-8)), 0.0, float(\(lodMax))));
      int tilesPerSide = \(tilemapRes) >> level;
      vec2 uv = clamp(fL.xy / max(abs(fL.z), 1e-6) * 0.5 + 0.5, 0.0, 0.999999);
      ivec2 tile = clamp(ivec2(uv * float(tilesPerSide)), ivec2(0), ivec2(tilesPerSide - 1));
      int tilemapIndex = lightIdx * 6 + face;
      int tileIdx = tilemapIndex * \(tilesPerTilemap) + akpTileOffset(tile, level);
      atomicOr(tiles_buf[tileIdx], 0x80000000u);
    }
    void main()
    {
      ivec2 screenSize = ivec2(u_params.yz);
      int lightCount = int(u_params.w);
      ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
      if (pixel.x >= screenSize.x || pixel.y >= screenSize.y) return;
      vec3 posEye = texelFetch(u_position, pixel, 0).xyz;
      if (posEye == vec3(0.0)) return;
      vec3 worldPos = (u_invView * vec4(posEye, 1.0)).xyz;
      float distToCamera = abs(posEye.z);
      if (lightCount > 0) akpTag(worldPos, distToCamera, 0, u_lightPosRadius0);
      if (lightCount > 1) akpTag(worldPos, distToCamera, 1, u_lightPosRadius1);
      if (lightCount > 2) akpTag(worldPos, distToCamera, 2, u_lightPosRadius2);
      if (lightCount > 3) akpTag(worldPos, distToCamera, 3, u_lightPosRadius3);
    }
    """

  static let tagUsagePunctualMSLCommon = """
    inline int akpFaceIndex(float3 lL)
    {
      float3 aP = abs(lL);
      if (aP.x > aP.y && aP.x > aP.z) return lL.x > 0.0 ? 1 : 2;
      if (aP.y > aP.x && aP.y > aP.z) return lL.y > 0.0 ? 3 : 4;
      return lL.z > 0.0 ? 5 : 0;
    }
    inline float3 akpFaceLocal(int face, float3 lL)
    {
      if (face == 1) return float3(-lL.y, lL.z, -lL.x);
      if (face == 2) return float3(lL.y, lL.z, lL.x);
      if (face == 3) return float3(lL.x, lL.z, -lL.y);
      if (face == 4) return float3(-lL.x, lL.z, lL.y);
      if (face == 5) return float3(lL.x, -lL.y, -lL.z);
      return lL;
    }
    inline int akpTileOffset(int2 tile, int lod)
    {
      int base = 0, size = \(tilemapRes);
      for (int l = 0; l < lod; l++) { base += size * size; size >>= 1; }
      return base + tile.y * size + tile.x;
    }
    """

  static let tagUsagePunctualMSL = """
    #include <metal_stdlib>
    using namespace metal;
    \(tagUsagePunctualMSLCommon)
    struct U
    {
      float4x4 invView;
      float4 lightPosRadius[4];
      float4 params;
    };
    inline void akpTag(float3 worldPos, float filmFootprint, int lightIdx, float4 posRadius,
                       device atomic_uint* tiles_buf)
    {
      float3 lL = worldPos - posRadius.xyz;
      float distanceToLight = max(max(abs(lL.x), abs(lL.y)), abs(lL.z));
      if (distanceToLight < 1e-6) return;
      if (length(lL) > posRadius.w) return;
      int face = akpFaceIndex(lL);
      float3 fL = akpFaceLocal(face, lL);
      float shadowPixelRadius = (2.0 * 1.4142135) / float(\(shadowMapMaxRes));
      float footprint = max(filmFootprint, 1e-6) / distanceToLight;
      float ratio = clamp(shadowPixelRadius / max(footprint, 1e-8), 0.0, 1.0);
      int level = int(clamp(-log2(max(ratio, 1e-8)), 0.0, float(\(lodMax))));
      int tilesPerSide = \(tilemapRes) >> level;
      float2 uv = clamp(fL.xy / max(abs(fL.z), 1e-6) * 0.5 + 0.5, 0.0, 0.999999);
      int2 tile = clamp(int2(uv * float(tilesPerSide)), int2(0), int2(tilesPerSide - 1));
      int tilemapIndex = lightIdx * 6 + face;
      int tileIdx = tilemapIndex * \(tilesPerTilemap) + akpTileOffset(tile, level);
      atomic_fetch_or_explicit(&tiles_buf[tileIdx], 0x80000000u, memory_order_relaxed);
    }
    kernel void compute_main(constant U& u [[buffer(0)]],
                             device atomic_uint* tiles_buf [[buffer(1)]],
                             texture2d<float> posTex [[texture(0)]],
                             sampler posSampler [[sampler(0)]],
                             uint2 gid [[thread_position_in_grid]])
    {
      int2 screenSize = int2(u.params.yz);
      int lightCount = int(u.params.w);
      int2 pixel = int2(gid);
      if (pixel.x >= screenSize.x || pixel.y >= screenSize.y) return;
      float3 posEye = posTex.read(uint2(pixel)).xyz;
      if (all(posEye == float3(0))) return;
      float3 worldPos = (u.invView * float4(posEye, 1.0)).xyz;
      float distToCamera = abs(posEye.z);
      for (int i = 0; i < lightCount; ++i)
        akpTag(worldPos, distToCamera * u.params.x, i, u.lightPosRadius[i], tiles_buf);
    }
    """

  static let tagUsageDirectionalGLSL = """
    #version 430
    layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
    layout(std430, binding = 0) buffer Tiles { uint tiles_buf[]; };
    layout(binding = 0) uniform sampler2D u_position;
    layout(binding = 1) uniform sampler2D u_data;
    uniform mat4 u_eyeToFitEye;
    uniform mat4 u_eyeToLightRotation;
    uniform vec4 u_directionalRefOffset;
    uniform ivec4 u_params;
    uniform ivec4 u_lodRange;

    mat4 levelMatrix(int i) {
      return mat4(texelFetch(u_data, ivec2(0, \(directionalTilemapBase) + i), 0),
                  texelFetch(u_data, ivec2(1, \(directionalTilemapBase) + i), 0),
                  texelFetch(u_data, ivec2(2, \(directionalTilemapBase) + i), 0),
                  texelFetch(u_data, ivec2(3, \(directionalTilemapBase) + i), 0));
    }
    int levelSlot(int i) {
      return int(texelFetch(u_data, ivec2(4, \(directionalTilemapBase) + i), 0).x);
    }

    int pickLevelIndex(vec3 posEye, bool isClipmap, int lodMin, int lodMax) {
      vec3 delta = (u_eyeToLightRotation * vec4(posEye, 0.0)).xyz - u_directionalRefOffset.xyz;
      float lod;
      if (isClipmap) {
        float narrowing = \(Float(tilemapRes)) / (\(Float(tilemapRes)) - 1.0001);
        lod = log2(length(delta) * narrowing * 2.0);
      } else {
        float narrowing = \(Float(tilemapRes)) / (\(Float(tilemapRes)) - 2.5001);
        float lodMinMinusOne = float(lodMin - 1);
        float lodMinHalfSize = exp2(lodMinMinusOne);
        lod = length(delta.xy) * narrowing / lodMinHalfSize + lodMinMinusOne;
      }
      lod += u_directionalRefOffset.w;
      int level = clamp(int(ceil(lod)), lodMin, lodMax);
      return level - lodMin;
    }

    void main()
    {
      ivec2 screenSize = u_params.xy;
      int levelCount = u_params.z;
      bool isClipmap = u_params.w != 0;
      ivec2 pixel = ivec2(gl_GlobalInvocationID.xy);
      if (pixel.x >= screenSize.x || pixel.y >= screenSize.y) return;
      vec3 posEye = texelFetch(u_position, pixel, 0).xyz;
      if (posEye == vec3(0.0)) return;
      posEye = (u_eyeToFitEye * vec4(posEye, 1.0)).xyz;

      int i = pickLevelIndex(posEye, isClipmap, u_lodRange.x, u_lodRange.y);
      if (i >= 0 && i < levelCount)
      {
        vec4 clip = levelMatrix(i) * vec4(posEye, 1.0);
        if (clip.w > 0.0)
        {
          vec3 ndc = clip.xyz / clip.w;
          ivec2 tile = clamp(ivec2((ndc.xy * 0.5 + 0.5) * \(Float(tilemapRes))),
                             ivec2(0), ivec2(\(tilemapRes - 1)));
          int slot = levelSlot(i);
          int tileIdx = slot * \(tilesPerTilemap) + tile.y * \(tilemapRes) + tile.x;
          atomicOr(tiles_buf[tileIdx], 0x80000000u);
        }
      }
    }
    """

  static let tagUsageDirectionalMSL = """
    #include <metal_stdlib>
    using namespace metal;
    struct U { float4x4 eyeToFitEye; float4x4 eyeToLightRotation;
              float4 directionalRefOffset; int4 params; int4 lodRange; };

    inline float4x4 levelMatrix(int i, texture2d<float> dataTex) {
      return float4x4(dataTex.read(uint2(0, \(directionalTilemapBase) + i)),
                      dataTex.read(uint2(1, \(directionalTilemapBase) + i)),
                      dataTex.read(uint2(2, \(directionalTilemapBase) + i)),
                      dataTex.read(uint2(3, \(directionalTilemapBase) + i)));
    }
    inline int levelSlot(int i, texture2d<float> dataTex) {
      return int(dataTex.read(uint2(4, \(directionalTilemapBase) + i)).x);
    }

    inline int pickLevelIndex(float3 posEye, bool isClipmap, int lodMin, int lodMax, constant U& u) {
      float3 delta = (u.eyeToLightRotation * float4(posEye, 0.0)).xyz - u.directionalRefOffset.xyz;
      float lod;
      if (isClipmap) {
        float narrowing = \(Float(tilemapRes)) / (\(Float(tilemapRes)) - 1.0001);
        lod = log2(length(delta) * narrowing * 2.0);
      } else {
        float narrowing = \(Float(tilemapRes)) / (\(Float(tilemapRes)) - 2.5001);
        float lodMinMinusOne = float(lodMin - 1);
        float lodMinHalfSize = exp2(lodMinMinusOne);
        lod = length(delta.xy) * narrowing / lodMinHalfSize + lodMinMinusOne;
      }
      lod += u.directionalRefOffset.w;
      int level = clamp(int(ceil(lod)), lodMin, lodMax);
      return level - lodMin;
    }

    kernel void compute_main(constant U& u [[buffer(0)]],
                             device atomic_uint* tiles_buf [[buffer(1)]],
                             texture2d<float> posTex [[texture(0)]],
                             texture2d<float> dataTex [[texture(1)]],
                             sampler posSampler [[sampler(0)]],
                             uint2 gid [[thread_position_in_grid]])
    {
      int2 screenSize = u.params.xy;
      int levelCount = u.params.z;
      bool isClipmap = u.params.w != 0;
      int2 pixel = int2(gid);
      if (pixel.x >= screenSize.x || pixel.y >= screenSize.y) return;
      float3 posEye = posTex.read(uint2(pixel)).xyz;
      if (all(posEye == float3(0))) return;
      posEye = (u.eyeToFitEye * float4(posEye, 1.0)).xyz;

      int i = pickLevelIndex(posEye, isClipmap, u.lodRange.x, u.lodRange.y, u);
      if (i < 0 || i >= levelCount) return;

      float4 clip = levelMatrix(i, dataTex) * float4(posEye, 1.0);
      if (clip.w <= 0.0) return;
      float3 ndc = clip.xyz / clip.w;
      int2 tile = clamp(int2((ndc.xy * 0.5 + 0.5) * \(Float(tilemapRes))),
                        int2(0), int2(\(tilemapRes - 1)));
      int slot = levelSlot(i, dataTex);
      int tileIdx = slot * \(tilesPerTilemap) + tile.y * \(tilemapRes) + tile.x;
      atomic_fetch_or_explicit(&tiles_buf[tileIdx], 0x80000000u, memory_order_relaxed);
    }
    """

  static let tagUsageVolumeGLSL = """
    #version 430
    layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
    layout(std430, binding = 0) buffer Tiles { uint tiles_buf[]; };
    layout(binding = 0) uniform sampler2D u_froxelDepth;
    layout(binding = 1) uniform sampler2D u_data;
    uniform mat4 u_invView;
    uniform mat4 u_eyeToFitEye;
    uniform mat4 u_eyeToLightRotation;
    uniform mat4 u_invProj;
    uniform vec4 u_directionalRefOffset;
    uniform vec4 u_lightPosRadius0;
    uniform vec4 u_lightPosRadius1;
    uniform vec4 u_lightPosRadius2;
    uniform vec4 u_lightPosRadius3;
    uniform vec4 u_volume;
    uniform vec4 u_params;
    uniform vec4 u_lodRange;
    \(tagUsagePunctualCommon)

    void tagTile(int tileIdx)
    {
      if ((tiles_buf[tileIdx] & 0x80000000u) == 0u) atomicOr(tiles_buf[tileIdx], 0x80000000u);
    }

    mat4 levelMatrix(int i) {
      return mat4(texelFetch(u_data, ivec2(0, \(directionalTilemapBase) + i), 0),
                  texelFetch(u_data, ivec2(1, \(directionalTilemapBase) + i), 0),
                  texelFetch(u_data, ivec2(2, \(directionalTilemapBase) + i), 0),
                  texelFetch(u_data, ivec2(3, \(directionalTilemapBase) + i), 0));
    }
    int levelSlot(int i) {
      return int(texelFetch(u_data, ivec2(4, \(directionalTilemapBase) + i), 0).x);
    }

    int pickLevelIndex(vec3 posEye, bool isClipmap, int lodMin, int lodMax) {
      vec3 delta = (u_eyeToLightRotation * vec4(posEye, 0.0)).xyz - u_directionalRefOffset.xyz;
      float lod;
      if (isClipmap) {
        float narrowing = \(Float(tilemapRes)) / (\(Float(tilemapRes)) - 1.0001);
        lod = log2(length(delta) * narrowing * 2.0);
      } else {
        float narrowing = \(Float(tilemapRes)) / (\(Float(tilemapRes)) - 2.5001);
        float lodMinMinusOne = float(lodMin - 1);
        float lodMinHalfSize = exp2(lodMinMinusOne);
        lod = length(delta.xy) * narrowing / lodMinHalfSize + lodMinMinusOne;
      }
      lod += u_directionalRefOffset.w;
      int level = clamp(int(ceil(lod)), lodMin, lodMax);
      return level - lodMin;
    }

    void tagDirectional(vec3 fitEye)
    {
      int i = pickLevelIndex(fitEye, u_params.w > 0.5, int(u_lodRange.x), int(u_lodRange.y));
      if (i < 0 || i >= int(u_params.z)) return;
      i = min(i + int(u_lodRange.z), int(u_params.z) - 1);
      vec4 clip = levelMatrix(i) * vec4(fitEye, 1.0);
      if (clip.w <= 0.0) return;
      vec3 ndc = clip.xyz / clip.w;
      if (abs(ndc.x) > 1.0 || abs(ndc.y) > 1.0) return;
      ivec2 tile = clamp(ivec2((ndc.xy * 0.5 + 0.5) * \(Float(tilemapRes))),
                         ivec2(0), ivec2(\(tilemapRes - 1)));
      tagTile(levelSlot(i) * \(tilesPerTilemap) + tile.y * \(tilemapRes) + tile.x);
    }

    void tagPunctual(vec3 worldPos, float footprint, int lightIdx, vec4 posRadius)
    {
      vec3 lL = worldPos - posRadius.xyz;
      float distanceToLight = max(max(abs(lL.x), abs(lL.y)), abs(lL.z));
      if (distanceToLight < 1e-6) return;
      if (length(lL) > posRadius.w) return;
      int face = akpFaceIndex(lL);
      vec3 fL = akpFaceLocal(face, lL);
      float shadowPixelRadius = (2.0 * 1.4142135) / float(\(shadowMapMaxRes));
      float ratio = clamp(shadowPixelRadius / max(max(footprint, 1e-6) / distanceToLight, 1e-8), 0.0, 1.0);
      int level = int(clamp(-log2(max(ratio, 1e-8)), 0.0, float(\(lodMax))));
      int tilesPerSide = \(tilemapRes) >> level;
      vec2 uv = clamp(fL.xy / max(abs(fL.z), 1e-6) * 0.5 + 0.5, 0.0, 0.999999);
      ivec2 tile = clamp(ivec2(uv * float(tilesPerSide)), ivec2(0), ivec2(tilesPerSide - 1));
      int tilemapIndex = lightIdx * 6 + face;
      tagTile(tilemapIndex * \(tilesPerTilemap) + akpTileOffset(tile, level));
    }

    void main()
    {
      ivec2 grid = max(ivec2(u_volume.zw), ivec2(1));
      ivec2 a = ivec2(gl_GlobalInvocationID.xy);
      if (a.x >= grid.x * 8 || a.y >= grid.y * 8) return;
      ivec2 sliceXY = a / grid;
      int s = sliceXY.y * 8 + sliceXY.x;
      ivec2 froxel = a - sliceXY * grid;

      float t0 = float(s) / 64.0;
      if (mix(u_volume.x, u_volume.y, t0 * t0) > texelFetch(u_froxelDepth, froxel, 0).x) return;

      float t = (float(s) + 0.5) / 64.0;
      float depth = mix(u_volume.x, u_volume.y, t * t);
      vec2 uv = (vec2(froxel) + 0.5) / vec2(grid);
      vec4 e = u_invProj * vec4(uv * 2.0 - 1.0, 1.0, 1.0);
      vec3 dirEye = e.xyz / e.w;
      vec3 posEye = dirEye * (depth / max(-dirEye.z, 1e-6));

      if (u_params.z > 0.5) tagDirectional((u_eyeToFitEye * vec4(posEye, 1.0)).xyz);

      vec3 worldPos = (u_invView * vec4(posEye, 1.0)).xyz;
      float footprint = u_params.x * depth;
      int lightCount = int(u_params.y);
      if (lightCount > 0) tagPunctual(worldPos, footprint, 0, u_lightPosRadius0);
      if (lightCount > 1) tagPunctual(worldPos, footprint, 1, u_lightPosRadius1);
      if (lightCount > 2) tagPunctual(worldPos, footprint, 2, u_lightPosRadius2);
      if (lightCount > 3) tagPunctual(worldPos, footprint, 3, u_lightPosRadius3);
    }
    """

  static let tagUsageVolumeMSL = """
    #include <metal_stdlib>
    using namespace metal;
    \(tagUsagePunctualMSLCommon)
    struct U
    {
      float4x4 invView;
      float4x4 eyeToFitEye;
      float4x4 eyeToLightRotation;
      float4x4 invProj;
      float4 directionalRefOffset;
      float4 lightPosRadius[4];
      float4 volume;
      float4 params;
      float4 lodRange;
    };

    inline float4x4 levelMatrix(int i, texture2d<float> dataTex) {
      return float4x4(dataTex.read(uint2(0, \(directionalTilemapBase) + i)),
                      dataTex.read(uint2(1, \(directionalTilemapBase) + i)),
                      dataTex.read(uint2(2, \(directionalTilemapBase) + i)),
                      dataTex.read(uint2(3, \(directionalTilemapBase) + i)));
    }
    inline int levelSlot(int i, texture2d<float> dataTex) {
      return int(dataTex.read(uint2(4, \(directionalTilemapBase) + i)).x);
    }

    inline int pickLevelIndex(float3 posEye, bool isClipmap, int lodMin, int lodMax, constant U& u) {
      float3 delta = (u.eyeToLightRotation * float4(posEye, 0.0)).xyz - u.directionalRefOffset.xyz;
      float lod;
      if (isClipmap) {
        float narrowing = \(Float(tilemapRes)) / (\(Float(tilemapRes)) - 1.0001);
        lod = log2(length(delta) * narrowing * 2.0);
      } else {
        float narrowing = \(Float(tilemapRes)) / (\(Float(tilemapRes)) - 2.5001);
        float lodMinMinusOne = float(lodMin - 1);
        float lodMinHalfSize = exp2(lodMinMinusOne);
        lod = length(delta.xy) * narrowing / lodMinHalfSize + lodMinMinusOne;
      }
      lod += u.directionalRefOffset.w;
      int level = clamp(int(ceil(lod)), lodMin, lodMax);
      return level - lodMin;
    }

    inline void tagTile(int tileIdx, device atomic_uint* tiles_buf)
    {
      if ((atomic_load_explicit(&tiles_buf[tileIdx], memory_order_relaxed) & 0x80000000u) == 0u)
        atomic_fetch_or_explicit(&tiles_buf[tileIdx], 0x80000000u, memory_order_relaxed);
    }

    inline void tagDirectional(float3 fitEye, constant U& u, texture2d<float> dataTex,
                               device atomic_uint* tiles_buf)
    {
      int i = pickLevelIndex(fitEye, u.params.w > 0.5, int(u.lodRange.x), int(u.lodRange.y), u);
      if (i < 0 || i >= int(u.params.z)) return;
      i = min(i + int(u.lodRange.z), int(u.params.z) - 1);
      float4 clip = levelMatrix(i, dataTex) * float4(fitEye, 1.0);
      if (clip.w <= 0.0) return;
      float3 ndc = clip.xyz / clip.w;
      if (abs(ndc.x) > 1.0 || abs(ndc.y) > 1.0) return;
      int2 tile = clamp(int2((ndc.xy * 0.5 + 0.5) * \(Float(tilemapRes))),
                        int2(0), int2(\(tilemapRes - 1)));
      tagTile(levelSlot(i, dataTex) * \(tilesPerTilemap) + tile.y * \(tilemapRes) + tile.x, tiles_buf);
    }

    inline void tagPunctual(float3 worldPos, float footprint, int lightIdx, float4 posRadius,
                            device atomic_uint* tiles_buf)
    {
      float3 lL = worldPos - posRadius.xyz;
      float distanceToLight = max(max(abs(lL.x), abs(lL.y)), abs(lL.z));
      if (distanceToLight < 1e-6) return;
      if (length(lL) > posRadius.w) return;
      int face = akpFaceIndex(lL);
      float3 fL = akpFaceLocal(face, lL);
      float shadowPixelRadius = (2.0 * 1.4142135) / float(\(shadowMapMaxRes));
      float ratio = clamp(shadowPixelRadius / max(max(footprint, 1e-6) / distanceToLight, 1e-8), 0.0, 1.0);
      int level = int(clamp(-log2(max(ratio, 1e-8)), 0.0, float(\(lodMax))));
      int tilesPerSide = \(tilemapRes) >> level;
      float2 uv = clamp(fL.xy / max(abs(fL.z), 1e-6) * 0.5 + 0.5, 0.0, 0.999999);
      int2 tile = clamp(int2(uv * float(tilesPerSide)), int2(0), int2(tilesPerSide - 1));
      int tilemapIndex = lightIdx * 6 + face;
      tagTile(tilemapIndex * \(tilesPerTilemap) + akpTileOffset(tile, level), tiles_buf);
    }

    kernel void compute_main(constant U& u [[buffer(0)]],
                             device atomic_uint* tiles_buf [[buffer(1)]],
                             texture2d<float> froxelDepthTex [[texture(0)]],
                             texture2d<float> dataTex [[texture(1)]],
                             sampler froxelDepthSampler [[sampler(0)]],
                             uint2 gid [[thread_position_in_grid]])
    {
      int2 grid = max(int2(u.volume.zw), int2(1));
      int2 a = int2(gid);
      if (a.x >= grid.x * 8 || a.y >= grid.y * 8) return;
      int2 sliceXY = a / grid;
      int s = sliceXY.y * 8 + sliceXY.x;
      int2 froxel = a - sliceXY * grid;

      float t0 = float(s) / 64.0;
      if (mix(u.volume.x, u.volume.y, t0 * t0) > froxelDepthTex.read(uint2(froxel)).x) return;

      float t = (float(s) + 0.5) / 64.0;
      float depth = mix(u.volume.x, u.volume.y, t * t);
      float2 uv = (float2(froxel) + 0.5) / float2(grid);
      float4 e = u.invProj * float4(uv * 2.0 - 1.0, 1.0, 1.0);
      float3 dirEye = e.xyz / e.w;
      float3 posEye = dirEye * (depth / max(-dirEye.z, 1e-6));

      if (u.params.z > 0.5) tagDirectional((u.eyeToFitEye * float4(posEye, 1.0)).xyz, u, dataTex, tiles_buf);

      float3 worldPos = (u.invView * float4(posEye, 1.0)).xyz;
      float footprint = u.params.x * depth;
      int lightCount = int(u.params.y);
      for (int i = 0; i < lightCount; ++i)
        tagPunctual(worldPos, footprint, i, u.lightPosRadius[i], tiles_buf);
    }
    """

  static let maskLodGLSL = """
    #version 430
    layout(local_size_x = \(tilemapRes), local_size_y = \(tilemapRes), local_size_z = 1) in;
    shared uint tiles_local[\(tilesPerTilemap)];
    shared uint levels_rendered;
    shared uint force_base_page;
    layout(std430, binding = 0) buffer Tiles { uint tiles_buf[]; };
    uniform int u_max_view_per_tilemap;
    int tileOffsetLds(ivec2 tile, int lod)
    {
      int base = 0, size = \(tilemapRes);
      for (int l = 0; l < lod; l++) { base += size * size; size >>= 1; }
      return base + tile.y * size + tile.x;
    }
    bool threadMask(ivec2 tile_co, int lod)
    {
      int lod_size = \(tilemapRes) >> lod;
      return tile_co.x < lod_size && tile_co.y < lod_size;
    }
    void main()
    {
      int tilemapBase = int(gl_WorkGroupID.x) * \(tilesPerTilemap);
      ivec2 tile_co = ivec2(gl_LocalInvocationID.xy);
      uint local_tile_index = gl_LocalInvocationIndex;

      if (local_tile_index == 0u) { force_base_page = 0u; }
      barrier();

      for (int lod = 0; lod <= \(lodMax); lod++)
      {
        if (threadMask(tile_co, lod))
        {
          int tile_offset = tileOffsetLds(tile_co, lod);
          uint tile_data = tiles_buf[tilemapBase + tile_offset];
          if ((tile_data & 0x80000000u) == 0u) { tile_data &= ~0x20002000u; }
          else { force_base_page = 1u; }
          tile_data &= ~(0x40000000u | 0x10000000u);
          tiles_local[tile_offset] = tile_data;
        }
      }

      for (int lod = 1; lod <= \(lodMax); lod++)
      {
        barrier();
        if (threadMask(tile_co, lod))
        {
          ivec2 prevCo = tile_co * 2;
          int prevLod = lod - 1;
          int t0 = tileOffsetLds(prevCo + ivec2(0, 0), prevLod);
          int t1 = tileOffsetLds(prevCo + ivec2(1, 0), prevLod);
          int t2 = tileOffsetLds(prevCo + ivec2(0, 1), prevLod);
          int t3 = tileOffsetLds(prevCo + ivec2(1, 1), prevLod);
          bool isMasked = ((tiles_local[t0] & tiles_local[t1] & tiles_local[t2] & tiles_local[t3])
                          & 0x80000000u) != 0u;
          int tile_offset = tileOffsetLds(tile_co, lod);
          if (isMasked)
          {
            tiles_local[tile_offset] |= 0x80000000u;
            tiles_local[tile_offset] &= ~0x20002000u;
            tiles_local[tile_offset] |= 0x40000000u;
            tiles_local[tile_offset] |= 0x10000000u;
          }
        }
      }

      if (local_tile_index == 0u) { levels_rendered = 0u; }
      barrier();
      for (int lod = 0; lod <= \(lodMax); lod++)
      {
        if (threadMask(tile_co, lod))
        {
          int tile_offset = tileOffsetLds(tile_co, lod);
          if ((tiles_local[tile_offset] & 0x20002000u) != 0u) { atomicOr(levels_rendered, 1u << lod); }
        }
      }
      barrier();

      if (int(bitCount(levels_rendered)) > u_max_view_per_tilemap)
      {
        int max_lod = findMSB(levels_rendered);
        for (int i = 1; i < u_max_view_per_tilemap; i++)
        {
          max_lod = findMSB(levels_rendered & ~(0xFFFFFFFFu << uint(max_lod)));
        }
        for (int lod = 0; lod < max_lod; lod++)
        {
          if (threadMask(tile_co, lod))
          {
            int tile_offset = tileOffsetLds(tile_co, lod);
            if ((tiles_local[tile_offset] & 0x20002000u) != 0u)
            {
              tiles_local[tile_offset] |= (0x10000000u | 0x40000000u);
              int bottom_offset = tileOffsetLds(tile_co >> (max_lod - lod), max_lod);
              atomicOr(tiles_local[bottom_offset], 0x40000000u);
              atomicAnd(tiles_local[bottom_offset], ~0x10000000u);
            }
          }
        }
      }

      barrier();

      if (local_tile_index == 0u)
      {
        if (force_base_page != 0u)
        {
          int tile_offset = tileOffsetLds(ivec2(0), \(lodMax));
          tiles_local[tile_offset] |= 0x40000000u;
          tiles_local[tile_offset] &= ~0x10000000u;
        }
      }

      for (int lod = 0; lod <= \(lodMax); lod++)
      {
        if (threadMask(tile_co, lod))
        {
          int tile_lds = tileOffsetLds(tile_co, lod);
          if ((tiles_local[tile_lds] & 0x40000000u) != 0u)
          {
            int tile_offset = tile_lds;
            if ((tiles_local[tile_lds] & 0x10000000u) != 0u) { tiles_buf[tilemapBase + tile_offset] &= ~0x80000000u; }
            else { tiles_buf[tilemapBase + tile_offset] |= 0x80000000u; }
          }
        }
      }
    }
    """

  static let maskLodMSL = """
    #include <metal_stdlib>
    using namespace metal;
    inline int tileOffsetLds(int2 tile, int lod)
    {
      int base = 0, size = \(tilemapRes);
      for (int l = 0; l < lod; l++) { base += size * size; size >>= 1; }
      return base + tile.y * size + tile.x;
    }
    inline bool threadMask(int2 tile_co, int lod)
    {
      int lod_size = \(tilemapRes) >> lod;
      return tile_co.x < lod_size && tile_co.y < lod_size;
    }
    struct U { int max_view_per_tilemap; };
    kernel void compute_main(constant U& U_ [[buffer(0)]],
                             device uint* tiles_buf [[buffer(1)]],
                             uint2 tilemap_id [[threadgroup_position_in_grid]],
                             uint2 tile_co_u [[thread_position_in_threadgroup]],
                             uint local_tile_index [[thread_index_in_threadgroup]])
    {
      threadgroup uint tiles_local[\(tilesPerTilemap)];
      threadgroup atomic_uint levels_rendered;
      threadgroup uint force_base_page;

      int tilemapBase = int(tilemap_id.x) * \(tilesPerTilemap);
      int2 tile_co = int2(tile_co_u);

      if (local_tile_index == 0u) { force_base_page = 0u; }
      threadgroup_barrier(mem_flags::mem_threadgroup);

      for (int lod = 0; lod <= \(lodMax); lod++)
      {
        if (threadMask(tile_co, lod))
        {
          int tile_offset = tileOffsetLds(tile_co, lod);
          uint tile_data = tiles_buf[tilemapBase + tile_offset];
          if ((tile_data & 0x80000000u) == 0u) { tile_data &= ~0x20002000u; }
          else { force_base_page = 1u; }
          tile_data &= ~(0x40000000u | 0x10000000u);
          tiles_local[tile_offset] = tile_data;
        }
      }

      for (int lod = 1; lod <= \(lodMax); lod++)
      {
        threadgroup_barrier(mem_flags::mem_threadgroup);
        if (threadMask(tile_co, lod))
        {
          int2 prevCo = tile_co * 2;
          int prevLod = lod - 1;
          int t0 = tileOffsetLds(prevCo + int2(0, 0), prevLod);
          int t1 = tileOffsetLds(prevCo + int2(1, 0), prevLod);
          int t2 = tileOffsetLds(prevCo + int2(0, 1), prevLod);
          int t3 = tileOffsetLds(prevCo + int2(1, 1), prevLod);
          bool isMasked = ((tiles_local[t0] & tiles_local[t1] & tiles_local[t2] & tiles_local[t3])
                          & 0x80000000u) != 0u;
          int tile_offset = tileOffsetLds(tile_co, lod);
          if (isMasked)
          {
            tiles_local[tile_offset] |= 0x80000000u;
            tiles_local[tile_offset] &= ~0x20002000u;
            tiles_local[tile_offset] |= 0x40000000u;
            tiles_local[tile_offset] |= 0x10000000u;
          }
        }
      }

      if (local_tile_index == 0u) { atomic_store_explicit(&levels_rendered, 0u, memory_order_relaxed); }
      threadgroup_barrier(mem_flags::mem_threadgroup);
      for (int lod = 0; lod <= \(lodMax); lod++)
      {
        if (threadMask(tile_co, lod))
        {
          int tile_offset = tileOffsetLds(tile_co, lod);
          if ((tiles_local[tile_offset] & 0x20002000u) != 0u)
          {
            atomic_fetch_or_explicit(&levels_rendered, 1u << uint(lod), memory_order_relaxed);
          }
        }
      }
      threadgroup_barrier(mem_flags::mem_threadgroup);

      uint levels_rendered_val = atomic_load_explicit(&levels_rendered, memory_order_relaxed);
      if (int(popcount(levels_rendered_val)) > U_.max_view_per_tilemap)
      {
        int max_lod = 31 - clz(levels_rendered_val);
        for (int i = 1; i < U_.max_view_per_tilemap; i++)
        {
          uint masked = levels_rendered_val & ~(0xFFFFFFFFu << uint(max_lod));
          max_lod = (masked == 0u) ? 0 : (31 - clz(masked));
        }
        for (int lod = 0; lod < max_lod; lod++)
        {
          if (threadMask(tile_co, lod))
          {
            int tile_offset = tileOffsetLds(tile_co, lod);
            if ((tiles_local[tile_offset] & 0x20002000u) != 0u)
            {
              tiles_local[tile_offset] |= (0x10000000u | 0x40000000u);
              int bottom_offset = tileOffsetLds(tile_co >> (max_lod - lod), max_lod);
              tiles_local[bottom_offset] |= 0x40000000u;
              tiles_local[bottom_offset] &= ~0x10000000u;
            }
          }
        }
      }

      threadgroup_barrier(mem_flags::mem_threadgroup);

      if (local_tile_index == 0u)
      {
        if (force_base_page != 0u)
        {
          int tile_offset = tileOffsetLds(int2(0), \(lodMax));
          tiles_local[tile_offset] |= 0x40000000u;
          tiles_local[tile_offset] &= ~0x10000000u;
        }
      }

      for (int lod = 0; lod <= \(lodMax); lod++)
      {
        if (threadMask(tile_co, lod))
        {
          int tile_lds = tileOffsetLds(tile_co, lod);
          if ((tiles_local[tile_lds] & 0x40000000u) != 0u)
          {
            if ((tiles_local[tile_lds] & 0x10000000u) != 0u) { tiles_buf[tilemapBase + tile_lds] &= ~0x80000000u; }
            else { tiles_buf[tilemapBase + tile_lds] |= 0x80000000u; }
          }
        }
      }
    }
    """
}
