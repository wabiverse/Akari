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
# include <Hd/sceneDelegate.h>
# include <Gf/vec3d.h>
# include <Gf/vec3f.h>
# include <Sdf/assetPath.h>
# include <Tf/token.h>
# include <Vt/value.h>
#else
# include <pxr/pxr.h>
# include <pxr/imaging/hd/sceneDelegate.h>
# include <pxr/base/gf/vec3d.h>
# include <pxr/base/gf/vec3f.h>
# include <pxr/usd/sdf/assetPath.h>
# include <pxr/base/tf/token.h>
# include <pxr/base/vt/value.h>
#endif

#include "HdAkari/atmosphere.h"
#include "HdAkari/scene.h"

#include <string>

PXR_NAMESPACE_OPEN_SCOPE

namespace {

VtValue Primvar(HdSceneDelegate *sceneDelegate, SdfPath const &id, char const *name)
{
  return sceneDelegate->Get(id, TfToken(name));
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

bool Enabled(VtValue const &value)
{
  bool b = false;
  int i = 0;
  float f = 0.0f;
  if (First(value, b)) return b;
  if (First(value, i)) return i != 0;
  if (First(value, f)) return f != 0.0f;
  return false;
}

void ReadFloat(HdSceneDelegate *sceneDelegate, SdfPath const &id, char const *name, float &out)
{
  const VtValue value = Primvar(sceneDelegate, id, name);
  double d = 0.0;
  if (!First(value, out) && First(value, d)) out = float(d);
}

void ReadColor(HdSceneDelegate *sceneDelegate, SdfPath const &id, char const *name, float &r, float &g, float &b)
{
  const VtValue value = Primvar(sceneDelegate, id, name);
  GfVec3f c;
  GfVec3d d;
  if (First(value, c)) { r = c[0]; g = c[1]; b = c[2]; }
  else if (First(value, d)) { r = float(d[0]); g = float(d[1]); b = float(d[2]); }
}

void ReadAsset(HdSceneDelegate *sceneDelegate, SdfPath const &id, char const *name, std::string &out)
{
  const VtValue value = Primvar(sceneDelegate, id, name);
  SdfAssetPath asset;
  std::string path;
  if (First(value, asset)) out = asset.GetResolvedPath().empty() ? asset.GetAssetPath() : asset.GetResolvedPath();
  else if (First(value, path)) out = path;
}

} // namespace

bool HdAkariSyncAtmosphere(HdSceneDelegate *sceneDelegate,
                           SdfPath const &id,
                           HdAkariScene *scene,
                           double radius)
{
  if (!Enabled(Primvar(sceneDelegate, id, "akari:atmosphere"))) {
    scene->RemoveAtmosphere(id);
    return false;
  }

  HdAkariAtmosphereData data;
  data.id = id;
  data.transform = sceneDelegate->GetTransform(id);
  data.visible = sceneDelegate->GetVisible(id);
  data.radius = radius;
  ReadFloat(sceneDelegate, id, "akari:atmosphere:thickness", data.thickness);
  ReadColor(sceneDelegate, id, "akari:atmosphere:rayleighScattering", data.rayleighR, data.rayleighG, data.rayleighB);
  ReadFloat(sceneDelegate, id, "akari:atmosphere:rayleighScaleHeight", data.rayleighScaleHeight);
  ReadColor(sceneDelegate, id, "akari:atmosphere:mieScattering", data.mieR, data.mieG, data.mieB);
  ReadColor(sceneDelegate, id, "akari:atmosphere:mieAbsorption", data.mieAbsorptionR, data.mieAbsorptionG, data.mieAbsorptionB);
  ReadFloat(sceneDelegate, id, "akari:atmosphere:mieScaleHeight", data.mieScaleHeight);
  ReadFloat(sceneDelegate, id, "akari:atmosphere:mieAnisotropy", data.mieAnisotropy);
  ReadColor(sceneDelegate, id, "akari:atmosphere:ozoneAbsorption", data.ozoneR, data.ozoneG, data.ozoneB);
  ReadFloat(sceneDelegate, id, "akari:atmosphere:ozoneCenter", data.ozoneCenter);
  ReadFloat(sceneDelegate, id, "akari:atmosphere:ozoneWidth", data.ozoneWidth);
  ReadColor(sceneDelegate, id, "akari:atmosphere:groundAlbedo", data.groundAlbedoR, data.groundAlbedoG, data.groundAlbedoB);
  ReadAsset(sceneDelegate, id, "akari:atmosphere:groundTexture", data.groundTexture);
  ReadAsset(sceneDelegate, id, "akari:atmosphere:nightTexture", data.nightTexture);
  ReadFloat(sceneDelegate, id, "akari:atmosphere:nightIntensity", data.nightIntensity);
  ReadFloat(sceneDelegate, id, "akari:atmosphere:aerialPerspectiveDistance", data.aerialPerspectiveDistance);
  ReadFloat(sceneDelegate, id, "akari:atmosphere:skyIntensity", data.skyIntensity);

  data.planet = Enabled(Primvar(sceneDelegate, id, "akari:planet"));
  ReadFloat(sceneDelegate, id, "akari:planet:seed", data.planetSeed);
  ReadFloat(sceneDelegate, id, "akari:planet:seaLevel", data.seaLevel);
  ReadFloat(sceneDelegate, id, "akari:planet:continentScale", data.continentScale);
  ReadFloat(sceneDelegate, id, "akari:planet:mountainHeight", data.mountainHeight);
  ReadFloat(sceneDelegate, id, "akari:planet:vegetation", data.vegetation);
  ReadFloat(sceneDelegate, id, "akari:planet:desert", data.desert);
  ReadFloat(sceneDelegate, id, "akari:planet:iceCaps", data.iceCaps);
  ReadColor(sceneDelegate, id, "akari:planet:oceanColor", data.oceanR, data.oceanG, data.oceanB);
  ReadFloat(sceneDelegate, id, "akari:planet:oceanRoughness", data.oceanRoughness);
  ReadFloat(sceneDelegate, id, "akari:planet:cloudCoverage", data.cloudCoverage);
  ReadFloat(sceneDelegate, id, "akari:planet:cloudAltitude", data.cloudAltitude);
  ReadFloat(sceneDelegate, id, "akari:planet:cloudRotation", data.cloudRotation);
  ReadFloat(sceneDelegate, id, "akari:planet:cloudEvolution", data.cloudEvolution);
  ReadFloat(sceneDelegate, id, "akari:planet:cloudOpacity", data.cloudOpacity);
  ReadFloat(sceneDelegate, id, "akari:planet:cloudScale", data.cloudScale);
  ReadFloat(sceneDelegate, id, "akari:planet:cloudThickness", data.cloudThickness);
  ReadColor(sceneDelegate, id, "akari:planet:landColorLow", data.landColorLow[0], data.landColorLow[1], data.landColorLow[2]);
  ReadColor(sceneDelegate, id, "akari:planet:landColorHigh", data.landColorHigh[0], data.landColorHigh[1], data.landColorHigh[2]);
  ReadColor(sceneDelegate, id, "akari:planet:forestColor", data.forestColor[0], data.forestColor[1], data.forestColor[2]);
  ReadColor(sceneDelegate, id, "akari:planet:desertColor", data.desertColor[0], data.desertColor[1], data.desertColor[2]);
  ReadColor(sceneDelegate, id, "akari:planet:shallowColor", data.shallowColor[0], data.shallowColor[1], data.shallowColor[2]);
  ReadColor(sceneDelegate, id, "akari:planet:rockColor", data.rockColor[0], data.rockColor[1], data.rockColor[2]);
  ReadColor(sceneDelegate, id, "akari:planet:snowColor", data.snowColor[0], data.snowColor[1], data.snowColor[2]);
  ReadColor(sceneDelegate, id, "akari:planet:bloomColor", data.bloomColor[0], data.bloomColor[1], data.bloomColor[2]);
  ReadFloat(sceneDelegate, id, "akari:planet:bloomAmount", data.bloomAmount);
  ReadFloat(sceneDelegate, id, "akari:planet:cityIntensity", data.cityIntensity);
  ReadFloat(sceneDelegate, id, "akari:planet:cityDensity", data.cityDensity);
  ReadFloat(sceneDelegate, id, "akari:planet:cloudSwirl", data.cloudSwirl);
  ReadFloat(sceneDelegate, id, "akari:planet:detail", data.detail);
  ReadFloat(sceneDelegate, id, "akari:planet:cloudSoftness", data.cloudSoftness);
  ReadFloat(sceneDelegate, id, "akari:planet:cloudShading", data.cloudShading);
  ReadFloat(sceneDelegate, id, "akari:planet:waves", data.waves);
  ReadFloat(sceneDelegate, id, "akari:planet:waveTime", data.waveTime);
  ReadFloat(sceneDelegate, id, "akari:atmosphere:halo", data.haloIntensity);
  ReadColor(sceneDelegate, id, "akari:atmosphere:haloColor", data.haloColor[0], data.haloColor[1], data.haloColor[2]);
  ReadFloat(sceneDelegate, id, "akari:atmosphere:haloRadius", data.haloRadius);
  ReadFloat(sceneDelegate, id, "akari:atmosphere:haloStreaks", data.haloStreaks);
  ReadFloat(sceneDelegate, id, "akari:atmosphere:haloShadow", data.haloShadow);
  ReadFloat(sceneDelegate, id, "akari:planet:fillIntensity", data.fillIntensity);
  ReadColor(sceneDelegate, id, "akari:planet:fillColor", data.fillColor[0], data.fillColor[1], data.fillColor[2]);
  ReadFloat(sceneDelegate, id, "akari:planet:rimIntensity", data.rimIntensity);
  ReadColor(sceneDelegate, id, "akari:planet:rimColor", data.rimColor[0], data.rimColor[1], data.rimColor[2]);

  scene->UpdateAtmosphere(std::move(data));
  scene->RemoveMesh(id);
  scene->RemoveProbe(id);
  return true;
}

PXR_NAMESPACE_CLOSE_SCOPE
