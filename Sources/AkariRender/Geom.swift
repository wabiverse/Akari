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
import simd

public extension Akari
{
  enum Geom
  {
    /// Convenience entry point that touches USD's arrays directly.
    public static func buildMesh(points: Pixar.VtVec3fArray,
                                 tris: Pixar.VtVec3iArray,
                                 uvs: Pixar.VtVec2fArray,
                                 verts: inout [Float],
                                 indices: inout [Int32],
                                 flipWinding: Bool = false)
    {
      let (pointsFlat, trisFlat, uvsFlat) = flatten(points: points, tris: tris, uvs: uvs)
      buildMesh(pointsFlat: pointsFlat, trisFlat: trisFlat, uvsFlat: uvsFlat,
                verts: &verts, indices: &indices, flipWinding: flipWinding)
    }

    /// Copies USD's point/triangle/uv arrays into plain Swift arrays.
    public static func flatten(points: Pixar.VtVec3fArray,
                               tris: Pixar.VtVec3iArray,
                               uvs: Pixar.VtVec2fArray) -> (points: [Float], tris: [Int32], uvs: [Float])
    {
      let ptCount = points.size()
      var pointsFlat = [Float](repeating: 0, count: ptCount * 3)
      for i in 0 ..< ptCount
      {
        let p = points[i]
        pointsFlat[i * 3 + 0] = p[0]
        pointsFlat[i * 3 + 1] = p[1]
        pointsFlat[i * 3 + 2] = p[2]
      }

      let triCount = tris.size()
      var trisFlat = [Int32](repeating: -1, count: triCount * 3)
      for idx in 0 ..< triCount
      {
        trisFlat[idx * 3 + 0] = tris[idx][0]
        trisFlat[idx * 3 + 1] = tris[idx][1]
        trisFlat[idx * 3 + 2] = tris[idx][2]
      }

      let uvCount = uvs.size()
      var uvsFlat = [Float](repeating: 0, count: triCount * 3 * 2)
      for i in 0 ..< min(uvCount, triCount * 3)
      {
        let uv = uvs[i]
        uvsFlat[i * 2 + 0] = uv[0]
        uvsFlat[i * 2 + 1] = uv[1]
      }

      return (pointsFlat, trisFlat, uvsFlat)
    }

    /// Builds the indexed triangle stream with auto smooth normals by
    /// splitting vertices at hard edges.
    public static func buildMesh(pointsFlat: [Float],
                                 trisFlat: [Int32],
                                 uvsFlat: [Float],
                                 verts: inout [Float],
                                 indices: inout [Int32],
                                 flipWinding: Bool = false)
    {
      let kHardEdgeCos: Float = 0.8660254 // cos(30°)

      let triCount = trisFlat.count / 3
      let ptCount = pointsFlat.count / 3

      verts.reserveCapacity(verts.count + triCount * 24)
      indices.reserveCapacity(indices.count + triCount * 3)
      var triIndices = trisFlat
      var triUvs = uvsFlat.count == trisFlat.count * 2 ? uvsFlat : [Float](repeating: 0, count: trisFlat.count * 2)
      repairWinding(&triIndices, &triUvs)

      func point(_ i: Int32) -> SIMD3<Float>
      {
        let o = Int(i) * 3
        return SIMD3<Float>(pointsFlat[o], pointsFlat[o + 1], pointsFlat[o + 2])
      }

      var smooth = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 0), count: ptCount)
      var faceNormals = [SIMD3<Float>](repeating: SIMD3<Float>(0, 0, 0), count: triCount)
      var faceValid = [Bool](repeating: false, count: triCount)

      for idx in 0 ..< triCount
      {
        let i0 = triIndices[idx * 3 + 0]
        let i1 = triIndices[idx * 3 + 1]
        let i2 = triIndices[idx * 3 + 2]
        if i0 < 0 || i1 < 0 || i2 < 0
        {
          continue
        }
        let p0 = point(i0); let p1 = point(i1); let p2 = point(i2)
        let fn = cross(p1 - p0, p2 - p0)
        let fnLen = length(fn)
        if fnLen <= 1e-8
        {
          continue
        }
        faceNormals[idx] = fn / fnLen
        faceValid[idx] = true
        smooth[Int(i0)] += fn
        smooth[Int(i1)] += fn
        smooth[Int(i2)] += fn
      }
      for i in 0 ..< smooth.count
      {
        let smoothLen = length(smooth[i])
        smooth[i] = smoothLen > 1e-8
          ? smooth[i] / smoothLen
          : SIMD3<Float>(0, 1, 0)
      }

