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
# include <Hd/extComputation.h>
# include <Hd/extComputationUtils.h>
# include <Hd/material.h>
# include <Hd/meshTopology.h>
# include <Hd/meshUtil.h>
# include <Hd/renderIndex.h>
# include <Hd/repr.h>
# include <Hd/instancer.h>
# include <Hd/sceneDelegate.h>
# include <Hd/tokens.h>
# include <Hd/types.h>
# include <PxOsd/tokens.h>
# include <Sdf/assetPath.h>
# include <Gf/matrix4f.h>
# include <Gf/vec2f.h>
# include <Tf/staticTokens.h>
#else
# include <pxr/pxr.h>
# include <pxr/imaging/hd/changeTracker.h>
# include <pxr/imaging/hd/extComputation.h>
# include <pxr/imaging/hd/extComputationUtils.h>
# include <pxr/imaging/hd/material.h>
# include <pxr/imaging/hd/meshTopology.h>
# include <pxr/imaging/hd/meshUtil.h>
# include <pxr/imaging/hd/renderIndex.h>
# include <pxr/imaging/hd/repr.h>
# include <pxr/imaging/hd/instancer.h>
# include <pxr/imaging/hd/sceneDelegate.h>
# include <pxr/imaging/hd/tokens.h>
# include <pxr/imaging/hd/types.h>
# include <pxr/imaging/pxOsd/tokens.h>
# include <pxr/usd/sdf/assetPath.h>
# include <pxr/base/gf/matrix4f.h>
# include <pxr/base/gf/vec2f.h>
# include <pxr/base/tf/staticTokens.h>
#endif

#include "HdAkari/mesh.h"
#include "HdAkari/style.h"
#include "HdAkari/instancer.h"
#include "HdAkari/lightProbe.h"
#include "HdAkari/materialBinding.h"
#include "HdAkari/renderParam.h"
#include "HdAkari/scene.h"
#include "HdAkari/textureAtlas.h"
#include "HdAkari/subdivision.h"
#include "HdAkari/stageInfo.h"

#include <algorithm>
#include <atomic>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <mutex>
#include <string>
#include <unordered_map>
#include <vector>

PXR_NAMESPACE_OPEN_SCOPE

TF_DEFINE_PRIVATE_TOKENS(_skinTokens,
  (restPoints)
  (geomBindXform)
  (influences)
  (numInfluencesPerComponent)
  (hasConstantInfluences)
  (blendShapeOffsets)
  (skinningXforms)
  (skinningDualQuats)
  (skelLocalToWorld)
  (primWorldToLocal)
);

// in arrayBins.cpp, the triangulation shared by every mesh with hydra's topology hash.
void HdAkariTriangulate(HdMeshTopology const &topology, HdMeshUtil &meshUtil, VtVec3iArray *triangles,
                        VtIntArray *params);

