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

  /// Points, faces and flat face varying normals.
  nonisolated static func author(_ mesh: Pixar.UsdGeomMesh, _ points: [SIMD3<Float>], _ counts: [Int32], _ indices: [Int32])
  {
    var mesh = mesh
    var normals: [SIMD3<Float>] = []
    normals.reserveCapacity(indices.count)
    var offset = 0
    for count in counts.map(Int.init)
    {
      let face = Array(indices[offset ..< offset + count].map(Int.init))
      let n = Kraken.PrimitiveShape.newell(points, face)
      let unit = simd_length(n) > 0 ? simd_normalize(n) : SIMD3<Float>(0, 0, 1)
      normals.append(contentsOf: repeatElement(unit, count: count))
      offset += count
    }

    let p = vec3fArray(points)
    let time = Pixar.UsdTimeCode.Default()
    _ = mesh.GetPointsAttr().Set(p, time)
    _ = mesh.GetFaceVertexCountsAttr().Set(intArray(counts), time)
    _ = mesh.GetFaceVertexIndicesAttr().Set(intArray(indices), time)
    _ = mesh.GetNormalsAttr().Set(vec3fArray(normals), time)
    _ = mesh.SetNormalsInterpolation(.faceVarying)
    var extent = Pixar.VtVec3fArray()
    if Pixar.UsdGeomPointBased.ComputeExtent(p, &extent) { _ = mesh.GetExtentAttr().Set(extent, time) }
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

  /// Adds the "Shift+A" menu's mesh `kind` at `xyz`, in the department layer.
  nonisolated static func add(_ stage: UsdStage, _ kind: Kraken.AddKind, at xyz: SIMD3<Double>) -> String
  {
    Kraken.Authoring.inDepartment(stage)
    { () -> String in
      let unit = units(stage), up = yUp(stage)
      let home = stage.GetDefaultPrim()
      let nested = home.isValid && home.isA(.xformable) && !home.isInstance
      let parent: Pixar.SdfPath = nested ? home.GetPath() : Sdf.Path.absoluteRootPath()
      let path = uniqueChild(stage, parent, kind.name)
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
          let shape = Kraken.PrimitiveShape.named(kind)
          let mesh = UsdGeom.Mesh.define(stage, path: path)
          _ = mesh.CreateSubdivisionSchemeAttr(any, false).Set(Tf.Token.none_, Pixar.UsdTimeCode.Default())
          author(mesh, shape.points.map { toStage($0, unit: unit, yUp: up) }, shape.faces.map { Int32($0.count) },
                 shape.faces.flatMap { $0.map(Int32.init) })
          prim = mesh.GetPrim()
      }
      // Gf matrices transform row vectors, so as simd columns they're transposed.
      var m = matrix_identity_double4x4
      if oriented && up { m = simd_double4x4(rows: [SIMD4(1, 0, 0, 0), SIMD4(0, 0, -1, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 0, 1)]) }
      m.columns.3 = SIMD4(xyz, 1)
      var local = Kraken.Layout.array(m.transpose)
      if nested
      {
        var cache = Pixar.UsdGeomXformCache(Pixar.UsdTimeCode.Default())
        let home = Kraken.Layout.matrix(rows(cache.GetLocalToWorldTransform(stage.GetDefaultPrim())))
        local = Kraken.Layout.array(home.inverse * Kraken.Layout.matrix(local))
      }

      let op = UsdGeom.Xformable(prim).addXformOp(type: .transform, precision: .double)
      _ = op.Set(matrix(local), Pixar.UsdTimeCode.Default())
      return path.string
    }
  }

  @discardableResult
  nonisolated static func setTransform(_ stage: UsdStage, _ path: String, _ local: [Double]) -> Bool
  {
    // Writing a static matrix would wipe out an animated transform, so hold the move in the session layer instead.
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
                                  _ indices: [Int32]) -> Bool
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
          #if compiler(>=6.4)
            primvar.GetAttrConsuming().Block()
          #else
            primvar.GetAttr().Block()
          #endif
          let indicesAttr = primvar.GetIndicesAttr()
          if indicesAttr.isValid { indicesAttr.Block() }
        }
      }
      #if compiler(>=6.4)
        let normals = primvars.GetPrimvar(.normals).GetAttrConsuming()
      #else
        let normals = primvars.GetPrimvar(.normals).GetAttr()
      #endif
      if normals.isValid { normals.Block() }
      author(mesh, p, counts, indices)
      return true
    }
  }

  /// Defined only in the department layer, with nothing composed under it, so deleting it there removes it.
  nonisolated static func ownsAlone(_ stage: UsdStage, _ prim: UsdPrim) -> Bool
  {
    let department = Kraken.Authoring.identifier(Kraken.Authoring.department(stage))
    for layer in stage.GetLayerStack(true) where Kraken.Authoring.identifier(layer) != department
    {
      if layer.pointee.HasSpec(prim.GetPath()) { return false }
    }

    var query = Pixar.UsdPrimCompositionQuery(prim, Pixar.UsdPrimCompositionQuery.Filter())
    return query.GetCompositionArcs().size() <= 1
  }

  /// Deletes what the department layer made, deactivates what it didn't, the way a shot prunes.
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

  /// Visibility the scene keeps, in the department layer.
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

  /// Hides or shows `path` in the viewport only, in the session layer.
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

  /// Turns an implicit primitive into the mesh it draws as, in place.
  @discardableResult
  nonisolated static func makeMesh(_ stage: UsdStage, _ path: String, _ time: Double) -> Bool
  {
    guard let prim = prim(stage, path), !prim.IsInstanceProxy() else { return false }
    if prim.isA(.mesh) { return true }
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
      return false
    }

    let points = shape.points.map
    { p -> SIMD3<Float> in
      let q = p * scale
      return up == .x ? SIMD3(q.z, q.x, q.y) : up == .y ? SIMD3(q.y, q.z, q.x) : q
    }

    return Kraken.Authoring.edit(stage, path)
    { target, _ in
      _ = target.SetTypeName(.mesh)
      let mesh = Pixar.UsdGeomMesh(target)
      _ = mesh.CreateSubdivisionSchemeAttr(Pixar.VtValue(), false).Set(Tf.Token.none_, Pixar.UsdTimeCode.Default())
      author(mesh, points, shape.faces.map { Int32($0.count) }, shape.faces.flatMap { $0.map(Int32.init) })
      return true
    }
  }
}
