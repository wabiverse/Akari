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

import Foundation
import simd

extension Kraken
{
  /// thins a sculpt's surface for the scene, folding only flat points with matching paint so the surface reads the same
  enum SculptSimplify
  {
    struct Surface: Sendable
    {
      var points: [SIMD3<Float>]
      var normals: [SIMD3<Float>]
      /// display paint with gloss in alpha
      var colors: [SIMD4<UInt8>]
      /// one per point, empty when nothing is masked
      var mask: [Float]
      var indices: [Int32]
    }

    /// the squared distances from a point to the planes it has gathered
    private struct Quadric
    {
      var xx = 0.0, xy = 0.0, xz = 0.0, xw = 0.0
      var yy = 0.0, yz = 0.0, yw = 0.0
      var zz = 0.0, zw = 0.0
      var ww = 0.0

      init() {}

      init(plane n: SIMD3<Double>, _ d: Double)
      {
        xx = n.x * n.x; xy = n.x * n.y; xz = n.x * n.z; xw = n.x * d
        yy = n.y * n.y; yz = n.y * n.z; yw = n.y * d
        zz = n.z * n.z; zw = n.z * d
        ww = d * d
      }

      static func += (a: inout Quadric, b: Quadric)
      {
        a.xx += b.xx; a.xy += b.xy; a.xz += b.xz; a.xw += b.xw
        a.yy += b.yy; a.yz += b.yz; a.yw += b.yw
        a.zz += b.zz; a.zw += b.zw
        a.ww += b.ww
      }

      func error(_ p: SIMD3<Double>) -> Double
      {
        xx * p.x * p.x + 2 * xy * p.x * p.y + 2 * xz * p.x * p.z + 2 * xw * p.x
          + yy * p.y * p.y + 2 * yz * p.y * p.z + 2 * yw * p.y
          + zz * p.z * p.z + 2 * zw * p.z + ww
      }

      func adding(_ b: Quadric) -> Quadric
      {
        var sum = self
        sum += b
        return sum
      }
    }

