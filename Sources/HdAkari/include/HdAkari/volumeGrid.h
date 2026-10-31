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
#ifndef HDAKARI_VOLUME_GRID_H
#define HDAKARI_VOLUME_GRID_H

#if __has_include(<pxr/pxrns.h>)
# include <pxr/pxrns.h>
#else
# include <pxr/pxr.h>
#endif

#include "HdAkari/api.h"

#include <string>
#include <vector>

PXR_NAMESPACE_OPEN_SCOPE

/// A VDB float grid resampled to a dense box of at most `maxResolution` voxels on its
/// longest side, box filtered. `localFromTexture` (row major, row vectors) takes the
/// box's [0, 1] texture coordinates to the grid's own space.
struct HdAkariVolumeGrid
{
  int width = 0;
  int height = 0;
  int depth = 0;
  std::vector<float> voxels;
  float maxValue = 0.0f;
  double localFromTexture[16] = {};
};

/// Reads `gridName` (or the first float grid) from the VDB at `path`, nullptr when it can't,
/// free it with HdAkariFreeVolumeGrid.
HDAKARI_API
HdAkariVolumeGrid *HdAkariLoadVolumeGrid(std::string const &path, std::string const &gridName, int maxResolution);

HDAKARI_API
void HdAkariFreeVolumeGrid(HdAkariVolumeGrid *grid);

inline int HdAkariVolumeGridWidth(HdAkariVolumeGrid const *grid) { return grid->width; }
inline int HdAkariVolumeGridHeight(HdAkariVolumeGrid const *grid) { return grid->height; }
inline int HdAkariVolumeGridDepth(HdAkariVolumeGrid const *grid) { return grid->depth; }
inline float const *HdAkariVolumeGridVoxels(HdAkariVolumeGrid const *grid) { return grid->voxels.data(); }
inline float HdAkariVolumeGridMax(HdAkariVolumeGrid const *grid) { return grid->maxValue; }
inline double HdAkariVolumeGridMatrix(HdAkariVolumeGrid const *grid, int i) { return grid->localFromTexture[i]; }

PXR_NAMESPACE_CLOSE_SCOPE

#endif // HDAKARI_VOLUME_GRID_H
