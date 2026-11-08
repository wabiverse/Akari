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
# include <Sdf/assetPath.h>
# include <Sdf/layer.h>
# include <Sdf/timeCode.h>
# include <Tf/pathUtils.h>
# include <Usd/primRange.h>
# include <UsdGeom/camera.h>
# include <UsdGeom/xformable.h>
# include <UsdGeom/xformCache.h>
# include <UsdGeom/bboxCache.h>
# include <UsdGeom/tokens.h>
# include <UsdMedia/spatialAudio.h>
# include <UsdRender/settings.h>
# include <Vt/dictionary.h>
#else
# include <pxr/pxr.h>
# include <pxr/base/tf/staticTokens.h>
# include <pxr/base/tf/pathUtils.h>
# include <pxr/usd/sdf/assetPath.h>
# include <pxr/usd/sdf/layer.h>
# include <pxr/usd/sdf/timeCode.h>
# include <pxr/usd/usd/primRange.h>
# include <pxr/usd/usdGeom/camera.h>
# include <pxr/usd/usdGeom/xformable.h>
# include <pxr/usd/usdGeom/xformCache.h>
# include <pxr/usd/usdGeom/bboxCache.h>
# include <pxr/usd/usdGeom/tokens.h>
# include <pxr/usd/usdMedia/spatialAudio.h>
# include <pxr/usd/usdRender/settings.h>
# include <pxr/base/vt/dictionary.h>
#endif

#include "HdAkari/stageInfo.h"

#include <algorithm>
#include <cmath>
#include <vector>

PXR_NAMESPACE_OPEN_SCOPE

TF_DEFINE_PRIVATE_TOKENS(_tokens,
  ((bloom, "akari:bloom"))
  ((cut, "akari:cut"))
  ((flare, "akari:flare"))
  ((fogSimBoundsMax, "akari:fogSim:boundsMax"))
  ((fogSimBoundsMin, "akari:fogSim:boundsMin"))
  ((fogSimDamping, "akari:fogSim:damping"))
  ((fogSimDissipation, "akari:fogSim:dissipation"))
  ((fogSimEnable, "akari:fogSim:enable"))
  ((fogSimReplenish, "akari:fogSim:replenish"))
  ((fogSimResolution, "akari:fogSim:resolution"))
  ((fogSimSettle, "akari:fogSim:settle"))
  ((fogSimStartFrame, "akari:fogSim:startFrame"))
  ((fogSimSubsteps, "akari:fogSim:substeps"))
  ((fogSimVorticity, "akari:fogSim:vorticity"))
  ((primvarsFogDisturber, "primvars:akari:fogDisturber"))
  ((primvarsFogDisturberLift, "primvars:akari:fogDisturber:lift"))
  ((primvarsFogDisturberRadius, "primvars:akari:fogDisturber:radius"))
  ((primvarsLightProbe, "primvars:akari:lightProbe"))
  ((streak, "akari:streak"))
  ((volumeAmbient, "akari:volume:ambient"))
  ((volumeAnisotropy, "akari:volume:anisotropy"))
  ((volumeDensity, "akari:volume:density"))
  ((volumeFloorHeight, "akari:volume:floorHeight"))
  ((volumeHazeDensity, "akari:volume:hazeDensity"))
  ((volumeHeightFalloff, "akari:volume:heightFalloff"))
  ((volumeMaxDistance, "akari:volume:maxDistance"))
  ((volumeNoiseAmount, "akari:volume:noiseAmount"))
  ((volumeNoiseOctaves, "akari:volume:noiseOctaves"))
  ((volumeNoiseScale, "akari:volume:noiseScale"))
  ((volumeSunScatter, "akari:volume:sunScatter"))
  ((volumeSwirl, "akari:volume:swirl"))
  ((volumetrics, "akari:volumetrics"))
  ((volumeWind, "akari:volume:wind"))
);

