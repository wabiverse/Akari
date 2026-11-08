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
# include <Hd/light.h>
# include <Hd/sceneDelegate.h>
# include <Hd/tokens.h>
# include <Sdf/assetPath.h>
# include <Vt/array.h>
# include <Vt/value.h>
#else
# include <pxr/pxr.h>
# include <pxr/base/tf/staticTokens.h>
# include <pxr/imaging/hd/changeTracker.h>
# include <pxr/imaging/hd/light.h>
# include <pxr/imaging/hd/sceneDelegate.h>
# include <pxr/imaging/hd/tokens.h>
# include <pxr/usd/sdf/assetPath.h>
# include <pxr/base/vt/array.h>
# include <pxr/base/vt/value.h>
#endif

#include <algorithm>
#include <cmath>

#include "HdAkari/light.h"
#include "HdAkari/domeImage.h"
#include "HdAkari/renderParam.h"
#include "HdAkari/scene.h"

PXR_NAMESPACE_OPEN_SCOPE

TF_DEFINE_PRIVATE_TOKENS(_tokens,
  ((hero, "akari:hero"))
  ((lightCameraVisible, "akari:light:cameraVisible"))
  ((lightProbes, "akari:light:probes"))
  ((primvarsLightCameraVisible, "primvars:akari:light:cameraVisible"))
  ((primvarsLightProbes, "primvars:akari:light:probes"))
  ((userPropertiesAkariHero, "userProperties:akari_hero"))
);

