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
    struct Mesh
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
    static let xfStride = 40
    static let ring = 3

    var meshes: [Mesh] = []
    /// Every mesh the layout was built from, empty ones too, by what a rebuild keys on.
    private var inputs: [UInt64: Input] = [:]

    struct Input
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

    var topologies: [UInt64: (revision: UInt64, topology: Akari.Geom.Topology)] = [:]

    /// A mesh's part of the layout, its indices from 0, kept until its triangles, winding or wire spacing change.
    struct Block
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
    struct Arrays
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

    var arrays = Arrays()
    /// The capture the layout draws into, and the laid out meshes it leaves undrawn while they're hidden.
    var capture: OpaquePointer?
    var undrawn: Set<UInt64> = []
    var capacities: [GLuint: Int] = [:]
    var pointCount = 0
    var faceCount = 0
    var cornerCount = 0

    var jointCount = 0
    var cursor = 0
    /// One world space vertex per point, drawn through the triangles' own indices,
    /// for the shadows, which only need positions and so skip the per corner expansion.
    public private(set) var shadowCapture: OpaquePointer?

    var kernels = Akari.ComputeKernels<Kernel>()
    var buffers = Buffers()

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
    var hasHistory = false
    /// The previous positions already match the current ones.
    var settled = true

    /// The layout's GPU buffers.
    struct Buffers
    {
      var faces: GLuint = 0
      var corners: GLuint = 0
      var uvs: GLuint = 0
      var faceStart: GLuint = 0
      var faceList: GLuint = 0
      var pointMesh: GLuint = 0
      var faceNormals: GLuint = 0
      var pointNormals: GLuint = 0
      var points: [GLuint] = []
      var transforms: [GLuint] = []
      /// GPU skinning: bind space rest points, each point's (first, count) influence range,
      /// the (palette joint, weight) influences, and this frame's joint palette, ringed.
      var restPoints: GLuint = 0
      var skinRanges: GLuint = 0
      var skinWeights: GLuint = 0
      var palettes: [GLuint] = []
      /// The vertex buffer compute writes, owned by the capture once recorded.
      var vertices: GLuint = 0
      /// One world space vertex per point, for the shadows.
      var shadowVertices: GLuint = 0
    }

    /// The compute kernels that deform, skin and settle the meshes, and write their vertices.
    enum Kernel: Akari.ComputeKernelName
    {
      case face, point, emit, shadow, settle, skin

      static let label = "deform"

      var glsl: String
      {
        switch self
        {
          case .face: faceGLSL
          case .point: pointGLSL
          case .emit: emitGLSL
          case .shadow: shadowGLSL
          case .settle: settleGLSL
          case .skin: skinGLSL
        }
      }

      var msl: String
      {
        switch self
        {
          case .face: faceMSL
          case .point: pointMSL
          case .emit: emitMSL
          case .shadow: shadowMSL
          case .settle: settleMSL
          case .skin: skinMSL
        }
      }

      var threadgroup: SIMD3<Int>
      {
        SIMD3(64, 1, 1)
      }
    }

    public init() {}

    deinit
    {
      releaseBuffers()
      kernels.release()
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
      store(&buffers.faces, arrays.faces, from: start.faces, usage: read)
      store(&buffers.corners, arrays.corners, from: start.corners, usage: read)
      store(&buffers.uvs, arrays.uvs, from: start.uvs, usage: read)
      store(&buffers.faceStart, arrays.starts, from: start.starts, usage: read)
      store(&buffers.faceList, arrays.list.isEmpty ? [0] : arrays.list, from: start.list, usage: read)
      store(&buffers.pointMesh, arrays.meshOfPoint, from: start.points, usage: read)
      if jointCount > 0
      {
        store(&buffers.restPoints, arrays.rest, from: start.rest, usage: read)
        store(&buffers.skinRanges, arrays.ranges, from: start.ranges, usage: read)
        store(&buffers.skinWeights, arrays.weights.isEmpty ? [0, 0] : arrays.weights, from: start.weights, usage: read)
        if buffers.palettes.isEmpty { buffers.palettes = [GLuint](repeating: 0, count: Self.ring) }
        for i in buffers.palettes.indices
        {
          reserve(&buffers.palettes[i], bytes: jointCount * 48, usage: read)
        }
      }

      let scratch = LGL_BUFFER_COMPUTE_READ | LGL_BUFFER_COMPUTE_WRITE
      reserve(&buffers.faceNormals, bytes: faceCount * 16, usage: scratch)
      reserve(&buffers.pointNormals, bytes: pointCount * 16, usage: scratch)
      if buffers.points.isEmpty { buffers.points = [GLuint](repeating: 0, count: Self.ring) }
      if buffers.transforms.isEmpty { buffers.transforms = [GLuint](repeating: 0, count: Self.ring) }
      for i in 0 ..< Self.ring
      {
        reserve(&buffers.points[i], bytes: pointCount * 12, usage: read)
        reserve(&buffers.transforms[i], bytes: self.meshes.count * Self.xfStride * 4, usage: read)
      }

      buffers.vertices = record(into: capture, vertexCount: cornerCount, indices: Array(0 ..< Int32(cornerCount)))
      hasHistory = false
      settled = true
      if let shadowCapture
      {
        buffers.shadowVertices = record(into: shadowCapture, vertexCount: pointCount, indices: arrays.shadow)
      }
    }

    /// Adds `block` for `mesh` to the end of the layout.
    func append(_ block: Block, _ mesh: Recorder.RawMesh, skinned: Bool)
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
  }
}
