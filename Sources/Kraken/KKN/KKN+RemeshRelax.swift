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

extension Kraken.Remesh
{
  /// unique edges of a polygon mesh as neighbor lists, and how many faces use each edge
  static func neighbors(_ nv: Int, _ counts: [Int32], _ indices: [Int32]) -> (offset: [Int32], nbr: [Int32], uses: [UInt64: Int32])
  {
    var uses: [UInt64: Int32] = [:]
    uses.reserveCapacity(indices.count)
    var at = 0
    for c in counts
    {
      let c = Int(c)
      for k in 0 ..< c { uses[key(indices[at + k], indices[at + (k + 1) % c]), default: 0] += 1 }
      at += c
    }

    var a: [Int32] = [], b: [Int32] = []
    a.reserveCapacity(uses.count)
    b.reserveCapacity(uses.count)
    for k in uses.keys.sorted()
    {
      a.append(Int32(truncatingIfNeeded: k >> 32))
      b.append(Int32(truncatingIfNeeded: k & 0xffff_ffff))
    }

    let (offset, nbr) = Surface.csr(nv, a, b)
    return (offset, nbr, uses)
  }

  /// evens the result over the surface, sliding verts toward their neighbors in the tangent plane and back onto the input
  static func relax(_ mesh: inout Mesh, _ s: Surface, iterations: Int, edge: Float, clock: Clock)
  {
    let nv = mesh.p.count
    let (offset, nbr, _) = neighbors(nv, mesh.counts, mesh.indices)
    var p = mesh.p, n = mesh.n, flags = mesh.flags, root = mesh.root
    let reach = edge * 0.5

    for iteration in 0 ... max(iterations, 0)
    {
      if iteration > 1 && clock.over(0.95) { break }

      var np = p, nn = n, nf = flags, nr = root
      np.withUnsafeMutableBufferPointer
      { pb in
        nn.withUnsafeMutableBufferPointer
        { nb in
          nf.withUnsafeMutableBufferPointer
          { fb in
            nr.withUnsafeMutableBufferPointer
            { rb in
              parallel(nv, grain: 512)
              { range in
                for i in range
                {
                  var x = p[i]
                  let feature = flags[i] & 3 != 0
                  if flags[i] & 4 != 0
                  {
                    rb[i] = s.nearest(root[i], x)
                    continue
                  }

                  if iteration > 0
                  {
                    var sum = V.zero, k: Float = 0
                    for e in Int(offset[i]) ..< Int(offset[i + 1])
                    {
                      let j = Int(nbr[e])
                      if feature && flags[j] & 3 == 0 { continue }
                      sum += p[j]
                      k += 1
                    }

                    if k > 0 && (!feature || k == 2)
                    {
                      var c = sum / k - x
                      if !feature { c = tangent(c, n[i]) }
                      x += c * 0.6
                    }
                  }

                  let v = s.nearest(root[i], x)
                  let (y, normal) = s.project(x, near: v)
                  x = y
                  rb[i] = v
                  nb[i] = normal
                  if feature
                  {
                    let f = s.nearestFeature(v, x)
                    if f >= 0
                    {
                      let (z, _) = s.projectFeature(x, from: f)
                      if simd_length(z - x) < reach
                      {
                        x = z
                      }
                      else
                      {
                        fb[i] &= ~3
                      }
                    }
                    else
                    {
                      fb[i] &= ~3
                    }
                  }

                  pb[i] = x.x.isFinite && x.y.isFinite && x.z.isFinite ? x : s.p[Int(v)]
                }
              }
            }
          }
        }
      }

      p = np
      n = nn
      flags = nf
      root = nr
    }

    mesh.p = p
    mesh.n = n
    mesh.flags = flags
    mesh.root = root
  }

