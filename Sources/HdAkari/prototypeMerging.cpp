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
# include <Gf/range3d.h>
# include <Hd/dataSourceTypeDefs.h>
# include <Hd/extComputationPrimvarsSchema.h>
# include <Hd/extentSchema.h>
# include <Hd/instancedBySchema.h>
# include <Hd/materialBindingsSchema.h>
# include <Hd/meshSchema.h>
# include <Hd/meshTopologySchema.h>
# include <Hd/primvarSchema.h>
# include <Hd/primvarsSchema.h>
# include <Hd/purposeSchema.h>
# include <Hd/retainedDataSource.h>
# include <Hd/tokens.h>
# include <Hd/visibilitySchema.h>
# include <Hd/xformSchema.h>
# include <PxOsd/tokens.h>
# include <Tf/stringUtils.h>
# include <Work/loops.h>
# include <Work/withScopedParallelism.h>
#else
# include <pxr/pxr.h>
# include <pxr/base/gf/matrix4d.h>
# include <pxr/base/gf/range3d.h>
# include <pxr/imaging/hd/dataSourceTypeDefs.h>
# include <pxr/imaging/hd/extComputationPrimvarsSchema.h>
# include <pxr/imaging/hd/extentSchema.h>
# include <pxr/imaging/hd/instancedBySchema.h>
# include <pxr/imaging/hd/materialBindingsSchema.h>
# include <pxr/imaging/hd/meshSchema.h>
# include <pxr/imaging/hd/meshTopologySchema.h>
# include <pxr/imaging/hd/primvarSchema.h>
# include <pxr/imaging/hd/primvarsSchema.h>
# include <pxr/imaging/hd/purposeSchema.h>
# include <pxr/imaging/hd/retainedDataSource.h>
# include <pxr/imaging/hd/tokens.h>
# include <pxr/imaging/hd/visibilitySchema.h>
# include <pxr/imaging/hd/xformSchema.h>
# include <pxr/imaging/pxOsd/tokens.h>
# include <pxr/base/tf/stringUtils.h>
# include <pxr/base/work/loops.h>
# include <pxr/base/work/withScopedParallelism.h>
#endif

#include "HdAkari/prototypeMerging.h"

#include <algorithm>
#include <iterator>
#include <unordered_set>

PXR_NAMESPACE_OPEN_SCOPE

namespace {

/// Merged meshes stop growing here.
constexpr size_t kMaxMergedFaces = 262144;

const std::string &MergedPrefix()
{
  static const std::string prefix = "__akariMerged_";
  return prefix;
}

bool IsMergedName(SdfPath const &path)
{
  return TfStringStartsWith(path.GetName(), MergedPrefix());
}

uint64_t Mix(uint64_t key, uint64_t value)
{
  return (key ^ value) * 1099511628211ull;
}

template <typename T>
T TypedValue(typename HdTypedSampledDataSource<T>::Handle const &ds, T fallback = T())
{
  return ds ? ds->GetTypedValue(0.0f) : fallback;
}

VtValue Value(HdSampledDataSourceHandle const &ds)
{
  return ds ? ds->GetValue(0.0f) : VtValue();
}

template <typename T>
void Grow(VtArray<T> &array, size_t extra)
{
  const size_t need = array.size() + extra;
  if (need > array.capacity()) array.reserve(std::max(need, array.capacity() * 2));
}

template <typename T>
bool Append(VtValue const &value, size_t expected, VtValue &out)
{
  if (!value.IsHolding<VtArray<T>>()) return false;
  if (out.IsEmpty()) out = VtArray<T>();
  if (!out.IsHolding<VtArray<T>>()) return false;
  VtArray<T> const &in = value.UncheckedGet<VtArray<T>>();
  VtArray<T> merged = out.UncheckedGet<VtArray<T>>();
  out = VtValue();
  Grow(merged, expected);
  for (size_t i = 0; i < expected; ++i) merged.push_back(i < in.size() ? in[i] : in.empty() ? T() : in.back());
  out = VtValue(std::move(merged));
  return true;
}

/// Appends one member's values of a varying primvar, `expected` of them.
bool AppendAny(VtValue const &value, size_t expected, VtValue &out)
{
  return Append<float>(value, expected, out) || Append<GfVec2f>(value, expected, out) ||
         Append<GfVec3f>(value, expected, out) || Append<GfVec4f>(value, expected, out) ||
         Append<double>(value, expected, out) || Append<GfVec3d>(value, expected, out) ||
         Append<int>(value, expected, out);
}

} // namespace

