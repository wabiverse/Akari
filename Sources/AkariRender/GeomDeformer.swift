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

public extension Akari.Geom
{
  /// Deforms the animated meshes on the GPU. Their triangulation is laid out
  /// once into buffers a capture records against, then each frame only their
  /// points and matrices are uploaded and compute rebuilds normals and the
  /// world space vertices in place, the same layout `Batch` writes.
  final class Deformer
  {
    private struct Mesh
    {
      var key: UInt64
      var topologyRevision: UInt64
      var flipWinding: Bool
      var pointCount: Int
      var pointBase: Int
      var cornerBase: Int
      var cornerCount: Int
      var dataRevision: UInt64 = .max
      var worldMatrix: [Float] = []
      var jointBase = 0
      var jointCount = 0
    }

    /// The per mesh matrices, world (16), normal (9) and prim id, padded.
    private static let xfStride = 40
    private static let ring = 3

    private var meshes: [Mesh] = []
    /// Every mesh the layout was built from, empty ones too, by what a rebuild keys on.
    private var inputs: [UInt64: Input] = [:]

    private struct Input
    {
      var topologyRevision: UInt64
      var flipWinding: Bool
      var pointCount: Int
      var tris: Pixar.VtVec3iArray
      var uvs: Pixar.VtVec2fArray
      var skinRevision: UInt64
      var skinInfluencesPerPoint: Int
      var jointCount: Int

      func same(as other: Input) -> Bool
      {
        topologyRevision == other.topologyRevision && flipWinding == other.flipWinding && pointCount == other.pointCount
          && skinRevision == other.skinRevision && skinInfluencesPerPoint == other.skinInfluencesPerPoint && jointCount == other.jointCount
      }
    }

    private var topologies: [UInt64: (revision: UInt64, topology: Akari.Geom.Topology)] = [:]

    /// A mesh's part of the layout, its indices from 0, kept until its triangles, winding or wire spacing change.
    private struct Block
    {
      var topologyRevision: UInt64
      var flipWinding: Bool
      var spacing: Float
      var pointCount: Int
      var triCount: Int
      /// Per triangle its three points, -1 when out of range, and a slot for the mesh index.
      var faces: [Int32]
      /// Per corner its point and its face with the hidden edge bits.
      var corners: [Int32]
      var uvs: [Float]
      /// Each point's faces, from `starts[p]` to `starts[p + 1]`.
      var starts: [Int32]
      var list: [Int32]
    }

    private var blocks: [UInt64: Block] = [:]

    /// The layout's contents, kept to append to.
    private struct Arrays
    {
      var faces: [Int32] = []
      var corners: [Int32] = []
      var uvs: [Float] = []
      var starts: [Int32] = [0]
      var list: [Int32] = []
      var meshOfPoint: [Int32] = []
      var rest: [Float] = []
      var ranges: [Int32] = []
      var weights: [Float] = []
      /// Per triangle its three points, for the shadow capture.
      var shadow: [Int32] = []
    }

    private var arrays = Arrays()
    /// The capture the layout draws into, and the laid out meshes it leaves undrawn while they're hidden.
    private var capture: OpaquePointer?
    private var undrawn: Set<UInt64> = []
    private var capacities: [GLuint: Int] = [:]
    private var pointCount = 0
    private var faceCount = 0
    private var cornerCount = 0

    private var faces: GLuint = 0
    private var corners: GLuint = 0
    private var uvs: GLuint = 0
    private var faceStart: GLuint = 0
    private var faceList: GLuint = 0
    private var pointMesh: GLuint = 0
    private var faceNormals: GLuint = 0
    private var pointNormals: GLuint = 0
    private var points: [GLuint] = []
    private var transforms: [GLuint] = []
    /// GPU skinning: bind space rest points, each point's (first, count) influence range,
    /// the (palette joint, weight) influences, and this frame's joint palette, ringed.
    private var restPoints: GLuint = 0
    private var skinRanges: GLuint = 0
    private var skinWeights: GLuint = 0
    private var palettes: [GLuint] = []
    private var jointCount = 0
    private var cursor = 0
    /// The vertex buffer compute writes, owned by the capture once recorded.
    private var vertices: GLuint = 0
    /// One world space vertex per point, drawn through the triangles' own indices,
    /// for the shadows, which only need positions and so skip the per corner expansion.
    public private(set) var shadowCapture: OpaquePointer?
    private var shadowVertices: GLuint = 0

    private var faceKernel: GLuint = 0
    private var pointKernel: GLuint = 0
    private var emitKernel: GLuint = 0
    private var shadowKernel: GLuint = 0
    private var settleKernel: GLuint = 0
    private var skinKernel: GLuint = 0
    /// Per prim id, how assembled it is and the center of the triangle it collapses to
    /// (assemble, x, y, z), and that triangle's size, negative to center it on the mesh.
    public var assembly: [Int32: SIMD4<Float>] = [:]
    public var assemblySize: [Int32: Float] = [:]
    /// Each prim's wire spacing in world units, its mesh drawing only the edges between cells that wide.
    public var wireSpacing: [Int32: Float] = [:]
    /// Set when the wire spacing changed, or a skinned mesh's skin wasn't whole yet, the next `needsRebuild` relays out.
    public var relayout = false
    /// Relayouts left for skins still arriving, so one that never completes doesn't relay out every frame.
    private var skinRetries = 8
    /// Where the camera is, the collapsed triangle faces it.
    public var eye = SIMD3<Float>(repeating: 0)
    public var zUp = false
    /// The vertices hold last frame's positions, which become this frame's previous ones.
    private var hasHistory = false
    /// The previous positions already match the current ones.
    private var settled = true

    public init() {}

    deinit
    {
      releaseBuffers()
      for kernel in [faceKernel, pointKernel, emitKernel, settleKernel, shadowKernel, skinKernel] where kernel != 0
      {
        gl.deleteComputeShader(kernel)
      }
    }

