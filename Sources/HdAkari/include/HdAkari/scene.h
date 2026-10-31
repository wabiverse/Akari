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
#ifndef HDAKARI_SCENE_H
#define HDAKARI_SCENE_H

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
#include <iterator>
#include <cmath>
#include <cstdint>
#include <cstring>

#include <mutex>
#include <string>
#include <atomic>
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

/// Copies `points` into `dst`, three floats each, and writes their bounds
/// (min xyz, max xyz) to `bounds`, for the GPU deformer's per frame upload.
inline void HdAkariCopyPoints(VtVec3fArray const &points, float *dst, float *bounds)
{
  const size_t n = points.size();
  float lo[3] = {3.4e38f, 3.4e38f, 3.4e38f}, hi[3] = {-3.4e38f, -3.4e38f, -3.4e38f};
  if (n > 0) {
    const float *src = points.cdata()->data();
    std::memcpy(dst, src, n * 3 * sizeof(float));
    for (size_t i = 0; i < n * 3; i += 3) {
      for (int k = 0; k < 3; ++k) {
        lo[k] = src[i + k] < lo[k] ? src[i + k] : lo[k];
        hi[k] = src[i + k] > hi[k] ? src[i + k] : hi[k];
      }
    }
  }
  for (int k = 0; k < 3; ++k) { bounds[k] = lo[k]; bounds[3 + k] = hi[k]; }
}

/// Writes `points`' bounds in their own space (min xyz, max xyz), zero when empty.
inline void HdAkariPointsBounds(VtVec3fArray const &points, float *bounds)
{
  GfVec3f lo(3.4e38f), hi(-3.4e38f);
  for (GfVec3f const &p : points) {
    for (int k = 0; k < 3; ++k) { lo[k] = std::min(lo[k], p[k]); hi[k] = std::max(hi[k], p[k]); }
  }
  if (points.empty()) lo = hi = GfVec3f(0.0f);
  for (int k = 0; k < 3; ++k) { bounds[k] = lo[k]; bounds[3 + k] = hi[k]; }
}

/// Up to `count` of `points`, evenly strided, as xyz into `out`, returns how many.
inline size_t HdAkariPointsSample(VtVec3fArray const &points, float *out, size_t count)
{
  size_t n = std::min(count, points.size()), stride = n ? points.size() / n : 1;
  for (size_t i = 0; i < n; ++i) {
    GfVec3f const &p = points[i * stride];
    out[i * 3] = p[0]; out[i * 3 + 1] = p[1]; out[i * 3 + 2] = p[2];
  }
  return n;
}