struct HdAkariPrototypeMergingSceneIndex::Group
{
  SdfPath path;
  std::vector<SdfPath> members;
  size_t faces = 0;
  HdContainerDataSourceHandle data;
};

struct HdAkariPrototypeMergingSceneIndex::Root
{
  SdfPath path;
  std::vector<std::shared_ptr<Group>> groups;
  std::unordered_map<SdfPath, size_t, SdfPath::Hash> memberGroup;
};

namespace {

using Group = HdAkariPrototypeMergingSceneIndex::Group;

/// A merged mesh's data, composed from its members the first time any of it
/// is asked for.
class MergedDataSource final : public HdContainerDataSource
{
public:
  HD_DECLARE_DATASOURCE(MergedDataSource);

  TfTokenVector GetNames() override
  {
    return {HdMeshSchema::GetSchemaToken(), HdPrimvarsSchema::GetSchemaToken(), HdXformSchema::GetSchemaToken(),
            HdExtentSchema::GetSchemaToken(), HdInstancedBySchema::GetSchemaToken(),
            HdMaterialBindingsSchema::GetSchemaToken(), HdPurposeSchema::GetSchemaToken(),
            HdVisibilitySchema::GetSchemaToken()};
  }

  HdDataSourceBaseHandle Get(TfToken const &name) override
  {
    if (name == HdPurposeSchema::GetSchemaToken() || name == HdInstancedBySchema::GetSchemaToken() ||
        name == HdMaterialBindingsSchema::GetSchemaToken()) {
      HdContainerDataSourceHandle ds = _input->GetPrim(_members.front()).dataSource;
      return ds ? ds->Get(name) : nullptr;
    }
    const TfTokenVector names = GetNames();
    if (std::find(names.begin(), names.end(), name) == names.end()) return nullptr;
    std::call_once(_once, [this] { _merged = _Merge(); });
    return _merged ? _merged->Get(name) : nullptr;
  }

private:
  MergedDataSource(HdSceneIndexBaseRefPtr input, std::vector<SdfPath> members)
    : _input(std::move(input)), _members(std::move(members))
  {
  }

