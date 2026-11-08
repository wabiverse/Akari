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
#ifndef HDAKARI_INSTANCER_H
#define HDAKARI_INSTANCER_H

#if __has_include(<pxr/pxrns.h>)
# include <pxr/pxrns.h>
# include <Sdf/path.h>
# include <Sdf/types.h>
# include <Gf/matrix4d.h>
# include <Gf/matrix4f.h>
# include <Hd/instancer.h>
# include <Hd/sceneDelegate.h>
# include <Hd/types.h>
# include <Vt/array.h>
# include <Vt/types.h>
# include <Vt/value.h>
#else
# include <pxr/pxr.h>
# include <pxr/usd/sdf/path.h>
# include <pxr/usd/sdf/types.h>
# include <pxr/base/gf/matrix4d.h>
# include <pxr/base/gf/matrix4f.h>
# include <pxr/imaging/hd/instancer.h>
# include <pxr/imaging/hd/sceneDelegate.h>
# include <pxr/imaging/hd/types.h>
# include <pxr/base/vt/array.h>
# include <pxr/base/vt/types.h>
# include <pxr/base/vt/value.h>
#endif

#include "HdAkari/api.h"

#include <cstddef>
#include <memory>
#include <mutex>
#include <unordered_map>
#include <unordered_set>

PXR_NAMESPACE_OPEN_SCOPE

class HdRenderIndex;

/// The most instances one prototype draws from one instancer, nested
/// instancers composed, whatever the triangle budget works out to. It only
/// bounds the allocation a very small prototype would otherwise ask for.
inline constexpr size_t HdAkariMaxInstances = size_t(1) << 14;

/// A prototype's instances, the matrices taking its own transformed points to
/// world space, nested instancers composed.
struct HdAkariInstanceSet
{
  VtMatrix4fArray transforms;
  /// Hashes `transforms`, equal sets from different instancers share it.
  uint64_t key = 0;
};

/// Caches an instancer's primvars and each prototype's composed instances.
class HDAKARI_API HdAkariInstancer final : public HdInstancer
{
public:
  HdAkariInstancer(HdSceneDelegate *delegate, SdfPath const &id);
  ~HdAkariInstancer() override = default;

  void Sync(HdSceneDelegate *sceneDelegate,
            HdRenderParam *renderParam,
            HdDirtyBits *dirtyBits) override;

  /// The instances of whichever of this instancer's prototypes `path` is or
  /// sits under, parent instancers composed.
  HdAkariInstanceSet Instances(HdRenderIndex &index, SdfPath const &path);

private:
  SdfPath _PrototypeOf(SdfPath const &path) const;

  std::mutex _mutex;
  GfMatrix4d _transform{1.0};
  VtValue _translations;
  VtValue _rotations;
  VtValue _scales;
  VtValue _transforms;
  SdfPathVector _prototypes;
  std::unordered_set<SdfPath, SdfPath::Hash> _prototypeSet;
  /// Bumped whenever the primvars or prototypes change.
  uint64_t _generation = 0;

  struct Composed
  {
    HdAkariInstanceSet set;
    uint64_t generation = 0;
    uint64_t parentKey = 0;
  };

  std::unordered_map<SdfPath, Composed, SdfPath::Hash> _sets;
};

/// `rprimId`'s instances under `instancerId`, empty when it has none.
HdAkariInstanceSet HdAkariInstances(HdRenderIndex &index, SdfPath const &instancerId, SdfPath const &rprimId);

PXR_NAMESPACE_CLOSE_SCOPE

#endif // HDAKARI_INSTANCER_H
