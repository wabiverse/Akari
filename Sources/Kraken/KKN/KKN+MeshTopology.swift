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

extension Kraken
{
  /// Edit mesh topology, each vertex keeps the cycle of edges around it (its disk) and each edge
  /// the cycle of face corners along it (its radial), so every neighbor is a step away, manifold
  /// or not.
  struct MeshTopology
  {
    struct Vert
    {
      var edge = -1
    }

    struct Edge
    {
      var v: (Int, Int)
      var next = (-1, -1)
      var prev = (-1, -1)
      var loop = -1
    }

    /// A face's corner, the edge on to the next corner, and its place in that edge's radial.
    struct Loop
    {
      var vert: Int
      var edge: Int
      var face: Int
      var next: Int
      var prev: Int
      var radialNext = -1
      var radialPrev = -1
    }

    struct Face
    {
      var loop = -1
      var count = 0
    }

    private(set) var verts: [Vert] = []
    private(set) var edges: [Edge] = []
    private(set) var loops: [Loop] = []
    private(set) var faces: [Face] = []

    init() {}

    init(vertexCount: Int, faces list: [[Int]])
    {
      for _ in 0 ..< vertexCount { _ = addVert() }
      for face in list where face.allSatisfy({ $0 >= 0 && $0 < vertexCount }) { addFace(face) }
    }

    // MARK: walking

    func other(_ e: Int, _ v: Int) -> Int
    {
      edges[e].v.0 == v ? edges[e].v.1 : edges[e].v.0
    }

    private func diskNext(_ e: Int, _ v: Int) -> Int
    {
      edges[e].v.0 == v ? edges[e].next.0 : edges[e].next.1
    }

    private func diskPrev(_ e: Int, _ v: Int) -> Int
    {
      edges[e].v.0 == v ? edges[e].prev.0 : edges[e].prev.1
    }

    /// The edge between `a` and `b`, if one is.
    func edge(_ a: Int, _ b: Int) -> Int?
    {
      guard a >= 0, a < verts.count, verts[a].edge >= 0 else { return nil }
      let first = verts[a].edge
      var e = first
      repeat
      {
        if other(e, a) == b { return e }
        e = diskNext(e, a)
      } while e != first
      return nil
    }

    func edgesAround(_ v: Int) -> [Int]
    {
      guard v >= 0, v < verts.count, verts[v].edge >= 0 else { return [] }
      let first = verts[v].edge
      var out: [Int] = []
      var e = first
      repeat
      {
        out.append(e)
        e = diskNext(e, v)
      } while e != first
      return out
    }

    func facesAround(_ e: Int) -> [Int]
    {
      let first = edges[e].loop
      guard first >= 0 else { return [] }
      var out: [Int] = []
      var l = first
      repeat
      {
        out.append(loops[l].face)
        l = loops[l].radialNext
      } while l != first
      return out
    }

    func facesTouching(_ v: Int) -> Set<Int>
    {
      Set(edgesAround(v).flatMap(facesAround))
    }

    func faceLoops(_ f: Int) -> [Int]
    {
      guard faces[f].count > 0 else { return [] }
      var out: [Int] = []
      var l = faces[f].loop
      repeat
      {
        out.append(l)
        l = loops[l].next
      } while l != faces[f].loop
      return out
    }

    func corners(of f: Int) -> [Int]
    {
      faceLoops(f).map { loops[$0].vert }
    }

    func sides(of f: Int) -> [Int]
    {
      faceLoops(f).map { loops[$0].edge }
    }

    /// Whether a face runs from `a` to `b` along their edge.
    func isDirected(_ a: Int, _ b: Int) -> Bool
    {
      guard let e = edge(a, b), edges[e].loop >= 0 else { return false }
      let first = edges[e].loop
      var l = first
      repeat
      {
        if loops[l].vert == a { return true }
        l = loops[l].radialNext
      } while l != first
      return false
    }