namespace {

// skinned meshes publish their points through an ext computation
VtValue GetPoints(HdSceneDelegate *sceneDelegate, SdfPath const &id)
{
  for (HdExtComputationPrimvarDescriptor const &pv : sceneDelegate->GetExtComputationPrimvarDescriptors(id, HdInterpolationVertex)) {
    if (pv.name != HdTokens->points) continue;

    const HdExtComputationUtils::ValueStore store = HdExtComputationUtils::GetComputedPrimvarValues({pv}, sceneDelegate);

    const auto it = store.find(pv.name);
    if (it != store.end()) return it->second;
  }

  return sceneDelegate->Get(id, HdTokens->points);
}

// the skinning computation behind the points when it offers a gpu kernel, the same test storm makes
SdfPath GpuSkinComputation(HdSceneDelegate *sceneDelegate, SdfPath const &id)
{
  for (HdExtComputationPrimvarDescriptor const &pv : sceneDelegate->GetExtComputationPrimvarDescriptors(id, HdInterpolationVertex)) {
    if (pv.name != HdTokens->points) continue;

    auto const *comp = static_cast<HdExtComputation const *>(
      sceneDelegate->GetRenderIndex().GetSprim(HdPrimTypeTokens->extComputation, pv.sourceComputationId));
    if (!comp || comp->GetGpuKernelSource().empty()) return SdfPath();
    if (comp->GetGpuKernelSource().find(_skinTokens->skinningDualQuats.GetString()) != std::string::npos) return SdfPath();
    return pv.sourceComputationId;
  }

  return SdfPath();
}

// a skinning input, resolved through the aggregator computation that holds the rest data.
VtValue SkinInput(HdSceneDelegate *sceneDelegate, SdfPath const &comp, TfToken const &name)
{
  for (HdExtComputationInputDescriptor const &in : sceneDelegate->GetExtComputationInputDescriptors(comp)) {
    if (in.name == name) return sceneDelegate->GetExtComputationInput(in.sourceComputationId, in.sourceComputationOutputName);
  }

  return sceneDelegate->GetExtComputationInput(comp, name);
}

GfMatrix4f SkinMatrix(VtValue const &value)
{
  if (value.IsHolding<GfMatrix4f>()) return value.UncheckedGet<GfMatrix4f>();
  if (value.IsHolding<GfMatrix4d>()) return GfMatrix4f(value.UncheckedGet<GfMatrix4d>());
  return GfMatrix4f(1.0f);
}

// the bind space rest points, per point influences and each joint's rest bounds.
bool ReadSkinRest(HdSceneDelegate *sceneDelegate, SdfPath const &comp, size_t jointCount,
                  HdAkariMeshData &data, std::vector<float> &jointBounds)
{
  const VtValue offsets = SkinInput(sceneDelegate, comp, _skinTokens->blendShapeOffsets);
  if (offsets.IsHolding<VtVec4fArray>() && !offsets.UncheckedGet<VtVec4fArray>().empty()) return false;

  const VtValue restVal = SkinInput(sceneDelegate, comp, _skinTokens->restPoints);
  const VtValue inflVal = SkinInput(sceneDelegate, comp, _skinTokens->influences);
  const VtValue countVal = SkinInput(sceneDelegate, comp, _skinTokens->numInfluencesPerComponent);
  const VtValue constVal = SkinInput(sceneDelegate, comp, _skinTokens->hasConstantInfluences);
  if (!restVal.IsHolding<VtVec3fArray>() || !inflVal.IsHolding<VtVec2fArray>() || !countVal.IsHolding<int>()) return false;

  const VtVec3fArray &rest = restVal.UncheckedGet<VtVec3fArray>();
  const VtVec2fArray &infl = inflVal.UncheckedGet<VtVec2fArray>();
  const int k = countVal.UncheckedGet<int>();
  const bool constant = constVal.IsHolding<bool>() && constVal.UncheckedGet<bool>();
  const size_t n = rest.size();
  if (k <= 0 || n == 0 || infl.size() != (constant ? size_t(k) : n * k)) return false;

  const GfMatrix4f bind = SkinMatrix(SkinInput(sceneDelegate, comp, _skinTokens->geomBindXform));
  VtVec3fArray points(n);
  VtVec2fArray perPoint(n * k);
  jointBounds.assign(jointCount * 6, 0.0f);
  for (size_t j = 0; j < jointCount; ++j) {
    for (int a = 0; a < 3; ++a) { jointBounds[j * 6 + a] = 3.4e38f; jointBounds[j * 6 + 3 + a] = -3.4e38f; }
  }

  for (size_t i = 0; i < n; ++i) {
    const GfVec3f p = bind.Transform(rest[i]);
    points[i] = p;
    for (int c = 0; c < k; ++c) {
      const GfVec2f w = infl[constant ? c : i * k + c];
      perPoint[i * k + c] = w;
      const int j = int(w[0]);
      if (w[1] <= 1e-5f || j < 0 || size_t(j) >= jointCount) continue;
      for (int a = 0; a < 3; ++a) {
        jointBounds[j * 6 + a] = std::min(jointBounds[j * 6 + a], p[a]);
        jointBounds[j * 6 + 3 + a] = std::max(jointBounds[j * 6 + 3 + a], p[a]);
      }
    }
  }

  data.points = std::move(points);
  data.skinInfluences = std::move(perPoint);
  data.skinInfluencesPerPoint = k;
  return true;
}

// this frame's per joint bind space to prim local matrices.
bool ReadSkinXforms(HdSceneDelegate *sceneDelegate, SdfPath const &comp, std::vector<float> const &jointBounds,
                    VtMatrix4fArray &out, GfVec3f &lo, GfVec3f &hi)
{
  const VtValue xfVal = SkinInput(sceneDelegate, comp, _skinTokens->skinningXforms);
  if (!xfVal.IsHolding<VtMatrix4fArray>()) return false;
  const VtMatrix4fArray &skin = xfVal.UncheckedGet<VtMatrix4fArray>();
  if (skin.size() * 6 != jointBounds.size()) return false;

  const VtValue skelVal = SkinInput(sceneDelegate, comp, _skinTokens->skelLocalToWorld);
  const VtValue primVal = SkinInput(sceneDelegate, comp, _skinTokens->primWorldToLocal);
  const GfMatrix4d skel = skelVal.IsHolding<GfMatrix4d>() ? skelVal.UncheckedGet<GfMatrix4d>() : GfMatrix4d(1.0);
  const GfMatrix4d prim = primVal.IsHolding<GfMatrix4d>() ? primVal.UncheckedGet<GfMatrix4d>() : GfMatrix4d(1.0);
  const GfMatrix4f toLocal(skel * prim);

  out.resize(skin.size());
  lo = GfVec3f(3.4e38f); hi = GfVec3f(-3.4e38f);
  for (size_t j = 0; j < skin.size(); ++j) {
    out[j] = skin[j] * toLocal;
    const float *b = &jointBounds[j * 6];
    if (b[0] > b[3]) continue;
    for (int corner = 0; corner < 8; ++corner) {
      const GfVec3f p = out[j].Transform(GfVec3f(corner & 1 ? b[3] : b[0], corner & 2 ? b[4] : b[1], corner & 4 ? b[5] : b[2]));
      for (int a = 0; a < 3; ++a) { lo[a] = std::min(lo[a], p[a]); hi[a] = std::max(hi[a], p[a]); }
    }
  }

  if (lo[0] > hi[0]) lo = hi = GfVec3f(0.0f);
  return true;
}

// packs a varying display color 8 bits a channel into the y of each untextured corner's uv for the shaders to unpack
void PackCornerColors(HdSceneDelegate *sceneDelegate, SdfPath const &id, HdMeshUtil &meshUtil,
                      VtVec3iArray const &tris, VtIntArray const &primitiveParams, VtVec2fArray &uvs,
                      HdAkariRefinedPrimvars const *refined)
{
  const size_t corners = tris.size() * 3;
  if (uvs.size() != corners && uvs.size() != 1) return;
  HdInterpolation interp = HdInterpolationConstant;
  bool found = false;
  for (int i = 0; i < HdInterpolationCount && !found; ++i) {
    for (HdPrimvarDescriptor const &pv : sceneDelegate->GetPrimvarDescriptors(id, HdInterpolation(i))) {
      if (pv.name == HdTokens->displayColor) { interp = HdInterpolation(i); found = true; break; }
    }
  }

  if (!found || interp == HdInterpolationConstant) return;
  VtValue value;
  if (refined) {
    if (!refined->Get(sceneDelegate, id, HdTokens->displayColor, interp, &value)) return;
  } else {
    value = sceneDelegate->Get(id, HdTokens->displayColor);
  }
  if (!value.IsHolding<VtVec3fArray>()) return;
  VtVec3fArray const &colors = value.UncheckedGet<VtVec3fArray>();
  if (colors.size() < 2) return;

  VtVec3fArray perCorner(corners);
  if (interp == HdInterpolationVertex || interp == HdInterpolationVarying) {
    for (size_t t = 0; t < tris.size(); ++t) {
      for (int c = 0; c < 3; ++c) {
        const int idx = tris[t][c];
        perCorner[t * 3 + c] = idx >= 0 && size_t(idx) < colors.size() ? colors[idx] : GfVec3f(1.0f);
      }
    }
  } else if (interp == HdInterpolationFaceVarying) {
    if (!HdAkariTriangulateFaceVarying(meshUtil, colors, perCorner) || perCorner.size() != corners) return;
  } else if (interp == HdInterpolationUniform && primitiveParams.size() == tris.size()) {
    for (size_t t = 0; t < tris.size(); ++t) {
      const int face = HdMeshUtil::DecodeFaceIndexFromCoarseFaceParam(primitiveParams[t]);
      const GfVec3f c = face >= 0 && size_t(face) < colors.size() ? colors[face] : GfVec3f(1.0f);
      for (int k = 0; k < 3; ++k) perCorner[t * 3 + k] = c;
    }
  } else {
    return;
  }

  // a constant material keeps one uv for the whole mesh, spread over the corners only when the material reads the color
  if (uvs.size() == 1) {
    if (!HdAkariShowsDisplayColor(sceneDelegate, id)) return;
    uvs = VtVec2fArray(corners, uvs[0]);
  }

  for (size_t i = 0; i < corners; ++i) {
    if (uvs[i][0] >= 0.0f) continue;
    auto channel = [&](int k) { return uint32_t(std::clamp(perCorner[i][k], 0.0f, 1.0f) * 255.0f + 0.5f); };
    uvs[i][1] = float((channel(0) << 16) | (channel(1) << 8) | channel(2)) + 1.0f;
  }
}

/// the interpolation the mesh authors its normals with, false when it authors none
bool NormalsInterpolation(HdSceneDelegate *sceneDelegate, SdfPath const &id, HdInterpolation *interp)
{
  for (int i = 0; i < HdInterpolationCount; ++i) {
    for (HdPrimvarDescriptor const &pv : sceneDelegate->GetPrimvarDescriptors(id, HdInterpolation(i))) {
      if (pv.name != HdTokens->normals) continue;

      *interp = HdInterpolation(i);
      return true;
    }
  }

  return false;
}

/// a polygon mesh's authored normals, one per triangle corner, empty when it authors none or they don't fit
VtVec3fArray CornerNormals(HdSceneDelegate *sceneDelegate, SdfPath const &id, HdMeshUtil &meshUtil,
                           VtVec3iArray const &tris, VtIntArray const &primitiveParams)
{
  HdInterpolation interp = HdInterpolationConstant;
  if (!NormalsInterpolation(sceneDelegate, id, &interp)) return {};

  const VtValue value = sceneDelegate->Get(id, HdTokens->normals);
  if (!value.IsHolding<VtVec3fArray>()) return {};

  VtVec3fArray const &normals = value.UncheckedGet<VtVec3fArray>();
  if (normals.empty()) return {};

  const size_t corners = tris.size() * 3;
  VtVec3fArray perCorner(corners);

  switch (interp) {
    case HdInterpolationConstant:
      std::fill(perCorner.begin(), perCorner.end(), normals[0]);
      break;

    case HdInterpolationVertex:
    case HdInterpolationVarying:
      for (size_t t = 0; t < tris.size(); ++t) {
        for (int c = 0; c < 3; ++c) {
          const int idx = tris[t][c];
          if (idx < 0 || size_t(idx) >= normals.size()) return {};
          perCorner[t * 3 + c] = normals[size_t(idx)];
        }
      }
      break;

    case HdInterpolationUniform:
      if (primitiveParams.size() != tris.size()) return {};
      for (size_t t = 0; t < tris.size(); ++t) {
        const int face = HdMeshUtil::DecodeFaceIndexFromCoarseFaceParam(primitiveParams[t]);
        if (face < 0 || size_t(face) >= normals.size()) return {};
        for (int c = 0; c < 3; ++c) perCorner[t * 3 + c] = normals[size_t(face)];
      }
      break;

    case HdInterpolationFaceVarying: {
      if (!HdAkariTriangulateFaceVarying(meshUtil, normals, perCorner) || perCorner.size() != corners) return {};
      break;
    }

    default:
      return {};
  }

  // a zero length normal can't shade, so the mesh shades flat rather than black
  for (GfVec3f &n : perCorner) {
    const float length = n.GetLength();
    if (length < 1e-12f || !std::isfinite(length)) return {};
    n /= length;
  }

  return perCorner;
}

// refined faces across the whole scene, capped so huge scenes can't refine without limit.
std::atomic<int64_t> gRefinedFaces{0};
constexpr int64_t kRefinedFaceBudget = 6'000'000;
constexpr int64_t kRefinedFacesPerMesh = 500'000;

int64_t RefinedFaceCount(HdMeshTopology const &topology, int level)
{
  return int64_t(topology.GetNumFaces()) << (2 * level);
}

/// hydra's refine level for this mesh, lowered until it fits the per mesh budget.
int RefineLevel(HdSceneDelegate *sceneDelegate, SdfPath const &id, HdMeshTopology const &topology)
{
  // an unauthored scheme falls back to catmull clark and refines like an authored one, a polygon mesh authors none
  if (!HdAkariSubdivision::IsSubdivisionScheme(topology.GetScheme())) return 0;

  int level = std::clamp(sceneDelegate->GetDisplayStyle(id).refineLevel, 0, 8);

  // a level the mesh asks for itself wins over the global one
  HdAkariPrimSubdivisionLevel(id, &level);

  while (level > 0 && RefinedFaceCount(topology, level) > kRefinedFacesPerMesh) --level;
  return level;
}

/// the per corner value indices of each face varying primvar, one subdivision channel each.
std::vector<std::pair<TfToken, VtIntArray>> FaceVaryingChannels(HdSceneDelegate *sceneDelegate, SdfPath const &id,
                                                                HdMeshTopology const &topology)
{
  std::vector<std::pair<TfToken, VtIntArray>> channels;
  const size_t corners = topology.GetFaceVertexIndices().size();
  for (HdPrimvarDescriptor const &pv : sceneDelegate->GetPrimvarDescriptors(id, HdInterpolationFaceVarying)) {
    VtIntArray indices;
    const VtValue value = sceneDelegate->GetIndexedPrimvar(id, pv.name, &indices);
    if (value.IsEmpty()) continue;
    if (indices.empty()) {
      indices.resize(corners);
      std::iota(indices.begin(), indices.end(), 0);
    }

    if (indices.size() == corners) channels.emplace_back(pv.name, std::move(indices));
  }

  return channels;
}

/// fills the mesh's coarse copy from its cage with the points moved onto the limit surface.
void SyncCoarseCage(HdSceneDelegate *sceneDelegate, SdfPath const &id, HdAkariTextureAtlas *atlas,
                    HdMeshTopology const &cage, VtVec3fArray limitPoints, HdAkariMeshData &data)
{
  HdAkariMeshData coarse;
  coarse.id = id;
  coarse.points = std::move(limitPoints);
  coarse.displayColor = data.displayColor;

  HdMeshUtil meshUtil(&cage, id);
  VtIntArray primitiveParams;
  HdAkariTriangulate(cage, meshUtil, &coarse.triangleIndices, &primitiveParams);
  HdAkariSyncMaterial(sceneDelegate, id, atlas, meshUtil, coarse, &cage, &primitiveParams);
  PackCornerColors(sceneDelegate, id, meshUtil, coarse.triangleIndices, primitiveParams, coarse.uvs, nullptr);

  data.coarsePoints = std::move(coarse.points);
  data.coarseTriangles = std::move(coarse.triangleIndices);
  data.coarseUvs = std::move(coarse.uvs);
  data.coarseTriangleFaces = std::move(coarse.triangleFaces);
}

} // namespace

