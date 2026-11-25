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

#include "HdAkari/subdivision.h"
#include "HdAkari/sceneData.h"

#if __has_include(<pxr/pxrns.h>)
# include <pxr/pxrns.h>
# include <Gf/vec2f.h>
# include <Gf/vec3f.h>
# include <Gf/vec4f.h>
# include <Hd/sceneDelegate.h>
# include <PxOsd/refinerFactory.h>
# include <PxOsd/tokens.h>
# include <Vt/array.h>
# include <OpenSubdiv/OSDAdaptivePrimvarRefiner.h>
# include <OpenSubdiv/OSDAdaptiveStencilTableFactory.h>
#else
# include <pxr/pxr.h>
# include <pxr/base/gf/vec2f.h>
# include <pxr/base/gf/vec3f.h>
# include <pxr/base/gf/vec4f.h>
# include <pxr/imaging/hd/sceneDelegate.h>
# include <pxr/imaging/pxOsd/refinerFactory.h>
# include <pxr/imaging/pxOsd/tokens.h>
# include <pxr/base/vt/array.h>
# include <opensubdiv/far/primvarRefiner.h>
# include <opensubdiv/far/stencilTableFactory.h>
#endif

#include <algorithm>
#include <numeric>

PXR_NAMESPACE_OPEN_SCOPE

namespace {

namespace Far = OpenSubdiv::Far;

/// a primvar value in the shape the opensubdiv primvar refiner blends
template <class T> struct Blended {
  T value;

  void Clear(void * = nullptr) { value = T(0.0f); }
  void AddWithWeight(Blended const &src, float weight) { value += src.value * weight; }
};

/// calls `body` with the array `value` holds, false for a type we don't refine
template <class Body> bool VisitArray(VtValue const &value, Body &&body)
{
  if (value.IsHolding<VtVec3fArray>()) return body(value.UncheckedGet<VtVec3fArray>());
  if (value.IsHolding<VtVec2fArray>()) return body(value.UncheckedGet<VtVec2fArray>());
  if (value.IsHolding<VtVec4fArray>()) return body(value.UncheckedGet<VtVec4fArray>());
  if (value.IsHolding<VtFloatArray>()) return body(value.UncheckedGet<VtFloatArray>());

  return false;
}

/// the values of every refinement level back to back, starting with the cage
template <class T> struct Levels {
  std::vector<Blended<T>> values;
  size_t lastLevelStart = 0;

  Blended<T> const *LastLevel() const { return values.data() + lastLevelStart; }
};

template <class T>
bool RefineLevels(Far::TopologyRefiner const &far, VtArray<T> const &cage, bool varying, Levels<T> *levels)
{
  const size_t base = size_t(far.GetLevel(0).GetNumVertices());
  if (cage.size() < base) return false;

  levels->values.resize(size_t(far.GetNumVerticesTotal()));
  for (size_t i = 0; i < base; ++i) levels->values[i].value = cage[i];

  Far::PrimvarRefiner refiner(far);
  Blended<T> *level = levels->values.data();
  for (int l = 1; l <= far.GetMaxLevel(); ++l) {
    Blended<T> *next = level + far.GetLevel(l - 1).GetNumVertices();
    if (varying) {
      refiner.InterpolateVarying(l, level, next);
    } else {
      refiner.Interpolate(l, level, next);
    }

    level = next;
  }

  levels->lastLevelStart = size_t(level - levels->values.data());
  return true;
}

template <class T>
bool RefineVertexArray(Far::TopologyRefiner const &far, VtArray<T> const &cage, bool varying, VtValue *out)
{
  Levels<T> levels;
  if (!RefineLevels(far, cage, varying, &levels)) return false;

  VtArray<T> refined(size_t(far.GetLevel(far.GetMaxLevel()).GetNumVertices()));
  for (size_t i = 0; i < refined.size(); ++i) refined[i] = levels.LastLevel()[i].value;

  *out = VtValue(std::move(refined));
  return true;
}

template <class T>
bool RefineFaceVaryingArray(Far::TopologyRefiner const &far, int channel, VtArray<T> const &cage, VtValue *out)
{
  const size_t base = size_t(far.GetLevel(0).GetNumFVarValues(channel));
  if (cage.size() < base) return false;

  std::vector<Blended<T>> values(size_t(far.GetNumFVarValuesTotal(channel)));
  for (size_t i = 0; i < base; ++i) values[i].value = cage[i];

  Far::PrimvarRefiner refiner(far);
  Blended<T> *level = values.data();
  for (int l = 1; l <= far.GetMaxLevel(); ++l) {
    Blended<T> *next = level + far.GetLevel(l - 1).GetNumFVarValues(channel);
    refiner.InterpolateFaceVarying(l, level, next, channel);
    level = next;
  }

  Far::TopologyLevel const &last = far.GetLevel(far.GetMaxLevel());
  VtArray<T> corners;
  corners.reserve(size_t(last.GetNumFaceVertices()));
  for (int f = 0; f < last.GetNumFaces(); ++f) {
    if (last.IsFaceHole(f)) continue;

    for (int v : last.GetFaceFVarValues(f, channel)) corners.push_back(level[v].value);
  }

  *out = VtValue(std::move(corners));
  return true;
}

}  // namespace