      func emitCorner(_ idx: Int, _ c: Int)
      {
        let p = Int(triIndices[idx * 3 + c])
        let sn = smooth[p]
        let n = dot(faceNormals[idx], sn) > kHardEdgeCos ? sn : faceNormals[idx]
        let uo = (idx * 3 + c) * 2
        let uv = SIMD2<Float>(triUvs[uo], triUvs[uo + 1])
        indices.append(appendVertex(p, n, uv, pointsFlat, &verts))
      }

      for idx in 0 ..< triCount
      {
        guard faceValid[idx] else { continue }
        if flipWinding {
          emitCorner(idx, 0); emitCorner(idx, 2); emitCorner(idx, 1)
        } else {
          emitCorner(idx, 0); emitCorner(idx, 1); emitCorner(idx, 2)
        }
      }
    }

    /// Repairs mesh face winding inconsistencies.
    private static func repairWinding(_ indices: inout [Int32], _ uvs: inout [Float])
    {
      let triCount = indices.count / 3
      guard triCount > 1 else { return }

      func edgeKey(_ a: Int32, _ b: Int32) -> UInt64
      {
        let ua = UInt64(bitPattern: Int64(a)); let ub = UInt64(bitPattern: Int64(b))
        return ua < ub ? (ua << 32) | ub : (ub << 32) | ua
      }

      var adjacency = [[(Int, Bool)]](repeating: [], count: triCount)

      var edgeFirstOwner: [UInt64: (tri: Int, forward: Bool)] = [:]
      edgeFirstOwner.reserveCapacity(triCount * 3)
      var pairedEdges: Set<UInt64> = []

      func processEdge(_ a: Int32, _ b: Int32, _ t: Int)
      {
        let key = edgeKey(a, b)
        guard !pairedEdges.contains(key) else { return }
        let forward = a < b
        if let first = edgeFirstOwner.removeValue(forKey: key)
        {
          let sameDirection = first.forward == forward
          adjacency[first.tri].append((t, sameDirection))
          adjacency[t].append((first.tri, sameDirection))
          pairedEdges.insert(key)
        }
        else
        {
          edgeFirstOwner[key] = (t, forward)
        }
      }

      for t in 0 ..< triCount
      {
        let v0 = indices[t * 3 + 0]; let v1 = indices[t * 3 + 1]; let v2 = indices[t * 3 + 2]
        guard v0 >= 0, v1 >= 0, v2 >= 0, v0 != v1, v1 != v2, v2 != v0 else { continue }
        processEdge(v0, v1, t)
        processEdge(v1, v2, t)
        processEdge(v2, v0, t)
      }

      var visited = [Bool](repeating: false, count: triCount)
      var flip = [Bool](repeating: false, count: triCount)

      for seed in 0 ..< triCount where !visited[seed]
      {
        visited[seed] = true
        var component = [seed]
        var queue = [seed]
        while let t = queue.popLast()
        {
          for (nbr, sameDirection) in adjacency[t]
          {
            if !visited[nbr]
            {
              visited[nbr] = true
              flip[nbr] = sameDirection ? !flip[t] : flip[t]
              component.append(nbr)
              queue.append(nbr)
            }
          }
        }

        let flippedCount = component.reduce(0) { $0 + (flip[$1] ? 1 : 0) }
        if flippedCount * 2 > component.count
        {
          for t in component { flip[t].toggle() }
        }
      }

      for t in 0 ..< triCount where flip[t]
      {
        indices.swapAt(t * 3 + 1, t * 3 + 2)
        let uo = t * 6
        uvs.swapAt(uo + 2, uo + 4)
        uvs.swapAt(uo + 3, uo + 5)
      }
    }

    private static func appendVertex(_ p: Int,
                                     _ n: SIMD3<Float>,
                                     _ uv: SIMD2<Float>,
                                     _ pointsFlat: [Float],
                                     _ verts: inout [Float]) -> Int32
    {
      let slot = Int32(verts.count / 8)
      let o = p * 3
      verts.append(pointsFlat[o + 0])
      verts.append(pointsFlat[o + 1])
      verts.append(pointsFlat[o + 2])
      verts.append(n.x)
      verts.append(n.y)
      verts.append(n.z)
      verts.append(uv.x)
      verts.append(uv.y)
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