  HdContainerDataSourceHandle _Merge() const
  {
    VtIntArray counts, indices, holes;
    VtVec3fArray points;
    GfRange3d bounds;
    TfToken orientation = HdTokens->rightHanded;
    HdContainerDataSourceHandle first;
    HdBoolDataSourceHandle doubleSided;
    HdTokenDataSourceHandle scheme;

    struct Varying { TfToken interpolation; TfToken role; VtValue merged; bool ok = true; };
    std::vector<TfToken> order;
    std::unordered_map<TfToken, Varying, TfToken::HashFunctor> varying;
    std::vector<std::pair<TfToken, HdDataSourceBaseHandle>> constants;

    for (SdfPath const &member : _members) {
      HdContainerDataSourceHandle ds = _input->GetPrim(member).dataSource;
      if (!ds) continue;
      HdMeshSchema mesh = HdMeshSchema::GetFromParent(ds);
      HdMeshTopologySchema topology = mesh.GetTopology();
      const VtIntArray memberCounts = TypedValue<VtIntArray>(topology.GetFaceVertexCounts());
      const VtIntArray memberIndices = TypedValue<VtIntArray>(topology.GetFaceVertexIndices());
      HdPrimvarsSchema primvars = HdPrimvarsSchema::GetFromParent(ds);
      const VtValue pointsValue = Value(primvars.GetPrimvar(HdTokens->points).GetPrimvarValue());
      if (!pointsValue.IsHolding<VtVec3fArray>()) continue;
      VtVec3fArray const &memberPoints = pointsValue.UncheckedGet<VtVec3fArray>();

      if (!first) {
        first = ds;
        doubleSided = mesh.GetDoubleSided();
        scheme = mesh.GetSubdivisionScheme();
        orientation = TypedValue<TfToken>(topology.GetOrientation(), HdTokens->rightHanded);
      }

      const int base = int(points.size());
      const int faceBase = int(counts.size());
      const GfMatrix4d xf = TypedValue<GfMatrix4d>(HdXformSchema::GetFromParent(ds).GetMatrix(), GfMatrix4d(1.0));
      Grow(points, memberPoints.size());
      for (GfVec3f const &p : memberPoints) {
        const GfVec3d world = xf.Transform(GfVec3d(p));
        points.push_back(GfVec3f(world));
        bounds.UnionWith(world);
      }
      Grow(counts, memberCounts.size());
      for (int c : memberCounts) counts.push_back(c);
      Grow(indices, memberIndices.size());
      for (int i : memberIndices) indices.push_back(i + base);
      for (int h : TypedValue<VtIntArray>(topology.GetHoleIndices())) holes.push_back(h + faceBase);

      for (TfToken const &name : primvars.GetPrimvarNames()) {
        if (name == HdTokens->points || name == HdTokens->normals) continue;
        HdPrimvarSchema primvar = primvars.GetPrimvar(name);
        const TfToken interpolation = TypedValue<TfToken>(primvar.GetInterpolation());
        if (interpolation == HdPrimvarSchemaTokens->constant) {
          if (first == ds) constants.emplace_back(name, primvars.GetContainer()->Get(name));
          continue;
        }
        size_t expected = memberPoints.size();
        if (interpolation == HdPrimvarSchemaTokens->faceVarying) expected = memberIndices.size();
        else if (interpolation == HdPrimvarSchemaTokens->uniform) expected = memberCounts.size();
        auto [it, inserted] = varying.try_emplace(name);
        if (inserted) {
          order.push_back(name);
          it->second.interpolation = interpolation;
          it->second.role = TypedValue<TfToken>(primvar.GetRole());
        }
        Varying &v = it->second;
        v.ok = v.ok && v.interpolation == interpolation &&
               AppendAny(Value(primvar.GetFlattenedPrimvarValue()), expected, v.merged);
      }
    }
    if (!first) return nullptr;

    std::vector<TfToken> names = {HdTokens->points};
    std::vector<HdDataSourceBaseHandle> values = {
      HdPrimvarSchema::Builder()
        .SetPrimvarValue(HdRetainedTypedSampledDataSource<VtVec3fArray>::New(points))
        .SetInterpolation(HdPrimvarSchema::BuildInterpolationDataSource(HdPrimvarSchemaTokens->vertex))
        .SetRole(HdPrimvarSchema::BuildRoleDataSource(HdPrimvarSchemaTokens->point))
        .Build()};
    for (TfToken const &name : order) {
      Varying const &v = varying[name];
      if (!v.ok || v.merged.IsEmpty()) continue;
      names.push_back(name);
      values.push_back(HdPrimvarSchema::Builder()
                         .SetPrimvarValue(HdRetainedSampledDataSource::New(v.merged))
                         .SetInterpolation(HdPrimvarSchema::BuildInterpolationDataSource(v.interpolation))
                         .SetRole(HdPrimvarSchema::BuildRoleDataSource(v.role))
                         .Build());
    }
    for (auto const &[name, value] : constants) {
      if (std::find(names.begin(), names.end(), name) != names.end()) continue;
      names.push_back(name);
      values.push_back(value);
    }

    HdContainerDataSourceHandle topology = HdMeshTopologySchema::Builder()
      .SetFaceVertexCounts(HdRetainedTypedSampledDataSource<VtIntArray>::New(counts))
      .SetFaceVertexIndices(HdRetainedTypedSampledDataSource<VtIntArray>::New(indices))
      .SetHoleIndices(HdRetainedTypedSampledDataSource<VtIntArray>::New(holes))
      .SetOrientation(HdRetainedTypedSampledDataSource<TfToken>::New(orientation))
      .Build();

    const TfToken fields[] = {
      HdMeshSchema::GetSchemaToken(), HdPrimvarsSchema::GetSchemaToken(), HdXformSchema::GetSchemaToken(),
      HdExtentSchema::GetSchemaToken(), HdInstancedBySchema::GetSchemaToken(),
      HdMaterialBindingsSchema::GetSchemaToken(), HdPurposeSchema::GetSchemaToken(),
      HdVisibilitySchema::GetSchemaToken()};
    const HdDataSourceBaseHandle fieldValues[] = {
      HdMeshSchema::Builder()
        .SetTopology(topology)
        .SetSubdivisionScheme(scheme ? scheme : HdRetainedTypedSampledDataSource<TfToken>::New(PxOsdOpenSubdivTokens->none))
        .SetDoubleSided(doubleSided)
        .Build(),
      HdRetainedContainerDataSource::New(names.size(), names.data(), values.data()),
      HdXformSchema::Builder()
        .SetMatrix(HdRetainedTypedSampledDataSource<GfMatrix4d>::New(GfMatrix4d(1.0)))
        .SetResetXformStack(HdRetainedTypedSampledDataSource<bool>::New(true))
        .Build(),
      HdExtentSchema::Builder()
        .SetMin(HdRetainedTypedSampledDataSource<GfVec3d>::New(bounds.GetMin()))
        .SetMax(HdRetainedTypedSampledDataSource<GfVec3d>::New(bounds.GetMax()))
        .Build(),
      first->Get(HdInstancedBySchema::GetSchemaToken()),
      first->Get(HdMaterialBindingsSchema::GetSchemaToken()),
      first->Get(HdPurposeSchema::GetSchemaToken()),
      HdVisibilitySchema::Builder().SetVisibility(HdRetainedTypedSampledDataSource<bool>::New(true)).Build()};
    return HdRetainedContainerDataSource::New(std::size(fields), fields, fieldValues);
  }

