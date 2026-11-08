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
#include "HdAkari/meshUtils.h"

#include <algorithm>
#include <cmath>
#include <numeric>
#include <unordered_map>
#include <vector>

PXR_NAMESPACE_OPEN_SCOPE

namespace {

/// Keeps a stable random subset of an aggregate's disconnected parts (blades,
/// leaves) to about `targetTriangles`, each grown about its center to hold the
/// coverage of the ones dropped, after Cook et al., "Stochastic Simplification
/// of Aggregate Detail" (2007). Clustering their points would fuse them into a
/// solid sheet. `outSources` names each kept triangle's original. False when
/// the mesh is one surface rather than many parts.
bool HdAkariPruneParts(VtVec3fArray const &points, VtVec3iArray const &tris, VtVec2fArray const &uvs,
                       size_t targetTriangles, VtVec3fArray &outPoints, VtVec3iArray &outTris,
                       VtVec2fArray &outUvs, VtIntArray &outSources)
{
  std::vector<int32_t> parent(points.size());
  for (size_t i = 0; i < parent.size(); ++i) parent[i] = int32_t(i);
  auto find = [&](int32_t i) {
    while (parent[i] != i) { parent[i] = parent[parent[i]]; i = parent[i]; }
    return i;
  };

  for (GfVec3i const &t : tris) {
    if (t[0] < 0 || t[1] < 0 || t[2] < 0 || size_t(std::max({t[0], t[1], t[2]})) >= points.size()) continue;
    for (int c = 1; c < 3; ++c) {
      const int32_t a = find(t[0]), b = find(t[c]);
      if (a != b) parent[std::max(a, b)] = std::min(a, b);
    }
  }

  std::unordered_map<int32_t, int32_t> partOf;
  std::vector<std::vector<int32_t>> parts;
  for (size_t i = 0; i < tris.size(); ++i) {
    GfVec3i const &t = tris[i];
    if (t[0] < 0 || t[1] < 0 || t[2] < 0 || size_t(std::max({t[0], t[1], t[2]})) >= points.size()) continue;
    auto [it, inserted] = partOf.try_emplace(find(t[0]), int32_t(parts.size()));
    if (inserted) parts.emplace_back();
    parts[it->second].push_back(int32_t(i));
  }

  size_t largest = 0;
  for (auto const &part : parts) largest = std::max(largest, part.size());
  // a few big parts are surfaces, which clustering simplifies better.
  if (parts.size() < 16 || largest * 4 > tris.size()) return false;

  std::vector<std::pair<uint64_t, int32_t>> order(parts.size());
  for (size_t p = 0; p < parts.size(); ++p) {
    uint64_t h = (uint64_t(parts[p][0]) + 0x9E3779B97F4A7C15ull) * 0xBF58476D1CE4E5B9ull;
    h = (h ^ (h >> 31)) * 0x94D049BB133111EBull;
    order[p] = {h ^ (h >> 29), int32_t(p)};
  }

  std::sort(order.begin(), order.end());
  std::vector<int32_t> kept;
  size_t keptTriangles = 0;
  for (auto const &[hash, p] : order) {
    if (!kept.empty() && keptTriangles + parts[p].size() > targetTriangles) continue;
    kept.push_back(p);
    keptTriangles += parts[p].size();
  }

  if (keptTriangles >= tris.size()) return false;
  // growing each part by the area it now stands for, so the kept parts still cover what all of them
  // did, capped so a very sparse level doesn't turn into giants.
  const float grow = float(std::min(std::sqrt(double(tris.size()) / double(keptTriangles)), 3.0));

  const bool cornerUvs = uvs.size() == tris.size() * 3;
  const bool pointUvs = !cornerUvs && uvs.size() == points.size();
  std::vector<int32_t> remap(points.size(), -1);
  VtVec3fArray keptPoints;
  VtVec3iArray keptTris;
  VtVec2fArray keptUvs;
  VtIntArray sources;
  keptTris.reserve(keptTriangles);
  sources.reserve(keptTriangles);
  for (int32_t p : kept) {
    GfVec3d center(0.0);
    size_t corners = 0;
    for (int32_t i : parts[p]) {
      for (int c = 0; c < 3; ++c, ++corners) center += GfVec3d(points[tris[i][c]]);
    }

    const GfVec3f pivot(center / double(std::max<size_t>(corners, 1)));
    for (int32_t i : parts[p]) {
      GfVec3i m;
      for (int c = 0; c < 3; ++c) {
        int32_t &r = remap[tris[i][c]];
        if (r < 0) {
          r = int32_t(keptPoints.size());
          keptPoints.push_back(pivot + (points[tris[i][c]] - pivot) * grow);
          if (pointUvs) keptUvs.push_back(uvs[tris[i][c]]);
        }

        m[c] = r;
      }

      keptTris.push_back(m);
      sources.push_back(i);
      if (cornerUvs) {
        for (int c = 0; c < 3; ++c) keptUvs.push_back(uvs[i * 3 + c]);
      }
    }
  }

  outPoints = std::move(keptPoints);
  outTris = std::move(keptTris);
  outUvs = cornerUvs || pointUvs ? std::move(keptUvs) : uvs;
  outSources = std::move(sources);
  return !outTris.empty();
}

}  // namespace