HdAkariMesh::HdAkariMesh(SdfPath const &id) : HdMesh(id) {}

HdDirtyBits
HdAkariMesh::GetInitialDirtyBitsMask() const
{
  return HdChangeTracker::Clean | HdChangeTracker::DirtyTopology |
         HdChangeTracker::DirtyPoints | HdChangeTracker::DirtyTransform |
         HdChangeTracker::DirtyVisibility | HdChangeTracker::DirtyPrimvar |
         HdChangeTracker::DirtyDisplayStyle | HdChangeTracker::DirtyInstancer |
         HdChangeTracker::DirtyInstanceIndex | HdChangeTracker::DirtyNormals | HdChangeTracker::DirtyDoubleSided;
}

HdDirtyBits
HdAkariMesh::_PropagateDirtyBits(HdDirtyBits bits) const
{
  return bits;
}

void
HdAkariMesh::_InitRepr(TfToken const &reprToken, HdDirtyBits *dirtyBits)
{
  const auto it = std::find_if(_reprs.begin(), _reprs.end(),
                               _ReprComparator(reprToken));
  if (it == _reprs.end()) {
    _reprs.emplace_back(reprToken, std::make_shared<HdRepr>());
    *dirtyBits |= HdChangeTracker::NewRepr;
  }
}

