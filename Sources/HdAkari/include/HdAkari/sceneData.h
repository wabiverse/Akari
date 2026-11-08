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
#ifndef HDAKARI_SCENE_DATA_H
#define HDAKARI_SCENE_DATA_H

#if __has_include(<pxr/pxrns.h>)
# include <pxr/pxrns.h>
# include <Sdf/path.h>
# include <Gf/matrix4d.h>
# include <Gf/matrix4f.h>
# include <Gf/vec2f.h>
# include <Gf/vec3d.h>
# include <Gf/vec3f.h>
# include <Gf/vec3i.h>
# include <Vt/array.h>
# include <Vt/types.h>
# include <Arch/swiftInterop.h>
# include <Tf/sharedPtrRetainReleaseHelper.h>
# include <Tf/stringUtils.h>
#else
# include <pxr/pxr.h>
# include <pxr/usd/sdf/path.h>
# include <pxr/base/gf/matrix4d.h>
# include <pxr/base/gf/matrix4f.h>
# include <pxr/base/gf/vec2f.h>
# include <pxr/base/gf/vec3d.h>
# include <pxr/base/gf/vec3f.h>
# include <pxr/base/gf/vec3i.h>
# include <pxr/base/vt/array.h>
# include <pxr/base/vt/types.h>
# include <pxr/base/tf/sharedPtrRetainReleaseHelper.h>
# include <pxr/base/tf/stringUtils.h>
#endif

#include "HdAkari/api.h"

#include <algorithm>
#include <cmath>
#include <cstdint>
#include <cstring>
#include <iterator>
#include <string>
#include <unordered_map>
#include <unordered_set>
#include <vector>

PXR_NAMESPACE_OPEN_SCOPE

/// @struct HdAkariMeshData
///
/// The CPU-side geometry Akari keeps for one mesh Rprim.
///
/// Updated in Sync and consumed by the GPU draw path, which gets
/// triangulated on ingest so the renderer never retessellates per
/// frame.
///
struct HdAkariMeshData
{
  SdfPath id;
  VtVec3fArray points;          // object space
  VtVec3iArray triangleIndices; // into points
  VtVec2fArray uvs;             // atlas space UV, one per triangleIndices corner, or one constant value
  GfMatrix4d transform = GfMatrix4d(1.0);
  /// The matrices taking `transform`'s output to world space, one per
  /// instance, empty when the mesh is drawn once at `transform`. Shared with
  /// every rprim under the same prototype, see `HdAkariInstanceSet`.
  VtMatrix4fArray instances;
  uint64_t instancesKey = 0;
  GfVec3f displayColor = GfVec3f(0.8f, 0.8f, 0.8f);
  float opacity = 1.0f;   // from the bound material's UsdPreviewSurface.
  bool transparent = false; // a constant opacity below 1 without a threshold, drawn by the transparency pass.
  bool emitter = false;     // black and emissive, light that casts no shadow.
  bool smooth = false;      // a subdivision surface, shaded without hard edges.
  /// Each triangle's Ptex face, its corners' places on it two bits apiece above.
  VtIntArray triangleFaces;
  /// Its faces' resolutions and the map's streaming id, -1 when it doesn't stream.
  VtIntArray faceRes;
  int ptexMap = -1;
  float roughness = 0.5f; // UsdPreviewSurface's own default.
  float metallic = 0.0f;  // UsdPreviewSurface's own default.
  bool visible = true;
  uint64_t dataRevision = 0; // incremented each Sync, GPU cache keys off this.
  uint64_t topologyRevision = 0; // only moves with the triangles and uvs, not the points.
  /// Hashes the object space geometry and material, so identical prototypes
  /// under different instancers can share one draw. Zero when not computed.
  uint64_t contentKey = 0;
  int32_t primId = -1;       // the Rprim's id, written to the primId AOV for picking.

  // UsdSkel meshes skinned on the GPU, `points` then holds the bind space rest points.
  int32_t skinInfluencesPerPoint = 0; // 0 when the points arrive already skinned.
  VtVec2fArray skinInfluences;        // (joint, weight), skinInfluencesPerPoint per point.
  VtMatrix4fArray skinXforms;         // per joint, bind space to the prim's local space.
  GfVec3f skinMin = GfVec3f(0.0f), skinMax = GfVec3f(0.0f); // this frame's local bounds.
  uint64_t skinRevision = 0;          // only moves with the influences and rest points.

  size_t TriangleCount() const { return triangleIndices.size(); }
};


