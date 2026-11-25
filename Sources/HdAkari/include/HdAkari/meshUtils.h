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
#ifndef HDAKARI_MESH_UTILS_H
#define HDAKARI_MESH_UTILS_H

#include "HdAkari/sceneData.h"

PXR_NAMESPACE_OPEN_SCOPE

/// copies `points` into `dst` as three floats each and writes their bounds, for the deformer's upload
inline void HdAkariCopyPoints(VtVec3fArray const &points, float *dst, float *bounds)
{
  const size_t n = points.size();
  float lo[3] = {3.4e38f, 3.4e38f, 3.4e38f};
  float hi[3] = {-3.4e38f, -3.4e38f, -3.4e38f};

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

/// writes the min and max corners of `points` in their own space, zero when empty
inline void HdAkariPointsBounds(VtVec3fArray const &points, float *bounds)
{
  GfVec3f lo(3.4e38f);
  GfVec3f hi(-3.4e38f);
  for (GfVec3f const &p : points) {
    for (int k = 0; k < 3; ++k) { lo[k] = std::min(lo[k], p[k]); hi[k] = std::max(hi[k], p[k]); }
  }

  if (points.empty()) lo = hi = GfVec3f(0.0f);
  for (int k = 0; k < 3; ++k) { bounds[k] = lo[k]; bounds[3 + k] = hi[k]; }
}

/// writes up to `count` evenly strided `points` as xyz into `out` and returns how many
inline size_t HdAkariPointsSample(VtVec3fArray const &points, float *out, size_t count)
{
  const size_t n = std::min(count, points.size());
  const size_t stride = n ? points.size() / n : 1;

  for (size_t i = 0; i < n; ++i) {
    GfVec3f const &p = points[i * stride];
    out[i * 3] = p[0]; out[i * 3 + 1] = p[1]; out[i * 3 + 2] = p[2];
  }

  return n;
}

/// `points` grown by `scale` about the center of their bounds, for a part standing in for pruned ones
inline VtVec3fArray HdAkariGrowPoints(VtVec3fArray const &points, float scale)
{
  if (points.empty()) return points;

  GfVec3f lo = points[0];
  GfVec3f hi = points[0];
  for (GfVec3f const &p : points) {
    for (int k = 0; k < 3; ++k) { lo[k] = std::min(lo[k], p[k]); hi[k] = std::max(hi[k], p[k]); }
  }

  const GfVec3f pivot = (lo + hi) * 0.5f;
  VtVec3fArray grown(points.size());
  for (size_t i = 0; i < points.size(); ++i) grown[i] = pivot + (points[i] - pivot) * scale;

  return grown;
}

/// each of `values` at `indices`, for a pruned mesh's per triangle data
inline VtIntArray HdAkariSubsetInts(VtIntArray const &values, VtIntArray const &indices)
{
  VtIntArray out;
  out.reserve(indices.size());
  for (int i : indices) out.push_back(i >= 0 && size_t(i) < values.size() ? values[i] : -1);
  return out;
}

/// simplifies a mesh to about `targetTriangles` by clustering points on a grid, pruning aggregates instead and naming their sources
HDAKARI_API bool HdAkariDecimate(VtVec3fArray const &points, VtVec3iArray const &tris, VtVec2fArray const &uvs,
                                 size_t targetTriangles,
                                 VtVec3fArray &outPoints, VtVec3iArray &outTris, VtVec2fArray &outUvs,
                                 VtIntArray &outSources);

/// each drawn triangle's streamed ptex face and corner places packed into an int, all ones where it has none
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

/// copies `points` into `dst` as three floats each, without computing bounds
inline void HdAkariCopyPointsFlat(VtVec3fArray const &points, float *dst)
{
  const size_t n = points.size();
  if (n > 0) std::memcpy(dst, points.cdata()->data(), n * 3 * sizeof(float));
}

/// copies triangle corners into `dst` as three ints each
inline void HdAkariCopyTriangles(VtVec3iArray const &tris, int32_t *dst)
{
  const size_t n = tris.size();
  if (n > 0) std::memcpy(dst, tris.cdata()->data(), n * 3 * sizeof(int32_t));
}

/// copies `uvs` into `dst` as two floats per corner, a constant uv repeating across every corner
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

/// the instance matrices read in place as row major floats, which the renderer reads as column major transforms
inline float const *HdAkariMatrixFloats(VtMatrix4fArray const &matrices)
{
  return matrices.empty() ? nullptr : matrices.cdata()->GetArray();
}

/// writes each instance matrix as 16 floats in the same layout
inline void HdAkariCopyInstances(HdAkariMeshData const &mesh, float *dst)
{
  const size_t n = mesh.instances.size();
  if (n > 0) std::memcpy(dst, mesh.instances.cdata()->GetArray(), n * 16 * sizeof(float));
}

/// the joints of a gpu skinned mesh, zero when its points arrive already skinned
inline size_t HdAkariSkinJointCount(HdAkariMeshData const &mesh)
{
  return mesh.skinInfluencesPerPoint > 0 ? mesh.skinXforms.size() : 0;
}

/// writes each joint matrix as three rows and the local bounds, for gpu skinning's upload
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

/// a path's hash, the per frame identity of a mesh without its string
inline uint64_t HdAkariPathKey(SdfPath const &path)
{
  return static_cast<uint64_t>(path.GetHash());
}

/// whether two triangulations and their uvs are the same
inline bool HdAkariSameTopology(VtVec3iArray const &tris, VtVec3iArray const &otherTris,
                                VtVec2fArray const &uvs, VtVec2fArray const &otherUvs)
{
  return tris == otherTris && uvs == otherUvs;
}

/// hashes raw bytes eight at a time, for content hashing reusable prototype geometry
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

/// bins the arrays of `mesh` by content, so equal ones across every mesh share one copy
HDAKARI_API void HdAkariInternMeshArrays(HdAkariMeshData &mesh);

/// ages the bins once per sync pass, dropping what no mesh has asked for in a few passes
HDAKARI_API void HdAkariPruneArrayBins();

/// a stable key over a prototype's geometry and material, equal keys and transforms can share one instanced draw
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

  if (!mesh.normals.empty()) {
    hash = HdAkariHashBytes(hash, mesh.normals.data(), mesh.normals.size() * sizeof(GfVec3f));
  }

  hash = HdAkariHashBytes(hash, &mesh.ptexMap, sizeof(int));
  hash = HdAkariHashBytes(hash, &mesh.displayColor, sizeof(GfVec3f));
  hash = HdAkariHashBytes(hash, &mesh.opacity, sizeof(float));
  hash = HdAkariHashBytes(hash, &mesh.roughness, sizeof(float));
  hash = HdAkariHashBytes(hash, &mesh.metallic, sizeof(float));

  const uint8_t flags = uint8_t(mesh.transparent ? 1 : 0)
    | uint8_t(mesh.emitter ? 2 : 0)
    | uint8_t(mesh.transform.GetDeterminant() < 0.0 ? 4 : 0)
    | uint8_t(mesh.smooth ? 8 : 0)
    | uint8_t(mesh.shadowCutout ? 16 : 0)
    | uint8_t(mesh.faceted ? 32 : 0);
  hash = HdAkariHashBytes(hash, &flags, sizeof(flags));

  return hash ? hash : 1;
}

PXR_NAMESPACE_CLOSE_SCOPE

#endif // HDAKARI_MESH_UTILS_H
