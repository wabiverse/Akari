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
import OpenUSDKit

public extension Akari.Geom
{
  /// Triangulates meshes into draw buffers, cached by
  /// `id` + `dataRevision` so that meshes that aren't
  /// modified get reused, preventing needless copies
  /// of unmodified geometry for every frame.
  final class Recorder
  {
    /// One mesh, straight off the scene's USD arrays.
    public struct RawMesh
    {
      public var id: String
      /// The path's hash, what per frame keys on.
      public var key: UInt64
      public var primId: Int32
      public var dataRevision: UInt64
      public var topologyRevision: UInt64
      public var flipWinding: Bool
      public var points: Pixar.VtVec3fArray
      public var tris: Pixar.VtVec3iArray
      public var uvs: Pixar.VtVec2fArray
      public var worldMatrix: [Float]
      public var normalMatrix: [Float]

      public init(id: String, key: UInt64, primId: Int32, dataRevision: UInt64, topologyRevision: UInt64,
                  flipWinding: Bool,
                  points: Pixar.VtVec3fArray, tris: Pixar.VtVec3iArray, uvs: Pixar.VtVec2fArray,
                  worldMatrix: [Float], normalMatrix: [Float])
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
      }
    }

    /// One mesh ready to append into a `Batch`.
    public struct Item
    {
      public var primId: Int32
      public var dataRevision: UInt64
      public var verts: [Float]
      public var indices: [Int32]
      public var worldMatrix: [Float]
      public var normalMatrix: [Float]
    }

    /// A built mesh, with what the cache keys on.
    private struct BuiltMesh
    {
      var id: String
      var primId: Int32
      var cached: CachedMesh
      var worldMatrix: [Float]
      var normalMatrix: [Float]
    }

    /// Everything needed to build one mesh,
    /// `topology` when only its points changed.
    private struct BuildInput
    {
      var id: String
      var primId: Int32
      var dataRevision: UInt64
      var topologyRevision: UInt64
      var flipWinding: Bool
      var pointsFlat: [Float]
      var trisFlat: [Int32]
      var uvsFlat: [Float]
      var topology: Akari.Geom.Topology?
      var worldMatrix: [Float]
      var normalMatrix: [Float]
    }

    private struct CachedMesh
    {
      var dataRevision: UInt64
      var topologyRevision: UInt64
      var flipWinding: Bool
      var topology: Akari.Geom.Topology?
      var verts: [Float]
      var indices: [Int32]
    }

    private var cache: [String: CachedMesh] = [:]
    /// Keeps each mesh's triangulation for when only its points move,
    /// off for meshes that rarely do, it costs about 50 bytes a triangle.
    private let keepsTopology: Bool

    public init(keepsTopology: Bool = true)
    {
      self.keepsTopology = keepsTopology
    }

    /// Reuses what's cached here or in `others`, builds the rest in
    /// parallel, reusing a mesh's triangulation when only its points
    /// moved.
    public func record(_ meshes: [RawMesh], reusing others: [Recorder] = []) -> [Item]
    {
      var readyItems: [BuiltMesh] = []
      var pendingInputs: [BuildInput] = []

      readyItems.reserveCapacity(meshes.count)
      pendingInputs.reserveCapacity(meshes.count)

      for mesh in meshes
      {
        let candidates = ([cache[mesh.id]] + others.map { $0.cache[mesh.id] }).compactMap(\.self)

        if let cached = candidates.first(where: { $0.dataRevision == mesh.dataRevision && $0.flipWinding == mesh.flipWinding })
        {
          if cached.verts.isEmpty || cached.indices.isEmpty { continue }
          readyItems.append(BuiltMesh(id: mesh.id, primId: mesh.primId, cached: cached,
                                      worldMatrix: mesh.worldMatrix, normalMatrix: mesh.normalMatrix))
          continue
        }

        if let topology = candidates.first(where: { $0.topologyRevision == mesh.topologyRevision })?.topology
        {
          pendingInputs.append(BuildInput(id: mesh.id, primId: mesh.primId, dataRevision: mesh.dataRevision,
                                          topologyRevision: mesh.topologyRevision, flipWinding: mesh.flipWinding,
                                          pointsFlat: Akari.Geom.flatten(points: mesh.points), trisFlat: [],
                                          uvsFlat: [], topology: topology, worldMatrix: mesh.worldMatrix,
                                          normalMatrix: mesh.normalMatrix))
          continue
        }

        let (pointsFlat, trisFlat, uvsFlat) = Akari.Geom.flatten(points: mesh.points, tris: mesh.tris, uvs: mesh.uvs)
        pendingInputs.append(BuildInput(id: mesh.id, primId: mesh.primId, dataRevision: mesh.dataRevision,
                                        topologyRevision: mesh.topologyRevision, flipWinding: mesh.flipWinding,
                                        pointsFlat: pointsFlat, trisFlat: trisFlat, uvsFlat: uvsFlat,
                                        topology: nil, worldMatrix: mesh.worldMatrix,
                                        normalMatrix: mesh.normalMatrix))
      }

      let builtItems = Self.buildInParallel(pendingInputs, keepsTopology: keepsTopology)

      var newCache: [String: CachedMesh] = [:]
      var items: [Item] = []

      let itemCount = readyItems.count + builtItems.count
      newCache.reserveCapacity(itemCount)
      items.reserveCapacity(itemCount)

      for item in readyItems + builtItems
      {
        var cached = item.cached
        if !keepsTopology { cached.topology = nil }
        newCache[item.id] = cached
        if item.cached.verts.isEmpty || item.cached.indices.isEmpty { continue }
        items.append(Item(primId: item.primId, dataRevision: item.cached.dataRevision,
                          verts: item.cached.verts, indices: item.cached.indices,
                          worldMatrix: item.worldMatrix, normalMatrix: item.normalMatrix))
      }
      cache = newCache
      return items
    }

    /// Passes the results buffer into `concurrentPerform`'s
    /// `@Sendable` closure, each iteration writes its own index.
    private struct UnsafeSendableBuffer: @unchecked Sendable
    {
      let buffer: UnsafeMutableBufferPointer<BuiltMesh?>
    }

    /// Triangulates the cache misses in parallel.
    private static func buildInParallel(_ inputs: [BuildInput], keepsTopology: Bool) -> [BuiltMesh]
    {
      guard !inputs.isEmpty else { return [] }

      var results = [BuiltMesh?](repeating: nil, count: inputs.count)
      results.withUnsafeMutableBufferPointer
      { buf in
        let box = UnsafeSendableBuffer(buffer: buf)
        DispatchQueue.concurrentPerform(iterations: inputs.count)
        { i in
          let input = inputs[i]
          let topology = input.topology
            ?? Akari.Geom.topology(trisFlat: input.trisFlat, uvsFlat: input.uvsFlat,
                                   pointCount: input.pointsFlat.count / 3)
          var verts: [Float] = []
          var indices: [Int32] = []
          Akari.Geom.buildMesh(pointsFlat: input.pointsFlat, topology: topology, verts: &verts,
                               indices: &indices, flipWinding: input.flipWinding)
          let cached = CachedMesh(dataRevision: input.dataRevision, topologyRevision: input.topologyRevision,
                                  flipWinding: input.flipWinding, topology: keepsTopology ? topology : nil,
                                  verts: verts, indices: indices)
          box.buffer[i] = BuiltMesh(id: input.id, primId: input.primId, cached: cached,
                                    worldMatrix: input.worldMatrix, normalMatrix: input.normalMatrix)
        }
      }

      return results.compactMap(\.self)
    }
  }
}