/// Simplifies a mesh to about `targetTriangles` by clustering its points on a
/// grid, for a level of detail no finer than the screen it covers.
inline bool HdAkariDecimate(VtVec3fArray const &points, VtVec3iArray const &tris, VtVec2fArray const &uvs,
                            size_t targetTriangles,
                            VtVec3fArray &outPoints, VtVec3iArray &outTris, VtVec2fArray &outUvs)
{
  const bool cornerUvs = uvs.size() == tris.size() * 3;
  if (tris.size() <= targetTriangles || points.empty()) return false;
  GfVec3f lo(3.4e38f), hi(-3.4e38f);
  for (GfVec3f const &p : points) {
    for (int k = 0; k < 3; ++k) { lo[k] = std::min(lo[k], p[k]); hi[k] = std::max(hi[k], p[k]); }
  }
  const GfVec3f size = hi - lo;
  // a surface's points fill a grid's cells by area, so the cell edge goes with the square root.
  double cell = std::max(double(size.GetLength()), 1e-12) / std::sqrt(std::max<double>(double(targetTriangles) * 0.5, 1.0));

  std::vector<int32_t> remap(points.size());
  for (int attempt = 0; attempt < 6; ++attempt, cell *= 1.4) {
    std::unordered_map<uint64_t, int32_t> cells;
    cells.reserve(std::min(points.size(), targetTriangles));
    std::vector<GfVec3d> sums;
    std::vector<int32_t> counts;
    for (size_t i = 0; i < points.size(); ++i) {
      uint64_t key = 0;
      for (int k = 0; k < 3; ++k) {
        key = key * 2097152ull + uint64_t(std::min(2097151.0, std::max(0.0, (points[i][k] - lo[k]) / cell)));
      }
      auto [it, inserted] = cells.try_emplace(key, int32_t(sums.size()));
      if (inserted) { sums.emplace_back(0.0); counts.push_back(0); }
      sums[it->second] += GfVec3d(points[i]);
      counts[it->second] += 1;
      remap[i] = it->second;
    }
    VtVec3iArray merged;
    VtVec2fArray mergedUvs;
    merged.reserve(std::min(tris.size(), targetTriangles * 2));
    for (size_t i = 0; i < tris.size(); ++i) {
      GfVec3i const &t = tris[i];
      if (t[0] < 0 || t[1] < 0 || t[2] < 0 || size_t(std::max({t[0], t[1], t[2]})) >= points.size()) continue;
      const GfVec3i m(remap[t[0]], remap[t[1]], remap[t[2]]);
      if (m[0] == m[1] || m[1] == m[2] || m[2] == m[0]) continue;
      merged.push_back(m);
      if (cornerUvs) {
        for (int c = 0; c < 3; ++c) mergedUvs.push_back(uvs[i * 3 + c]);
      }
    }
    if (merged.size() > targetTriangles * 3 / 2 && attempt < 5) continue;
    VtVec3fArray centers(sums.size());
    for (size_t c = 0; c < sums.size(); ++c) centers[c] = GfVec3f(sums[c] / double(counts[c]));
    outPoints = std::move(centers);
    outTris = std::move(merged);
    outUvs = cornerUvs ? std::move(mergedUvs) : uvs;
    return !outTris.empty();
  }
  return false;
}

/// Each drawn triangle's streamed Ptex face, `sources` naming its triangle
/// in `triangleFaces` as Akari's build does: the face in the low 18 bits,
/// its corners places on it two bits apiece above, then the face's ulog2
/// and vlog2 from `faceRes`. All ones where it has none.
inline void HdAkariPtexTriangleEntries(VtIntArray const &triangleFaces, VtIntArray const &faceRes,
                                       int32_t const *sources, size_t count, uint32_t *out)
{
  int const *faces = triangleFaces.cdata();
  int const *res = faceRes.cdata();
  for (size_t i = 0; i < count; ++i) {
    const size_t t = size_t(sources[i] & 0x7FFFFFFF);
    uint32_t entry = 0xFFFFFFFFu;
    if (t < triangleFaces.size()) {
      const uint32_t packed = uint32_t(faces[t]);
      const uint32_t face = packed & 0xFFFFFFu;
      uint32_t code = (packed >> 24) & 63u;
      if (sources[i] < 0) code = (code & 3u) | ((code >> 4) & 3u) << 2 | ((code >> 2) & 3u) << 4;
      if (face < (1u << 18) && face < faceRes.size()) entry = face | code << 18 | (uint32_t(res[face]) & 0xFFu) << 24;
    }
    out[i] = entry;
  }
}

/// Copies `points` into `dst`, three floats each, without computing bounds.
inline void HdAkariCopyPointsFlat(VtVec3fArray const &points, float *dst)
{
  const size_t n = points.size();
  if (n > 0) std::memcpy(dst, points.cdata()->data(), n * 3 * sizeof(float));
}

/// Copies triangle corners into `dst`, three ints each.
inline void HdAkariCopyTriangles(VtVec3iArray const &tris, int32_t *dst)
{
  const size_t n = tris.size();
  if (n > 0) std::memcpy(dst, tris.cdata()->data(), n * 3 * sizeof(int32_t));
}

/// Copies `uvs` into `dst`, two floats per triangle corner. A constant uv
/// arrives as one value and repeats across every corner.
inline void HdAkariCopyUVs(VtVec2fArray const &uvs, float *dst, size_t corners)
{
  const size_t n = uvs.size();
  if (n == 1) {
    const float u = uvs[0][0], v = uvs[0][1];
    for (size_t i = 0; i < corners; ++i) {
      dst[i * 2 + 0] = u;
      dst[i * 2 + 1] = v;
    }
  } else if (n > 0) {
    std::memcpy(dst, uvs.cdata()->data(), std::min(n, corners) * 2 * sizeof(float));
  }
}

