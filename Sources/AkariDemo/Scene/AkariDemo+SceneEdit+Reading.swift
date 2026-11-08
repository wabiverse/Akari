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

extension AkariDemo.SceneEdit
{
  nonisolated static func prim(_ stage: UsdStage, _ path: String) -> UsdPrim?
  {
    guard Pixar.SdfPath.IsValidPathString(std.string(path), nil) else { return nil }
    let prim = stage.GetPrimAtPath(Sdf.Path(path))
    return prim.isValid ? prim : nil
  }

  nonisolated static func numbers(_ v: Pixar.GfVec3d) -> [Double]
  {
    Array(UnsafeBufferPointer(start: v.GetArray(), count: 3))
  }

  nonisolated static func rows(_ m: Pixar.GfMatrix4d) -> [Double]
  {
    Array(UnsafeBufferPointer(start: m.GetArray(), count: 16))
  }

  nonisolated static func matrix(_ a: [Double]) -> Pixar.GfMatrix4d
  {
    Pixar.GfMatrix4d(a[0], a[1], a[2], a[3], a[4], a[5], a[6], a[7], a[8], a[9], a[10], a[11], a[12], a[13], a[14], a[15])
  }

  nonisolated static func invisible(_ prim: UsdPrim, _ t: Pixar.UsdTimeCode) -> Bool
  {
    Pixar.UsdGeomImageable(prim).ComputeVisibility(t) == .invisible
  }

  nonisolated static func float(_ attribute: Usd.Attribute, _ t: Pixar.UsdTimeCode) -> Double?
  {
    var f: Float = 0
    return attribute.Get(&f, t) ? Double(f) : nil
  }

  nonisolated static func children(_ prim: UsdPrim) -> [UsdPrim]
  {
    var range = prim.GetChildren()
    var out: [UsdPrim] = []
    while let child = range.next() { out.append(child) }
    return out
  }

  nonisolated static func hasAnyChild(_ prim: UsdPrim) -> Bool
  {
    var range = prim.GetAllChildren()
    return range.next() != nil
  }

  nonisolated static func isWidget(_ prim: UsdPrim) -> Bool
  {
    prim.isA(.camera) || prim.hasAPI(.lightAPI)
    || (prim.typeName == .xform && !prim.isInstance && !hasAnyChild(prim))
  }

  /// Cameras, lights and empties, drawn as viewport widgets.
  nonisolated static func widgetPaths(_ stage: UsdStage) -> [String]
  {
    var paths: [String] = []
    func visit(_ prim: UsdPrim)
    {
      for child in children(prim)
      {
        if child.isA(.camera) || child.hasAPI(.lightAPI) { paths.append(child.GetPath().string); continue }
        if child.typeName == .xform, !child.isInstance, !hasAnyChild(child) { paths.append(child.GetPath().string) }
        visit(child)
      }
    }

    visit(stage.GetPseudoRoot())
    return paths
  }

  nonisolated static func widgets(_ stage: UsdStage, _ paths: [String], _ time: Double) -> [Object]
  {
    let t = Pixar.UsdTimeCode(time)
    var cache = Pixar.UsdGeomXformCache(t)
    return paths.compactMap
    { path -> Object? in
      guard let prim = prim(stage, path), prim.IsActive(), !invisible(prim, t) else { return nil }
      var o = Object(path: path, world: rows(cache.GetLocalToWorldTransform(prim)))
      if prim.isA(.camera)
      {
        let camera = Pixar.UsdGeomCamera(prim)
        o.kind = .camera
        o.focalLength = float(camera.GetFocalLengthAttr(), t) ?? 0
        o.horizontalAperture = float(camera.GetHorizontalApertureAttr(), t) ?? 0
        o.verticalAperture = float(camera.GetVerticalApertureAttr(), t) ?? 0
      }
      else if prim.isA(.distantLight)
      {
        o.kind = .distantLight
        o.angle = float(Pixar.UsdLuxDistantLight(prim).GetAngleAttr(), t) ?? 0
      }
      else if prim.isA(.sphereLight)
      {
        o.kind = .sphereLight
        o.size = float(Pixar.UsdLuxSphereLight(prim).GetRadiusAttr(), t) ?? 0
        if prim.hasAPI(.shapingAPI), let cone = float(Pixar.UsdLuxShapingAPI(prim).GetShapingConeAngleAttr(), t),
           cone < 179
        {
          o.kind = .spotLight
          o.angle = cone
        }
      }
      else if prim.isA(.rectLight)
      {
        let light = Pixar.UsdLuxRectLight(prim)
        o.kind = .rectLight
        o.size = float(light.GetWidthAttr(), t) ?? 0
        o.size2 = float(light.GetHeightAttr(), t) ?? 0
      }
      else if prim.isA(.diskLight)
      {
        o.kind = .diskLight
        o.size = float(Pixar.UsdLuxDiskLight(prim).GetRadiusAttr(), t) ?? 0
      }
      else if prim.isA(.domeLight)
      {
        o.kind = .domeLight
      }
      else if prim.isA(.cylinderLight)
      {
        let light = Pixar.UsdLuxCylinderLight(prim)
        o.kind = .cylinderLight
        o.size = float(light.GetLengthAttr(), t) ?? 0
        o.size2 = float(light.GetRadiusAttr(), t) ?? 0
      }
      else
      {
        o.kind = prim.hasAPI(.lightAPI) ? .sphereLight : .other
      }

      return o
    }
  }

  nonisolated static func bboxCache(_ t: Pixar.UsdTimeCode) -> Pixar.UsdGeomBBoxCache
  {
    var purposes = Pixar.TfTokenVector()
    purposes.push_back(.default_)
    purposes.push_back(.render)
    return Pixar.UsdGeomBBoxCache(t, purposes, false, false)
  }

