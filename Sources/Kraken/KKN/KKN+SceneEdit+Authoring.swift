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

extension Kraken.SceneEdit
{
  nonisolated static func vec3fArray(_ points: [SIMD3<Float>]) -> Pixar.VtVec3fArray
  {
    let vectors = points.map { Pixar.GfVec3f($0.x, $0.y, $0.z) }
    return vectors.withUnsafeBufferPointer { Overlay.vtArray($0.baseAddress, $0.count) }
  }

  nonisolated static func intArray(_ values: [Int32]) -> Pixar.VtIntArray
  {
    values.withUnsafeBufferPointer { Overlay.vtArray($0.baseAddress, $0.count) }
  }

  nonisolated static func floatArray(_ values: [Float]) -> Pixar.VtFloatArray
  {
    values.withUnsafeBufferPointer { Overlay.vtArray($0.baseAddress, $0.count) }
  }

  /// face varying normals smoothed across edges flatter than `angle` degrees, sharp elsewhere and along every edge in `sharp`
  nonisolated static func smoothNormals(_ points: [SIMD3<Float>], _ counts: [Int32], _ indices: [Int32],
                                        angle: Float = 40, sharp: Set<Kraken.Edge> = []) -> [SIMD3<Float>]
  {
    var faces: [[Int]] = []
    faces.reserveCapacity(counts.count)
    var offset = 0
    for count in counts.map(Int.init)
    {
      faces.append(indices[offset ..< offset + count].map(Int.init))
      offset += count
    }

    let weighted = faces.map { Kraken.PrimitiveShape.newell(points, $0) }
    let unit = weighted.map { simd_length($0) > 0 ? simd_normalize($0) : SIMD3<Float>(0, 0, 1) }

    var around = [[Int]](repeating: [], count: points.count)
    for (f, face) in faces.enumerated()
    {
      for v in face where v < points.count { around[v].append(f) }
    }

    let limit = cos(angle * .pi / 180)
    var normals: [SIMD3<Float>] = []
    normals.reserveCapacity(indices.count)

    for (f, face) in faces.enumerated()
    {
      for v in face
      {
        guard v < points.count else
        {
          normals.append(unit[f])
          continue
        }

        var sum = SIMD3<Float>.zero
        if sharp.isEmpty
        {
          for g in around[v] where simd_dot(unit[f], unit[g]) >= limit { sum += weighted[g] }
        }
        else
        {
          for g in fan(of: f, around: v, faces, around[v], unit, limit, sharp) { sum += weighted[g] }
        }

        normals.append(simd_length(sum) > 0 ? simd_normalize(sum) : unit[f])
      }
    }

    return normals
  }

  /// the faces around `v` that `f` reaches across edges that aren't sharp and whose faces meet flatter than `limit`
  private nonisolated static func fan(of f: Int, around v: Int, _ faces: [[Int]], _ touching: [Int], _ unit: [SIMD3<Float>],
                                      _ limit: Float, _ sharp: Set<Kraken.Edge>) -> [Int]
  {
    func neighbors(_ g: Int) -> Set<Int>
    {
      let face = faces[g]
      guard let i = face.firstIndex(of: v) else { return [] }
      return [face[(i + face.count - 1) % face.count], face[(i + 1) % face.count]]
    }

    var reached = [f]
    var seen: Set<Int> = [f]
    var head = 0

    while head < reached.count
    {
      let c = reached[head]
      head += 1

      let sides = neighbors(c)
      for g in touching where !seen.contains(g) && simd_dot(unit[c], unit[g]) >= limit
      {
        let shared = sides.intersection(neighbors(g))
        guard shared.contains(where: { !sharp.contains(Kraken.Edge(v, $0)) }) else { continue }
        seen.insert(g)
        reached.append(g)
      }
    }

    return reached
  }

