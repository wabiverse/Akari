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

#include <algorithm>
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

// in arrayBins.cpp, the triangulation shared by every mesh with Hydra's topology hash.
void HdAkariTriangulate(HdMeshTopology const &topology, HdMeshUtil &meshUtil, VtVec3iArray *triangles,
                        VtIntArray *params);

namespace {

// skinned meshes (UsdSkel) publish points through an ext computation.
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

// the UsdSkel linear blend skinning computation behind the points, when it offers
// a GPU kernel (unless USDSKELIMAGING_FORCE_CPU_COMPUTE), the same test Storm makes.
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

// a varying displayColor, packed 8 bits a channel into the y of each untextured corner's uv
// (one past the packed value, zero when there is none) for the shaders to unpack.
void PackCornerColors(HdSceneDelegate *sceneDelegate, SdfPath const &id, HdMeshUtil &meshUtil,
                      VtVec3iArray const &tris, VtIntArray const &primitiveParams, VtVec2fArray &uvs)
{
  const size_t corners = tris.size() * 3;
  if (uvs.size() != corners) return;
  HdInterpolation interp = HdInterpolationConstant;
  bool found = false;
  for (int i = 0; i < HdInterpolationCount && !found; ++i) {
    for (HdPrimvarDescriptor const &pv : sceneDelegate->GetPrimvarDescriptors(id, HdInterpolation(i))) {
      if (pv.name == HdTokens->displayColor) { interp = HdInterpolation(i); found = true; break; }
    }
  }
  if (!found || interp == HdInterpolationConstant) return;
  const VtValue value = sceneDelegate->Get(id, HdTokens->displayColor);
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
    VtValue triangulated;
    if (meshUtil.ComputeTriangulatedFaceVaryingPrimvar(colors.cdata(), int(colors.size()), HdTypeFloatVec3, &triangulated)
          != HdMeshComputationResult::Success || !triangulated.IsHolding<VtVec3fArray>()) return;
    perCorner = triangulated.UncheckedGet<VtVec3fArray>();
    if (perCorner.size() != corners) return;
  } else if (interp == HdInterpolationUniform && primitiveParams.size() == tris.size()) {
    for (size_t t = 0; t < tris.size(); ++t) {
      const int face = HdMeshUtil::DecodeFaceIndexFromCoarseFaceParam(primitiveParams[t]);
      const GfVec3f c = face >= 0 && size_t(face) < colors.size() ? colors[face] : GfVec3f(1.0f);
      for (int k = 0; k < 3; ++k) perCorner[t * 3 + k] = c;
    }
  } else {
    return;
  }
  for (size_t i = 0; i < corners; ++i) {
    if (uvs[i][0] >= 0.0f) continue;
    auto channel = [&](int k) { return uint32_t(std::clamp(perCorner[i][k], 0.0f, 1.0f) * 255.0f + 0.5f); };
    uvs[i][1] = float((channel(0) << 16) | (channel(1) << 8) | channel(2)) + 1.0f;
  }
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
         HdChangeTracker::DirtyInstanceIndex;
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

  bool geoChanged = instanced || (*dirtyBits & (HdChangeTracker::DirtyTopology | HdChangeTracker::DirtyPoints)) != 0;

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
                           textures.emissivePath, textures.emissiveColor, textures.sources);
    }
    scene->UpdateMeshDisplay(id, xf, color, opacity, roughness, metallic, vis);
    *dirtyBits = HdChangeTracker::Clean;
    return;
  }

  // only the points moved, keep the triangulation and material.
  const HdDirtyBits rebuildBits = HdChangeTracker::DirtyTopology | HdChangeTracker::DirtyPrimvar;
  const bool pointsOnly = !instanced && !(*dirtyBits & HdChangeTracker::DirtyMaterialId) &&
                          (!(*dirtyBits & rebuildBits) ||
                           (_topologyRevision != 0 && GetMeshTopology(sceneDelegate).ComputeHash() == _topologyHash));
  if (pointsOnly && !_skinComputation.IsEmpty()) {
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
    const VtValue pointsVal = ::PXR_NS::GetPoints(sceneDelegate, id);
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

  // topology -> triangulated indices (computed once, not per frame).
  HdMeshTopology topology = GetMeshTopology(sceneDelegate);
  data.smooth = topology.GetScheme() == PxOsdOpenSubdivTokens->catmullClark ||
                topology.GetScheme() == PxOsdOpenSubdivTokens->loop;
  HdMeshUtil meshUtil(&topology, id);
  VtIntArray primitiveParams;
  HdAkariTriangulate(topology, meshUtil, &data.triangleIndices, &primitiveParams);

  // points (object space), or for GPU skinning the rest points it deforms.
  _skinComputation = GpuSkinComputation(sceneDelegate, id);
  if (!_skinComputation.IsEmpty()) {
    const VtValue xfVal = SkinInput(sceneDelegate, _skinComputation, _skinTokens->skinningXforms);
    const size_t joints = xfVal.IsHolding<VtMatrix4fArray>() ? xfVal.UncheckedGet<VtMatrix4fArray>().size() : 0;
    if (joints > 0 &&
        ReadSkinRest(sceneDelegate, _skinComputation, joints, data, _skinJointBounds) &&
        ReadSkinXforms(sceneDelegate, _skinComputation, _skinJointBounds, data.skinXforms, data.skinMin, data.skinMax)) {
      data.skinRevision = ++_skinRevision;
    } else {
      _skinComputation = SdfPath();
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

  data.transform = sceneDelegate->GetTransform(id);
  data.visible = sceneDelegate->GetVisible(id);

  // constant display color.
  const VtValue colorVal = sceneDelegate->Get(id, HdTokens->displayColor);
  if (colorVal.IsHolding<VtVec3fArray>()) {
    const VtVec3fArray colors = colorVal.UncheckedGet<VtVec3fArray>();
    if (!colors.empty()) {
      data.displayColor = colors[0];
    }
  }

  // bound material's constant diffuseColor/opacity/roughness/metallic.
  HdAkariSyncMaterial(sceneDelegate, id, atlas, meshUtil, data, &topology, &primitiveParams);
  PackCornerColors(sceneDelegate, id, meshUtil, data.triangleIndices, primitiveParams, data.uvs);
  data.contentKey = HdAkariMeshContentKey(data);

  // bump revision so the GPU buffer cache knows to rebuild.
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
  if (auto *param = static_cast<HdAkariRenderParam *>(renderParam)) {
    if (HdAkariScene *scene = param->GetScene()) {
      scene->RemoveMesh(GetId());
      scene->RemoveProbe(GetId());
      scene->RemoveStyle(GetPrimId());
    }
  }
}

PXR_NAMESPACE_CLOSE_SCOPE
