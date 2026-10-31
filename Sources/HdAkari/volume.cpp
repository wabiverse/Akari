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
# include <Hd/repr.h>
# include <Hd/sceneDelegate.h>
# include <Sdf/assetPath.h>
# include <Vt/value.h>
#else
# include <pxr/pxr.h>
# include <pxr/imaging/hd/changeTracker.h>
# include <pxr/imaging/hd/repr.h>
# include <pxr/imaging/hd/sceneDelegate.h>
# include <pxr/usd/sdf/assetPath.h>
# include <pxr/base/vt/value.h>
#endif

#include "HdAkari/volume.h"
#include "HdAkari/renderParam.h"
#include "HdAkari/scene.h"

#include <algorithm>

PXR_NAMESPACE_OPEN_SCOPE

namespace {

HdAkariScene *SceneOf(HdRenderParam *renderParam)
{
  auto *param = static_cast<HdAkariRenderParam *>(renderParam);
  return param ? param->GetScene() : nullptr;
}

template <typename T>
bool First(VtValue const &value, T &out)
{
  if (value.IsHolding<T>()) { out = value.UncheckedGet<T>(); return true; }
  if (value.IsHolding<VtArray<T>>()) {
    VtArray<T> const &values = value.UncheckedGet<VtArray<T>>();
    if (values.empty()) return false;
    out = values[0];
    return true;
  }
  return false;
}

void ReadFloat(HdSceneDelegate *sceneDelegate, SdfPath const &id, char const *name, float &out)
{
  const VtValue value = sceneDelegate->Get(id, TfToken(name));
  double d = 0.0;
  int i = 0;
  if (First(value, out)) return;
  if (First(value, d)) out = float(d);
  else if (First(value, i)) out = float(i);
}

} // namespace

HdAkariVolume::HdAkariVolume(SdfPath const &id)
  : HdVolume(id)
{}

HdAkariVolume::~HdAkariVolume() = default;

HdDirtyBits
HdAkariVolume::GetInitialDirtyBitsMask() const
{
  return HdChangeTracker::Clean
    | HdChangeTracker::DirtyTransform
    | HdChangeTracker::DirtyVisibility
    | HdChangeTracker::DirtyPrimvar
    | HdChangeTracker::DirtyVolumeField
    | HdChangeTracker::DirtyMaterialId;
}

HdDirtyBits
HdAkariVolume::_PropagateDirtyBits(HdDirtyBits bits) const
{
  return bits;
}

void
HdAkariVolume::_InitRepr(TfToken const &reprToken, HdDirtyBits *dirtyBits)
{
  const auto it = std::find_if(_reprs.begin(), _reprs.end(), _ReprComparator(reprToken));
  if (it == _reprs.end()) {
    _reprs.emplace_back(reprToken, std::make_shared<HdRepr>());
    *dirtyBits |= HdChangeTracker::NewRepr;
  }
}

void
HdAkariVolume::Sync(HdSceneDelegate *sceneDelegate,
                    HdRenderParam   *renderParam,
                    HdDirtyBits     *dirtyBits,
                    TfToken const   & /*reprToken*/)
{
  HdAkariScene *scene = SceneOf(renderParam);
  if (!scene) {
    *dirtyBits = HdChangeTracker::Clean;
    return;
  }

  const SdfPath &id = GetId();
  HdAkariVolumeData data;
  data.id = id;
  data.transform = sceneDelegate->GetTransform(id);
  data.visible = sceneDelegate->GetVisible(id);
  for (HdVolumeFieldDescriptor const &field : sceneDelegate->GetVolumeFieldDescriptors(id)) {
    if (data.densityField.IsEmpty() || field.fieldName == TfToken("density")) {
      data.densityField = field.fieldId;
      data.densityName = field.fieldName.GetString();
    }
  }
  ReadFloat(sceneDelegate, id, "akari:volume:densityScale", data.densityScale);
  ReadFloat(sceneDelegate, id, "akari:volume:anisotropy", data.anisotropy);
  ReadFloat(sceneDelegate, id, "akari:volume:maxResolution", data.maxResolution);
  const VtValue albedo = sceneDelegate->Get(id, TfToken("akari:volume:albedo"));
  GfVec3f c;
  if (First(albedo, c)) { data.albedoR = c[0]; data.albedoG = c[1]; data.albedoB = c[2]; }

  scene->UpdateVolume(std::move(data));
  *dirtyBits = HdChangeTracker::Clean;
}

void
HdAkariVolume::Finalize(HdRenderParam *renderParam)
{
  if (HdAkariScene *scene = SceneOf(renderParam)) scene->RemoveVolume(GetId());
}

HdAkariField::HdAkariField(SdfPath const &id)
  : HdField(id)
{}

HdAkariField::~HdAkariField() = default;

HdDirtyBits
HdAkariField::GetInitialDirtyBitsMask() const
{
  return HdField::AllDirty;
}

void
HdAkariField::Sync(HdSceneDelegate *sceneDelegate,
                   HdRenderParam   *renderParam,
                   HdDirtyBits     *dirtyBits)
{
  HdAkariScene *scene = SceneOf(renderParam);
  if (!scene) {
    *dirtyBits = HdField::Clean;
    return;
  }

  const SdfPath &id = GetId();
  HdAkariFieldData data;
  data.id = id;
  const VtValue path = sceneDelegate->Get(id, HdFieldTokens->filePath);
  if (path.IsHolding<SdfAssetPath>()) {
    SdfAssetPath const &asset = path.UncheckedGet<SdfAssetPath>();
    data.filePath = asset.GetResolvedPath().empty() ? asset.GetAssetPath() : asset.GetResolvedPath();
  }
  const VtValue name = sceneDelegate->Get(id, HdFieldTokens->fieldName);
  if (name.IsHolding<TfToken>()) data.fieldName = name.UncheckedGet<TfToken>().GetString();
  else if (name.IsHolding<std::string>()) data.fieldName = name.UncheckedGet<std::string>();

  scene->UpdateField(std::move(data));
  *dirtyBits = HdField::Clean;
}

void
HdAkariField::Finalize(HdRenderParam *renderParam)
{
  if (HdAkariScene *scene = SceneOf(renderParam)) scene->RemoveField(GetId());
}

PXR_NAMESPACE_CLOSE_SCOPE