/// Writes each instance's matrix as 16 floats, row-major like
/// `GfMatrix4f::GetArray`, which the renderer reads as a column-major
/// transform.
inline void HdAkariCopyInstances(HdAkariMeshData const &mesh, float *dst)
{
  const size_t n = mesh.instances.size();
  if (n > 0) std::memcpy(dst, mesh.instances.cdata()->GetArray(), n * 16 * sizeof(float));
}

/// The joints of a GPU skinned mesh, zero when its points arrive already skinned.
inline size_t HdAkariSkinJointCount(HdAkariMeshData const &mesh)
{
  return mesh.skinInfluencesPerPoint > 0 ? mesh.skinXforms.size() : 0;
}

/// Writes each joint's matrix as the three rows a column vector multiply
/// reads, twelve floats each, and the local bounds (min xyz, max xyz),
/// for the GPU skinning's per frame upload.
inline void HdAkariCopySkin(HdAkariMeshData const &mesh, float *palette, float *bounds)
{
  const size_t n = HdAkariSkinJointCount(mesh);
  for (size_t j = 0; j < n; ++j) {
    const float *m = mesh.skinXforms.cdata()[j].data();
    for (int r = 0; r < 3; ++r) {
      for (int c = 0; c < 4; ++c) palette[j * 12 + r * 4 + c] = m[c * 4 + r];
    }
  }
  for (int k = 0; k < 3; ++k) { bounds[k] = mesh.skinMin[k]; bounds[3 + k] = mesh.skinMax[k]; }
}

/// A path's hash, the per frame identity of a mesh without its string.
inline uint64_t HdAkariPathKey(SdfPath const &path)
{
  return static_cast<uint64_t>(path.GetHash());
}

/// Whether two triangulations and their uvs are the same.
inline bool HdAkariSameTopology(VtVec3iArray const &tris, VtVec3iArray const &otherTris,
                                VtVec2fArray const &uvs, VtVec2fArray const &otherUvs)
{
  return tris == otherTris && uvs == otherUvs;
}

/// Hashes raw bytes eight at a time, for content hashing reusable prototype geometry.
inline uint64_t HdAkariHashBytes(uint64_t hash, void const *bytes, size_t count)
{
  auto const *p = static_cast<unsigned char const *>(bytes);
  size_t i = 0;
  for (; i + 8 <= count; i += 8) {
    uint64_t word;
    std::memcpy(&word, p + i, 8);
    hash = (hash ^ word) * 0x9E3779B97F4A7C15ull;
    hash ^= hash >> 29;
  }
  for (; i < count; ++i) {
    hash ^= p[i];
    hash *= 1099511628211ull;
  }
  return hash;
}

/// Bins `mesh`'s arrays by content, so equal ones across every mesh share one copy.
HDAKARI_API void HdAkariInternMeshArrays(HdAkariMeshData &mesh);

/// Ages the bins once a sync pass, dropping what no mesh has asked for in a few.
HDAKARI_API void HdAkariPruneArrayBins();

/// A stable key over a prototype's object space geometry and material. Two
/// Rprims with the same key and transform can share one GPU instanced draw:
/// their points, triangles, uvs and material are identical.
inline uint64_t HdAkariMeshContentKey(HdAkariMeshData const &mesh)
{
  uint64_t hash = 1469598103934665603ull;
  if (!mesh.points.empty()) {
    hash = HdAkariHashBytes(hash, mesh.points.data(), mesh.points.size() * sizeof(GfVec3f));
  }
  if (!mesh.triangleIndices.empty()) {
    hash = HdAkariHashBytes(hash, mesh.triangleIndices.data(),
                            mesh.triangleIndices.size() * sizeof(GfVec3i));
  }
  if (!mesh.uvs.empty()) {
    hash = HdAkariHashBytes(hash, mesh.uvs.data(), mesh.uvs.size() * sizeof(GfVec2f));
  }
  hash = HdAkariHashBytes(hash, &mesh.ptexMap, sizeof(int));
  hash = HdAkariHashBytes(hash, &mesh.displayColor, sizeof(GfVec3f));
  hash = HdAkariHashBytes(hash, &mesh.opacity, sizeof(float));
  hash = HdAkariHashBytes(hash, &mesh.roughness, sizeof(float));
  hash = HdAkariHashBytes(hash, &mesh.metallic, sizeof(float));
  const uint8_t flags = uint8_t(mesh.transparent ? 1 : 0)
    | uint8_t(mesh.emitter ? 2 : 0)
    | uint8_t(mesh.transform.GetDeterminant() < 0.0 ? 4 : 0)
    | uint8_t(mesh.smooth ? 8 : 0);
  hash = HdAkariHashBytes(hash, &flags, sizeof(flags));
  return hash ? hash : 1;
}