    /// Whether `meshes` need relaying out (other meshes, or one's triangles changed).
    public func needsRebuild(_ meshes: [Recorder.RawMesh]) -> Bool
    {
      if relayout { return true }
      var seen = Set<UInt64>(minimumCapacity: meshes.count)
      for i in meshes.indices where seen.insert(meshes[i].key).inserted
      {
        let key = meshes[i].key
        guard
          let old = inputs[key],
          old.flipWinding == meshes[i].flipWinding,
          old.pointCount == meshes[i].points.size(),
          old.skinRevision == meshes[i].skinRevision,
          old.skinInfluencesPerPoint == meshes[i].skinInfluencesPerPoint,
          old.jointCount == meshes[i].skinPalette.count / 12
        else { return true }
        guard old.topologyRevision != meshes[i].topologyRevision else { continue }

        // a resync can bump the revision with the same triangles, only a real change relays out.
        guard Pixar.HdAkariSameTopology(old.tris, meshes[i].tris, old.uvs, meshes[i].uvs) else { return true }
        inputs[key]?.topologyRevision = meshes[i].topologyRevision
        if let cached = topologies[key] { topologies[key] = (meshes[i].topologyRevision, cached.topology) }
      }
      return seen.count != inputs.count
    }

    /// Lays `meshes` out and records their draws into `capture`, one per mesh.
    /// The meshes already laid out keep their place, so unless one of them
    /// changed only the new ones are laid out and uploaded.
    public func rebuild(_ meshes: [Recorder.RawMesh], into capture: OpaquePointer)
    {
      relayout = false
      guard ensureKernels() else { return }
      self.capture = capture
      undrawn = []
      let order = Dictionary(self.meshes.indices.map { (self.meshes[$0].key, $0) }, uniquingKeysWith: { a, _ in a })
      let meshes = Self.unique(meshes).sorted { (order[$0.key] ?? .max) < (order[$1.key] ?? .max) }
      let next = Dictionary(meshes.map { ($0.key, Self.input($0)) }, uniquingKeysWith: { a, _ in a })
      let byKey = Dictionary(meshes.map { ($0.key, $0) }, uniquingKeysWith: { a, _ in a })
      let appending = !self.meshes.isEmpty && inputs.allSatisfy
      { key, old in
        guard let new = next[key], let mesh = byKey[key] else { return false }
        return old.same(as: new) && (blocks[key].map { $0.spacing == wireSpacing[mesh.primId] ?? 0 } ?? true)
      }
      if !appending
      {
        releaseBuffers()
        arrays = Arrays()
        self.meshes = []
        let live = Set(meshes.map(\.key))
        topologies = topologies.filter { live.contains($0.key) }
        blocks = blocks.filter { live.contains($0.key) }
      }
      labgl.captureClear(capture)
      if shadowCapture == nil { shadowCapture = labgl.captureCreate() }
      if let shadowCapture { labgl.captureClear(shadowCapture) }
      let start = (faces: arrays.faces.count, corners: arrays.corners.count, uvs: arrays.uvs.count, starts: arrays.starts.count,
                   list: arrays.list.count, points: arrays.meshOfPoint.count, rest: arrays.rest.count, ranges: arrays.ranges.count,
                   weights: arrays.weights.count)
      let laidOut = appending ? Set(inputs.keys) : []
      inputs = next

      var incomplete = false
      for mesh in meshes where !laidOut.contains(mesh.key)
      {
        let count = mesh.points.size()
        let spacing = wireSpacing[mesh.primId] ?? 0
        let block: Block
        if let cached = blocks[mesh.key],
           cached.topologyRevision == mesh.topologyRevision,
           cached.flipWinding == mesh.flipWinding,
           cached.spacing == spacing,
           cached.pointCount == count
        {
          block = cached
        }
        else
        {
          block = layOut(mesh, spacing: spacing)
          blocks[mesh.key] = block
        }
        guard count > 0, block.triCount > 0 else { continue }
        let joints = mesh.skinPalette.count / 12
        let skinned = mesh.skinInfluencesPerPoint > 0 && joints > 0 && mesh.skinInfluences.size() == count * mesh.skinInfluencesPerPoint
        // a skin whose palette or weights haven't caught up with its
        // points get laid out unskinned and tried again next frame.
        if mesh.skinInfluencesPerPoint > 0, !skinned, skinRetries > 0 { incomplete = true }
        append(block, mesh, skinned: skinned)
      }
      if incomplete { relayout = true; skinRetries -= 1 } else { skinRetries = 8 }
      guard cornerCount > 0 else { return }

      let read = LGL_BUFFER_COMPUTE_READ | LGL_BUFFER_MAP_WRITE
      store(&faces, arrays.faces, from: start.faces, usage: read)
      store(&corners, arrays.corners, from: start.corners, usage: read)
      store(&uvs, arrays.uvs, from: start.uvs, usage: read)
      store(&faceStart, arrays.starts, from: start.starts, usage: read)
      store(&faceList, arrays.list.isEmpty ? [0] : arrays.list, from: start.list, usage: read)
      store(&pointMesh, arrays.meshOfPoint, from: start.points, usage: read)
      if jointCount > 0
      {
        store(&restPoints, arrays.rest, from: start.rest, usage: read)
        store(&skinRanges, arrays.ranges, from: start.ranges, usage: read)
        store(&skinWeights, arrays.weights.isEmpty ? [0, 0] : arrays.weights, from: start.weights, usage: read)
        if palettes.isEmpty { palettes = [GLuint](repeating: 0, count: Self.ring) }
        for i in palettes.indices
        {
          reserve(&palettes[i], bytes: jointCount * 48, usage: read)
        }
      }

      let scratch = LGL_BUFFER_COMPUTE_READ | LGL_BUFFER_COMPUTE_WRITE
      reserve(&faceNormals, bytes: faceCount * 16, usage: scratch)
      reserve(&pointNormals, bytes: pointCount * 16, usage: scratch)
      if points.isEmpty { points = [GLuint](repeating: 0, count: Self.ring) }
      if transforms.isEmpty { transforms = [GLuint](repeating: 0, count: Self.ring) }
      for i in 0 ..< Self.ring
      {
        reserve(&points[i], bytes: pointCount * 12, usage: read)
        reserve(&transforms[i], bytes: self.meshes.count * Self.xfStride * 4, usage: read)
      }

      vertices = record(into: capture, vertexCount: cornerCount, indices: Array(0 ..< Int32(cornerCount)))
      hasHistory = false
      settled = true
      if let shadowCapture
      {
        shadowVertices = record(into: shadowCapture, vertexCount: pointCount, indices: arrays.shadow)
      }
    }

