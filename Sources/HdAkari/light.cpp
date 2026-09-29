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
# include <Hd/light.h>
# include <Hd/sceneDelegate.h>
# include <Hd/tokens.h>
# include <Vt/value.h>
#else
# include <pxr/pxr.h>
# include <pxr/imaging/hd/changeTracker.h>
# include <pxr/imaging/hd/light.h>
# include <pxr/imaging/hd/sceneDelegate.h>
# include <pxr/imaging/hd/tokens.h>
# include <pxr/base/vt/value.h>
#endif

#include "HdAkari/light.h"
#include "HdAkari/renderParam.h"
#include "HdAkari/scene.h"

PXR_NAMESPACE_OPEN_SCOPE

HdAkariLight::HdAkariLight(SdfPath const &id)
  : HdLight(id)
{}

HdAkariLight::~HdAkariLight() = default;

HdDirtyBits
HdAkariLight::GetInitialDirtyBitsMask() const
{
  return HdLight::AllDirty;
}

void
HdAkariLight::Sync(HdSceneDelegate *sceneDelegate,
                   HdRenderParam   *renderParam,
                   HdDirtyBits     *dirtyBits)
{
  const SdfPath &id = GetId();
  auto *param = static_cast<HdAkariRenderParam *>(renderParam);
  HdAkariScene *scene = param ? param->GetScene() : nullptr;
  if (!scene || id.IsEmpty())
  {
    *dirtyBits = HdChangeTracker::Clean;
    return;
  }

  HdAkariLightData data;
  data.id = id;
  data.transform = sceneDelegate->GetTransform(id);
  data.visible = sceneDelegate->GetVisible(id);

  const VtValue intensityVal = sceneDelegate->GetLightParamValue(id, HdLightTokens->intensity);
  if (intensityVal.IsHolding<float>())
  {
    data.intensity = intensityVal.UncheckedGet<float>();
  }

  const VtValue exposureVal = sceneDelegate->GetLightParamValue(id, HdLightTokens->exposure);
  if (exposureVal.IsHolding<float>())
  {
    data.exposure = exposureVal.UncheckedGet<float>();
  }

  const VtValue colorVal = sceneDelegate->GetLightParamValue(id, HdLightTokens->color);
  if (colorVal.IsHolding<GfVec3f>())
  {
    const GfVec3f color = colorVal.UncheckedGet<GfVec3f>();
    data.colorR = color[0];
    data.colorG = color[1];
    data.colorB = color[2];
  }

  const VtValue radiusVal = sceneDelegate->GetLightParamValue(id, HdLightTokens->radius);
  if (radiusVal.IsHolding<float>())
  {
    data.radius = radiusVal.UncheckedGet<float>();
  }

  data.dataRevision = ++_dataGeneration;

  scene->UpdateLight(std::move(data));

  *dirtyBits = HdChangeTracker::Clean;
}

void
HdAkariLight::Finalize(HdRenderParam *renderParam)
{
  if (auto *param = static_cast<HdAkariRenderParam *>(renderParam))
  {
    if (HdAkariScene *scene = param->GetScene())
    {
      scene->RemoveLight(GetId());
    }
  }
}

PXR_NAMESPACE_CLOSE_SCOPE
