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
# include <Hd/sceneDelegate.h>
# include <Gf/vec3d.h>
# include <Gf/vec3f.h>
# include <Sdf/assetPath.h>
# include <Tf/token.h>
# include <Vt/value.h>
#else
# include <pxr/pxr.h>
# include <pxr/base/tf/staticTokens.h>
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

TF_DEFINE_PRIVATE_TOKENS(_tokens,
  ((atmosphere, "akari:atmosphere"))
  ((atmosphereAerialPerspectiveDistance, "akari:atmosphere:aerialPerspectiveDistance"))
  ((atmosphereGroundAlbedo, "akari:atmosphere:groundAlbedo"))
  ((atmosphereGroundTexture, "akari:atmosphere:groundTexture"))
  ((atmosphereHalo, "akari:atmosphere:halo"))
  ((atmosphereHaloColor, "akari:atmosphere:haloColor"))
  ((atmosphereHaloRadius, "akari:atmosphere:haloRadius"))
  ((atmosphereHaloShadow, "akari:atmosphere:haloShadow"))
  ((atmosphereHaloStreaks, "akari:atmosphere:haloStreaks"))
  ((atmosphereMieAbsorption, "akari:atmosphere:mieAbsorption"))
  ((atmosphereMieAnisotropy, "akari:atmosphere:mieAnisotropy"))
  ((atmosphereMieScaleHeight, "akari:atmosphere:mieScaleHeight"))
  ((atmosphereMieScattering, "akari:atmosphere:mieScattering"))
  ((atmosphereNightIntensity, "akari:atmosphere:nightIntensity"))
  ((atmosphereNightTexture, "akari:atmosphere:nightTexture"))
  ((atmosphereOzoneAbsorption, "akari:atmosphere:ozoneAbsorption"))
  ((atmosphereOzoneCenter, "akari:atmosphere:ozoneCenter"))
  ((atmosphereOzoneWidth, "akari:atmosphere:ozoneWidth"))
  ((atmosphereRayleighScaleHeight, "akari:atmosphere:rayleighScaleHeight"))
  ((atmosphereRayleighScattering, "akari:atmosphere:rayleighScattering"))
  ((atmosphereSkyIntensity, "akari:atmosphere:skyIntensity"))
  ((atmosphereThickness, "akari:atmosphere:thickness"))
  ((planet, "akari:planet"))
  ((planetBloomAmount, "akari:planet:bloomAmount"))
  ((planetBloomColor, "akari:planet:bloomColor"))
  ((planetCityDensity, "akari:planet:cityDensity"))
  ((planetCityIntensity, "akari:planet:cityIntensity"))
  ((planetCloudAltitude, "akari:planet:cloudAltitude"))
  ((planetCloudCoverage, "akari:planet:cloudCoverage"))
  ((planetCloudEvolution, "akari:planet:cloudEvolution"))
  ((planetCloudOpacity, "akari:planet:cloudOpacity"))
  ((planetCloudRotation, "akari:planet:cloudRotation"))
  ((planetCloudScale, "akari:planet:cloudScale"))
  ((planetCloudShading, "akari:planet:cloudShading"))
  ((planetCloudSoftness, "akari:planet:cloudSoftness"))
  ((planetCloudSwirl, "akari:planet:cloudSwirl"))
  ((planetCloudThickness, "akari:planet:cloudThickness"))
  ((planetContinentScale, "akari:planet:continentScale"))
  ((planetDesert, "akari:planet:desert"))
  ((planetDesertColor, "akari:planet:desertColor"))
  ((planetDetail, "akari:planet:detail"))
  ((planetFillColor, "akari:planet:fillColor"))
  ((planetFillIntensity, "akari:planet:fillIntensity"))
  ((planetForestColor, "akari:planet:forestColor"))
  ((planetIceCaps, "akari:planet:iceCaps"))
  ((planetLandColorHigh, "akari:planet:landColorHigh"))
  ((planetLandColorLow, "akari:planet:landColorLow"))
  ((planetMountainHeight, "akari:planet:mountainHeight"))
  ((planetOceanColor, "akari:planet:oceanColor"))
  ((planetOceanRoughness, "akari:planet:oceanRoughness"))
  ((planetRimColor, "akari:planet:rimColor"))
  ((planetRimIntensity, "akari:planet:rimIntensity"))
  ((planetRockColor, "akari:planet:rockColor"))
  ((planetSeaLevel, "akari:planet:seaLevel"))
  ((planetSeed, "akari:planet:seed"))
  ((planetShallowColor, "akari:planet:shallowColor"))
  ((planetSnowColor, "akari:planet:snowColor"))
  ((planetVegetation, "akari:planet:vegetation"))
  ((planetWaves, "akari:planet:waves"))
  ((planetWaveTime, "akari:planet:waveTime"))
);