struct HdAkariSubdivision::Refiner {
  PxOsdTopologyRefinerSharedPtr far;
};

HdAkariSubdivision::~HdAkariSubdivision() = default;

bool HdAkariSubdivision::IsSubdivisionScheme(TfToken const &scheme)
{
  return scheme == PxOsdOpenSubdivTokens->catmullClark || scheme == PxOsdOpenSubdivTokens->loop ||
         scheme == PxOsdOpenSubdivTokens->bilinear;
}

std::shared_ptr<HdAkariSubdivision>
HdAkariSubdivision::Create(HdMeshTopology const &topology, int level,
                           std::vector<std::pair<TfToken, VtIntArray>> const &faceVarying)
{
  if (level <= 0 || !IsSubdivisionScheme(topology.GetScheme())) return nullptr;

  std::vector<VtIntArray> channels;
  channels.reserve(faceVarying.size());
  for (auto const &[name, indices] : faceVarying) channels.push_back(indices);

  PxOsdTopologyRefinerSharedPtr far = PxOsdRefinerFactory::Create(topology.GetPxOsdMeshTopology(), channels);
  if (!far || far->GetLevel(0).GetNumFaces() == 0) return nullptr;

  Far::TopologyRefiner::UniformOptions options(level);
  options.fullTopologyInLastLevel = true;
  far->RefineUniform(options);
  if (far->GetMaxLevel() <= 0) return nullptr;

  std::shared_ptr<HdAkariSubdivision> result(new HdAkariSubdivision());

  const int maxLevel = far->GetMaxLevel();
  for (auto const &[name, indices] : faceVarying) result->_channels.push_back(name);

  // hand each cage face index down the levels so every refined face knows where it came from
  Far::PrimvarRefiner primvars(*far);
  std::vector<int> faces(size_t(far->GetLevel(0).GetNumFaces()));
  std::iota(faces.begin(), faces.end(), 0);
  for (int l = 1; l <= maxLevel; ++l) {
    std::vector<int> next(size_t(far->GetLevel(l).GetNumFaces()));
    primvars.InterpolateFaceUniform(l, faces, next);
    faces.swap(next);
  }

  Far::TopologyLevel const &last = far->GetLevel(maxLevel);
  VtIntArray counts, indices, baseFaces;
  counts.reserve(size_t(last.GetNumFaces()));
  indices.reserve(size_t(last.GetNumFaceVertices()));
  baseFaces.reserve(size_t(last.GetNumFaces()));

  for (int f = 0; f < last.GetNumFaces(); ++f) {
    if (last.IsFaceHole(f)) continue;

    Far::ConstIndexArray corners = last.GetFaceVertices(f);
    counts.push_back(corners.size());
    for (int v : corners) indices.push_back(v);
    baseFaces.push_back(faces[size_t(f)]);
  }

  // a cage point and its descendant in the last level share the same limit position
  result->_cageVertices.resize(size_t(far->GetLevel(0).GetNumVertices()));
  std::iota(result->_cageVertices.begin(), result->_cageVertices.end(), 0);
  for (int l = 0; l < maxLevel; ++l) {
    Far::TopologyLevel const &parent = far->GetLevel(l);
    for (int &v : result->_cageVertices) v = parent.GetVertexChildVertex(v);
  }

  result->_topology = HdMeshTopology(PxOsdOpenSubdivTokens->none, PxOsdOpenSubdivTokens->rightHanded, counts, indices);
  result->_topology.SetGeomSubsets(topology.GetGeomSubsets());

  result->_baseFaces = std::move(baseFaces);
  result->_refiner = std::make_unique<Refiner>(Refiner{std::move(far)});
  return result;
}

