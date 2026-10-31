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

#if __has_include(<pxr/pxrns.h>)
# include <pxr/pxrns.h>
# include <Gf/matrix4d.h>
# include <Gf/quatd.h>
# include <Gf/quatf.h>
# include <Gf/quath.h>
# include <Gf/rotation.h>
# include <Gf/vec3d.h>
# include <Gf/vec3f.h>
# include <Gf/vec4f.h>
# include <Hd/changeTracker.h>
# include <Hd/instancer.h>
# include <Hd/renderIndex.h>
# include <Hd/rprim.h>
# include <Hd/sceneDelegate.h>
# include <Hd/tokens.h>
# include <Vt/array.h>
#else
# include <pxr/pxr.h>
# include <pxr/base/gf/matrix4d.h>
# include <pxr/base/gf/quatd.h>
# include <pxr/base/gf/quatf.h>
# include <pxr/base/gf/quath.h>
# include <pxr/base/gf/rotation.h>
# include <pxr/base/gf/vec3d.h>
# include <pxr/base/gf/vec3f.h>
# include <pxr/base/gf/vec4f.h>
# include <pxr/imaging/hd/changeTracker.h>
# include <pxr/imaging/hd/instancer.h>
# include <pxr/imaging/hd/renderIndex.h>
# include <pxr/imaging/hd/rprim.h>
# include <pxr/imaging/hd/sceneDelegate.h>
# include <pxr/imaging/hd/tokens.h>
# include <pxr/base/vt/array.h>
#endif

#include "HdAkari/instancer.h"
#include "HdAkari/scene.h"

#include <algorithm>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

PXR_NAMESPACE_OPEN_SCOPE

namespace {

size_t MaxInstances()
{
  // A development override, for profiling a dense scene.
  static const size_t limit = [] {
    if (const char *env = std::getenv("AKARI_MAX_INSTANCES")) return std::max<size_t>(1, std::strtoull(env, nullptr, 10));
    return HdAkariMaxInstances;
  }();
  return limit;
}

/// Warns once per instancer that its instances were sampled, so a dense
/// scatter is visible in the log without printing on every sync.
void WarnInstancesSampled(SdfPath const &instancerId, size_t total, size_t kept)
{
  static std::mutex mutex;
  static std::unordered_set<std::string> warned;
  std::lock_guard<std::mutex> lock(mutex);
  if (!warned.insert(instancerId.GetString()).second) return;
  std::fprintf(stderr,
               "HdAkari: %s has %zu instances, drawing %zu of them sampled evenly.\n",
               instancerId.GetString().c_str(), total, kept);
}

bool Vec3At(VtValue const &value, int i, GfVec3d &out)
{
  if (value.IsHolding<VtVec3fArray>()) {
    VtVec3fArray const &a = value.UncheckedGet<VtVec3fArray>();
    if (i < 0 || size_t(i) >= a.size()) return false;
    out = GfVec3d(a[i]);
    return true;
  }
  if (value.IsHolding<VtVec3dArray>()) {
    VtVec3dArray const &a = value.UncheckedGet<VtVec3dArray>();
    if (i < 0 || size_t(i) >= a.size()) return false;
    out = a[i];
    return true;
  }
  return false;
}

bool QuatAt(VtValue const &value, int i, GfQuatd &out)
{
  if (value.IsHolding<VtQuathArray>()) {
    VtQuathArray const &a = value.UncheckedGet<VtQuathArray>();
    if (i < 0 || size_t(i) >= a.size()) return false;
    out = GfQuatd(a[i]);
    return true;
  }
  if (value.IsHolding<VtQuatfArray>()) {
    VtQuatfArray const &a = value.UncheckedGet<VtQuatfArray>();
    if (i < 0 || size_t(i) >= a.size()) return false;
    out = GfQuatd(a[i]);
    return true;
  }
  if (value.IsHolding<VtVec4fArray>()) {
    VtVec4fArray const &a = value.UncheckedGet<VtVec4fArray>();
    if (i < 0 || size_t(i) >= a.size()) return false;
    out = GfQuatd(a[i][0], a[i][1], a[i][2], a[i][3]);
    return true;
  }
  return false;
}

GfMatrix4d LocalInstanceMatrix(VtValue const &transforms,
                               VtValue const &translations,
                               VtValue const &rotations,
                               VtValue const &scales,
                               int index,
                               GfMatrix4d const &instancerXf)
{
  GfMatrix4d m(1.0);
  if (transforms.IsHolding<VtMatrix4dArray>()) {
    VtMatrix4dArray const &matrices = transforms.UncheckedGet<VtMatrix4dArray>();
    if (index >= 0 && size_t(index) < matrices.size()) m = matrices[index];
  }
  GfVec3d v;
  if (Vec3At(scales, index, v)) m = m * GfMatrix4d(1.0).SetScale(v);
  GfQuatd q;
  if (QuatAt(rotations, index, q)) m = m * GfMatrix4d(1.0).SetRotate(GfRotation(q));
  if (Vec3At(translations, index, v)) m = m * GfMatrix4d(1.0).SetTranslate(v);
  return m * instancerXf;
}

/// Visits `0 ..< count` in bit reversed order, the first `limit` of them, so
/// whichever prefix gets drawn spreads evenly across the whole range.
template <typename Visit>
void VisitBitReversed(size_t count, size_t limit, Visit &&visit)
{
  int bits = 0;
  while ((size_t(1) << bits) < count) ++bits;
  size_t visited = 0;
  for (size_t i = 0; i < (size_t(1) << bits) && visited < limit; ++i) {
    size_t r = 0;
    for (int b = 0; b < bits; ++b) r |= ((i >> b) & 1) << (bits - 1 - b);
    if (r < count) visit(visited++, r);
  }
}

} // namespace