HdAkariStageInfo
HdAkariInspectStage(UsdStage *stage)
{
  HdAkariStageInfo info;
  if (!stage) return info;

  const VtDictionary layerData = stage->GetRootLayer()->GetCustomLayerData();
  const auto cm = layerData.find("colorManagement");
  if (cm != layerData.end() && cm->second.IsHolding<VtDictionary>()) {
    const VtDictionary &d = cm->second.UncheckedGet<VtDictionary>();
    info.hasColorManagement = true;
    auto text = [&](char const *key, std::string &out) {
      auto it = d.find(key);
      if (it != d.end() && it->second.IsHolding<std::string>()) out = it->second.UncheckedGet<std::string>();
    };

    auto number = [&](char const *key, double &out) {
      auto it = d.find(key);
      if (it != d.end() && it->second.CanCast<double>()) out = VtValue::Cast<double>(it->second).UncheckedGet<double>();
    };

    text("viewTransform", info.viewTransform);
    text("look", info.look);
    number("exposure", info.exposure);
    number("gamma", info.gamma);
  }

  info.startTimeCode = stage->GetStartTimeCode();
  info.endTimeCode = stage->GetEndTimeCode();
  info.timeCodesPerSecond = stage->GetTimeCodesPerSecond();

  SdfPathVector renderCameras;
  const UsdRenderSettings settings = UsdRenderSettings::GetStageRenderSettings(UsdStageWeakPtr(stage));
  if (settings && settings.GetCameraRel().GetForwardedTargets(&renderCameras) && !renderCameras.empty() &&
      stage->GetPrimAtPath(renderCameras.front()).IsA<UsdGeomCamera>()) {
    info.renderCamera = renderCameras.front().GetString();
  }

  for (UsdPrim const &prim : stage->Traverse()) {
    if (prim.IsA<UsdGeomCamera>()) {
      info.cameras.push_back(prim.GetPath().GetString());
      continue;
    }

    if (!info.soundtrack.empty() || !prim.IsA<UsdMediaSpatialAudio>()) continue;

    UsdMediaSpatialAudio audio(prim);
    SdfAssetPath file;
    if (!audio.GetFilePathAttr().Get(&file) || file.GetAssetPath().empty()) continue;

    // an unresolved relative path is anchored to the layer that authored it.
    std::string path = file.GetResolvedPath();
    if (path.empty()) {
      const SdfLayerHandle layer = stage->GetRootLayer();
      path = TfIsRelativePath(file.GetAssetPath()) && layer
          ? TfNormPath(TfGetPathName(layer->GetRealPath()) + "/" + file.GetAssetPath())
          : file.GetAssetPath();
    }

    info.soundtrack = path;

    SdfTimeCode start;
    if (audio.GetStartTimeAttr().Get(&start)) info.soundtrackStartTimeCode = start.GetValue();
    audio.GetMediaOffsetAttr().Get(&info.soundtrackMediaOffset);
    audio.GetGainAttr().Get(&info.soundtrackGain);
  }

  return info;
}

bool
HdAkariLayerOpens(std::string const &path)
{
  return bool(SdfLayer::FindOrOpen(path));
}

HdAkariCameraLens
HdAkariCameraLensAt(UsdStage *stage, std::string const &path, double timeCode)
{
  HdAkariCameraLens lens;
  if (!stage || !SdfPath::IsValidPathString(path)) return lens;
  UsdGeomCamera camera(stage->GetPrimAtPath(SdfPath(path)));
  if (!camera) return lens;
  const UsdTimeCode t(timeCode);
  float f = 0.0f;
  if (camera.GetFStopAttr().Get(&f, t)) lens.fStop = f;
  if (camera.GetFocusDistanceAttr().Get(&f, t)) lens.focusDistance = f;
  if (camera.GetFocalLengthAttr().Get(&f, t)) lens.focalLength = f;
  if (camera.GetHorizontalApertureAttr().Get(&f, t)) lens.horizontalAperture = f;
  auto custom = [&](TfToken const &name, double &out) {
    if (UsdAttribute attr = camera.GetPrim().GetAttribute(name)) {
      float v = 0.0f;
      double d = 0.0;
      if (attr.Get(&v, t)) out = v;
      else if (attr.Get(&d, t)) out = d;
    }
  };

  custom(_tokens->bloom, lens.bloom);
  custom(_tokens->streak, lens.streak);
  custom(_tokens->flare, lens.flare);
  return lens;
}

