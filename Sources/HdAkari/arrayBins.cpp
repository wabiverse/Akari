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
# include <Hd/meshUtil.h>
# include <Vt/value.h>
#else
# include <pxr/pxr.h>
# include <pxr/imaging/hd/meshUtil.h>
# include <pxr/base/vt/value.h>
#endif

#include "HdAkari/scene.h"

#include <array>
#include <atomic>
#include <cstring>
#include <mutex>
#include <unordered_map>

PXR_NAMESPACE_OPEN_SCOPE

namespace {

/// What arrays equal by content bin to, the first one seen holding the memory
/// every later equal one shares. An entry not asked for in a few sync passes
/// goes, the meshes holding its array keep it.
struct Bins
{
  struct Entry
  {
    VtValue array;
    uint64_t used;
  };
  struct Bin
  {
    std::mutex mutex;
    std::unordered_multimap<uint64_t, Entry> entries;
  };
  std::array<Bin, 64> bins;
  std::atomic<uint64_t> pass{0};
  /// Only a pass that synced something ages the bins, an idle frame doesn't.
  std::atomic<bool> touched{false};

  template <class T>
  VtArray<T> Intern(VtArray<T> const &array)
  {
    // a small array costs more to bin than to keep.
    if (array.size() * sizeof(T) < 1024) return array;
    touched.store(true, std::memory_order_relaxed);
    const size_t bytes = array.size() * sizeof(T);
    const uint64_t hash = HdAkariHashBytes(typeid(T).hash_code(), array.cdata(), bytes);
    Bin &bin = bins[hash & 63];
    std::lock_guard<std::mutex> lock(bin.mutex);
    const auto range = bin.entries.equal_range(hash);
    for (auto it = range.first; it != range.second; ++it) {
      if (!it->second.array.IsHolding<VtArray<T>>()) continue;
      VtArray<T> const &held = it->second.array.UncheckedGet<VtArray<T>>();
      if (held.size() != array.size() || std::memcmp(held.cdata(), array.cdata(), bytes) != 0) continue;
      it->second.used = pass.load(std::memory_order_relaxed);
      return held;
    }
    bin.entries.emplace(hash, Entry{VtValue(array), pass.load(std::memory_order_relaxed)});
    return array;
  }

  bool Prune(uint64_t keep)
  {
    if (!touched.exchange(false)) return false;
    const uint64_t now = pass.fetch_add(1) + 1;
    for (Bin &bin : bins) {
      std::lock_guard<std::mutex> lock(bin.mutex);
      for (auto it = bin.entries.begin(); it != bin.entries.end();) {
        it = it->second.used + keep < now ? bin.entries.erase(it) : std::next(it);
      }
    }
    return true;
  }
};

Bins &TheBins()
{
  static Bins *bins = new Bins();
  return *bins;
}

struct Triangulation
{
  VtVec3iArray triangles;
  VtIntArray params;
  uint64_t used;
};

std::mutex triangulationMutex;
std::unordered_map<uint64_t, Triangulation> triangulations;

} // namespace

void HdAkariInternMeshArrays(HdAkariMeshData &mesh)
{
  Bins &bins = TheBins();
  mesh.points = bins.Intern(mesh.points);
  mesh.triangleIndices = bins.Intern(mesh.triangleIndices);
  mesh.uvs = bins.Intern(mesh.uvs);
  mesh.triangleFaces = bins.Intern(mesh.triangleFaces);
  mesh.skinInfluences = bins.Intern(mesh.skinInfluences);
}

void HdAkariTriangulate(HdMeshTopology const &topology, HdMeshUtil &meshUtil, VtVec3iArray *triangles,
                        VtIntArray *params)
{
  // Hydra's own topology hash, what Storm shares its index buffers by.
  const uint64_t key = topology.ComputeHash();
  TheBins().touched.store(true, std::memory_order_relaxed);
  const uint64_t now = TheBins().pass.load(std::memory_order_relaxed);
  {
    std::lock_guard<std::mutex> lock(triangulationMutex);
    const auto found = triangulations.find(key);
    if (found != triangulations.end()) {
      found->second.used = now;
      *triangles = found->second.triangles;
      *params = found->second.params;
      return;
    }
  }
  meshUtil.ComputeTriangleIndices(triangles, params);
  std::lock_guard<std::mutex> lock(triangulationMutex);
  triangulations.emplace(key, Triangulation{*triangles, *params, now});
}

void HdAkariPruneArrayBins()
{
  constexpr uint64_t keep = 8;
  if (!TheBins().Prune(keep)) return;
  const uint64_t now = TheBins().pass.load(std::memory_order_relaxed);
  std::lock_guard<std::mutex> lock(triangulationMutex);
  for (auto it = triangulations.begin(); it != triangulations.end();) {
    it = it->second.used + keep < now ? triangulations.erase(it) : std::next(it);
  }
}

PXR_NAMESPACE_CLOSE_SCOPE
