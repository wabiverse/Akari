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
# include <Hd/changeTracker.h>
# include <Hd/instancer.h>
# include <Hd/meshTopology.h>
# include <Hd/meshUtil.h>
# include <Hd/renderIndex.h>
# include <Hd/repr.h>
# include <Hd/sceneDelegate.h>
# include <Hd/tokens.h>
# include <PxOsd/tokens.h>
# include <Gf/vec3f.h>
# include <Vt/value.h>
#else
# include <pxr/pxr.h>
# include <pxr/imaging/hd/changeTracker.h>
# include <pxr/imaging/hd/instancer.h>
# include <pxr/imaging/hd/meshTopology.h>
# include <pxr/imaging/hd/meshUtil.h>
# include <pxr/imaging/hd/renderIndex.h>
# include <pxr/imaging/hd/repr.h>
# include <pxr/imaging/hd/sceneDelegate.h>
# include <pxr/imaging/hd/tokens.h>
# include <pxr/imaging/pxOsd/tokens.h>
# include <pxr/base/gf/vec3f.h>
# include <pxr/base/vt/value.h>
#endif

#include "HdAkari/basisCurves.h"
#include "HdAkari/instancer.h"
#include "HdAkari/materialBinding.h"
#include "HdAkari/renderParam.h"
#include "HdAkari/scene.h"
#include "HdAkari/style.h"
#include "HdAkari/textureAtlas.h"

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

PXR_NAMESPACE_OPEN_SCOPE

