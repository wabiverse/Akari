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
import HydraKit

public extension Akari.Geom
{
  /// triangulates meshes into draw buffers, cached by id and data revision so unchanged meshes are reused
  final class Recorder
  {
    /// one mesh, straight off the scene's usd arrays.
    public struct RawMesh
    {
      public var id: String
      /// the path's hash, what per frame keys on.
      public var key: UInt64
      public var primId: Int32
      public var dataRevision: UInt64
      public var topologyRevision: UInt64
      public var flipWinding: Bool
      /// a subdivision surface, shaded without hard edges.
      public var smooth = false
      /// a polygon mesh without authored normals, shaded flat per face.
      public var faceted = false
      /// a polygon mesh's authored normals, one per triangle corner, empty when it authors none.
      public var normals = Pixar.VtVec3fArray()
      /// each triangle's ptex face, what its streamed tiles key on.
      public var triangleFaces = Pixar.VtIntArray()
      /// the face resolutions and the map they stream from, -1 when they don't.
      public var faceRes = Pixar.VtIntArray()
      public var ptexMap: Int32 = -1
      public var points: Pixar.VtVec3fArray
      public var tris: Pixar.VtVec3iArray
      public var uvs: Pixar.VtVec2fArray
      public var worldMatrix: [Float]
      public var normalMatrix: [Float]
      /// the matrices taking `worldMatrix` to world space, shared by every mesh under a prototype, empty when it draws once
      public var instances: Akari.Geom.Matrices = []
      /// hashes `instances`, equal sets share it.
      public var instancesKey: UInt64 = 0
      /// set when live instances draws this prototype's instances
      public var livePrototype: String?
      /// a binned prototype's draws, one per each instance set.
      public var instanceDraws: [InstanceDraw] = []
      /// a hash of the object space geometry and material, so identical prototypes under different instancers share a draw
      public var contentKey: UInt64 = 0
      /// gpu skinned meshes, `points` are the rest points, each skinned by this many joint and weight pairs
      public var skinInfluencesPerPoint = 0
      public var skinInfluences = Pixar.VtVec2fArray()
      public var skinPalette: [Float] = []
      public var skinBounds: [Float] = []
      public var skinRevision: UInt64 = 0
      /// drawn by the transparency pass instead of the gbuffer.
      public var transparent = false
      /// black and emissive, casts no shadow.
      public var emitter = false
      /// drawn only from the side its winding faces, as the mesh authors.
      public var singleSided = false
      /// whether the material can cut holes in the shadow.
      public var shadowCutout = true
      /// the bound material's constant opacity.
      public var opacity: Float = 1
      /// the bound material's constant color and roughness.
      public var color = SIMD3<Float>(repeating: 0.8)
      public var roughness: Float = 0.5

      /// the limit surface cage of a refined subdivision surface, empty for other meshes.
      public var coarsePoints = Pixar.VtVec3fArray()
      public var coarseTris = Pixar.VtVec3iArray()
      public var coarseUvs = Pixar.VtVec2fArray()
      public var coarseTriangleFaces = Pixar.VtIntArray()

      /// a moving refined mesh's cage, and the stencils that build its refined points from it on the gpu.
      public var cagePoints = Pixar.VtVec3fArray()
      public var stencilOffsets = Pixar.VtIntArray()
      public var stencilIndices = Pixar.VtIntArray()
      public var stencilWeights = Pixar.VtFloatArray()

      /// whether the deformer builds this mesh's points from its cage instead of uploading them.
      public var refinesOnGPU: Bool
      {
        !cagePoints.empty() && stencilOffsets.size() == points.size() + 1
          && stencilIndices.size() == stencilWeights.size()
      }

      /// whether this mesh has a coarse cage to draw in place of its refined faces.
      public var hasCoarse: Bool
      {
        !coarseTris.empty() && !coarsePoints.empty()
      }