    /// Adds `block` for `mesh` to the end of the layout.
    private func append(_ block: Block, _ mesh: Recorder.RawMesh, skinned: Bool)
    {
      let count = block.pointCount
      let pointBase = Int32(pointCount), faceBase = Int32(faceCount), cornerBase = cornerCount
      let meshIndex = Int32(meshes.count)
      arrays.faces.reserveCapacity(arrays.faces.count + block.faces.count)
      arrays.shadow.reserveCapacity(arrays.shadow.count + block.triCount * 3)
      for f in stride(from: 0, to: block.faces.count, by: 4)
      {
        let valid = block.faces[f] >= 0
        for k in 0 ..< 3
        {
          arrays.faces.append(valid ? block.faces[f + k] + pointBase : -1)
          arrays.shadow.append(valid ? block.faces[f + k] + pointBase : 0)
        }
        arrays.faces.append(meshIndex)
      }
      arrays.corners.reserveCapacity(arrays.corners.count + block.corners.count)
      for c in stride(from: 0, to: block.corners.count, by: 2)
      {
        arrays.corners.append(block.corners[c] + pointBase)
        arrays.corners.append(block.corners[c + 1] + faceBase)
      }
      arrays.uvs.append(contentsOf: block.uvs)
      let listBase = Int32(arrays.list.count)
      arrays.list.reserveCapacity(arrays.list.count + block.list.count)
      for f in block.list
      {
        arrays.list.append(f + faceBase)
      }
      for p in 1 ... count
      {
        arrays.starts.append(block.starts[p] + listBase)
      }
      arrays.meshOfPoint.append(contentsOf: repeatElement(meshIndex, count: count))

      let joints = mesh.skinPalette.count / 12
      let k = skinned ? mesh.skinInfluencesPerPoint : 0
      if skinned
      {
        arrays.rest += Akari.Geom.flatten(points: mesh.points)
        arrays.weights.reserveCapacity(arrays.weights.count + count * k * 2)
        for p in 0 ..< count
        {
          arrays.ranges.append(Int32(arrays.weights.count / 2))
          arrays.ranges.append(Int32(k))
          for c in 0 ..< k
          {
            let w = mesh.skinInfluences[p * k + c]
            arrays.weights.append(Float(jointCount + Int(w[0])))
            arrays.weights.append(w[1])
          }
        }
      }
      else
      {
        arrays.rest.append(contentsOf: repeatElement(0, count: count * 3))
        arrays.ranges.append(contentsOf: repeatElement(0, count: count * 2))
      }

      meshes.append(Mesh(key: mesh.key,
                         topologyRevision: mesh.topologyRevision,
                         flipWinding: mesh.flipWinding,
                         pointCount: count,
                         pointBase: Int(pointBase),
                         cornerBase: cornerBase,
                         cornerCount: block.triCount * 3,
                         jointBase: k > 0 ? jointCount : 0,
                         jointCount: k > 0 ? joints : 0))
      if k > 0 { jointCount += joints }
      pointCount += count
      faceCount += block.triCount
      cornerCount += block.triCount * 3
    }

    private static func input(_ mesh: Recorder.RawMesh) -> Input
    {
      Input(topologyRevision: mesh.topologyRevision,
            flipWinding: mesh.flipWinding,
            pointCount: mesh.points.size(),
            tris: mesh.tris,
            uvs: mesh.uvs,
            skinRevision: mesh.skinRevision,
            skinInfluencesPerPoint: mesh.skinInfluencesPerPoint,
            jointCount: mesh.skinPalette.count / 12)
    }

    /// Writes `values` from `start` on into `buffer`, which grows by half again once they no longer fit.
    private func store<T>(_ buffer: inout GLuint, _ values: [T], from start: Int, usage: GLuint)
    {
      let size = MemoryLayout<T>.stride
      var from = start
      if buffer == 0 || capacities[buffer, default: 0] < values.count * size
      {
        reserve(&buffer, bytes: values.count * size, usage: usage)
        from = 0
      }
      guard from < values.count, let p = gl.mapBuffer(buffer) else { return }
      values.withUnsafeBytes { (p + from * size).copyMemory(from: $0.baseAddress! + from * size, byteCount: (values.count - from) * size) }
      gl.unmapBuffer(buffer)
    }

    /// Makes `buffer` hold at least `bytes`, half again more when it has to grow, its contents lost.
    private func reserve(_ buffer: inout GLuint, bytes: Int, usage: GLuint)
    {
      if buffer != 0, capacities[buffer, default: 0] >= bytes { return }
      if buffer != 0 { gl.deleteBuffer(buffer); capacities[buffer] = nil }
      let capacity = max(bytes + bytes / 2, 16)
      buffer = gl.createBuffer(usage: usage, sizeBytes: GLsizei(capacity))
      capacities[buffer] = capacity
    }

    private func layOut(_ mesh: Recorder.RawMesh, spacing: Float) -> Block
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
    private static func hiddenEdges(_ mesh: Recorder.RawMesh, triangles: [Int32], spacing: Float) -> [UInt8]
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

