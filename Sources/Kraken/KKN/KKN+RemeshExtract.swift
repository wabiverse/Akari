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
  /// the polygon mesh pulled out of the fields, with where each vert sits on the input
  struct Mesh
  {
    var p: [V] = []
    var n: [V] = []

    /// the cross field direction at each vert, while the grid steps are still being fixed
    var q: [V] = []

    /// bit 0 near a sharp edge, bit 1 near an open boundary, bit 2 pinned to a corner
    var flags: [UInt8] = []

    /// a vert of the input near each vert, where walks over the surface start
    var root: [Int32] = []
    var counts: [Int32] = []
    var indices: [Int32] = []

    var faceCount: Int { counts.count }

    func faces() -> [[Int32]]
    {
      var out: [[Int32]] = []
      out.reserveCapacity(counts.count)
      var at = 0
      for c in counts
      {
        out.append(Array(indices[at ..< at + Int(c)]))
        at += Int(c)
      }
      return out
    }

    mutating func set(_ faces: [[Int32]])
    {
      counts = faces.map { Int32($0.count) }
      indices = faces.flatMap { $0 }
    }
  }

  /// pulls the quad dominant mesh out of the position field, merging agreeing verts, linking grid neighbors and tracing faces
  static func extract(_ levels: [Level], bottom: Int, scale: Float, surface: Surface) -> Mesh
  {
    let l = levels[bottom]
    let n = l.count
    let inv = 1 / scale

    // sort every edge into a merge, a grid edge, or nothing
    struct Merge
    {
      var error: Float
      var a: Int32
      var b: Int32
    }

    let chunks = max(min(n / 2048, 256), 1)
    let size = (n + chunks - 1) / chunks
    var merges = [[Merge]](repeating: [], count: chunks)
    var links = [[SIMD2<Int32>]](repeating: [], count: chunks)
    merges.withUnsafeMutableBufferPointer
    { mb in
      links.withUnsafeMutableBufferPointer
      { lb in
        DispatchQueue.concurrentPerform(iterations: chunks)
        { c in
          var m: [Merge] = [], k: [SIMD2<Int32>] = []
          for i in c * size ..< min(n, (c + 1) * size)
          {
            for e in Int(l.offset[i]) ..< Int(l.offset[i + 1])
            {
              let j = Int(l.nbr[e])
              guard j > i else { continue }

              let qj = align(l.q[i], l.q[j], l.n[j])
              let (_, _, si, sj, error) = compatPosition(l.p[i], l.n[i], l.q[i], l.o[i], l.p[j], l.n[j], qj, l.o[j], scale, inv)
              let d = si &- sj
              let ad = SIMD2<Int32>(abs(d.x), abs(d.y))
              if ad.x > 1 || ad.y > 1 || (ad.x == 1 && ad.y == 1) { continue }

              if ad.x == 0 && ad.y == 0
              {
                m.append(Merge(error: error, a: Int32(i), b: Int32(j)))
              }
              else
              {
                k.append(SIMD2(Int32(i), Int32(j)))
              }
            }
          }

          mb[c] = m
          lb[c] = k
        }
      }
    }

    if ProcessInfo.processInfo.environment["REMESH_DEBUG"] != nil
    {
      var errs: [Float] = []
      for i in 0 ..< n
      {
        for e in Int(l.offset[i]) ..< Int(l.offset[i + 1])
        {
          let j = Int(l.nbr[e])
          guard j > i else { continue }
          let qj = align(l.q[i], l.q[j], l.n[j])
          let (_, _, _, _, error) = compatPosition(l.p[i], l.n[i], l.q[i], l.o[i], l.p[j], l.n[j], qj, l.o[j], scale, inv)
          errs.append(error.squareRoot() / scale)
        }
      }
      errs.sort()
      let pct = [0.5, 0.9, 0.95, 0.99].map { errs[Int(Double(errs.count - 1) * $0)] }
      print("  field error pct", pct, "merges", merges.reduce(0) { $0 + $1.count }, "links", links.reduce(0) { $0 + $1.count }, "edges", errs.count)
    }

    // merge verts that share a grid point, cheapest first, never letting a cluster drift off its point
    var all = merges.flatMap { $0 }
    all.sort { $0.error < $1.error }
    var root = [Int32](0 ..< Int32(n))
    var sum = l.o.map { SIMD4<Float>($0, 1) }
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

    let drift = scale * scale * 4.0
    for m in all
    {
      let a = find(m.a), b = find(m.b)
      guard a != b else { continue }

      let sa = sum[Int(a)], sb = sum[Int(b)]
      let ca = V(sa.x, sa.y, sa.z) / sa.w, cb = V(sb.x, sb.y, sb.z) / sb.w
      guard simd_length_squared(ca - cb) < drift else { continue }

      let (keep, drop) = sa.w >= sb.w ? (a, b) : (b, a)
      root[Int(drop)] = keep
      sum[Int(keep)] = sa + sb
    }

    var id = [Int32](repeating: -1, count: n)
    var mesh = Mesh()
    var normalSum: [V] = []
    for i in 0 ..< n
    {
      let r = Int(find(Int32(i)))
      if id[r] < 0
      {
        id[r] = Int32(mesh.p.count)
        let s = sum[r]
        mesh.p.append(V(s.x, s.y, s.z) / s.w)
        normalSum.append(.zero)
        mesh.flags.append(0)
        mesh.root.append(l.root[i])
        mesh.q.append(l.q[i])
      }

      let v = Int(id[r])
      id[i] = Int32(v)
      normalSum[v] += l.n[i] * max(l.area[i], 1e-30)
      mesh.flags[v] |= l.flags[i] & 3
      if l.kind[i] == 2
      {
        mesh.flags[v] |= 4
        mesh.p[v] = l.anchor[i]
        mesh.root[v] = l.root[i]
      }
    }

    mesh.n = normalSum.map { normalized($0, V(0, 0, 1)) }

    // grid edges between the merged verts
    var keys: [UInt64] = []
    for list in links
    {
      for k in list
      {
        let a = id[Int(k.x)], b = id[Int(k.y)]
        if a != b { keys.append(key(a, b)) }
      }
    }

    keys.sort()
    var edges: [SIMD2<Int32>] = []
    for (k, e) in keys.enumerated() where k == 0 || e != keys[k - 1]
    {
      let a = Int32(truncatingIfNeeded: e >> 32), b = Int32(truncatingIfNeeded: e & 0xffff_ffff)
      guard simd_length(mesh.p[Int(a)] - mesh.p[Int(b)]) < scale * 1.8 else { continue }
      edges.append(SIMD2(a, b))
    }

    if ProcessInfo.processInfo.environment["REMESH_DEBUG"] != nil
    {
      var close = 0
      var grid: [SIMD3<Int32>: [Int]] = [:]
      for (i, x) in mesh.p.enumerated() { grid[SIMD3<Int32>((x / scale).rounded(.down)), default: []].append(i) }
      for (i, x) in mesh.p.enumerated()
      {
        let g = SIMD3<Int32>((x / scale).rounded(.down))
        for dz in -1 ... 1 { for dy in -1 ... 1 { for dx in -1 ... 1 { for j in grid[g &+ SIMD3(Int32(dx), Int32(dy), Int32(dz))] ?? [] where j > i && simd_length(mesh.p[j] - x) < scale * 0.4 { close += 1 } } } }
      }
      var degree = [Int](repeating: 0, count: mesh.p.count)
      for e in edges { degree[Int(e.x)] += 1; degree[Int(e.y)] += 1 }
      var hist = [Int](repeating: 0, count: 10)
      for d in degree { hist[min(d, 9)] += 1 }

      // why close clusters did not merge
      var why = [String: Int]()
      for i in 0 ..< n
      {
        for e in Int(l.offset[i]) ..< Int(l.offset[i + 1])
        {
          let j = Int(l.nbr[e])
          guard j > i, id[i] != id[j], simd_length(mesh.p[Int(id[i])] - mesh.p[Int(id[j])]) < scale * 0.4 else { continue }
          let qj = align(l.q[i], l.q[j], l.n[j])
          let (_, _, si, sj, _) = compatPosition(l.p[i], l.n[i], l.q[i], l.o[i], l.p[j], l.n[j], qj, l.o[j], scale, inv)
          let d = si &- sj
          let oo = simd_length(l.o[i] - l.o[j]) / scale
          why["d\(d.x),\(d.y) oo\(Int(oo * 10))", default: 0] += 1
        }
      }
      print("  why", why.sorted { $0.value > $1.value }.prefix(12))
      print("  clusters", mesh.p.count, "edges", edges.count, "close pairs", close, "degree hist", hist)
    }

    trace(&mesh, edges, scale: scale)
    return mesh
  }

  /// walks the faces of the edge graph, each one on the left of its edges when seen from outside
  static func trace(_ mesh: inout Mesh, _ edges: [SIMD2<Int32>], scale: Float, holes: Int = 40)
  {
    let nv = mesh.p.count
    var edges = edges

    // where two edges leave a vert in almost the same direction the longer one is spurious
    for _ in 0 ..< 2
    {
      let (offset, nbr) = Surface.csr(nv, edges.map { $0.x }, edges.map { $0.y })
      var drop = Set<UInt64>()
      for v in 0 ..< nv
      {
        let lo = Int(offset[v]), hi = Int(offset[v + 1])
        guard hi - lo > 1 else { continue }

        let ring = nbr[lo ..< hi].map { w -> (V, Float, Int32) in
          let d = tangent(mesh.p[Int(w)] - mesh.p[v], mesh.n[v])
          return (normalized(d, .zero), simd_length(d), w)
        }

        for a in 0 ..< ring.count
        {
          for b in a + 1 ..< ring.count where simd_dot(ring[a].0, ring[b].0) > 0.82
          {
            let longer = ring[a].1 > ring[b].1 ? ring[a].2 : ring[b].2
            drop.insert(key(Int32(v), longer))
          }
        }
      }

      if drop.isEmpty { break }
      edges.removeAll { drop.contains(key($0.x, $0.y)) }
    }

    let (offset, list) = Surface.csr(nv, edges.map { $0.x }, edges.map { $0.y })
    var nbr = list

    // order every vert's neighbors counterclockwise around its normal
    for v in 0 ..< nv
    {
      let lo = Int(offset[v]), hi = Int(offset[v + 1])
      guard hi - lo > 1 else { continue }

      let nn = mesh.n[v]
      let x = perpendicular(nn), y = simd_cross(nn, x)
      let ring = nbr[lo ..< hi].map
      { w -> (Float, Int32) in
        let d = mesh.p[Int(w)] - mesh.p[v]
        return (atan2(simd_dot(d, y), simd_dot(d, x)), w)
      }
      .sorted { $0.0 < $1.0 }
      for (k, r) in ring.enumerated() { nbr[lo + k] = r.1 }
    }

    // the next half edge keeps the face on the left
    func next(from a: Int32, to b: Int32) -> Int
    {
      let lo = Int(offset[Int(b)]), hi = Int(offset[Int(b) + 1])
      var k = lo
      while k < hi && nbr[k] != a { k += 1 }
      guard k < hi else { return -1 }
      return k == lo ? hi - 1 : k - 1
    }

    var from = [Int32](repeating: 0, count: nbr.count)
    for v in 0 ..< nv { for k in Int(offset[v]) ..< Int(offset[v + 1]) { from[k] = Int32(v) } }

    let closed = !mesh.flags.contains { $0 & 2 != 0 }
    var used = [Bool](repeating: false, count: nbr.count)
    var faces: [[Int32]] = []
    var debug = [String: Int]()
    defer { if ProcessInfo.processInfo.environment["REMESH_DEBUG"] != nil { print("  trace", debug.sorted { $0.key < $1.key }) } }

    func accept(_ loop: [Int32])
    {
      guard loop.count >= 3 else { return }

      if loop.count > 8
      {
        // a long loop is a hole in the grid, filled unless it runs along an open boundary
        let open = loop.filter { mesh.flags[Int($0)] & 2 != 0 }.count
        guard loop.count <= holes, closed || open * 2 < loop.count else
        {
          debug["long", default: 0] += 1
          return
        }
      }

      // a loop that turns the wrong way round its normals is the outside of a hole, not a face
      var normal = V.zero
      let c = loop.reduce(V.zero) { $0 + mesh.p[Int($1)] } / Float(loop.count)
      var expect = V.zero
      for k in 0 ..< loop.count
      {
        let a = mesh.p[Int(loop[k])] - c, b = mesh.p[Int(loop[(k + 1) % loop.count])] - c
        normal += simd_cross(a, b)
        expect += mesh.n[Int(loop[k])]
      }

      // on a closed surface every loop bounds a face or hole, the normal test only matters for small loops and open meshes
      guard simd_dot(normal, expect) > 0 || (closed && loop.count > 4) else
      {
        debug["flip\(min(loop.count, 9))", default: 0] += 1
        return
      }

      debug["len\(min(loop.count, 9))", default: 0] += 1
      faces.append(loop)
    }

    for start in 0 ..< nbr.count where !used[start]
    {
      var loop: [Int32] = []
      var h = start
      var ok = false
      for _ in 0 ..< 256
      {
        used[h] = true
        loop.append(from[h])
        let g = next(from: from[h], to: nbr[h])
        if g < 0 { break }
        if g == start
        {
          ok = true
          break
        }

        if used[g] { break }
        h = g
      }

      guard ok else
      {
        debug["open", default: 0] += 1
        continue
      }

      // drop spurs, a b a becomes a
      var changed = true
      while changed && loop.count >= 3
      {
        changed = false
        for k in 0 ..< loop.count
        {
          let a = loop[(k + loop.count - 1) % loop.count], c = loop[(k + 1) % loop.count]
          if a == c
          {
            for d in [k, (k + 1) % loop.count].sorted(by: >) { loop.remove(at: d) }
            changed = true
            break
          }
        }
      }

      // a loop through the same vert twice is two loops touching there
      var pending = [loop]
      var guardCount = 0
      while let current = pending.popLast(), guardCount < 64
      {
        guardCount += 1
        var seen: [Int32: Int] = [:]
        var split = false
        for (k, v) in current.enumerated()
        {
          if let first = seen[v]
          {
            pending.append(Array(current[first ..< k]))
            pending.append(Array(current[k...] + current[..<first]))
            split = true
            break
          }

          seen[v] = k
        }

        if !split { accept(current) }
      }
    }

    if ProcessInfo.processInfo.environment["REMESH_DEBUG"] != nil
    {
      var hist = [String: Int]()
      for f in faces where f.count == 3
      {
        let l = (0 ..< 3).map { simd_length(mesh.p[Int(f[$0])] - mesh.p[Int(f[($0 + 1) % 3])]) / scale }.sorted()
        hist["\(Int(l[0] * 10)),\(Int(l[1] * 10)),\(Int(l[2] * 10))", default: 0] += 1
      }
      print("  tri edge lengths x10", hist.sorted { $0.value > $1.value }.prefix(10))
    }

    mesh.set(faces)
  }

  /// joins pairs of neighboring triangles into quads where the quad comes out well shaped
  static func pairTriangles(_ mesh: inout Mesh)
  {
    var faces = mesh.faces()
    var owner: [UInt64: [Int]] = [:]
    for (f, face) in faces.enumerated() where face.count == 3
    {
      for k in 0 ..< 3 { owner[key(face[k], face[(k + 1) % 3]), default: []].append(f) }
    }

    struct Pair
    {
      var score: Float
      var a: Int
      var b: Int
      var quad: [Int32]
    }

    var pairs: [Pair] = []
    for (_, fs) in owner.sorted(by: { $0.key < $1.key }) where fs.count == 2
    {
      let t0 = faces[fs[0]], t1 = faces[fs[1]]

      // find the shared edge as it runs in t0
      var quad: [Int32] = []
      for k in 0 ..< 3
      {
        let a = t0[k], b = t0[(k + 1) % 3], c = t0[(k + 2) % 3]
        if let j = t1.firstIndex(of: b), t1[(j + 1) % 3] == a
        {
          let d = t1[(j + 2) % 3]
          quad = [a, d, b, c]
          break
        }
      }

      guard quad.count == 4, Set(quad).count == 4 else { continue }

      var worst: Float = 0
      var ok = true
      let q = quad.map { mesh.p[Int($0)] }
      for k in 0 ..< 4
      {
        let u = normalized(q[(k + 1) % 4] - q[k], .zero), w = normalized(q[(k + 3) % 4] - q[k], .zero)
        let cosine = simd_dot(u, w)
        if cosine < -0.85 { ok = false }
        worst = max(worst, abs(cosine))
      }

      let n0 = simd_cross(q[1] - q[0], q[2] - q[0]), n1 = simd_cross(q[2] - q[0], q[3] - q[0])
      guard ok, simd_dot(normalized(n0, .zero), normalized(n1, .zero)) > 0.3 else { continue }

      pairs.append(Pair(score: worst, a: fs[0], b: fs[1], quad: quad))
    }

    pairs.sort { $0.score != $1.score ? $0.score < $1.score : $0.a < $1.a }
    var gone = [Bool](repeating: false, count: faces.count)
    for pair in pairs where !gone[pair.a] && !gone[pair.b]
    {
      gone[pair.a] = true
      gone[pair.b] = true
      faces.append(pair.quad)
      gone.append(false)
    }

    mesh.set(faces.enumerated().filter { !gone[$0.offset] }.map { $0.element })
  }

  /// cuts every face into quads around its center, through the middle of each edge
  static func split(_ mesh: Mesh) -> Mesh
  {
    var out = Mesh()
    out.p = mesh.p
    out.n = mesh.n
    out.flags = mesh.flags
    out.root = mesh.root
    var mid: [UInt64: Int32] = [:]

    func midpoint(_ a: Int32, _ b: Int32) -> Int32
    {
      let k = key(a, b)
      if let m = mid[k] { return m }

      out.p.append((mesh.p[Int(a)] + mesh.p[Int(b)]) * 0.5)
      out.n.append(normalized(mesh.n[Int(a)] + mesh.n[Int(b)], mesh.n[Int(a)]))
      out.flags.append(mesh.flags[Int(a)] & mesh.flags[Int(b)] & 3)
      out.root.append(mesh.root[Int(a)])
      let m = Int32(out.p.count - 1)
      mid[k] = m
      return m
    }

    var faces: [[Int32]] = []
    for face in mesh.faces().flatMap({ cut($0, mesh.p) })
    {
      let c = Int32(out.p.count)
      out.p.append(face.reduce(V.zero) { $0 + mesh.p[Int($1)] } / Float(face.count))
      out.n.append(normalized(face.reduce(V.zero) { $0 + mesh.n[Int($1)] }, mesh.n[Int(face[0])]))
      out.flags.append(0)
      out.root.append(mesh.root[Int(face[0])])
      let m = (0 ..< face.count).map { midpoint(face[$0], face[($0 + 1) % face.count]) }
      for k in 0 ..< face.count
      {
        faces.append([face[k], m[k], c, m[(k + face.count - 1) % face.count]])
      }
    }

    out.set(faces)
    return out
  }

  /// cuts a big polygon along its shortest inside diagonals into pieces of at most six sides so quads come out as small stars
  static func cut(_ face: [Int32], _ p: [V]) -> [[Int32]]
  {
    guard face.count > 6 else { return [face] }

    var pending = [face], done: [[Int32]] = []
    var guardCount = 0
    while let poly = pending.popLast()
    {
      guardCount += 1
      if poly.count <= 6 || guardCount > 64
      {
        done.append(poly)
        continue
      }

      // flatten onto the best fit plane
      let m = poly.count
      let c = poly.reduce(V.zero) { $0 + p[Int($1)] } / Float(m)
      var normal = V.zero
      for k in 0 ..< m { normal += simd_cross(p[Int(poly[k])] - c, p[Int(poly[(k + 1) % m])] - c) }
      normal = normalized(normal, V(0, 0, 1))
      let x = perpendicular(normal), y = simd_cross(normal, x)
      let flat = poly.map { v -> SIMD2<Float> in
        let d = p[Int(v)] - c
        return SIMD2(simd_dot(d, x), simd_dot(d, y))
      }

      func crosses(_ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>, _ d: SIMD2<Float>) -> Bool
      {
        func side(_ p: SIMD2<Float>, _ q: SIMD2<Float>, _ r: SIMD2<Float>) -> Float { (q.x - p.x) * (r.y - p.y) - (q.y - p.y) * (r.x - p.x) }
        return side(a, b, c) * side(a, b, d) < 0 && side(c, d, a) * side(c, d, b) < 0
      }

      func inside(_ q: SIMD2<Float>) -> Bool
      {
        var odd = false
        for k in 0 ..< m
        {
          let a = flat[k], b = flat[(k + 1) % m]
          if (a.y > q.y) != (b.y > q.y), q.x < a.x + (q.y - a.y) / (b.y - a.y) * (b.x - a.x) { odd.toggle() }
        }
        return odd
      }

      // both pieces keep at least four corners, so no new triangles appear
      var best: (Int, Int)? = nil, shortest = Float.infinity
      for i in 0 ..< m
      {
        for j in stride(from: i + 3, to: m, by: 1) where m - (j - i) >= 3
        {
          let d = simd_length_squared(flat[i] - flat[j])
          guard d < shortest, inside((flat[i] + flat[j]) * 0.5) else { continue }

          let blocked = (0 ..< m).contains
          { k in
            let k2 = (k + 1) % m
            return k != i && k2 != i && k != j && k2 != j && crosses(flat[i], flat[j], flat[k], flat[k2])
          }

          if !blocked
          {
            shortest = d
            best = (i, j)
          }
        }
      }

      guard let (i, j) = best else
      {
        done.append(poly)
        continue
      }

      pending.append(Array(poly[i ... j]))
      pending.append(Array(poly[j...] + poly[...i]))
    }

    return done
  }
}