namespace {

/// The most tube vertices one curve prim expands into, shared by all of its
/// curves. A dense scatter can hold millions of tiny curves, which would
/// otherwise tessellate into billions of vertices and exhaust memory before
/// the first frame. Curves past the budget are sampled out evenly.
constexpr size_t HdAkariMaxCurveVertices = 1'000'000;

/// The most tube vertices every curve prim in the scene expands into.
constexpr size_t HdAkariMaxSceneCurveVertices = 12'000'000;

/// `id`'s share of the scene's curve budget, by the square root of how many
/// control vertices it holds against every curve prim's, counted once per
/// render index, so a palm's crown keeps its leaflets beside ground cover
/// with millions of curves.
size_t CurveVertexBudget(HdSceneDelegate *delegate, SdfPath const &id)
{
  constexpr size_t minimum = 4096;
  static std::mutex mutex;
  static HdRenderIndex const *cached = nullptr;
  static std::unordered_map<SdfPath, size_t, SdfPath::Hash> shares;
  static size_t fallback = HdAkariMaxCurveVertices;

  HdRenderIndex &index = delegate->GetRenderIndex();
  std::lock_guard<std::mutex> lock(mutex);
  if (cached != &index) {
    cached = &index;
    shares.clear();
    size_t budget = HdAkariMaxSceneCurveVertices;
    if (const char *env = std::getenv("AKARI_CURVE_VERTEX_BUDGET")) {
      budget = std::max<size_t>(1, std::strtoull(env, nullptr, 10));
    }
    std::vector<std::pair<SdfPath, size_t>> counts;
    size_t total = 0;
    for (SdfPath const &rprimId : index.GetRprimIds()) {
      if (!dynamic_cast<HdBasisCurves const *>(index.GetRprim(rprimId))) continue;
      const HdBasisCurvesTopology topology = delegate->GetBasisCurvesTopology(rprimId);
      size_t cvs = 0;
      for (int c : topology.GetCurveVertexCounts()) cvs += size_t(std::max(c, 0));
      const size_t weight = size_t(std::sqrt(double(cvs)) * 1024.0);
      counts.emplace_back(rprimId, weight);
      total += weight;
    }
    const size_t cap = std::max(minimum, std::min(budget, HdAkariMaxCurveVertices));
    fallback = std::clamp(budget / std::max<size_t>(1, counts.size()), std::min(minimum, cap), cap);
    for (auto const &[path, weight] : counts) {
      const size_t share = total ? size_t(double(budget) * double(weight) / double(total)) : fallback;
      shares[path] = std::clamp(share, std::min(minimum, cap), cap);
    }
  }
  const auto found = shares.find(id);
  return found == shares.end() ? fallback : found->second;
}

/// Warns once per prim that its curves were sampled, so a dense scatter is
/// visible in the log without printing on every sync.
void WarnCurvesSampled(SdfPath const &id, size_t total, size_t kept)
{
  static std::mutex mutex;
  static std::unordered_set<std::string> warned;
  std::lock_guard<std::mutex> lock(mutex);
  if (!warned.insert(id.GetString()).second) return;
  std::fprintf(stderr,
               "HdAkari: %s has %zu curves, drawing %zu of them sampled evenly; "
               "the rest would exceed the curve geometry budget.\n",
               id.GetString().c_str(), total, kept);
}

struct CurvePoint
{
  GfVec3f p;
  float width;
};

// a cubic segment's point at t, the four control points weighted by its basis.
CurvePoint Cubic(TfToken const &basis, CurvePoint const *c, float t)
{
  float w[4];
  const float t2 = t * t, t3 = t2 * t, s = 1.0f - t;
  if (basis == HdTokens->bezier) {
    w[0] = s * s * s; w[1] = 3.0f * s * s * t; w[2] = 3.0f * s * t2; w[3] = t3;
  } else if (basis == HdTokens->catmullRom) {
    w[0] = 0.5f * (-t3 + 2.0f * t2 - t);
    w[1] = 0.5f * (3.0f * t3 - 5.0f * t2 + 2.0f);
    w[2] = 0.5f * (-3.0f * t3 + 4.0f * t2 + t);
    w[3] = 0.5f * (t3 - t2);
  } else {
    w[0] = s * s * s / 6.0f;
    w[1] = (3.0f * t3 - 6.0f * t2 + 4.0f) / 6.0f;
    w[2] = (-3.0f * t3 + 3.0f * t2 + 3.0f * t + 1.0f) / 6.0f;
    w[3] = t3 / 6.0f;
  }
  CurvePoint out{GfVec3f(0.0f), 0.0f};
  for (int k = 0; k < 4; ++k) {
    out.p += c[k].p * w[k];
    out.width += c[k].width * w[k];
  }
  return out;
}

/// How many points `Evaluate` produces for one curve, without evaluating it.
size_t EvaluatedPointCount(int count, TfToken const &type, TfToken const &basis,
                           bool periodic, int samples)
{
  if (count <= 0) return 0;
  if (type != HdTokens->cubic || count < 4) return size_t(count) + (periodic ? 1 : 0);

  const bool bezier = basis == HdTokens->bezier;
  size_t ctrl = size_t(count);
  if (periodic) ctrl += bezier ? 1 : 3;
  else if (!bezier) ctrl += 2;

  const size_t step = bezier ? 3 : 1;
  size_t segments = 0;
  for (size_t s = 0; s + 3 < ctrl; s += step) ++segments;
  return segments == 0 ? 0 : segments * size_t(samples) + 1;
}

// the curve evaluated into a polyline, cubic segments `samples` each.
std::vector<CurvePoint> Evaluate(std::vector<CurvePoint> const &cv, TfToken const &type,
                                 TfToken const &basis, bool periodic, int samples)
{
  if (type != HdTokens->cubic || cv.size() < 4) {
    std::vector<CurvePoint> out = cv;
    if (periodic && !cv.empty()) out.push_back(cv.front());
    return out;
  }
  std::vector<CurvePoint> ctrl = cv;
  const bool bezier = basis == HdTokens->bezier;
  if (periodic) {
    if (bezier) ctrl.push_back(cv.front());
    else for (int k = 0; k < 3; ++k) ctrl.push_back(cv[k % cv.size()]);
  } else if (!bezier) {
    ctrl.insert(ctrl.begin(), cv.front());
    ctrl.push_back(cv.back());
  }
  const size_t step = bezier ? 3 : 1;
  std::vector<CurvePoint> out;
  out.reserve(EvaluatedPointCount(int(cv.size()), type, basis, periodic, samples));
  for (size_t s = 0; s + 3 < ctrl.size(); s += step) {
    for (int i = (out.empty() ? 0 : 1); i <= samples; ++i) {
      out.push_back(Cubic(basis, &ctrl[s], float(i) / samples));
    }
  }
  return out;
}

// a tube of `sides` around the polyline, frames carried along it so it doesn't twist.
/// A flat strip along `line`, across the up axis where it can be, two
/// triangles a segment where a tube takes twelve.
void Ribbon(std::vector<CurvePoint> const &line, VtVec3fArray &points, VtVec3iArray &tris)
{
  const size_t base = points.size();
  points.reserve(base + line.size() * 2);
  for (size_t i = 0; i < line.size(); ++i) {
    const GfVec3f t = (i + 1 < line.size() ? line[i + 1].p - line[i].p : line[i].p - line[i - 1].p).GetNormalized();
    GfVec3f across = GfCross(t, GfVec3f(0, 1, 0));
    if (across.GetLength() < 1e-3f) across = GfCross(t, GfVec3f(1, 0, 0));
    across = across.GetNormalized() * std::max(line[i].width * 0.5f, 1e-5f);
    points.push_back(line[i].p + across);
    points.push_back(line[i].p - across);
  }
  for (size_t i = 0; i + 1 < line.size(); ++i) {
    const int a = int(base + i * 2);
    tris.push_back(GfVec3i(a, a + 1, a + 3));
    tris.push_back(GfVec3i(a, a + 3, a + 2));
  }
}

void Tube(std::vector<CurvePoint> const &line, int sides, VtVec3fArray &points, VtVec3iArray &tris)
{
  if (line.size() < 2) return;
  if (sides == 2) {
    Ribbon(line, points, tris);
    return;
  }
  const size_t base = points.size();
  const size_t triBase = tris.size();
  const size_t ringVerts = line.size() * size_t(sides);
  const size_t ringTris = (line.size() - 1) * size_t(sides) * 2;
  points.resize(base + ringVerts);
  tris.resize(triBase + ringTris);
  GfVec3f *dstPoints = points.data() + base;
  GfVec3i *dstTris = tris.data() + triBase;

  GfVec3f tangent = (line[1].p - line[0].p).GetNormalized();
  GfVec3f normal = std::abs(tangent[1]) < 0.9f ? GfCross(tangent, GfVec3f(0, 1, 0)).GetNormalized()
                                               : GfCross(tangent, GfVec3f(1, 0, 0)).GetNormalized();
  for (size_t i = 0; i < line.size(); ++i) {
    const GfVec3f ahead = i + 1 < line.size() ? line[i + 1].p - line[i].p : line[i].p - line[i - 1].p;
    const GfVec3f behind = i > 0 ? line[i].p - line[i - 1].p : ahead;
    GfVec3f t = (ahead.GetNormalized() + behind.GetNormalized());
    if (t.GetLength() < 1e-6f) t = ahead;
    t.Normalize();
    normal = (normal - t * GfDot(normal, t));
    if (normal.GetLength() < 1e-6f) normal = std::abs(t[1]) < 0.9f ? GfCross(t, GfVec3f(0, 1, 0)) : GfCross(t, GfVec3f(1, 0, 0));
    normal.Normalize();
    const GfVec3f binormal = GfCross(t, normal);
    const float r = std::max(line[i].width * 0.5f, 1e-5f);
    GfVec3f *ring = dstPoints + i * size_t(sides);
    for (int k = 0; k < sides; ++k) {
      const float a = 2.0f * float(M_PI) * float(k) / float(sides);
      ring[k] = line[i].p + (normal * std::cos(a) + binormal * std::sin(a)) * r;
    }
  }
  for (size_t i = 0; i + 1 < line.size(); ++i) {
    GfVec3i *quads = dstTris + i * size_t(sides) * 2;
    for (int k = 0; k < sides; ++k) {
      const int a = int(i) * sides + k, b = int(i) * sides + (k + 1) % sides;
      const int c = a + sides, d = b + sides;
      quads[k * 2] = GfVec3i(a, b, d);
      quads[k * 2 + 1] = GfVec3i(a, d, c);
    }
  }
}

} // namespace

