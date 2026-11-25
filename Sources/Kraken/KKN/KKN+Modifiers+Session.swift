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

import CxxStdlib
import Foundation
import HdAkari
import HydraKit
import simd

extension Kraken.Modifiers
{
  /// the attributes the stack overrides in the session layer, cleared before each evaluation so the cage reads as authored
  nonisolated static let overridden: [Tf.Token] =
    [Tf.Token("points"), Tf.Token("faceVertexCounts"), Tf.Token("faceVertexIndices"), Tf.Token("extent"),
     Tf.Token("normals"), Tf.Token("creaseIndices"), Tf.Token("creaseLengths"), Tf.Token("creaseSharpnesses"),
     Kraken.SceneEdit.sharpEdgesName, Tf.Token("akari:subdivision:viewportLevel"),
     Tf.Token("akari:subdivision:renderLevel")]

  /// drops everything the stack put in the session layer for this mesh
  nonisolated static func clearSession(_ stage: UsdStage, _ prim: UsdPrim)
  {
    Kraken.Authoring.inSession(stage)
    {
      // the whole spec goes, so nothing is left declaring the attribute or the interpolation it was given
      var owner = prim
      for name in overridden { _ = owner.RemoveProperty(name) }

      for primvar in Pixar.UsdGeomPrimvarsAPI(prim).GetPrimvars()
      {
        _ = owner.RemoveProperty(primvar.GetIndicesAttr().name)
      }
    }
  }

  /// drops everything the stack put in the session layer for the mesh at path
  nonisolated static func clearSession(_ stage: UsdStage, _ path: String)
  {
    guard let prim = Kraken.SceneEdit.prim(stage, path), prim.isA(.mesh) else { return }

    clearSession(stage, prim)
  }

  /// evaluates the stack of the mesh at `path` into the session layer, called on the frame queue
  nonisolated static func sync(_ stage: UsdStage, _ path: String, _ time: Double, render: Bool = false)
  {
    guard let prim = Kraken.SceneEdit.prim(stage, path), prim.isA(.mesh), !prim.IsInstanceProxy() else { return }

    clearSession(stage, prim)

    let stack = read(stage, path)
    guard !stack.isEmpty else { return }

    refine(stage, prim, stack, render: render)

    let mesh = Kraken.SceneEdit.mesh(stage, path, time)
    guard mesh.valid else { return }

    let points = stride(from: 0, to: mesh.points.count - 2, by: 3)
      .map { SIMD3<Float>(mesh.points[$0], mesh.points[$0 + 1], mesh.points[$0 + 2]) }
    let cage = Geometry.cage(points: points, counts: mesh.counts, indices: mesh.indices, creases: mesh.creases,
                             creaseSharpness: mesh.creaseSharpness, sharp: mesh.sharp)

    guard let out = evaluate(cage, stack, render: render) else { return }

    Kraken.Authoring.inSession(stage) { author(prim, out, cage) }
  }

  /// turns refinement off while the subdivision modifier is off, since akari reads the level off the prim and hydra doesn't watch it
  nonisolated private static func refine(_ stage: UsdStage, _ prim: UsdPrim, _ stack: [Entry], render: Bool)
  {
    guard let entry = stack.first(where: { $0.kind.isRefinement }) else { return }

    if !entry.shows(render: render)
    {
      let name = Tf.Token(render ? "akari:subdivision:renderLevel" : "akari:subdivision:viewportLevel")
      Kraken.Authoring.inSession(stage)
      {
        guard let level = prim.attribute(named: name)
          ?? prim.createAttribute(name: name, typeName: Sdf.getValueType(for: .int), custom: true,
                                  variability: .uniform) else { return }

        _ = level.set(Int32(0))
      }
    }

    // the level is read straight off the prim, so hydra has to be told the mesh changed either way
    Pixar.HdAkariMarkMeshDirty(std.string(prim.GetPath().string))
  }