double
HdAkariTimeCodesPerSecond(UsdStage *stage)
{
  return stage ? stage->GetTimeCodesPerSecond() : 0.0;
}

bool
HdAkariPrimTransformPoint(UsdStage *stage, std::string const &path, double timeCode, bool toLocal, double *xyz)
{
  if (!stage || !xyz || !SdfPath::IsValidPathString(path)) return false;
  const UsdPrim prim = stage->GetPrimAtPath(SdfPath(path));
  if (!prim) return false;
  UsdGeomXformCache cache{UsdTimeCode(timeCode)};
  GfMatrix4d m = cache.GetLocalToWorldTransform(prim);
  if (toLocal) m = m.GetInverse();
  const GfVec3d p = m.Transform(GfVec3d(xyz[0], xyz[1], xyz[2]));
  xyz[0] = p[0];
  xyz[1] = p[1];
  xyz[2] = p[2];
  return true;
}

bool
HdAkariPrimLocalCenter(UsdStage *stage, std::string const &path, double timeCode, double *xyz)
{
  if (!stage || !xyz || !SdfPath::IsValidPathString(path)) return false;
  const UsdPrim prim = stage->GetPrimAtPath(SdfPath(path));
  if (!prim) return false;
  UsdGeomBBoxCache cache(UsdTimeCode(timeCode), {UsdGeomTokens->default_, UsdGeomTokens->render, UsdGeomTokens->proxy});
  const GfRange3d range = cache.ComputeUntransformedBound(prim).ComputeAlignedRange();
  if (range.IsEmpty()) return false;
  const GfVec3d mid = range.GetMidpoint();
  xyz[0] = mid[0];
  xyz[1] = mid[1];
  xyz[2] = mid[2];
  return true;
}

HdAkariStageVolume
HdAkariStageVolumeAt(UsdStage *stage, double timeCode)
{
  HdAkariStageVolume volume;
  if (!stage) return volume;
  UsdPrim prim = stage->GetPrimAtPath(SdfPath("/World/RenderSettings"));
  if (!prim) return volume;
  const UsdTimeCode t(timeCode);
  auto number = [&](TfToken const &name, bool &has, double &out) {
    if (UsdAttribute attr = prim.GetAttribute(name)) {
      float v = 0.0f;
      double d = 0.0;
      if (attr.Get(&v, t)) { out = v; has = true; }
      else if (attr.Get(&d, t)) { out = d; has = true; }
    }
  };

  number(_tokens->volumeDensity, volume.hasDensity, volume.density);
  number(_tokens->volumeAnisotropy, volume.hasAnisotropy, volume.anisotropy);
  number(_tokens->volumeMaxDistance, volume.hasMaxDistance, volume.maxDistance);
  bool has = false;
  number(_tokens->volumeNoiseAmount, has, volume.noiseAmount);
  number(_tokens->volumeNoiseScale, has, volume.noiseScale);
  number(_tokens->volumeNoiseOctaves, has, volume.noiseOctaves);
  number(_tokens->volumeSwirl, has, volume.swirl);
  number(_tokens->volumeHeightFalloff, has, volume.heightFalloff);
  number(_tokens->volumeFloorHeight, has, volume.floorHeight);
  number(_tokens->volumeHazeDensity, has, volume.hazeDensity);
  number(_tokens->volumeAmbient, has, volume.ambient);
  number(_tokens->volumeSunScatter, has, volume.sunScatter);
  if (UsdAttribute attr = prim.GetAttribute(_tokens->volumeWind)) {
    GfVec3f w(0.0f);
    GfVec3d wd(0.0);
    if (attr.Get(&w, t)) { volume.windX = w[0]; volume.windY = w[1]; volume.windZ = w[2]; }
    else if (attr.Get(&wd, t)) { volume.windX = wd[0]; volume.windY = wd[1]; volume.windZ = wd[2]; }
  }

  const double tps = stage->GetTimeCodesPerSecond();
  volume.seconds = timeCode / (tps > 0.0 ? tps : 24.0);
  if (UsdAttribute attr = prim.GetAttribute(_tokens->volumetrics)) {
    bool on = true;
    if (attr.Get(&on, t)) { volume.enabled = on; volume.hasEnabled = true; }
  }

  return volume;
}