bool HdAkariSubdivision::RefineVertex(VtValue const &value, bool varying, VtValue *out) const
{
  return VisitArray(value, [&](auto const &cage) {
    return RefineVertexArray(*_refiner->far, cage, varying, out);
  });
}

bool HdAkariSubdivision::RefineFaceVarying(TfToken const &name, VtValue const &values, VtValue *out) const
{
  const auto it = std::find(_channels.begin(), _channels.end(), name);
  if (it == _channels.end()) return false;

  const int channel = int(it - _channels.begin());
  return VisitArray(values, [&](auto const &cage) {
    return RefineFaceVaryingArray(*_refiner->far, channel, cage, out);
  });
}

bool HdAkariSubdivision::GetStencils(HdAkariStencils *out) const
{
  Far::TopologyRefiner const &far = *_refiner->far;

  Far::StencilTableFactory::Options options;
  options.interpolationMode = Far::StencilTableFactory::INTERPOLATE_VERTEX;
  options.generateOffsets = true;
  options.generateControlVerts = false;
  options.generateIntermediateLevels = false;
  options.factorizeIntermediateLevels = true;
  options.maxLevel = unsigned(far.GetMaxLevel());

  std::unique_ptr<Far::StencilTable const> table(Far::StencilTableFactory::Create(far, options));
  const int count = table ? table->GetNumStencils() : 0;
  if (count != far.GetLevel(far.GetMaxLevel()).GetNumVertices()) return false;

  std::vector<int> const &offsets = table->GetOffsets();
  std::vector<int> const &sizes = table->GetSizes();

  out->offsets.resize(size_t(count) + 1);
  for (int i = 0; i < count; ++i) out->offsets[size_t(i)] = offsets[size_t(i)];
  out->offsets[size_t(count)] = offsets.empty() ? 0 : offsets.back() + sizes.back();

  out->indices.assign(table->GetControlIndices().begin(), table->GetControlIndices().end());
  out->weights.assign(table->GetWeights().begin(), table->GetWeights().end());
  return true;
}

bool HdAkariSubdivision::LimitCage(VtVec3fArray const &cagePoints, VtVec3fArray *out) const
{
  Far::TopologyRefiner const &far = *_refiner->far;

  Levels<GfVec3f> levels;
  if (!RefineLevels(far, cagePoints, false, &levels)) return false;

  std::vector<Blended<GfVec3f>> limit(size_t(far.GetLevel(far.GetMaxLevel()).GetNumVertices()));
  Far::PrimvarRefiner(far).Limit(levels.LastLevel(), limit);

  out->resize(_cageVertices.size());
  for (size_t i = 0; i < _cageVertices.size(); ++i) (*out)[i] = limit[size_t(_cageVertices[i])].value;

  return true;
}

bool HdAkariRefinedPrimvars::Get(HdSceneDelegate *sceneDelegate, SdfPath const &id, TfToken const &name,
                                 HdInterpolation interpolation, VtValue *out) const
{
  VtIntArray indices;
  VtValue value = sceneDelegate->GetIndexedPrimvar(id, name, &indices);
  if (value.IsEmpty()) return false;
  if (interpolation == HdInterpolationFaceVarying) return subdivision->RefineFaceVarying(name, value, out);

  // indexed primvars are expanded to flat arrays before they get refined
  if (!indices.empty()) {
    const bool flattened = VisitArray(value, [&](auto const &values) {
      std::decay_t<decltype(values)> flat(indices.size());
      for (size_t i = 0; i < indices.size(); ++i) {
        const int at = indices[i];
        if (at >= 0 && size_t(at) < values.size()) flat[i] = values[size_t(at)];
      }

      value = VtValue(std::move(flat));
      return true;
    });

    if (!flattened) return false;
  }

  if (interpolation == HdInterpolationVertex || interpolation == HdInterpolationVarying) {
    return subdivision->RefineVertex(value, interpolation == HdInterpolationVarying, out);
  }

  // uniform values stay per cage face since every refined face maps back to its cage face
  *out = value;
  return true;
}

PXR_NAMESPACE_CLOSE_SCOPE