HdAkariBasisCurves::HdAkariBasisCurves(SdfPath const &id) : HdBasisCurves(id) {}

HdAkariBasisCurves::~HdAkariBasisCurves() = default;

HdDirtyBits
HdAkariBasisCurves::GetInitialDirtyBitsMask() const
{
  return HdChangeTracker::Clean | HdChangeTracker::DirtyTopology | HdChangeTracker::DirtyPoints |
         HdChangeTracker::DirtyTransform | HdChangeTracker::DirtyVisibility | HdChangeTracker::DirtyPrimvar |
         HdChangeTracker::DirtyWidths | HdChangeTracker::DirtyMaterialId | HdChangeTracker::DirtyInstancer |
         HdChangeTracker::DirtyInstanceIndex;
}

HdDirtyBits
HdAkariBasisCurves::_PropagateDirtyBits(HdDirtyBits bits) const
{
  return bits;
}

void
HdAkariBasisCurves::_InitRepr(TfToken const &reprToken, HdDirtyBits *dirtyBits)
{
  const auto it = std::find_if(_reprs.begin(), _reprs.end(), _ReprComparator(reprToken));
  if (it == _reprs.end()) {
    _reprs.emplace_back(reprToken, std::make_shared<HdRepr>());
    *dirtyBits |= HdChangeTracker::NewRepr;
  }
}

