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

#include <pxr/pxrns.h>
#include <Sdf/path.h>
#include <Gf/matrix4d.h>
#include <Gf/vec2f.h>
#include <Gf/vec3f.h>
#include <Gf/vec3i.h>
#include <Vt/array.h>
#include <Vt/types.h>

#include <Arch/swiftInterop.h>
#include <Tf/sharedPtrRetainReleaseHelper.h>

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
  GfVec3f extentMin = GfVec3f(0.0f); // object-space bounds, for frustum culling.
  GfVec3f extentMax = GfVec3f(0.0f);
  GfVec3f displayColor = GfVec3f(0.8f, 0.8f, 0.8f);
  float opacity = 1.0f;   // from the bound material's UsdPreviewSurface.
  float roughness = 0.5f; // UsdPreviewSurface's own default.
  float metallic = 0.0f;  // UsdPreviewSurface's own default.
  bool visible = true;
  uint64_t dataRevision = 0; // incremented each Sync, GPU cache keys off this.

  size_t TriangleCount() const { return triangleIndices.size(); }
};


/// @class HdAkariScene
///
/// Thread safe registry of the meshes the delegate has synced.
///
/// `HdAkariMesh` writes into it (Sync runs on worker threads),
/// the render pass reads a snapshot to draw. One per render
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
    m.transform = xf;
    m.displayColor = color;
    m.opacity = opacity;
    m.roughness = roughness;
    m.metallic = metallic;
    m.visible = visible;
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
    _meshes.erase(id);
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

  /// Monotonically increasing counter, bumped on
  /// every UpdateMesh/RemoveMesh. The render side
  /// caches this value to skip capture rerecording
  /// when the scene geometry has not changed.
  uint64_t Revision() const
  {
    return _revision.load(std::memory_order_relaxed);
  }

private:
  mutable std::mutex _mutex;
  std::unordered_map<SdfPath, HdAkariMeshData, SdfPath::Hash> _meshes;
  std::atomic<uint64_t> _revision{0};
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
