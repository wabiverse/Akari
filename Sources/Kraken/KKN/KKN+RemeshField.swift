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

import Dispatch
import Foundation
import simd

extension Kraken.Remesh
{
  /// one level of the multiresolution graph the orientation and position fields are smoothed on
  final class Level
  {
    var count: Int
    var p: [V]
    var n: [V]
    var area: [Float]
    var offset: [Int32] = []
    var nbr: [Int32] = []

    /// the finer verts merged into each vert here, the second is -1 when one was left alone
    var child0: [Int32] = []
    var child1: [Int32] = []

    /// the coarser vert each vert here was merged into
    var parent: [Int32] = []

    var kind: [UInt8]
    var dir: [V]
    var anchor: [V]
    var flags: [UInt8]

    /// a vert on the finest level under each vert, where walks over the input start
    var root: [Int32]

    /// the cross field direction and the nearest grid point of the position field
    var q: [V] = []
    var o: [V] = []

    /// the direction the surface bends most, and how much to trust it
    var bend: [SIMD4<Float>] = []

    /// verts grouped so no two in a group are neighbors, which lets each group be smoothed in parallel
    var colors: [[Int32]] = []
    var spacing: Float = 0

    init(count: Int, p: [V], n: [V], area: [Float], kind: [UInt8], dir: [V], anchor: [V], flags: [UInt8], root: [Int32])
    {
      self.count = count
      self.p = p
      self.n = n
      self.area = area
      self.kind = kind
      self.dir = dir
      self.anchor = anchor
      self.flags = flags
      self.root = root
    }

    /// mean edge length
    func measure()
    {
      var sums = [Double](repeating: 0, count: 64)
      var counts = [Int](repeating: 0, count: 64)
      let chunk = max((count + 63) / 64, 1)
      sums.withUnsafeMutableBufferPointer
      { sb in
        counts.withUnsafeMutableBufferPointer
        { cb in
          DispatchQueue.concurrentPerform(iterations: 64)
          { c in
            var s: Double = 0, k = 0
            for i in min(c * chunk, count) ..< min(count, (c + 1) * chunk)
            {
              for e in Int(offset[i]) ..< Int(offset[i + 1])
              {
                s += Double(simd_length(p[i] - p[Int(nbr[e])]))
                k += 1
              }
            }

            sb[c] = s
            cb[c] = k
          }
        }
      }

      let k = counts.reduce(0, +)
      spacing = k > 0 ? Float(sums.reduce(0, +) / Double(k)) : 0
    }

    /// greedy coloring, the verts that would need more than 63 colors go in a last group smoothed in order
    func color()
    {
      var c = [UInt8](repeating: 255, count: count)
      var groups = [[Int32]](repeating: [], count: 64)
      for i in 0 ..< count
      {
        var used: UInt64 = 0
        for e in Int(offset[i]) ..< Int(offset[i + 1])
        {
          let k = c[Int(nbr[e])]
          if k < 64 { used |= 1 << UInt64(k) }
        }

        let free = (~used).trailingZeroBitCount
        let k = min(free, 63)
        c[i] = UInt8(k)
        groups[k].append(Int32(i))
      }

      colors = groups.filter { !$0.isEmpty }
    }
  }

  /// builds coarser and coarser levels by merging neighbors with matching normals
  static func hierarchy(_ s: Surface, scale: Float, clock: Clock) -> [Level]
  {
    let base = Level(count: s.count, p: s.p, n: s.n, area: s.area, kind: s.kind, dir: s.dir, anchor: s.p, flags: s.flags,
                     root: Array(0 ..< Int32(s.count)))
    base.offset = s.offset
    base.nbr = s.nbr
    base.measure()
    var levels = [base]

    while levels.count < 30, let last = levels.last, last.count > 48
    {
      let next = coarsen(last, near: scale * 0.25)
      guard Double(next.count) < Double(last.count) * 0.97 else { break }

      next.measure()
      levels.append(next)
      if ProcessInfo.processInfo.environment["REMESH_DEBUG"] != nil { print("  level", levels.count - 1, next.count, next.spacing) }
    }

    return levels
  }

