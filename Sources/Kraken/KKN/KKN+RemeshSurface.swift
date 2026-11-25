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
  /// fans every polygon into triangles, skipping faces with corners that point nowhere
  static func triangulate(_ counts: [Int32], _ indices: [Int32], _ verts: Int) -> [Int32]
  {
    var tri: [Int32] = []
    tri.reserveCapacity(indices.count * 3)
    var at = 0
    let limit = Int32(verts)

    for c in counts
    {
      let c = Int(c)
      guard c >= 0, at + c <= indices.count else { break }

      if c >= 3
      {
        let a = indices[at]
        for k in 1 ..< c - 1
        {
          let b = indices[at + k], d = indices[at + k + 1]
          guard a >= 0, b >= 0, d >= 0, a < limit, b < limit, d < limit else { continue }

          tri += [a, b, d]
        }
      }

      at += c
    }

    return tri
  }

  /// joins verts that sit at the same place, then drops degenerate triangles and verts nothing uses
  static func weld(_ p: inout [V], _ tri: inout [Int32])
  {
    guard !p.isEmpty else { return }

    let lo = p.reduce(V(repeating: .infinity)) { simd_min($0, $1) }
    let hi = p.reduce(V(repeating: -.infinity)) { simd_max($0, $1) }
    let cell = max((hi - lo).max() / 2_000_000, 1e-30)

    struct Keyed
    {
      var key: UInt64
      var index: Int32
    }

    var keyed = [Keyed](repeating: Keyed(key: 0, index: 0), count: p.count)
    p.withUnsafeBufferPointer
    { pb in
      keyed.withUnsafeMutableBufferPointer
      { kb in
        parallel(pb.count)
        { range in
          for i in range
          {
            let g = simd_clamp((pb[i] - lo) / cell, V(repeating: 0), V(repeating: 2_097_151)).rounded(.toNearestOrEven)
            let k = UInt64(g.x) << 42 | UInt64(g.y) << 21 | UInt64(g.z)
            kb[i] = Keyed(key: k, index: Int32(i))
          }
        }
      }
    }

    keyed.sort { $0.key < $1.key }
    var remap = [Int32](repeating: 0, count: p.count)
    var first = Int32(0)
    for k in 0 ..< keyed.count
    {
      if k == 0 || keyed[k].key != keyed[k - 1].key { first = keyed[k].index }
      remap[Int(keyed[k].index)] = first
    }

    let diag = simd_length(hi - lo)
    let tiny = diag * diag * 1e-14
    var kept: [Int32] = []
    kept.reserveCapacity(tri.count)
    for t in stride(from: 0, to: tri.count, by: 3)
    {
      let a = remap[Int(tri[t])], b = remap[Int(tri[t + 1])], c = remap[Int(tri[t + 2])]
      guard a != b, b != c, a != c else { continue }

      let doubled = simd_length_squared(simd_cross(p[Int(b)] - p[Int(a)], p[Int(c)] - p[Int(a)]))
      guard doubled > tiny else { continue }

      kept += [a, b, c]
    }

    var index = [Int32](repeating: -1, count: p.count)
    var out: [V] = []
    out.reserveCapacity(p.count)
    for k in 0 ..< kept.count
    {
      let v = Int(kept[k])
      if index[v] < 0
      {
        index[v] = Int32(out.count)
        out.append(p[v])
      }

      kept[k] = index[v]
    }

    p = out
    tri = kept
  }

  /// keeps the part of the mesh on the positive side of a plane, splitting the triangles it crosses
  static func cut(_ p: inout [V], _ tri: inout [Int32], axis: Int, at plane: Float)
  {
    let lo = p.reduce(V(repeating: .infinity)) { simd_min($0, $1) }
    let hi = p.reduce(V(repeating: -.infinity)) { simd_max($0, $1) }
    let eps = (hi - lo).max() * 1e-6
    for i in p.indices where abs(p[i][axis] - plane) < eps { p[i][axis] = plane }

    var crossing: [UInt64: Int32] = [:]
    var out: [Int32] = []
    out.reserveCapacity(tri.count)

    func meet(_ a: Int32, _ b: Int32) -> Int32
    {
      let k = key(a, b)
      if let m = crossing[k] { return m }

      let pa = p[Int(a)], pb = p[Int(b)]
      let t = (plane - pa[axis]) / (pb[axis] - pa[axis])
      var x = pa + (pb - pa) * t
      x[axis] = plane
      p.append(x)
      crossing[k] = Int32(p.count - 1)
      return Int32(p.count - 1)
    }

    for t in stride(from: 0, to: tri.count, by: 3)
    {
      let v = [tri[t], tri[t + 1], tri[t + 2]]
      let d = v.map { p[Int($0)][axis] - plane }
      if d.allSatisfy({ $0 >= 0 })
      {
        out += v
        continue
      }

      if d.allSatisfy({ $0 <= 0 }) { continue }

      var poly: [Int32] = []
      for k in 0 ..< 3
      {
        let j = (k + 1) % 3
        if d[k] >= 0 { poly.append(v[k]) }
        if (d[k] > 0 && d[j] < 0) || (d[k] < 0 && d[j] > 0) { poly.append(meet(v[k], v[j])) }
      }

      guard poly.count >= 3 else { continue }

      for k in 1 ..< poly.count - 1 { out += [poly[0], poly[k], poly[k + 1]] }
    }

    tri = out
    weld(&p, &tri)
  }

  /// splits long edges until none is longer than `longest` so the fields have enough samples, dense sculpts pass through
  static func refine(_ p: inout [V], _ tri: inout [Int32], longest: Float, cap: Int)
  {
    let limit = longest * longest
    guard limit > 0, limit.isFinite else { return }

    for _ in 0 ..< 24
    {
      var mid: [UInt64: Int32] = [:]
      var added: [V] = []
      var touched = [Bool](repeating: false, count: tri.count / 3)
      for t in stride(from: 0, to: tri.count, by: 3)
      {
        for k in 0 ..< 3
        {
          let a = tri[t + k], b = tri[t + (k + 1) % 3]
          guard simd_length_squared(p[Int(a)] - p[Int(b)]) > limit else { continue }

          touched[t / 3] = true
          let e = key(a, b)
          if mid[e] == nil
          {
            mid[e] = Int32(p.count + added.count)
            added.append((p[Int(a)] + p[Int(b)]) * 0.5)
          }
        }
      }

      guard !added.isEmpty, p.count + added.count <= cap else { return }

      p += added
      var out: [Int32] = []
      out.reserveCapacity(tri.count * 2)
      for t in stride(from: 0, to: tri.count, by: 3)
      {
        guard touched[t / 3] else
        {
          out += [tri[t], tri[t + 1], tri[t + 2]]
          continue
        }

        var v = [tri[t], tri[t + 1], tri[t + 2]]
        var m = (0 ..< 3).map { mid[key(v[$0], v[($0 + 1) % 3])] }
        let marked = m.compactMap { $0 }.count

        // turn the triangle so its split edges come first
        var turns = 0
        while turns < 3, marked == 1 ? m[0] == nil : (marked == 2 ? (m[0] == nil || m[1] == nil) : false)
        {
          v = [v[1], v[2], v[0]]
          m = [m[1], m[2], m[0]]
          turns += 1
        }

        let a = v[0], b = v[1], c = v[2]
        switch marked
        {
          case 0:
            out += v
          case 1:
            let ab = m[0]!
            out += [a, ab, c, ab, b, c]
          case 2:
            let ab = m[0]!, bc = m[1]!
            out += [ab, b, bc]
            if simd_length_squared(p[Int(a)] - p[Int(bc)]) < simd_length_squared(p[Int(ab)] - p[Int(c)])
            {
              out += [a, ab, bc, a, bc, c]
            }
            else
            {
              out += [a, ab, c, ab, bc, c]
            }
          default:
            let ab = m[0]!, bc = m[1]!, ca = m[2]!
            out += [a, ab, ca, ab, b, bc, ca, bc, c, ab, bc, ca]
        }
      }

      tri = out
    }
  }

  /// the triangles the fields are laid out on, with the neighbors, normals and sharp edges of every vert
  struct Surface
  {
    var p: [V] = []
    var tri: [Int32] = []
    var n: [V] = []
    var area: [Float] = []
    var offset: [Int32] = []
    var nbr: [Int32] = []
    var triOffset: [Int32] = []
    var triOf: [Int32] = []

    /// 0 free, 1 on a line the grid has to follow, 2 a corner the grid has to pass through
    var kind: [UInt8] = []
    var dir: [V] = []

    /// bit 0 on a sharp edge, bit 1 on an open boundary
    var flags: [UInt8] = []

    /// the sharp and open edges around each vert
    var featureOffset: [Int32] = []
    var featureNbr: [Int32] = []

    var count: Int { p.count }

    init(_ points: [V], _ triangles: [Int32], sharpAngle: Float, edge: Float, guides: [[V]])
    {
      p = points
      tri = triangles
      let nv = p.count, nt = tri.count / 3

      // face normals and areas
      var fn = [V](repeating: .zero, count: nt)
      var fa = [Float](repeating: 0, count: nt)
      p.withUnsafeBufferPointer
      { pb in
        tri.withUnsafeBufferPointer
        { tb in
          fn.withUnsafeMutableBufferPointer
          { fnb in
            fa.withUnsafeMutableBufferPointer
            { fab in
              parallel(nt)
              { range in
                for t in range
                {
                  let a = pb[Int(tb[3 * t])], b = pb[Int(tb[3 * t + 1])], c = pb[Int(tb[3 * t + 2])]
                  let x = simd_cross(b - a, c - a)
                  let l = simd_length(x)
                  fab[t] = l * 0.5
                  fnb[t] = l > 0 ? x / l : .zero
                }
              }
            }
          }
        }
      }

      // triangles around each vert
      var tcount = [Int32](repeating: 0, count: nv + 1)
      for v in tri { tcount[Int(v) + 1] += 1 }
      for i in 0 ..< nv { tcount[i + 1] += tcount[i] }
      triOffset = tcount
      var fill = tcount
      triOf = [Int32](repeating: 0, count: tri.count)
      for t in 0 ..< nt
      {
        for k in 0 ..< 3
        {
          let v = Int(tri[3 * t + k])
          triOf[Int(fill[v])] = Int32(t)
          fill[v] += 1
        }
      }

      // vert normals and areas
      n = [V](repeating: .zero, count: nv)
      area = [Float](repeating: 0, count: nv)
      triOffset.withUnsafeBufferPointer
      { ob in
        triOf.withUnsafeBufferPointer
        { tb in
          n.withUnsafeMutableBufferPointer
          { nb in
            area.withUnsafeMutableBufferPointer
            { ab in
              parallel(nv)
              { range in
                for v in range
                {
                  var sum = V.zero, a: Float = 0
                  for k in Int(ob[v]) ..< Int(ob[v + 1])
                  {
                    let t = Int(tb[k])
                    sum += fn[t] * fa[t]
                    a += fa[t]
                  }

                  nb[v] = normalized(sum, V(0, 0, 1))
                  ab[v] = a / 3
                }
              }
            }
          }
        }
      }

      // edges, gathered by their lower vert, with the triangles on each side
      var hcount = [Int32](repeating: 0, count: nv + 1)
      for t in 0 ..< nt
      {
        for k in 0 ..< 3
        {
          let a = tri[3 * t + k], b = tri[3 * t + (k + 1) % 3]
          hcount[Int(min(a, b)) + 1] += 1
        }
      }

      for i in 0 ..< nv { hcount[i + 1] += hcount[i] }
      var hfill = hcount
      var hother = [Int32](repeating: 0, count: tri.count)
      var htri = [Int32](repeating: 0, count: tri.count)
      for t in 0 ..< nt
      {
        for k in 0 ..< 3
        {
          let a = tri[3 * t + k], b = tri[3 * t + (k + 1) % 3]
          let lo = Int(min(a, b))
          hother[Int(hfill[lo])] = max(a, b)
          htri[Int(hfill[lo])] = Int32(t)
          hfill[lo] += 1
        }
      }

      // unique edges per vert, and which of them are sharp or open
      let cosSharp = sharpAngle > 0 ? cos(sharpAngle * .pi / 180) : -2
      var ucount = [Int32](repeating: 0, count: nv + 1)
      var sharpCount = [Int32](repeating: 0, count: nv + 1)
      hcount.withUnsafeBufferPointer
      { hc in
        hother.withUnsafeMutableBufferPointer
        { ho in
          htri.withUnsafeMutableBufferPointer
          { ht in
            ucount.withUnsafeMutableBufferPointer
            { uc in
              sharpCount.withUnsafeMutableBufferPointer
              { sc in
                parallel(nv)
                { range in
                  for v in range
                  {
                    let lo = Int(hc[v]), hi = Int(hc[v + 1])

                    // sort the few entries by their other vert
                    if hi - lo > 1
                    {
                      for i in lo + 1 ..< hi
                      {
                        let o = ho[i], t = ht[i]
                        var j = i - 1
                        while j >= lo && ho[j] > o
                        {
                          ho[j + 1] = ho[j]
                          ht[j + 1] = ht[j]
                          j -= 1
                        }

                        ho[j + 1] = o
                        ht[j + 1] = t
                      }
                    }

                    var unique: Int32 = 0, sharp: Int32 = 0
                    var i = lo
                    while i < hi
                    {
                      var j = i + 1
                      while j < hi && ho[j] == ho[i] { j += 1 }
                      unique += 1
                      let uses = j - i
                      if uses != 2 || simd_dot(fn[Int(ht[i])], fn[Int(ht[i + 1])]) < cosSharp { sharp += 1 }
                      i = j
                    }

                    uc[v + 1] = unique
                    sc[v + 1] = sharp
                  }
                }
              }
            }
          }
        }
      }

      for i in 0 ..< nv
      {
        ucount[i + 1] += ucount[i]
        sharpCount[i + 1] += sharpCount[i]
      }

      let ne = Int(ucount[nv]), ns = Int(sharpCount[nv])
      var ea = [Int32](repeating: 0, count: ne), eb = [Int32](repeating: 0, count: ne)
      var sa = [Int32](repeating: 0, count: ns), sb = [Int32](repeating: 0, count: ns)
      var sopen = [Bool](repeating: false, count: ns)
      hcount.withUnsafeBufferPointer
      { hc in
        hother.withUnsafeBufferPointer
        { ho in
          htri.withUnsafeBufferPointer
          { ht in
            ea.withUnsafeMutableBufferPointer
            { eab in
              eb.withUnsafeMutableBufferPointer
              { ebb in
                sa.withUnsafeMutableBufferPointer
                { sab in
                  sb.withUnsafeMutableBufferPointer
                  { sbb in
                    sopen.withUnsafeMutableBufferPointer
                    { sob in
                      parallel(nv)
                      { range in
                        for v in range
                        {
                          var e = Int(ucount[v]), s = Int(sharpCount[v])
                          var i = Int(hc[v])
                          let hi = Int(hc[v + 1])
                          while i < hi
                          {
                            var j = i + 1
                            while j < hi && ho[j] == ho[i] { j += 1 }
                            eab[e] = Int32(v)
                            ebb[e] = ho[i]
                            e += 1
                            let uses = j - i
                            if uses != 2 || simd_dot(fn[Int(ht[i])], fn[Int(ht[i + 1])]) < cosSharp
                            {
                              sab[s] = Int32(v)
                              sbb[s] = ho[i]
                              sob[s] = uses != 2
                              s += 1
                            }

                            i = j
                          }
                        }
                      }
                    }
                  }
                }
              }
            }
          }
        }
      }

      (offset, nbr) = Self.csr(nv, ea, eb)

      // drop short sharp chains, they are noise on scans and sculpts rather than real edges
      var root = [Int32](0 ..< Int32(nv))
      func find(_ x: Int32) -> Int32
      {
        var x = x
        while root[Int(x)] != x
        {
          root[Int(x)] = root[Int(root[Int(x)])]
          x = root[Int(x)]
        }
        return x
      }

      for k in 0 ..< ns
      {
        let a = find(sa[k]), b = find(sb[k])
        if a != b { root[Int(max(a, b))] = min(a, b) }
      }

      var length = [Float](repeating: 0, count: nv)
      for k in 0 ..< ns { length[Int(find(sa[k]))] += simd_length(p[Int(sa[k])] - p[Int(sb[k])]) }
      let shortest = edge * 3
      var fa2: [Int32] = [], fb2: [Int32] = []
      flags = [UInt8](repeating: 0, count: nv)
      for k in 0 ..< ns where length[Int(find(sa[k]))] >= shortest
      {
        fa2.append(sa[k])
        fb2.append(sb[k])
        let bit: UInt8 = sopen[k] ? 3 : 1
        flags[Int(sa[k])] |= bit
        flags[Int(sb[k])] |= bit
      }

      (featureOffset, featureNbr) = Self.csr(nv, fa2, fb2)
      classify(edge: edge)
      if !guides.isEmpty { follow(guides, edge: edge) }
    }

    /// compressed neighbor lists from an edge list
    static func csr(_ nv: Int, _ a: [Int32], _ b: [Int32]) -> ([Int32], [Int32])
    {
      var offset = [Int32](repeating: 0, count: nv + 1)
      for k in a.indices
      {
        offset[Int(a[k]) + 1] += 1
        offset[Int(b[k]) + 1] += 1
      }

      for i in 0 ..< nv { offset[i + 1] += offset[i] }
      var fill = offset
      var nbr = [Int32](repeating: 0, count: Int(offset[nv]))
      for k in a.indices
      {
        nbr[Int(fill[Int(a[k])])] = b[k]
        fill[Int(a[k])] += 1
        nbr[Int(fill[Int(b[k])])] = a[k]
        fill[Int(b[k])] += 1
      }

      return (offset, nbr)
    }

    /// follows a sharp chain from v through w for about reach, stopping at forks and ends
    func walk(_ v: Int32, _ w: Int32, reach: Float) -> V
    {
      var prev = v, cur = w
      var travelled = simd_length(p[Int(w)] - p[Int(v)])
      for _ in 0 ..< 64
      {
        guard travelled < reach else { break }

        let lo = Int(featureOffset[Int(cur)]), hi = Int(featureOffset[Int(cur) + 1])
        guard hi - lo == 2 else { break }

        let next = featureNbr[lo] == prev ? featureNbr[lo + 1] : featureNbr[lo]
        travelled += simd_length(p[Int(next)] - p[Int(cur)])
        prev = cur
        cur = next
      }

      return p[Int(cur)]
    }

    /// marks every vert on a sharp chain as a line with its direction, or as a corner where chains meet or turn
    mutating func classify(edge: Float)
    {
      let nv = p.count
      kind = [UInt8](repeating: 0, count: nv)
      dir = [V](repeating: .zero, count: nv)
      var bend = [Float](repeating: -1, count: nv)
      let reach = edge * 0.5

      for v in 0 ..< nv
      {
        let lo = Int(featureOffset[v]), hi = Int(featureOffset[v + 1])
        switch hi - lo
        {
          case 0:
            continue
          case 1:
            kind[v] = 1
            dir[v] = walk(Int32(v), featureNbr[lo], reach: reach) - p[v]
          case 2:
            let a = normalized(walk(Int32(v), featureNbr[lo], reach: reach) - p[v], .zero)
            let b = normalized(walk(Int32(v), featureNbr[lo + 1], reach: reach) - p[v], .zero)
            bend[v] = simd_dot(a, b)
            kind[v] = 1
            dir[v] = a - b
          default:
            kind[v] = 2
        }
      }

      // a turn becomes a corner only where it is sharpest along its chain
      for v in 0 ..< nv where kind[v] == 1 && bend[v] > -0.5
      {
        let lo = Int(featureOffset[v]), hi = Int(featureOffset[v + 1])
        let sharpest = (lo ..< hi).allSatisfy { bend[Int(featureNbr[$0])] <= bend[v] }
        if sharpest { kind[v] = 2 }
      }

      for v in 0 ..< nv where kind[v] == 1
      {
        let d = normalized(tangent(dir[v], n[v]), .zero)
        if d == .zero { kind[v] = 2 } else { dir[v] = d }
      }
    }

    /// turns verts along the guide curves into lines the grid follows
    mutating func follow(_ guides: [[V]], edge: Float)
    {
      let cell = edge
      var grid: [SIMD3<Int32>: [Int32]] = [:]
      for v in 0 ..< p.count
      {
        let g = SIMD3<Int32>((p[v] / cell).rounded(.down))
        grid[g, default: []].append(Int32(v))
      }

      for curve in guides where curve.count >= 2
      {
        for k in 0 ..< curve.count - 1
        {
          let a = curve[k], b = curve[k + 1]
          let along = normalized(b - a, .zero)
          guard along != .zero else { continue }

          let steps = max(Int(simd_length(b - a) / (edge * 0.25)), 1)
          for s in 0 ... steps
          {
            let x = a + (b - a) * (Float(s) / Float(steps))
            let g = SIMD3<Int32>((x / cell).rounded(.down))
            var best: Int32 = -1, bestDistance = Float.infinity
            for dz in -1 ... 1
            {
              for dy in -1 ... 1
              {
                for dx in -1 ... 1
                {
                  for v in grid[g &+ SIMD3(Int32(dx), Int32(dy), Int32(dz))] ?? []
                  {
                    let d = simd_length_squared(p[Int(v)] - x)
                    if d < bestDistance
                    {
                      bestDistance = d
                      best = v
                    }
                  }
                }
              }
            }

            guard best >= 0, kind[Int(best)] == 0, bestDistance < edge * edge else { continue }

            let d = normalized(tangent(along, n[Int(best)]), .zero)
            if d != .zero
            {
              kind[Int(best)] = 1
              dir[Int(best)] = d
            }
          }
        }
      }
    }

    /// the vert nearest `x` found by walking downhill over the surface, staying on the same side of thin parts
    func nearest(_ start: Int32, _ x: V) -> Int32
    {
      var v = Int(start)
      var best = simd_length_squared(p[v] - x)
      for _ in 0 ..< 512
      {
        var next = v
        for k in Int(offset[v]) ..< Int(offset[v + 1])
        {
          let j = Int(nbr[k])
          let d = simd_length_squared(p[j] - x)
          if d < best
          {
            best = d
            next = j
          }
        }

        if next == v { break }
        v = next
      }

      return Int32(v)
    }

    /// x pulled onto the triangles around v, with the smooth normal there
    func project(_ x: V, near v: Int32) -> (V, V)
    {
      var best = p[Int(v)], normal = n[Int(v)], distance = simd_length_squared(best - x)
      for k in Int(triOffset[Int(v)]) ..< Int(triOffset[Int(v) + 1])
      {
        let t = Int(triOf[k])
        let a = Int(tri[3 * t]), b = Int(tri[3 * t + 1]), c = Int(tri[3 * t + 2])
        let (q, w) = closest(x, p[a], p[b], p[c])
        let d = simd_length_squared(q - x)
        if d < distance
        {
          distance = d
          best = q
          normal = normalized(n[a] * w.x + n[b] * w.y + n[c] * w.z, n[Int(v)])
        }
      }

      return (best, normal)
    }

    /// the nearest sharp vert to v within a few rings, or -1
    func nearestFeature(_ v: Int32, _ x: V) -> Int32
    {
      if flags[Int(v)] != 0 { return v }

      var ring: [Int32] = [v], seen: Set<Int32> = [v]
      for _ in 0 ..< 4
      {
        var next: [Int32] = []
        var best: Int32 = -1, distance = Float.infinity
        for u in ring
        {
          for k in Int(offset[Int(u)]) ..< Int(offset[Int(u) + 1])
          {
            let j = nbr[k]
            guard seen.insert(j).inserted else { continue }

            next.append(j)
            if flags[Int(j)] != 0
            {
              let d = simd_length_squared(p[Int(j)] - x)
              if d < distance
              {
                distance = d
                best = j
              }
            }
          }
        }

        if best >= 0 { return best }
        ring = next
      }

      return -1
    }

    /// x pulled onto the sharp chain through f, walking along it first
    func projectFeature(_ x: V, from f: Int32) -> (V, Int32)
    {
      var v = Int(f)
      var best = simd_length_squared(p[v] - x)
      for _ in 0 ..< 256
      {
        var next = v
        for k in Int(featureOffset[v]) ..< Int(featureOffset[v + 1])
        {
          let j = Int(featureNbr[k])
          let d = simd_length_squared(p[j] - x)
          if d < best
          {
            best = d
            next = j
          }
        }

        if next == v { break }
        v = next
      }

      var q = p[v], distance = best
      for k in Int(featureOffset[v]) ..< Int(featureOffset[v + 1])
      {
        let c = closest(x, p[v], p[Int(featureNbr[k])])
        let d = simd_length_squared(c - x)
        if d < distance
        {
          distance = d
          q = c
        }
      }

      return (q, Int32(v))
    }
  }
}