  /// writes points, faces, auto smoothed normals split at sharp edges, and creases as pairs of verts
  nonisolated static func author(_ mesh: Pixar.UsdGeomMesh, _ points: [SIMD3<Float>], _ counts: [Int32], _ indices: [Int32],
                                 creases: [Int32] = [], creaseSharpness: [Float] = [], sharp: [Int32] = [])
  {
    var mesh = mesh
    let sharpEdges = Set(stride(from: 0, to: sharp.count - 1, by: 2).map { Kraken.Edge(Int(sharp[$0]), Int(sharp[$0 + 1])) })
    let normals = smoothNormals(points, counts, indices, sharp: sharpEdges)
    let p = vec3fArray(points)
    let time = Pixar.UsdTimeCode.Default()

    _ = mesh.GetPointsAttr().Set(p, time)
    _ = mesh.GetFaceVertexCountsAttr().Set(intArray(counts), time)
    _ = mesh.GetFaceVertexIndicesAttr().Set(intArray(indices), time)
    _ = mesh.GetNormalsAttr().Set(vec3fArray(normals), time)
    _ = mesh.SetNormalsInterpolation(.faceVarying)

    var extent = Pixar.VtVec3fArray()
    if Pixar.UsdGeomPointBased.ComputeExtent(p, &extent) { _ = mesh.GetExtentAttr().Set(extent, time) }

    // only rewritten where there are creases now or were before, so plain meshes stay plain
    let creaseIndices = mesh.GetCreaseIndicesAttr()
    if !creaseSharpness.isEmpty || creaseIndices.HasAuthoredValue()
    {
      _ = creaseIndices.Set(intArray(creases), time)
      _ = mesh.GetCreaseLengthsAttr().Set(intArray([Int32](repeating: 2, count: creaseSharpness.count)), time)
      _ = mesh.GetCreaseSharpnessesAttr().Set(floatArray(creaseSharpness), time)
    }

    let prim = mesh.GetPrim()
    if let edges = prim.attribute(named: sharpEdgesName) ?? (sharp.isEmpty ? nil : prim.createAttribute(name: sharpEdgesName, typeName: .intArray))
    {
      _ = edges.Set(intArray(sharp), time)
    }
  }

  nonisolated static func uniqueChild(_ stage: UsdStage, _ parent: Pixar.SdfPath, _ base: String) -> Pixar.SdfPath
  {
    var name = String(base.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })
    if name.first?.isNumber ?? true { name = "_" + name }

    var path = parent.AppendChild(Tf.Token(name))
    var i = 1

    while stage.getPrim(at: path).isValid
    {
      path = parent.AppendChild(Tf.Token(name + String(format: "_%03d", i)))
      i += 1
    }

