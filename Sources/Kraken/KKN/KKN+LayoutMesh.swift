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
  struct Edge: Hashable
  {
    let a: Int
    let b: Int

    init(_ x: Int, _ y: Int)
    {
      a = min(x, y)
      b = max(x, y)
    }
  }

  enum SelectMode: Int
  {
    case vertex, edge, face
  }

  /// a mesh in edit mode in its own space with vertex, edge and face selections, its connectivity in a `MeshTopology`
  struct EditMesh
  {
    var path: String
    var points: [SIMD3<Float>]
    private(set) var faces: [[Int]] = []
    private(set) var allEdges: [Edge] = []

    var verts = Set<Int>()
    var edges = Set<Edge>()
    var selectedFaces = Set<Int>()
    var mode: SelectMode = .vertex
    var topology: MeshTopology

    /// how hard subdivision holds each edge, from 0 smooth to 1 fully hard
    var creases: [Edge: Float] = [:]

    /// edges marked sharp, which the shading normals split along
    var sharp = Set<Edge>()

    init(path: String, points: [SIMD3<Float>], faces: [[Int]], creases: [Edge: Float] = [:], sharp: Set<Edge> = [])
    {
      self.path = path
      self.points = points
      topology = MeshTopology(vertexCount: points.count, faces: faces)
      snapshot()

      let present = Set(allEdges)
      self.creases = creases.filter { present.contains($0.key) && $0.value > 0 }
      self.sharp = sharp.intersection(present)
    }

    static func edges(of face: [Int]) -> [Edge]
    {
      face.indices.map { Edge(face[$0], face[($0 + 1) % face.count]) }
    }

    func center(_ face: [Int]) -> SIMD3<Float>
    {
      face.reduce(SIMD3<Float>.zero) { $0 + points[$1] } / Float(max(face.count, 1))
    }

    func normal(_ face: [Int]) -> SIMD3<Float>
    {
      var n = SIMD3<Float>.zero
      for i in face.indices
      {
        let a = points[face[i]], b = points[face[(i + 1) % face.count]]
        n += SIMD3((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y))
      }

      let length = simd_length(n)
      return length > 0 ? n / length : SIMD3(0, 0, 1)
    }

    var selectedFaceList: [Int]
    {
      mode == .face ? selectedFaces.sorted() : faces.indices.filter { faces[$0].allSatisfy(verts.contains) }
    }

    var median: SIMD3<Float>?
    {
      guard !verts.isEmpty else { return nil }
      return verts.reduce(SIMD3<Float>.zero) { $0 + points[$1] } / Float(verts.count)
    }

    // MARK: topology

    /// reads the faces and edges off the topology, whose faces are all alive and in order between ops
    mutating func snapshot()
    {
      faces = topology.faces.indices.compactMap { topology.faces[$0].count > 0 ? topology.corners(of: $0) : nil }
      allEdges = topology.edges.compactMap { $0.loop >= 0 ? Edge($0.v.0, $0.v.1) : nil }
    }

    mutating func addPoint(_ p: SIMD3<Float>) -> Int
    {
      points.append(p)
      return topology.addVert()
    }

    /// renumbers past the faces an op killed and the verts and edges they left unused
    mutating func rebuild() -> (verts: [Int], faces: [Int])
    {
      let (mesh, vertMap, faceMap) = topology.compacted()
      var kept = [SIMD3<Float>](repeating: .zero, count: mesh.verts.count)
      for (old, new) in vertMap.enumerated() where new >= 0 { kept[new] = points[old] }

      points = kept
      topology = mesh
      snapshot()

      // creases and sharp edges follow their verts and are dropped with the edges an op removed
      let present = Set(allEdges)
      var held = [Edge: Float]()
      for (e, c) in creases
      {
        if let m = remap(edge: e, vertMap), present.contains(m) { held[m] = c }
      }

      creases = held
      sharp = Set(sharp.compactMap { remap(edge: $0, vertMap) }).intersection(present)

      return (vertMap, faceMap)
    }

    func remap(edge e: Edge, _ map: [Int]) -> Edge?
    {
      guard e.b < map.count, map[e.a] >= 0, map[e.b] >= 0 else { return nil }
      return Edge(map[e.a], map[e.b])
    }

    func remap(_ list: some Sequence<Int>, _ map: [Int]) -> Set<Int>
    {
      Set(list.compactMap { $0 >= 0 && $0 < map.count && map[$0] >= 0 ? map[$0] : nil })
    }

    func remap(edges list: some Sequence<Edge>, _ map: [Int]) -> Set<Edge>
    {
      Set(list.compactMap
      {
        guard $0.b < map.count, map[$0.a] >= 0, map[$0.b] >= 0 else { return nil }
        return Edge(map[$0.a], map[$0.b])
      })
    }

    /// renumbers after an op and selects the faces it made
    mutating func finish(selecting made: [Int?], verts extra: [Int] = [])
    {
      let map = rebuild()
      select(faces: Array(remap(made.compactMap { $0 }, map.faces)), verts: Array(remap(extra, map.verts)))
    }

    func side(_ e: Edge) -> Int?
    {
      topology.edge(e.a, e.b)
    }

    func pair(_ e: Int) -> Edge
    {
      Edge(topology.edges[e].v.0, topology.edges[e].v.1)
    }
  }
}