  /// What a click can select, with their centers.
  nonisolated static func selectable(_ stage: UsdStage, _ time: Double) -> [Object]
  {
    let t = Pixar.UsdTimeCode(time)
    var xforms = Pixar.UsdGeomXformCache(t)
    var boxes = bboxCache(t)
    var objects: [Object] = []
    func visit(_ prim: UsdPrim)
    {
      for child in children(prim)
      {
        let widget = isWidget(child)
        let object = (child.IsModel() && !child.IsGroup()) || child.isA(.gprim)
          || child.isA(.pointInstancer) || child.isInstance
        guard widget || object else
        {
          visit(child)
          continue
        }

        if invisible(child, t) { continue }
        let world = xforms.GetLocalToWorldTransform(child)
        var c = world.ExtractTranslation()
        if object
        {
          let range = boxes.ComputeWorldBound(child).ComputeAlignedRange()
          if !range.IsEmpty() { c = range.GetMidpoint() }
        }

        objects.append(Object(path: child.GetPath().string, world: rows(world), center: numbers(c)))
      }
    }

    visit(stage.GetPseudoRoot())
    return objects
  }

  /// The object a click on `path` selects, its model, outside any instance.
  nonisolated static func object(for path: String, _ stage: UsdStage) -> String
  {
    guard var p = prim(stage, path) else { return path }
    while p.isValid, p.IsInstanceProxy() { p = p.GetParent() }
    guard p.isValid else { return path }
    var model: UsdPrim?
    var walk = p
    while walk.isValid, !walk.IsPseudoRoot()
    {
      if walk.IsModel(), !walk.IsGroup(), !walk.IsInstanceProxy() { model = walk }
      walk = walk.GetParent()
    }

    return (model ?? p).GetPath().string
  }

  nonisolated static func transform(_ stage: UsdStage, _ path: String, _ time: Double) -> (local: [Double], parent: [Double])?
  {
    guard let prim = prim(stage, path), prim.isA(.xformable) else { return nil }
    let t = Pixar.UsdTimeCode(time)
    var m = Pixar.GfMatrix4d(1.0)
    var resets = false
    _ = Pixar.UsdGeomXformable(prim).GetLocalTransformation(&m, &resets, t)
    var cache = Pixar.UsdGeomXformCache(t)
    return (rows(m), resets ? rows(Pixar.GfMatrix4d(1.0)) : rows(cache.GetParentToWorldTransform(prim)))
  }

  nonisolated static func worldBounds(_ stage: UsdStage, _ path: String, _ time: Double) -> [Double]?
  {
    guard let prim = prim(stage, path) else { return nil }
    var cache = bboxCache(Pixar.UsdTimeCode(time))
    let range = cache.ComputeWorldBound(prim).ComputeAlignedRange()
    guard !range.IsEmpty() else { return nil }
    #if compiler(>=6.4)
      return numbers(range.GetMinConsuming()) + numbers(range.GetMaxConsuming())
    #else
      return numbers(range.GetMin()) + numbers(range.GetMax())
    #endif
  }

  nonisolated static func mesh(_ stage: UsdStage, _ path: String, _ time: Double) -> Mesh
  {
    guard let prim = prim(stage, path), prim.isA(.mesh), !prim.IsInstanceProxy() else { return Mesh() }
    let mesh = Pixar.UsdGeomMesh(prim)
    let t = Pixar.UsdTimeCode(time)
    var points = Pixar.VtVec3fArray(), counts = Pixar.VtIntArray(), indices = Pixar.VtIntArray()
    guard mesh.GetPointsAttr().Get(&points, t), mesh.GetFaceVertexCountsAttr().Get(&counts, t),
          mesh.GetFaceVertexIndicesAttr().Get(&indices, t) else { return Mesh() }
    var out = Mesh(valid: true)
    let xyz: UnsafePointer<Pixar.GfVec3f>? = Overlay.cdata(points)
    let faceCounts: UnsafePointer<Int32>? = Overlay.cdata(counts)
    let faceIndices: UnsafePointer<Int32>? = Overlay.cdata(indices)
    if let xyz
    {
      out.points = Array(UnsafeBufferPointer(start: UnsafeRawPointer(xyz).assumingMemoryBound(to: Float.self), count: points.size() * 3))
    }

    out.counts = Array(UnsafeBufferPointer(start: faceCounts, count: counts.size()))
    out.indices = Array(UnsafeBufferPointer(start: faceIndices, count: indices.size()))
    return out
  }

  nonisolated static func units(_ stage: UsdStage) -> Float
  {
    let metersPerUnit = UsdGeom.getMetersPerUnit(for: stage)
    return Float(1 / (metersPerUnit > 0 ? metersPerUnit : 1))
  }

  nonisolated static func yUp(_ stage: UsdStage) -> Bool
  {
    UsdGeom.getUpAxis(for: stage) == .y
  }

  nonisolated static func toStage(_ p: SIMD3<Float>, unit: Float, yUp: Bool) -> SIMD3<Float>
  {
    let q = p * unit
    return yUp ? SIMD3(q.x, q.z, -q.y) : q
  }

  /// A primitive's mesh as Add would author it, for the edit mode preview.
  nonisolated static func primitive(_ stage: UsdStage, _ kind: AkariDemo.AddKind) -> Mesh
  {
    let shape = AkariDemo.PrimitiveShape.named(kind)
    let unit = units(stage), up = yUp(stage)
    return Mesh(valid: !shape.faces.isEmpty,
                points: shape.points.flatMap { p -> [Float] in let q = toStage(p, unit: unit, yUp: up); return [q.x, q.y, q.z] },
                counts: shape.faces.map { Int32($0.count) }, indices: shape.faces.flatMap { $0.map(Int32.init) })
  }
}