struct HdAkariLightData
{
  SdfPath id;
  GfMatrix4d transform = GfMatrix4d(1.0);
  float colorR = 1.0f;
  float colorG = 1.0f;
  float colorB = 1.0f;
  float intensity = 1.0f;
  float exposure = 0.0f;
  float radius = 0.5f;
  float diffuse = 1.0f;
  float specular = 1.0f;
  /// A cylinder light's length along its local x axis and its own radius, 0 for the rest.
  float length = 0.0f;
  float tubeRadius = 0.0f;
  /// A rect light's size along its local x and y, emitting toward -z, a disk's as the square of its area, 0 for the rest.
  float width = 0.0f;
  float height = 0.0f;
  bool hero = false;
  bool visible = true;
  bool cameraVisible = true; // false keeps its glow out of what the camera sees through the fog, it still lights.
  bool probes = true;        // false leaves it out of the light probes' bounce, for lights that move every frame.
  uint64_t dataRevision = 0;
};

/// A dome light, the environment every direction sees, `textureFile` is
/// resolved and empty for a constant color.
struct HdAkariDomeData
{
  SdfPath id;
  GfMatrix4d transform = GfMatrix4d(1.0);
  float colorR = 1.0f;
  float colorG = 1.0f;
  float colorB = 1.0f;
  float intensity = 1.0f;
  float exposure = 0.0f;
  std::string textureFile;
  bool visible = true;
};

/// A distant light, the sun or moon, `angle` its apparent diameter in degrees.
struct HdAkariDistantData
{
  SdfPath id;
  GfMatrix4d transform = GfMatrix4d(1.0);
  float colorR = 1.0f;
  float colorG = 1.0f;
  float colorB = 1.0f;
  float intensity = 1.0f;
  float exposure = 0.0f;
  float angle = 0.53f;
  bool visible = true;
};

/// A light probe authored as a gprim with `primvars:akari:lightProbe`
/// ("volume" or "sphere"), its local bounds from `transform` give the extent.
/// Volumes may set `primvars:akari:lightProbeResolution` (int3) probe counts.
struct HdAkariLightProbeData
{
  SdfPath id;
  GfMatrix4d transform = GfMatrix4d(1.0);
  float minX = -1.0f, minY = -1.0f, minZ = -1.0f;
  float maxX = 1.0f, maxY = 1.0f, maxZ = 1.0f;
  bool isSphere = false;
  bool visible = true;
  int resolutionX = 0, resolutionY = 0, resolutionZ = 0; // 0 = auto
};