    /// Uploads this frame's points and matrices and deforms on the GPU.
    /// Returns the bounds, per mesh caster bounds and keys, in draw order.
    public func update(_ meshes: [Recorder.RawMesh]) -> (bounds: (min: SIMD3<Float>, max: SIMD3<Float>)?,
                                                         casterBounds: [Float], casterKeys: [UInt64])
    {
      guard
        cornerCount > 0,
        !points.isEmpty
      else { return (nil, [], []) }

      let given = Set(meshes.lazy.map(\.key))
      let hidden = Set(self.meshes.lazy.map(\.key).filter { !given.contains($0) })
      if hidden != undrawn, let capture
      {
        undrawn = hidden
        labgl.captureClear(capture)
        vertices = record(into: capture, vertexCount: cornerCount, indices: Array(0 ..< Int32(cornerCount)))
        if let shadowCapture
        {
          labgl.captureClear(shadowCapture)
          shadowVertices = record(into: shadowCapture, vertexCount: pointCount, indices: arrays.shadow)
        }
        hasHistory = false
      }

      cursor = (cursor + 1) % Self.ring
      guard
        let pointPtr = gl.mapBuffer(points[cursor])?.assumingMemoryBound(to: Float.self),
        let xfPtr = gl.mapBuffer(transforms[cursor])?.assumingMemoryBound(to: Float.self)
      else { return (nil, [], []) }
      let palettePtr = palettes.isEmpty ? nil : gl.mapBuffer(palettes[cursor])?.assumingMemoryBound(to: Float.self)

      let indexOf = Dictionary(meshes.indices.map { (meshes[$0].key, $0) }, uniquingKeysWith: { a, _ in a })
      var casterBounds: [Float] = []
      var casterKeys: [UInt64] = []
      casterBounds.reserveCapacity(self.meshes.count * 6)
      var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo

      for (index, laidOut) in self.meshes.enumerated()
      {
        // a mesh laid out but not given this frame collapses to a point, so it draws nothing.
        guard let i = indexOf[laidOut.key]
        else
        {
          (xfPtr + index * Self.xfStride).update(repeating: 0, count: Self.xfStride)
          xfPtr[index * Self.xfStride + 37] = 1
          continue
        }
        var local = [Float](repeating: 0, count: 6)
        if laidOut.jointCount > 0, let palettePtr, meshes[i].skinPalette.count == laidOut.jointCount * 12
        {
          meshes[i].skinPalette.withUnsafeBufferPointer
          {
            (palettePtr + laidOut.jointBase * 12).update(from: $0.baseAddress!, count: $0.count)
          }
          local = meshes[i].skinBounds
        }
        else
        {
          // its palette changed size since the layout, relay out rather than skin with the old one.
          if laidOut.jointCount > 0 { relayout = true }
          Pixar.HdAkariCopyPoints(meshes[i].points, pointPtr + laidOut.pointBase * 3, &local)
        }

        let xf = xfPtr + index * Self.xfStride
        let m = meshes[i].worldMatrix
        for k in 0 ..< 16
        {
          xf[k] = m[k]
        }
        for k in 0 ..< 9
        {
          xf[16 + k] = meshes[i].normalMatrix[k]
        }
        xf[25] = Float(meshes[i].primId)

        var wlo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), whi = -wlo
        for corner in 0 ..< 8
        {
          let p = SIMD3(corner & 1 != 0 ? local[3] : local[0],
                        corner & 2 != 0 ? local[4] : local[1],
                        corner & 4 != 0 ? local[5] : local[2])
          let w = SIMD3(m[0] * p.x + m[4] * p.y + m[8] * p.z + m[12],
                        m[1] * p.x + m[5] * p.y + m[9] * p.z + m[13],
                        m[2] * p.x + m[6] * p.y + m[10] * p.z + m[14])
          wlo = pointwiseMin(wlo, w)
          whi = pointwiseMax(whi, w)
        }
        let assemble = assembly[meshes[i].primId] ?? SIMD4(1, 0, 0, 0)
        let size = assemblySize[meshes[i].primId] ?? -0.4
        let center = size < 0 ? (wlo + whi) * 0.5 : SIMD3(assemble.y, assemble.z, assemble.w)
        xf[26] = assemble.x
        xf[27] = center.x
        xf[28] = center.y
        xf[29] = center.z
        xf[30] = abs(size)
        xf[31] = zUp ? 1 : 0
        xf[32] = eye.x
        xf[33] = eye.y
        xf[34] = eye.z
        xf[35] = Float(laidOut.cornerBase / 3)
        xf[36] = Float(laidOut.cornerCount / 3)
        xf[37] = 0
        casterBounds += [wlo.x, wlo.y, wlo.z, whi.x, whi.y, whi.z]
        lo = pointwiseMin(lo, wlo)
        hi = pointwiseMax(hi, whi)

        var key = (14_695_981_039_346_656_037 ^ meshes[i].dataRevision) &* 1_099_511_628_211
        for value in m
        {
          key = (key ^ UInt64(value.bitPattern)) &* 1_099_511_628_211
        }
        casterKeys.append(key)
      }
      gl.unmapBuffer(points[cursor])
      gl.unmapBuffer(transforms[cursor])
      if palettePtr != nil { gl.unmapBuffer(palettes[cursor]) }

      dispatch()
      return (lo.x <= hi.x ? (lo, hi) : nil, casterBounds, casterKeys)
    }