  static func coarsen(_ f: Level, near: Float) -> Level
  {
    let n = f.count
    var mate = [Int32](repeating: -1, count: n)
    var proposal = [Int32](repeating: -1, count: n)

    // a few rounds of mutual proposals give a matching without any locks
    for _ in 0 ..< 10
    {
      mate.withUnsafeMutableBufferPointer
      { mb in
        proposal.withUnsafeMutableBufferPointer
        { pb in
          parallel(n)
          { range in
            for i in range
            {
              pb[i] = -1
              guard mb[i] < 0 else { continue }

              var best: Int32 = -1, score = -Float.infinity
              for e in Int(f.offset[i]) ..< Int(f.offset[i + 1])
              {
                let j = Int(f.nbr[e])
                guard j != i, mb[j] < 0 else { continue }

                let d = simd_dot(f.n[i], f.n[j])
                guard d > 0 else { continue }

                // the same score seen from both ends, with a tiny hash so ties break the same way too
                let lo = UInt32(min(i, j)), hi = UInt32(max(i, j))
                var h = lo &* 0x9e37_79b1 ^ hi &* 0x85eb_ca6b
                h ^= h >> 15
                let s = d / max(f.area[i] + f.area[j], 1e-30) * (1 + Float(h & 0xffff) * 1e-7)
                if s > score
                {
                  score = s
                  best = Int32(j)
                }
              }

              pb[i] = best
            }
          }

          parallel(n)
          { range in
            for i in range where pb[i] >= 0 && pb[Int(pb[i])] == Int32(i)
            {
              mb[i] = pb[i]
            }
          }
        }
      }
    }

    var parent = [Int32](repeating: -1, count: n)
    var c0: [Int32] = [], c1: [Int32] = []
    c0.reserveCapacity(n / 2 + 1)
    c1.reserveCapacity(n / 2 + 1)
    for i in 0 ..< n where parent[i] < 0
    {
      let id = Int32(c0.count)
      parent[i] = id
      c0.append(Int32(i))
      let m = mate[i]
      if m >= 0
      {
        parent[Int(m)] = id
        c1.append(m)
      }
      else
      {
        c1.append(-1)
      }
    }

    f.parent = parent
    let m = c0.count
    var p = [V](repeating: .zero, count: m), nn = [V](repeating: .zero, count: m)
    var area = [Float](repeating: 0, count: m)
    var kind = [UInt8](repeating: 0, count: m), dir = [V](repeating: .zero, count: m)
    var anchor = [V](repeating: .zero, count: m), flags = [UInt8](repeating: 0, count: m)
    var root = [Int32](repeating: 0, count: m)

    p.withUnsafeMutableBufferPointer
    { pb in
      nn.withUnsafeMutableBufferPointer
      { nb in
        area.withUnsafeMutableBufferPointer
        { ab in
          kind.withUnsafeMutableBufferPointer
          { kb in
            dir.withUnsafeMutableBufferPointer
            { db in
              anchor.withUnsafeMutableBufferPointer
              { anb in
                flags.withUnsafeMutableBufferPointer
                { fb in
                  root.withUnsafeMutableBufferPointer
                  { rb in
                    parallel(m)
                    { range in
                      for c in range
                      {
                        let a = Int(c0[c]), b = Int(c1[c])
                        rb[c] = f.root[a]
                        guard b >= 0 else
                        {
                          pb[c] = f.p[a]
                          nb[c] = f.n[a]
                          ab[c] = f.area[a]
                          kb[c] = f.kind[a]
                          db[c] = f.dir[a]
                          anb[c] = f.anchor[a]
                          fb[c] = f.flags[a]
                          continue
                        }

                        let wa = max(f.area[a], 1e-30), wb = max(f.area[b], 1e-30)
                        ab[c] = f.area[a] + f.area[b]
                        pb[c] = (f.p[a] * wa + f.p[b] * wb) / (wa + wb)
                        nb[c] = normalized(f.n[a] * wa + f.n[b] * wb, f.n[a])
                        fb[c] = f.flags[a] | f.flags[b]

                        // constraints that disagree at this scale are dropped here, the finer levels still hold them
                        let ka = f.kind[a], kb2 = f.kind[b]
                        let apart = simd_length(f.anchor[a] - f.anchor[b]) > near
                        if ka == 2 && kb2 == 2
                        {
                          kb[c] = apart ? 0 : 2
                          anb[c] = (f.anchor[a] + f.anchor[b]) * 0.5
                        }
                        else if ka == 2 || kb2 == 2
                        {
                          kb[c] = 2
                          anb[c] = ka == 2 ? f.anchor[a] : f.anchor[b]
                        }
                        else if ka == 1 && kb2 == 1
                        {
                          let d = simd_dot(f.dir[a], f.dir[b])
                          anb[c] = (f.anchor[a] + f.anchor[b]) * 0.5
                          let across = simd_length(tangent(f.anchor[b] - f.anchor[a], normalized(f.dir[a], V(1, 0, 0))))
                          if abs(d) > 0.9 && across < near
                          {
                            kb[c] = 1
                            db[c] = normalized(tangent(f.dir[a] + (d < 0 ? -f.dir[b] : f.dir[b]), nb[c]), f.dir[a])
                          }
                          else
                          {
                            kb[c] = abs(d) <= 0.9 && !apart ? 2 : 0
                          }
                        }
                        else if ka == 1 || kb2 == 1
                        {
                          let s = ka == 1 ? a : b
                          kb[c] = 1
                          db[c] = normalized(tangent(f.dir[s], nb[c]), f.dir[s])
                          anb[c] = f.anchor[s]
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

    // neighbors of the merged verts, without repeats
    var bound = [Int32](repeating: 0, count: m + 1)
    for c in 0 ..< m
    {
      let a = Int(c0[c]), b = Int(c1[c])
      var d = f.offset[a + 1] - f.offset[a]
      if b >= 0 { d += f.offset[b + 1] - f.offset[b] }
      bound[c + 1] = bound[c] + d
    }

    var scratch = [Int32](repeating: 0, count: Int(bound[m]))
    var degree = [Int32](repeating: 0, count: m + 1)
    scratch.withUnsafeMutableBufferPointer
    { sb in
      degree.withUnsafeMutableBufferPointer
      { db in
        parallel(m)
        { range in
          for c in range
          {
            let start = Int(bound[c])
            var k = start
            for child in [c0[c], c1[c]] where child >= 0
            {
              for e in Int(f.offset[Int(child)]) ..< Int(f.offset[Int(child) + 1])
              {
                let pc = parent[Int(f.nbr[e])]
                if pc != Int32(c)
                {
                  sb[k] = pc
                  k += 1
                }
              }
            }

            // sort and drop repeats in place
            if k - start > 1
            {
              for i in start + 1 ..< k
              {
                let x = sb[i]
                var j = i - 1
                while j >= start && sb[j] > x
                {
                  sb[j + 1] = sb[j]
                  j -= 1
                }

                sb[j + 1] = x
              }
            }

            var w = start
            for i in start ..< k where i == start || sb[i] != sb[i - 1]
            {
              sb[w] = sb[i]
              w += 1
            }

            db[c + 1] = Int32(w - start)
          }
        }
      }
    }

    for c in 0 ..< m { degree[c + 1] += degree[c] }
    var nbr = [Int32](repeating: 0, count: Int(degree[m]))
    nbr.withUnsafeMutableBufferPointer
    { nb in
      parallel(m)
      { range in
        for c in range
        {
          let from = Int(bound[c]), to = Int(degree[c]), k = Int(degree[c + 1] - degree[c])
          for i in 0 ..< k { nb[to + i] = scratch[from + i] }
        }
      }
    }

    let level = Level(count: m, p: p, n: nn, area: area, kind: kind, dir: dir, anchor: anchor, flags: flags, root: root)
    level.offset = degree
    level.nbr = nbr
    level.child0 = c0
    level.child1 = c1
    return level
  }

  // MARK: orientation field

  /// the representatives of two crosses that line up best
  @inline(__always) static func compatOrientation(_ q0: V, _ n0: V, _ q1: V, _ n1: V) -> (V, V)
  {
    let a1 = simd_cross(n0, q0), b1 = simd_cross(n1, q1)
    let d00 = simd_dot(q0, q1), d01 = simd_dot(q0, b1), d10 = simd_dot(a1, q1), d11 = simd_dot(a1, b1)
    var best = abs(d00), a = q0, b = q1, d = d00
    if abs(d01) > best + 1e-6
    {
      best = abs(d01)
      b = b1
      d = d01
    }

    if abs(d10) > best + 1e-6
    {
      best = abs(d10)
      a = a1
      b = q1
      d = d10
    }

    if abs(d11) > best + 1e-6
    {
      a = a1
      b = b1
      d = d11
    }

    return (a, d < 0 ? -b : b)
  }

  /// the representative of q1's cross closest to q0
  @inline(__always) static func align(_ q0: V, _ q1: V, _ n1: V) -> V
  {
    let t1 = simd_cross(n1, q1)
    let a = simd_dot(q0, q1), b = simd_dot(q0, t1)
    if abs(a) >= abs(b) { return a >= 0 ? q1 : -q1 }
    return b >= 0 ? t1 : -t1
  }

  /// principal bend direction per vert from how the normals turn across its edges, smoothed a little
  static func bends(_ l: Level, scale: Float)
  {
    var bend = [SIMD4<Float>](repeating: .zero, count: l.count)
    bend.withUnsafeMutableBufferPointer
    { bb in
      parallel(l.count)
      { range in
        for i in range
        {
          let n = l.n[i]
          let x = perpendicular(n), y = simd_cross(n, x)
          var a00: Float = 0, a01: Float = 0, a11: Float = 0
          var b00: Float = 0, b01: Float = 0, b10: Float = 0, b11: Float = 0
          for e in Int(l.offset[i]) ..< Int(l.offset[i + 1])
          {
            let j = Int(l.nbr[e])
            let d = l.p[j] - l.p[i], dn = l.n[j] - n
            let ex = simd_dot(d, x), ey = simd_dot(d, y), nx = simd_dot(dn, x), ny = simd_dot(dn, y)
            a00 += ex * ex
            a01 += ex * ey
            a11 += ey * ey
            b00 += nx * ex
            b01 += nx * ey
            b10 += ny * ex
            b11 += ny * ey
          }

          let det = a00 * a11 - a01 * a01
          guard det > 1e-30 else { continue }

          // the shape operator b times inverse a, made symmetric
          let i00 = a11 / det, i01 = -a01 / det, i11 = a00 / det
          let s00 = b00 * i00 + b01 * i01, s01 = b00 * i01 + b01 * i11
          let s10 = b10 * i00 + b11 * i01, s11 = b10 * i01 + b11 * i11
          let sxy = (s01 + s10) * 0.5
          let split = ((s00 - s11) * (s00 - s11) + 4 * sxy * sxy).squareRoot()
          let mean = abs(s00 + s11)
          let angle = 0.5 * atan2(2 * sxy, s00 - s11)
          let d = x * cos(angle) + y * sin(angle)

          let strength = simd_clamp((split * scale - 0.04) / 0.25, 0, 1)
          let anisotropy = simd_clamp(split / max(mean + split, 1e-20) * 2 - 0.3, 0, 1)
          let trust = strength * anisotropy
          guard trust.isFinite else { continue }

          bb[i] = SIMD4(d, trust)
        }
      }
    }

    // two passes of trust weighted cross averaging calm the noise
    for _ in 0 ..< 2
    {
      var next = bend
      next.withUnsafeMutableBufferPointer
      { nb in
        parallel(l.count)
        { range in
          for i in range
          {
            let n = l.n[i]
            var sum = V.zero, w: Float = 0
            let own = bend[i]
            var reference = V(own.x, own.y, own.z)
            if own.w > 0
            {
              sum = reference * own.w
              w = own.w
            }

            for e in Int(l.offset[i]) ..< Int(l.offset[i + 1])
            {
              let b = bend[Int(l.nbr[e])]
              guard b.w > 0 else { continue }

              let d = V(b.x, b.y, b.z)
              if w == 0 { reference = tangent(d, n) }
              sum += align(reference, d, l.n[Int(l.nbr[e])]) * b.w
              w += b.w
            }

            let degree = Float(l.offset[i + 1] - l.offset[i] + 1)
            let d = normalized(tangent(sum, n), .zero)
            nb[i] = d == .zero ? .zero : SIMD4(d, simd_length(sum) / degree)
          }
        }
      }

      bend = next
    }

    l.bend = bend
  }

  /// solves the cross field from the coarsest level down to the one the grid is pulled from
  static func orient(_ levels: [Level], bottom: Int, scale: Float, curvature: Float, clock: Clock)
  {
    let top = levels.count - 1
    for li in stride(from: top, through: bottom, by: -1)
    {
      let l = levels[li]
      if li == top
      {
        l.q = (0 ..< l.count).map { l.kind[$0] == 1 ? l.dir[$0] : perpendicular(l.n[$0]) }
      }
      else
      {
        let up = levels[li + 1]
        l.q = (0 ..< l.count).map
        { i in
          if l.kind[i] == 1 { return l.dir[i] }
          let q = up.q[Int(l.parent[i])]
          return normalized(tangent(q, l.n[i]), perpendicular(l.n[i]))
        }
      }

      // bends are read at the scale of the result, finer levels only see noise, so they inherit them
      if curvature > 0
      {
        if l.spacing >= scale * 0.6 || li == top
        {
          bends(l, scale: scale)
        }
        else
        {
          let up = levels[li + 1]
          l.bend = (0 ..< l.count).map
          { i in
            let b = up.bend[Int(l.parent[i])]
            let d = normalized(tangent(V(b.x, b.y, b.z), l.n[i]), .zero)
            return d == .zero ? .zero : SIMD4(d, b.w)
          }
        }
      }
      l.color()
      let iterations = l.count < 200_000 ? 24 : 12
      for it in 0 ..< iterations
      {
        if it > 2 && clock.over(0.4) { break }
        smoothOrientation(l, curvature: curvature)
      }
    }
  }

  static func smoothOrientation(_ l: Level, curvature: Float)
  {
    let useBend = curvature > 0 && l.bend.count == l.count
    l.q.withUnsafeMutableBufferPointer
    { buffer in
      let qb = buffer
      for (gi, group) in l.colors.enumerated()
      {
        let serial = gi == l.colors.count - 1 && group.count > 0 && l.colorsOverflow
        let body: (Range<Int>) -> Void =
        { range in
          for g in range
          {
            let i = Int(group[g])
            if l.kind[i] == 1
            {
              qb[i] = l.dir[i]
              continue
            }

            let n = l.n[i]
            var sum = qb[i], w: Float = 0
            for e in Int(l.offset[i]) ..< Int(l.offset[i + 1])
            {
              let j = Int(l.nbr[e])
              let (a, b) = compatOrientation(sum, n, qb[j], l.n[j])
              sum = tangent(a * w + b, n)
              w += 1
              sum = normalized(sum, a)
            }

            if useBend
            {
              let bend = l.bend[i]
              if bend.w > 0
              {
                let (a, b) = compatOrientation(sum, n, V(bend.x, bend.y, bend.z), n)
                sum = normalized(tangent(a * w + b * (bend.w * curvature * max(w, 1)), n), a)
              }
            }

            qb[i] = sum
          }
        }

        if serial { body(0 ..< group.count) } else { parallel(group.count, grain: 1024, body) }
      }
    }
  }

  // MARK: position field

  /// the point between two surface samples where their tangent planes meet best
  @inline(__always) static func middle(_ p0: V, _ n0: V, _ p1: V, _ n1: V) -> V
  {
    let n0p0 = simd_dot(n0, p0), n0p1 = simd_dot(n0, p1), n1p0 = simd_dot(n1, p0), n1p1 = simd_dot(n1, p1)
    let n0n1 = simd_dot(n0, n1)
    let denom = 1 / (1 - n0n1 * n0n1 + 1e-4)
    let l0 = 2 * (n0p1 - n0p0 - n0n1 * (n1p0 - n1p1)) * denom
    let l1 = 2 * (n1p0 - n1p1 - n0n1 * (n0p1 - n0p0)) * denom
    return 0.5 * (p0 + p1) - 0.25 * (n0 * l0 + n1 * l1)
  }

  @inline(__always) static func roundGrid(_ o: V, _ q: V, _ t: V, _ p: V, _ s: Float, _ inv: Float) -> V
  {
    let d = p - o
    return o + q * ((simd_dot(q, d) * inv).rounded() * s) + t * ((simd_dot(t, d) * inv).rounded() * s)
  }

  /// the grid points of two verts' lattices that land closest together, with their steps from each vert's own point
  @inline(__always) static func compatPosition(_ p0: V, _ n0: V, _ q0: V, _ o0: V, _ p1: V, _ n1: V, _ q1: V, _ o1: V,
                                               _ s: Float, _ inv: Float) -> (V, V, SIMD2<Int32>, SIMD2<Int32>, Float)
  {
    let t0 = simd_cross(n0, q0), t1 = simd_cross(n1, q1)
    let m = middle(p0, n0, p1, n1)
    let d0 = m - o0, d1 = m - o1
    let i0 = SIMD2<Float>((simd_dot(q0, d0) * inv).rounded(.down), (simd_dot(t0, d0) * inv).rounded(.down))
    let i1 = SIMD2<Float>((simd_dot(q1, d1) * inv).rounded(.down), (simd_dot(t1, d1) * inv).rounded(.down))
    let base0 = o0 + q0 * (i0.x * s) + t0 * (i0.y * s)
    let base1 = o1 + q1 * (i1.x * s) + t1 * (i1.y * s)

    var best = Float.infinity, bi = 0, bj = 0
    for i in 0 ..< 4
    {
      let a = base0 + q0 * (Float(i & 1) * s) + t0 * (Float(i >> 1) * s)
      for j in 0 ..< 4
      {
        let b = base1 + q1 * (Float(j & 1) * s) + t1 * (Float(j >> 1) * s)
        let d = simd_length_squared(a - b)
        if d < best
        {
          best = d
          bi = i
          bj = j
        }
      }
    }

    let a = base0 + q0 * (Float(bi & 1) * s) + t0 * (Float(bi >> 1) * s)
    let b = base1 + q1 * (Float(bj & 1) * s) + t1 * (Float(bj >> 1) * s)
    let s0 = SIMD2<Int32>(Int32(i0.x) + Int32(bi & 1), Int32(i0.y) + Int32(bi >> 1))
    let s1 = SIMD2<Int32>(Int32(i1.x) + Int32(bj & 1), Int32(i1.y) + Int32(bj >> 1))
    return (a, b, s0, s1, best)
  }

  @inline(__always) static func constrain(_ o: V, _ l: Level, _ i: Int) -> V
  {
    switch l.kind[i]
    {
      case 1:
        let u = simd_cross(l.n[i], l.dir[i])
        return o - u * simd_dot(o - l.anchor[i], u)
      case 2:
        return l.anchor[i]
      default:
        return o
    }
  }

  /// solves the position field from the coarsest level down to the one the grid is pulled from
  static func position(_ levels: [Level], bottom: Int, scale: Float, clock: Clock)
  {
    let top = levels.count - 1
    let inv = 1 / scale

    // carry the finished cross field back up so every level agrees with the one it is pulled from
    if bottom < top
    {
      for li in bottom + 1 ... top
      {
        let l = levels[li], down = levels[li - 1]
        l.q = (0 ..< l.count).map
        { c in
          if l.kind[c] == 1 { return l.dir[c] }
          return normalized(tangent(down.q[Int(l.child0[c])], l.n[c]), perpendicular(l.n[c]))
        }
      }
    }

    for li in stride(from: top, through: bottom, by: -1)
    {
      let l = levels[li]
      if li == top
      {
        l.o = (0 ..< l.count).map { constrain(l.p[$0], l, $0) }
      }
      else
      {
        let up = levels[li + 1]
        l.o = (0 ..< l.count).map
        { i in
          let n = l.n[i], q = l.q[i]
          var o = up.o[Int(l.parent[i])]
          o -= n * simd_dot(n, o - l.p[i])
          o = roundGrid(o, q, simd_cross(n, q), l.p[i], scale, inv)
          return constrain(o, l, i)
        }
      }

      let iterations = l.count < 200_000 ? 16 : 10
      for it in 0 ..< iterations
      {
        if it > 2 && clock.over(0.75) { break }
        smoothPosition(l, scale: scale)
      }
    }
  }

  static func smoothPosition(_ l: Level, scale: Float)
  {
    let inv = 1 / scale
    l.o.withUnsafeMutableBufferPointer
    { buffer in
      let ob = buffer
      for (gi, group) in l.colors.enumerated()
      {
        let serial = gi == l.colors.count - 1 && l.colorsOverflow
        let body: (Range<Int>) -> Void =
        { range in
          for g in range
          {
            let i = Int(group[g])
            if l.kind[i] == 2
            {
              ob[i] = l.anchor[i]
              continue
            }

            let p = l.p[i], n = l.n[i], q = l.q[i]
            var sum = ob[i], w: Float = 0
            for e in Int(l.offset[i]) ..< Int(l.offset[i + 1])
            {
              let j = Int(l.nbr[e])
              let (a, b, _, _, _) = compatPosition(p, n, q, sum, l.p[j], l.n[j], l.q[j], ob[j], scale, inv)
              sum = (a * w + b) / (w + 1)
              w += 1
              sum -= n * simd_dot(n, sum - p)
            }

            sum = roundGrid(sum, q, simd_cross(n, q), p, scale, inv)
            ob[i] = constrain(sum, l, i)
          }
        }

        if serial { body(0 ..< group.count) } else { parallel(group.count, grain: 1024, body) }
      }
    }
  }
}

extension Kraken.Remesh.Level
{
  /// whether the last color group holds the verts that ran out of colors
  var colorsOverflow: Bool { colors.count == 64 }
}
