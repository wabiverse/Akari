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

import AkariCore
import Foundation
import HdAkari
import HydraKit
import LabGL

extension Akari.Geom.Deformer
{
  func layOut(_ mesh: Akari.Geom.Recorder.RawMesh, spacing: Float) -> Block
  {
    let count = mesh.points.size()
    let topology: Akari.Geom.Topology
    if let cached = topologies[mesh.key],
       cached.revision == mesh.topologyRevision,
       cached.topology.vertexFaceStart.count == count + 1
    {
      topology = cached.topology
    }
    else
    {
      let (_, tris, uvs) = Akari.Geom.flatten(points: Pixar.VtVec3fArray(), tris: mesh.tris, uvs: mesh.uvs)
      topology = Akari.Geom.topology(trisFlat: tris, uvsFlat: uvs, pointCount: count)
      topologies[mesh.key] = (mesh.topologyRevision, topology)
    }

    let triCount = count > 0 ? topology.triIndices.count / 3 : 0
    var block = Block(topologyRevision: mesh.topologyRevision, flipWinding: mesh.flipWinding, spacing: spacing,
                      pointCount: count, triCount: triCount, faces: [], corners: [], uvs: [], starts: [0], list: [])
    guard triCount > 0 else { return block }
    block.faces.reserveCapacity(triCount * 4)
    block.corners.reserveCapacity(triCount * 6)
    block.uvs.reserveCapacity(triCount * 6)
    let hidden = Self.hiddenEdges(mesh, triangles: topology.triIndices, spacing: spacing)
    let order: (Int, Int, Int) = mesh.flipWinding ? (0, 2, 1) : (0, 1, 2)
    for t in 0 ..< triCount
    {
      let i0 = Int(topology.triIndices[t * 3]), i1 = Int(topology.triIndices[t * 3 + 1]), i2 = Int(topology.triIndices[t * 3 + 2])
      let valid = i0 >= 0 && i0 < count && i1 >= 0 && i1 < count && i2 >= 0 && i2 < count
      block.faces += valid ? [Int32(i0), Int32(i1), Int32(i2), 0] : [-1, -1, -1, 0]
      let index = [i0, i1, i2]
      var bits: Int32 = 0
      if !hidden.isEmpty
      {
        if hidden[t] & (1 << order.0) != 0 { bits |= 1 }
        if hidden[t] & (1 << order.1) != 0 { bits |= 2 }
        if hidden[t] & (1 << order.2) != 0 { bits |= 4 }
      }

      for c in [order.0, order.1, order.2]
      {
        block.corners.append(Int32(valid ? index[c] : 0))
        block.corners.append(Int32(t) | (bits << 28))
        block.uvs.append(topology.triUvs[(t * 3 + c) * 2])
        block.uvs.append(topology.triUvs[(t * 3 + c) * 2 + 1])
      }
    }

    block.starts.reserveCapacity(count + 1)
    block.list.reserveCapacity(topology.vertexFaces.count)
    for p in 0 ..< count
    {
      for k in Int(topology.vertexFaceStart[p]) ..< Int(topology.vertexFaceStart[p + 1])
      {
        block.list.append(topology.vertexFaces[k])
      }

      block.starts.append(Int32(block.list.count))
    }

    return block
  }