  HdSceneIndexBaseRefPtr _input;
  std::vector<SdfPath> _members;
  std::once_flag _once;
  HdContainerDataSourceHandle _merged;
};

/// The prototype root a mesh is instanced under, empty when it isn't.
SdfPath PrototypeRootOf(SdfPath const &path, HdContainerDataSourceHandle const &ds)
{
  HdInstancedBySchema instancedBy = HdInstancedBySchema::GetFromParent(ds);
  if (!instancedBy.GetPrototypeRoots()) return SdfPath();
  for (SdfPath const &root : instancedBy.GetPrototypeRoots()->GetTypedValue(0.0f)) {
    if (path.HasPrefix(root)) return root;
  }
  return SdfPath();
}

VtArray<SdfPath> InstancersOf(HdContainerDataSourceHandle const &ds)
{
  HdInstancedBySchema instancedBy = HdInstancedBySchema::GetFromParent(ds);
  return instancedBy.GetPaths() ? instancedBy.GetPaths()->GetTypedValue(0.0f) : VtArray<SdfPath>();
}

/// What has to match for two meshes to merge: their instancer, material,
/// purpose, sidedness, winding and constant primvars, and which varying
/// primvars they carry. Zero when the mesh can't merge at all.
uint64_t MergeKey(HdContainerDataSourceHandle const &ds)
{
  if (!ds) return 0;
  HdExtComputationPrimvarsSchema computed = HdExtComputationPrimvarsSchema::GetFromParent(ds);
  if (computed && !computed.GetExtComputationPrimvarNames().empty()) return 0;
  HdBoolDataSourceHandle visible = HdVisibilitySchema::GetFromParent(ds).GetVisibility();
  if (visible && !visible->GetTypedValue(0.0f)) return 0;
  HdPrimvarsSchema primvars = HdPrimvarsSchema::GetFromParent(ds);
  if (!primvars.GetPrimvar(HdTokens->points)) return 0;

  uint64_t key = 1469598103934665603ull;
  for (SdfPath const &instancer : InstancersOf(ds)) key = Mix(key, instancer.GetHash());
  HdMaterialBindingSchema binding = HdMaterialBindingsSchema::GetFromParent(ds).GetMaterialBinding();
  if (binding.GetPath()) key = Mix(key, binding.GetPath()->GetTypedValue(0.0f).GetHash());
  key = Mix(key, TypedValue<TfToken>(HdPurposeSchema::GetFromParent(ds).GetPurpose()).Hash());
  HdMeshSchema mesh = HdMeshSchema::GetFromParent(ds);
  key = Mix(key, TypedValue<bool>(mesh.GetDoubleSided()) ? 1 : 2);
  key = Mix(key, TypedValue<TfToken>(mesh.GetTopology().GetOrientation()).Hash());
  key = Mix(key, TypedValue<TfToken>(mesh.GetSubdivisionScheme()).Hash());

  TfTokenVector names = primvars.GetPrimvarNames();
  std::sort(names.begin(), names.end());
  for (TfToken const &name : names) {
    if (name == HdTokens->points || name == HdTokens->normals) continue;
    HdPrimvarSchema primvar = primvars.GetPrimvar(name);
    const TfToken interpolation = TypedValue<TfToken>(primvar.GetInterpolation());
    key = Mix(Mix(key, name.Hash()), interpolation.Hash());
    if (interpolation == HdPrimvarSchemaTokens->constant) key = Mix(key, Value(primvar.GetPrimvarValue()).GetHash());
  }
  return key ? key : 1;
}

} // namespace

