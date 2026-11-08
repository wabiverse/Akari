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

#include "HdAkari/sceneData.h"
#include "HdAkari/meshUtils.h"

PXR_NAMESPACE_OPEN_SCOPE

/// Thread safe registry of the meshes and lights the delegate has synced.
///
/// `HdAkariMesh` and `HdAkariLight` write into it (Sync runs on worker
/// threads), the render pass reads a snapshot to draw. One per render
/// delegate from the render param.
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

  /// `primId` keeps a prim Hydra finalizes after its replacement synced from taking the new one along.
  void RemoveMesh(SdfPath const &id, int32_t primId = -1)
  {
    std::lock_guard<std::mutex> lock(_mutex);
    auto it = _meshes.find(id);
    if (it == _meshes.end() || (primId >= 0 && it->second.primId >= 0 && it->second.primId != primId)) return;
    _meshes.erase(it);
    _dirtyMeshes.insert(id);
    _revision.fetch_add(1, std::memory_order_relaxed);
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
