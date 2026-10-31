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
# include <Hd/material.h>
# include <Hd/materialNetworkSchema.h>
# include <Hd/materialNodeSchema.h>
# include <Hd/materialNodeParameterSchema.h>
# include <Hd/materialSchema.h>
# include <Hd/renderDelegate.h>
# include <Hd/renderIndex.h>
# include <Hd/sceneDelegate.h>
# include <Hd/sceneIndex.h>
# include <Vt/value.h>
#else
# include <pxr/pxr.h>
# include <pxr/imaging/hd/changeTracker.h>
# include <pxr/imaging/hd/material.h>
# include <pxr/imaging/hd/materialNetworkSchema.h>
# include <pxr/imaging/hd/materialNodeSchema.h>
# include <pxr/imaging/hd/materialNodeParameterSchema.h>
# include <pxr/imaging/hd/materialSchema.h>
# include <pxr/imaging/hd/renderDelegate.h>
# include <pxr/imaging/hd/renderIndex.h>
# include <pxr/imaging/hd/sceneDelegate.h>
# include <pxr/imaging/hd/sceneIndex.h>
# include <pxr/base/vt/value.h>
#endif

#include "HdAkari/material.h"
#include "HdAkari/materialBinding.h"
#include "HdAkari/renderParam.h"
#include "HdAkari/textureAtlas.h"

PXR_NAMESPACE_OPEN_SCOPE

namespace {

const TfToken kPreviewSurface("UsdPreviewSurface");
const TfToken kEmissiveColor("emissiveColor");
const TfToken kOpacity("opacity");

// the preview surface's emission and opacity value sources, from the scene index.
bool FindConstants(HdSceneDelegate *sceneDelegate, SdfPath const &id,
                   HdSampledDataSourceHandle &emissive, HdSampledDataSourceHandle &opacity)
{
  HdRenderIndex &index = sceneDelegate->GetRenderIndex();
  HdSceneIndexBaseRefPtr sceneIndex = index.GetTerminalSceneIndex();
  if (!sceneIndex) return false;

  const HdMaterialNetworkSchema network = HdMaterialSchema::GetFromParent(sceneIndex->GetPrim(id).dataSource)
    .GetMaterialNetwork(index.GetRenderDelegate()->GetMaterialRenderContexts());
  HdMaterialNodeContainerSchema nodes = network.GetNodes();
  for (TfToken const &name : nodes.GetNames()) {
    const HdMaterialNodeSchema node = nodes.Get(name);
    const HdTokenDataSourceHandle identifier = node.GetNodeIdentifier();
    if (!identifier || identifier->GetTypedValue(0.0f) != kPreviewSurface) continue;
    HdMaterialNodeParameterContainerSchema params = node.GetParameters();
    emissive = params.Get(kEmissiveColor).GetValue();
    opacity = params.Get(kOpacity).GetValue();
    return emissive || opacity;
  }
  return false;
}

} // namespace

HdAkariMaterial::HdAkariMaterial(SdfPath const &id)
  : HdMaterial(id)
{}

HdDirtyBits
HdAkariMaterial::GetInitialDirtyBitsMask() const
{
  return HdMaterial::AllDirty;
}

void
HdAkariMaterial::Sync(HdSceneDelegate *sceneDelegate,
                      HdRenderParam   *renderParam,
                      HdDirtyBits     *dirtyBits)
{
  auto *param = static_cast<HdAkariRenderParam *>(renderParam);
  HdAkariTextureAtlas *atlas = param ? param->GetTextureAtlas() : nullptr;
  if (!atlas || !(*dirtyBits & HdMaterial::DirtyResource))
  {
    *dirtyBits = HdChangeTracker::Clean;
    return;
  }
  HdAkariForgetMaterial(GetId());
  if (!_emissive && !_opacity && !atlas->HasConstants(GetId().GetString()))
  {
    *dirtyBits = HdChangeTracker::Clean;
    return;
  }

  if (_emissive || _opacity || FindConstants(sceneDelegate, GetId(), _emissive, _opacity))
  {
    const VtValue emissive = _emissive ? _emissive->GetValue(0.0f) : VtValue();
    const VtValue opacity = _opacity ? _opacity->GetValue(0.0f) : VtValue();
    const bool hasEmissive = emissive.IsHolding<GfVec3f>();
    const bool hasOpacity = opacity.IsHolding<float>();
    if ((hasEmissive || !_emissive) && (hasOpacity || !_opacity))
    {
      atlas->UpdateConstants(GetId().GetString(),
                             hasEmissive ? &emissive.UncheckedGet<GfVec3f>() : nullptr,
                             hasOpacity ? &opacity.UncheckedGet<float>() : nullptr);
      *dirtyBits = HdChangeTracker::Clean;
      return;
    }
    // the network changed under the cached sources, look again next time.
    _emissive = nullptr;
    _opacity = nullptr;
  }

  const VtValue resource = sceneDelegate->GetMaterialResource(GetId());
  if (resource.IsHolding<HdMaterialNetworkMap>())
  {
    for (auto const &entry : resource.UncheckedGet<HdMaterialNetworkMap>().map)
    {
      for (HdMaterialNode const &node : entry.second.nodes)
      {
        if (node.identifier != kPreviewSurface) continue;
        auto emissiveIt = node.parameters.find(kEmissiveColor);
        auto opacityIt = node.parameters.find(kOpacity);
        const bool hasEmissive = emissiveIt != node.parameters.end() && emissiveIt->second.IsHolding<GfVec3f>();
        const bool hasOpacity = opacityIt != node.parameters.end() && opacityIt->second.IsHolding<float>();
        atlas->UpdateConstants(GetId().GetString(),
                               hasEmissive ? &emissiveIt->second.UncheckedGet<GfVec3f>() : nullptr,
                               hasOpacity ? &opacityIt->second.UncheckedGet<float>() : nullptr);
      }
    }
  }
  *dirtyBits = HdChangeTracker::Clean;
}

PXR_NAMESPACE_CLOSE_SCOPE