HdAkariFogSim
HdAkariFogSimAt(UsdStage *stage, double timeCode)
{
  HdAkariFogSim sim;
  if (!stage) return sim;
  UsdPrim prim = stage->GetPrimAtPath(SdfPath("/World/RenderSettings"));
  if (!prim) return sim;
  const UsdTimeCode t(timeCode);
  auto number = [&](TfToken const &name, double &out) {
    if (UsdAttribute attr = prim.GetAttribute(name)) {
      float v = 0.0f;
      double d = 0.0;
      int i = 0;
      if (attr.Get(&v, t)) out = v;
      else if (attr.Get(&d, t)) out = d;
      else if (attr.Get(&i, t)) out = i;
    }
  };

  auto vector = [&](TfToken const &name, double &x, double &y, double &z) {
    if (UsdAttribute attr = prim.GetAttribute(name)) {
      GfVec3f f;
      GfVec3d d;
      if (attr.Get(&f, t)) { x = f[0]; y = f[1]; z = f[2]; }
      else if (attr.Get(&d, t)) { x = d[0]; y = d[1]; z = d[2]; }
    }
  };

  if (UsdAttribute attr = prim.GetAttribute(_tokens->fogSimEnable)) {
    bool on = false;
    int onInt = 0;
    if (attr.Get(&on, t)) sim.enable = on;
    else if (attr.Get(&onInt, t)) sim.enable = onInt != 0;
  }

  vector(_tokens->fogSimBoundsMin, sim.minX, sim.minY, sim.minZ);
  vector(_tokens->fogSimBoundsMax, sim.maxX, sim.maxY, sim.maxZ);
  if (UsdAttribute attr = prim.GetAttribute(_tokens->fogSimResolution)) {
    int r = 0;
    float rf = 0.0f;
    GfVec3i r3;
    GfVec3f r3f;
    if (attr.Get(&r, t)) sim.resolution = r;
    else if (attr.Get(&rf, t)) sim.resolution = int(rf);
    else if (attr.Get(&r3, t)) sim.resolution = r3[0];
    else if (attr.Get(&r3f, t)) sim.resolution = int(r3f[0]);
  }

  double substeps = sim.substeps;
  number(_tokens->fogSimVorticity, sim.vorticity);
  number(_tokens->fogSimStartFrame, sim.startFrame);
  number(_tokens->fogSimSubsteps, substeps);
  number(_tokens->fogSimDissipation, sim.dissipation);
  number(_tokens->fogSimSettle, sim.settle);
  number(_tokens->fogSimReplenish, sim.replenish);
  number(_tokens->fogSimDamping, sim.damping);
  sim.substeps = std::max(1, int(substeps));
  return sim;
}

