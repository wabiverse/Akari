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

import AkariCore
import Foundation
import OpenUSDKit

public extension Akari
{
  enum Geom
  {
    /// Builds the indexed triangle stream with auto smooth normals by
    /// splitting vertices at hard edges.
    public static func buildMesh(points: Pixar.VtVec3fArray,
                                 tris: Pixar.VtVec3iArray,
                                 verts: inout [Float],
                                 indices: inout [Int32])
    {
      let kHardEdgeCos: Float = 0.8660254 // cos(30°)

      let triCount = tris.size()
      let ptCount = points.size()

      verts.reserveCapacity(verts.count + triCount * 18)
      indices.reserveCapacity(indices.count + triCount * 3)

      // smooth per point normals.
      var smooth = [GfVec3f](repeating: GfVec3f(0.0, 0.0, 0.0), count: ptCount)
      var faceNormals = [GfVec3f](repeating: GfVec3f(0.0, 0.0, 0.0), count: triCount)
      var faceValid = [Bool](repeating: false, count: triCount)

      for idx in 0 ..< tris.size()
      {
        if tris[idx][0] < 0 || tris[idx][1] < 0 || tris[idx][2] < 0
        {
          continue
        }
        let p0 = points[Int(tris[idx][0])]
        let p1 = points[Int(tris[idx][1])]
        let p2 = points[Int(tris[idx][2])]
        let fn = Pixar.GfCross(p1 - p0, p2 - p0)
        if fn.GetLength() <= 1e-8
        {
          continue
        }
        faceNormals[idx] = fn.GetNormalized()
        faceValid[idx] = true
        for i in 0 ..< 3
        {
          let p = Int(tris[idx][i])
          smooth[p] = smooth[p] + fn
        }
      }
      for i in 0 ..< smooth.count
      {
        smooth[i] = smooth[i].GetLength() > 1e-8
          ? smooth[i].GetNormalized()
          : GfVec3f(0.0, 1.0, 0.0)
      }

      for idx in 0 ..< tris.size()
      {
        guard faceValid[idx] else { continue }
        let fnN = faceNormals[idx]
        for c in 0 ..< 3
        {
          let p = Int(tris[idx][c])
          let sn = smooth[p]
          let n = Pixar.GfDot(fnN, sn) > kHardEdgeCos ? sn : fnN
          indices.append(appendVertex(p, n, points, &verts))
        }
      }
    }

    private static func appendVertex(_ p: Int,
                                     _ n: GfVec3f,
                                     _ points: Pixar.VtVec3fArray,
                                     _ verts: inout [Float]) -> Int32
    {
      let slot = Int32(verts.count / 6)
      let pt = points[p]
      verts.append(pt[0])
      verts.append(pt[1])
      verts.append(pt[2])
      verts.append(n[0])
      verts.append(n[1])
      verts.append(n[2])
      return slot
    }
  }
}

public extension Swift.Array where Element == Float
{
  /// Copies a packed 16 float (column major) matrix into a
  /// GfMatrix4d. Used to reinterpret per mesh transform and
  /// camera matrices for LabGL's immediate mode capture.
  var toMatrix4d: Pixar.GfMatrix4d
  {
    precondition(count == 16, "expected a packed 4x4 matrix (16 floats)")

    var out = Pixar.GfMatrix4d(1.0)
    for r in 0 ..< 4
    {
      for c in 0 ..< 4
      {
        out[r][c] = Double(self[r * 4 + c])
      }
    }
    return out
  }
}
