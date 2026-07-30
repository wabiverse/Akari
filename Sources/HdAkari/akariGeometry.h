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
#ifndef AKARI_GEOMETRY_H
#define AKARI_GEOMETRY_H

#include <vector>

#include <pxr/pxrns.h>
#include <Gf/matrix4d.h>
#include <Gf/vec3f.h>
#include <Gf/vec3i.h>
#include <Vt/array.h>

/* Geometry helpers. */

PXR_NAMESPACE_OPEN_SCOPE

/// Builds the indexed triangle stream with auto smooth normals by
/// splitting vertices at hard edges.
inline void
BuildMeshGeometry(VtVec3fArray const &points, VtVec3iArray const &tris,
                  std::vector<float> &verts, std::vector<int> &indices)
{
  const float kHardEdgeCos = 0.8660254f; // cos(30°)

  // smooth per point normals.
  std::vector<GfVec3f> smooth(points.size(), GfVec3f(0.0f));
  for (GfVec3i const &t : tris) {
    if (t[0] < 0 || t[1] < 0 || t[2] < 0) {
      continue;
    }
    const GfVec3f &p0 = points[t[0]];
    const GfVec3f &p1 = points[t[1]];
    const GfVec3f &p2 = points[t[2]];
    const GfVec3f fn = GfCross(p1 - p0, p2 - p0);
    if (fn.GetLength() <= 1e-8f) {
      continue;
    }
    for (int i = 0; i < 3; ++i) {
      smooth[t[i]] += fn;
    }
  }
  for (GfVec3f &n : smooth) {
    n = n.GetLength() > 1e-8f ? n.GetNormalized() : GfVec3f(0.0f, 1.0f, 0.0f);
  }

  auto appendVertex = [&verts, &points](int p, GfVec3f const &n) -> int {
    const int slot = static_cast<int>(verts.size() / 6);
    const GfVec3f &pt = points[p];
    verts.push_back(pt[0]);
    verts.push_back(pt[1]);
    verts.push_back(pt[2]);
    verts.push_back(n[0]);
    verts.push_back(n[1]);
    verts.push_back(n[2]);
    return slot;
  };

  for (GfVec3i const &t : tris) {
    if (t[0] < 0 || t[1] < 0 || t[2] < 0) {
      continue;
    }
    const GfVec3f &p0 = points[t[0]];
    const GfVec3f &p1 = points[t[1]];
    const GfVec3f &p2 = points[t[2]];
    GfVec3f fn = GfCross(p1 - p0, p2 - p0);
    if (fn.GetLength() <= 1e-8f) {
      continue;
    }
    const GfVec3f fnN = fn.GetNormalized();
    for (int c = 0; c < 3; ++c) {
      const int p = t[c];
      const GfVec3f &sn = smooth[p];
      // within the threshold: smooth shading, share the per point normal.
      // outside the threshold: hard edge, split the vertex with the face normal.
      GfVec3f n = (GfDot(fnN, sn) > kHardEdgeCos) ? sn : fnN;
      indices.push_back(appendVertex(p, n));
    }
  }
}

/// Copies a packed 16 float (column major) matrix into a
/// GfMatrix4d. Used to reinterpret per mesh transform and
/// camera matrices for LabGL's immediate mode capture.
inline GfMatrix4d
ToMatrix4d(const float *m)
{
  GfMatrix4d out(1.0);
  for (int r = 0; r < 4; ++r) {
    for (int c = 0; c < 4; ++c) {
      out[r][c] = static_cast<double>(m[r * 4 + c]);
    }
  }
  return out;
}

PXR_NAMESPACE_CLOSE_SCOPE

#endif // AKARI_GEOMETRY_H