HdAkariLight::HdAkariLight(SdfPath const &id, TfToken const &type)
  : HdLight(id),
    _type(type)
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

  if (_type == HdPrimTypeTokens->domeLight)
  {
    HdAkariDomeData dome;
    dome.id = id;
    dome.transform = sceneDelegate->GetTransform(id);
    dome.visible = sceneDelegate->GetVisible(id);

    const VtValue intensity = sceneDelegate->GetLightParamValue(id, HdLightTokens->intensity);
    if (intensity.IsHolding<float>())
    {
      dome.intensity = intensity.UncheckedGet<float>();
    }

    const VtValue exposure = sceneDelegate->GetLightParamValue(id, HdLightTokens->exposure);
    if (exposure.IsHolding<float>())
    {
      dome.exposure = exposure.UncheckedGet<float>();
    }

    const VtValue color = sceneDelegate->GetLightParamValue(id, HdLightTokens->color);
    if (color.IsHolding<GfVec3f>())
    {
      const GfVec3f c = color.UncheckedGet<GfVec3f>();
      dome.colorR = c[0]; dome.colorG = c[1]; dome.colorB = c[2];
    }

    const VtValue file = sceneDelegate->GetLightParamValue(id, HdLightTokens->textureFile);
    if (file.IsHolding<SdfAssetPath>())
    {
      const SdfAssetPath &asset = file.UncheckedGet<SdfAssetPath>();
      dome.textureFile = asset.GetResolvedPath().empty() ? asset.GetAssetPath() : asset.GetResolvedPath();
      HdAkariPrefetchDomeImage(dome.textureFile, HdAkariDomeSmallWidth, HdAkariDomeSunThreshold);
    }
    
    scene->UpdateDome(std::move(dome));
    *dirtyBits = HdChangeTracker::Clean;
    return;
  }

  if (_type == HdPrimTypeTokens->distantLight)
  {
    HdAkariDistantData distant;
    distant.id = id;
    distant.transform = sceneDelegate->GetTransform(id);
    distant.visible = sceneDelegate->GetVisible(id);
    const VtValue intensity = sceneDelegate->GetLightParamValue(id, HdLightTokens->intensity);
    if (intensity.IsHolding<float>()) distant.intensity = intensity.UncheckedGet<float>();
    const VtValue exposure = sceneDelegate->GetLightParamValue(id, HdLightTokens->exposure);
    if (exposure.IsHolding<float>()) distant.exposure = exposure.UncheckedGet<float>();
    const VtValue angle = sceneDelegate->GetLightParamValue(id, HdLightTokens->angle);
    if (angle.IsHolding<float>()) distant.angle = angle.UncheckedGet<float>();
    const VtValue color = sceneDelegate->GetLightParamValue(id, HdLightTokens->color);
    if (color.IsHolding<GfVec3f>())
    {
      const GfVec3f c = color.UncheckedGet<GfVec3f>();
      distant.colorR = c[0]; distant.colorG = c[1]; distant.colorB = c[2];
    }
    // intensity is the luminance of its disk, normalized or not, as RenderMan's distant light has no normalize.
    const float halfAngle = std::clamp(distant.angle * float(M_PI) / 360.0f, 0.0f, float(M_PI));
    if (halfAngle > 0.0f)
    {
      const float s = std::sin(halfAngle);
      distant.intensity *= float(M_PI) * (halfAngle <= float(M_PI) / 2 ? s * s : 2.0f - s * s);
    }

    scene->UpdateDistant(std::move(distant));
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

  const VtValue diffuseVal = sceneDelegate->GetLightParamValue(id, HdLightTokens->diffuse);
  if (diffuseVal.IsHolding<float>())
  {
    data.diffuse = diffuseVal.UncheckedGet<float>();
  }

  const VtValue specularVal = sceneDelegate->GetLightParamValue(id, HdLightTokens->specular);
  if (specularVal.IsHolding<float>())
  {
    data.specular = specularVal.UncheckedGet<float>();
  }

  const VtValue radiusVal = sceneDelegate->GetLightParamValue(id, HdLightTokens->radius);
  if (radiusVal.IsHolding<float>())
  {
    data.radius = radiusVal.UncheckedGet<float>();
  }

  // a sphere's radius scales with its transform, as UsdLux has it, the other shapes scale by their axes.
  if (_type == HdPrimTypeTokens->sphereLight)
  {
    const GfMatrix4d xf = sceneDelegate->GetTransform(id);
    data.radius *= float(std::cbrt(std::abs(xf.GetDeterminant3())));
  }

  // cylinders and disks shade as the sphere of the same emitting area.
  float area = 4.0f * float(M_PI) * data.radius * data.radius;
  if (_type == HdPrimTypeTokens->cylinderLight)
  {
    const VtValue lengthVal = sceneDelegate->GetLightParamValue(id, HdLightTokens->length);
    const float length = lengthVal.IsHolding<float>() ? lengthVal.UncheckedGet<float>() : 1.0f;
    area = 2.0f * float(M_PI) * data.radius * length;
    data.length = length;
    data.tubeRadius = data.radius;
    data.radius = std::sqrt(data.radius * length * 0.5f);
  }
  else if (_type == HdPrimTypeTokens->diskLight)
  {
    area = float(M_PI) * data.radius * data.radius;
    data.width = data.height = data.radius * std::sqrt(float(M_PI));
    data.radius *= 0.5f;
  }
  else if (_type == HdPrimTypeTokens->rectLight)
  {
    const VtValue widthVal = sceneDelegate->GetLightParamValue(id, HdLightTokens->width);
    const VtValue heightVal = sceneDelegate->GetLightParamValue(id, HdLightTokens->height);
    data.width = widthVal.IsHolding<float>() ? widthVal.UncheckedGet<float>() : 1.0f;
    data.height = heightVal.IsHolding<float>() ? heightVal.UncheckedGet<float>() : 1.0f;
    area = data.width * data.height;
    data.radius = std::sqrt(area / (4.0f * float(M_PI)));
  }

  // a normalized light's intensity is its power, spread over its surface.
  const VtValue normalizeVal = sceneDelegate->GetLightParamValue(id, HdLightTokens->normalize);
  if (normalizeVal.IsHolding<bool>() && normalizeVal.UncheckedGet<bool>() && area > 0.0f)
  {
    data.intensity /= area;
  }

  // a hero light always keeps full quality shadows, `akari:hero` in USD or an `akari_hero` user property.
  for (TfToken const &name : {_tokens->hero, _tokens->userPropertiesAkariHero})
  {
    const VtValue heroVal = sceneDelegate->GetLightParamValue(id, name);
    if (heroVal.IsHolding<bool>()) data.hero = heroVal.UncheckedGet<bool>();
    else if (heroVal.IsHolding<int>()) data.hero = heroVal.UncheckedGet<int>() != 0;
    else if (heroVal.IsHolding<float>()) data.hero = heroVal.UncheckedGet<float>() != 0.0f;
    if (data.hero) break;
  }

  for (TfToken const &name : {_tokens->primvarsLightCameraVisible, _tokens->lightCameraVisible})
  {
    const VtValue v = sceneDelegate->GetLightParamValue(id, name);
    if (v.IsHolding<bool>()) { data.cameraVisible = v.UncheckedGet<bool>(); break; }
    if (v.IsHolding<int>()) { data.cameraVisible = v.UncheckedGet<int>() != 0; break; }
    if (v.IsHolding<VtArray<bool>>() && !v.UncheckedGet<VtArray<bool>>().empty()) { data.cameraVisible = v.UncheckedGet<VtArray<bool>>()[0]; break; }
  }

  for (TfToken const &name : {_tokens->primvarsLightProbes, _tokens->lightProbes})
  {
    const VtValue v = sceneDelegate->GetLightParamValue(id, name);
    if (v.IsHolding<bool>()) { data.probes = v.UncheckedGet<bool>(); break; }
    if (v.IsHolding<int>()) { data.probes = v.UncheckedGet<int>() != 0; break; }
    if (v.IsHolding<VtArray<bool>>() && !v.UncheckedGet<VtArray<bool>>().empty()) { data.probes = v.UncheckedGet<VtArray<bool>>()[0]; break; }
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
      if (_type == HdPrimTypeTokens->domeLight) scene->RemoveDome(GetId());
      else if (_type == HdPrimTypeTokens->distantLight) scene->RemoveDistant(GetId());
      else scene->RemoveLight(GetId());
    }
  }
}

PXR_NAMESPACE_CLOSE_SCOPE
