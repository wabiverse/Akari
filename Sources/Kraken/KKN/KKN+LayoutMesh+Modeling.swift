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

extension Kraken.EditMesh
{
  /// Adds a shape's points and faces, its corners counting from its own first point, and returns the faces made.
  mutating func add(points shape: [SIMD3<Float>], faces loops: [[Int]]) -> [Int]
  {
    let base = points.count
    for p in shape { _ = addPoint(p) }
    let made = loops.compactMap { topology.addFace($0.map { $0 + base }) }
    snapshot()
    return made
  }

  /// Extrudes the selected faces as a region, or the selected edges into new faces,
  /// returning the direction to move the extrusion along, `nil` for a free move.
  mutating func extrude() -> SIMD3<Float>?
  {
    let region = selectedFaceList
    if !region.isEmpty
    {
      let inside = Set(region)
      var copy: [Int: Int] = [:]
      for v in Set(region.flatMap { faces[$0] }).sorted() { copy[v] = addPoint(points[v]) }
      let direction = simd_normalize(region.reduce(SIMD3<Float>.zero) { $0 + normal(faces[$1]) })
      var walls: [[Int]] = []
      for f in region
      {
        let face = faces[f]
        for i in face.indices
        {
          let a = face[i], b = face[(i + 1) % face.count]
          guard let e = topology.edge(a, b), topology.facesAround(e).filter(inside.contains).count == 1 else { continue }
          walls.append([a, b, copy[b]!, copy[a]!])
        }
      }

      var made: [Int?] = []
      for f in region
      {
        topology.killFace(f)
        made.append(topology.addFace(faces[f].map { copy[$0]! }))
      }

      for wall in walls { topology.addFace(wall) }
      finish(selecting: made)
      return direction.x.isFinite ? direction : nil
    }

    guard !verts.isEmpty else { return nil }
    var copy: [Int: Int] = [:]
    for v in verts.sorted() { copy[v] = addPoint(points[v]) }
    let chosen = mode == .vertex ? Set(allEdges.filter { verts.contains($0.a) && verts.contains($0.b) }) : edges
    for e in chosen
    {
      topology.addFace(topology.isDirected(e.a, e.b) ? [e.b, e.a, copy[e.a]!, copy[e.b]!] : [e.a, e.b, copy[e.b]!, copy[e.a]!])
    }

    let map = rebuild()
    clearSelection()
    verts = remap(copy.values, map.verts)
    edges = remap(edges: chosen.map { Kraken.Edge(copy[$0.a]!, copy[$0.b]!) }, map.verts)
    flush()
    return nil
  }

  /// Insets each selected face by `amount` of the way to its middle.
  mutating func inset(_ amount: Float)
  {
    let region = selectedFaceList
    guard !region.isEmpty else { return }
    let t = min(max(amount, 0), 0.999)
    var made: [Int?] = []
    for f in region
    {
      let face = faces[f]
      let c = center(face)
      let ring = face.map { addPoint(simd_mix(points[$0], c, SIMD3(repeating: t))) }
      topology.killFace(f)
      made.append(topology.addFace(ring))
      for i in face.indices
      {
        let j = (i + 1) % face.count
        topology.addFace([face[i], face[j], ring[j], ring[i]])
      }
    }

    finish(selecting: made)
  }

  enum Removal
  {
    case vertices, edges, faces
  }

  mutating func delete(_ what: Removal)
  {
    var doomed = Set<Int>()
    switch what
    {
      case .vertices:
        for v in verts { doomed.formUnion(topology.facesTouching(v)) }
      case .edges:
        let chosen = mode == .vertex ? Set(allEdges.filter { verts.contains($0.a) && verts.contains($0.b) }) : edges
        for e in chosen { if let s = side(e) { doomed.formUnion(topology.facesAround(s)) } }
      case .faces:
        doomed = Set(selectedFaceList)
    }

    for f in doomed { topology.killFace(f) }
    clearSelection()
    compact()
  }

  /// Makes a face of the selected verts, ordered around their middle.
  mutating func fill() -> Bool
  {
    let list = verts.sorted()
    guard list.count >= 3 else { return false }
    let c = list.reduce(SIMD3<Float>.zero) { $0 + points[$1] } / Float(list.count)
    var n = SIMD3<Float>.zero
    for i in list.indices
    {
      for j in list.indices where j > i
      {
        let cross = simd_cross(points[list[i]] - c, points[list[j]] - c)
        if simd_length(cross) > simd_length(n) { n = cross }
      }
    }

    guard simd_length(n) > 0 else { return false }
    n = simd_normalize(n)
    let u = simd_normalize(points[list[0]] - c - n * simd_dot(points[list[0]] - c, n))
    let w = simd_cross(n, u)
    var face = list.sorted
    {
      let a = points[$0] - c, b = points[$1] - c
      return atan2(simd_dot(a, w), simd_dot(a, u)) < atan2(simd_dot(b, w), simd_dot(b, u))
    }

    if face.indices.contains(where: { topology.isDirected(face[$0], face[($0 + 1) % face.count]) }) { face.reverse() }
    guard let made = topology.addFace(face) else { return false }
    finish(selecting: [made])
    return true
  }