HdAkariPrototypeMergingSceneIndexRefPtr
HdAkariPrototypeMergingSceneIndex::New(HdSceneIndexBaseRefPtr const &inputSceneIndex)
{
  return TfCreateRefPtr(new HdAkariPrototypeMergingSceneIndex(inputSceneIndex));
}

HdAkariPrototypeMergingSceneIndex::HdAkariPrototypeMergingSceneIndex(HdSceneIndexBaseRefPtr const &inputSceneIndex)
  : HdSingleInputFilteringSceneIndexBase(inputSceneIndex)
{
}

bool HdAkariPrototypeMergingSceneIndex::_IsRoot(SdfPath const &path) const
{
  HdContainerDataSourceHandle ds = _GetInputSceneIndex()->GetPrim(path).dataSource;
  return ds && PrototypeRootOf(path, ds) == path && !InstancersOf(ds).empty();
}

std::shared_ptr<HdAkariPrototypeMergingSceneIndex::Root>
HdAkariPrototypeMergingSceneIndex::_GetRoot(SdfPath const &rootPath) const
{
  std::shared_future<std::shared_ptr<Root>> pending;
  {
    std::lock_guard<std::mutex> lock(_mutex);
    const auto found = _roots.find(rootPath);
    if (found != _roots.end()) return found->second;
    const auto building = _building.find(rootPath);
    if (building != _building.end()) pending = building->second;
  }
  if (pending.valid()) return pending.get();
  if (!_IsRoot(rootPath)) return nullptr;
  std::promise<std::shared_ptr<Root>> promise;
  {
    std::lock_guard<std::mutex> lock(_mutex);
    const auto found = _roots.find(rootPath);
    if (found != _roots.end()) return found->second;
    const auto building = _building.find(rootPath);
    if (building != _building.end()) pending = building->second;
    else _building.emplace(rootPath, promise.get_future().share());
  }
  if (pending.valid()) return pending.get();

  HdSceneIndexBaseRefPtr const &input = _GetInputSceneIndex();
  const VtArray<SdfPath> instancers = InstancersOf(input->GetPrim(rootPath).dataSource);
  auto root = std::make_shared<Root>();
  root->path = rootPath;
  std::vector<std::pair<SdfPath, HdContainerDataSourceHandle>> meshes;
  std::vector<SdfPath> stack = {rootPath};
  while (!stack.empty()) {
    const SdfPath path = stack.back();
    stack.pop_back();
    const HdSceneIndexPrim prim = input->GetPrim(path);
    // a nested instancer's prototypes are roots of their own.
    if (path != rootPath && prim.primType == HdPrimTypeTokens->instancer) continue;
    if (prim.primType == HdPrimTypeTokens->mesh) meshes.emplace_back(path, prim.dataSource);
    SdfPathVector children = input->GetChildPrimPaths(path);
    stack.insert(stack.end(), children.rbegin(), children.rend());
  }
  std::vector<std::pair<uint64_t, size_t>> keys(meshes.size());
  WorkWithScopedParallelism([&]() {
    WorkParallelForN(meshes.size(), [&](size_t begin, size_t end) {
      for (size_t i = begin; i < end; ++i) {
        auto const &[path, ds] = meshes[i];
        if (InstancersOf(ds) != instancers || PrototypeRootOf(path, ds) != rootPath) continue;
        if (const uint64_t key = MergeKey(ds)) {
          keys[i] = {key, TypedValue<VtIntArray>(HdMeshSchema::GetFromParent(ds).GetTopology().GetFaceVertexCounts()).size()};
        }
      }
    }, /*grainSize=*/32);
  });
  std::unordered_map<uint64_t, size_t> open;
  for (size_t i = 0; i < meshes.size(); ++i) {
    const auto [key, faces] = keys[i];
    if (!key) continue;
    SdfPath const &path = meshes[i].first;
    auto slot = open.find(key);
    if (slot == open.end() || root->groups[slot->second]->faces + faces > kMaxMergedFaces) {
      auto group = std::make_shared<Group>();
      slot = open.insert_or_assign(key, root->groups.size()).first;
      root->groups.push_back(group);
    }
    Group &group = *root->groups[slot->second];
    group.members.push_back(path);
    group.faces += faces;
    root->memberGroup[path] = slot->second;
  }
  // a lone mesh gains nothing from merging.
  for (auto &group : root->groups) {
    if (group->members.size() == 1) root->memberGroup.erase(group->members.front());
  }
  root->groups.erase(std::remove_if(root->groups.begin(), root->groups.end(),
                                    [](auto const &group) { return group->members.size() < 2; }),
                     root->groups.end());
  for (size_t i = 0; i < root->groups.size(); ++i) {
    Group &group = *root->groups[i];
    group.path = rootPath.AppendChild(TfToken(MergedPrefix() + std::to_string(i)));
    for (SdfPath const &member : group.members) root->memberGroup[member] = i;
    group.data = MergedDataSource::New(input, group.members);
  }

  std::lock_guard<std::mutex> lock(_mutex);
  _building.erase(rootPath);
  promise.set_value(root);
  return _roots.emplace(rootPath, root).first->second;
}

