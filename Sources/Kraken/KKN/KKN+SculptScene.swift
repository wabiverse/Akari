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
import AkariRender
import CxxStdlib
import Foundation
import HydraKit
import simd

extension Kraken.Layout
{
  /// the turn that stands a z up world on its feet for the sculpt viewport, which keeps y up
  nonisolated static func sculptUpright(_ stage: UsdStage) -> simd_float4x4
  {
    guard !Kraken.SceneEdit.yUp(stage) else { return matrix_identity_float4x4 }
    return simd_float4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, 0, -1, 0), SIMD4(0, 1, 0, 0), SIMD4(0, 0, 0, 1)))
  }

  /// where the prim at path sits in the sculpt viewport's upright world
  nonisolated static func sculptFrame(_ stage: UsdStage, _ path: String, upright: simd_float4x4) -> simd_float4x4
  {
    let prim = stage.GetPrimAtPath(Sdf.Path(path))
    guard prim.isValid else { return upright }

    var cache = Pixar.UsdGeomXformCache(Pixar.UsdTimeCode.Default())
    let world = Kraken.Layout.matrix(Kraken.SceneEdit.rows(cache.GetLocalToWorldTransform(prim)))
    let columns = (0 ..< 4).map { SIMD4<Float>(world[$0]) }
    return upright * simd_float4x4(columns: (columns[0], columns[1], columns[2], columns[3]))
  }

  /// the layout's view as the sculpt viewport's camera, both orbit a focus point by pitch and yaw
  func sculptCamera(upright: simd_float4x4) -> Kraken.SculptCamera
  {
    let view = hydra.viewCamera
    var camera = Kraken.SculptCamera()
    let focus = upright * SIMD4<Float>(Float(view.focus[0]), Float(view.focus[1]), Float(view.focus[2]), 1)
    camera.target = SIMD3(focus.x, focus.y, focus.z)
    camera.distance = Float(view.distance)
    camera.pitch = -Float(view.rotation[0]) * .pi / 180
    camera.yaw = Float(view.rotation[1]) * .pi / 180

    // the field of view the viewport last drew with, so the two tabs frame the scene the same
    if let drawn = engine.viewportCamera, drawn.projection.columns.1.y > 0
    {
      camera.fov = 2 * atan(1 / drawn.projection.columns.1.y)
    }
    else
    {
      camera.fov = Float(2 * atan(0.5 * Double(view.gfCamera.horizontalAperture) / max(Double(view.gfCamera.focalLength), 1e-3)))
    }

    return camera
  }

  /// hands the sculpt viewport's camera back to the layout's view
  func adoptSculptCamera(_ camera: Kraken.SculptCamera, upright: simd_float4x4)
  {
    let focus = upright.inverse * SIMD4<Float>(camera.target, 1)
    hydra.stopFlick()
    hydra.viewCamera.focus = Pixar.GfVec3d(Double(focus.x), Double(focus.y), Double(focus.z))
    hydra.viewCamera.distance = Double(camera.distance)
    hydra.viewCamera.rotation = Pixar.GfVec3d(-Double(camera.pitch) * 180 / .pi, Double(camera.yaw) * 180 / .pi,
                                              hydra.viewCamera.rotation[2])
  }

  /// the scene's other meshes as flat shaded triangles in the sculpt viewport's world, only those that fit the budget
  nonisolated static func sculptScene(_ stage: UsdStage, excluding path: String?, upright: simd_float4x4,
                                      budget: Int = 4_000_000) -> [Kraken.SculptVertex]
  {
    let time = Pixar.UsdTimeCode.Default()
    var cache = Pixar.UsdGeomXformCache(time)
    var out: [Kraken.SculptVertex] = []
    var triangles = 0

    for prim in stage.traverse() where prim.isA(.gprim)
    {
      let at = prim.GetPath().string
      if let path, at == path || at.hasPrefix(path + "/") { continue }
      guard !Kraken.SceneEdit.invisible(prim, time) else { continue }

      let purpose = Pixar.UsdGeomImageable(prim).ComputePurpose().string
      guard purpose != "guide", purpose != "proxy" else { continue }

      // implicit shapes draw as the mesh they would become, so a plain cube shows like any mesh
      var mesh = Kraken.SceneEdit.mesh(stage, at, time.GetValue())
      if !mesh.valid, let shape = Kraken.SceneEdit.implicitMesh(prim, time.GetValue())
      {
        mesh = Kraken.SceneEdit.Mesh(valid: true)
        mesh.points = shape.points.flatMap { [$0.x, $0.y, $0.z] }
        mesh.counts = shape.counts
        mesh.indices = shape.indices
      }
      guard mesh.valid, !mesh.points.isEmpty else { continue }

      let faces = mesh.counts.reduce(0) { $0 + max(Int($1) - 2, 0) }
      guard triangles + faces <= budget else { continue }
      triangles += faces

      let world = Kraken.Layout.matrix(Kraken.SceneEdit.rows(cache.GetLocalToWorldTransform(prim)))
      let columns = (0 ..< 4).map { SIMD4<Float>(world[$0]) }
      let place = upright * simd_float4x4(columns: (columns[0], columns[1], columns[2], columns[3]))
      let points = stride(from: 0, to: mesh.points.count - 2, by: 3).map
      { i -> SIMD3<Float> in
        let p = place * SIMD4(mesh.points[i], mesh.points[i + 1], mesh.points[i + 2], 1)
        return SIMD3(p.x, p.y, p.z)
      }

      // the color it shows as one flat color, gloss low like a solid view's
      var shown = SIMD3<Float>(repeating: 0.7)
      let primvar = Pixar.UsdGeomPrimvarsAPI(prim).GetPrimvar(Tf.Token("displayColor"))
      var colors = Pixar.VtVec3fArray()
      if primvar.GetInterpolation() == .constant, primvar.Get(&colors, time), colors.size() > 0,
         let c: UnsafePointer<Pixar.GfVec3f> = Overlay.cdata(colors)
      {
        let rgb = UnsafeRawPointer(c).assumingMemoryBound(to: Float.self)
        shown = Kraken.SculptUSD.display(SIMD3(rgb[0], rgb[1], rgb[2]))
      }

      let bytes = SIMD3<UInt32>(simd_clamp(shown * 255, SIMD3(repeating: 0), SIMD3(repeating: 255)).rounded(.toNearestOrAwayFromZero))
      let packed = bytes.x | bytes.y << 8 | bytes.z << 16 | 38 << 24

      var start = 0
      for count in mesh.counts.map(Int.init)
      {
        defer { start += max(count, 0) }
        guard count >= 3, start + count <= mesh.indices.count else { continue }

        for k in 1 ..< count - 1
        {
          let corners = [mesh.indices[start], mesh.indices[start + k], mesh.indices[start + k + 1]].map(Int.init)
          guard corners.allSatisfy({ $0 >= 0 && $0 < points.count }) else { continue }

          let a = points[corners[0]], b = points[corners[1]], c = points[corners[2]]
          let cross = simd_cross(b - a, c - a)
          let length = simd_length(cross)
          guard length > 0 else { continue }

          let n = cross / length
          for p in [a, b, c]
          {
            out.append(Kraken.SculptVertex(x: p.x, y: p.y, z: p.z, nx: n.x, ny: n.y, nz: n.z, color: packed, mask: 0))
          }
        }
      }
    }

    return out
  }

  /// brings the sculpt viewport up to date with the scene's view, the sculpt's placement and the meshes around it
  func refreshSculptScene(takesCamera: Bool)
  {
    let sculpt = sculpt
    let path = sculpt.primPath ?? sculpt.opening

    onStage
    { [weak self] stage in
      let upright = Self.sculptUpright(stage)
      let frame = path.map { Self.sculptFrame(stage, $0, upright: upright) } ?? upright
      DispatchQueue.main.async
      {
        guard let self else { return }
        sculpt.upright = upright
        if sculpt.primPath == path || sculpt.primPath == nil { sculpt.frame = frame }
        if takesCamera
        {
          let camera = self.sculptCamera(upright: upright)
          sculpt.viewCamera = camera
          sculpt.requestedCamera = camera
          sculpt.requestedHeight = self.engine.viewportSize.height > 1 ? Float(self.engine.viewportSize.height) : nil
        }
      }

      let around = Self.sculptScene(stage, excluding: path, upright: upright)
      DispatchQueue.main.async
      {
        sculpt.scene = around
        sculpt.sceneRevision += 1
      }
    }
  }
}
