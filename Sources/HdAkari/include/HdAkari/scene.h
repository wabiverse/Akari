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
# include <Gf/vec2f.h>
# include <Gf/vec3f.h>
# include <Gf/vec3i.h>
# include <Vt/array.h>
# include <Vt/types.h>
# include <Arch/swiftInterop.h>
# include <Tf/sharedPtrRetainReleaseHelper.h>
#else
# include <pxr/pxr.h>
# include <pxr/usd/sdf/path.h>
# include <pxr/base/gf/matrix4d.h>
# include <pxr/base/gf/vec2f.h>
# include <pxr/base/gf/vec3f.h>
# include <pxr/base/gf/vec3i.h>
# include <pxr/base/vt/array.h>
# include <pxr/base/vt/types.h>
# include <pxr/base/tf/sharedPtrRetainReleaseHelper.h>
#endif

#include "HdAkari/api.h"

#include <cstring>

#include <mutex>
#include <atomic>
#include <unordered_map>

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
  VtVec2fArray uvs;             // atlas space UV, one per triangleIndices corner (see mesh.cpp)
  GfMatrix4d transform = GfMatrix4d(1.0);
  GfVec3f displayColor = GfVec3f(0.8f, 0.8f, 0.8f);
  float opacity = 1.0f;   // from the bound material's UsdPreviewSurface.
  float roughness = 0.5f; // UsdPreviewSurface's own default.
  float metallic = 0.0f;  // UsdPreviewSurface's own default.
  bool visible = true;
  uint64_t dataRevision = 0; // incremented each Sync, GPU cache keys off this.
  uint64_t topologyRevision = 0; // only moves with the triangles and uvs, not the points.
  int32_t primId = -1;       // the Rprim's id, written to the primId AOV for picking.

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
  bool visible = true;
  uint64_t dataRevision = 0;
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
  int resolutionX = 0, resolutionY = 0, resolutionZ = 0; // 0 = auto
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

/// @class HdAkariScene
///
/// Thread safe registry of the meshes and lights the delegate has synced.
///
/// `HdAkariMesh` and `HdAkariLight` write into it (Sync runs on worker
/// threads), the render pass reads a snapshot to draw. One per render
/// delegate from the render param.
///
class SWIFT_SHARED_REFERENCE(HdAkariSceneRetain, HdAkariSceneRelease)
HdAkariScene
{
public:
  void UpdateMesh(HdAkariMeshData data)
  {
    std::lock_guard<std::mutex> lock(_mutex);
    auto it = _meshes.find(data.id);
    bool geometryChanged = (it == _meshes.end())
                        || (data.dataRevision != it->second.dataRevision);
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
      out.push_back(kv.second);
    }
    return out;
  }

  /// Monotonically increasing counter, bumped on every UpdateProbe/RemoveProbe.
  uint64_t ProbeRevision() const
  {
    return _probeRevision.load(std::memory_order_relaxed);
  }

private:
  mutable std::mutex _mutex;
  std::unordered_map<SdfPath, HdAkariMeshData, SdfPath::Hash> _meshes;
  std::atomic<uint64_t> _revision{0};
  std::unordered_map<SdfPath, HdAkariLightData, SdfPath::Hash> _lights;
  std::atomic<uint64_t> _lightRevision{0};
  std::unordered_map<SdfPath, HdAkariLightProbeData, SdfPath::Hash> _probes;
  std::atomic<uint64_t> _probeRevision{0};
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
