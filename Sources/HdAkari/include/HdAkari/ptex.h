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

/// the ptex texture's average color, linearized, drawn where its tiles haven't streamed
HDAKARI_API GfVec3f HdAkariPtexAverageColor(std::string const &path);

/// each face's resolution in the ptex texture, ulog2 in the low four bits and vlog2 above
HDAKARI_API VtIntArray HdAkariPtexFaceRes(std::string const &path);

/// the id streamed tiles of the ptex texture key on, -1 when its faces can't stream
HDAKARI_API int HdAkariPtexMapId(std::string const &path);

/// streamed tiles key on map, face, level and tile, each level halves the face and each tile is 64 texels a side
constexpr int HdAkariPtexTileSize = 64;
constexpr int HdAkariPtexFaceBits = 18;

/// queues tiles to decode on worker threads, a key already queued only waits once
HDAKARI_API void HdAkariPtexRequestTiles(uint64_t const *keys, int count);

/// takes up to `maxTiles` decoded tiles that fit `maxTexels`, each with its key, size and bordered texels in 8 bit rgba
HDAKARI_API int HdAkariPtexTakeTiles(uint64_t *keys, uint32_t *sizes, uint32_t *offsets, uint32_t *texels,
                                     int maxTiles, int maxTexels);

/// the tiles queued or decoding
HDAKARI_API int HdAkariPtexPendingTiles();

PXR_NAMESPACE_CLOSE_SCOPE

#endif // HDAKARI_PTEX_H
