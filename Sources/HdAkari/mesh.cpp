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
#include "HdAkari/mesh.h"
#include "HdAkari/materialBinding.h"
#include "HdAkari/renderParam.h"
#include "HdAkari/scene.h"
#include "HdAkari/textureAtlas.h"

#include <Hd/changeTracker.h>
#include <Hd/material.h>
#include <Hd/meshTopology.h>
#include <Hd/meshUtil.h>
#include <Hd/repr.h>
#include <Hd/sceneDelegate.h>
#include <Hd/tokens.h>
#include <Hd/types.h>
#include <Sdf/assetPath.h>
#include <Gf/vec2f.h>

#include <algorithm>
#include <cmath>
#include <cstdio>
#include <string>

PXR_NAMESPACE_OPEN_SCOPE

HdAkariMesh::HdAkariMesh(SdfPath const &id) : HdMesh(id) {}

HdDirtyBits
HdAkariMesh::GetInitialDirtyBitsMask() const
{
  return HdChangeTracker::Clean | HdChangeTracker::DirtyTopology |
         HdChangeTracker::DirtyPoints | HdChangeTracker::DirtyTransform |
         HdChangeTracker::DirtyVisibility | HdChangeTracker::DirtyPrimvar |
         HdChangeTracker::DirtyDisplayStyle;
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

  bool geoChanged = (*dirtyBits & (HdChangeTracker::DirtyTopology | HdChangeTracker::DirtyPoints)) != 0;

  if (!geoChanged) {
    // only display properties changed, mutate in place, zero copy.
    auto xf = sceneDelegate->GetTransform(id);
    bool vis = sceneDelegate->GetVisible(id);
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
                           textures.emissivePath, textures.emissiveColor);
    }
    scene->UpdateMeshDisplay(id, xf, color, opacity, roughness, metallic, vis);
    *dirtyBits = HdChangeTracker::Clean;
    return;
  }

  // geometry changed -> full rebuild.
  HdAkariMeshData data;
  data.id = id;

  // topology -> triangulated indices (computed once, not per frame).
  HdMeshTopology topology = GetMeshTopology(sceneDelegate);
  HdMeshUtil meshUtil(&topology, id);
  VtIntArray primitiveParams;
  meshUtil.ComputeTriangleIndices(&data.triangleIndices, &primitiveParams);

  // points (object space).
  const VtValue pointsVal = sceneDelegate->Get(id, HdTokens->points);
  if (pointsVal.IsHolding<VtVec3fArray>()) {
    data.points = pointsVal.UncheckedGet<VtVec3fArray>();
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
  HdAkariSyncMaterial(sceneDelegate, id, atlas, meshUtil, data);

  // bump revision so the GPU buffer cache knows to rebuild.
  data.dataRevision = ++_dataGeneration;

  scene->UpdateMesh(std::move(data));

  *dirtyBits = HdChangeTracker::Clean;
}

void
HdAkariMesh::Finalize(HdRenderParam *renderParam)
{
  if (auto *param = static_cast<HdAkariRenderParam *>(renderParam)) {
    if (HdAkariScene *scene = param->GetScene()) {
      scene->RemoveMesh(GetId());
    }
  }
}

PXR_NAMESPACE_CLOSE_SCOPE