  /// edges of the result that lie along sharp edges of the input, as vert pairs
  static func sharpEdges(_ mesh: Mesh, _ s: Surface, edge: Float) -> [Int32]
  {
    let (_, _, uses) = neighbors(mesh.p.count, mesh.counts, mesh.indices)
    var out: [Int32] = []
    for (k, count) in uses.sorted(by: { $0.key < $1.key }) where count == 2
    {
      let a = Int32(truncatingIfNeeded: k >> 32), b = Int32(truncatingIfNeeded: k & 0xffff_ffff)
      guard mesh.flags[Int(a)] & 5 != 0, mesh.flags[Int(b)] & 5 != 0 else { continue }

      let m = (mesh.p[Int(a)] + mesh.p[Int(b)]) * 0.5
      let v = s.nearest(mesh.root[Int(a)], m)
      let f = s.nearestFeature(v, m)
      guard f >= 0 else { continue }

      let (z, _) = s.projectFeature(m, from: f)
      if simd_length(z - m) < simd_length(mesh.p[Int(a)] - mesh.p[Int(b)]) * 0.15
      {
        out += [a, b]
      }
    }

    return out
  }

  /// mirrors the half mesh across the plane and joins the seam, pulling near edges onto it and bridging the rest with quads
  static func mirror(_ r: inout Result, axis: Int, at plane: Float, edge: Float)
  {
    let nv = r.points.count
    let (_, _, uses) = neighbors(nv, r.counts, r.indices)

    // open edges in the direction their face runs along them
    var open: [(Int32, Int32)] = []
    var at = 0
    for c in r.counts
    {
      let c = Int(c)
      for k in 0 ..< c
      {
        let a = r.indices[at + k], b = r.indices[at + (k + 1) % c]
        if uses[key(a, b)] == 1 { open.append((a, b)) }
      }
      at += c
    }

    func off(_ v: Int32) -> Float { abs(r.points[Int(v)][axis] - plane) }
    func along(_ a: Int32, _ b: Int32) -> Bool
    {
      let d = r.points[Int(b)] - r.points[Int(a)]
      return abs(d[axis]) < simd_length(d) * 0.6
    }

    // a chain of open edges near the plane is the cut and goes onto it, a boundary that only crosses the plane stays put
    var near = [Int32: [Int32]]()
    for (a, b) in open
    {
      near[a, default: []].append(b)
      near[b, default: []].append(a)
    }

    var seam = [Bool](repeating: false, count: nv)
    for (v, around) in near
    {
      let close = off(v) < edge * 0.3 || (off(v) < edge * 1.6 && around.allSatisfy { off($0) < edge * 1.6 })
      if close { seam[Int(v)] = true }
    }

    for v in 0 ..< nv where seam[v] { r.points[v][axis] = plane }

    var twin = [Int32](repeating: 0, count: nv)
    var points = r.points
    for v in 0 ..< nv
    {
      if seam[v]
      {
        twin[v] = Int32(v)
        continue
      }

      var x = r.points[v]
      x[axis] = 2 * plane - x[axis]
      twin[v] = Int32(points.count)
      points.append(x)
    }

    var counts = r.counts, indices = r.indices
    at = 0
    for c in r.counts
    {
      let face = r.indices[at ..< at + Int(c)]
      indices += face.reversed().map { twin[Int($0)] }
      counts.append(c)
      at += Int(c)
    }

    // bridges across the gaps left along the plane
    for (a, b) in open where !(seam[Int(a)] && seam[Int(b)]) && along(a, b) && off(a) < edge * 2.5 && off(b) < edge * 2.5
    {
      var face = [b, a, twin[Int(a)], twin[Int(b)]]
      face = face.enumerated().filter { $0.offset == 0 || $0.element != face[$0.offset - 1] }.map { $0.element }
      if face.count > 1 && face.last == face.first { face.removeLast() }
      guard face.count >= 3 else { continue }

      counts.append(Int32(face.count))
      indices += face
    }

    if ProcessInfo.processInfo.environment["REMESH_DEBUG"] != nil
    {
      let bridges = counts.count - 2 * r.counts.count
      let (_, _, after) = neighbors(points.count, counts, indices)
      var nearOpen = 0
      for (a, b) in open where off(a) < edge * 2.5 && off(b) < edge * 2.5 { nearOpen += 1 }
      print("  mirror: half open \(open.count), near plane \(nearOpen), seam verts \(seam.filter { $0 }.count), bridges \(bridges), open after \(after.values.filter { $0 == 1 }.count), over-used \(after.values.filter { $0 > 2 }.count)")
    }

    r.sharp += r.sharp.map { twin[Int($0)] }
    r.points = points
    r.counts = counts
    r.indices = indices
  }
}