    private func dispatch()
    {
      if jointCount > 0
      {
        setCount(skinKernel, pointCount)
        gl.setComputeShaderBuffer(skinKernel, binding: 0, buffer: skinRanges)
        gl.setComputeShaderBuffer(skinKernel, binding: 1, buffer: skinWeights)
        gl.setComputeShaderBuffer(skinKernel, binding: 2, buffer: palettes[cursor])
        gl.setComputeShaderBuffer(skinKernel, binding: 3, buffer: restPoints)
        gl.setComputeShaderBuffer(skinKernel, binding: 4, buffer: points[cursor])
        gl.dispatchCompute(skinKernel, groupsX: GLuint((pointCount + 63) / 64), groupsY: 1, groupsZ: 1)
      }

      setCount(faceKernel, faceCount)
      gl.setComputeShaderBuffer(faceKernel, binding: 0, buffer: faces)
      gl.setComputeShaderBuffer(faceKernel, binding: 1, buffer: points[cursor])
      gl.setComputeShaderBuffer(faceKernel, binding: 2, buffer: faceNormals)
      gl.dispatchCompute(faceKernel, groupsX: GLuint((faceCount + 63) / 64), groupsY: 1, groupsZ: 1)

      setCount(pointKernel, pointCount)
      gl.setComputeShaderBuffer(pointKernel, binding: 0, buffer: faceStart)
      gl.setComputeShaderBuffer(pointKernel, binding: 1, buffer: faceList)
      gl.setComputeShaderBuffer(pointKernel, binding: 2, buffer: faceNormals)
      gl.setComputeShaderBuffer(pointKernel, binding: 3, buffer: pointNormals)
      gl.dispatchCompute(pointKernel, groupsX: GLuint((pointCount + 63) / 64), groupsY: 1, groupsZ: 1)

      setCount(emitKernel, cornerCount, flag: hasHistory)
      hasHistory = true
      settled = false
      gl.setComputeShaderBuffer(emitKernel, binding: 0, buffer: corners)
      gl.setComputeShaderBuffer(emitKernel, binding: 1, buffer: uvs)
      gl.setComputeShaderBuffer(emitKernel, binding: 2, buffer: points[cursor])
      gl.setComputeShaderBuffer(emitKernel, binding: 3, buffer: pointNormals)
      gl.setComputeShaderBuffer(emitKernel, binding: 4, buffer: faceNormals)
      gl.setComputeShaderBuffer(emitKernel, binding: 5, buffer: pointMesh)
      gl.setComputeShaderBuffer(emitKernel, binding: 6, buffer: transforms[cursor])
      gl.setComputeShaderBuffer(emitKernel, binding: 7, buffer: vertices)
      gl.dispatchCompute(emitKernel, groupsX: GLuint((cornerCount + 63) / 64), groupsY: 1, groupsZ: 1)

      guard shadowVertices != 0 else { return }
      setCount(shadowKernel, pointCount)
      gl.setComputeShaderBuffer(shadowKernel, binding: 0, buffer: points[cursor])
      gl.setComputeShaderBuffer(shadowKernel, binding: 1, buffer: pointMesh)
      gl.setComputeShaderBuffer(shadowKernel, binding: 2, buffer: transforms[cursor])
      gl.setComputeShaderBuffer(shadowKernel, binding: 3, buffer: shadowVertices)
      gl.dispatchCompute(shadowKernel, groupsX: GLuint((pointCount + 63) / 64), groupsY: 1, groupsZ: 1)
    }

    /// Records one draw per mesh against the vertex buffer compute fills,
    /// the capture takes the vertex and index buffers over at their unmap.
    /// Records one draw per mesh, by its corner range of `indices`, against a vertex
    /// buffer compute fills, the capture takes both over at their unmap. Returns that buffer.
    private func record(into capture: OpaquePointer, vertexCount: Int, indices indexData: [Int32]) -> GLuint
    {
      let stride = Batch.vertexStride
      let vertices = gl.createBuffer(usage: LGL_BUFFER_VERTEX | LGL_BUFFER_COMPUTE_WRITE | LGL_BUFFER_MAP_WRITE
        | LGL_BUFFER_CAPTURE_ADOPT,
        sizeBytes: GLsizei(max(vertexCount, 1) * stride))
      let indices = gl.createBuffer(usage: LGL_BUFFER_INDEX | LGL_BUFFER_MAP_WRITE | LGL_BUFFER_CAPTURE_ADOPT,
                                    sizeBytes: GLsizei(max(indexData.count, 1) * 4))
      guard vertices != 0, indices != 0 else { return 0 }
      if let p = gl.mapBuffer(indices)
      {
        indexData.withUnsafeBytes { p.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
      }

      gl.bindTexture(target: GL_TEXTURE_2D, texture: 0)
      labgl.captureStart(capture)
      _ = gl.mapBuffer(vertices)
      gl.unmapBuffer(vertices)
      gl.unmapBuffer(indices)

      gl.enable(GL_DEPTH_TEST)
      gl.depthFunc(GLenum(GL_GREATER))
      gl.disable(GL_CULL_FACE)
      gl.frontFace(GL_CCW)

      gl.bindBuffer(target: GL_ARRAY_BUFFER, buffer: vertices)
      gl.bindBuffer(target: GL_ELEMENT_ARRAY_BUFFER, buffer: indices)
      gl.enableClientState(GL_VERTEX_ARRAY)
      gl.enableClientState(GL_COLOR_ARRAY)
      gl.enableClientState(GL_TEXTURE_COORD_ARRAY)
      gl.enableClientState(GL_NORMAL_ARRAY)
      let floatBytes = MemoryLayout<Float>.stride
      gl.vertexPointer(size: 4, type: GL_FLOAT, stride: GLsizei(stride), pointer: .init(bitPattern: 0 * floatBytes))
      gl.colorPointer(size: 4, type: GL_FLOAT, stride: GLsizei(stride), pointer: .init(bitPattern: 4 * floatBytes))
      gl.texCoordPointer(size: 2, type: GL_FLOAT, stride: GLsizei(stride), pointer: .init(bitPattern: 8 * floatBytes))
      gl.normalPointer(type: GL_FLOAT, stride: GLsizei(stride), pointer: .init(bitPattern: 10 * floatBytes))

      // the real bounds arrive per frame, these only keep the capture from scanning.
      let unbounded: [Float] = [-1e30, -1e30, -1e30, 1e30, 1e30, 1e30]
      for mesh in meshes where !undrawn.contains(mesh.key)
      {
        unbounded.withUnsafeBufferPointer { labgl.captureNextDrawBounds($0.baseAddress!) }
        gl.drawElements(mode: GL_TRIANGLES,
                        count: Int32(mesh.cornerCount),
                        type: GL_UNSIGNED_INT,
                        indices: .init(bitPattern: mesh.cornerBase * 4))
      }

      gl.disableClientState(GL_NORMAL_ARRAY)
      gl.disableClientState(GL_TEXTURE_COORD_ARRAY)
      gl.disableClientState(GL_COLOR_ARRAY)
      gl.disableClientState(GL_VERTEX_ARRAY)
      gl.bindBuffer(target: GL_ARRAY_BUFFER, buffer: 0)
      gl.bindBuffer(target: GL_ELEMENT_ARRAY_BUFFER, buffer: 0)
      labgl.captureStop()
      return vertices
    }

    /// The first of any meshes sharing an id.
    private static func unique(_ meshes: [Recorder.RawMesh]) -> [Recorder.RawMesh]
    {
      var seen = Set<UInt64>()
      return meshes.filter { seen.insert($0.key).inserted }
    }

    /// Zeroes the motion of a frame nothing deformed in, once.
    public func settle()
    {
      guard !settled, hasHistory, settleKernel != 0, vertices != 0, cornerCount > 0 else { return }
      settled = true
      setCount(settleKernel, cornerCount)
      gl.setComputeShaderBuffer(settleKernel, binding: 0, buffer: vertices)
      gl.dispatchCompute(settleKernel, groupsX: GLuint((cornerCount + 63) / 64), groupsY: 1, groupsZ: 1)
    }

    private func setCount(_ kernel: GLuint, _ count: Int, flag: Bool = false)
    {
      var params = SIMD4<Int32>(Int32(count), flag ? 1 : 0, 0, 0)
      gl.setComputeShaderUniform(kernel, name: "u_params", type: GL_INT_VEC4, data: &params)
    }

    /// Everything but `vertices`, which the capture owns and frees on its clear.
    private func releaseBuffers()
    {
      for buffer in [faces, corners, uvs, faceStart, faceList, pointMesh, faceNormals, pointNormals,
                     restPoints, skinRanges, skinWeights]
        + points + transforms + palettes where buffer != 0
      {
        gl.deleteBuffer(buffer)
      }
      faces = 0; corners = 0; uvs = 0; faceStart = 0; faceList = 0; pointMesh = 0
      faceNormals = 0; pointNormals = 0; points = []; transforms = []; vertices = 0; shadowVertices = 0
      restPoints = 0; skinRanges = 0; skinWeights = 0; palettes = []
      pointCount = 0; faceCount = 0; cornerCount = 0; jointCount = 0
      capacities = [:]
    }

    private func ensureKernels() -> Bool
    {
      if faceKernel == 0
      {
        faceKernel = gl.precompileComputeShader(name: "akari-deform-faces", glsl: Self.faceGLSL, msl: Self.faceMSL)
        pointKernel = gl.precompileComputeShader(name: "akari-deform-points", glsl: Self.pointGLSL, msl: Self.pointMSL)
        emitKernel = gl.precompileComputeShader(name: "akari-deform-emit", glsl: Self.emitGLSL, msl: Self.emitMSL)
        settleKernel = gl.precompileComputeShader(name: "akari-deform-settle", glsl: Self.settleGLSL, msl: Self.settleMSL)
        shadowKernel = gl.precompileComputeShader(name: "akari-deform-shadow", glsl: Self.shadowGLSL, msl: Self.shadowMSL)
        skinKernel = gl.precompileComputeShader(name: "akari-deform-skin", glsl: Self.skinGLSL, msl: Self.skinMSL)
        for kernel in [faceKernel, pointKernel, emitKernel, shadowKernel, settleKernel, skinKernel]
        {
          gl.setComputeShaderThreadgroupSize(kernel, x: 64, y: 1, z: 1)
        }
      }
      return [faceKernel, pointKernel, emitKernel, shadowKernel, settleKernel, skinKernel].allSatisfy
      {
        $0 != 0 && gl.waitComputeShader($0) != 0
      }
    }
  }
}

