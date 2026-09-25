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
import Metal

extension Akari.ShadowAtlas
{
  /// LOD tiles per side of one tilemap's internal quadtree.
  static let tilemapRes = 32
  static let lodMax = 5
  static let lodCount = lodMax + 1
  /// 32*32 + 16*16 + 8*8 + 4*4 + 2*2 + 1*1.
  static let tilesPerTilemap: Int = {
    var total = 0, size = tilemapRes
    for _ in 0 ... lodMax
    {
      total += size * size; size >>= 1
    }
    return total
  }()

  /// The maximum number of concurrent output streams the GPU supports.
  static let maxAmplificationViews: Int = {
    guard let device = MTLCreateSystemDefaultDevice() else { return 2 }

    for maxViewports in [8, 4, 2]
    {
      if device.supportsVertexAmplificationCount(maxViewports)
      {
        return maxViewports
      }
    }

    return 2
  }()

  static let maxShadowViews = 512

  /// Bound by the deferred shader's fixed `u_pointLight*` slot count.
  static let maxPunctualLights = 4
  static let facesPerLight = 6
  /// Punctual tilemaps occupy slots [0, maxPunctualTilemaps).
  static let maxPunctualTilemaps = maxPunctualLights * facesPerLight
  static let maxDirectionalTilemaps = Int(ShadowSettings.maxLevels)
  static let directionalTilemapBase = maxPunctualTilemaps
  /// One render view per cube face and LOD, after the directional views.
  static let punctualViewBase = maxDirectionalTilemaps
  static let maxViews = maxDirectionalTilemaps + maxPunctualTilemaps * lodCount
  static let maxPunctualViews = maxPunctualTilemaps * lodCount
  static let maxTilemaps = maxPunctualTilemaps + maxDirectionalTilemaps
  static let maxTiles = maxTilemaps * tilesPerTilemap
  /// GPU chunk culling per run.
  static let maxRuns = (maxViews + 1) / 2

  /// Pages per atlas layer, one per amplified view.
  static let pagesPerLayer = maxAmplificationViews
  static let maxPage = 2048
  static let poolLayers = maxPage / pagesPerLayer
  /// Radix the page pack format's x/y fields use for a page id.
  static let pagePackRadix = 64
  /// Texels per page.
  static let pageResolution = 256
  static let pageShift = 8
  /// `pageResolution * tilemapRes`.
  static let shadowMapMaxRes = pageResolution * tilemapRes

  static let flagIsAllocated: UInt32 = 1 << 28
  static let flagDoUpdate: UInt32 = 1 << 29
  static let flagIsRendered: UInt32 = 1 << 30
  static let flagIsUsed: UInt32 = 1 << 31

  /// Frames in flight, the depth of every written ring.
  static let bufferRing = 3
  static let levelParamsStride = 16
  /// Texels per row of `data`.
  static let dataTextureWidth = 6

  static func flatIndex(tileX: Int, tileY: Int, lod: Int) -> Int
  {
    var base = 0, size = tilemapRes
    for _ in 0 ..< lod
    {
      base += size * size; size >>= 1
    }
    return base + tileY * size + tileX
  }

  static func decodeFlatIndex(_ index: Int) -> (lod: Int, x: Int, y: Int)
  {
    var remaining = index, size = tilemapRes, lod = 0
    while remaining >= size * size
    {
      remaining -= size * size
      size >>= 1
      lod += 1
    }
    return (lod, remaining % size, remaining / size)
  }
}