void
HdAkariMesh::Sync(HdSceneDelegate *sceneDelegate,
                  HdRenderParam *renderParam,
                  HdDirtyBits *dirtyBits,
                  TfToken const & /*reprToken*/)
{
  const SdfPath &id = GetId();
  auto *param = static_cast<HdAkariRenderParam *>(renderParam);
  HdAkariScene *scene = param ? param->GetScene() : nullptr;
  HdAkariTextureAtlas *atlas = param ? param->GetTextureAtlas() : nullptr;
  if (atlas) atlas->EnsureGridSized(sceneDelegate);
  if (!scene) {
    *dirtyBits = HdChangeTracker::Clean;
    return;
  }

  const TfToken renderTag = sceneDelegate->GetRenderTag(id);
  if (renderTag != HdRenderTagTokens->geometry &&
      renderTag != HdRenderTagTokens->render) {
    scene->RemoveMesh(id);
    *dirtyBits = HdChangeTracker::Clean;
    return;
  }

  HdAkariSyncStyle(sceneDelegate, id, GetPrimId(), scene);

  // a point instancer's prototype republishes every instance whenever anything changes.
  _UpdateInstancer(sceneDelegate, dirtyBits);
  const SdfPath instancerId = GetInstancerId();
  const bool instanced = !instancerId.IsEmpty();
  if (instanced) HdInstancer::_SyncInstancerAndParents(sceneDelegate->GetRenderIndex(), instancerId);

  // which sides draw is decided as the triangles are laid out, so a change to it rebuilds them
  bool geoChanged = instanced || (*dirtyBits & (HdChangeTracker::DirtyTopology | HdChangeTracker::DirtyPoints |
                                                 HdChangeTracker::DirtyNormals | HdChangeTracker::DirtyDoubleSided)) != 0;

  // the uvs point into the bound material's atlas cell, so a binding to another material needs them baked again
  if (!geoChanged && (*dirtyBits & HdChangeTracker::DirtyMaterialId) && sceneDelegate->GetMaterialId(id) != _materialId) {
    geoChanged = true;
  }

  if (!geoChanged) {
    if (HdAkariSyncLightProbe(sceneDelegate, id, scene, nullptr)) {
      *dirtyBits = HdChangeTracker::Clean;
      return;
    }

    // only display properties changed, mutate in place, zero copy.
    auto xf = sceneDelegate->GetTransform(id);
    bool vis = sceneDelegate->GetVisible(id);

    // a moving mesh with nothing about its look dirty skips the material lookup.
    const HdDirtyBits lookBits = HdChangeTracker::DirtyMaterialId | HdChangeTracker::DirtyPrimvar |
                                 HdChangeTracker::DirtyDisplayStyle;
    if (!(*dirtyBits & lookBits) && scene->UpdateMeshTransform(id, xf, vis)) {
      *dirtyBits = HdChangeTracker::Clean;
      return;
    }

    GfVec3f color(0.8f, 0.8f, 0.8f);
    float opacity = 1.0f;
    float roughness = 0.5f;
    float metallic = 0.0f;
    const VtValue colorVal = sceneDelegate->Get(id, HdTokens->displayColor);
    if (colorVal.IsHolding<VtVec3fArray>()) {
      const VtVec3fArray colors = colorVal.UncheckedGet<VtVec3fArray>();
      if (!colors.empty()) color = colors[0];
    }

    HdAkariMaterialTextures textures;
    SdfPath materialId;
    float opacityThreshold = 0.0f;
    HdAkariApplyMaterial(sceneDelegate, id, color, opacity, roughness, metallic, opacityThreshold, textures, materialId);
    if (atlas && !textures.opacityPath.empty()) {
      // meshes with no bound material each get their own cell.
      const std::string cellKey = materialId.IsEmpty() ? id.GetString() : materialId.GetString();
      atlas->GetOrBakeCell(cellKey,
                           textures.roughnessPath, roughness,
                           textures.metallicPath, metallic,
                           textures.opacityPath, opacity,
                           opacityThreshold,
                           textures.colorPath, color,
                           textures.normalPath,
                           textures.emissivePath, textures.emissiveColor, textures.sources,
                           textures.specular);
    }

    // a material edit can turn a surface into glass or back, so it is classified again like a full sync.
    const HdAkariSurface surface = HdAkariClassifySurface(textures, color, opacity, opacityThreshold);
    scene->UpdateMeshDisplay(id, xf, color, opacity, roughness, metallic, surface, vis && !surface.hidden);
    *dirtyBits = HdChangeTracker::Clean;
    return;
  }

  // only the points moved, keep the triangulation and material.
  const HdDirtyBits rebuildBits = HdChangeTracker::DirtyTopology | HdChangeTracker::DirtyPrimvar;
  const bool sameSurface = !(*dirtyBits & HdChangeTracker::DirtyMaterialId) &&
                           (!(*dirtyBits & rebuildBits) ||
                            (_topologyRevision != 0 && GetMeshTopology(sceneDelegate).ComputeHash() == _baseTopologyHash)) &&
                           !(*dirtyBits & HdChangeTracker::DirtyDisplayStyle) &&
                           !(*dirtyBits & HdChangeTracker::DirtyDoubleSided);

  // authored normals that moved with the points are read again by a full sync
  const bool normalsMoved = _authoredNormals && (*dirtyBits & HdChangeTracker::DirtyNormals);
  const bool pointsOnly = !instanced && sameSurface && !normalsMoved;

  // an instanced skin whose instancer held still only moved its joints, its stored instances still stand.
  const bool stillInstances =
    instanced && !(*dirtyBits & (HdChangeTracker::DirtyInstancer | HdChangeTracker::DirtyInstanceIndex));
  if ((pointsOnly || (stillInstances && sameSurface)) && !_skinComputation.IsEmpty()) {
    VtMatrix4fArray xforms;
    GfVec3f lo, hi;
    if (ReadSkinXforms(sceneDelegate, _skinComputation, _skinJointBounds, xforms, lo, hi) &&
        scene->UpdateMeshSkin(id, xforms, lo, hi, sceneDelegate->GetTransform(id), sceneDelegate->GetVisible(id),
                              _dataGeneration + 1)) {
      ++_dataGeneration;
      *dirtyBits = HdChangeTracker::Clean;
      return;
    }
  }

  if (pointsOnly && _skinComputation.IsEmpty()) {
    VtValue pointsVal = ::PXR_NS::GetPoints(sceneDelegate, id);

    // a moving cage refines on the gpu, falling back to the cpu when its stencils can't be built.
    if (_subdivision && pointsVal.IsHolding<VtVec3fArray>() && _SyncMovingCage(scene, sceneDelegate, pointsVal)) {
      *dirtyBits = HdChangeTracker::Clean;
      return;
    }

    if (_subdivision) {
      VtValue refined;
      pointsVal = _subdivision->RefineVertex(pointsVal, false, &refined) ? refined : VtValue();
    }

    if (pointsVal.IsHolding<VtVec3fArray>() &&
        scene->UpdateMeshPoints(id, pointsVal.UncheckedGet<VtVec3fArray>(),
                                sceneDelegate->GetTransform(id), sceneDelegate->GetVisible(id),
                                _dataGeneration + 1)) {
      ++_dataGeneration;
      *dirtyBits = HdChangeTracker::Clean;
      return;
    }
  }

  // geometry changed -> full rebuild.
  HdAkariMeshData data;
  data.id = id;
  data.primId = GetPrimId();
  data.doubleSided = sceneDelegate->GetDoubleSided(id);

  HdMeshTopology topology = GetMeshTopology(sceneDelegate);
  data.smooth = topology.GetScheme() == PxOsdOpenSubdivTokens->catmullClark ||
                topology.GetScheme() == PxOsdOpenSubdivTokens->loop;
  _baseTopologyHash = topology.ComputeHash();
  _materialId = sceneDelegate->GetMaterialId(id);

  // object space points, or the rest points gpu skinning deforms
  _skinComputation = GpuSkinComputation(sceneDelegate, id);
  if (!_skinComputation.IsEmpty()) {
    const VtValue xfVal = SkinInput(sceneDelegate, _skinComputation, _skinTokens->skinningXforms);
    const size_t joints = xfVal.IsHolding<VtMatrix4fArray>() ? xfVal.UncheckedGet<VtMatrix4fArray>().size() : 0;
    if (joints > 0 &&
        ReadSkinRest(sceneDelegate, _skinComputation, joints, data, _skinJointBounds) &&
        ReadSkinXforms(sceneDelegate, _skinComputation, _skinJointBounds, data.skinXforms, data.skinMin, data.skinMax)) {
      // an instanced skin syncs in full every frame, only new rest points or weights relay it out.
      if (_skinRevision == 0 || data.points != _skinRestPoints || data.skinInfluences != _skinInfluences) {
        _skinRestPoints = data.points;
        _skinInfluences = data.skinInfluences;
        ++_skinRevision;
      }
      data.skinRevision = _skinRevision;
    } else {
      _skinComputation = SdfPath();
      _skinRestPoints = VtVec3fArray();
      _skinInfluences = VtVec2fArray();
      data.points = VtVec3fArray();
      data.skinInfluences = VtVec2fArray();
      data.skinInfluencesPerPoint = 0;
    }
  }

  if (_skinComputation.IsEmpty()) {
    const VtValue pointsVal = ::PXR_NS::GetPoints(sceneDelegate, id);
    if (pointsVal.IsHolding<VtVec3fArray>()) {
      data.points = pointsVal.UncheckedGet<VtVec3fArray>();
    }
  }

  if (HdAkariSyncLightProbe(sceneDelegate, id, scene, &data.points)) {
    *dirtyBits = HdChangeTracker::Clean;
    return;
  }

  // subdivision surfaces draw refined to hydra's refine level. skinned meshes keep their cage for gpu skinning.
  _ReleaseSubdivision();
  const HdMeshTopology cage = topology;
  const VtVec3fArray cagePoints = data.points;
  const int level = _skinComputation.IsEmpty() ? RefineLevel(sceneDelegate, id, topology) : 0;
  if (level > 0 && gRefinedFaces.load() + RefinedFaceCount(topology, level) <= kRefinedFaceBudget) {
    HdMeshTopology tagged = topology;
    tagged.SetSubdivTags(sceneDelegate->GetSubdivTags(id));
    _subdivision = HdAkariSubdivision::Create(tagged, level, FaceVaryingChannels(sceneDelegate, id, topology));
    VtValue refinedPoints;
    if (_subdivision && _subdivision->RefineVertex(VtValue(data.points), false, &refinedPoints)) {
      topology = _subdivision->GetTopology();
      data.points = refinedPoints.UncheckedGet<VtVec3fArray>();
      _refinedFaces = topology.GetNumFaces();
      gRefinedFaces += _refinedFaces;
    } else {
      _subdivision.reset();
    }
  }

  // triangulate once here so the renderer never has to per frame.
  HdMeshUtil meshUtil(&topology, id);
  VtIntArray primitiveParams;
  HdAkariTriangulate(topology, meshUtil, &data.triangleIndices, &primitiveParams);

  // point each refined triangle back at its cage face for uniform primvars, ptex and subsets.
  if (_subdivision) {
    VtIntArray const &baseFaces = _subdivision->GetBaseFaces();
    for (int &param : primitiveParams) {
      const int face = HdMeshUtil::DecodeFaceIndexFromCoarseFaceParam(param);
      if (face >= 0 && size_t(face) < baseFaces.size()) {
        param = HdMeshUtil::EncodeCoarseFaceParam(baseFaces[size_t(face)], HdMeshUtil::DecodeEdgeFlagFromCoarseFaceParam(param));
      }
    }
  }

  HdAkariRefinedPrimvars refinedPrimvars{_subdivision.get()};
  HdAkariRefinedPrimvars const *refined = _subdivision ? &refinedPrimvars : nullptr;

  data.transform = sceneDelegate->GetTransform(id);
  data.visible = sceneDelegate->GetVisible(id);

  // constant display color.
  const VtValue colorVal = sceneDelegate->Get(id, HdTokens->displayColor);
  if (colorVal.IsHolding<VtVec3fArray>()) {
    const VtVec3fArray colors = colorVal.UncheckedGet<VtVec3fArray>();
    if (!colors.empty()) {
      data.displayColor = colors[0];
    }
  } else if (colorVal.IsHolding<GfVec3f>()) {
    // a draw mode stand-in gives its drawModeColor as one value, not an array.
    data.displayColor = colorVal.UncheckedGet<GfVec3f>();
  }

  // the bound material's constant color, opacity, roughness and metallic
  HdAkariSyncMaterial(sceneDelegate, id, atlas, meshUtil, data, &cage, &primitiveParams, refined);
  PackCornerColors(sceneDelegate, id, meshUtil, data.triangleIndices, primitiveParams, data.uvs, refined);

  // a glowing mesh can light only diffuse or only specular, as a cross polarized studio does
  if (data.emitter) HdAkariPrimLightLobes(id, &data.lightDiffuse, &data.lightSpecular);

  // a polygon mesh shades with the normals it authors and flat without them, a subdivision surface makes its own
  if (!_subdivision && cage.GetScheme() == PxOsdOpenSubdivTokens->none) {
    data.normals = CornerNormals(sceneDelegate, id, meshUtil, data.triangleIndices, primitiveParams);
  }

  data.faceted = !data.smooth && data.normals.empty();
  _authoredNormals = !data.normals.empty();
  data.contentKey = HdAkariMeshContentKey(data);

  // shadows, probes and distant views draw the cage on its limit surface instead of the refined faces.
  VtVec3fArray limitPoints;
  if (_subdivision && _subdivision->LimitCage(cagePoints, &limitPoints)) {
    SyncCoarseCage(sceneDelegate, id, atlas, cage, std::move(limitPoints), data);
  }

  // bump revision so the gpu buffer cache knows to rebuild.
  data.dataRevision = ++_dataGeneration;
  const HdTopology::ID topologyHash = topology.ComputeHash();
  if (_topologyRevision == 0 || topologyHash != _topologyHash || data.uvs != _topologyUvs) {
    _topologyHash = topologyHash;
    _topologyUvs = data.uvs;
    _topologyRevision = data.dataRevision;
  }

  data.topologyRevision = _topologyRevision;

  // one prototype mesh carries its prototype's shared instance set.
  if (instanced) {
    HdAkariInstanceSet set = HdAkariInstances(sceneDelegate->GetRenderIndex(), instancerId, id);
    data.instances = std::move(set.transforms);
    data.instancesKey = set.key;
  }

  if (instanced && data.instances.empty()) scene->RemoveMesh(id);
  else scene->UpdateMesh(std::move(data));

  *dirtyBits = HdChangeTracker::Clean;
}