      /// the coarse cage as a mesh of its own, keyed apart from the refined one.
      public var coarse: RawMesh?
      {
        guard hasCoarse else { return nil }
        let salt: UInt64 = 0xC0A2_5E00_C0A2_5E00
        var mesh = self
        mesh.points = coarsePoints
        mesh.tris = coarseTris
        mesh.uvs = coarseUvs
        mesh.triangleFaces = coarseTriangleFaces
        if coarseTriangleFaces.empty() { mesh.faceRes = Pixar.VtIntArray() }
        mesh.coarsePoints = Pixar.VtVec3fArray()
        mesh.coarseTris = Pixar.VtVec3iArray()
        mesh.coarseUvs = Pixar.VtVec2fArray()
        mesh.coarseTriangleFaces = Pixar.VtIntArray()
        if mesh.contentKey != 0 { mesh.contentKey = (mesh.contentKey ^ salt) &* 1_099_511_628_211 }
        mesh.dataRevision ^= salt
        mesh.topologyRevision ^= salt
        return mesh
      }

      public init(id: String, key: UInt64, primId: Int32, dataRevision: UInt64, topologyRevision: UInt64,
                  flipWinding: Bool,
                  points: Pixar.VtVec3fArray, tris: Pixar.VtVec3iArray, uvs: Pixar.VtVec2fArray,
                  worldMatrix: [Float], normalMatrix: [Float], contentKey: UInt64 = 0)
      {
        self.id = id
        self.key = key
        self.primId = primId
        self.dataRevision = dataRevision
        self.topologyRevision = topologyRevision
        self.flipWinding = flipWinding
        self.points = points
        self.tris = tris
        self.uvs = uvs
        self.worldMatrix = worldMatrix
        self.normalMatrix = normalMatrix
        self.contentKey = contentKey
      }
    }

    /// one instance set a prototype draws with, its first `count` matrices, ordered so any prefix is an even sample
    public struct InstanceDraw
    {
      public var key: UInt64
      public var transforms: Akari.Geom.Matrices
      public var count: Int
      public var livePrototype: String?
      /// the level of detail band the prototype draws in, in pixels per unit of each instance's size.
      public var lod = SIMD2<Float>(0, .infinity)
      /// the bounds its level of detail and culling take, before each instance's transform, when not its own.
      public var bounds: [Float]?

      public init(key: UInt64, transforms: Akari.Geom.Matrices, count: Int, livePrototype: String? = nil)
      {
        self.key = key
        self.transforms = transforms
        self.count = count
        self.livePrototype = livePrototype
      }
    }

    /// one mesh ready to append into a `Batch`.
    public struct Item
    {
      public var primId: Int32
      public var dataRevision: UInt64
      public var built: Akari.Geom.Built
      public var verts: UnsafeBufferPointer<Float>
      {
        built.verts
      }

      public var indices: UnsafeBufferPointer<Int32>
      {
        built.indices
      }

      public var ptexFaces: UnsafeBufferPointer<UInt32>
      {
        built.ptexFaces
      }

      public var worldMatrix: [Float]
      public var normalMatrix: [Float]
      /// nonempty for a gpu instanced prototype.
      public var instanceDraws: [InstanceDraw] = []
    }

    /// a built mesh, with what the cache keys on.
    private struct BuiltMesh
    {
      var id: String
      var primId: Int32
      var cached: CachedMesh
      var worldMatrix: [Float]
      var normalMatrix: [Float]
      var instanceDraws: [InstanceDraw]
    }

    /// what building one mesh needs, `topology` when only its points changed
    private struct BuildInput
    {
      var id: String
      var primId: Int32
      var dataRevision: UInt64
      var topologyRevision: UInt64
      var flipWinding: Bool
      var cacheKey: UInt64
      var smooth: Bool
      var faceted: Bool
      var normals: Pixar.VtVec3fArray
      var points: Pixar.VtVec3fArray
      var tris: Pixar.VtVec3iArray
      var uvs: Pixar.VtVec2fArray
      /// empty unless its ptex streams.
      var triangleFaces: Pixar.VtIntArray
      var faceRes: Pixar.VtIntArray
      var topology: Akari.Geom.Topology?
      var worldMatrix: [Float]
      var normalMatrix: [Float]
      var instanceDraws: [InstanceDraw]
    }