  /// Per triangle, the edges (bit c, the edge facing corner c) inside one of the irregular cells
  /// `spacing` wide its rest surface is cut into, so a dense mesh becomes a sparse wireframe. Empty
  /// without a spacing.
  private static func hiddenEdges(_ mesh: Akari.Geom.Recorder.RawMesh, triangles: [Int32], spacing: Float) -> [UInt8]
  {
    let count = mesh.points.size()
    guard spacing > 0, triangles.count >= 3, count > 0 else { return [] }
    let m = mesh.worldMatrix
    let det = m.count == 16
      ? m[0] * (m[5] * m[10] - m[6] * m[9]) - m[1] * (m[4] * m[10] - m[6] * m[8]) + m[2] * (m[4] * m[9] - m[5] * m[8]) : 1
    let cellSize = spacing / max(Float(cbrt(Double(abs(det)))), 1e-6)
    let points = (0 ..< count).map { SIMD3<Float>(mesh.points[$0][0], mesh.points[$0][1], mesh.points[$0][2]) }
    func hash(_ g: SIMD3<Int32>) -> SIMD3<Float>
    {
      var h = UInt32(bitPattern: g.x &* 73_856_093 ^ g.y &* 19_349_663 ^ g.z &* 83_492_791)
      var out = SIMD3<Float>()
      for k in 0 ..< 3
      {
        h ^= h >> 16; h = h &* 0x7FEB_352D; h ^= h >> 15; h = h &* 0x846C_A68B; h ^= h >> 16
        out[k] = Float(h & 0xFFFF) / 65535
      }

      return out
    }

    func cell(_ p: SIMD3<Float>) -> SIMD3<Int32>
    {
      let g = SIMD3<Int32>(p / cellSize, rounding: .down)
      var best = g, distance = Float.infinity
      for dz: Int32 in -1 ... 1
      {
        for dy: Int32 in -1 ... 1
        {
          for dx: Int32 in -1 ... 1
          {
            let n = g &+ SIMD3(dx, dy, dz)
            let seed = (SIMD3<Float>(n) + 0.1 + hash(n) * 0.8) * cellSize
            let d = ((seed - p) * (seed - p)).sum()
            if d < distance { distance = d; best = n }
          }
        }
      }

      return best
    }

    let triCount = triangles.count / 3
    var cells = [SIMD3<Int32>](repeating: .zero, count: triCount)
    /// welded by position, so a uv seam isn't taken for a cell's edge.
    func weld(_ p: Int32) -> SIMD3<Int32>
    {
      let q = points[Int(p)] / (cellSize * 1e-3)
      return SIMD3<Int32>(q, rounding: .toNearestOrEven)
    }

    var welded = [SIMD3<Int32>](repeating: .zero, count: count)
    for p in 0 ..< count
    {
      welded[p] = weld(Int32(p))
    }

    struct Edge: Hashable { var a: SIMD3<Int32>; var b: SIMD3<Int32> }
    var edges: [Edge: [Int32]] = [:]
    edges.reserveCapacity(triCount * 2)
    func key(_ a: Int32, _ b: Int32) -> Edge
    {
      let wa = welded[Int(a)], wb = welded[Int(b)]
      let less = wa.x != wb.x ? wa.x < wb.x : wa.y != wb.y ? wa.y < wb.y : wa.z < wb.z
      return less ? Edge(a: wa, b: wb) : Edge(a: wb, b: wa)
    }

    for t in 0 ..< triCount
    {
      let i = (0 ..< 3).map { triangles[t * 3 + $0] }
      guard i.allSatisfy({ $0 >= 0 && Int($0) < count }) else { continue }
      cells[t] = cell((points[Int(i[0])] + points[Int(i[1])] + points[Int(i[2])]) / 3)
      for c in 0 ..< 3
      {
        edges[key(i[(c + 1) % 3], i[(c + 2) % 3]), default: []].append(Int32(t))
      }
    }

    var hidden = [UInt8](repeating: 0, count: triCount)
    for t in 0 ..< triCount
    {
      let i = (0 ..< 3).map { triangles[t * 3 + $0] }
      guard i.allSatisfy({ $0 >= 0 && Int($0) < count }) else { continue }
      for c in 0 ..< 3
      {
        let shared = edges[key(i[(c + 1) % 3], i[(c + 2) % 3])] ?? []
        if shared.count > 1, shared.allSatisfy({ cells[Int($0)] == cells[t] }) { hidden[t] |= 1 << c }
      }
    }

    return hidden
  }
}
