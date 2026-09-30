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
# include <Hd/bufferSource.h>
# include <Hd/changeTracker.h>
# include <Hd/meshTopology.h>
# include <Hd/meshUtil.h>
# include <Hd/mesh.h>
# include <Hd/repr.h>
# include <Hd/sceneDelegate.h>
# include <Hd/cubeSchema.h>
# include <Hd/tokens.h>
# include <Hd/vtBufferSource.h>
# include <Sdf/path.h>
# include <Vt/array.h>
# include <Vt/value.h>
# include <GeomUtil/cuboidMeshGenerator.h>
#else
# include <pxr/pxr.h>
# include <pxr/imaging/hd/version.h>
# include <pxr/imaging/hd/mesh.h>
# include <pxr/imaging/hd/rprim.h>
# include <pxr/imaging/hd/drawingCoord.h>
# include <pxr/imaging/hd/enums.h>
# include <pxr/imaging/hd/perfLog.h>
# include <pxr/usd/sdf/path.h>
# include <pxr/base/vt/array.h>
# include <pxr/base/vt/value.h>
# include <pxr/imaging/geomUtil/cuboidMeshGenerator.h>
#endif

#include "HdAkari/cube.h"
#include "HdAkari/lightProbe.h"
#include "HdAkari/materialBinding.h"
#include "HdAkari/renderParam.h"
#include "HdAkari/textureAtlas.h"
#include "HdAkari/scene.h"

#include <algorithm>

PXR_NAMESPACE_OPEN_SCOPE

HdAkariCube::HdAkariCube(SdfPath const &id)
  : HdRprim(id)
{}

HdAkariCube::~HdAkariCube() = default;

TfTokenVector const&
HdAkariCube::GetBuiltinPrimvarNames() const
{
    static const TfTokenVector primvarNames = {
        HdCubeSchemaTokens->size
    };

    return primvarNames;
}

HdDirtyBits
HdAkariCube::GetInitialDirtyBitsMask() const
{
  HdDirtyBits mask = HdChangeTracker::Clean
    | HdChangeTracker::DirtyTopology
    | HdChangeTracker::DirtyPoints
    | HdChangeTracker::DirtyTransform
    | HdChangeTracker::DirtyVisibility
    | HdChangeTracker::DirtyPrimvar
    | HdChangeTracker::DirtyDisplayStyle
    | HdChangeTracker::DirtyMaterialId;
  
  return mask;
}

HdDirtyBits
HdAkariCube::_PropagateDirtyBits(HdDirtyBits bits) const
{
  return bits;
}

void
HdAkariCube::_InitRepr(TfToken const &reprToken, HdDirtyBits *dirtyBits)
{
  const auto it = std::find_if(_reprs.begin(), _reprs.end(),
                               _ReprComparator(reprToken));
  if (it == _reprs.end()) {
    _reprs.emplace_back(reprToken, std::make_shared<HdRepr>());
    *dirtyBits |= HdChangeTracker::NewRepr;
  }
}

void
HdAkariCube::Sync(HdSceneDelegate *sceneDelegate,
                  HdRenderParam   *renderParam,
                  HdDirtyBits     *dirtyBits,
                  TfToken const   &reprToken)
{
  const SdfPath &id = GetId();
  auto *param = static_cast<HdAkariRenderParam *>(renderParam);
  auto scene = param ? param->GetScene() : nullptr;
  if (!scene) {
    *dirtyBits = HdChangeTracker::Clean;
    return;
  }

  HdAkariMeshData data;
  data.id = id;
  data.primId = GetPrimId();

  // fetch parameters.
  VtValue sizeVal = sceneDelegate->Get(id, HdCubeSchemaTokens->size);
  double size = sizeVal.IsHolding<double>() ? sizeVal.UncheckedGet<double>() : 2.0;

  const size_t numPoints = GeomUtilCuboidMeshGenerator::ComputeNumPoints();

  data.points.resize(numPoints);
  GeomUtilCuboidMeshGenerator::GeneratePoints(
    data.points.begin(),
    /* lX */ size,
    /* lY */ size,
    /* lZ */ size
  );

  if (HdAkariSyncLightProbe(sceneDelegate, id, scene, &data.points)) {
    *dirtyBits = HdChangeTracker::Clean;
    return;
  }

  PxOsdMeshTopology topology = GeomUtilCuboidMeshGenerator::GenerateTopology();

  HdMeshTopology meshTopology(topology);
  HdMeshUtil meshUtil(&meshTopology, id);
  VtIntArray primitiveParams;
  meshUtil.ComputeTriangleIndices(&data.triangleIndices, &primitiveParams);

  data.transform = sceneDelegate->GetTransform(id);
  data.visible = sceneDelegate->GetVisible(id);
  
  // constant display color, a minimal way to support authored colors.
  // (todo): support actual per-vertex color.
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

  // bump revision so the GPU buffer cache knows to rebuild.
  data.dataRevision = ++_dataGeneration;
  
  scene->UpdateMesh(std::move(data));
  
  *dirtyBits = HdChangeTracker::Clean;
}

void
HdAkariCube::Finalize(HdRenderParam *renderParam)
{
  if (auto *param = static_cast<HdAkariRenderParam *>(renderParam)) {
    if (auto scene = param->GetScene()) {
      scene->RemoveMesh(GetId());
      scene->RemoveProbe(GetId());
    }
  }
}

PXR_NAMESPACE_CLOSE_SCOPE
