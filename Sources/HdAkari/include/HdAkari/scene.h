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
#include <Gf/vec3f.h>
#include <Gf/vec3i.h>
#include <Vt/array.h>
#include <Vt/types.h>

#include <Arch/swiftInterop.h>
#include <Tf/sharedPtrRetainReleaseHelper.h>

#include <mutex>
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
  GfMatrix4d transform = GfMatrix4d(1.0);
  GfVec3f displayColor = GfVec3f(0.8f, 0.8f, 0.8f);
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
    _meshes[data.id] = std::move(data);
  }

  void RemoveMesh(SdfPath const &id)
  {
    std::lock_guard<std::mutex> lock(_mutex);
    _meshes.erase(id);
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

private:
  mutable std::mutex _mutex;
  std::unordered_map<SdfPath, HdAkariMeshData, SdfPath::Hash> _meshes;
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
