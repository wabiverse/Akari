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
import LatticeUSD

public extension Akari.Geom
{
  /// deforms animated meshes on the gpu, laid out once so each frame only points and matrices upload and compute rebuilds the vertices
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
      /// where its cage sits in the cage buffer, for a mesh refined on the gpu.
      var cageBase = 0
      var cageCount = 0
    }

    /// the per mesh world matrix, normal matrix and prim id, padded
    static let xfStride = 40
    static let ring = 3

    var meshes: [Mesh] = []
    /// every mesh the layout was built from, empty ones too, by what a rebuild keys on.
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
      var cagePointCount: Int
      var stencilCount: Int
      var authoredNormals: Bool

      func same(as other: Input) -> Bool
      {
        topologyRevision == other.topologyRevision && flipWinding == other.flipWinding && pointCount == other.pointCount
          && skinRevision == other.skinRevision && skinInfluencesPerPoint == other.skinInfluencesPerPoint && jointCount == other.jointCount
          && cagePointCount == other.cagePointCount && stencilCount == other.stencilCount
          && authoredNormals == other.authoredNormals
      }
    }

    var topologies: [UInt64: (revision: UInt64, topology: Akari.Geom.Topology)] = [:]

    /// a mesh's part of the layout, its indices from 0, kept until its triangles, winding or wire spacing change.
    struct Block
    {
      var topologyRevision: UInt64
      var flipWinding: Bool
      var spacing: Float
      var pointCount: Int
      var triCount: Int
      /// per triangle its three points, -1 when out of range, and a slot for the mesh index.
      var faces: [Int32]
      /// per corner its point and its face with the hidden edge bits.
      var corners: [Int32]
      var uvs: [Float]
      /// each point's faces, from `starts[p]` to `starts[p + 1]`.
      var starts: [Int32]
      var list: [Int32]
      /// a polygon mesh's authored normals per corner and the smooth normal of each point under them, empty for other meshes
      var cornerNormals: [Float] = []
      var restNormals: [Float] = []
    }

    private var blocks: [UInt64: Block] = [:]

    /// the layout's contents, kept to append to.
    struct Arrays
    {
      var faces: [Int32] = []
      var corners: [Int32] = []
      var uvs: [Float] = []
      var starts: [Int32] = [0]
      var list: [Int32] = []
      /// authored normals per corner and the smooth normals they turn against per point, zero for the rest.
      var cornerNormals: [Float] = []
      var restNormals: [Float] = []
      var meshOfPoint: [Int32] = []
      var rest: [Float] = []
      var ranges: [Int32] = []
      var weights: [Float] = []
      /// per triangle its three points, for the shadow capture.
      var shadow: [Int32] = []
      /// refined points built from cages on the gpu, each stencil's target, its weight range and each term's cage point and weight
      var stencilTargets: [Int32] = []
      var stencilStarts: [Int32] = [0]
      var stencilIndices: [Int32] = []
      var stencilWeights: [Float] = []
    }

    var arrays = Arrays()
    /// the capture the layout draws into, and the laid out meshes it leaves undrawn while they're hidden.
    var capture: OpaquePointer?
    var undrawn: Set<UInt64> = []
    var capacities: [GLuint: Int] = [:]
    var pointCount = 0
    var faceCount = 0
    var cornerCount = 0

    var jointCount = 0
    var cagePointCount = 0
    var cursor = 0
    /// one world vertex per point drawn through the triangles' own indices, for the shadows that only need positions
    public private(set) var shadowCapture: OpaquePointer?
    /// each shown transparent mesh's world bounds as of the last update, what the glass shadow map fits.
    public internal(set) var glassBounds: [(min: SIMD3<Float>, max: SIMD3<Float>)] = []
    public var hasGlass: Bool { !glassBounds.isEmpty }

    var kernels = Akari.ComputeKernels<Kernel>()
    var buffers = Buffers()

    /// per prim id, how assembled it is, the center of the triangle it collapses to and that triangle's size, negative to center on the mesh
    public var assembly: [Int32: SIMD4<Float>] = [:]
    public var assemblySize: [Int32: Float] = [:]
    /// each prim's wire spacing in world units, its mesh drawing only the edges between cells that wide.
    public var wireSpacing: [Int32: Float] = [:]
    /// set when the wire spacing changed, or a skinned mesh's skin wasn't whole yet, the next `needsRebuild` relays out.
    public var relayout = false
    /// relayouts left for skins still arriving, so one that never completes doesn't relay out every frame.
    private var skinRetries = 8
    /// where the camera is, the collapsed triangle faces it.
    public var eye = SIMD3<Float>(repeating: 0)
    public var zUp = false
    /// the vertices hold last frame's positions, which become this frame's previous ones.
    var hasHistory = false
    /// the previous positions already match the current ones.
    var settled = true

    /// the layout's gpu buffers.
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
      var cornerNormals: GLuint = 0
      var restNormals: GLuint = 0
      var points: [GLuint] = []
      var transforms: [GLuint] = []
      /// gpu skinning buffers, the rest points, each point's influence range, the influences and this frame's joint palette
      var restPoints: GLuint = 0
      var skinRanges: GLuint = 0
      var skinWeights: GLuint = 0
      var palettes: [GLuint] = []
      /// gpu subdivision: the stencils, read only once laid out, and this frame's cage points, ringed.
      var stencilTargets: GLuint = 0
      var stencilStarts: GLuint = 0
      var stencilIndices: GLuint = 0
      var stencilWeights: GLuint = 0
      var cages: [GLuint] = []
      /// the vertex buffer compute writes, owned by the capture once recorded.
      var vertices: GLuint = 0
      /// one world space vertex per point, for the shadows.
      var shadowVertices: GLuint = 0
      /// one uint per draw, nonzero for glass, so the glass maps encode only glass draws, ringed.
      var glassDraws: [GLuint] = []
      /// one value per draw, nonzero where its bounds reach into the camera, ringed apart from the points since the camera moves on its own
      var cameraDraws: [GLuint] = []
    }

    /// which revision of each mesh's points each ring slot holds and its bounds then, so unchanged points aren't copied or scanned again
    var written: [UInt64] = []
    var pointBounds: [Float] = []
    /// this frame's glass draw mask, see `Buffers.glassDraws`.
    public internal(set) var glassDraws: GLuint = 0
    /// world bounds per recorded draw with hidden ones far outside every view, so shadow culling lines up with the draws, and which are glass
    public internal(set) var drawBounds: [Float] = []
    public internal(set) var glassDrawIndices: [Int] = []
    /// per recorded draw, whether its bounds hold all it draws, false while assembling pulls its vertices toward a triangle outside them
    var drawBounded: [Bool] = []
    /// the ring slot of `Buffers.cameraDraws` written last and how many draws each slot holds room for
    var cameraCursor = 0
    var cameraCapacity = 0
    /// where a draw that shouldn't land in any view is put.
    public static let nowhere: [Float] = [1e30, 1e30, 1e30, 1e30, 1e30, 1e30]

    /// the compute kernels that deform, skin and settle the meshes, and write their vertices.
    enum Kernel: Akari.ComputeKernelName
    {
      case face, point, emit, shadow, settle, skin, subdivide

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
          case .subdivide: subdivideGLSL
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
          case .subdivide: subdivideMSL
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
      if let shadowCapture { labgl.captureDestroy(shadowCapture) }
      releaseBuffers()
      kernels.release()
    }

    /// whether `meshes` need laying out again, other meshes or changed triangles
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
          old.jointCount == meshes[i].skinPalette.count / 12,
          old.cagePointCount == Self.cagePointCount(meshes[i]),
          old.stencilCount == Self.stencilCount(meshes[i])
        else { return true }
        guard old.topologyRevision != meshes[i].topologyRevision else { continue }

        // a resync can bump the revision with the same triangles, only a real change relays out.
        guard Pixar.HdAkariSameTopology(old.tris, meshes[i].tris, old.uvs, meshes[i].uvs) else { return true }
        inputs[key]?.topologyRevision = meshes[i].topologyRevision
        if let cached = topologies[key] { topologies[key] = (meshes[i].topologyRevision, cached.topology) }
      }

      return seen.count != inputs.count
    }

    /// lays `meshes` out and records their draws into `capture`, keeping the place of meshes already laid out
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
                   cornerNormals: arrays.cornerNormals.count, restNormals: arrays.restNormals.count,
                   list: arrays.list.count, points: arrays.meshOfPoint.count, rest: arrays.rest.count, ranges: arrays.ranges.count,
                   weights: arrays.weights.count, stencilTargets: arrays.stencilTargets.count,
                   stencilStarts: arrays.stencilStarts.count, stencilTerms: arrays.stencilIndices.count)
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
           cached.pointCount == count,
           cached.cornerNormals.isEmpty != Self.authoredNormals(mesh)
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

        // a skin whose palette or weights lag its points is laid out unskinned and tried again next frame
        if mesh.skinInfluencesPerPoint > 0, !skinned, skinRetries > 0 { incomplete = true }
        append(block, mesh, skinned: skinned)
      }

      if incomplete { relayout = true; skinRetries -= 1 } else { skinRetries = 8 }
      guard cornerCount > 0 else { return }

      let read = LGL_BUFFER_COMPUTE_READ | LGL_BUFFER_MAP_WRITE
      store(&buffers.faces, arrays.faces, from: start.faces, usage: read)
      store(&buffers.corners, arrays.corners, from: start.corners, usage: read)
      store(&buffers.uvs, arrays.uvs, from: start.uvs, usage: read)
      store(&buffers.cornerNormals, arrays.cornerNormals, from: start.cornerNormals, usage: read)
      store(&buffers.restNormals, arrays.restNormals, from: start.restNormals, usage: read)
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

      if !arrays.stencilTargets.isEmpty
      {
        store(&buffers.stencilTargets, arrays.stencilTargets, from: start.stencilTargets, usage: read)
        store(&buffers.stencilStarts, arrays.stencilStarts, from: start.stencilStarts, usage: read)
        store(&buffers.stencilIndices, arrays.stencilIndices, from: start.stencilTerms, usage: read)
        store(&buffers.stencilWeights, arrays.stencilWeights, from: start.stencilTerms, usage: read)
        if buffers.cages.isEmpty { buffers.cages = [GLuint](repeating: 0, count: Self.ring) }
        for i in buffers.cages.indices
        {
          reserve(&buffers.cages[i], bytes: cagePointCount * 12, usage: read)
        }
      }

      let scratch = LGL_BUFFER_COMPUTE_READ | LGL_BUFFER_COMPUTE_WRITE
      reserve(&buffers.faceNormals, bytes: faceCount * 16, usage: scratch)
      reserve(&buffers.pointNormals, bytes: pointCount * 16, usage: scratch)
      if buffers.points.isEmpty { buffers.points = [GLuint](repeating: 0, count: Self.ring) }
      if buffers.transforms.isEmpty { buffers.transforms = [GLuint](repeating: 0, count: Self.ring) }
      if buffers.glassDraws.isEmpty { buffers.glassDraws = [GLuint](repeating: 0, count: Self.ring) }

      // a relaid out ring holds no mesh's points yet.
      written = []
      for i in 0 ..< Self.ring
      {
        reserve(&buffers.glassDraws[i], bytes: max(self.meshes.count, 1) * 4, usage: read)
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

    /// adds `block` for `mesh` to the end of the layout.
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
      if block.cornerNormals.count == block.triCount * 12, block.restNormals.count == count * 4
      {
        arrays.cornerNormals += block.cornerNormals
        arrays.restNormals += block.restNormals
      }
      else
      {
        arrays.cornerNormals.append(contentsOf: repeatElement(0, count: block.triCount * 12))
        arrays.restNormals.append(contentsOf: repeatElement(0, count: count * 4))
      }

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

      let cageBase = cagePointCount
      let cageCount = mesh.refinesOnGPU ? appendStencils(mesh, pointBase: pointBase) : 0

      meshes.append(Mesh(key: mesh.key,
                         topologyRevision: mesh.topologyRevision,
                         flipWinding: mesh.flipWinding,
                         pointCount: count,
                         pointBase: Int(pointBase),
                         cornerBase: cornerBase,
                         cornerCount: block.triCount * 3,
                         jointBase: k > 0 ? jointCount : 0,
                         jointCount: k > 0 ? joints : 0,
                         cageBase: cageCount > 0 ? cageBase : 0,
                         cageCount: cageCount))
      if k > 0 { jointCount += joints }
      pointCount += count
      faceCount += block.triCount
      cornerCount += block.triCount * 3
    }

    /// adds a refined mesh's stencils, its rows writing its points from `pointBase` on. returns its cage point count.
    private func appendStencils(_ mesh: Recorder.RawMesh, pointBase: Int32) -> Int
    {
      let offsets: UnsafePointer<Int32>? = Overlay.cdata(mesh.stencilOffsets)
      let indices: UnsafePointer<Int32>? = Overlay.cdata(mesh.stencilIndices)
      let weights: UnsafePointer<Float>? = Overlay.cdata(mesh.stencilWeights)
      guard let offsets, let indices, let weights else { return 0 }

      let rows = mesh.stencilOffsets.size() - 1
      let terms = mesh.stencilIndices.size()
      let cageBase = Int32(cagePointCount)
      let termBase = Int32(arrays.stencilIndices.count)
      arrays.stencilTargets += (0 ..< Int32(rows)).map { pointBase + $0 }
      arrays.stencilStarts += UnsafeBufferPointer(start: offsets + 1, count: rows).map { termBase + $0 }
      arrays.stencilIndices += UnsafeBufferPointer(start: indices, count: terms).map { cageBase + $0 }
      arrays.stencilWeights += UnsafeBufferPointer(start: weights, count: terms)

      let cageCount = mesh.cagePoints.size()
      cagePointCount += cageCount
      return cageCount
    }

    private static func cagePointCount(_ mesh: Recorder.RawMesh) -> Int
    {
      mesh.refinesOnGPU ? mesh.cagePoints.size() : 0
    }

    private static func stencilCount(_ mesh: Recorder.RawMesh) -> Int
    {
      mesh.refinesOnGPU ? mesh.stencilIndices.size() : 0
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
            jointCount: mesh.skinPalette.count / 12,
            cagePointCount: cagePointCount(mesh),
            stencilCount: stencilCount(mesh),
            authoredNormals: authoredNormals(mesh))
    }

    /// whether the mesh shades with its own normals, one per triangle corner.
    static func authoredNormals(_ mesh: Recorder.RawMesh) -> Bool
    {
      !mesh.smooth && !mesh.normals.empty() && mesh.normals.size() == mesh.tris.size() * 3
    }

    /// how the emit kernel shades a mesh, kept in its transform slot 38.
    static func shading(_ mesh: Recorder.RawMesh) -> Float
    {
      if mesh.smooth { return 1 }
      if authoredNormals(mesh) { return 3 }
      return mesh.faceted ? 2 : 0
    }

    /// writes `values` from `start` on into `buffer`, which grows by half again once they no longer fit.
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

    /// makes `buffer` hold at least `bytes`, half again more when it has to grow, its contents lost.
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