extension Akari.Geom.Deformer
{
  /// Per point of a GPU skinned mesh, its rest point blended by its joints' matrices,
  /// UsdSkel's linear blend skinning, into the points the rest of the deform reads.
  static let skinBody = """
      if (int(gid) >= PARAMS.x) return;
      INT2 r = skin_ranges[gid];
      if (r.y == 0) return;
      VEC4 h = VEC4(rest[gid * 3], rest[gid * 3 + 1], rest[gid * 3 + 2], 1.0);
      VEC3 p = VEC3(0.0);
      for (int i = 0; i < r.y; ++i)
      {
        VEC2 w = skin_weights[r.x + i];
        if (w.y <= 1e-5) continue;
        int j = int(w.x) * 3;
        p += w.y * VEC3(dot(palette[j], h), dot(palette[j + 1], h), dot(palette[j + 2], h));
      }
      points[gid * 3] = p.x;
      points[gid * 3 + 1] = p.y;
      points[gid * 3 + 2] = p.z;
    """

  static let skinGLSL = glslPrelude + """
    layout(std430, binding = 0) buffer SkinRanges { ivec2 skin_ranges[]; };
    layout(std430, binding = 1) buffer SkinWeights { vec2 skin_weights[]; };
    layout(std430, binding = 2) buffer Palette { vec4 palette[]; };
    layout(std430, binding = 3) buffer Rest { float rest[]; };
    layout(std430, binding = 4) buffer Points { float points[]; };
    void main()
    {
      uint gid = gl_GlobalInvocationID.x;
      \(skinBody)
    }
    """

  static let skinMSL = mslPrelude + """
    kernel void compute_main(constant U& u [[buffer(0)]],
                             device const int2* skin_ranges [[buffer(1)]],
                             device const float2* skin_weights [[buffer(2)]],
                             device const float4* palette [[buffer(3)]],
                             device const float* rest [[buffer(4)]],
                             device float* points [[buffer(5)]],
                             uint gid [[thread_position_in_grid]])
    {
      \(skinBody)
    }
    """

  /// Per triangle: its unit normal, and its doubled area for the smooth weighting.
  static let faceBody = """
      if (int(gid) >= PARAMS.x) return;
      INT4 f = faces[gid];
      if (f.x < 0) { face_normals[gid] = VEC4(0.0); return; }
      VEC3 p0 = VEC3(points[f.x * 3], points[f.x * 3 + 1], points[f.x * 3 + 2]);
      VEC3 p1 = VEC3(points[f.y * 3], points[f.y * 3 + 1], points[f.y * 3 + 2]);
      VEC3 p2 = VEC3(points[f.z * 3], points[f.z * 3 + 1], points[f.z * 3 + 2]);
      VEC3 n = cross(p1 - p0, p2 - p0);
      float l = length(n);
      face_normals[gid] = l > 1e-8 ? VEC4(n / l, l) : VEC4(0.0);
    """