    return path
  }

  /// applies MaterialBindingAPI in the never saved session layer to prims that bind without it, since hydra ignores those bindings
  nonisolated static func adoptLegacyBindings(_ stage: UsdStage, under root: UsdPrim? = nil)
  {
    let names = [Tf.Token("material:binding"), Tf.Token("material:binding:preview"), Tf.Token("material:binding:full")]
    var found: [UsdPrim] = []

    func visit(_ prim: UsdPrim)
    {
      if !prim.hasAPI(.materialBindingAPI), names.contains(where: { prim.HasRelationship($0) }) { found.append(prim) }

      // an instance's prims are shared, its prototype can't take an opinion from here
      guard !prim.isInstance else { return }
      for child in children(prim) { visit(child) }
    }

    visit(root ?? stage.GetPseudoRoot())
    guard !found.isEmpty else { return }

    let previous = Kraken.Authoring.editTarget(stage)
    stage.SetEditTarget(Kraken.Authoring.target(stage.GetSessionLayer()))
    defer { stage.SetEditTarget(previous) }

    for prim in found { _ = UsdShade.MaterialBindingAPI.apply(prim) }
  }

  /// adds a shift a menu item of `kind` at `xyz` in the department layer
  nonisolated static func add(_ stage: UsdStage, _ kind: Kraken.AddKind, at xyz: SIMD3<Double>,
                              options: Kraken.AddOptions = .standard, under parentPath: String? = nil) -> String
  {
    // under the parent asked for, else the default prim when it can hold children, else the root
    let home = parentPath.map { $0 == "/" ? UsdPrim() : stage.GetPrimAtPath(Sdf.Path($0)) } ?? stage.GetDefaultPrim()
    let nested = home.isValid && home.isA(.xformable) && !home.isInstance
    let parent: Pixar.SdfPath = home.isValid ? home.GetPath() : Sdf.Path.absoluteRootPath()
    let path = uniqueChild(stage, parent, kind.name)

    return Kraken.Authoring.inDepartment(stage, for: path)
    { () -> String in
      let unit = units(stage), up = yUp(stage)
      let any = Pixar.VtValue()
      var oriented = false
      let prim: UsdPrim

      switch kind
      {
        case .point, .spot:
          let light = UsdLux.SphereLight.define(stage, path: path)
          light.CreateRadiusAttr(any, false).set(0.1 * unit)
          light.CreateIntensityAttr(any, false).set(kind == .spot ? Float(400) : Float(100))
          light.CreateTreatAsPointAttr(any, false).set(false)
          if kind == .spot
          {
            let shaping = Pixar.UsdLuxShapingAPI.Apply(light.GetPrim())
            shaping.CreateShapingConeAngleAttr(any, false).set(Float(45))
            shaping.CreateShapingConeSoftnessAttr(any, false).set(Float(0.15))
            oriented = true
          }

          prim = light.GetPrim()
        case .sun:
          let light = UsdLux.DistantLight.define(stage, path: path)
          light.CreateIntensityAttr(any, false).set(Float(50000))
          light.CreateAngleAttr(any, false).set(Float(0.526))
          prim = light.GetPrim()
          oriented = true
        case .area:
          let light = UsdLux.RectLight.define(stage, path: path)
          light.CreateWidthAttr(any, false).set(unit)
          light.CreateHeightAttr(any, false).set(unit)
          light.CreateIntensityAttr(any, false).set(Float(50))
          prim = light.GetPrim()
          oriented = true
        case .tube:
          // a tube of light along its local x axis
          let light = UsdLux.CylinderLight.define(stage, path: path)
          light.CreateRadiusAttr(any, false).set(Float(0.05 * unit))
          light.CreateLengthAttr(any, false).set(Float(unit))
          light.CreateIntensityAttr(any, false).set(Float(100))
          prim = light.GetPrim()
        case .dome:
          // an even white world until a texture is picked for it
          let light = UsdLux.DomeLight.define(stage, path: path)
          light.CreateIntensityAttr(any, false).set(Float(1))
          prim = light.GetPrim()
        case .camera:
          let camera = UsdGeom.Camera.define(stage, path: path)
          camera.CreateFocalLengthAttr(any, false).set(Float(50))
          camera.CreateHorizontalApertureAttr(any, false).set(Float(36))
          camera.CreateVerticalApertureAttr(any, false).set(Float(24))
          _ = camera.CreateClippingRangeAttr(any, false).Set(Pixar.GfVec2f(0.1 * unit, 1000 * unit), Pixar.UsdTimeCode.Default())
          prim = camera.GetPrim()
          oriented = true
        case .empty:
          prim = UsdGeom.Xform.define(stage, path: path).GetPrim()
        default:
          let shape = Kraken.PrimitiveShape.named(kind, options)
          let mesh = UsdGeom.Mesh.define(stage, path: path)
          _ = mesh.CreateSubdivisionSchemeAttr(any, false).Set(Tf.Token.none_, Pixar.UsdTimeCode.Default())
          author(mesh, shape.points.map { toStage($0, unit: unit, yUp: up) }, shape.faces.map { Int32($0.count) },
                 shape.faces.flatMap { $0.map(Int32.init) })

          // a sheet has no inside, it shows from both sides like it does while modeling
          if [.plane, .grid, .circle].contains(kind) { _ = mesh.CreateDoubleSidedAttr(any, false).Set(true, Pixar.UsdTimeCode.Default()) }
          prim = mesh.GetPrim()
      }

      // m transforms column vectors and `Kraken.Layout.array` writes its columns as the gf rows
      var m = matrix_identity_double4x4
      if oriented && up { m = simd_double4x4(rows: [SIMD4(1, 0, 0, 0), SIMD4(0, 0, -1, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 0, 1)]).transpose }
      m.columns.3 = SIMD4(xyz, 1)

      var local = Kraken.Layout.array(m)
      if nested
      {
        var cache = Pixar.UsdGeomXformCache(Pixar.UsdTimeCode.Default())
        let world = Kraken.Layout.matrix(rows(cache.GetLocalToWorldTransform(home)))
        local = Kraken.Layout.array(world.inverse * Kraken.Layout.matrix(local))
      }

      let op = UsdGeom.Xformable(prim).addXformOp(type: .transform, precision: .double)
      _ = op.Set(matrix(local), Pixar.UsdTimeCode.Default())
      return path.string
    }
  }

  @discardableResult
  nonisolated static func setTransform(_ stage: UsdStage, _ path: String, _ local: [Double]) -> Bool
  {
    // writing a static matrix would wipe out an animated transform, so hold the move in the session layer instead
    if local.count == 16, let held = overrideTransform(stage, path, local) { return held }

    return Kraken.Authoring.edit(stage, path)
    { prim, _ in
      guard prim.isA(.xformable), local.count == 16 else { return false }

      let xformable = Pixar.UsdGeomXformable(prim)
      var resets = false
      let ops = xformable.GetOrderedXformOps(&resets)
      var op: Pixar.UsdGeomXformOp
      let single = ops.size() == 1 && ops[0].GetOpType() == .transform

      if single
      {
        op = ops[0]
      }
      else
      {
        _ = xformable.ClearXformOpOrder()
        op = xformable.addXformOp(type: .transform, precision: .double)
        if resets { _ = xformable.SetResetXformStack(true) }
      }

      return op.Set(matrix(local), Pixar.UsdTimeCode.Default())
    }
  }

  @discardableResult
  nonisolated static func setMesh(_ stage: UsdStage, _ path: String, _ points: [Float], _ counts: [Int32],
                                  _ indices: [Int32], creases: [Int32] = [], creaseSharpness: [Float] = [],
                                  sharp: [Int32] = []) -> Bool
  {
    Kraken.Authoring.edit(stage, path)
    { prim, _ in
      guard prim.isA(.mesh) else { return false }

      let mesh = Pixar.UsdGeomMesh(prim)
      let old: Mesh = Self.mesh(stage, path, Pixar.UsdTimeCode.Default().GetValue())

      var p: [SIMD3<Float>] = []
      p.reserveCapacity(points.count / 3)
      for i in stride(from: 0, to: points.count - 2, by: 3) { p.append(SIMD3(points[i], points[i + 1], points[i + 2])) }

      let primvars = Pixar.UsdGeomPrimvarsAPI(prim)
      let sameTopology = old.counts == counts && old.indices == indices
      if !sameTopology || old.points.count != points.count
      {
        for primvar in primvars.GetPrimvars() where primvar.GetInterpolation() != .constant
        {
          #if compiler(>=6.4) && canImport(Usd)
            primvar.GetAttrConsuming().Block()
          #else
            primvar.GetAttr().Block()
          #endif

          let indicesAttr = primvar.GetIndicesAttr()
          if indicesAttr.isValid { indicesAttr.Block() }
        }
      }

      #if compiler(>=6.4) && canImport(Usd)
        let normals = primvars.GetPrimvar(.normals).GetAttrConsuming()
      #else
        let normals = primvars.GetPrimvar(.normals).GetAttr()
      #endif
      if normals.isValid { normals.Block() }

      author(mesh, p, counts, indices, creases: creases, creaseSharpness: creaseSharpness, sharp: sharp)
      return true
    }
  }

  /// how much of a mesh shows through while modelling works on the cage under its stack
  nonisolated static let ghostOpacity: Float = 0.14

  nonisolated static let displayOpacityName = Tf.Token("primvars:displayOpacity")

  /// dims the mesh at `path` so the cage reads against it, or restores it, in the never saved session layer
  nonisolated static func ghost(_ stage: UsdStage, _ path: String, on: Bool)
  {
    guard let prim = prim(stage, path), prim.isA(.mesh), !prim.IsInstanceProxy() else { return }

    Kraken.Authoring.inSession(stage)
    {
      var owner = prim
      guard on else
      {
        _ = owner.RemoveProperty(displayOpacityName)
        return
      }

      let primvar = Pixar.UsdGeomPrimvarsAPI(prim)
        .CreatePrimvar(Tf.Token("displayOpacity"), .floatArray, .constant, -1)
      _ = primvar.Set(floatArray([ghostOpacity]), Pixar.UsdTimeCode.Default())
    }
  }

  nonisolated static func isMesh(_ stage: UsdStage, _ path: String) -> Bool
  {
    guard let prim = prim(stage, path) else { return false }

    return prim.isA(.mesh) && !prim.IsInstanceProxy()
  }

  /// shades the mesh smoothly across its faces or flat on each one, by writing the normals it shades with
  @discardableResult
  nonisolated static func shade(_ stage: UsdStage, _ path: String, smooth: Bool, time: Double) -> Bool
  {
    let data = mesh(stage, path, time)
    guard data.valid else { return false }

    let points = stride(from: 0, to: data.points.count - 2, by: 3)
      .map { SIMD3<Float>(data.points[$0], data.points[$0 + 1], data.points[$0 + 2]) }
    let sharp = smooth ? [] : Set(stride(from: 0, to: data.sharp.count - 1, by: 2)
      .map { Kraken.Edge(Int(data.sharp[$0]), Int(data.sharp[$0 + 1])) })
    let normals = smoothNormals(points, data.counts, data.indices, angle: smooth ? 180 : 0, sharp: sharp)

    return Kraken.Authoring.edit(stage, path)
    { prim, _ in
      guard prim.isA(.mesh) else { return false }

      var mesh = Pixar.UsdGeomMesh(prim)
      _ = mesh.GetNormalsAttr().Set(vec3fArray(normals), Pixar.UsdTimeCode.Default())
      _ = mesh.SetNormalsInterpolation(.faceVarying)

      // shading everything smooth means no edge is held hard any more
      if smooth, let edges = prim.attribute(named: sharpEdgesName), edges.HasAuthoredValue()
      {
        _ = edges.Set(intArray([]), Pixar.UsdTimeCode.Default())
      }

      return true
    }
  }

  /// whether the department layer alone made the prim, its spec and every arc on it authored there, so deleting it removes it
  nonisolated static func ownsAlone(_ stage: UsdStage, _ prim: UsdPrim) -> Bool
  {
    let department = Kraken.Authoring.identifier(Kraken.Authoring.department(stage))
    for layer in stage.GetLayerStack(true) where Kraken.Authoring.identifier(layer) != department
    {
      if layer.pointee.HasSpec(prim.GetPath()) { return false }
    }

    // arcs the asset itself composes are its own business, only the ones the stage's layers author count
    var filter = Pixar.UsdPrimCompositionQuery.Filter()
    filter.arcIntroducedFilter = .IntroducedInRootLayerStack
    var query = Pixar.UsdPrimCompositionQuery(prim, filter)
    let path = prim.GetPath().string
    for arc in query.GetCompositionArcs() where arc.GetArcType() != Pixar.PcpArcTypeRoot
    {
      guard Kraken.Authoring.identifier(arc.GetIntroducingLayer()) == department, arc.GetIntroducingPrimPath().string == path
      else { return false }
    }

    return true
  }

  /// deletes what the department layer made and deactivates what it didn't, the way a shot prunes
  nonisolated static func remove(_ stage: UsdStage, _ path: String)
  {
    guard let prim = prim(stage, path), !prim.IsInstanceProxy() else { return }

    Kraken.Authoring.inDepartment(stage)
    {
      if ownsAlone(stage, prim) { _ = stage.RemovePrim(prim.GetPath()) }
      else { _ = prim.SetActive(false) }
    }
  }

  nonisolated static func duplicate(_ stage: UsdStage, _ path: String) -> String
  {
    guard let prim = prim(stage, path), !prim.IsInstanceProxy() else { return "" }

    return Kraken.Authoring.inDepartment(stage)
    { () -> String in
      let department = Kraken.Authoring.department(stage)
      var base = prim.name.string
      if let cut = base.lastIndex(of: "_"), base.distance(from: cut, to: base.endIndex) == 4,
         base[base.index(after: cut)].isNumber
      {
        base = String(base[..<cut])
      }

      let target = uniqueChild(stage, prim.GetPath().GetParentPath(), base)
      let own = ownsAlone(stage, prim)

      if department.pointee.HasSpec(prim.GetPath())
      {
        if !target.GetParentPath().IsAbsoluteRootPath() { _ = Pixar.SdfCreatePrimInLayer(department, target.GetParentPath()) }
        _ = Pixar.SdfCopySpec(department, prim.GetPath(), department, target)
      }

      if !own
      {
        let copy = stage.DefinePrim(target, prim.typeName)
        var references = copy.GetReferences()
        _ = references.AddInternalReference(prim.GetPath(), Pixar.SdfLayerOffset(offset: 0, scale: 1),
                                            Pixar.UsdListPositionBackOfPrependList)
      }

      return target.string
    }
  }

  /// sets the visibility the scene keeps, in the department layer
  nonisolated static func setVisible(_ stage: UsdStage, _ path: String, _ visible: Bool)
  {
    Kraken.Authoring.edit(stage, path)
    { prim, _ in
      let imageable = Pixar.UsdGeomImageable(prim)
      if visible { imageable.MakeVisible(Pixar.UsdTimeCode.Default()) }
      else { imageable.MakeInvisible(Pixar.UsdTimeCode.Default()) }
      return true
    }
  }

  /// hides or shows `path` in the viewport only, in the session layer
  nonisolated static func setHidden(_ stage: UsdStage, _ path: String, _ hidden: Bool)
  {
    guard let prim = prim(stage, path) else { return }

    Kraken.Authoring.inSession(stage)
    {
      let imageable = Pixar.UsdGeomImageable(prim)
      if hidden { imageable.MakeInvisible(Pixar.UsdTimeCode.Default()) }
      else { imageable.MakeVisible(Pixar.UsdTimeCode.Default()) }
    }
  }

  @discardableResult
  nonisolated static func setLight(_ stage: UsdStage, _ path: String, size: Double, size2: Double, angle: Double) -> Bool
  {
    Kraken.Authoring.edit(stage, path)
    { prim, _ in
      let any = Pixar.VtValue()
      if prim.isA(.rectLight)
      {
        let light = Pixar.UsdLuxRectLight(prim)
        light.CreateWidthAttr(any, false).set(Float(size))
        light.CreateHeightAttr(any, false).set(Float(size2))
      }
      else if prim.isA(.diskLight)
      {
        Pixar.UsdLuxDiskLight(prim).CreateRadiusAttr(any, false).set(Float(size))
      }
      else if prim.isA(.sphereLight)
      {
        if prim.hasAPI(.shapingAPI), angle > 0
        {
          Pixar.UsdLuxShapingAPI(prim).CreateShapingConeAngleAttr(any, false).set(Float(angle))
        }
        else
        {
          Pixar.UsdLuxSphereLight(prim).CreateRadiusAttr(any, false).set(Float(size))
        }
      }
      else if prim.isA(.distantLight)
      {
        if angle > 0 { Pixar.UsdLuxDistantLight(prim).CreateAngleAttr(any, false).set(Float(angle)) }
      }
      else
      {
        return false
      }

      return true
    }
  }

  /// turns an implicit primitive into the mesh it draws as, in place
  @discardableResult
  nonisolated static func makeMesh(_ stage: UsdStage, _ path: String, _ time: Double) -> Bool
  {
    guard let prim = prim(stage, path), !prim.IsInstanceProxy() else { return false }
    if prim.isA(.mesh) { return true }
    guard let shape = implicitMesh(prim, time) else { return false }

    return Kraken.Authoring.edit(stage, path)
    { target, _ in
      _ = target.SetTypeName(.mesh)
      let mesh = Pixar.UsdGeomMesh(target)
      _ = mesh.CreateSubdivisionSchemeAttr(Pixar.VtValue(), false).Set(Tf.Token.none_, Pixar.UsdTimeCode.Default())
      author(mesh, shape.points, shape.counts, shape.indices)
      return true
    }
  }

  /// the mesh an implicit primitive draws as, in its own space, nil for anything that isn't one
  nonisolated static func implicitMesh(_ prim: UsdPrim, _ time: Double)
    -> (points: [SIMD3<Float>], counts: [Int32], indices: [Int32])?
  {
    guard prim.isValid, !prim.isA(.mesh) else { return nil }

    let t = Pixar.UsdTimeCode(time)

    func double(_ attribute: Usd.Attribute) -> Double
    {
      var d = 1.0
      _ = attribute.Get(&d, t)
      return d
    }

    func axis(_ attribute: Usd.Attribute) -> Tf.Token
    {
      var token = Tf.Token.z
      _ = attribute.Get(&token, t)
      return token
    }

    var shape: Kraken.PrimitiveShape
    var scale = SIMD3<Float>(repeating: 1)
    var up = Tf.Token.z

    if prim.isA(.cube)
    {
      shape = Kraken.PrimitiveShape.named(.cube)
      scale = SIMD3(repeating: Float(double(Pixar.UsdGeomCube(prim).GetSizeAttr()) / 2))
    }
    else if prim.isA(.sphere)
    {
      shape = Kraken.PrimitiveShape.named(.uvsphere)
      scale = SIMD3(repeating: Float(double(Pixar.UsdGeomSphere(prim).GetRadiusAttr())))
    }
    else if prim.isA(.cylinder)
    {
      let cylinder = Pixar.UsdGeomCylinder(prim)
      shape = Kraken.PrimitiveShape.named(.cylinder)
      let r = Float(double(cylinder.GetRadiusAttr())), h = Float(double(cylinder.GetHeightAttr()))
      scale = SIMD3(r, r, h / 2)
      up = axis(cylinder.GetAxisAttr())
    }
    else if prim.isA(.cone)
    {
      let cone = Pixar.UsdGeomCone(prim)
      shape = Kraken.PrimitiveShape.named(.cone)
      let r = Float(double(cone.GetRadiusAttr())), h = Float(double(cone.GetHeightAttr()))
      scale = SIMD3(r, r, h / 2)
      up = axis(cone.GetAxisAttr())
    }
    else if prim.isA(.capsule)
    {
      let capsule = Pixar.UsdGeomCapsule(prim)
      shape = Kraken.PrimitiveShape.named(.uvsphere)
      let r = double(capsule.GetRadiusAttr()), h = double(capsule.GetHeightAttr())
      shape.points = shape.points.map { SIMD3($0.x, $0.y, $0.z + ($0.z >= 0 ? 1 : -1) * Float(h / 2 / r)) }
      scale = SIMD3(repeating: Float(r))
      up = axis(capsule.GetAxisAttr())
    }
    else if prim.isA(.plane)
    {
      let plane = Pixar.UsdGeomPlane(prim)
      shape = Kraken.PrimitiveShape.named(.plane)
      scale = SIMD3(Float(double(plane.GetWidthAttr()) / 2), Float(double(plane.GetLengthAttr()) / 2), 1)
      up = axis(plane.GetAxisAttr())
    }
    else
    {
      return nil
    }

    let points = shape.points.map
    { p -> SIMD3<Float> in
      let q = p * scale
      return up == .x ? SIMD3(q.z, q.x, q.y) : up == .y ? SIMD3(q.y, q.z, q.x) : q
    }

    return (points, shape.faces.map { Int32($0.count) }, shape.faces.flatMap { $0.map(Int32.init) })
  }
}
