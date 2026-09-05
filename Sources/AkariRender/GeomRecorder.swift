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
      public var dataRevision: UInt64
      public var flipWinding: Bool
      public var points: Pixar.VtVec3fArray
      public var tris: Pixar.VtVec3iArray
      public var uvs: Pixar.VtVec2fArray
      public var worldMatrix: [Float]
      public var normalMatrix: [Float]

      public init(id: String, dataRevision: UInt64, flipWinding: Bool,
                  points: Pixar.VtVec3fArray, tris: Pixar.VtVec3iArray, uvs: Pixar.VtVec2fArray,
                  worldMatrix: [Float], normalMatrix: [Float])
      {
        self.id = id
        self.dataRevision = dataRevision
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
      public var verts: [Float]
      public var indices: [Int32]
      public var worldMatrix: [Float]
      public var normalMatrix: [Float]
    }

    /// A built mesh, with what the cache keys on.
    private struct BuiltMesh
    {
      var id: String
      var dataRevision: UInt64
      var flipWinding: Bool
      var verts: [Float]
      var indices: [Int32]
      var worldMatrix: [Float]
      var normalMatrix: [Float]
    }

    /// Everything needed to build one mesh.
    private struct BuildInput
    {
      var id: String
      var dataRevision: UInt64
      var flipWinding: Bool
      var pointsFlat: [Float]
      var trisFlat: [Int32]
      var uvsFlat: [Float]
      var worldMatrix: [Float]
      var normalMatrix: [Float]
    }

    private struct CachedMesh
    {
      var dataRevision: UInt64
      var flipWinding: Bool
      var verts: [Float]
      var indices: [Int32]
    }

    private var cache: [String: CachedMesh] = [:]

    public init() {}

    /// Reuses what's cached, builds the rest in parallel.
    public func record(_ meshes: [RawMesh]) -> [Item]
    {
      var readyItems: [BuiltMesh] = []
      var pendingInputs: [BuildInput] = []

      readyItems.reserveCapacity(meshes.count)
      pendingInputs.reserveCapacity(meshes.count)

      for mesh in meshes
      {
        // cached for reuse across captures unless this mesh's own
        // geometry (dataRevision) or flip state actually changed.
        if let cached = cache[mesh.id],
           cached.dataRevision == mesh.dataRevision,
           cached.flipWinding == mesh.flipWinding
        {
          if cached.verts.isEmpty || cached.indices.isEmpty { continue }
          readyItems.append(BuiltMesh(id: mesh.id, dataRevision: cached.dataRevision,
                                      flipWinding: mesh.flipWinding, verts: cached.verts,
                                      indices: cached.indices, worldMatrix: mesh.worldMatrix,
                                      normalMatrix: mesh.normalMatrix))
          continue
        }

        let (pointsFlat, trisFlat, uvsFlat) = Akari.Geom.flatten(points: mesh.points, tris: mesh.tris, uvs: mesh.uvs)
        pendingInputs.append(BuildInput(id: mesh.id, dataRevision: mesh.dataRevision,
                                        flipWinding: mesh.flipWinding, pointsFlat: pointsFlat,
                                        trisFlat: trisFlat, uvsFlat: uvsFlat, worldMatrix: mesh.worldMatrix,
                                        normalMatrix: mesh.normalMatrix))
      }

      let builtItems = Self.buildInParallel(pendingInputs)

      var newCache: [String: CachedMesh] = [:]
      var items: [Item] = []

      let itemCount = readyItems.count + builtItems.count
      newCache.reserveCapacity(itemCount)
      items.reserveCapacity(itemCount)

      for item in readyItems + builtItems
      {
        if item.verts.isEmpty || item.indices.isEmpty { continue }
        newCache[item.id] = CachedMesh(dataRevision: item.dataRevision,
                                       flipWinding: item.flipWinding,
                                       verts: item.verts,
                                       indices: item.indices)
        items.append(Item(verts: item.verts, indices: item.indices,
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
    private static func buildInParallel(_ inputs: [BuildInput]) -> [BuiltMesh]
    {
      guard !inputs.isEmpty else { return [] }

      var results = [BuiltMesh?](repeating: nil, count: inputs.count)
      results.withUnsafeMutableBufferPointer
      { buf in
        let box = UnsafeSendableBuffer(buffer: buf)
        DispatchQueue.concurrentPerform(iterations: inputs.count)
        { i in
          let input = inputs[i]
          var verts: [Float] = []
          var indices: [Int32] = []
          Akari.Geom.buildMesh(pointsFlat: input.pointsFlat, trisFlat: input.trisFlat,
                               uvsFlat: input.uvsFlat, verts: &verts, indices: &indices,
                               flipWinding: input.flipWinding)
          box.buffer[i] = BuiltMesh(id: input.id, dataRevision: input.dataRevision,
                                    flipWinding: input.flipWinding, verts: verts, indices: indices,
                                    worldMatrix: input.worldMatrix, normalMatrix: input.normalMatrix)
        }
      }
      return results.compactMap(\.self)
    }
  }
}