int
HdAkariFogDisturbersAt(UsdStage *stage, double timeCode, float *out, int capacity, double window)
{
  if (!stage || !out || capacity <= 0) return 0;
  // the disturbers are found once per stage, then only their transforms are read.
  static UsdStage *cachedStage = nullptr;
  static std::vector<SdfPath> cached;
  if (cachedStage != stage) {
    cachedStage = stage;
    cached.clear();
    for (UsdPrim const &prim : stage->Traverse()) {
      UsdAttribute flag = prim.GetAttribute(_tokens->primvarsFogDisturber);
      bool on = false;
      int onInt = 0;
      if (flag && ((flag.Get(&on) && on) || (flag.Get(&onInt) && onInt != 0))) cached.push_back(prim.GetPath());
    }
  }

  const double tps = stage->GetTimeCodesPerSecond() > 0.0 ? stage->GetTimeCodesPerSecond() : 24.0;
  int count = 0;
  for (SdfPath const &path : cached) {
    if (count >= capacity) break;
    UsdPrim prim = stage->GetPrimAtPath(path);
    UsdGeomXformable xf(prim);
    if (!xf) continue;
    UsdGeomImageable image(prim);
    if (image && image.ComputeVisibility(UsdTimeCode(timeCode)) == UsdGeomTokens->invisible) continue;
    const GfVec3d now = xf.ComputeLocalToWorldTransform(UsdTimeCode(timeCode)).ExtractTranslation();
    const double span = window > 0.0 ? window : 1.0;
    const GfVec3d before = xf.ComputeLocalToWorldTransform(UsdTimeCode(timeCode - span)).ExtractTranslation();
    float radius = 0.5f;
    if (UsdAttribute r = prim.GetAttribute(_tokens->primvarsFogDisturberRadius)) {
      double rd = 0.0;
      if (!r.Get(&radius, UsdTimeCode(timeCode)) && r.Get(&rd, UsdTimeCode(timeCode))) radius = float(rd);
    }

    const GfVec3d v = (now - before) * (tps / span);
    float lift = 1.0f;
    if (UsdAttribute l = prim.GetAttribute(_tokens->primvarsFogDisturberLift)) {
      double ld = 0.0;
      if (!l.Get(&lift, UsdTimeCode(timeCode)) && l.Get(&ld, UsdTimeCode(timeCode))) lift = float(ld);
    }

    float *o = out + count * 8;
    o[0] = float(now[0]); o[1] = float(now[1]); o[2] = float(now[2]); o[3] = radius;
    o[4] = float(v[0]); o[5] = float(v[1]); o[6] = float(v[2]); o[7] = lift;
    ++count;
  }

  return count;
}

HdAkariShutter
HdAkariCameraShutter(UsdStage *stage, std::string const &path, double timeCode)
{
  HdAkariShutter shutter;
  if (!stage || !SdfPath::IsValidPathString(path)) return shutter;
  UsdGeomCamera camera(stage->GetPrimAtPath(SdfPath(path)));
  if (!camera) return shutter;
  camera.GetShutterOpenAttr().Get(&shutter.open, UsdTimeCode(timeCode));
  camera.GetShutterCloseAttr().Get(&shutter.close, UsdTimeCode(timeCode));
  // a cut's first frame doesn't look back across it.
  if (UsdAttribute attr = camera.GetPrim().GetAttribute(_tokens->cut)) {
    bool cut = false, next = false;
    attr.Get(&cut, UsdTimeCode(timeCode));
    attr.Get(&next, UsdTimeCode(std::floor(timeCode) + 1.0));
    if (cut) shutter.open = std::max(shutter.open, 0.0);
    if (next) shutter.close = std::min(shutter.close, 0.0);
  }

  return shutter;
}

int
HdAkariProbeBakeTimes(UsdStage *stage, double *out, int capacity)
{
  if (!stage || !out || capacity <= 0) return 0;
  std::vector<double> times;
  for (UsdPrim const &prim : stage->Traverse()) {
    if (!prim.HasAttribute(_tokens->primvarsLightProbe)) continue;
    UsdGeomImageable image(prim);
    if (!image) continue;
    std::vector<double> candidates = {stage->GetStartTimeCode()};
    for (UsdPrim p = prim; p && !p.IsPseudoRoot(); p = p.GetParent()) {
      std::vector<double> samples;
      if (UsdAttribute vis = UsdGeomImageable(p).GetVisibilityAttr()) vis.GetTimeSamples(&samples);
      candidates.insert(candidates.end(), samples.begin(), samples.end());
    }

    std::sort(candidates.begin(), candidates.end());
    for (double t : candidates) {
      if (t < stage->GetStartTimeCode() || t > stage->GetEndTimeCode()) continue;
      if (image.ComputeVisibility(UsdTimeCode(t)) != UsdGeomTokens->invisible) {
        times.push_back(std::round(t));
        break;
      }
    }
  }

  std::sort(times.begin(), times.end());
  times.erase(std::unique(times.begin(), times.end()), times.end());
  const int count = std::min(int(times.size()), capacity);
  std::copy(times.begin(), times.begin() + count, out);
  return count;
}

PXR_NAMESPACE_CLOSE_SCOPE
