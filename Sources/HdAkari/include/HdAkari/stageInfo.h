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
#ifndef HDAKARI_STAGE_INFO_H
#define HDAKARI_STAGE_INFO_H

#if __has_include(<pxr/pxrns.h>)
# include <pxr/pxrns.h>
# include <Usd/stage.h>
#else
# include <pxr/pxr.h>
# include <pxr/usd/usd/stage.h>
#endif

#include "HdAkari/api.h"

#include <string>
#include <vector>

PXR_NAMESPACE_OPEN_SCOPE

/// What a final render needs to know about a stage.
struct HdAkariStageInfo
{
  /// Every camera prim's path, in traversal order.
  std::vector<std::string> cameras;
  /// The camera the stage's render settings render through, empty without one.
  std::string renderCamera;
  double startTimeCode = 0;
  double endTimeCode = 0;
  double timeCodesPerSecond = 24;
  /// The first spatial audio prim's resolved file, empty when there is none.
  std::string soundtrack;
  /// The time code the soundtrack starts playing at.
  double soundtrackStartTimeCode = 0;
  /// Seconds into the file playback begins from.
  double soundtrackMediaOffset = 0;
  double soundtrackGain = 1;
  /// The color management the layer was authored with,
  /// `customLayerData`'s `colorManagement` dictionary.
  bool hasColorManagement = false;
  std::string viewTransform;
  std::string look;
  double exposure = 0;
  double gamma = 1;
};

HDAKARI_API HdAkariStageInfo HdAkariInspectStage(UsdStage *stage);

/// The stage's time codes per second, without walking it like HdAkariInspectStage.
HDAKARI_API double HdAkariTimeCodesPerSecond(UsdStage *stage);

/// Moves `xyz` between the prim at `path`'s own space and the world at `timeCode`, false without the prim.
HDAKARI_API bool HdAkariPrimTransformPoint(UsdStage *stage, std::string const &path, double timeCode, bool toLocal,
                                           double *xyz);

/// The center of the prim at `path`'s bounds in its own space at `timeCode`, false without the prim.
HDAKARI_API bool HdAkariPrimLocalCenter(UsdStage *stage, std::string const &path, double timeCode, double *xyz);

/// Whether the layer at `path` opens, false when it is missing or fails to parse.
HDAKARI_API bool HdAkariLayerOpens(std::string const &path);

/// A camera's `shutter:open` and `shutter:close` at `timeCode`, in frames around it.
struct HdAkariShutter
{
  double open = 0;
  double close = 0;
};

HDAKARI_API HdAkariShutter HdAkariCameraShutter(UsdStage *stage, std::string const &path, double timeCode);

/// A camera's lens for depth of field (`fStop` 0 = pinhole) and its `akari:bloom`, `akari:streak`
/// and `akari:flare` strengths, at `timeCode`.
struct HdAkariCameraLens
{
  double fStop = 0;
  double focusDistance = 0;
  double focalLength = 50;
  double horizontalAperture = 36;
  double bloom = 0.04;
  double streak = 0;
  double flare = 0;
};

HDAKARI_API HdAkariCameraLens HdAkariCameraLensAt(UsdStage *stage, std::string const &path, double timeCode);

/// The froxel fog `/World/RenderSettings` authors at `timeCode`: `akari:volume:density` (per meter),
/// `akari:volume:anisotropy`, `akari:volume:maxDistance` (meters) and `akari:volumetrics`,
/// each `has` false where it isn't authored.
struct HdAkariStageVolume
{
  bool hasDensity = false;
  double density = 0;
  bool hasAnisotropy = false;
  double anisotropy = 0;
  bool hasMaxDistance = false;
  double maxDistance = 0;
  bool hasEnabled = false;
  bool enabled = true;
  /// The fog's shape: noise (0 = homogeneous), its feature size (m) and octaves, the wind (m/s) that
  /// scrolls it and the swirl that churns it, a ground layer from `floorHeight` (world up) thinning
  /// over `heightFalloff` (m, 0 = none) and the haze density (per m) everywhere above it.
  double noiseAmount = 0;
  double noiseScale = 1.5;
  double noiseOctaves = 4;
  double windX = 0, windY = 0, windZ = 0;
  double swirl = 0;
  double heightFalloff = 0;
  double floorHeight = 0;
  double hazeDensity = 0;
  /// How much the sky and environment light the fog (1), the cinematic look wants the lights alone.
  double ambient = 1;
  /// How much the sun scatters in the fog (1), 0 indoors, where its shadow can't be trusted to reach.
  double sunScatter = 1;
  /// The stage time in seconds, which the flow is evaluated at.
  double seconds = 0;
};

HDAKARI_API HdAkariStageVolume HdAkariStageVolumeAt(UsdStage *stage, double timeCode);

/// The fog smoke simulation `/World/RenderSettings` asks for, `akari:fogSim:*`.
struct HdAkariFogSim
{
  bool enable = false;
  double minX = -14, minY = -12, minZ = -0.65;
  double maxX = 14, maxY = 12, maxZ = 2.4;
  int resolution = 192;
  double vorticity = 2.5;
  double startFrame = 1;
  int substeps = 2;
  double dissipation = 0.15;
  double settle = 0.12;
  double replenish = 0.6;
  double damping = 0.4;
};

HDAKARI_API HdAkariFogSim HdAkariFogSimAt(UsdStage *stage, double timeCode);

/// The prims with `primvars:akari:fogDisturber` set, at most `capacity`, eight floats each into `out`:
/// world position, `primvars:akari:fogDisturber:radius` (m), velocity (stage units per second) over the
/// `window` frames before `timeCode`, and `primvars:akari:fogDisturber:lift` (default 1).
HDAKARI_API int HdAkariFogDisturbersAt(UsdStage *stage, double timeCode, float *out, int capacity, double window = 1.0);

/// The first frame each prim with `primvars:akari:lightProbe` is visible, at most `capacity` of
/// them in order into `out`, so a viewport can bake them all as the stage loads.
HDAKARI_API int HdAkariProbeBakeTimes(UsdStage *stage, double *out, int capacity);

PXR_NAMESPACE_CLOSE_SCOPE

#endif // HDAKARI_STAGE_INFO_H
