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
  /// the rotation k for which the k-th direction of v's cross lines up with u's
  @inline(__always) static func rotation(_ qu: V, _ qv: V, _ nv: V) -> Int
  {
    let tv = simd_cross(nv, qv)
    let a = simd_dot(qu, qv), b = simd_dot(qu, tv)
    if abs(a) >= abs(b) { return a >= 0 ? 0 : 2 }
    return b >= 0 ? 1 : 3
  }

  /// an integer grid step written in v's frame, rewritten in u's frame when v's k-th direction is u's first
  @inline(__always) static func turn(_ d: SIMD2<Int32>, _ k: Int) -> SIMD2<Int32>
  {
    switch k & 3
    {
      case 0: return d
      case 1: return SIMD2(d.y, -d.x)
      case 2: return SIMD2(-d.x, -d.y)
      default: return SIMD2(-d.y, d.x)
    }
  }

  /// removes grid lines that just stop by letting a few edges shrink or turn so the steps around every face add to zero, then rebuilds the mesh
  static func untangle(_ mesh: inout Mesh, scale: Float, clock: Clock)
  {
    let nv = mesh.p.count
    guard nv > 0, mesh.q.count == nv else { return }

    let inv = 1 / scale
    let faces = mesh.faces()
    let (offset, nbr, _) = neighbors(nv, mesh.counts, mesh.indices)

    // combs the cross field so neighbors use the same of their four directions, with seams only around singularities
    var q = mesh.q
    var seen = [Bool](repeating: false, count: nv)
    var queue: [Int32] = []
    queue.reserveCapacity(nv)
    for s in 0 ..< nv where !seen[s]
    {
      seen[s] = true
      queue.append(Int32(s))
      var head = queue.count - 1
      while head < queue.count
      {
        let i = Int(queue[head])
        head += 1
        for e in Int(offset[i]) ..< Int(offset[i + 1])
        {
          let j = Int(nbr[e])
          guard !seen[j] else { continue }

          seen[j] = true
          q[j] = align(q[i], q[j], mesh.n[j])
          queue.append(Int32(j))
        }
      }
    }

    // edges with their grid step, measured from the geometry in the frame of their lower vert
    struct Edge
    {
      var u: Int32
      var v: Int32
      var step: SIMD2<Int32>
      var real: SIMD2<Float>
      var free: Bool
      var faces: (Int32, Int32) = (-1, -1)
      var uses = 0
    }

    var index: [UInt64: Int32] = [:]
    index.reserveCapacity(mesh.indices.count)
    var edges: [Edge] = []
    var corner: [[Int32]] = []
    corner.reserveCapacity(faces.count)
    for (f, face) in faces.enumerated()
    {
      var list: [Int32] = []
      for c in 0 ..< face.count
      {
        let a = face[c], b = face[(c + 1) % face.count]
        let k = key(a, b)
        let e: Int32
        if let found = index[k]
        {
          e = found
        }
        else
        {
          e = Int32(edges.count)
          index[k] = e
          let u = Int(min(a, b)), v = Int(max(a, b))
          let d = mesh.p[v] - mesh.p[u]
          let t = simd_cross(mesh.n[u], q[u])
          let real = SIMD2(simd_dot(d, q[u]), simd_dot(d, t)) * inv

          // every extracted edge is one grid step, along whichever axis it runs closer to
          let step = abs(real.x) >= abs(real.y) ? SIMD2<Int32>(real.x >= 0 ? 1 : -1, 0) : SIMD2<Int32>(0, real.y >= 0 ? 1 : -1)
          edges.append(Edge(u: Int32(u), v: Int32(v), step: step, real: real, free: rotation(q[u], q[v], mesh.n[v]) == 0))
        }

        edges[Int(e)].uses += 1
        if edges[Int(e)].faces.0 < 0 { edges[Int(e)].faces.0 = Int32(f) } else { edges[Int(e)].faces.1 = Int32(f) }
        list.append(e)
      }

      corner.append(list)
    }

    // measure steps against the mean edge so shrinking and growing cost the same on average
    let mean = edges.reduce(Float(0)) { $0 + simd_length($1.real) } / Float(max(edges.count, 1))
    if mean > 0 { for k in edges.indices { edges[k].real /= mean } }

    // the error around each face in its first corner's frame and how each edge's frame turns into it
    var singular = [Bool](repeating: false, count: faces.count)
    var into = [[Int]](repeating: [], count: faces.count)
    var sides = [[Int32]](repeating: [], count: faces.count)
    func around(_ f: Int, _ change: [SIMD2<Int32>]) -> SIMD2<Int32>?
    {
      let face = faces[f]
      let m = face.count
      let r = (0 ..< m).map { c -> Int in
        let a = Int(face[c]), b = Int(face[(c + 1) % m])
        return rotation(q[a], q[b], mesh.n[b])
      }

      if r.reduce(0, +) & 3 != 0 { return nil }

      var sum = SIMD2<Int32>.zero
      var turned = 0
      var xf = [Int](repeating: 0, count: m), sd = [Int32](repeating: 0, count: m)
      for c in 0 ..< m
      {
        let a = face[c]
        let ek = Int(corner[f][c])
        let edge = edges[ek]
        let d = edge.step &+ (change.isEmpty ? .zero : change[ek])
        if a == edge.u
        {
          xf[c] = turned
          sd[c] = 1
          sum &+= turn(d, turned)
        }
        else
        {
          xf[c] = (turned + r[c]) & 3
          sd[c] = -1
          sum &-= turn(d, xf[c])
        }

        turned = (turned + r[c]) & 3
      }

      if change.isEmpty
      {
        into[f] = xf
        sides[f] = sd
      }

      return sum
    }

    var excess = [SIMD2<Int32>](repeating: .zero, count: faces.count)
    for f in faces.indices
    {
      if let sum = around(f, []) { excess[f] = sum } else { singular[f] = true }
    }

    let inconsistent = faces.indices.filter { !singular[$0] && excess[$0] != .zero }.count
    guard inconsistent > 0 else { return }

    // an edge can change where it has a face on each side running along it opposite ways
    var place = [(Int32, Int32)](repeating: (-1, -1), count: edges.count)
    for k in edges.indices
    {
      let e = edges[k]
      edges[k].free = e.uses == 2 && !(singular[Int(e.faces.0)] && singular[Int(e.faces.1)]) || e.uses == 1
      if e.uses == 2, !singular[Int(e.faces.0)], !singular[Int(e.faces.1)]
      {
        let c0 = corner[Int(e.faces.0)].firstIndex(of: Int32(k))!, c1 = corner[Int(e.faces.1)].firstIndex(of: Int32(k))!
        if sides[Int(e.faces.0)][c0] == sides[Int(e.faces.1)][c1] { edges[k].free = false }
      }

      for f in [e.faces.0, e.faces.1] where f >= 0 && !singular[Int(f)]
      {
        let c = Int32(corner[Int(f)].firstIndex(of: Int32(k))!)
        if place[k].0 < 0 { place[k].0 = c } else { place[k].1 = c }
      }
    }

    var faceEdges = [[Int32]](repeating: [], count: faces.count)
    for (k, e) in edges.enumerated() where e.free
    {
      faceEdges[Int(e.faces.0)].append(Int32(k))
      if e.faces.1 >= 0 { faceEdges[Int(e.faces.1)].append(Int32(k)) }
    }

    func cornerOf(_ f: Int32, _ k: Int32) -> Int
    {
      corner[Int(f)].firstIndex(of: k)!
    }

    let units: [SIMD2<Int32>] = [SIMD2(1, 0), SIMD2(0, 1), SIMD2(-1, 0), SIMD2(0, -1)]
    func unit(_ w: SIMD2<Int32>) -> Int { units.firstIndex(of: w) ?? 0 }

    // the cost of adding delta to an edge's step, it may shrink, double or lean a step sideways but never turn or flip
    var change = [SIMD2<Int32>](repeating: .zero, count: edges.count)
    func cost(_ k: Int, _ delta: SIMD2<Int32>) -> Float
    {
      let e = edges[k]
      let now = e.step &+ change[k], next = now &+ delta
      let base = e.step
      let along = base.x != 0 ? 0 : 1
      let side = 1 - along
      if next[side] != 0 && next[along] != base[along] { return .infinity }
      if abs(next[side]) > 1 { return .infinity }
      if next[along] != 0 && next[along] != base[along] && next[along] != 2 * base[along] { return .infinity }

      var d: Float = 0
      for axis in 0 ..< 2 where delta[axis] != 0
      {
        let real = e.real[axis]
        d += abs(Float(next[axis]) - real) - abs(Float(now[axis]) - real)
      }

      return max(d, 0) + 0.1
    }

    let outside = Int32(faces.count)
    var need = excess
    for f in faces.indices where singular[f] { need[f] = .zero }

    // a search state is a face and the unit step being pushed out of it, in that face's frame
    let states = (faces.count + 1) * 4
    var dist = [Float](repeating: .infinity, count: states)
    var via = [Int32](repeating: -1, count: states)
    var back = [Int32](repeating: -1, count: states)
    var touched: [Int32] = []
    var fixed = 0, failed = 0
    let reach: Float = 60
    for start in faces.indices where need[start] != .zero
    {
      var tries = 0
      while need[start] != .zero, tries < 8
      {
        tries += 1
        if clock.over(0.8) { break }

        let n0 = need[start]
        let w0 = abs(n0.x) >= abs(n0.y) ? SIMD2<Int32>(n0.x > 0 ? 1 : -1, 0) : SIMD2<Int32>(0, n0.y > 0 ? 1 : -1)
        for t in touched
        {
          dist[Int(t)] = .infinity
          via[Int(t)] = -1
        }

        touched.removeAll(keepingCapacity: true)
        var heap = Heap()
        let s0 = Int32(start * 4 + unit(w0))
        dist[Int(s0)] = 0
        touched.append(s0)
        heap.push(0, s0)
        var found: Int32 = -1
        var visits = 0
        while let (d, state) = heap.pop()
        {
          guard d <= dist[Int(state)] else { continue }

          let t = state / 4, w = units[Int(state % 4)]
          if state != s0
          {
            // w arrived here, which helps a face whose error points the other way
            if t == outside || singular[Int(t)] || simd_reduce_add(need[Int(t)] &* w) < 0
            {
              found = state
              break
            }
          }

          visits += 1
          if visits > 30000 || t == outside || d > reach { break }

          // push w out of t across each free edge
          for ek in faceEdges[Int(t)]
          {
            let e = edges[Int(ek)]
            let c = cornerOf(t, ek)
            let delta = turn(SIMD2(-w.x, -w.y) &* sides[Int(t)][c], (4 - into[Int(t)][c]) & 3)
            let step = cost(Int(ek), delta)
            guard step.isFinite else { continue }

            let other = e.faces.0 == t ? (e.faces.1 >= 0 ? e.faces.1 : outside) : e.faces.0
            var arrive = SIMD2<Int32>(1, 0)
            var sink: Float = 0
            if other == outside
            {
              sink = 1.5
            }
            else if singular[Int(other)]
            {
              sink = 6
            }
            else
            {
              let co = cornerOf(other, ek)
              arrive = turn(delta &* sides[Int(other)][co], into[Int(other)][co])
            }

            let next = other * 4 + Int32(unit(arrive))
            let nd = d + step + sink
            if nd < dist[Int(next)]
            {
              if dist[Int(next)] == .infinity { touched.append(next) }
              dist[Int(next)] = nd
              via[Int(next)] = ek
              back[Int(next)] = state
              heap.push(nd, next)
            }
          }
        }

        guard found >= 0 else
        {
          failed += 1
          break
        }

        // walk back, adding each push to its edge
        var state = found
        while state != s0
        {
          let ek = Int(via[Int(state)]), prior = back[Int(state)]
          let t = prior / 4, w = units[Int(prior % 4)]
          let c = cornerOf(t, Int32(ek))
          change[ek] &+= turn(SIMD2(-w.x, -w.y) &* sides[Int(t)][c], (4 - into[Int(t)][c]) & 3)
          state = prior
        }

        let ft = found / 4
        if ft != outside && !singular[Int(ft)] { need[Int(ft)] &+= units[Int(found % 4)] }
        need[start] &-= w0
        fixed += 1
      }
    }

    if ProcessInfo.processInfo.environment["REMESH_DEBUG"] != nil
    {
      let after = faces.indices.filter { !singular[$0] && around($0, change) != .zero }.count
      print("  untangle: \(faces.count) faces, \(edges.filter { $0.free }.count)/\(edges.count) free, \(singular.filter { $0 }.count) singular, inconsistent \(inconsistent) -> \(after), fixed \(fixed), failed \(failed)")
    }

    // rebuild: steps of zero join their verts, diagonal steps are dropped so the faces on both sides join
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

    for (k, e) in edges.enumerated() where e.step &+ change[k] == .zero
    {
      let a = find(e.u), b = find(e.v)
      if a != b { root[Int(max(a, b))] = min(a, b) }
    }

    var id = [Int32](repeating: -1, count: nv)
    var out = Mesh()
    var weight: [Float] = []
    for v in 0 ..< nv
    {
      let r = Int(find(Int32(v)))
      if id[r] < 0
      {
        id[r] = Int32(out.p.count)
        out.p.append(.zero)
        out.n.append(.zero)
        out.q.append(q[r])
        out.flags.append(0)
        out.root.append(mesh.root[r])
        weight.append(0)
      }

      let w = Int(id[r])
      id[v] = Int32(w)
      out.p[w] += mesh.p[v]
      out.n[w] += mesh.n[v]
      out.flags[w] |= mesh.flags[v]
      weight[w] += 1
    }

    for w in out.p.indices
    {
      out.p[w] /= weight[w]
      out.n[w] = normalized(out.n[w], V(0, 0, 1))
    }

    for v in 0 ..< nv where mesh.flags[v] & 4 != 0
    {
      out.p[Int(id[v])] = mesh.p[v]
      out.root[Int(id[v])] = mesh.root[v]
    }

    // the unit steps that are left, rewritten from the lower new vert to the higher in the lower one's frame
    var kept: [SIMD2<Int32>] = []
    var steps: [UInt64: SIMD2<Int32>] = [:]
    for (k, e) in edges.enumerated()
    {
      var s = e.step &+ change[k]
      let size = abs(s.x) + abs(s.y)
      guard size == 1 || (size == 2 && (s.x == 0 || s.y == 0)) else { continue }

      let a = id[Int(e.u)], b = id[Int(e.v)]
      guard a != b, steps[key(a, b)] == nil else { continue }

      // into the frame of a
      s = turn(s, rotation(out.q[Int(a)], q[Int(e.u)], mesh.n[Int(e.u)]))
      func link(_ a: Int32, _ b: Int32, _ s: SIMD2<Int32>)
      {
        var a = a, b = b, s = s
        if a > b
        {
          s = turn(SIMD2(-s.x, -s.y), rotation(out.q[Int(b)], out.q[Int(a)], out.n[Int(a)]))
          swap(&a, &b)
        }

        steps[key(a, b)] = s
        kept.append(SIMD2(a, b))
      }

      if size == 1
      {
        link(a, b, s)
        continue
      }

      // a stretched edge gets a vert in its middle, which adds a grid line between the faces beside it
      let m = Int32(out.p.count)
      out.p.append((out.p[Int(a)] + out.p[Int(b)]) * 0.5)
      out.n.append(normalized(out.n[Int(a)] + out.n[Int(b)], out.n[Int(a)]))
      out.q.append(out.q[Int(a)])
      out.flags.append(out.flags[Int(a)] & out.flags[Int(b)])
      out.root.append(out.root[Int(a)])
      let half = s / 2
      link(a, m, half)
      link(m, b, half)
    }

    if ProcessInfo.processInfo.environment["REMESH_DEBUG"] != nil
    {
      var kinds = [String: Int]()
      for (k, e) in edges.enumerated() { let s = e.step &+ change[k]; kinds["\(abs(s.x) + abs(s.y))\(s.x == 0 || s.y == 0 ? "a" : "d")", default: 0] += 1 }
      print("  rebuild verts \(nv) -> \(out.p.count), kept edges \(kept.count) of \(edges.count), kinds \(kinds)")
    }
    trace(&out, kept, scale: scale, holes: 240)
    fill(&out, steps)
    if ProcessInfo.processInfo.environment["REMESH_DEBUG"] != nil { print("  rebuilt", out.faceCount, "faces from", faces.count) }
    if out.faceCount * 2 > faces.count { mesh = out }
  }

  /// fills rectangles and other grid outlines with unit quads, giving every corner whole number coordinates
  static func fill(_ mesh: inout Mesh, _ steps: [UInt64: SIMD2<Int32>])
  {
    var faces: [[Int32]] = []
    for face in mesh.faces()
    {
      guard face.count > 4, let cells = lattice(&mesh, face, steps) else
      {
        faces.append(face)
        continue
      }

      faces += cells
    }

    mesh.set(faces)
  }

  /// unit quads covering a face whose steps close up into a simple outline on the grid, or nil
  static func lattice(_ mesh: inout Mesh, _ face: [Int32], _ steps: [UInt64: SIMD2<Int32>]) -> [[Int32]]?
  {
    let m = face.count
    var at = SIMD2<Int32>.zero, turned = 0
    var coords: [SIMD2<Int32>] = []
    for c in 0 ..< m
    {
      let a = face[c], b = face[(c + 1) % m]
      guard var s = steps[key(a, b)] else { return nil }

      let r = rotation(mesh.q[Int(a)], mesh.q[Int(b)], mesh.n[Int(b)])
      if a > b { s = turn(SIMD2(-s.x, -s.y), r) }
      coords.append(at)
      at &+= turn(s, turned)
      turned = (turned + r) & 3
    }

    guard at == .zero else { return nil }
    guard turned == 0 else { return nil }
    guard Set(coords).count == m else { return nil }

    let lo = coords.reduce(SIMD2<Int32>(repeating: .max)) { simd_min($0, $1) }
    let hi = coords.reduce(SIMD2<Int32>(repeating: .min)) { simd_max($0, $1) }
    guard (hi &- lo).max() <= 40 else { return nil }

    var area: Int32 = 0
    for c in 0 ..< m
    {
      let a = coords[c], b = coords[(c + 1) % m]
      area += a.x * b.y - b.x * a.y
    }

    guard area > 0 else { return nil }

    func inside(_ x: Float, _ y: Float) -> Bool
    {
      var odd = false
      for c in 0 ..< m
      {
        let a = SIMD2<Float>(coords[c]), b = SIMD2<Float>(coords[(c + 1) % m])
        if (a.y > y) != (b.y > y), x < a.x + (y - a.y) / (b.y - a.y) * (b.x - a.x) { odd.toggle() }
      }
      return odd
    }

    var corner: [SIMD2<Int32>: Int32] = [:]
    for (c, x) in coords.enumerated() { corner[x] = face[c] }

    func point(_ g: SIMD2<Int32>) -> Int32
    {
      if let v = corner[g] { return v }

      // a new inner vert, placed by inverse distance over the outline and pulled onto the surface later
      var sum = V.zero, normal = V.zero, w: Float = 0
      var nearest = face[0], best = Float.infinity
      for (c, x) in coords.enumerated()
      {
        let d = simd_length_squared(SIMD2<Float>(x &- g))
        let k = 1 / max(d * d, 1e-6)
        sum += mesh.p[Int(face[c])] * k
        normal += mesh.n[Int(face[c])] * k
        w += k
        if d < best
        {
          best = d
          nearest = face[c]
        }
      }

      let v = Int32(mesh.p.count)
      mesh.p.append(sum / w)
      mesh.n.append(normalized(normal, mesh.n[Int(nearest)]))
      mesh.q.append(mesh.q[Int(face[0])])
      mesh.flags.append(0)
      mesh.root.append(mesh.root[Int(nearest)])
      corner[g] = v
      return v
    }

    var cells: [[Int32]] = []
    for y in lo.y ..< hi.y
    {
      for x in lo.x ..< hi.x where inside(Float(x) + 0.5, Float(y) + 0.5)
      {
        cells.append([point(SIMD2(x, y)), point(SIMD2(x + 1, y)), point(SIMD2(x + 1, y + 1)), point(SIMD2(x, y + 1))])
      }
    }

    return cells.count == Int(area / 2) ? cells : nil
  }

  /// +1 when the face runs along its edge from u to v, -1 the other way
  @inline(__always) static func sign(_ face: [Int32], _ u: Int32, _ v: Int32) -> Int32
  {
    let m = face.count
    for c in 0 ..< m where face[c] == u && face[(c + 1) % m] == v { return 1 }
    return -1
  }

  /// a small binary min heap for the searches
  struct Heap
  {
    var items: [(Float, Int32)] = []

    mutating func push(_ d: Float, _ t: Int32)
    {
      items.append((d, t))
      var i = items.count - 1
      while i > 0
      {
        let p = (i - 1) / 2
        guard items[p].0 > items[i].0 else { break }
        items.swapAt(p, i)
        i = p
      }
    }

    mutating func pop() -> (Float, Int32)?
    {
      guard let top = items.first else { return nil }

      let last = items.removeLast()
      if !items.isEmpty
      {
        items[0] = last
        var i = 0
        while true
        {
          let a = 2 * i + 1, b = a + 1
          var m = i
          if a < items.count && items[a].0 < items[m].0 { m = a }
          if b < items.count && items[b].0 < items[m].0 { m = b }
          if m == i { break }
          items.swapAt(m, i)
          i = m
        }
      }

      return top
    }
  }
}