  /// Remakes the faces touching any vert `into` moves, with it moved.
  private mutating func weld(_ into: [Int: Int])
  {
    var touched = Set<Int>()
    for v in into.keys { touched.formUnion(topology.facesTouching(v)) }
    for f in touched.sorted()
    {
      let corners = topology.corners(of: f).map { into[$0] ?? $0 }
      topology.killFace(f)
      topology.addFace(corners)
    }
  }

  /// Welds the selected verts into one at `target`, their middle when `nil`.
  mutating func merge(at target: SIMD3<Float>?)
  {
    guard let keep = verts.min(), let middle = median else { return }
    points[keep] = target ?? middle
    weld(Dictionary(uniqueKeysWithValues: verts.filter { $0 != keep }.map { ($0, keep) }))
    let map = rebuild()
    clearSelection()
    verts = remap([keep], map.verts)
    flush()
  }

  mutating func mergeByDistance(_ distance: Float)
  {
    let list = verts.sorted()
    var root = Dictionary(uniqueKeysWithValues: list.map { ($0, $0) })
    for (i, a) in list.enumerated()
    {
      guard root[a] == a else { continue }
      for b in list[(i + 1)...] where root[b] == b && simd_distance(points[a], points[b]) <= distance
      {
        root[b] = a
      }
    }

    weld(root.filter { $0.key != $0.value })
    compact()
  }

  mutating func subdivide()
  {
    let region = selectedFaceList
    guard !region.isEmpty else { return }
    var middles: [Kraken.Edge: Int] = [:]
    for f in region
    {
      for e in Self.edges(of: faces[f]) where middles[e] == nil
      {
        middles[e] = addPoint((points[e.a] + points[e.b]) * 0.5)
      }
    }

    let chosen = Set(region)
    var neighbors = Set<Int>()
    for e in middles.keys { if let s = side(e) { neighbors.formUnion(topology.facesAround(s)) } }
    neighbors.subtract(chosen)
    var made: [Int?] = []
    for f in region
    {
      let face = faces[f]
      let c = addPoint(center(face))
      topology.killFace(f)
      for i in face.indices
      {
        let prev = face[(i + face.count - 1) % face.count], v = face[i], next = face[(i + 1) % face.count]
        made.append(topology.addFace([v, middles[Kraken.Edge(v, next)]!, c, middles[Kraken.Edge(prev, v)]!]))
      }
    }

    for f in neighbors
    {
      topology.killFace(f)
      topology.addFace(split(faces[f], middles))
    }

    finish(selecting: made)
  }

  private func split(_ face: [Int], _ middles: [Kraken.Edge: Int]) -> [Int]
  {
    var loop: [Int] = []
    for i in face.indices
    {
      loop.append(face[i])
      if let m = middles[Kraken.Edge(face[i], face[(i + 1) % face.count])] { loop.append(m) }
    }

    return loop
  }

  /// Copies the selected faces, selecting the copy.
  mutating func duplicate() -> Bool
  {
    let region = selectedFaceList
    guard !region.isEmpty else { return false }
    var copy: [Int: Int] = [:]
    for v in Set(region.flatMap { faces[$0] }).sorted() { copy[v] = addPoint(points[v]) }
    finish(selecting: region.map { topology.addFace(faces[$0].map { copy[$0]! }) })
    return true
  }

  mutating func loopCut(_ edge: Kraken.Edge, at t: Float = 0.5)
  {
    let cut = ring(edge)
    guard cut.count > 1 else { return }
    var middles: [Kraken.Edge: Int] = [:]
    var touched = Set<Int>()
    for e in cut
    {
      if let s = side(e) { touched.formUnion(topology.facesAround(s)) }
      middles[e] = addPoint(simd_mix(points[e.a], points[e.b], SIMD3(repeating: t)))
    }

    for f in touched.sorted()
    {
      let face = faces[f]
      topology.killFace(f)
      let hits = face.count == 4 ? (0 ..< 4).filter { middles[Kraken.Edge(face[$0], face[($0 + 1) % 4])] != nil } : []
      if hits.count == 2, hits[1] - hits[0] == 2
      {
        let i = hits[0]
        let a = middles[Kraken.Edge(face[i], face[(i + 1) % 4])]!, b = middles[Kraken.Edge(face[(i + 2) % 4], face[(i + 3) % 4])]!
        topology.addFace([face[i], a, b, face[(i + 3) % 4]])
        topology.addFace([a, face[(i + 1) % 4], face[(i + 2) % 4], b])
      }
      else
      {
        topology.addFace(split(face, middles))
      }
    }

    let map = rebuild()
    clearSelection()
    let fresh = remap(middles.values, map.verts)
    edges = Set(allEdges.filter { fresh.contains($0.a) && fresh.contains($0.b) })
    verts = fresh
    if mode != .face { flush() }
  }
}