namespace {

VtValue Primvar(HdSceneDelegate *sceneDelegate, SdfPath const &id, TfToken const &name)
{
  return sceneDelegate->Get(id, name);
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

void ReadFloat(HdSceneDelegate *sceneDelegate, SdfPath const &id, TfToken const &name, float &out)
{
  const VtValue value = Primvar(sceneDelegate, id, name);
  double d = 0.0;
  if (!First(value, out) && First(value, d)) out = float(d);
}

void ReadColor(HdSceneDelegate *sceneDelegate, SdfPath const &id, TfToken const &name, float &r, float &g, float &b)
{
  const VtValue value = Primvar(sceneDelegate, id, name);
  GfVec3f c;
  GfVec3d d;
  if (First(value, c)) { r = c[0]; g = c[1]; b = c[2]; }
  else if (First(value, d)) { r = float(d[0]); g = float(d[1]); b = float(d[2]); }
}

void ReadAsset(HdSceneDelegate *sceneDelegate, SdfPath const &id, TfToken const &name, std::string &out)
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
  if (!Enabled(Primvar(sceneDelegate, id, _tokens->atmosphere))) {
    scene->RemoveAtmosphere(id);
    return false;
  }

  HdAkariAtmosphereData data;
  data.id = id;
  data.transform = sceneDelegate->GetTransform(id);
  data.visible = sceneDelegate->GetVisible(id);
  data.radius = radius;
  ReadFloat(sceneDelegate, id, _tokens->atmosphereThickness, data.thickness);
  ReadColor(sceneDelegate, id, _tokens->atmosphereRayleighScattering, data.rayleighR, data.rayleighG, data.rayleighB);
  ReadFloat(sceneDelegate, id, _tokens->atmosphereRayleighScaleHeight, data.rayleighScaleHeight);
  ReadColor(sceneDelegate, id, _tokens->atmosphereMieScattering, data.mieR, data.mieG, data.mieB);
  ReadColor(sceneDelegate, id, _tokens->atmosphereMieAbsorption, data.mieAbsorptionR, data.mieAbsorptionG, data.mieAbsorptionB);
  ReadFloat(sceneDelegate, id, _tokens->atmosphereMieScaleHeight, data.mieScaleHeight);
  ReadFloat(sceneDelegate, id, _tokens->atmosphereMieAnisotropy, data.mieAnisotropy);
  ReadColor(sceneDelegate, id, _tokens->atmosphereOzoneAbsorption, data.ozoneR, data.ozoneG, data.ozoneB);
  ReadFloat(sceneDelegate, id, _tokens->atmosphereOzoneCenter, data.ozoneCenter);
  ReadFloat(sceneDelegate, id, _tokens->atmosphereOzoneWidth, data.ozoneWidth);
  ReadColor(sceneDelegate, id, _tokens->atmosphereGroundAlbedo, data.groundAlbedoR, data.groundAlbedoG, data.groundAlbedoB);
  ReadAsset(sceneDelegate, id, _tokens->atmosphereGroundTexture, data.groundTexture);
  ReadAsset(sceneDelegate, id, _tokens->atmosphereNightTexture, data.nightTexture);
  ReadFloat(sceneDelegate, id, _tokens->atmosphereNightIntensity, data.nightIntensity);
  ReadFloat(sceneDelegate, id, _tokens->atmosphereAerialPerspectiveDistance, data.aerialPerspectiveDistance);
  ReadFloat(sceneDelegate, id, _tokens->atmosphereSkyIntensity, data.skyIntensity);

  data.planet = Enabled(Primvar(sceneDelegate, id, _tokens->planet));
  ReadFloat(sceneDelegate, id, _tokens->planetSeed, data.planetSeed);
  ReadFloat(sceneDelegate, id, _tokens->planetSeaLevel, data.seaLevel);
  ReadFloat(sceneDelegate, id, _tokens->planetContinentScale, data.continentScale);
  ReadFloat(sceneDelegate, id, _tokens->planetMountainHeight, data.mountainHeight);
  ReadFloat(sceneDelegate, id, _tokens->planetVegetation, data.vegetation);
  ReadFloat(sceneDelegate, id, _tokens->planetDesert, data.desert);
  ReadFloat(sceneDelegate, id, _tokens->planetIceCaps, data.iceCaps);
  ReadColor(sceneDelegate, id, _tokens->planetOceanColor, data.oceanR, data.oceanG, data.oceanB);
  ReadFloat(sceneDelegate, id, _tokens->planetOceanRoughness, data.oceanRoughness);
  ReadFloat(sceneDelegate, id, _tokens->planetCloudCoverage, data.cloudCoverage);
  ReadFloat(sceneDelegate, id, _tokens->planetCloudAltitude, data.cloudAltitude);
  ReadFloat(sceneDelegate, id, _tokens->planetCloudRotation, data.cloudRotation);
  ReadFloat(sceneDelegate, id, _tokens->planetCloudEvolution, data.cloudEvolution);
  ReadFloat(sceneDelegate, id, _tokens->planetCloudOpacity, data.cloudOpacity);
  ReadFloat(sceneDelegate, id, _tokens->planetCloudScale, data.cloudScale);
  ReadFloat(sceneDelegate, id, _tokens->planetCloudThickness, data.cloudThickness);
  ReadColor(sceneDelegate, id, _tokens->planetLandColorLow, data.landColorLow[0], data.landColorLow[1], data.landColorLow[2]);
  ReadColor(sceneDelegate, id, _tokens->planetLandColorHigh, data.landColorHigh[0], data.landColorHigh[1], data.landColorHigh[2]);
  ReadColor(sceneDelegate, id, _tokens->planetForestColor, data.forestColor[0], data.forestColor[1], data.forestColor[2]);
  ReadColor(sceneDelegate, id, _tokens->planetDesertColor, data.desertColor[0], data.desertColor[1], data.desertColor[2]);
  ReadColor(sceneDelegate, id, _tokens->planetShallowColor, data.shallowColor[0], data.shallowColor[1], data.shallowColor[2]);
  ReadColor(sceneDelegate, id, _tokens->planetRockColor, data.rockColor[0], data.rockColor[1], data.rockColor[2]);
  ReadColor(sceneDelegate, id, _tokens->planetSnowColor, data.snowColor[0], data.snowColor[1], data.snowColor[2]);
  ReadColor(sceneDelegate, id, _tokens->planetBloomColor, data.bloomColor[0], data.bloomColor[1], data.bloomColor[2]);
  ReadFloat(sceneDelegate, id, _tokens->planetBloomAmount, data.bloomAmount);
  ReadFloat(sceneDelegate, id, _tokens->planetCityIntensity, data.cityIntensity);
  ReadFloat(sceneDelegate, id, _tokens->planetCityDensity, data.cityDensity);
  ReadFloat(sceneDelegate, id, _tokens->planetCloudSwirl, data.cloudSwirl);
  ReadFloat(sceneDelegate, id, _tokens->planetDetail, data.detail);
  ReadFloat(sceneDelegate, id, _tokens->planetCloudSoftness, data.cloudSoftness);
  ReadFloat(sceneDelegate, id, _tokens->planetCloudShading, data.cloudShading);
  ReadFloat(sceneDelegate, id, _tokens->planetWaves, data.waves);
  ReadFloat(sceneDelegate, id, _tokens->planetWaveTime, data.waveTime);
  ReadFloat(sceneDelegate, id, _tokens->atmosphereHalo, data.haloIntensity);
  ReadColor(sceneDelegate, id, _tokens->atmosphereHaloColor, data.haloColor[0], data.haloColor[1], data.haloColor[2]);
  ReadFloat(sceneDelegate, id, _tokens->atmosphereHaloRadius, data.haloRadius);
  ReadFloat(sceneDelegate, id, _tokens->atmosphereHaloStreaks, data.haloStreaks);
  ReadFloat(sceneDelegate, id, _tokens->atmosphereHaloShadow, data.haloShadow);
  ReadFloat(sceneDelegate, id, _tokens->planetFillIntensity, data.fillIntensity);
  ReadColor(sceneDelegate, id, _tokens->planetFillColor, data.fillColor[0], data.fillColor[1], data.fillColor[2]);
  ReadFloat(sceneDelegate, id, _tokens->planetRimIntensity, data.rimIntensity);
  ReadColor(sceneDelegate, id, _tokens->planetRimColor, data.rimColor[0], data.rimColor[1], data.rimColor[2]);

  scene->UpdateAtmosphere(std::move(data));
  scene->RemoveMesh(id);
  scene->RemoveProbe(id);
  return true;
}

PXR_NAMESPACE_CLOSE_SCOPE