  /// writes an evaluated mesh over the prim, at whatever edit target is aimed at it
  nonisolated static func author(_ prim: UsdPrim, _ out: Geometry, _ cage: Geometry)
  {
    var mesh = Pixar.UsdGeomMesh(prim)
    let time = Pixar.UsdTimeCode.Default()
    let points = Kraken.SceneEdit.vec3fArray(out.points)

    _ = mesh.GetPointsAttr().Set(points, time)
    _ = mesh.GetFaceVertexCountsAttr().Set(Kraken.SceneEdit.intArray(out.counts), time)
    _ = mesh.GetFaceVertexIndicesAttr().Set(Kraken.SceneEdit.intArray(out.indices), time)

    var extent = Pixar.VtVec3fArray()
    if Pixar.UsdGeomPointBased.ComputeExtent(points, &extent) { _ = mesh.GetExtentAttr().Set(extent, time) }

    if !out.creaseSharpness.isEmpty || mesh.GetCreaseIndicesAttr().HasAuthoredValue()
    {
      _ = mesh.GetCreaseIndicesAttr().Set(Kraken.SceneEdit.intArray(out.creases), time)
      _ = mesh.GetCreaseLengthsAttr()
        .Set(Kraken.SceneEdit.intArray([Int32](repeating: 2, count: out.creaseSharpness.count)), time)
      _ = mesh.GetCreaseSharpnessesAttr().Set(Kraken.SceneEdit.floatArray(out.creaseSharpness), time)
    }

    if !out.sharp.isEmpty,
       let edges = prim.attribute(named: Kraken.SceneEdit.sharpEdgesName)
       ?? prim.createAttribute(name: Kraken.SceneEdit.sharpEdgesName, typeName: Sdf.getValueType(for: .intArray),
                               custom: true)
    {
      _ = edges.Set(Kraken.SceneEdit.intArray(out.sharp), time)
    }

    // a mesh that shades off its own normals keeps doing so, smoothed over the faces the stack made
    if mesh.GetNormalsAttr().HasAuthoredValue()
    {
      let sharp = Set(stride(from: 0, to: out.sharp.count - 1, by: 2)
        .map { Kraken.Edge(Int(out.sharp[$0]), Int(out.sharp[$0 + 1])) })
      let normals = Kraken.SceneEdit.smoothNormals(out.points, out.counts, out.indices, sharp: sharp)
      _ = mesh.GetNormalsAttr().Set(Kraken.SceneEdit.vec3fArray(normals), time)
      _ = mesh.SetNormalsInterpolation(.faceVarying)
    }

    carry(prim, out, cage)
  }

  /// points every primvar at the cage values its piece came from as an indexed primvar, so uvs and colors survive topology changes
  nonisolated static func carry(_ prim: UsdPrim, _ out: Geometry, _ cage: Geometry)
  {
    let time = Pixar.UsdTimeCode.Default()

    for primvar in Pixar.UsdGeomPrimvarsAPI(prim).GetPrimvars()
    {
      let source: [Int32] = switch primvar.GetInterpolation().string
      {
        case "vertex", "varying": out.pointSource
        case "faceVarying": out.cornerSource
        case "uniform": out.faceSource
        default: []
      }

      guard !source.isEmpty else { continue }

      var authored = Pixar.VtIntArray()
      let indexed = primvar.GetIndices(&authored, time) && authored.size() > 0
      var cageIndices: [Int32] = []
      let data: UnsafePointer<Int32>? = Overlay.cdata(authored)
      if indexed, data != nil
      {
        cageIndices = Array(UnsafeBufferPointer(start: data, count: authored.size()))
      }

      #if compiler(>=6.4) && canImport(Usd)
        let values = primvar.GetAttrConsuming()
      #else
        let values = primvar.GetAttr()
      #endif

      var held = Pixar.VtValue()
      let elements = indexed ? cageIndices.count : (values.Get(&held, time) ? Int(held.GetArraySize()) : 0)

      // a stack that left this interpolation alone the way the cage had it needs no indirection
      let moved = source.count != elements || source.enumerated().contains { $0.element != Int32($0.offset) }
      guard moved else { continue }

      let composed = source.map
      { i -> Int32 in
        guard i >= 0 else { return 0 }
        guard indexed else { return i }

        return Int(i) < cageIndices.count ? cageIndices[Int(i)] : 0
      }

      _ = primvar.SetIndices(Kraken.SceneEdit.intArray(composed), time)
    }
  }