HdAkariInstancer::HdAkariInstancer(HdSceneDelegate *delegate, SdfPath const &id)
  : HdInstancer(delegate, id)
{
}

void HdAkariInstancer::Sync(HdSceneDelegate *sceneDelegate,
                            HdRenderParam * /*renderParam*/,
                            HdDirtyBits *dirtyBits)
{
  HdInstancer::_UpdateInstancer(sceneDelegate, dirtyBits);

  const bool transformsDirty = *dirtyBits & (HdChangeTracker::DirtyTransform |
                                             HdChangeTracker::DirtyPrimvar);
  const bool topologyDirty = *dirtyBits & (HdChangeTracker::DirtyInstanceIndex |
                                           HdChangeTracker::DirtyInstancer |
                                           HdChangeTracker::DirtyVisibility);
  if (!transformsDirty && !topologyDirty) return;

  const SdfPath &id = GetId();
  GfMatrix4d transform(1.0);
  VtValue translations, rotations, scales, transforms;
  SdfPathVector prototypes;
  if (transformsDirty) {
    transform = sceneDelegate->GetInstancerTransform(id);
    translations = sceneDelegate->Get(id, HdInstancerTokens->instanceTranslations);
    rotations = sceneDelegate->Get(id, HdInstancerTokens->instanceRotations);
    scales = sceneDelegate->Get(id, HdInstancerTokens->instanceScales);
    transforms = sceneDelegate->Get(id, HdInstancerTokens->instanceTransforms);
  }
  if (topologyDirty) prototypes = sceneDelegate->GetInstancerPrototypes(id);

  std::lock_guard<std::mutex> lock(_mutex);
  if (transformsDirty) {
    _transform = transform;
    _translations = std::move(translations);
    _rotations = std::move(rotations);
    _scales = std::move(scales);
    _transforms = std::move(transforms);
  }
  if (topologyDirty) {
    _prototypes = std::move(prototypes);
    _prototypeSet = std::unordered_set<SdfPath, SdfPath::Hash>(_prototypes.begin(), _prototypes.end());
  }
  _sets.clear();
  ++_generation;
}

SdfPath HdAkariInstancer::_PrototypeOf(SdfPath const &path) const
{
  for (SdfPath p = path; !p.IsEmpty() && !p.IsAbsoluteRootPath(); p = p.GetParentPath()) {
    if (_prototypeSet.count(p)) return p;
  }
  return path;
}

HdAkariInstanceSet HdAkariInstancer::Instances(HdRenderIndex &index, SdfPath const &path)
{
  // Held while composing, so the rprims of one prototype wait for its set
  // instead of each composing their own. Parents lock after their children.
  std::lock_guard<std::mutex> lock(_mutex);
  const SdfPath prototype = _PrototypeOf(path);

  HdAkariInstanceSet parent;
  const SdfPath &parentId = GetParentId();
  if (!parentId.IsEmpty()) {
    auto *outer = dynamic_cast<HdAkariInstancer *>(index.GetInstancer(parentId));
    if (!outer) return {};
    parent = outer->Instances(index, GetId());
    if (parent.transforms.empty()) return {};
  }

  const auto found = _sets.find(prototype);
  if (found != _sets.end() && found->second.generation == _generation &&
      found->second.parentKey == parent.key) {
    return found->second.set;
  }

  const VtIntArray indices = GetDelegate()->GetInstanceIndices(GetId(), prototype);
  std::vector<GfMatrix4d> local;
  local.reserve(indices.size());
  for (int i : indices) {
    local.push_back(LocalInstanceMatrix(_transforms, _translations, _rotations, _scales, i, _transform));
  }

  HdAkariInstanceSet set;
  const size_t outer = parentId.IsEmpty() ? 1 : parent.transforms.size();
  const size_t total = local.size() * outer;
  const size_t kept = std::min(total, MaxInstances());
  if (kept < total) WarnInstancesSampled(GetId(), total, kept);
  if (kept > 0) {
    set.transforms = VtMatrix4fArray(kept);
    GfMatrix4f *dst = set.transforms.data();
    VisitBitReversed(total, kept, [&](size_t slot, size_t k) {
      GfMatrix4d const &l = local[k % local.size()];
      dst[slot] = parentId.IsEmpty() ? GfMatrix4f(l)
                                     : GfMatrix4f(l * GfMatrix4d(parent.transforms[k / local.size()]));
    });
    set.key = HdAkariHashBytes(1469598103934665603ull, set.transforms.cdata(), kept * sizeof(GfMatrix4f));
  }

  _sets[prototype] = Composed{set, _generation, parent.key};
  return set;
}

HdAkariInstanceSet HdAkariInstances(HdRenderIndex &index, SdfPath const &instancerId, SdfPath const &rprimId)
{
  auto *instancer = dynamic_cast<HdAkariInstancer *>(index.GetInstancer(instancerId));
  return instancer ? instancer->Instances(index, rprimId) : HdAkariInstanceSet();
}

PXR_NAMESPACE_CLOSE_SCOPE