    private struct CachedMesh
    {
      var dataRevision: UInt64
      var topologyRevision: UInt64
      var flipWinding: Bool
      var topology: Akari.Geom.Topology?
      var built: Akari.Geom.Built
    }

    private var cache: [String: CachedMesh] = [:]
    /// keeps each mesh's triangulation for when only its points move, off for meshes that rarely move since it costs about 50 bytes a triangle
    private let keepsTopology: Bool

    public init(keepsTopology: Bool = true)
    {
      self.keepsTopology = keepsTopology
    }

    /// the most triangles one record keeps built in memory for the next, past that a scene would be held twice, mapped builds are kept anyway
    private static let cacheTriangles = 8_000_000
    /// how much one chunk builds before its handed on.
    private static let chunkTriangles = 2_000_000
    private static let chunkMeshes = 4096

    /// reuses what's cached, builds the rest a chunk at a time in parallel and hands each chunk to `body` in order
    public func record(_ meshes: [RawMesh], reusing others: [Recorder] = [], body: ([Item]) -> Void)
    {
      let small = meshes.reduce(0) { $0 + $1.tris.size() } <= Self.cacheTriangles
      var newCache: [String: CachedMesh] = [:]
      var start = 0
      while start < meshes.count
      {
        var end = start
        var triangles = 0
        while end < meshes.count, end == start || (triangles < Self.chunkTriangles && end - start < Self.chunkMeshes)
        {
          triangles += meshes[end].tris.size()
          end += 1
        }

        var readyItems: [BuiltMesh] = []
        var pendingInputs: [BuildInput] = []
        for mesh in meshes[start ..< end]
        {
          let candidates = ([cache[mesh.id]] + others.map { $0.cache[mesh.id] }).compactMap(\.self)

          if let cached = candidates.first(where: { $0.dataRevision == mesh.dataRevision && $0.flipWinding == mesh.flipWinding })
          {
            if cached.built.isEmpty { continue }
            readyItems.append(BuiltMesh(id: mesh.id, primId: mesh.primId, cached: cached,
                                        worldMatrix: mesh.worldMatrix, normalMatrix: mesh.normalMatrix,
                                        instanceDraws: mesh.instanceDraws))
            continue
          }

          let topology = candidates.first(where: { $0.topologyRevision == mesh.topologyRevision })?.topology
          let streams = mesh.ptexMap >= 0 && mesh.triangleFaces.size() == mesh.tris.size()
          let cacheKey = Akari.Geom.GeometryCache.key(contentKey: mesh.contentKey, flipWinding: mesh.flipWinding,
                                                      points: mesh.points.size(), triangles: mesh.tris.size(),
                                                      uvs: mesh.uvs.size())
          pendingInputs.append(BuildInput(id: mesh.id, primId: mesh.primId, dataRevision: mesh.dataRevision,
                                          topologyRevision: mesh.topologyRevision, flipWinding: mesh.flipWinding,
                                          cacheKey: cacheKey, smooth: mesh.smooth, faceted: mesh.faceted,
                                          normals: mesh.normals, points: mesh.points, tris: mesh.tris, uvs: mesh.uvs,
                                          triangleFaces: streams ? mesh.triangleFaces : Pixar.VtIntArray(),
                                          faceRes: streams ? mesh.faceRes : Pixar.VtIntArray(),
                                          topology: topology, worldMatrix: mesh.worldMatrix,
                                          normalMatrix: mesh.normalMatrix, instanceDraws: mesh.instanceDraws))
        }

        let builtItems = Self.buildInParallel(pendingInputs, keepsTopology: keepsTopology)
        var items: [Item] = []
        items.reserveCapacity(readyItems.count + builtItems.count)
        for item in readyItems + builtItems
        {
          if small || item.cached.built.isMapped
          {
            var cached = item.cached
            if !keepsTopology { cached.topology = nil }
            newCache[item.id] = cached
          }

          if item.cached.built.isEmpty { continue }
          items.append(Item(primId: item.primId, dataRevision: item.cached.dataRevision,
                            built: item.cached.built,
                            worldMatrix: item.worldMatrix, normalMatrix: item.normalMatrix,
                            instanceDraws: item.instanceDraws))
        }

        if !items.isEmpty { body(items) }
        start = end
      }

      cache = newCache
    }