  /// Per point: the area weighted smooth normal, and whether its faces meet within 30°.
  static let pointBody = """
      if (int(gid) >= PARAMS.x) return;
      int s = face_start[gid], e = face_start[gid + 1];
      VEC3 sum = VEC3(0.0);
      for (int i = s; i < e; ++i) { VEC4 fn = face_normals[face_list[i]]; sum += fn.xyz * fn.w; }
      float sl = length(sum);
      VEC3 smooth_n = sl > 1e-8 ? sum / sl : VEC3(0.0, 1.0, 0.0);
      bool is_smooth = true;
      for (int a = s; a < e && is_smooth; ++a)
      {
        VEC4 na = face_normals[face_list[a]];
        if (na.w <= 0.0) continue;
        for (int b = a + 1; b < e; ++b)
        {
          VEC4 nb = face_normals[face_list[b]];
          if (nb.w <= 0.0) continue;
          if (dot(na.xyz, nb.xyz) <= 0.8660254) { is_smooth = false; break; }
        }
      }
      point_normals[gid] = VEC4(smooth_n, is_smooth ? 1.0 : 0.0);
    """

  /// Per triangle corner: the world space vertex `Batch` lays out.
  static let emitBody = """
      if (int(gid) >= PARAMS.x) return;
      INT2 c = corners[gid];
      int p = c.x;
      int face = c.y & 0x0FFFFFFF;
      int base = point_mesh[p] * 40;
      VEC3 lp = VEC3(points[p * 3], points[p * 3 + 1], points[p * 3 + 2]);
      VEC4 pn = point_normals[p];
      VEC4 fn = face_normals[face];
      VEC3 n = (pn.w > 0.5 || fn.w <= 0.0) ? pn.xyz : fn.xyz;
      int o = int(gid) * 14;
      VEC3 wp = VEC3(xf[base + 0] * lp.x + xf[base + 4] * lp.y + xf[base + 8] * lp.z + xf[base + 12],
                     xf[base + 1] * lp.x + xf[base + 5] * lp.y + xf[base + 9] * lp.z + xf[base + 13],
                     xf[base + 2] * lp.x + xf[base + 6] * lp.y + xf[base + 10] * lp.z + xf[base + 14]);
      VEC3 nw = VEC3(xf[base + 16] * n.x + xf[base + 17] * n.y + xf[base + 18] * n.z,
                     xf[base + 19] * n.x + xf[base + 20] * n.y + xf[base + 21] * n.z,
                     xf[base + 22] * n.x + xf[base + 23] * n.y + xf[base + 24] * n.z);
      int k = int(gid) % 3;
      float s = 1.0;
      if (xf[base + 26] < 0.9999)
      {
        VEC3 center = VEC3(xf[base + 27], xf[base + 28], xf[base + 29]);
        float size = xf[base + 30];
        VEC3 up = xf[base + 31] > 0.5 ? VEC3(0.0, 0.0, 1.0) : VEC3(0.0, 1.0, 0.0);
        VEC3 toEye = VEC3(xf[base + 32], xf[base + 33], xf[base + 34]) - center;
        VEC3 fwd = length(toEye) > 1e-6 ? normalize(toEye) : VEC3(0.0, 0.0, 1.0);
        VEC3 side = cross(up, fwd);
        side = length(side) > 1e-6 ? normalize(side) : VEC3(1.0, 0.0, 0.0);
        VEC3 lift = cross(fwd, side);
        float angle = 1.5707963 + float(k) * 2.0943951;
        VEC3 target = center + (side * cos(angle) + lift * sin(angle)) * size;
        float hash = fract(sin(float(int(gid) / 3) * 12.9898) * 43758.5453);
        // ensures that a dense mesh isn't drawn a few hundred thousand times over the same pixels.
        int local = int(gid) / 3 - int(xf[base + 35]);
        bool spare = local != 0;
        VEC3 slot = center;
        if (spare)
        {
          float a = fract(sin(float(int(gid) / 3) * 78.233) * 24634.6345);
          float b = fract(sin(float(int(gid) / 3) * 39.3468) * 11789.5523);
          if (a + b > 1.0) { a = 1.0 - a; b = 1.0 - b; }
          VEC3 c0 = center + (side * cos(1.5707963) + lift * sin(1.5707963)) * size;
          VEC3 c1 = center + (side * cos(3.6651914) + lift * sin(3.6651914)) * size;
          VEC3 c2 = center + (side * cos(5.7595865) + lift * sin(5.7595865)) * size;
          slot = c0 + (c1 - c0) * a + (c2 - c0) * b;
          target = slot + (target - center) * (1.6 / sqrt(max(xf[base + 36], 1.0)));
        }
        float reach = clamp(length(wp - center) / max(size * 6.0, 1e-4), 0.0, 1.0);
        float t = clamp(xf[base + 26] * 1.6 - 0.6 * (0.35 * hash + 0.65 * reach), 0.0, 1.0);
        s = t * t * (3.0 - 2.0 * t);
        wp = mix(target, wp, s) + fwd * (sin(3.14159265 * s) * size * 0.5);
        // still in its slot, under the collapsed triangle: nothing to draw.
        if (spare && s < 0.02) wp = slot;
        nw = mix(fwd, nw, s);
      }
      // hidden meshes points are never written, it collapses to the origin.
      if (xf[base + 37] > 0.5) { wp = VEC3(0.0); nw = VEC3(0.0, 0.0, 1.0); }
      VEC3 prev = PARAMS.y != 0 && xf[base + 37] < 0.5 ? VEC3(out_verts[o + 0], out_verts[o + 1], out_verts[o + 2]) : wp;
      out_verts[o + 0] = wp.x;
      out_verts[o + 1] = wp.y;
      out_verts[o + 2] = wp.z;
      out_verts[o + 3] = float(k) * 2.0 + s + float((c.y >> 28) & 7) * 8.0;
      out_verts[o + 4] = xf[base + 25];
      out_verts[o + 5] = prev.x;
      out_verts[o + 6] = prev.y;
      out_verts[o + 7] = prev.z;
      out_verts[o + 8] = uvs[gid].x;
      out_verts[o + 9] = uvs[gid].y;
      out_verts[o + 10] = nw.x;
      out_verts[o + 11] = nw.y;
      out_verts[o + 12] = nw.z;
      out_verts[o + 13] = float(int(gid) / 3);
    """

