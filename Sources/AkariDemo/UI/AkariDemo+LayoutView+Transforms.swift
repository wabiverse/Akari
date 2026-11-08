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
import HdAkari
import HydraKit
import simd
import SwiftCrossUI
#if os(macOS)
  import AppKit
#endif

#if os(macOS)
  extension AkariDemo.LayoutView
  {
    func begin(_ kind: Modal.Kind, axis: Int? = nil, plane: Bool = false, along: SIMD3<Double>? = nil,
               confirmOnRelease: Bool = false)
    {
      guard let pivot = layout.pivot else
      {
        layout.status = "Nothing selected"
        return
      }

      var next = Modal(kind: kind, axis: axis, plane: plane, along: along,
                       start: bounds.contains(mouse) ? mouse : CGPoint(x: bounds.midX, y: bounds.midY),
                       pivot: pivot, confirmOnRelease: confirmOnRelease)
      if layout.mode == .edit
      {
        guard let mesh = layout.mesh, !mesh.verts.isEmpty || kind == .inset else { return }
        next.mesh = mesh
      }
      else
      {
        for path in layout.selection
        {
          if let placement = layout.placements[path] { next.originals[path] = placement }
        }

        guard !next.originals.isEmpty else { return }
      }

      layout.checkpoint()
      layout.dragging = .modal
      modal = next
      update()
    }

    func begin(_ handle: Handle)
    {
      switch handle
      {
        case let .move(i): begin(.translate, axis: i, confirmOnRelease: true)
        case let .plane(i): begin(.translate, axis: i, plane: true, confirmOnRelease: true)
        case .free: begin(.translate, confirmOnRelease: true)
        case let .rotate(i): begin(.rotate, axis: i, confirmOnRelease: true)
        case .view: begin(.rotate, confirmOnRelease: true)
        case let .scale(i): begin(.scale, axis: i, confirmOnRelease: true)
        case .uniform: begin(.scale, confirmOnRelease: true)
      }
    }

    func extrude()
    {
      var direction: SIMD3<Float>?
      layout.editMesh { mesh, _ in direction = mesh.extrude() }
      let world = layout.meshWorld
      let along = direction.map
      { d -> SIMD3<Double> in
        let v = world * SIMD4(SIMD3<Double>(d), 0)
        return simd_normalize(SIMD3(v.x, v.y, v.z))
      }

      begin(.translate, along: along)
    }

    func duplicate()
    {
      if layout.mode == .edit
      {
        var made = false
        layout.editMesh { mesh, _ in made = mesh.duplicate() }
        if made { begin(.translate) }
      }
      else
      {
        layout.duplicateSelected { [weak self] in self?.begin(.translate) }
      }
    }

    private static func closest(on base: SIMD3<Double>, _ axis: SIMD3<Double>,
                                to ray: (origin: SIMD3<Double>, direction: SIMD3<Double>)) -> SIMD3<Double>
    {
      let w = base - ray.origin
      let a = simd_dot(axis, axis), b = simd_dot(axis, ray.direction), c = simd_dot(ray.direction, ray.direction)
      let d = simd_dot(axis, w), e = simd_dot(ray.direction, w)
      let denominator = a * c - b * b
      guard abs(denominator) > 1e-12 else { return base }
      return base + axis * ((b * e - c * d) / denominator)
    }

    static func hit(_ base: SIMD3<Double>, _ normal: SIMD3<Double>,
                            _ ray: (origin: SIMD3<Double>, direction: SIMD3<Double>)) -> SIMD3<Double>?
    {
      let denominator = simd_dot(normal, ray.direction)
      guard abs(denominator) > 1e-9 else { return nil }
      return ray.origin + ray.direction * (simd_dot(normal, base - ray.origin) / denominator)
    }

    private static func translation(_ t: SIMD3<Double>) -> simd_double4x4
    {
      var m = matrix_identity_double4x4
      m.columns.3 = SIMD4(t, 1)
      return m
    }

    private static func around(_ c: SIMD3<Double>, _ m: simd_double3x3) -> simd_double4x4
    {
      let linear = simd_double4x4(columns: (SIMD4(m.columns.0, 0), SIMD4(m.columns.1, 0), SIMD4(m.columns.2, 0),
                                            SIMD4(0, 0, 0, 1)))
      return translation(c) * linear * translation(-c)
    }

    private static func outer(_ a: SIMD3<Double>) -> simd_double3x3
    {
      simd_double3x3(columns: (a * a.x, a * a.y, a * a.z))
    }

    private static func screenAngle(_ p: CGPoint, around c: CGPoint) -> Double
    {
      atan2(-Double(p.y - c.y), Double(p.x - c.x))
    }

    /// The world space change the modal's pointer and typed number make, and what the header says about it.
    private func delta(_ modal: Modal, _ camera: AkariDemo.ViewCamera) -> (simd_double4x4, String)
    {
      let numeric = Double(modal.numeric == "-" ? "" : modal.numeric)
      let snapping = NSEvent.modifierFlags.contains(.control)
      let c = modal.pivot
      let center = camera.project(c) ?? CGPoint(x: bounds.midX, y: bounds.midY)
      let axis = axisVector(modal)
      let names = ["X", "Y", "Z"]
      let along = modal.along != nil ? " along normal"
        : modal.axis.map { " \(modal.plane ? "locking" : "along") \(modal.local ? "local" : "global") \(names[$0])" } ?? ""
      switch modal.kind
      {
        case .translate:
          var move = SIMD3<Double>.zero
          if let numeric
          {
            move = (axis ?? self.axis(0)) * numeric * layout.unit
          }
          else if let axis, !modal.plane
          {
            move = Self.closest(on: c, axis, to: camera.ray(mouse)) - Self.closest(on: c, axis, to: camera.ray(modal.start))
          }
          else
          {
            let normal = modal.plane ? (axis ?? camera.forward) : camera.forward
            if let a = Self.hit(c, normal, camera.ray(modal.start)), let b = Self.hit(c, normal, camera.ray(mouse))
            {
              move = b - a
            }
          }

          if snapping
          {
            let unit = layout.unit
            if let axis, !modal.plane { move = axis * (simd_dot(move, axis) / unit).rounded() * unit }
            else { move = (move / unit).rounded(.toNearestOrAwayFromZero) * unit }
          }

          let meters = move / layout.unit
          let text = axis != nil && !modal.plane
            ? String(format: "D: %.4g m", simd_dot(meters, axis!))
            : String(format: "Dx %.4g m  Dy %.4g m  Dz %.4g m", simd_dot(meters, self.axis(0)),
                     simd_dot(meters, self.axis(1)), simd_dot(meters, self.axis(2)))
          return (Self.translation(move), text + along + (modal.numeric.isEmpty ? "" : "  [\(modal.numeric)]"))
        case .rotate:
          var angle = Self.screenAngle(mouse, around: center) - Self.screenAngle(modal.start, around: center)
          let k = axis.flatMap { modal.plane ? nil : $0 } ?? camera.forward
          if simd_dot(k, camera.forward) > 0 { angle = -angle }
          if let numeric { angle = numeric * .pi / 180 }
          if snapping { angle = (angle / (5 * .pi / 180)).rounded() * 5 * .pi / 180 }
          let rotation = simd_double3x3(simd_quatd(angle: angle, axis: simd_normalize(k)))
          return (Self.around(c, rotation), String(format: "Rot: %.4g°", angle * 180 / .pi) + along)
        case .scale:
          let start = max(hypot(modal.start.x - center.x, modal.start.y - center.y), 5)
          var factor = numeric ?? Double(hypot(mouse.x - center.x, mouse.y - center.y) / start)
          if snapping { factor = (factor * 10).rounded() / 10 }
          let identity = matrix_identity_double3x3
          let m: simd_double3x3
          if let axis
          {
            m = modal.plane ? identity * factor + Self.outer(axis) * (1 - factor) : identity + Self.outer(axis) * (factor - 1)
          }
          else
          {
            m = identity * factor
          }

          return (Self.around(c, m), String(format: "Scale: %.4g", factor) + along)
        case .inset:
          let start = max(hypot(modal.start.x - center.x, modal.start.y - center.y), 5)
          let amount = numeric ?? max(0, 1 - Double(hypot(mouse.x - center.x, mouse.y - center.y) / start))
          return (matrix_identity_double4x4, String(format: "Thickness: %.3g", amount))
      }
    }

    func update()
    {
      guard let modal, let camera else { return }
      let (d, text) = delta(modal, camera)
      layout.status = text
      if modal.kind == .inset, var mesh = modal.mesh
      {
        let center = camera.project(modal.pivot) ?? CGPoint(x: bounds.midX, y: bounds.midY)
        let start = max(hypot(modal.start.x - center.x, modal.start.y - center.y), 5)
        let amount = Double(modal.numeric).map { $0 } ?? max(0, 1 - Double(hypot(mouse.x - center.x, mouse.y - center.y) / start))
        mesh.inset(Float(amount))
        layout.mesh = mesh
        layout.writeMesh()
        return
      }

      if var mesh = modal.mesh
      {
        let world = layout.meshWorld
        let m = world.inverse * d * world
        for v in mesh.verts
        {
          let p = m * SIMD4(SIMD3<Double>(mesh.points[v]), 1)
          mesh.points[v] = SIMD3<Float>(SIMD3(p.x, p.y, p.z))
        }

        layout.mesh = mesh
        layout.writeMesh()
      }
      else
      {
        layout.setLocals(modal.originals.mapValues { $0.parent.inverse * d * $0.world })
      }
    }

    func confirm()
    {
      modal = nil
      layout.dragging = nil
      layout.status = ""
      layout.refresh()
    }

    func cancel()
    {
      guard let modal else { return }
      if let mesh = modal.mesh
      {
        layout.mesh = mesh
        layout.writeMesh()
      }
      else
      {
        layout.setLocals(modal.originals.mapValues(\.local))
      }

      self.modal = nil
      layout.dragging = nil
      layout.status = ""
    }
  }
#endif
