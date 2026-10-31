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
#ifndef HDAKARI_PTEX_H
#define HDAKARI_PTEX_H

#if __has_include(<pxr/pxrns.h>)
# include <pxr/pxrns.h>
# include <Gf/vec3f.h>
# include <Vt/types.h>
#else
# include <pxr/pxr.h>
# include <pxr/base/gf/vec3f.h>
# include <pxr/base/vt/types.h>
#endif

#include "HdAkari/api.h"

#include <cstdint>
#include <string>

PXR_NAMESPACE_OPEN_SCOPE

/// The Ptex texture at `path`'s average color, linearized from sRGB, what
/// draws where its tiles haven't streamed, or can't.
HDAKARI_API GfVec3f HdAkariPtexAverageColor(std::string const &path);

/// Each face's resolution in the Ptex texture at `path`, ulog2 in the low
/// four bits and vlog2 the four above, empty with HdAkariPtexFaceColors.
HDAKARI_API VtIntArray HdAkariPtexFaceRes(std::string const &path);

/// The id streamed tiles of the Ptex texture at `path` key on, -1 when its
/// faces can't stream, not quads, or past what a key holds.
HDAKARI_API int HdAkariPtexMapId(std::string const &path);

/// Streamed tiles key on (map + 1) << 18 | face in the high 32 bits and
/// level << 16 | tile in the low, a level halving the face's resolution
/// each step and a tile 64 texels a side, row by row across the level.
constexpr int HdAkariPtexTileSize = 64;
constexpr int HdAkariPtexFaceBits = 18;

/// Queues tiles for HdAkariPtexTakeTiles, decoded on worker threads.
/// A key queued or decoded and not yet taken waits its turn just once.
HDAKARI_API void HdAkariPtexRequestTiles(uint64_t const *keys, int count);

/// Takes up to `maxTiles` decoded tiles whose texels fit `maxTexels`
/// each key, its interior width | height << 16, and the offset of its
/// (width + 2) x (height + 2) texels, bordered by its neighbours', 8 bit
/// rgba as the files store them. Returns how many it took.
HDAKARI_API int HdAkariPtexTakeTiles(uint64_t *keys, uint32_t *sizes, uint32_t *offsets, uint32_t *texels,
                                     int maxTiles, int maxTexels);

/// Tiles queued or decoding.
HDAKARI_API int HdAkariPtexPendingTiles();

PXR_NAMESPACE_CLOSE_SCOPE

#endif // HDAKARI_PTEX_H