    // MARK: making and killing

    mutating func addVert() -> Int
    {
      verts.append(Vert())
      return verts.count - 1
    }

    private mutating func setNext(_ e: Int, _ v: Int, _ n: Int)
    {
      if edges[e].v.0 == v { edges[e].next.0 = n } else { edges[e].next.1 = n }
    }

    private mutating func setPrev(_ e: Int, _ v: Int, _ p: Int)
    {
      if edges[e].v.0 == v { edges[e].prev.0 = p } else { edges[e].prev.1 = p }
    }

    private mutating func link(_ e: Int, into v: Int)
    {
      let first = verts[v].edge
      guard first >= 0 else
      {
        setNext(e, v, e)
        setPrev(e, v, e)
        verts[v].edge = e
        return
      }

      let last = diskPrev(first, v)
      setNext(last, v, e)
      setPrev(e, v, last)
      setNext(e, v, first)
      setPrev(first, v, e)
    }

    private mutating func ensureEdge(_ a: Int, _ b: Int) -> Int
    {
      if let e = edge(a, b) { return e }
      edges.append(Edge(v: (a, b)))
      let e = edges.count - 1
      link(e, into: a)
      link(e, into: b)
      return e
    }

    private mutating func attach(_ l: Int, to e: Int)
    {
      let first = edges[e].loop
      guard first >= 0 else
      {
        loops[l].radialNext = l
        loops[l].radialPrev = l
        edges[e].loop = l
        return
      }

      let last = loops[first].radialPrev
      loops[last].radialNext = l
      loops[l].radialPrev = last
      loops[l].radialNext = first
      loops[first].radialPrev = l
    }

    private mutating func detach(_ l: Int)
    {
      let e = loops[l].edge, n = loops[l].radialNext, p = loops[l].radialPrev
      if n == l
      {
        edges[e].loop = -1
        return
      }

      loops[p].radialNext = n
      loops[n].radialPrev = p
      if edges[e].loop == l { edges[e].loop = n }
    }

    /// A face through `corners`, repeats in a row dropped, `nil` when fewer than three different corners are left.
    @discardableResult
    mutating func addFace(_ corners: [Int]) -> Int?
    {
      var ring: [Int] = []
      for v in corners where ring.last != v { ring.append(v) }
      if ring.count > 1, ring.first == ring.last { ring.removeLast() }
      guard Set(ring).count >= 3 else { return nil }
      let f = faces.count, base = loops.count, n = ring.count
      faces.append(Face(loop: base, count: n))
      for (i, v) in ring.enumerated()
      {
        let e = ensureEdge(v, ring[(i + 1) % n])
        loops.append(Loop(vert: v, edge: e, face: f, next: base + (i + 1) % n, prev: base + (i + n - 1) % n))
        attach(base + i, to: e)
      }

      return f
    }

    /// Takes the face out of its edges' radials, leaving its edges and verts for `compacted` to drop.
    mutating func killFace(_ f: Int)
    {
      for l in faceLoops(f) { detach(l) }
      faces[f] = Face()
    }

    /// The topology rebuilt without dead faces, edges no face uses or verts no face uses, verts kept in order,
    /// with each old vert's and face's new index, -1 for gone.
    func compacted() -> (mesh: MeshTopology, verts: [Int], faces: [Int])
    {
      let live = faces.indices.filter { faces[$0].count > 0 }
      var used = [Bool](repeating: false, count: verts.count)
      for f in live { for v in corners(of: f) { used[v] = true } }
      var mesh = MeshTopology()
      var vertMap = [Int](repeating: -1, count: verts.count)
      for v in verts.indices where used[v] { vertMap[v] = mesh.addVert() }
      var faceMap = [Int](repeating: -1, count: faces.count)
      for f in live { faceMap[f] = mesh.addFace(corners(of: f).map { vertMap[$0] }) ?? -1 }
      return (mesh, vertMap, faceMap)
    }
  }
}
