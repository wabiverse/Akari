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
  static let commonGLSL = """
    uint shadow_page_pack(uvec3 page) { return (page.x << 0u) | (page.y << 3u) | (page.z << 6u); }
    uvec3 shadow_page_unpack(uint data)
    {
      return uvec3((data >> 0u) & 7u, (data >> 3u) & 7u, (data >> 6u) & 127u);
    }
    struct Tile { uvec3 page; uint cache_index; bool is_used, do_update, is_allocated, is_rendered, is_cached, is_dynamic; };
    Tile shadow_tile_unpack(uint data)
    {
      Tile t;
      t.page = shadow_page_unpack(data);
      t.cache_index = (data >> 14u) & 8191u;
      t.is_used = (data & 0x80000000u) != 0u;
      t.is_cached = (data & 0x08000000u) != 0u;
      t.is_allocated = (data & 0x10000000u) != 0u;
      t.is_rendered = (data & 0x40000000u) != 0u;
      t.do_update = (data & 0x20000000u) != 0u;
      t.is_dynamic = (data & 0x00002000u) != 0u;
      return t;
    }
    uint shadow_tile_pack(Tile t)
    {
      uint data = shadow_page_pack(t.page) & 8191u;
      data |= (t.cache_index & 8191u) << 14u;
      data |= t.is_used ? 0x80000000u : 0u;
      data |= t.is_allocated ? 0x10000000u : 0u;
      data |= t.is_cached ? 0x08000000u : 0u;
      data |= t.is_rendered ? 0x40000000u : 0u;
      data |= t.do_update ? 0x20000000u : 0u;
      data |= t.is_dynamic ? 0x00002000u : 0u;
      return data;
    }
    """

  static let freeOpsGLSL = """
    void page_free(inout Tile tile)
    {
      int index = atomicAdd(pages_info_buf[0], 1);
      if (index >= 0 && index < MAX_PAGE)
      {
        pages_free_buf[index] = shadow_page_pack(tile.page);
      }
      else
      {
        atomicAdd(pages_info_buf[0], -1);
      }
      tile.page = uvec3(7u, 7u, 127u);
      tile.is_cached = false;
      tile.is_allocated = false;
    }
    void page_cache_append(inout Tile tile, uint tile_index)
    {
      uint index = uint(atomicAdd(pages_info_buf[2], 1)) % uint(MAX_PAGE);
      if (pages_cached_buf[index].x != 0xFFFFFFFFu)
      {
        page_free(tile);
        return;
      }
      pages_cached_buf[index] = uvec2(shadow_page_pack(tile.page), tile_index);
      tile.page = uvec3(7u, 7u, 127u);
      tile.cache_index = index;
      tile.is_cached = true;
      tile.is_allocated = false;
    }
    void page_cache_remove(inout Tile tile)
    {
      uint index = tile.cache_index % uint(MAX_PAGE);
      uint entry = pages_cached_buf[index].x;
      tile.cache_index = 8191u;
      tile.is_cached = false;
      if (entry == 0xFFFFFFFFu)
      {
        tile.is_allocated = false;
        return;
      }
      tile.page = shadow_page_unpack(entry);
      tile.is_allocated = true;
      pages_cached_buf[index] = uvec2(0xFFFFFFFFu, 0xFFFFFFFFu);
    }
    """

  static func glslBuffers() -> String
  {
    """
    #version 430
    #define MAX_PAGE \(maxPage)
    layout(std430, binding = 0) buffer Tiles { uint tiles_buf[]; };
    layout(std430, binding = 1) buffer PagesFree { uint pages_free_buf[]; };
    layout(std430, binding = 2) buffer PagesInfo { int pages_info_buf[]; };
    layout(std430, binding = 3) buffer PagesCached { uvec2 pages_cached_buf[]; };
    \(commonGLSL)
    """
  }

  static let freeGLSL = glslBuffers() + freeOpsGLSL + """
    layout(local_size_x = \(tilemapRes * tilemapRes), local_size_y = 1, local_size_z = 1) in;
    void main()
    {
      int tilemapBase = int(gl_WorkGroupID.x) * \(tilesPerTilemap);
      uint local_tile = gl_LocalInvocationID.x;
      uint tile_start = 0u;
      int size = \(tilemapRes);
      for (int lod = 0; lod <= \(lodMax); ++lod)
      {
        uint lod_len = uint(size * size);
        if (local_tile < lod_len)
        {
          int tile_index = tilemapBase + int(tile_start + local_tile);
          Tile tile = shadow_tile_unpack(tiles_buf[tile_index]);
          bool is_orphaned = !tile.is_used && (tile.do_update || tile.is_dynamic);
          if (is_orphaned)
          {
            if (tile.is_cached) { page_cache_remove(tile); }
            if (tile.is_allocated) { page_free(tile); }
          }
          if (tile.is_used)
          {
            if (tile.is_cached) { page_cache_remove(tile); }
            if (!tile.is_allocated) { atomicAdd(pages_info_buf[1], 1); }
          }
          else
          {
            if (tile.is_allocated) { page_cache_append(tile, uint(tile_index)); }
          }
          tiles_buf[tile_index] = shadow_tile_pack(tile);
        }
        tile_start += lod_len;
        size >>= 1;
      }
    }
    """

  static let allocateGLSL = glslBuffers() + """
    layout(local_size_x = \(tilemapRes * tilemapRes), local_size_y = 1, local_size_z = 1) in;
    void main()
    {
      int tilemapBase = int(gl_WorkGroupID.x) * \(tilesPerTilemap);
      uint local_tile = gl_LocalInvocationID.x;
      uint tile_start = 0u;
      int size = \(tilemapRes);
      for (int lod = 0; lod <= \(lodMax); ++lod)
      {
        uint lod_len = uint(size * size);
        if (local_tile < lod_len)
        {
          int tile_index = tilemapBase + int(tile_start + local_tile);
          Tile tile = shadow_tile_unpack(tiles_buf[tile_index]);
          if (tile.is_used && !tile.is_allocated)
          {
            int index = atomicAdd(pages_info_buf[0], -1) - 1;
            if (index >= 0 && index < MAX_PAGE)
            {
              tile.page = shadow_page_unpack(pages_free_buf[index]);
              tile.is_allocated = true;
              tile.do_update = true;
              pages_free_buf[index] = 0xFFFFFFFFu;
            }
            else if (index < 0)
            {
              atomicAdd(pages_info_buf[0], 1);
            }
          }
          tiles_buf[tile_index] = shadow_tile_pack(tile);
        }
        tile_start += lod_len;
        size >>= 1;
      }
    }
    """

  static let defragOpsGLSL = """
    uint find_first_valid(uint src, uint dst)
    {
      for (uint i = src; i < dst; i++)
      {
        if (pages_cached_buf[i % uint(MAX_PAGE)].x != 0xFFFFFFFFu) return i;
      }
      return dst;
    }
    void free_cached_page(uint page_index)
    {
      uint tile_index = pages_cached_buf[page_index].y;
      Tile tile = shadow_tile_unpack(tiles_buf[tile_index]);
      page_cache_remove(tile);
      page_free(tile);
      tiles_buf[tile_index] = shadow_tile_pack(tile);
    }
    void page_cache_update_page_ref(uint page_index, uint new_page_index)
    {
      uint tile_index = pages_cached_buf[page_index].y;
      Tile tile = shadow_tile_unpack(tiles_buf[tile_index]);
      tile.cache_index = new_page_index % uint(MAX_PAGE);
      tiles_buf[tile_index] = shadow_tile_pack(tile);
    }
    """

  static let defragGLSL = glslBuffers() + freeOpsGLSL + defragOpsGLSL + """
    layout(local_size_x = 1, local_size_y = 1, local_size_z = 1) in;
    void main()
    {
      int additional_pages = pages_info_buf[1] - pages_info_buf[0];
      uint src = uint(pages_info_buf[3]);
      uint end = uint(pages_info_buf[4]);
      src = find_first_valid(src, end);
      for (; additional_pages > 0 && src < end; additional_pages--)
      {
        free_cached_page(src % uint(MAX_PAGE));
        src = find_first_valid(src, end);
      }
      bool is_empty = (src == end);
      if (!is_empty)
      {
        for (uint dst = end - 1u; dst > src; dst--)
        {
          if (pages_cached_buf[dst % uint(MAX_PAGE)].x != 0xFFFFFFFFu) continue;
          page_cache_update_page_ref(src % uint(MAX_PAGE), dst % uint(MAX_PAGE));
          pages_cached_buf[dst % uint(MAX_PAGE)] = pages_cached_buf[src % uint(MAX_PAGE)];
          pages_cached_buf[src % uint(MAX_PAGE)] = uvec2(0xFFFFFFFFu, 0xFFFFFFFFu);
          src = find_first_valid(src, dst);
        }
      }
      end = uint(pages_info_buf[2]);
      for (; additional_pages > 0 && src < end; src++)
      {
        uint slot = src % uint(MAX_PAGE);
        if (pages_cached_buf[slot].x == 0xFFFFFFFFu) continue;
        free_cached_page(slot);
        additional_pages--;
      }
      pages_info_buf[3] = int(src);
      pages_info_buf[4] = int(end);
      pages_info_buf[1] = 0;
      if (uint(pages_info_buf[3]) > uint(MAX_PAGE))
      {
        pages_info_buf[2] -= MAX_PAGE;
        pages_info_buf[3] -= MAX_PAGE;
        pages_info_buf[4] -= MAX_PAGE;
      }
    }
    """

  static let commonMSL = """
    struct Tile { uint3 page; uint cache_index; bool is_used, do_update, is_allocated, is_rendered, is_cached, is_dynamic; };
    inline uint shadow_page_pack(uint3 page) { return (page.x << 0u) | (page.y << 3u) | (page.z << 6u); }
    inline uint3 shadow_page_unpack(uint data)
    {
      return uint3((data >> 0u) & 7u, (data >> 3u) & 7u, (data >> 6u) & 127u);
    }
    inline Tile shadow_tile_unpack(uint data)
    {
      Tile t;
      t.page = shadow_page_unpack(data);
      t.cache_index = (data >> 14u) & 8191u;
      t.is_used = (data & 0x80000000u) != 0u;
      t.is_cached = (data & 0x08000000u) != 0u;
      t.is_allocated = (data & 0x10000000u) != 0u;
      t.is_rendered = (data & 0x40000000u) != 0u;
      t.do_update = (data & 0x20000000u) != 0u;
      t.is_dynamic = (data & 0x00002000u) != 0u;
      return t;
    }
    inline uint shadow_tile_pack(thread const Tile& t)
    {
      uint data = shadow_page_pack(t.page) & 8191u;
      data |= (t.cache_index & 8191u) << 14u;
      data |= t.is_used ? 0x80000000u : 0u;
      data |= t.is_allocated ? 0x10000000u : 0u;
      data |= t.is_cached ? 0x08000000u : 0u;
      data |= t.is_rendered ? 0x40000000u : 0u;
      data |= t.do_update ? 0x20000000u : 0u;
      data |= t.is_dynamic ? 0x00002000u : 0u;
      return data;
    }
    """

  static let freeOpsMSL = """
    inline void page_free(thread Tile& tile, device uint* pages_free_buf, device atomic_int* pages_info_buf)
    {
      int index = atomic_fetch_add_explicit(&pages_info_buf[0], 1, memory_order_relaxed);
      if (index >= 0 && index < MAX_PAGE)
      {
        pages_free_buf[index] = shadow_page_pack(tile.page);
      }
      else
      {
        atomic_fetch_add_explicit(&pages_info_buf[0], -1, memory_order_relaxed);
      }
      tile.page = uint3(7u, 7u, 127u);
      tile.is_cached = false;
      tile.is_allocated = false;
    }
    inline void page_cache_append(thread Tile& tile, uint tile_index,
                                  device uint2* pages_cached_buf,
                                  device uint* pages_free_buf,
                                  device atomic_int* pages_info_buf)
    {
      uint index = uint(atomic_fetch_add_explicit(&pages_info_buf[2], 1, memory_order_relaxed)) % uint(MAX_PAGE);
      if (pages_cached_buf[index].x != 0xFFFFFFFFu)
      {
        page_free(tile, pages_free_buf, pages_info_buf);
        return;
      }
      pages_cached_buf[index] = uint2(shadow_page_pack(tile.page), tile_index);
      tile.page = uint3(7u, 7u, 127u);
      tile.cache_index = index;
      tile.is_cached = true;
      tile.is_allocated = false;
    }
    inline void page_cache_remove(thread Tile& tile, device uint2* pages_cached_buf)
    {
      uint index = tile.cache_index % uint(MAX_PAGE);
      uint entry = pages_cached_buf[index].x;
      tile.cache_index = 8191u;
      tile.is_cached = false;
      if (entry == 0xFFFFFFFFu)
      {
        tile.is_allocated = false;
        return;
      }
      tile.page = shadow_page_unpack(entry);
      tile.is_allocated = true;
      pages_cached_buf[index] = uint2(0xFFFFFFFFu, 0xFFFFFFFFu);
    }
    """

  static func mslPrelude(_ includeCacheOps: Bool) -> String
  {
    "#include <metal_stdlib>\nusing namespace metal;\n#define MAX_PAGE \(maxPage)\n" + commonMSL
      + (includeCacheOps ? freeOpsMSL : "")
  }

  static let freeMSL = mslPrelude(true) + """
    kernel void compute_main(device uint* tiles_buf [[buffer(1)]],
                             device uint* pages_free_buf [[buffer(2)]],
                             device atomic_int* pages_info_buf [[buffer(3)]],
                             device uint2* pages_cached_buf [[buffer(4)]],
                             uint tilemap_id [[threadgroup_position_in_grid]],
                             uint local_tile [[thread_position_in_threadgroup]])
    {
      int tilemapBase = int(tilemap_id) * \(tilesPerTilemap);
      uint tile_start = 0u;
      int size = \(tilemapRes);
      for (int lod = 0; lod <= \(lodMax); ++lod)
      {
        uint lod_len = uint(size * size);
        if (local_tile < lod_len)
        {
          int tile_index = tilemapBase + int(tile_start + local_tile);
          Tile tile = shadow_tile_unpack(tiles_buf[tile_index]);
          bool is_orphaned = !tile.is_used && (tile.do_update || tile.is_dynamic);
          if (is_orphaned)
          {
            if (tile.is_cached) { page_cache_remove(tile, pages_cached_buf); }
            if (tile.is_allocated) { page_free(tile, pages_free_buf, pages_info_buf); }
          }
          if (tile.is_used)
          {
            if (tile.is_cached) { page_cache_remove(tile, pages_cached_buf); }
            if (!tile.is_allocated) { atomic_fetch_add_explicit(&pages_info_buf[1], 1, memory_order_relaxed); }
          }
          else
          {
            if (tile.is_allocated)
            {
              page_cache_append(tile, uint(tile_index),
                                pages_cached_buf,
                                pages_free_buf,
                                pages_info_buf);
            }
          }
          tiles_buf[tile_index] = shadow_tile_pack(tile);
        }
        tile_start += lod_len;
        size >>= 1;
      }
    }
    """

  static let allocateMSL = mslPrelude(false) + """
    kernel void compute_main(device uint* tiles_buf [[buffer(1)]],
                             device uint* pages_free_buf [[buffer(2)]],
                             device atomic_int* pages_info_buf [[buffer(3)]],
                             device uint2* pages_cached_buf [[buffer(4)]],
                             uint tilemap_id [[threadgroup_position_in_grid]],
                             uint local_tile [[thread_position_in_threadgroup]])
    {
      int tilemapBase = int(tilemap_id) * \(tilesPerTilemap);
      uint tile_start = 0u;
      int size = \(tilemapRes);
      for (int lod = 0; lod <= \(lodMax); ++lod)
      {
        uint lod_len = uint(size * size);
        if (local_tile < lod_len)
        {
          int tile_index = tilemapBase + int(tile_start + local_tile);
          Tile tile = shadow_tile_unpack(tiles_buf[tile_index]);
          if (tile.is_used && !tile.is_allocated)
          {
            int index = atomic_fetch_add_explicit(&pages_info_buf[0], -1, memory_order_relaxed) - 1;
            if (index >= 0 && index < MAX_PAGE)
            {
              tile.page = shadow_page_unpack(pages_free_buf[index]);
              tile.is_allocated = true;
              tile.do_update = true;
              pages_free_buf[index] = 0xFFFFFFFFu;
            }
            else if (index < 0)
            {
              atomic_fetch_add_explicit(&pages_info_buf[0], 1, memory_order_relaxed);
            }
          }
          tiles_buf[tile_index] = shadow_tile_pack(tile);
        }
        tile_start += lod_len;
        size >>= 1;
      }
    }
    """

  static let defragOpsMSL = """
    inline uint find_first_valid(uint src, uint dst, device uint2* pages_cached_buf)
    {
      for (uint i = src; i < dst; i++)
      {
        if (pages_cached_buf[i % uint(MAX_PAGE)].x != 0xFFFFFFFFu) return i;
      }
      return dst;
    }
    inline void free_cached_page(uint page_index, device uint* tiles_buf, device uint2* pages_cached_buf,
                                 device uint* pages_free_buf, device atomic_int* pages_info_buf)
    {
      uint tile_index = pages_cached_buf[page_index].y;
      Tile tile = shadow_tile_unpack(tiles_buf[tile_index]);
      page_cache_remove(tile, pages_cached_buf);
      page_free(tile, pages_free_buf, pages_info_buf);
      tiles_buf[tile_index] = shadow_tile_pack(tile);
    }
    inline void page_cache_update_page_ref(uint page_index, uint new_page_index,
                                           device uint* tiles_buf, device uint2* pages_cached_buf)
    {
      uint tile_index = pages_cached_buf[page_index].y;
      Tile tile = shadow_tile_unpack(tiles_buf[tile_index]);
      tile.cache_index = new_page_index % uint(MAX_PAGE);
      tiles_buf[tile_index] = shadow_tile_pack(tile);
    }
    """

  static let defragMSL = mslPrelude(true) + defragOpsMSL + """
    kernel void compute_main(device uint* tiles_buf [[buffer(1)]],
                             device uint* pages_free_buf [[buffer(2)]],
                             device atomic_int* pages_info_buf [[buffer(3)]],
                             device uint2* pages_cached_buf [[buffer(4)]])
    {
      int additional_pages = atomic_load_explicit(&pages_info_buf[1], memory_order_relaxed)
                            - atomic_load_explicit(&pages_info_buf[0], memory_order_relaxed);
      uint src = uint(atomic_load_explicit(&pages_info_buf[3], memory_order_relaxed));
      uint end = uint(atomic_load_explicit(&pages_info_buf[4], memory_order_relaxed));
      src = find_first_valid(src, end, pages_cached_buf);
      for (; additional_pages > 0 && src < end; additional_pages--)
      {
        free_cached_page(src % uint(MAX_PAGE), tiles_buf, pages_cached_buf, pages_free_buf, pages_info_buf);
        src = find_first_valid(src, end, pages_cached_buf);
      }
      bool is_empty = (src == end);
      if (!is_empty)
      {
        for (uint dst = end - 1u; dst > src; dst--)
        {
          if (pages_cached_buf[dst % uint(MAX_PAGE)].x != 0xFFFFFFFFu) continue;
          page_cache_update_page_ref(src % uint(MAX_PAGE), dst % uint(MAX_PAGE), tiles_buf, pages_cached_buf);
          pages_cached_buf[dst % uint(MAX_PAGE)] = pages_cached_buf[src % uint(MAX_PAGE)];
          pages_cached_buf[src % uint(MAX_PAGE)] = uint2(0xFFFFFFFFu, 0xFFFFFFFFu);
          src = find_first_valid(src, dst, pages_cached_buf);
        }
      }
      end = uint(atomic_load_explicit(&pages_info_buf[2], memory_order_relaxed));
      for (; additional_pages > 0 && src < end; src++)
      {
        uint slot = src % uint(MAX_PAGE);
        if (pages_cached_buf[slot].x == 0xFFFFFFFFu) continue;
        free_cached_page(slot, tiles_buf, pages_cached_buf, pages_free_buf, pages_info_buf);
        additional_pages--;
      }
      atomic_store_explicit(&pages_info_buf[3], int(src), memory_order_relaxed);
      atomic_store_explicit(&pages_info_buf[4], int(end), memory_order_relaxed);
      atomic_store_explicit(&pages_info_buf[1], 0, memory_order_relaxed);
      if (uint(src) > uint(MAX_PAGE))
      {
        atomic_fetch_add_explicit(&pages_info_buf[2], -int(MAX_PAGE), memory_order_relaxed);
        atomic_fetch_add_explicit(&pages_info_buf[3], -int(MAX_PAGE), memory_order_relaxed);
        atomic_fetch_add_explicit(&pages_info_buf[4], -int(MAX_PAGE), memory_order_relaxed);
      }
    }
    """

  /// A tile is resident once drawn into the page it still owns.
  static let pageTableBody = """
      int slot = index / \(tilesPerTilemap);
      int local = index % \(tilesPerTilemap);
      uint packed = tiles_buf[index];
      bool resident = (packed & 0x80000000u) != 0u
                   && (packed & 0x10000000u) != 0u
                   && ((packed & 0x20002000u) == 0u
                       || (packed & 0x40000000u) != 0u);
      bool to_render = (packed & 0x80000000u) != 0u
                    && (packed & 0x10000000u) != 0u
                    && (packed & 0x20002000u) != 0u;
      bool full_render = to_render && (packed & 0x20000000u) != 0u;
      int page = int((packed >> 6u) & 127u) * \(pagePackRadix)
               + int(packed & 7u) + int((packed >> 3u) & 7u) * 8;
      vec4 entry = resident
        ? vec4(float(page / \(pagesPerLayer)), float(page % \(pagesPerLayer)), 1.0, float(page))
        : vec4(0.0);
    """

  /// The per view indirection the surface shader reads.
  static let renderMapBody = """
      if (local < \(tilemapRes * tilemapRes))
      {
          for (int view = 0; view < \(maxDirectionalTilemaps); ++view)
        {
          if (slot_of_view[view] != slot) { continue; }
          render_map[view * \(tilemapRes * tilemapRes) + local] =
            to_render ? uint(page) : 0xFFFFFFFFu;
          render_map_static[view * \(tilemapRes * tilemapRes) + local] =
            full_render ? uint(page) : 0xFFFFFFFFu;
        }
      }
      if (slot < \(maxPunctualTilemaps))
      {
        int lod = 0, lodBase = 0, size = \(tilemapRes);
        while (lod < \(lodMax) && local >= lodBase + size * size) { lodBase += size * size; size >>= 1; ++lod; }
        int rel = local - lodBase;
        int view = \(punctualViewBase) + slot * \(lodCount) + lod;
        render_map[view * \(tilemapRes * tilemapRes) + (rel / size) * \(tilemapRes) + rel % size] =
          to_render ? uint(page) : 0xFFFFFFFFu;
        render_map_static[view * \(tilemapRes * tilemapRes) + (rel / size) * \(tilemapRes) + rel % size] =
          full_render ? uint(page) : 0xFFFFFFFFu;
      }
    """

  static let pageTableGLSL = """
    #version 430
    layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
    layout(std430, binding = 0) buffer Tiles { uint tiles_buf[]; };
    layout(std430, binding = 2) buffer RenderMap { uint render_map[]; };
    layout(std430, binding = 3) buffer SlotOfView { int slot_of_view[]; };
    layout(std430, binding = 4) buffer RenderMapStatic { uint render_map_static[]; };
    layout(rgba16f, binding = 0) uniform writeonly image2D u_pageTable;
    void main()
    {
      int index = int(gl_GlobalInvocationID.x);
      if (index >= \(maxTiles)) return;
      \(pageTableBody)
      imageStore(u_pageTable, ivec2(local, slot), entry);
      \(renderMapBody)
    }
    """

  static let pageTableMSL = """
    #include <metal_stdlib>
    using namespace metal;
    #define vec2 float2
    #define vec4 float4
    kernel void compute_main(device uint* tiles_buf [[buffer(1)]],
                             device uint* render_map [[buffer(3)]],
                             device int* slot_of_view [[buffer(4)]],
                             device uint* render_map_static [[buffer(5)]],
                             texture2d<float, access::write> u_pageTable [[texture(0)]],
                             uint gid [[thread_position_in_grid]])
    {
      int index = int(gid);
      if (index >= \(maxTiles)) return;
      \(pageTableBody)
      u_pageTable.write(entry, uint2(local, slot));
      \(renderMapBody)
    }
    """

  static let pageClearBody = """
      int page = int(clear_list[gid.z]);
      int layer = page / \(pagesPerLayer);
      int col = page % \(pagesPerLayer);
      int2 texel = int2(col * \(pageResolution) + int(gid.x), int(gid.y));
    """

  /// Sets whether a toRender tile has been rendered of each drawn view.
  static let retireDrawnBody = """
      if (gid >= \(maxViews * tilemapRes * tilemapRes)u) return;
      int view = int(gid / \(tilemapRes * tilemapRes)u);
      if (drawn[view] == 0) return;
      uint rect = render_rect[view];
      if (rect == 0u) return;
      int local = int(gid % \(tilemapRes * tilemapRes)u);
      int x = local % \(tilemapRes), y = local / \(tilemapRes);
      if (x < int(rect & 31u) || y < int((rect >> 5) & 31u) ||
          x > int((rect >> 10) & 31u) || y > int((rect >> 15) & 31u)) return;
      int size = \(tilemapRes);
      int base;
      if (view < \(punctualViewBase))
      {
        int slot = slot_of_view[view];
        if (slot < 0) return;
        base = slot * \(tilesPerTilemap);
      }
      else
      {
        int pv = view - \(punctualViewBase);
        base = (pv / \(lodCount)) * \(tilesPerTilemap);
        for (int l = 0; l < pv % \(lodCount); ++l) { base += size * size; size >>= 1; }
      }
      if (x >= size || y >= size) return;
      uint index = uint(base + y * size + x);
      uint packed = tiles_buf[index];
      uint resident = \(flagIsUsed | flagIsAllocated)u;
      if ((packed & resident) == resident && (packed & \(flagDoUpdate | flagDynamicUpdate)u) != 0u)
      {
        tiles_buf[index] = packed | \(flagIsRendered)u;
      }
    """

  static let retireDrawnGLSL = """
    #version 430
    layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
    layout(std430, binding = 0) buffer Tiles { uint tiles_buf[]; };
    layout(std430, binding = 1) buffer SlotOfView { int slot_of_view[]; };
    layout(std430, binding = 2) buffer Drawn { int drawn[]; };
    layout(std430, binding = 3) buffer RenderRect { uint render_rect[]; };
    void main()
    {
      uint gid = gl_GlobalInvocationID.x;
      \(retireDrawnBody)
    }
    """

  static let retireDrawnMSL = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void compute_main(device uint* tiles_buf [[buffer(1)]],
                             device int* slot_of_view [[buffer(2)]],
                             device int* drawn [[buffer(3)]],
                             device uint* render_rect [[buffer(4)]],
                             uint3 gid3 [[thread_position_in_grid]])
    {
      uint gid = gid3.x;
      \(retireDrawnBody)
    }
    """

  static let cullBody = """
      int drawCount = PARAMS.x;
      if (int(gid) >= drawCount * PARAMS.y) return;
      int run = int(gid) / drawCount;
      int draw = int(gid) % drawCount;
      VEC3 lo = VEC3(bounds[draw * 6 + 0], bounds[draw * 6 + 1], bounds[draw * 6 + 2]);
      VEC3 hi = VEC3(bounds[draw * 6 + 3], bounds[draw * 6 + 4], bounds[draw * 6 + 5]);
      bool visible = false;
      for (int k = 0; k < \(maxAmplificationViews) && !visible; ++k)
      {
        int view = run_views[run * \(maxAmplificationViews) + k];
        if (view < 0) continue;
        uint rect = render_rect[view];
        if (rect == 0u) continue;
        float size = float(view >= \(punctualViewBase) ? (\(tilemapRes) >> ((view - \(punctualViewBase)) % \(lodCount)))
                                                       : \(tilemapRes));
        VEC2 rmin = VEC2(float(rect & 31u), float((rect >> 5u) & 31u)) / size * 2.0 - 1.0;
        VEC2 rmax = (VEC2(float((rect >> 10u) & 31u), float((rect >> 15u) & 31u)) + 1.0) / size * 2.0 - 1.0;
        int out0 = 0, out1 = 0, out2 = 0, out3 = 0, out4 = 0, out5 = 0;
        for (int c = 0; c < 8; ++c)
        {
          VEC4 p = XF(run * \(maxAmplificationViews) + k)
                 * VEC4((c & 1) != 0 ? hi.x : lo.x, (c & 2) != 0 ? hi.y : lo.y, (c & 4) != 0 ? hi.z : lo.z, 1.0);
          out0 += p.x < rmin.x * p.w ? 1 : 0;
          out1 += p.x > rmax.x * p.w ? 1 : 0;
          out2 += p.y < rmin.y * p.w ? 1 : 0;
          out3 += p.y > rmax.y * p.w ? 1 : 0;
          out4 += p.z < -p.w ? 1 : 0;
          out5 += p.z > p.w ? 1 : 0;
        }
        visible = out0 < 8 && out1 < 8 && out2 < 8 && out3 < 8 && out4 < 8 && out5 < 8;
      }
      visibility[gid] = visible ? 1u : 0u;
    """

  static let cullGLSL = """
    #version 430
    layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
    layout(std430, binding = 0) buffer Bounds { float bounds[]; };
    layout(std430, binding = 1) buffer RunViews { int run_views[]; };
    layout(std430, binding = 2) buffer RunXf { mat4 run_xf[]; };
    layout(std430, binding = 3) buffer RenderRect { uint render_rect[]; };
    layout(std430, binding = 4) buffer Visibility { uint visibility[]; };
    uniform ivec4 u_params;
    #define PARAMS u_params
    #define VEC2 vec2
    #define VEC3 vec3
    #define VEC4 vec4
    #define XF(i) run_xf[i]
    void main()
    {
      uint gid = gl_GlobalInvocationID.x;
      \(cullBody)
    }
    """

  static let cullMSL = """
    #include <metal_stdlib>
    using namespace metal;
    struct U { int4 params; };
    #define PARAMS u.params
    #define VEC2 float2
    #define VEC3 float3
    #define VEC4 float4
    #define XF(i) run_xf[i]
    kernel void compute_main(constant U& u [[buffer(0)]],
                             device const float* bounds [[buffer(1)]],
                             device const int* run_views [[buffer(2)]],
                             device const float4x4* run_xf [[buffer(3)]],
                             device const uint* render_rect [[buffer(4)]],
                             device uint* visibility [[buffer(5)]],
                             uint3 gid3 [[thread_position_in_grid]])
    {
      uint gid = gid3.x;
      \(cullBody)
    }
    """

  static let cullPunctualBody = """
      int drawCount = PARAMS.x;
      int draw = int(gid);
      if (draw >= drawCount) return;
      VEC3 lo = VEC3(bounds[draw * 6 + 0], bounds[draw * 6 + 1], bounds[draw * 6 + 2]);
      VEC3 hi = VEC3(bounds[draw * 6 + 3], bounds[draw * 6 + 4], bounds[draw * 6 + 5]);
      uint n = 0u;
      for (int k = 0; k < PARAMS.y; ++k)
      {
        int view = candidate_views[k];
        uint rect = render_rect[view];
        if (rect == 0u) continue;
        float size = float(\(tilemapRes) >> ((view - \(punctualViewBase)) % \(lodCount)));
        VEC2 rmin = VEC2(float(rect & 31u), float((rect >> 5u) & 31u)) / size * 2.0 - 1.0;
        VEC2 rmax = (VEC2(float((rect >> 10u) & 31u), float((rect >> 15u) & 31u)) + 1.0) / size * 2.0 - 1.0;
        int out0 = 0, out1 = 0, out2 = 0, out3 = 0, out4 = 0, out5 = 0;
        for (int c = 0; c < 8; ++c)
        {
          VEC4 p = XF(view)
                 * VEC4((c & 1) != 0 ? hi.x : lo.x, (c & 2) != 0 ? hi.y : lo.y, (c & 4) != 0 ? hi.z : lo.z, 1.0);
          out0 += p.x < rmin.x * p.w ? 1 : 0;
          out1 += p.x > rmax.x * p.w ? 1 : 0;
          out2 += p.y < rmin.y * p.w ? 1 : 0;
          out3 += p.y > rmax.y * p.w ? 1 : 0;
          out4 += p.z < -p.w ? 1 : 0;
          out5 += p.z > p.w ? 1 : 0;
        }
        if (out0 < 8 && out1 < 8 && out2 < 8 && out3 < 8 && out4 < 8 && out5 < 8)
        {
          instance_view[draw * \(maxPunctualViews) + int(n)] = uint(view);
          n += 1u;
        }
      }
      visibility[PARAMS.z + draw] = n;
    """

  static let cullPunctualGLSL = """
    #version 430
    layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
    layout(std430, binding = 0) buffer Bounds { float bounds[]; };
    layout(std430, binding = 1) buffer CandidateViews { int candidate_views[]; };
    layout(std430, binding = 2) buffer ViewXf { mat4 view_xf[]; };
    layout(std430, binding = 3) buffer RenderRect { uint render_rect[]; };
    layout(std430, binding = 4) buffer Visibility { uint visibility[]; };
    layout(std430, binding = 5) buffer InstanceView { uint instance_view[]; };
    uniform ivec4 u_params;
    #define PARAMS u_params
    #define VEC2 vec2
    #define VEC3 vec3
    #define VEC4 vec4
    #define XF(i) view_xf[i]
    void main()
    {
      uint gid = gl_GlobalInvocationID.x;
      \(cullPunctualBody)
    }
    """

  static let cullPunctualMSL = """
    #include <metal_stdlib>
    using namespace metal;
    struct U { int4 params; };
    #define PARAMS u.params
    #define VEC2 float2
    #define VEC3 float3
    #define VEC4 float4
    #define XF(i) view_xf[i]
    kernel void compute_main(constant U& u [[buffer(0)]],
                             device const float* bounds [[buffer(1)]],
                             device const int* candidate_views [[buffer(2)]],
                             device const float4x4* view_xf [[buffer(3)]],
                             device const uint* render_rect [[buffer(4)]],
                             device uint* visibility [[buffer(5)]],
                             device uint* instance_view [[buffer(6)]],
                             uint3 gid3 [[thread_position_in_grid]])
    {
      uint gid = gid3.x;
      \(cullPunctualBody)
    }
    """

  static let pageClearGLSL = """
    #version 430
    layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;
    layout(std430, binding = 0) buffer ClearList { uint clear_list[]; };
    layout(r32ui, binding = 0) uniform writeonly uimage2DArray u_atlas;
    void main()
    {
      ivec3 gid = ivec3(gl_GlobalInvocationID);
      \(pageClearBody)
      imageStore(u_atlas, ivec3(texel, layer), uvec4(0xFFFFFFFFu));
    }
    """

  static let pageClearMSL = """
    #include <metal_stdlib>
    using namespace metal;
    #define int2 int2
    kernel void compute_main(device uint* clear_list [[buffer(1)]],
                             texture2d_array<uint, access::write> u_atlas [[texture(0)]],
                             uint3 gid3 [[thread_position_in_grid]])
    {
      uint3 gid = gid3;
      \(pageClearBody)
      u_atlas.write(uint4(0xFFFFFFFF), uint2(texel), uint(layer));
    }
    """

  /// Copies each listed page's static depth into the atlas, the base the dynamic casters draw over.
  static let pageCopyGLSL = """
    #version 430
    layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;
    layout(std430, binding = 0) buffer ClearList { uint clear_list[]; };
    layout(r32ui, binding = 0) uniform readonly uimage2DArray u_static;
    layout(r32ui, binding = 1) uniform writeonly uimage2DArray u_atlas;
    void main()
    {
      ivec3 gid = ivec3(gl_GlobalInvocationID);
      \(pageClearBody)
      imageStore(u_atlas, ivec3(texel, layer), imageLoad(u_static, ivec3(texel, layer)));
    }
    """

  static let pageCopyMSL = """
    #include <metal_stdlib>
    using namespace metal;
    kernel void compute_main(device uint* clear_list [[buffer(1)]],
                             texture2d_array<uint, access::read> u_static [[texture(0)]],
                             texture2d_array<uint, access::write> u_atlas [[texture(1)]],
                             uint3 gid3 [[thread_position_in_grid]])
    {
      uint3 gid = gid3;
      \(pageClearBody)
      u_atlas.write(u_static.read(uint2(texel), uint(layer)), uint2(texel), uint(layer));
    }
    """
}