void
HdAkariMesh::Finalize(HdRenderParam *renderParam)
{
  _ReleaseSubdivision();
  if (auto *param = static_cast<HdAkariRenderParam *>(renderParam)) {
    if (HdAkariScene *scene = param->GetScene()) {
      scene->RemoveMesh(GetId(), GetPrimId());
      scene->RemoveProbe(GetId());
      scene->RemoveStyle(GetPrimId());
    }
  }
}

void
HdAkariMesh::_ReleaseSubdivision()
{
  gRefinedFaces -= _refinedFaces;
  _refinedFaces = 0;
  _subdivision.reset();
  _sentStencils = false;
}

bool
HdAkariMesh::_SyncMovingCage(HdAkariScene *scene, HdSceneDelegate *sceneDelegate, VtValue const &cagePoints)
{
  if (cagePoints.UncheckedGet<VtVec3fArray>().size() != _subdivision->GetCagePointCount()) return false;

  // the stencils are built once, the first time the cage moves, and stay with the scene's mesh after that.
  HdAkariStencils stencils;
  if (!_sentStencils && !_subdivision->GetStencils(&stencils)) return false;

  SdfPath const &id = GetId();
  if (!scene->UpdateMeshCage(id, cagePoints.UncheckedGet<VtVec3fArray>(), _sentStencils ? nullptr : &stencils,
                             sceneDelegate->GetTransform(id), sceneDelegate->GetVisible(id), _dataGeneration + 1)) {
    return false;
  }

  ++_dataGeneration;
  _sentStencils = true;
  return true;
}

PXR_NAMESPACE_CLOSE_SCOPE
