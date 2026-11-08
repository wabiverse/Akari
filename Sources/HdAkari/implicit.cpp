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
# include <Tf/staticTokens.h>
# include <Hd/changeTracker.h>
# include <Hd/instancer.h>
# include <Hd/meshTopology.h>
# include <Hd/meshUtil.h>
# include <Hd/repr.h>
# include <Hd/sceneDelegate.h>
# include <Hd/tokens.h>
# include <GeomUtil/capsuleMeshGenerator.h>
# include <GeomUtil/coneMeshGenerator.h>
# include <GeomUtil/cylinderMeshGenerator.h>
# include <Vt/value.h>
#else
# include <pxr/pxr.h>
# include <pxr/base/tf/staticTokens.h>
# include <pxr/imaging/hd/changeTracker.h>
# include <pxr/imaging/hd/instancer.h>
# include <pxr/imaging/hd/meshTopology.h>
# include <pxr/imaging/hd/meshUtil.h>
# include <pxr/imaging/hd/repr.h>
# include <pxr/imaging/hd/sceneDelegate.h>
# include <pxr/imaging/hd/tokens.h>
# include <pxr/imaging/geomUtil/capsuleMeshGenerator.h>
# include <pxr/imaging/geomUtil/coneMeshGenerator.h>
# include <pxr/imaging/geomUtil/cylinderMeshGenerator.h>
# include <pxr/base/vt/value.h>
#endif

#include "HdAkari/implicit.h"
#include "HdAkari/instancer.h"
#include "HdAkari/materialBinding.h"
#include "HdAkari/renderParam.h"
#include "HdAkari/textureAtlas.h"
#include "HdAkari/scene.h"
#include "HdAkari/style.h"

#include <algorithm>

PXR_NAMESPACE_OPEN_SCOPE

TF_DEFINE_PRIVATE_TOKENS(_tokens,
  (axis)
  (height)
  (radius)
  (radiusBottom)
  (radiusTop)
  ((x, "X"))
  ((y, "Y"))
  ((z, "Z"))
);

namespace {

double ImplicitDouble(HdSceneDelegate *sceneDelegate, SdfPath const &id, TfToken const &name, double fallback)
{
  const VtValue value = sceneDelegate->Get(id, name);
  if (value.IsHolding<double>()) return value.UncheckedGet<double>();
  if (value.IsHolding<float>()) return value.UncheckedGet<float>();
  return fallback;
}

// The frame turning the generators' +z spine onto the prim's axis.
GfMatrix4d ImplicitBasis(TfToken const &axis)
{
  if (axis == _tokens->x) return GfMatrix4d(0, 1, 0, 0, 0, 0, 1, 0, 1, 0, 0, 0, 0, 0, 0, 1);
  if (axis == _tokens->y) return GfMatrix4d(0, 0, 1, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 1);
  return GfMatrix4d(1.0);
}

} // namespace

HdAkariImplicit::HdAkariImplicit(SdfPath const &id, TfToken const &type)
  : HdRprim(id),
    _type(type)
{}

HdAkariImplicit::~HdAkariImplicit() = default;

TfTokenVector const&
HdAkariImplicit::GetBuiltinPrimvarNames() const
{
  static const TfTokenVector primvarNames = {
    _tokens->height, _tokens->radius, _tokens->radiusTop, _tokens->radiusBottom, _tokens->axis
  };

  return primvarNames;
}

HdDirtyBits
HdAkariImplicit::GetInitialDirtyBitsMask() const
{
  return HdChangeTracker::Clean
    | HdChangeTracker::DirtyTopology
    | HdChangeTracker::DirtyPoints
    | HdChangeTracker::DirtyTransform
    | HdChangeTracker::DirtyVisibility
    | HdChangeTracker::DirtyPrimvar
    | HdChangeTracker::DirtyDisplayStyle
    | HdChangeTracker::DirtyMaterialId
    | HdChangeTracker::DirtyInstancer;
}

HdDirtyBits
HdAkariImplicit::_PropagateDirtyBits(HdDirtyBits bits) const
{
  return bits;
}

void
HdAkariImplicit::_InitRepr(TfToken const &reprToken, HdDirtyBits *dirtyBits)
{
  const auto it = std::find_if(_reprs.begin(), _reprs.end(),
                               _ReprComparator(reprToken));
  if (it == _reprs.end()) {
    _reprs.emplace_back(reprToken, std::make_shared<HdRepr>());
    *dirtyBits |= HdChangeTracker::NewRepr;
  }
}

