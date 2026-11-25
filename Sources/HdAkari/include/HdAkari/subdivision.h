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

#ifndef HDAKARI_SUBDIVISION_H
#define HDAKARI_SUBDIVISION_H

#if __has_include(<pxr/pxrns.h>)
# include <pxr/pxrns.h>
# include <Hd/enums.h>
# include <Hd/meshTopology.h>
# include <Sdf/path.h>
# include <Tf/token.h>
# include <Vt/types.h>
# include <Vt/value.h>
#else
# include <pxr/pxr.h>
# include <pxr/imaging/hd/enums.h>
# include <pxr/imaging/hd/meshTopology.h>
# include <pxr/usd/sdf/path.h>
# include <pxr/base/tf/token.h>
# include <pxr/base/vt/types.h>
# include <pxr/base/vt/value.h>
#endif

#include <memory>
#include <utility>
#include <vector>

PXR_NAMESPACE_OPEN_SCOPE

class HdSceneDelegate;
struct HdAkariStencils;

/// a catmull clark, loop or bilinear mesh refined uniformly as hydra expects, with creases, corners, holes and primvars
class HdAkariSubdivision
{
public:
  /// refines a tagged topology `level` times, null when it can't, each face varying primvar refined by name
  static std::shared_ptr<HdAkariSubdivision> Create(HdMeshTopology const &topology, int level,
                                                    std::vector<std::pair<TfToken, VtIntArray>> const &faceVarying);

  ~HdAkariSubdivision();

  /// whether `scheme` is one opensubdiv refines
  static bool IsSubdivisionScheme(TfToken const &scheme);

  /// the refined faces with holes removed
  HdMeshTopology const &GetTopology() const { return _topology; }

  /// the cage face each refined face came from
  VtIntArray const &GetBaseFaces() const { return _baseFaces; }

  /// how many points the cage has
  size_t GetCagePointCount() const { return _cageVertices.size(); }

  /// refines a vertex or varying primvar onto the refined points
  bool RefineVertex(VtValue const &value, bool varying, VtValue *out) const;

  /// refines a face varying primvar to one value per refined face corner
  bool RefineFaceVarying(TfToken const &name, VtValue const &values, VtValue *out) const;

  /// the weights that build every refined point from the cage points, for refining on the gpu
  bool GetStencils(HdAkariStencils *out) const;

  /// moves the cage points onto the limit surface so the cage can stand in for the refined mesh
  bool LimitCage(VtVec3fArray const &cagePoints, VtVec3fArray *out) const;

private:
  HdAkariSubdivision() = default;

  struct Refiner;

  std::unique_ptr<Refiner> _refiner;
  HdMeshTopology _topology;
  VtIntArray _baseFaces;
  std::vector<TfToken> _channels;
  std::vector<int> _cageVertices;
};

/// reads a refined mesh's primvars by name
struct HdAkariRefinedPrimvars
{
  HdAkariSubdivision const *subdivision = nullptr;

  /// vertex and varying values come back per refined point, face varying per refined corner and uniform per cage face
  bool Get(HdSceneDelegate *sceneDelegate, SdfPath const &id, TfToken const &name,
           HdInterpolation interpolation, VtValue *out) const;
};

PXR_NAMESPACE_CLOSE_SCOPE

#endif // HDAKARI_SUBDIVISION_H