std::shared_ptr<HdAkariPrototypeMergingSceneIndex::Root>
HdAkariPrototypeMergingSceneIndex::_FindBuiltRoot(SdfPath const &path) const
{
  std::lock_guard<std::mutex> lock(_mutex);
  if (_roots.empty()) return nullptr;
  for (SdfPath p = path; !p.IsEmpty() && !p.IsAbsoluteRootPath(); p = p.GetParentPath()) {
    const auto found = _roots.find(p);
    if (found != _roots.end()) return found->second;
  }
  return nullptr;
}

HdSceneIndexPrim HdAkariPrototypeMergingSceneIndex::GetPrim(SdfPath const &primPath) const
{
  if (IsMergedName(primPath)) {
    if (std::shared_ptr<Root> root = _GetRoot(primPath.GetParentPath())) {
      for (auto const &group : root->groups) {
        if (group->path != primPath) continue;
        std::lock_guard<std::mutex> lock(_mutex);
        return {HdPrimTypeTokens->mesh, group->data};
      }
    }
    return {};
  }

  HdSceneIndexPrim prim = _GetInputSceneIndex()->GetPrim(primPath);
  if (prim.primType != HdPrimTypeTokens->mesh || !prim.dataSource) return prim;
  const SdfPath rootPath = PrototypeRootOf(primPath, prim.dataSource);
  if (rootPath.IsEmpty()) return prim;
  std::shared_ptr<Root> root = _GetRoot(rootPath);
  if (root && root->memberGroup.count(primPath)) prim.primType = TfToken();
  return prim;
}

