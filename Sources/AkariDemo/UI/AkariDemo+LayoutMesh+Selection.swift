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

extension AkariDemo.EditMesh
{
  mutating func flush()
  {
    switch mode
    {
      case .vertex:
        edges = Set(allEdges.filter { verts.contains($0.a) && verts.contains($0.b) })
        selectedFaces = Set(faces.indices.filter { faces[$0].allSatisfy(verts.contains) })
      case .edge:
        verts = Set(edges.flatMap { [$0.a, $0.b] })
        selectedFaces = Set(faces.indices.filter { Self.edges(of: faces[$0]).allSatisfy(edges.contains) })
      case .face:
        verts = Set(selectedFaces.flatMap { faces[$0] })
        edges = Set(selectedFaces.flatMap { Self.edges(of: faces[$0]) })
    }
  }

  mutating func setMode(_ next: AkariDemo.SelectMode)
  {
    guard next != mode else { return }
    if next == .edge, mode == .vertex
    {
      edges = Set(allEdges.filter { verts.contains($0.a) && verts.contains($0.b) })
    }

    mode = next
    flush()
  }

  mutating func selectAll(_ on: Bool)
  {
    verts = on ? Set(points.indices) : []
    edges = on ? Set(allEdges) : []
    selectedFaces = on ? Set(faces.indices) : []
  }

  mutating func invert()
  {
    switch mode
    {
      case .vertex: verts = Set(points.indices).subtracting(verts)
      case .edge: edges = Set(allEdges).subtracting(edges)
      case .face: selectedFaces = Set(faces.indices).subtracting(selectedFaces)
    }

    flush()
  }

  mutating func clearSelection()
  {
    verts = []
    edges = []
    selectedFaces = []
  }

  mutating func toggle(vertex v: Int, extend: Bool)
  {
    if !extend { clearSelection() }
    if extend, verts.contains(v) { verts.remove(v) } else { verts.insert(v) }
    flush()
  }

  mutating func toggle(edge e: AkariDemo.Edge, extend: Bool)
  {
    if !extend { clearSelection() }
    if extend, edges.contains(e) { edges.remove(e) } else { edges.insert(e) }
    flush()
  }

  mutating func toggle(face f: Int, extend: Bool)
  {
    if !extend { clearSelection() }
    if extend, selectedFaces.contains(f) { selectedFaces.remove(f) } else { selectedFaces.insert(f) }
    flush()
  }

  /// Selects the faces' verts as the mode sees them after an op made new geometry.
  mutating func select(faces list: [Int], verts extra: [Int] = [])
  {
    clearSelection()
    selectedFaces = Set(list)
    verts = Set(list.flatMap { faces[$0] }).union(extra)
    edges = Set(list.flatMap { Self.edges(of: faces[$0]) })
    if mode == .vertex { flush() }
  }

  /// Drops points no face uses and faces with fewer than three corners, keeping what's selected.
  mutating func compact()
  {
    let map = rebuild()
    verts = remap(verts, map.verts)
    edges = remap(edges: edges, map.verts)
    selectedFaces = remap(selectedFaces, map.faces)
    flush()
  }

  mutating func selectLinked(from seed: Set<Int>? = nil)
  {
    var reached = seed ?? verts
    var stack = Array(reached)
    while let v = stack.popLast()
    {
      for e in topology.edgesAround(v)
      {
        let o = topology.other(e, v)
        if reached.insert(o).inserted { stack.append(o) }
      }
    }

    verts.formUnion(reached)
    selectedFaces.formUnion(faces.indices.filter { faces[$0].allSatisfy(verts.contains) })
    edges.formUnion(allEdges.filter { verts.contains($0.a) && verts.contains($0.b) })
  }

  /// The loop of edges `edge` continues into, walking straight across each four way vertex both ways.
  func edgeLoop(_ edge: AkariDemo.Edge) -> [AkariDemo.Edge]
  {
    guard let start = side(edge) else { return [edge] }
    var loop: [AkariDemo.Edge] = [edge]
    var seen: Set<Int> = [start]
    for from in [edge.b, edge.a]
    {
      var current = start
      var at = from
      while true
      {
        let sides = Set(topology.facesAround(current).flatMap(topology.sides(of:)))
        let onward = topology.edgesAround(at).filter { !sides.contains($0) }
        guard onward.count == 1, let next = onward.first, seen.insert(next).inserted else { break }
        loop.append(pair(next))
        current = next
        at = topology.other(next, at)
      }
    }

    return loop
  }

  /// Selects the loop through `edge`, or in face mode the strip of faces across it.
  mutating func selectLoop(_ edge: AkariDemo.Edge, extend: Bool)
  {
    if !extend { clearSelection() }
    if mode == .face
    {
      for e in ring(edge) { if let s = side(e) { selectedFaces.formUnion(topology.facesAround(s)) } }
    }
    else
    {
      let loop = edgeLoop(edge)
      edges.formUnion(loop)
      if mode == .vertex { verts.formUnion(loop.flatMap { [$0.a, $0.b] }) }
    }

    flush()
  }

  /// The edges a loop cut through `edge` crosses, walking quads both ways.
  func ring(_ edge: AkariDemo.Edge) -> [AkariDemo.Edge]
  {
    guard let start = side(edge) else { return [edge] }
    var cut = [start]
    var crossed: Set<Int> = [start]
    var visited = Set<Int>()
    for first in topology.facesAround(start)
    {
      var face = first
      var entering = start
      while !visited.contains(face), topology.faces[face].count == 4
      {
        visited.insert(face)
        guard let l = topology.faceLoops(face).first(where: { topology.loops[$0].edge == entering }) else { break }
        let opposite = topology.loops[topology.loops[l].next].next
        let across = topology.loops[opposite].edge
        guard crossed.insert(across).inserted else { break }
        cut.append(across)
        guard let next = topology.facesAround(across).first(where: { $0 != face }) else { break }
        face = next
        entering = across
      }
    }

    return cut.map(pair)
  }
}