/// @class HdAkariScene
///
/// Thread safe registry of the meshes and lights the delegate has synced.
///
/// `HdAkariMesh` and `HdAkariLight` write into it (Sync runs on worker
/// threads), the render pass reads a snapshot to draw. One per render
/// delegate from the render param.
///
/// The meshes Hydra touched since the last drain, the ones still
/// visible, and the path keys of the ones removed or hidden.
struct HdAkariMeshChanges
{
  std::vector<HdAkariMeshData> updated;
  std::vector<uint64_t> removed;
};

class SWIFT_SHARED_REFERENCE(HdAkariSceneRetain, HdAkariSceneRelease)
HdAkariScene
{
public:
  void UpdateMesh(HdAkariMeshData data)
  {
    HdAkariInternMeshArrays(data);
    std::lock_guard<std::mutex> lock(_mutex);
    auto it = _meshes.find(data.id);
    bool geometryChanged = (it == _meshes.end())
                        || (data.dataRevision != it->second.dataRevision);
    _dirtyMeshes.insert(data.id);
    _meshes[data.id] = std::move(data);
    if (geometryChanged) {
      _revision.fetch_add(1, std::memory_order_relaxed);
    }
  }

  /// Update only display properties (transform, color, opacity, roughness,
  /// metallic, visibility) on an existing mesh without touching geometry or
  /// bumping the scene revision, avoids copying points/indices entirely.
  void UpdateMeshDisplay(SdfPath const &id,
                         GfMatrix4d const &xf,
                         GfVec3f const &color,
                         float opacity,
                         float roughness,
                         float metallic,
                         bool visible)
  {
    std::lock_guard<std::mutex> lock(_mutex);
    auto it = _meshes.find(id);
    if (it == _meshes.end()) return;
    auto &m = it->second;
    const bool changed = m.transform != xf || m.displayColor != color || m.opacity != opacity ||
                         m.roughness != roughness || m.metallic != metallic || m.visible != visible;
    m.transform = xf;
    m.displayColor = color;
    m.opacity = opacity;
    m.roughness = roughness;
    m.metallic = metallic;
    m.visible = visible;
    if (changed) {
      _dirtyMeshes.insert(id);
      _revision.fetch_add(1, std::memory_order_relaxed);
    }
  }

  /// Move or show/hide an existing mesh, keeping everything else.
  /// False when the mesh isn't stored yet.
  bool UpdateMeshTransform(SdfPath const &id, GfMatrix4d const &xf, bool visible)
  {
    std::lock_guard<std::mutex> lock(_mutex);
    auto it = _meshes.find(id);
    if (it == _meshes.end()) return false;
    auto &m = it->second;
    if (m.transform != xf || m.visible != visible) {
      m.transform = xf;
      m.visible = visible;
      _dirtyMeshes.insert(id);
      _revision.fetch_add(1, std::memory_order_relaxed);
    }
    return true;
  }

  /// Swap in new points on an existing mesh, keeping its triangles, uvs
  /// and material. False when the mesh isn't stored yet.
  bool UpdateMeshPoints(SdfPath const &id,
                        VtVec3fArray const &points,
                        GfMatrix4d const &xf,
                        bool visible,
                        uint64_t dataRevision)
  {
    std::lock_guard<std::mutex> lock(_mutex);
    auto it = _meshes.find(id);
    if (it == _meshes.end()) return false;
    auto &m = it->second;
    m.points = points;
    m.transform = xf;
    m.visible = visible;
    m.dataRevision = dataRevision;
    _dirtyMeshes.insert(id);
    _revision.fetch_add(1, std::memory_order_relaxed);

    return true;
  }

  /// Swap in this frame's joint matrices and bounds on an existing GPU skinned
  /// mesh, keeping its rest points and influences. False when it isn't stored yet.
  bool UpdateMeshSkin(SdfPath const &id,
                      VtMatrix4fArray const &xforms,
                      GfVec3f const &lo,
                      GfVec3f const &hi,
                      GfMatrix4d const &xf,
                      bool visible,
                      uint64_t dataRevision)
  {
    std::lock_guard<std::mutex> lock(_mutex);
    auto it = _meshes.find(id);
    if (it == _meshes.end() || it->second.skinInfluencesPerPoint == 0) return false;
    auto &m = it->second;
    m.skinXforms = xforms;
    m.skinMin = lo;
    m.skinMax = hi;
    m.transform = xf;
    m.visible = visible;
    m.dataRevision = dataRevision;
    _dirtyMeshes.insert(id);
    _revision.fetch_add(1, std::memory_order_relaxed);

    return true;
  }

  /// Copy only the geometry (points + indices) from a previously stored
  /// mesh, used by Sync when only transform/color/visibility changed.
  bool CopyMeshGeometry(SdfPath const &id, HdAkariMeshData &dst) const
  {
    std::lock_guard<std::mutex> lock(_mutex);
    auto it = _meshes.find(id);
    if (it == _meshes.end()) return false;
    dst.points = it->second.points;
    dst.triangleIndices = it->second.triangleIndices;
    dst.uvs = it->second.uvs;
    return true;
  }

  void RemoveMesh(SdfPath const &id)
  {
    std::lock_guard<std::mutex> lock(_mutex);
    if (_meshes.erase(id) > 0) {
      _dirtyMeshes.insert(id);
      _revision.fetch_add(1, std::memory_order_relaxed);
    }
  }

  size_t MeshCount() const
  {
    std::lock_guard<std::mutex> lock(_mutex);
    return _meshes.size();
  }

  size_t TriangleCount() const
  {
    std::lock_guard<std::mutex> lock(_mutex);
    size_t n = 0;
    for (auto const &kv : _meshes) {
      n += kv.second.TriangleCount();
    }
    return n;
  }

  /// Copy out the current visible meshes for a
  /// frame (drawing must not hold the lock while
  /// it touches the GPU).
  std::vector<HdAkariMeshData> Snapshot() const
  {
    std::lock_guard<std::mutex> lock(_mutex);
    std::vector<HdAkariMeshData> out;
    out.reserve(_meshes.size());
    for (auto const &kv : _meshes) {
      if (kv.second.visible) {
        out.push_back(kv.second);
      }
    }
    return out;
  }

  /// Takes the meshes changed since the last call, so a
  /// frame copies what moved instead of the whole scene.
  HdAkariMeshChanges DrainMeshChanges()
  {
    std::lock_guard<std::mutex> lock(_mutex);
    HdAkariMeshChanges out;
    out.updated.reserve(_dirtyMeshes.size());
    for (SdfPath const &id : _dirtyMeshes) {
      auto it = _meshes.find(id);
      if (it != _meshes.end() && it->second.visible) {
        out.updated.push_back(it->second);
      } else {
        out.removed.push_back(HdAkariPathKey(id));
      }
    }
    _dirtyMeshes.clear();
    return out;
  }

  /// Monotonically increasing counter, bumped on
  /// every UpdateMesh/RemoveMesh. The render side
  /// caches this value to skip capture rerecording
  /// when the scene geometry has not changed.
  uint64_t Revision() const
  {
    return _revision.load(std::memory_order_relaxed);
  }

  void UpdateLight(HdAkariLightData data)
  {
    std::lock_guard<std::mutex> lock(_mutex);
    _lights[data.id] = std::move(data);
    _lightRevision.fetch_add(1, std::memory_order_relaxed);
  }

  void RemoveLight(SdfPath const &id)
  {
    std::lock_guard<std::mutex> lock(_mutex);
    _lights.erase(id);
    _lightRevision.fetch_add(1, std::memory_order_relaxed);
  }

  size_t LightCount() const
  {
    std::lock_guard<std::mutex> lock(_mutex);
    return _lights.size();
  }

  /// Copy out the current visible lights for a frame, same shape as Snapshot() for meshes.
  std::vector<HdAkariLightData> LightSnapshot() const
  {
    std::lock_guard<std::mutex> lock(_mutex);
    std::vector<HdAkariLightData> out;
    out.reserve(_lights.size());
    for (auto const &kv : _lights)
    {
      if (kv.second.visible)
      {
        out.push_back(kv.second);
      }
    }
    return out;
  }

  /// Monotonically increasing counter, bumped on every UpdateLight/RemoveLight.
  uint64_t LightRevision() const
  {
    return _lightRevision.load(std::memory_order_relaxed);
  }

  void UpdateDome(HdAkariDomeData data)
  {
    std::lock_guard<std::mutex> lock(_mutex);
    _domes[data.id] = std::move(data);
    _domeRevision.fetch_add(1, std::memory_order_relaxed);
  }

  void RemoveDome(SdfPath const &id)
  {
    std::lock_guard<std::mutex> lock(_mutex);
    if (_domes.erase(id) > 0) {
      _domeRevision.fetch_add(1, std::memory_order_relaxed);
    }
  }

  /// The brightest visible dome, so a cross fade hands over to the one fading in, false when there is none.
  bool DomeSnapshot(HdAkariDomeData &out) const
  {
    std::lock_guard<std::mutex> lock(_mutex);
    float best = -1.0f;
    for (auto const &kv : _domes) {
      HdAkariDomeData const &d = kv.second;
      const size_t dot = d.textureFile.rfind('.');
      const std::string ext = dot == std::string::npos ? std::string() : TfStringToLower(d.textureFile.substr(dot + 1));
      const bool hdr = ext == "exr" || ext == "hdr" || ext == "tx";
      const float level = (hdr ? 1e6f : 0.0f) + d.intensity * std::exp2(d.exposure) * std::max({d.colorR, d.colorG, d.colorB});
      if (d.visible && level > best) { out = d; best = level; }
    }
    return best >= 0.0f;
  }

  void UpdateDistant(HdAkariDistantData data)
  {
    std::lock_guard<std::mutex> lock(_mutex);
    _distants[data.id] = std::move(data);
  }

  void RemoveDistant(SdfPath const &id)
  {
    std::lock_guard<std::mutex> lock(_mutex);
    _distants.erase(id);
  }

  /// The brightest visible distant light, the one that shades as the sun, false when there is none.
  bool DistantSnapshot(HdAkariDistantData &out) const
  {
    std::lock_guard<std::mutex> lock(_mutex);
    float best = -1.0f;
    for (auto const &kv : _distants) {
      HdAkariDistantData const &d = kv.second;
      const float power = d.intensity * std::exp2(d.exposure) * std::max(d.colorR, std::max(d.colorG, d.colorB));
      if (d.visible && power > best) { best = power; out = d; }
    }
    return best >= 0.0f;
  }

  /// Monotonically increasing counter, bumped on every UpdateDome/RemoveDome.
  uint64_t DomeRevision() const
  {
    return _domeRevision.load(std::memory_order_relaxed);
  }

  void UpdateProbe(HdAkariLightProbeData data)
  {
    std::lock_guard<std::mutex> lock(_mutex);
    _probes[data.id] = std::move(data);
    _probeRevision.fetch_add(1, std::memory_order_relaxed);
  }

  /// Keeps the stored bounds when only the transform changed.
  bool CopyProbeBounds(SdfPath const &id, HdAkariLightProbeData &dst) const
  {
    std::lock_guard<std::mutex> lock(_mutex);
    auto it = _probes.find(id);
    if (it == _probes.end()) return false;
    dst.minX = it->second.minX; dst.minY = it->second.minY; dst.minZ = it->second.minZ;
    dst.maxX = it->second.maxX; dst.maxY = it->second.maxY; dst.maxZ = it->second.maxZ;
    return true;
  }

  void RemoveProbe(SdfPath const &id)
  {
    std::lock_guard<std::mutex> lock(_mutex);
    if (_probes.erase(id) > 0) {
      _probeRevision.fetch_add(1, std::memory_order_relaxed);
    }
  }

  std::vector<HdAkariLightProbeData> ProbeSnapshot() const
  {
    std::lock_guard<std::mutex> lock(_mutex);
    std::vector<HdAkariLightProbeData> out;
    out.reserve(_probes.size());
    for (auto const &kv : _probes) {
      if (kv.second.visible) out.push_back(kv.second);
    }
    return out;
  }

  /// Monotonically increasing counter, bumped on every UpdateProbe/RemoveProbe.
  uint64_t ProbeRevision() const
  {
    return _probeRevision.load(std::memory_order_relaxed);
  }

  void UpdateAtmosphere(HdAkariAtmosphereData data)
  {
    std::lock_guard<std::mutex> lock(_mutex);
    _atmospheres[data.id] = std::move(data);
    _atmosphereRevision.fetch_add(1, std::memory_order_relaxed);
  }

  void RemoveAtmosphere(SdfPath const &id)
  {
    std::lock_guard<std::mutex> lock(_mutex);
    if (_atmospheres.erase(id) > 0) {
      _atmosphereRevision.fetch_add(1, std::memory_order_relaxed);
    }
  }

  /// The first visible planet, false when there is none.
  bool AtmosphereSnapshot(HdAkariAtmosphereData &out) const
  {
    std::lock_guard<std::mutex> lock(_mutex);
    for (auto const &kv : _atmospheres) {
      if (kv.second.visible) { out = kv.second; return true; }
    }
    return false;
  }

  /// Monotonically increasing counter, bumped on every UpdateAtmosphere/RemoveAtmosphere.
  uint64_t AtmosphereRevision() const
  {
    return _atmosphereRevision.load(std::memory_order_relaxed);
  }

  void UpdateVolume(HdAkariVolumeData data)
  {
    std::lock_guard<std::mutex> lock(_mutex);
    _volumes[data.id] = std::move(data);
    _volumeRevision.fetch_add(1, std::memory_order_relaxed);
  }

  void RemoveVolume(SdfPath const &id)
  {
    std::lock_guard<std::mutex> lock(_mutex);
    if (_volumes.erase(id) > 0) _volumeRevision.fetch_add(1, std::memory_order_relaxed);
  }

  void UpdateField(HdAkariFieldData data)
  {
    std::lock_guard<std::mutex> lock(_mutex);
    _fields[data.id] = std::move(data);
    _volumeRevision.fetch_add(1, std::memory_order_relaxed);
  }

  void RemoveField(SdfPath const &id)
  {
    std::lock_guard<std::mutex> lock(_mutex);
    if (_fields.erase(id) > 0) _volumeRevision.fetch_add(1, std::memory_order_relaxed);
  }

  /// The visible volumes, each with its density field's file resolved.
  std::vector<HdAkariVolumeData> VolumeSnapshot() const
  {
    std::lock_guard<std::mutex> lock(_mutex);
    std::vector<HdAkariVolumeData> out;
    for (auto const &kv : _volumes) {
      if (!kv.second.visible) continue;
      HdAkariVolumeData v = kv.second;
      auto it = _fields.find(v.densityField);
      if (it == _fields.end() || it->second.filePath.empty()) continue;
      v.densityFile = it->second.filePath;
      if (!it->second.fieldName.empty()) v.densityName = it->second.fieldName;
      out.push_back(std::move(v));
    }
    return out;
  }

  /// Monotonically increasing counter, bumped on every volume or field change.
  uint64_t VolumeRevision() const
  {
    return _volumeRevision.load(std::memory_order_relaxed);
  }

  void UpdateStyle(HdAkariStyleData data)
  {
    std::lock_guard<std::mutex> lock(_mutex);
    auto it = _styles.find(data.primId);
    if (it != _styles.end()) {
      HdAkariStyleData const &a = it->second;
      const float x[] = {a.shadingModel, a.color, a.unlit, a.assemble, a.frontX, a.frontY, a.frontZ, a.frontRadius, a.frontBand,
                         a.frontGlowR, a.frontGlowG, a.frontGlowB, a.frontGlow, a.wireR, a.wireG, a.wireB, a.wireGlow,
                         a.centerX, a.centerY, a.centerZ, a.size, a.hasCenter ? 1.0f : 0.0f, a.wireSpacing};
      const float y[] = {data.shadingModel, data.color, data.unlit, data.assemble, data.frontX, data.frontY, data.frontZ,
                         data.frontRadius, data.frontBand, data.frontGlowR, data.frontGlowG, data.frontGlowB,
                         data.frontGlow, data.wireR, data.wireG, data.wireB, data.wireGlow,
                         data.centerX, data.centerY, data.centerZ, data.size, data.hasCenter ? 1.0f : 0.0f,
                         data.wireSpacing};
      if (std::equal(std::begin(x), std::end(x), std::begin(y))) return;
    }
    _styles[data.primId] = data;
    _styleRevision.fetch_add(1, std::memory_order_relaxed);
  }

  void RemoveStyle(int32_t primId)
  {
    std::lock_guard<std::mutex> lock(_mutex);
    if (_styles.erase(primId) > 0) _styleRevision.fetch_add(1, std::memory_order_relaxed);
  }

  std::vector<HdAkariStyleData> StyleSnapshot() const
  {
    std::lock_guard<std::mutex> lock(_mutex);
    std::vector<HdAkariStyleData> out;
    out.reserve(_styles.size());
    for (auto const &kv : _styles) out.push_back(kv.second);
    return out;
  }

  /// Monotonically increasing counter, bumped on every UpdateStyle/RemoveStyle.
  uint64_t StyleRevision() const
  {
    return _styleRevision.load(std::memory_order_relaxed);
  }

private:
  mutable std::mutex _mutex;
  std::unordered_map<SdfPath, HdAkariMeshData, SdfPath::Hash> _meshes;
  std::unordered_set<SdfPath, SdfPath::Hash> _dirtyMeshes;
  std::atomic<uint64_t> _revision{0};
  std::unordered_map<SdfPath, HdAkariLightData, SdfPath::Hash> _lights;
  std::atomic<uint64_t> _lightRevision{0};
  std::unordered_map<SdfPath, HdAkariLightProbeData, SdfPath::Hash> _probes;
  std::atomic<uint64_t> _probeRevision{0};
  std::unordered_map<SdfPath, HdAkariDomeData, SdfPath::Hash> _domes;
  std::atomic<uint64_t> _domeRevision{0};
  std::unordered_map<SdfPath, HdAkariDistantData, SdfPath::Hash> _distants;
  std::unordered_map<SdfPath, HdAkariAtmosphereData, SdfPath::Hash> _atmospheres;
  std::atomic<uint64_t> _atmosphereRevision{0};
  std::unordered_map<SdfPath, HdAkariVolumeData, SdfPath::Hash> _volumes;
  std::unordered_map<SdfPath, HdAkariFieldData, SdfPath::Hash> _fields;
  std::atomic<uint64_t> _volumeRevision{0};
  std::unordered_map<int32_t, HdAkariStyleData> _styles;
  std::atomic<uint64_t> _styleRevision{0};
};

PXR_NAMESPACE_CLOSE_SCOPE

inline void HdAkariSceneRetain(PXR_INTERNAL_NS::HdAkariScene *scene)
{
  PXR_INTERNAL_NS::Tf_SharedPtrRetainReleaseHelper<PXR_INTERNAL_NS::HdAkariScene>::Retain(scene);
}

inline void HdAkariSceneRelease(PXR_INTERNAL_NS::HdAkariScene *scene)
{
  PXR_INTERNAL_NS::Tf_SharedPtrRetainReleaseHelper<PXR_INTERNAL_NS::HdAkariScene>::Release(scene);
}

#endif // HDAKARI_SCENE_H