bool HdAkariDecimate(VtVec3fArray const &points, VtVec3iArray const &tris, VtVec2fArray const &uvs,
                     size_t targetTriangles,
                     VtVec3fArray &outPoints, VtVec3iArray &outTris, VtVec2fArray &outUvs,
                     VtIntArray &outSources)
{
  const bool cornerUvs = uvs.size() == tris.size() * 3;
  const bool pointUvs = !cornerUvs && uvs.size() == points.size();
  if (tris.size() <= targetTriangles || points.empty()) return false;
  outSources = VtIntArray();
  if (HdAkariPruneParts(points, tris, uvs, targetTriangles, outPoints, outTris, outUvs, outSources)) return true;
  outSources = VtIntArray();
  GfVec3f lo(3.4e38f), hi(-3.4e38f);
  for (GfVec3f const &p : points) {
    for (int k = 0; k < 3; ++k) { lo[k] = std::min(lo[k], p[k]); hi[k] = std::max(hi[k], p[k]); }
  }

  const GfVec3f size = hi - lo;
  double area = 0.0;
  for (GfVec3i const &t : tris) {
    if (t[0] < 0 || t[1] < 0 || t[2] < 0 || size_t(std::max({t[0], t[1], t[2]})) >= points.size()) continue;
    area += 0.5 * double(GfCross(points[t[1]] - points[t[0]], points[t[2]] - points[t[0]]).GetLength());
  }
  // a surface's points fill a grid's cells by area, so the cell edge goes with the square root of
  // what each kept vertex covers, its relief counted, never coarser than the bounds would make it.
  const double vertices = std::max<double>(double(targetTriangles) * 0.5, 1.0);
  double cell = std::max(std::min(std::sqrt(area / vertices), double(size.GetLength()) / std::sqrt(vertices)), 1e-12);

  std::vector<int32_t> remap(points.size());
  for (int attempt = 0; attempt < 6; ++attempt, cell *= 1.4) {
    std::unordered_map<uint64_t, int32_t> cells;
    cells.reserve(std::min(points.size(), targetTriangles));
    std::vector<GfVec3d> sums;
    std::vector<GfVec2d> uvSums;
    std::vector<int32_t> counts;
    for (size_t i = 0; i < points.size(); ++i) {
      uint64_t key = 0;
      for (int k = 0; k < 3; ++k) {
        key = key * 2097152ull + uint64_t(std::min(2097151.0, std::max(0.0, (points[i][k] - lo[k]) / cell)));
      }

      auto [it, inserted] = cells.try_emplace(key, int32_t(sums.size()));
      if (inserted) { sums.emplace_back(0.0); counts.push_back(0); if (pointUvs) uvSums.emplace_back(0.0); }
      sums[it->second] += GfVec3d(points[i]);
      if (pointUvs) uvSums[it->second] += GfVec2d(uvs[i]);
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
    if (pointUvs) {
      mergedUvs.resize(sums.size());
      for (size_t c = 0; c < sums.size(); ++c) mergedUvs[c] = GfVec2f(uvSums[c] / double(counts[c]));
    }

    outPoints = std::move(centers);
    outTris = std::move(merged);
    outUvs = cornerUvs || pointUvs ? std::move(mergedUvs) : uvs;
    return !outTris.empty();
  }

  return false;
}

PXR_NAMESPACE_CLOSE_SCOPE
