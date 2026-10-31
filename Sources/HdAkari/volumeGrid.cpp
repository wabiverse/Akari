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

#include <openvdb/openvdb.h>
#include <openvdb/io/File.h>

#include "HdAkari/volumeGrid.h"

#include <algorithm>
#include <cmath>
#include <mutex>

PXR_NAMESPACE_OPEN_SCOPE

HdAkariVolumeGrid *
HdAkariLoadVolumeGrid(std::string const &path, std::string const &gridName, int maxResolution)
{
  static std::once_flag once;
  std::call_once(once, [] { openvdb::initialize(); });

  openvdb::FloatGrid::Ptr grid;
  try {
    openvdb::io::File file(path);
    file.open(false);
    openvdb::GridBase::Ptr base;
    if (!gridName.empty() && file.hasGrid(gridName)) base = file.readGrid(gridName);
    if (!base) {
      for (auto it = file.beginName(); it != file.endName(); ++it) {
        openvdb::GridBase::Ptr candidate = file.readGrid(it.gridName());
        if (candidate && candidate->isType<openvdb::FloatGrid>()) { base = candidate; break; }
      }
    }
    file.close();
    grid = openvdb::gridPtrCast<openvdb::FloatGrid>(base);
  } catch (openvdb::Exception const &) {
    return nullptr;
  }
  if (!grid) return nullptr;

  const openvdb::CoordBBox box = grid->evalActiveVoxelBoundingBox();
  if (box.empty()) return nullptr;
  const openvdb::Coord dim = box.dim();
  const int longest = std::max(dim.x(), std::max(dim.y(), dim.z()));
  const int stride = std::max(1, int(std::ceil(double(longest) / double(std::max(maxResolution, 8)))));

  auto *out = new HdAkariVolumeGrid;
  out->width = (dim.x() + stride - 1) / stride;
  out->height = (dim.y() + stride - 1) / stride;
  out->depth = (dim.z() + stride - 1) / stride;
  out->voxels.assign(size_t(out->width) * out->height * out->depth, 0.0f);

  const openvdb::Coord lo = box.min();
  for (auto it = grid->cbeginValueOn(); it; ++it) {
    openvdb::CoordBBox span;
    it.getBoundingBox(span);
    const float v = *it;
    for (int z = span.min().z(); z <= span.max().z(); ++z)
      for (int y = span.min().y(); y <= span.max().y(); ++y)
        for (int x = span.min().x(); x <= span.max().x(); ++x) {
          const int ox = (x - lo.x()) / stride, oy = (y - lo.y()) / stride, oz = (z - lo.z()) / stride;
          out->voxels[(size_t(oz) * out->height + oy) * out->width + ox] += v;
        }
  }
  const float norm = 1.0f / float(stride * stride * stride);
  float peak = 0.0f;
  for (float &v : out->voxels) { v = std::max(v * norm, 0.0f); peak = std::max(peak, v); }
  out->maxValue = peak;

  const openvdb::math::Transform &xf = grid->transform();
  const openvdb::Vec3d origin = xf.indexToWorld(openvdb::Vec3d(lo.x() - 0.5, lo.y() - 0.5, lo.z() - 0.5));
  const openvdb::Vec3d ex = xf.indexToWorld(openvdb::Vec3d(lo.x() - 0.5 + out->width * stride, lo.y() - 0.5, lo.z() - 0.5)) - origin;
  const openvdb::Vec3d ey = xf.indexToWorld(openvdb::Vec3d(lo.x() - 0.5, lo.y() - 0.5 + out->height * stride, lo.z() - 0.5)) - origin;
  const openvdb::Vec3d ez = xf.indexToWorld(openvdb::Vec3d(lo.x() - 0.5, lo.y() - 0.5, lo.z() - 0.5 + out->depth * stride)) - origin;
  const double m[16] = { ex.x(), ex.y(), ex.z(), 0.0,
                         ey.x(), ey.y(), ey.z(), 0.0,
                         ez.x(), ez.y(), ez.z(), 0.0,
                         origin.x(), origin.y(), origin.z(), 1.0 };
  std::copy(m, m + 16, out->localFromTexture);
  return out;
}

void
HdAkariFreeVolumeGrid(HdAkariVolumeGrid *grid)
{
  delete grid;
}

PXR_NAMESPACE_CLOSE_SCOPE