/// A planet with an atmosphere, authored as a sphere with `primvars:akari:atmosphere`.
/// The sphere's `radius` and `transform` place the ground, in stage units, every
/// other length is in kilometers and every coefficient per kilometer.
struct HdAkariAtmosphereData
{
  SdfPath id;
  GfMatrix4d transform = GfMatrix4d(1.0);
  double radius = 6360000.0;
  float thickness = 100.0f;
  float rayleighR = 0.005802f, rayleighG = 0.013558f, rayleighB = 0.0331f;
  float rayleighScaleHeight = 8.0f;
  float mieR = 0.003996f, mieG = 0.003996f, mieB = 0.003996f;
  float mieAbsorptionR = 0.0044f, mieAbsorptionG = 0.0044f, mieAbsorptionB = 0.0044f;
  float mieScaleHeight = 1.2f;
  float mieAnisotropy = 0.8f;
  float ozoneR = 0.00065f, ozoneG = 0.001881f, ozoneB = 0.000085f;
  float ozoneCenter = 25.0f;
  float ozoneWidth = 30.0f;
  float groundAlbedoR = 0.3f, groundAlbedoG = 0.3f, groundAlbedoB = 0.3f;
  std::string groundTexture;
  std::string nightTexture;
  float nightIntensity = 1.0f;
  float aerialPerspectiveDistance = 128.0f;
  float skyIntensity = 1.0f;
  // the procedural planet, `primvars:akari:planet`, in place of the ground albedo or textures.
  bool planet = false;
  float planetSeed = 0.0f;
  float seaLevel = 0.62f;
  float continentScale = 2.0f;
  float mountainHeight = 5.0f;
  float vegetation = 0.7f;
  float desert = 0.5f;
  float iceCaps = 0.5f;
  float oceanR = 0.004f, oceanG = 0.016f, oceanB = 0.035f;
  float oceanRoughness = 0.2f;
  float cloudCoverage = 0.45f;
  float cloudAltitude = 6.0f;
  float cloudRotation = 0.0f;
  float cloudEvolution = 0.0f;
  float cloudOpacity = 0.95f;
  float cloudScale = 1.0f;
  float cloudThickness = 4.0f; // km, the slab the clouds fill above cloudAltitude.
  // the surface palette, negative where unauthored (the built in colors then).
  float landColorLow[3] = {-1.0f, -1.0f, -1.0f};
  float landColorHigh[3] = {-1.0f, -1.0f, -1.0f};
  float forestColor[3] = {-1.0f, -1.0f, -1.0f};
  float desertColor[3] = {-1.0f, -1.0f, -1.0f};
  float shallowColor[3] = {-1.0f, -1.0f, -1.0f};
  float rockColor[3] = {-1.0f, -1.0f, -1.0f};
  float snowColor[3] = {-1.0f, -1.0f, -1.0f};
  float bloomColor[3] = {-1.0f, -1.0f, -1.0f};
  float bloomAmount = 0.0f;
  float cityIntensity = 0.02f;
  float cityDensity = 0.5f;
  float cloudSwirl = 0.0f; // feeds the cloud noise back into itself
  float detail = 0.0f; // fine speckle across the ground
  float cloudSoftness = 0.0f; // 1 drops the billowed edges for soft, round weather
  float cloudShading = 0.0f; // wrap lit tops and dark undersides
  float waves = 0.0f;
  float waveTime = 0.0f; // seconds
  // an art directed halo, fill and rim (after McGuire's Tiny Planet), all off by default.
  float haloIntensity = 0.0f;
  float haloColor[3] = {0.45f, 0.72f, 1.0f};
  float haloRadius = 0.25f; // of the planet's radius
  float haloStreaks = 0.15f;
  float haloShadow = 0.75f;
  float fillIntensity = 0.0f;
  float fillColor[3] = {0.55f, 0.65f, 1.0f};
  float rimIntensity = 0.0f; // how far (0-1) the limb dissolves into rimColor
  float rimColor[3] = {0.6f, 0.8f, 1.0f};
  bool visible = true;
};

/// A `UsdVolVolume`'s density field and how it scatters, `primvars:akari:volume:*` on the volume.
struct HdAkariVolumeData
{
  SdfPath id;
  GfMatrix4d transform = GfMatrix4d(1.0);
  SdfPath densityField;
  std::string densityFile;
  std::string densityName;
  float densityScale = 1.0f;
  float albedoR = 1.0f, albedoG = 1.0f, albedoB = 1.0f;
  float anisotropy = 0.8f;
  float maxResolution = 512.0f;
  bool visible = true;
};

/// An `OpenVDBAsset` field, `filePath` resolved.
struct HdAkariFieldData
{
  SdfPath id;
  std::string filePath;
  std::string fieldName;
};

/// How a stylized mesh is drawn, `primvars:akari:*` on the mesh:
/// `shadingModel` 0 wireframe, 1 flat, 2 Gouraud, 3 Phong, 4 radiosity / Whitted, 5 full (fractions blend),
/// an `shadingModelFront` sphere (center, radius) inside which the mesh is at `shadingModel` and outside one
/// shadingModel behind, `color` (1 color, 0 luminance), `unlit` (black outside the front) and `assemble` (0
/// collapsed into one triangle, 1 whole).
struct HdAkariStyleData
{
  int32_t primId = -1;
  float shadingModel = 5.0f;
  float color = 1.0f;
  float unlit = 0.0f;
  float assemble = 1.0f;
  float frontX = 0.0f, frontY = 0.0f, frontZ = 0.0f, frontRadius = -1.0f;
  float frontBand = 0.04f;
  float frontGlowR = 1.0f, frontGlowG = 0.8f, frontGlowB = 0.55f, frontGlow = 2.0f;
  float wireR = 0.3f, wireG = 1.0f, wireB = 0.45f, wireGlow = 4.0f;
  float wireSpacing = 0.0f;
  float centerX = 0.0f, centerY = 0.0f, centerZ = 0.0f;
  bool hasCenter = false;
  float size = 0.4f;
};

/// The meshes Hydra touched since the last drain, the ones still
/// visible, and the path keys of the ones removed or hidden.
struct HdAkariMeshChanges
{
  std::vector<HdAkariMeshData> updated;
  std::vector<uint64_t> removed;
};

PXR_NAMESPACE_CLOSE_SCOPE

#endif // HDAKARI_SCENE_DATA_H