void
HdAkariBasisCurves::Sync(HdSceneDelegate *sceneDelegate,
                         HdRenderParam   *renderParam,
                         HdDirtyBits     *dirtyBits,
                         TfToken const   & /*reprToken*/)
{
  const SdfPath &id = GetId();
  auto *param = static_cast<HdAkariRenderParam *>(renderParam);
  HdAkariScene *scene = param ? param->GetScene() : nullptr;
  if (!scene) {
    *dirtyBits = HdChangeTracker::Clean;
    return;
  }
  HdAkariSyncStyle(sceneDelegate, id, GetPrimId(), scene);

  HdAkariMeshData data;
  data.id = id;
  data.primId = GetPrimId();
  data.transform = sceneDelegate->GetTransform(id);
  data.visible = sceneDelegate->GetVisible(id);

  const HdDirtyBits geometryBits = HdChangeTracker::DirtyTopology | HdChangeTracker::DirtyPoints |
                                   HdChangeTracker::DirtyWidths;
  const bool rebuildGeometry = !_geometryBuilt || (*dirtyBits & geometryBits) != 0;

  if (rebuildGeometry) {
    const HdBasisCurvesTopology topology = GetBasisCurvesTopology(sceneDelegate);
    const VtValue pointsVal = sceneDelegate->Get(id, HdTokens->points);
    const VtValue widthsVal = sceneDelegate->Get(id, HdTokens->widths);
    // const, a non-const VtArray detaches from Hydra's on its first element access.
    const VtVec3fArray cv = pointsVal.IsHolding<VtVec3fArray>() ? pointsVal.UncheckedGet<VtVec3fArray>() : VtVec3fArray();
    const VtFloatArray widths = widthsVal.IsHolding<VtFloatArray>() ? widthsVal.UncheckedGet<VtFloatArray>()
                              : widthsVal.IsHolding<float>() ? VtFloatArray(1, widthsVal.UncheckedGet<float>())
                              : widthsVal.IsHolding<double>() ? VtFloatArray(1, float(widthsVal.UncheckedGet<double>()))
                              : VtFloatArray();

    const VtIntArray counts = topology.GetCurveVertexCounts();
    const bool periodic = topology.GetCurveWrap() == HdTokens->periodic;
    const TfToken &type = topology.GetCurveType();
    const TfToken &basis = topology.GetCurveBasis();
    const float maxWidth = widths.empty() ? 0.01f : *std::max_element(widths.begin(), widths.end());

    // Dense scatters (grass, needles, a palm's four thousand leaflets) are
    // flat ribbons with a sample per segment, so a prim with thousands of
    // curves stays affordable. Sparse, prominent curves keep round tubes.
    const size_t curveCount = counts.size();
    const int samples = curveCount > 1000 ? 1 : 8;
    const int sides = curveCount > 1000 ? 2 : maxWidth > 0.02f ? 8 : 6;

    // Bound one prim's tubes, sampling whole curves evenly when they exceed it.
    const size_t vertexBudget = CurveVertexBudget(sceneDelegate, id);
    const size_t triangleBudget = vertexBudget * 2;
    size_t totalVertices = 0, totalTriangles = 0, offset = 0;
    for (int count : counts) {
      if (count <= 0 || offset + size_t(count) > cv.size()) break;
      const size_t n = EvaluatedPointCount(count, type, basis, periodic, samples);
      if (n >= 2) {
        totalVertices += n * size_t(sides);
        totalTriangles += (n - 1) * size_t(sides == 2 ? 1 : sides) * 2;
      }
      offset += size_t(count);
    }
    const size_t stride = std::max<size_t>(
        {1, (totalVertices + vertexBudget - 1) / vertexBudget,
         (totalTriangles + triangleBudget - 1) / triangleBudget});
    const size_t kept = (curveCount + stride - 1) / stride;
    if (stride > 1) WarnCurvesSampled(id, curveCount, kept);

    // Reserve the exact selected geometry before appending, so a dense prim
    // doesn't repeatedly double its buffers while it tessellates.
    size_t reserveVertices = 0, reserveTriangles = 0;
    offset = 0;
    for (size_t c = 0; c < counts.size(); ++c) {
      const int count = counts[c];
      if (count <= 0 || offset + size_t(count) > cv.size()) break;
      if (c % stride == 0) {
        const size_t n = EvaluatedPointCount(count, type, basis, periodic, samples);
        if (n >= 2) {
          reserveVertices += n * size_t(sides);
          reserveTriangles += (n - 1) * size_t(sides == 2 ? 1 : sides) * 2;
        }
      }
      offset += size_t(count);
    }
    data.points.reserve(reserveVertices);
    data.triangleIndices.reserve(reserveTriangles);

    offset = 0;
    for (size_t c = 0; c < counts.size(); ++c) {
      const int count = counts[c];
      if (count <= 0 || offset + size_t(count) > cv.size()) break;
      if (c % stride == 0) {
        std::vector<CurvePoint> line(size_t(count), CurvePoint{GfVec3f(0.0f), 0.0f});
        for (int i = 0; i < count; ++i) {
          const size_t v = offset + size_t(i);
          const float w = widths.empty() ? 0.01f
                        : widths.size() == cv.size() ? widths[v]
                        : widths.size() == counts.size() ? widths[c] : widths[0];
          line[size_t(i)] = CurvePoint{cv[v], w};
        }
        Tube(Evaluate(line, type, basis, periodic, samples), sides, data.points, data.triangleIndices);
      }
      offset += size_t(count);
    }

    _tubePoints = data.points;
    _tubeTriangles = data.triangleIndices;
    _geometryBuilt = true;
  } else {
    data.points = _tubePoints;
    data.triangleIndices = _tubeTriangles;
  }

  const VtValue colorVal = sceneDelegate->Get(id, HdTokens->displayColor);
  if (colorVal.IsHolding<VtVec3fArray>() && !colorVal.UncheckedGet<VtVec3fArray>().empty()) {
    data.displayColor = colorVal.UncheckedGet<VtVec3fArray>()[0];
  }

  VtIntArray faceCounts(data.triangleIndices.size(), 3);
  VtIntArray faceIndices(data.triangleIndices.size() * 3);
  for (size_t t = 0; t < data.triangleIndices.size(); ++t) {
    for (int k = 0; k < 3; ++k) faceIndices[t * 3 + k] = data.triangleIndices.cdata()[t][k];
  }
  HdMeshTopology mesh(PxOsdOpenSubdivTokens->none, HdTokens->rightHanded, faceCounts, faceIndices);
  HdMeshUtil meshUtil(&mesh, id);
  HdAkariTextureAtlas *atlas = param->GetTextureAtlas();
  if (atlas) atlas->EnsureGridSized(sceneDelegate);
  HdAkariSyncMaterial(sceneDelegate, id, atlas, meshUtil, data);
  data.dataRevision = ++_dataGeneration;
  data.topologyRevision = data.dataRevision;

  _UpdateInstancer(sceneDelegate, dirtyBits);
  const SdfPath instancerId = GetInstancerId();
  if (!instancerId.IsEmpty()) {
    HdInstancer::_SyncInstancerAndParents(sceneDelegate->GetRenderIndex(), instancerId);
    HdAkariInstanceSet set = HdAkariInstances(sceneDelegate->GetRenderIndex(), instancerId, id);
    data.instances = std::move(set.transforms);
    data.instancesKey = set.key;
  }
  if (data.triangleIndices.empty() || (!instancerId.IsEmpty() && data.instances.empty())) {
    scene->RemoveMesh(id);
  } else {
    data.contentKey = HdAkariMeshContentKey(data);
    scene->UpdateMesh(std::move(data));
  }

  *dirtyBits = HdChangeTracker::Clean;
}

void
HdAkariBasisCurves::Finalize(HdRenderParam *renderParam)
{
  if (auto *param = static_cast<HdAkariRenderParam *>(renderParam)) {
    if (HdAkariScene *scene = param->GetScene()) {
      scene->RemoveMesh(GetId());
      scene->RemoveStyle(GetPrimId());
    }
  }
}

PXR_NAMESPACE_CLOSE_SCOPE