    /// hands the results buffer into the concurrent loop, each iteration writes its own index
    private struct UnsafeSendableBuffer: @unchecked Sendable
    {
      let buffer: UnsafeMutableBufferPointer<BuiltMesh?>
      let inputs: [BuildInput]
    }

    /// meshes past this build one at a time.
    private static let largeTriangles = 1_000_000

    /// triangulates the cache misses in parallel, the large ones after the rest and one by one.
    private static func buildInParallel(_ inputs: [BuildInput], keepsTopology: Bool) -> [BuiltMesh]
    {
      guard !inputs.isEmpty else { return [] }

      var results = [BuiltMesh?](repeating: nil, count: inputs.count)
      let small = inputs.indices.filter { inputs[$0].tris.size() <= largeTriangles }
      results.withUnsafeMutableBufferPointer
      { buf in
        let box = UnsafeSendableBuffer(buffer: buf, inputs: inputs)
        DispatchQueue.concurrentPerform(iterations: small.count)
        { j in
          let i = small[j]
          box.buffer[i] = build(box.inputs[i], keepsTopology: keepsTopology)
        }
      }

      for i in inputs.indices where inputs[i].tris.size() > largeTriangles
      {
        results[i] = build(inputs[i], keepsTopology: keepsTopology)
      }

      return results.compactMap(\.self)
    }

    private static func build(_ input: BuildInput, keepsTopology: Bool) -> BuiltMesh
    {
      if !keepsTopology, let built = Akari.Geom.GeometryCache.shared.load(input.cacheKey)
      {
        return BuiltMesh(id: input.id, primId: input.primId,
                         cached: CachedMesh(dataRevision: input.dataRevision, topologyRevision: input.topologyRevision,
                                            flipWinding: input.flipWinding, topology: nil, built: built),
                         worldMatrix: input.worldMatrix, normalMatrix: input.normalMatrix,
                         instanceDraws: input.instanceDraws)
      }

      let topology: Akari.Geom.Topology
      let pointsFlat: [Float]
      if let cached = input.topology
      {
        topology = cached
        pointsFlat = Akari.Geom.flatten(points: input.points)
      }
      else
      {
        let flat = Akari.Geom.flatten(points: input.points, tris: input.tris, uvs: input.uvs, expandsConstantUv: false)
        topology = Akari.Geom.topology(trisFlat: flat.tris, uvsFlat: flat.uvs, pointCount: flat.points.count / 3)
        pointsFlat = flat.points
      }

      var verts: [Float] = []
      var indices: [Int32] = []
      var sources: [Int32] = []
      Akari.Geom.buildMesh(pointsFlat: pointsFlat, topology: topology, verts: &verts,
                           indices: &indices, sources: &sources, flipWinding: input.flipWinding, subdivided: input.smooth,
                           faceted: input.faceted, normals: Akari.Geom.flatten(points: input.normals))
      var ptexFaces: [UInt32] = []
      if !input.triangleFaces.empty()
      {
        ptexFaces = [UInt32](repeating: 0, count: sources.count)
        sources.withUnsafeBufferPointer
        { src in
          ptexFaces.withUnsafeMutableBufferPointer
          {
            Pixar.HdAkariPtexTriangleEntries(input.triangleFaces, input.faceRes, src.baseAddress, src.count, $0.baseAddress)
          }
        }
      }

      let cached = CachedMesh(dataRevision: input.dataRevision, topologyRevision: input.topologyRevision,
                              flipWinding: input.flipWinding, topology: keepsTopology ? topology : nil,
                              built: Akari.Geom.GeometryCache.shared.store(input.cacheKey, verts: verts, indices: indices,
                                                                           ptexFaces: ptexFaces))
      return BuiltMesh(id: input.id, primId: input.primId, cached: cached,
                       worldMatrix: input.worldMatrix, normalMatrix: input.normalMatrix,
                       instanceDraws: input.instanceDraws)
    }
  }
}
