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

#include <algorithm>

PXR_NAMESPACE_OPEN_SCOPE

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
  const bool changed = *dirtyBits & (HdMaterial::DirtyResource | HdMaterial::DirtyParams);
  *dirtyBits = HdChangeTracker::Clean;
  if (!atlas || !changed) return;
  HdAkariForgetMaterial(GetId());
  if (!_baked) {
    _baked = true;
    return;
  }

  const std::string key = GetId().GetString();
  float row[HdAkariTextureAtlas::kConstantTexels * 4] = {0.18f, 0.18f, 0.18f, 1.0f, 0.5f, 0.0f, 0.0f, 0.0f};
  const bool constant = atlas->GetConstants(key, row);
  GfVec3f color(row[0], row[1], row[2]);
  float opacity = row[3], roughness = row[4], metallic = row[5], opacityThreshold = row[6];
  HdAkariMaterialTextures textures;
  SdfPath resolved;
  HdAkariApplyMaterialId(sceneDelegate, GetId(), color, opacity, roughness, metallic, opacityThreshold, textures,
                         resolved);
  const bool untextured = textures.roughnessPath.empty() && textures.metallicPath.empty()
                       && textures.opacityPath.empty() && textures.colorPath.empty()
                       && textures.normalPath.empty() && textures.emissivePath.empty();
  if (constant && untextured) {
    // the meshes classify on these, only a change of class needs them synced again.
    auto emitter = [](GfVec3f const &c, GfVec3f const &e) {
      return std::max({c[0], c[1], c[2]}) < 0.02f && std::max({e[0], e[1], e[2]}) > 0.5f;
    };

    const bool sameClass = (row[3] < 0.98f) == (opacity < 0.98f)
                        && emitter(GfVec3f(row[0], row[1], row[2]), GfVec3f(row[8], row[9], row[10]))
                             == emitter(color, textures.emissiveColor);
    atlas->UpdateConstantMaterial(key, color, opacity, roughness, metallic, opacityThreshold, textures.emissiveColor);
    if (sameClass) return;
  }
  else {
    atlas->ForgetCell(key);
  }

  HdRenderIndex &index = sceneDelegate->GetRenderIndex();
  for (SdfPath const &id : HdAkariMaterialUsers(key)) {
    if (index.HasRprim(id)) index.GetChangeTracker().MarkRprimDirty(id, HdChangeTracker::DirtyMaterialId);
  }
}

PXR_NAMESPACE_CLOSE_SCOPE