  /// the mesh the shot authors under the stack, what modeling edits, with the result put back over it after
  nonisolated static func cage(_ stage: UsdStage, _ path: String, _ time: Double) -> Kraken.SceneEdit.Mesh
  {
    guard let prim = Kraken.SceneEdit.prim(stage, path), prim.isA(.mesh), !read(stage, path).isEmpty else
    {
      return Kraken.SceneEdit.mesh(stage, path, time)
    }

    clearSession(stage, prim)
    let mesh = Kraken.SceneEdit.mesh(stage, path, time)
    sync(stage, path, time)
    return mesh
  }

  // MARK: applying

  /// the modifiers of the prim whose result is baked and waiting for the scene to be saved
  nonisolated static func applied(_ stage: UsdStage, _ path: String) -> [String]
  {
    guard let prim = Kraken.SceneEdit.prim(stage, path) else { return [] }

    var tokens = Pixar.VtTokenArray()
    guard let attribute = prim.attribute(named: pending), attribute.Get(&tokens, Pixar.UsdTimeCode.Default()) else
    {
      return []
    }

    var out: [String] = []
    out.reserveCapacity(tokens.size())
    for i in 0 ..< tokens.size() { out.append(tokens[i].string) }
    return out
  }

  /// marks the stack's bottom modifier as part of the mesh, written down only when the scene saves
  nonisolated static func apply(_ stage: UsdStage, _ path: String, _ name: String)
  {
    guard let prim = Kraken.SceneEdit.prim(stage, path) else { return }

    let waiting = applied(stage, path)
    guard !waiting.contains(name) else { return }

    Kraken.Authoring.inSession(stage)
    {
      guard let attribute = prim.attribute(named: pending)
        ?? prim.createAttribute(name: pending, typeName: Sdf.getValueType(for: .tokenArray), custom: true,
                                variability: .uniform) else { return }

      let tokens = (waiting + [name]).map { Tf.Token($0) }
      let array: Pixar.VtTokenArray = tokens.withUnsafeBufferPointer
      {
        Overlay.vtArray($0.baseAddress, $0.count)
      }

      _ = attribute.Set(array, Pixar.UsdTimeCode.Default())
    }
  }

  // MARK: saving

  /// writes every applied modifier into the shot and takes it off the stack, called while the scene saves
  nonisolated static func flush(_ stage: UsdStage, _ paths: [String], _ time: Double)
  {
    for path in paths
    {
      let waiting = applied(stage, path)
      guard !waiting.isEmpty, let prim = Kraken.SceneEdit.prim(stage, path) else { continue }

      clearSession(stage, prim)

      let stack = read(stage, path)
      let baking = stack.filter { waiting.contains($0.name) }
      let mesh = Kraken.SceneEdit.mesh(stage, path, time)
      guard mesh.valid, !baking.isEmpty else { continue }

      let points = stride(from: 0, to: mesh.points.count - 2, by: 3)
        .map { SIMD3<Float>(mesh.points[$0], mesh.points[$0 + 1], mesh.points[$0 + 2]) }
      let cage = Geometry.cage(points: points, counts: mesh.counts, indices: mesh.indices, creases: mesh.creases,
                               creaseSharpness: mesh.creaseSharpness, sharp: mesh.sharp)

      var baked = cage
      for entry in baking { baked = apply(entry, to: baked) }

      Kraken.Authoring.edit(stage, path)
      { prim, _ in
        author(prim, baked, cage)
        return true
      }

      for entry in baking { remove(stage, path, entry.name) }

      Kraken.Authoring.inSession(stage) { _ = prim.attribute(named: pending)?.Clear() }
      sync(stage, path, time)
    }
  }

  // MARK: the whole stage

  /// every mesh on the stage that carries a stack
  nonisolated static func stacked(_ stage: UsdStage) -> [String]
  {
    var paths: [String] = []
    func visit(_ prim: UsdPrim)
    {
      for child in Kraken.SceneEdit.children(prim)
      {
        if child.isA(.mesh), child.attribute(named: order) != nil { paths.append(child.GetPath().string) }
        visit(child)
      }
    }

    visit(stage.GetPseudoRoot())
    return paths
  }

  /// evaluates every stack on the stage, after a scene opens or before a final render
  nonisolated static func syncAll(_ stage: UsdStage, _ time: Double, render: Bool = false)
  {
    for path in stacked(stage) { sync(stage, path, time, render: render) }
  }
}