SdfPathVector HdAkariPrototypeMergingSceneIndex::GetChildPrimPaths(SdfPath const &primPath) const
{
  SdfPathVector children = _GetInputSceneIndex()->GetChildPrimPaths(primPath);
  if (IsMergedName(primPath)) return {};
  if (std::shared_ptr<Root> root = _GetRoot(primPath)) {
    for (auto const &group : root->groups) children.push_back(group->path);
  }
  return children;
}

void HdAkariPrototypeMergingSceneIndex::_Rebuild(std::vector<SdfPath> const &rootPaths,
                                                 HdSceneIndexObserver::AddedPrimEntries *added,
                                                 HdSceneIndexObserver::RemovedPrimEntries *removed)
{
  std::vector<std::shared_ptr<Root>> olds(rootPaths.size()), roots(rootPaths.size());
  {
    std::lock_guard<std::mutex> lock(_mutex);
    for (size_t i = 0; i < rootPaths.size(); ++i) {
      const auto found = _roots.find(rootPaths[i]);
      if (found == _roots.end()) continue;
      olds[i] = found->second;
      _roots.erase(found);
    }
  }
  WorkParallelForN(rootPaths.size(), [&](size_t begin, size_t end) {
    for (size_t i = begin; i < end; ++i) {
      WorkWithScopedParallelism([&]() { roots[i] = _GetRoot(rootPaths[i]); });
    }
  });
  for (size_t i = 0; i < rootPaths.size(); ++i) {
    std::shared_ptr<Root> const &old = olds[i];
    std::shared_ptr<Root> const &root = roots[i];
    std::unordered_set<SdfPath, SdfPath::Hash> kept;
    if (root) {
      for (auto const &group : root->groups) {
        kept.insert(group->path);
        added->emplace_back(group->path, HdPrimTypeTokens->mesh);
      }
      for (auto const &[member, group] : root->memberGroup) added->emplace_back(member, TfToken());
    }
    if (old) {
      for (auto const &group : old->groups) {
        if (!kept.count(group->path)) removed->emplace_back(group->path);
      }
      for (auto const &[member, group] : old->memberGroup) {
        if (!root || !root->memberGroup.count(member)) added->emplace_back(member, HdPrimTypeTokens->mesh);
      }
    }
  }
}

void HdAkariPrototypeMergingSceneIndex::_PrimsAdded(HdSceneIndexBase const &,
                                                    HdSceneIndexObserver::AddedPrimEntries const &entries)
{
  std::vector<SdfPath> stale;
  std::unordered_set<SdfPath, SdfPath::Hash> seen;
  for (auto const &entry : entries) {
    SdfPath rootPath;
    if (std::shared_ptr<Root> root = _FindBuiltRoot(entry.primPath)) {
      rootPath = root->path;
    } else if (entry.primType == HdPrimTypeTokens->mesh) {
      rootPath = PrototypeRootOf(entry.primPath, _GetInputSceneIndex()->GetPrim(entry.primPath).dataSource);
    }
    if (!rootPath.IsEmpty() && seen.insert(rootPath).second) stale.push_back(rootPath);
  }
  HdSceneIndexObserver::AddedPrimEntries rebuilt;
  HdSceneIndexObserver::RemovedPrimEntries removed;
  _Rebuild(stale, &rebuilt, &removed);

  // members arrive without a type, so no rprim is made for them only to go.
  HdSceneIndexObserver::AddedPrimEntries added;
  added.reserve(entries.size() + rebuilt.size());
  std::unordered_set<SdfPath, SdfPath::Hash> retyped;
  for (auto const &entry : rebuilt) retyped.insert(entry.primPath);
  for (auto const &entry : entries) {
    if (!retyped.count(entry.primPath)) added.push_back(entry);
  }
  added.insert(added.end(), rebuilt.begin(), rebuilt.end());
  if (!removed.empty()) _SendPrimsRemoved(removed);
  _SendPrimsAdded(added);
}