void
HdAkariImplicit::Sync(HdSceneDelegate *sceneDelegate,
                      HdRenderParam   *renderParam,
                      HdDirtyBits     *dirtyBits,
                      TfToken const   &reprToken)
{
  const SdfPath &id = GetId();
  auto *param = static_cast<HdAkariRenderParam *>(renderParam);
  HdAkariScene *scene = param ? param->GetScene() : nullptr;
  if (!scene) {
    *dirtyBits = HdChangeTracker::Clean;
    return;
  }

  HdAkariMeshData data;
  data.id = id;
  data.primId = GetPrimId();
  HdAkariSyncStyle(sceneDelegate, id, data.primId, scene);

  // a point instancer's prototype publishes one matrix per instance, the
  // renderer draws it with GPU instancing instead of copying the mesh.
  _UpdateInstancer(sceneDelegate, dirtyBits);
  const SdfPath instancerId = GetInstancerId();
  const bool instanced = !instancerId.IsEmpty();
  if (instanced) HdInstancer::_SyncInstancerAndParents(sceneDelegate->GetRenderIndex(), instancerId);

  const double height = ImplicitDouble(sceneDelegate, id, _tokens->height, _type == HdPrimTypeTokens->capsule ? 1.0 : 2.0);
  const double radius = ImplicitDouble(sceneDelegate, id, _tokens->radius, _type == HdPrimTypeTokens->capsule ? 0.5 : 1.0);
  const double top = ImplicitDouble(sceneDelegate, id, _tokens->radiusTop, radius);
  const double bottom = ImplicitDouble(sceneDelegate, id, _tokens->radiusBottom, radius);
  const VtValue axisVal = sceneDelegate->Get(id, _tokens->axis);
  const GfMatrix4d basis = ImplicitBasis(axisVal.IsHolding<TfToken>() ? axisVal.UncheckedGet<TfToken>() : _tokens->z);

  const size_t numRadial = 96, numCapAxial = 24;
  PxOsdMeshTopology topology;
  if (_type == HdPrimTypeTokens->capsule) {
    data.points.resize(GeomUtilCapsuleMeshGenerator::ComputeNumPoints(numRadial, numCapAxial));
    GeomUtilCapsuleMeshGenerator::GeneratePoints(data.points.begin(), numRadial, numCapAxial, radius, height, &basis);
    topology = GeomUtilCapsuleMeshGenerator::GenerateTopology(numRadial, numCapAxial);
  } else if (_type == HdPrimTypeTokens->cone) {
    data.points.resize(GeomUtilConeMeshGenerator::ComputeNumPoints(numRadial));
    GeomUtilConeMeshGenerator::GeneratePoints(data.points.begin(), numRadial, radius, height, &basis);
    topology = GeomUtilConeMeshGenerator::GenerateTopology(numRadial);
  } else {
    data.points.resize(GeomUtilCylinderMeshGenerator::ComputeNumPoints(numRadial));
    GeomUtilCylinderMeshGenerator::GeneratePoints(data.points.begin(), numRadial, bottom, top, height, &basis);
    topology = GeomUtilCylinderMeshGenerator::GenerateTopology(numRadial);
  }

  HdMeshTopology meshTopology(topology);
  HdMeshUtil meshUtil(&meshTopology, id);
  VtIntArray primitiveParams;
  meshUtil.ComputeTriangleIndices(&data.triangleIndices, &primitiveParams);

  data.transform = sceneDelegate->GetTransform(id);
  data.visible = sceneDelegate->GetVisible(id);

  const VtValue colorVal = sceneDelegate->Get(id, HdTokens->displayColor);
  if (colorVal.IsHolding<VtVec3fArray>()) {
    const VtVec3fArray colors = colorVal.UncheckedGet<VtVec3fArray>();
    if (!colors.empty()) {
      data.displayColor = colors[0];
    }
  }

  HdAkariTextureAtlas *atlas = param->GetTextureAtlas();
  if (atlas) atlas->EnsureGridSized(sceneDelegate);
  HdAkariSyncMaterial(sceneDelegate, id, atlas, meshUtil, data);

  data.contentKey = HdAkariMeshContentKey(data);
  data.dataRevision = ++_dataGeneration;
  if (instanced) {
    HdAkariInstanceSet set = HdAkariInstances(sceneDelegate->GetRenderIndex(), instancerId, id);
    data.instances = std::move(set.transforms);
    data.instancesKey = set.key;
    // nothing to draw without instances.
    if (data.instances.empty()) {
      scene->RemoveMesh(id);
      *dirtyBits = HdChangeTracker::Clean;
      return;
    }
  }

  scene->UpdateMesh(std::move(data));

  *dirtyBits = HdChangeTracker::Clean;
}

void
HdAkariImplicit::Finalize(HdRenderParam *renderParam)
{
  if (auto *param = static_cast<HdAkariRenderParam *>(renderParam)) {
    if (HdAkariScene *scene = param->GetScene()) {
      scene->RemoveMesh(GetId(), GetPrimId());
      scene->RemoveStyle(GetPrimId());
    }
  }
}

PXR_NAMESPACE_CLOSE_SCOPE