  /// Per point, its world position once, for the shadows indexed draws.
  static let shadowBody = """
      if (int(gid) >= PARAMS.x) return;
      int p = int(gid);
      int base = point_mesh[p] * 40;
      VEC3 lp = VEC3(points[p * 3], points[p * 3 + 1], points[p * 3 + 2]);
      int o = p * 14;
      out_verts[o + 0] = xf[base + 0] * lp.x + xf[base + 4] * lp.y + xf[base + 8] * lp.z + xf[base + 12];
      out_verts[o + 1] = xf[base + 1] * lp.x + xf[base + 5] * lp.y + xf[base + 9] * lp.z + xf[base + 13];
      out_verts[o + 2] = xf[base + 2] * lp.x + xf[base + 6] * lp.y + xf[base + 10] * lp.z + xf[base + 14];
      if (xf[base + 37] > 0.5) { out_verts[o + 0] = 0.0; out_verts[o + 1] = 0.0; out_verts[o + 2] = 0.0; }
      out_verts[o + 3] = 1.0;
      out_verts[o + 4] = xf[base + 25];
      for (int k = 5; k < 14; ++k) out_verts[o + k] = 0.0;
      out_verts[o + 7] = 1.0;
    """

  static let shadowGLSL = glslPrelude + """
    layout(std430, binding = 0) buffer Points { float points[]; };
    layout(std430, binding = 1) buffer PointMesh { int point_mesh[]; };
    layout(std430, binding = 2) buffer Xf { float xf[]; };
    layout(std430, binding = 3) buffer OutVerts { float out_verts[]; };
    void main()
    {
      uint gid = gl_GlobalInvocationID.x;
      \(shadowBody)
    }
    """

  static let shadowMSL = mslPrelude + """
    kernel void compute_main(constant U& u [[buffer(0)]],
                             device const float* points [[buffer(1)]],
                             device const int* point_mesh [[buffer(2)]],
                             device const float* xf [[buffer(3)]],
                             device float* out_verts [[buffer(4)]],
                             uint gid [[thread_position_in_grid]])
    {
      \(shadowBody)
    }
    """

  static let glslPrelude = """
    #version 430
    layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
    uniform ivec4 u_params;
    #define PARAMS u_params
    #define INT2 ivec2
    #define INT4 ivec4
    #define VEC2 vec2
    #define VEC3 vec3
    #define VEC4 vec4

    """

  static let mslPrelude = """
    #include <metal_stdlib>
    using namespace metal;
    struct U { int4 params; };
    #define PARAMS u.params
    #define INT2 int2
    #define INT4 int4
    #define VEC2 float2
    #define VEC3 float3
    #define VEC4 float4

    """

  static let faceGLSL = glslPrelude + """
    layout(std430, binding = 0) buffer Faces { ivec4 faces[]; };
    layout(std430, binding = 1) buffer Points { float points[]; };
    layout(std430, binding = 2) buffer FaceNormals { vec4 face_normals[]; };
    void main()
    {
      uint gid = gl_GlobalInvocationID.x;
      \(faceBody)
    }
    """

  static let faceMSL = mslPrelude + """
    kernel void compute_main(constant U& u [[buffer(0)]],
                             device const int4* faces [[buffer(1)]],
                             device const float* points [[buffer(2)]],
                             device float4* face_normals [[buffer(3)]],
                             uint gid [[thread_position_in_grid]])
    {
      \(faceBody)
    }
    """

  static let pointGLSL = glslPrelude + """
    layout(std430, binding = 0) buffer FaceStart { int face_start[]; };
    layout(std430, binding = 1) buffer FaceList { int face_list[]; };
    layout(std430, binding = 2) buffer FaceNormals { vec4 face_normals[]; };
    layout(std430, binding = 3) buffer PointNormals { vec4 point_normals[]; };
    void main()
    {
      uint gid = gl_GlobalInvocationID.x;
      \(pointBody)
    }
    """

  static let pointMSL = mslPrelude + """
    kernel void compute_main(constant U& u [[buffer(0)]],
                             device const int* face_start [[buffer(1)]],
                             device const int* face_list [[buffer(2)]],
                             device const float4* face_normals [[buffer(3)]],
                             device float4* point_normals [[buffer(4)]],
                             uint gid [[thread_position_in_grid]])
    {
      \(pointBody)
    }
    """

  static let emitGLSL = glslPrelude + """
    layout(std430, binding = 0) buffer Corners { ivec2 corners[]; };
    layout(std430, binding = 1) buffer Uvs { vec2 uvs[]; };
    layout(std430, binding = 2) buffer Points { float points[]; };
    layout(std430, binding = 3) buffer PointNormals { vec4 point_normals[]; };
    layout(std430, binding = 4) buffer FaceNormals { vec4 face_normals[]; };
    layout(std430, binding = 5) buffer PointMesh { int point_mesh[]; };
    layout(std430, binding = 6) buffer Xf { float xf[]; };
    layout(std430, binding = 7) buffer OutVerts { float out_verts[]; };
    void main()
    {
      uint gid = gl_GlobalInvocationID.x;
      \(emitBody)
    }
    """

  static let settleBody = """
      if (int(gid) >= PARAMS.x) return;
      int o = int(gid) * 14;
      out_verts[o + 5] = out_verts[o + 0];
      out_verts[o + 6] = out_verts[o + 1];
      out_verts[o + 7] = out_verts[o + 2];
    """

  static let settleGLSL = glslPrelude + """
    layout(std430, binding = 0) buffer OutVerts { float out_verts[]; };
    void main()
    {
      uint gid = gl_GlobalInvocationID.x;
      \(settleBody)
    }
    """

  static let settleMSL = mslPrelude + """
    kernel void compute_main(constant U& u [[buffer(0)]],
                             device float* out_verts [[buffer(1)]],
                             uint gid [[thread_position_in_grid]])
    {
      \(settleBody)
    }
    """

  static let emitMSL = mslPrelude + """
    kernel void compute_main(constant U& u [[buffer(0)]],
                             device const int2* corners [[buffer(1)]],
                             device const float2* uvs [[buffer(2)]],
                             device const float* points [[buffer(3)]],
                             device const float4* point_normals [[buffer(4)]],
                             device const float4* face_normals [[buffer(5)]],
                             device const int* point_mesh [[buffer(6)]],
                             device const float* xf [[buffer(7)]],
                             device float* out_verts [[buffer(8)]],
                             uint gid [[thread_position_in_grid]])
    {
      \(emitBody)
    }
    """
}