void HdAkariPrototypeMergingSceneIndex::_PrimsRemoved(HdSceneIndexBase const &,
                                                      HdSceneIndexObserver::RemovedPrimEntries const &entries)
{
  std::vector<SdfPath> stale;
  {
    std::lock_guard<std::mutex> lock(_mutex);
    for (auto const &entry : entries) {
      for (auto it = _roots.begin(); it != _roots.end();) {
        if (it->first.HasPrefix(entry.primPath)) it = _roots.erase(it);
        else ++it;
      }
    }
  }
  for (auto const &entry : entries) {
    if (std::shared_ptr<Root> root = _FindBuiltRoot(entry.primPath)) stale.push_back(root->path);
  }
  _SendPrimsRemoved(entries);
  if (stale.empty()) return;
  std::sort(stale.begin(), stale.end());
  stale.erase(std::unique(stale.begin(), stale.end()), stale.end());
  HdSceneIndexObserver::AddedPrimEntries added;
  HdSceneIndexObserver::RemovedPrimEntries removed;
  _Rebuild(stale, &added, &removed);
  if (!removed.empty()) _SendPrimsRemoved(removed);
  if (!added.empty()) _SendPrimsAdded(added);
}

void HdAkariPrototypeMergingSceneIndex::_PrimsDirtied(HdSceneIndexBase const &,
                                                      HdSceneIndexObserver::DirtiedPrimEntries const &entries)
{
  static const HdDataSourceLocatorSet structural = {
    HdInstancedBySchema::GetDefaultLocator(), HdMaterialBindingsSchema::GetDefaultLocator(),
    HdVisibilitySchema::GetDefaultLocator(), HdPurposeSchema::GetDefaultLocator()};
  static const HdDataSourceLocatorSet geometry = {
    HdMeshSchema::GetDefaultLocator(), HdPrimvarsSchema::GetDefaultLocator(), HdExtentSchema::GetDefaultLocator()};

  HdSceneIndexObserver::DirtiedPrimEntries dirtied;
  std::vector<SdfPath> stale;
  for (auto const &entry : entries) {
    std::shared_ptr<Root> root = _FindBuiltRoot(entry.primPath);
    if (!root || !root->memberGroup.count(entry.primPath)) {
      dirtied.push_back(entry);
      continue;
    }
    if (entry.dirtyLocators.Intersects(structural)) {
      stale.push_back(root->path);
      continue;
    }
    std::shared_ptr<Group> group = root->groups[root->memberGroup.at(entry.primPath)];
    {
      std::lock_guard<std::mutex> lock(_mutex);
      group->data = MergedDataSource::New(_GetInputSceneIndex(), group->members);
    }
    dirtied.emplace_back(group->path, geometry);
  }
  if (!dirtied.empty()) _SendPrimsDirtied(dirtied);
  if (stale.empty()) return;
  std::sort(stale.begin(), stale.end());
  stale.erase(std::unique(stale.begin(), stale.end()), stale.end());
  HdSceneIndexObserver::AddedPrimEntries added;
  HdSceneIndexObserver::RemovedPrimEntries removed;
  _Rebuild(stale, &added, &removed);
  if (!removed.empty()) _SendPrimsRemoved(removed);
  if (!added.empty()) _SendPrimsAdded(added);
}

void HdAkariPrototypeMergingSceneIndex::_PrimsRenamed(HdSceneIndexBase const &sender,
                                                      HdSceneIndexObserver::RenamedPrimEntries const &entries)
{
  HdSceneIndexObserver::RemovedPrimEntries removed;
  HdSceneIndexObserver::AddedPrimEntries added;
  HdSceneIndexObserver::ConvertPrimsRenamedToRemovedAndAdded(sender, entries, &removed, &added);
  if (!removed.empty()) _PrimsRemoved(sender, removed);
  if (!added.empty()) _PrimsAdded(sender, added);
}

PXR_NAMESPACE_CLOSE_SCOPE