    /// `tolerance` is how far the surface may stray from its planes and `longest` the longest edge a fold may leave
    static func simplify(_ surface: Surface, tolerance: Float, longest: Float) -> Surface
    {
      let points = surface.points, normals = surface.normals, colors = surface.colors, mask = surface.mask
      let count = points.count
      let masked = mask.count == count
      guard count > 3, normals.count == count, colors.count == count, surface.indices.count >= 3 else { return surface }

      var tris: [SIMD3<Int32>] = stride(from: 0, to: surface.indices.count - 2, by: 3).map
      {
        SIMD3(surface.indices[$0], surface.indices[$0 + 1], surface.indices[$0 + 2])
      }

      var live = [Bool](repeating: true, count: tris.count)
      var around = [[Int32]](repeating: [], count: count)
      var quadrics = [Quadric](repeating: Quadric(), count: count)
      for (t, tri) in tris.enumerated()
      {
        let a = SIMD3<Double>(points[Int(tri.x)]), b = SIMD3<Double>(points[Int(tri.y)]), c = SIMD3<Double>(points[Int(tri.z)])
        let cross = simd_cross(b - a, c - a)
        let length = simd_length(cross)
        if length > 0
        {
          let n = cross / length
          let q = Quadric(plane: n, -simd_dot(n, a))
          for i in [tri.x, tri.y, tri.z] { quadrics[Int(i)] += q }
        }

        for i in [tri.x, tri.y, tri.z] { around[Int(i)].append(Int32(t)) }
      }

      let limit = Double(tolerance) * Double(tolerance)

      /// the live triangles at a point and the points around it, which match one for one where the surface closes
      func ring(_ u: Int) -> (tris: [Int32], points: [Int32])
      {
        var faces: [Int32] = []
        var others: [Int32] = []
        for t in around[u] where live[Int(t)]
        {
          faces.append(t)
          let tri = tris[Int(t)]
          for i in [tri.x, tri.y, tri.z] where Int(i) != u && !others.contains(i) { others.append(i) }
        }

        return (faces, others)
      }

      /// whether u can fold into v without folding the surface over, pinching it, or changing its look
      func folds(_ u: Int, into v: Int, _ ring: (tris: [Int32], points: [Int32]), _ other: [Int32]) -> Bool
      {
        guard colors[u] == colors[v], !masked || abs(mask[u] - mask[v]) < 0.004 else { return false }
        guard simd_dot(normals[u], normals[v]) > 0.9995 else { return false }

        // the two points may share only the two corners across their edge, or the surface pinches
        var shared = 0
        for w in ring.points where other.contains(w) { shared += 1 }
        guard shared == 2 else { return false }

        let p = points[v]
        for w in ring.points where simd_distance_squared(p, points[Int(w)]) > longest * longest { return false }
        for t in ring.tris
        {
          let tri = tris[Int(t)]
          if tri.x == Int32(v) || tri.y == Int32(v) || tri.z == Int32(v) { continue }

          let a = points[Int(tri.x)], b = points[Int(tri.y)], c = points[Int(tri.z)]
          let before = simd_cross(b - a, c - a)
          let moved = [tri.x, tri.y, tri.z].map { Int($0) == u ? p : points[Int($0)] }
          let after = simd_cross(moved[1] - moved[0], moved[2] - moved[0])
          let size = simd_length(after)
          guard size > 1e-12, simd_dot(before, after) > 0, simd_dot(after / size, normals[v]) > 0.999 else { return false }
        }

        return true
      }

      var alive = [Bool](repeating: true, count: count)
      var restless = [Bool](repeating: true, count: count)
      var folded = 1
      while folded > 0
      {
        folded = 0
        var touched = [Bool](repeating: false, count: count)
        for u in 0 ..< count where alive[u] && restless[u] && !touched[u]
        {
          restless[u] = false
          let mine = ring(u)

          // a point on an open edge or where sheets meet stays, its triangles and neighbors don't pair up
          guard mine.tris.count == mine.points.count, mine.tris.count >= 3 else { continue }

          var best = -1
          var lowest = limit
          for w in mine.points where !touched[Int(w)]
          {
            let v = Int(w)
            let cost = quadrics[u].adding(quadrics[v]).error(SIMD3<Double>(points[v]))
            guard cost <= lowest else { continue }
            guard folds(u, into: v, mine, ring(v).points) else { continue }
            best = v
            lowest = cost
          }

          guard best >= 0 else { continue }

          // the triangles across the edge go, the rest take v in place of u
          for t in mine.tris
          {
            var tri = tris[Int(t)]
            if tri.x == Int32(best) || tri.y == Int32(best) || tri.z == Int32(best)
            {
              live[Int(t)] = false
              continue
            }

            if tri.x == Int32(u) { tri.x = Int32(best) } else if tri.y == Int32(u) { tri.y = Int32(best) } else { tri.z = Int32(best) }
            tris[Int(t)] = tri
            around[best].append(t)
          }

          around[best].removeAll { !live[Int($0)] }
          around[u] = []
          alive[u] = false
          quadrics[best] += quadrics[u]
          folded += 1

          touched[u] = true
          touched[best] = true
          restless[best] = true
          for w in mine.points
          {
            touched[Int(w)] = true
            restless[Int(w)] = true
          }
        }
      }

      // the points left, numbered again in order
      var remap = [Int32](repeating: -1, count: count)
      var out = Surface(points: [], normals: [], colors: [], mask: [], indices: [])
      for i in 0 ..< count where alive[i]
      {
        remap[i] = Int32(out.points.count)
        out.points.append(points[i])
        out.normals.append(normals[i])
        out.colors.append(colors[i])
        if masked { out.mask.append(mask[i]) }
      }

      out.indices.reserveCapacity(tris.count)
      for (t, tri) in tris.enumerated() where live[t]
      {
        out.indices += [remap[Int(tri.x)], remap[Int(tri.y)], remap[Int(tri.z)]]
      }

      return out
    }
  }
}
