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
  extension Kraken.LayoutView
  {
    // MARK: toolbar and navigation gizmo

    var navigationCenter: CGPoint
    {
      CGPoint(x: bounds.maxX - 62, y: 108)
    }

    func navigationBalls() -> [(index: Int, sign: Double, point: CGPoint, depth: Double)]
    {
      guard let camera else { return [] }
      var balls: [(index: Int, sign: Double, point: CGPoint, depth: Double)] = []
      for i in 0 ..< 3
      {
        for sign in [1.0, -1.0]
        {
          let v = camera.view * SIMD4(axis(i) * sign, 0)
          balls.append((i, sign, CGPoint(x: navigationCenter.x + CGFloat(v.x) * 38, y: navigationCenter.y - CGFloat(v.y) * 38), v.z))
        }
      }

      return balls.sorted { $0.depth < $1.depth }
    }

    func navigationHit(_ p: CGPoint) -> Bool
    {
      guard hypot(p.x - navigationCenter.x, p.y - navigationCenter.y) < 52 else { return false }
      if let ball = navigationBalls().reversed().first(where: { hypot($0.point.x - p.x, $0.point.y - p.y) < 10 })
      {
        let views: [Hydra.RenderEngine.StandardView] = ball.sign > 0 ? [.right, .back, .top] : [.left, .front, .bottom]
        layout.hydra.setStandardView(views[ball.index])
      }

      return true
    }

    // MARK: light handles

    enum LightHandle: Equatable
    {
      case aim, cone, size(Int)
    }

    private var activeLight: Kraken.Layout.Widget?
    {
      guard modal == nil, layout.mode == .object, let path = layout.active else { return nil }
      return layout.widgets.first { $0.path == path && $0.kind.hasLightHandles }
    }

    /// The space a widget is drawn in, its scale left out where the drawing ignores it.
    private func drawn(_ widget: Kraken.Layout.Widget) -> simd_double4x4
    {
      var world = widget.world
      guard widget.kind.ignoresScale else { return world }
      world.columns.0 /= max(simd_length(world.columns.0), 1e-12)
      world.columns.1 /= max(simd_length(world.columns.1), 1e-12)
      world.columns.2 /= max(simd_length(world.columns.2), 1e-12)
      return world
    }

    private static func apply(_ m: simd_double4x4, _ p: SIMD3<Double>) -> SIMD3<Double>
    {
      let q = m * SIMD4(p, 1)
      return SIMD3(q.x, q.y, q.z)
    }

    private func aimLength(_ widget: Kraken.Layout.Widget) -> Double
    {
      (widget.kind == .rectLight || widget.kind == .diskLight ? 0.6 : 2) * layout.unit
    }

    /// The active light's handles: its aim at the end of its direction, then its size or spot cone.
    private func lightHandles(_ camera: Kraken.ViewCamera) -> [(LightHandle, [CGPoint], SIMD3<Double>)]
    {
      guard let widget = activeLight else { return [] }
      let world = drawn(widget)
      var list: [(LightHandle, [CGPoint], SIMD3<Double>)] = []
      func ring(_ radius: Double, z: Double) -> [CGPoint]
      {
        var segments: [CGPoint] = []
        var last: CGPoint?
        for k in 0 ... 48
        {
          let t = Double(k) / 48 * 2 * .pi
          let q = camera.project(Self.apply(world, SIMD3(cos(t) * radius, sin(t) * radius, z)))
          if let last, let q { segments += [last, q] }
          last = q
        }

        return segments
      }

      if widget.kind != .sphereLight
      {
        let tip = Self.apply(world, SIMD3(0, 0, -aimLength(widget)))
        if let q = camera.project(tip) { list.append((.aim, [q, q], tip)) }
      }

      switch widget.kind
      {
        case .sphereLight:
          list.append((.size(0), ring(max(widget.size, 0.05 * layout.unit), z: 0), .zero))
        case .spotLight:
          let length = 2 * layout.unit
          list.append((.cone, ring(length * tan(min(widget.angle, 89) * .pi / 180), z: -length), .zero))
        case .rectLight:
          let w = widget.size / 2, h = widget.size2 / 2
          for (i, corner) in [SIMD3(-w, -h, 0), SIMD3(w, -h, 0), SIMD3(w, h, 0), SIMD3(-w, h, 0)].enumerated()
          {
            let p = Self.apply(world, corner)
            if let q = camera.project(p) { list.append((.size(i), [q, q], p)) }
          }
        case .diskLight:
          list.append((.size(0), ring(widget.size, z: 0), .zero))
        default:
          break
      }

      return list
    }

    func lightHandle(at p: CGPoint) -> LightHandle?
    {
      guard let camera else { return nil }
      var best: (LightHandle, CGFloat)?
      for (handle, segments, _) in lightHandles(camera)
      {
        let d = Self.distance(p, segments)
        if d < 8, d < (best?.1 ?? .infinity) { best = (handle, d) }
      }

      return best?.0
    }

    func beginLightDrag(_ handle: LightHandle)
    {
      guard let widget = activeLight, let placement = layout.placements[widget.path], let camera else { return }
      let from = lightHandles(camera).first { $0.0 == handle }?.2 ?? .zero
      layout.checkpoint()
      layout.dragging = .light
      lightDrag = (handle, widget, placement, from)
    }

    func updateLightDrag()
    {
      guard let drag = lightDrag, let camera else { return }
      let widget = drag.widget
      let world = drawn(widget)
      let origin = SIMD3(world.columns.3.x, world.columns.3.y, world.columns.3.z)
      let axis = simd_normalize(SIMD3(world.columns.2.x, world.columns.2.y, world.columns.2.z))
      let ray = camera.ray(mouse)
      switch drag.handle
      {
        case .aim:
          guard let target = Self.hit(drag.from, camera.forward, ray), simd_distance(target, origin) > 1e-9 else { return }
          let z = -simd_normalize(target - origin)
          let m = drag.placement.world
          let scale = SIMD3(simd_length(m.columns.0), simd_length(m.columns.1), simd_length(m.columns.2))
          var x = simd_normalize(SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z))
          x -= z * simd_dot(x, z)
          if simd_length(x) < 1e-6 { x = simd_cross(layout.up, z) }
          x = simd_normalize(x)
          let y = simd_cross(z, x)
          let aimed = simd_double4x4(columns: (SIMD4(x * scale.x, 0), SIMD4(y * scale.y, 0), SIMD4(z * scale.z, 0),
                                               SIMD4(origin, 1)))
          layout.setLocals([widget.path: drag.placement.parent.inverse * aimed])
          layout.status = "Aim"
        case .cone:
          let length = 2 * layout.unit
          let center = origin - axis * length
          guard let hit = Self.hit(center, axis, ray) else { return }
          let angle = min(max(atan(simd_distance(hit, center) / length) * 180 / .pi, 1), 89)
          layout.setLight(widget.path, size: widget.size, size2: widget.size2, angle: angle)
          layout.status = String(format: "Spot Size: %.1f°", angle * 2)
        case .size:
          guard let hit = Self.hit(origin, widget.kind == .sphereLight ? -camera.forward : axis, ray) else { return }
          if widget.kind == .rectLight
          {
            let local = Self.apply(widget.world.inverse, hit)
            let w = max(abs(local.x) * 2, 1e-4 * layout.unit), h = max(abs(local.y) * 2, 1e-4 * layout.unit)
            layout.setLight(widget.path, size: w, size2: h, angle: 0)
            layout.status = String(format: "Size: %.3g m × %.3g m", w / layout.unit, h / layout.unit)
          }
          else
          {
            let local = Self.apply((widget.kind == .diskLight ? widget.world : world).inverse, hit)
            let r = max(widget.kind == .diskLight ? simd_length(SIMD2(local.x, local.y)) : simd_distance(hit, origin), 1e-4 * layout.unit)
            layout.setLight(widget.path, size: r, size2: widget.size2, angle: 0)
            layout.status = String(format: "Radius: %.3g m", r / layout.unit)
          }
      }
    }

    func drawLightHandles(_ camera: Kraken.ViewCamera)
    {
      let gold = NSColor(red: 1, green: 0.82, blue: 0.2, alpha: 1)
      for (handle, segments, _) in lightHandles(camera)
      {
        let hot = handle == lightHover || handle == lightDrag?.handle
        let color = hot ? NSColor.white : gold
        if segments.count == 2, segments[0] == segments[1]
        {
          if case .size = handle
          {
            color.setFill()
            CGRect(x: segments[0].x - 4, y: segments[0].y - 4, width: 8, height: 8).fill()
          }
          else
          {
            dot(segments[0], hot ? 7 : 6, color, outline: .black)
          }
        }
        else
        {
          stroke(segments, color, hot ? 2.5 : 1.5)
        }
      }
    }

    // MARK: gizmo

    private func gizmoLength(_ camera: Kraken.ViewCamera, _ pivot: SIMD3<Double>) -> Double
    {
      86 * camera.pixelSize(at: pivot)
    }

    func ring(_ camera: Kraken.ViewCamera, _ c: SIMD3<Double>, _ u: SIMD3<Double>, _ v: SIMD3<Double>,
                      _ radius: Double) -> [CGPoint]
    {
      var segments: [CGPoint] = []
      var last: CGPoint?
      for k in 0 ... 48
      {
        let t = Double(k) / 48 * 2 * .pi
        let q = camera.project(c + (u * cos(t) + v * sin(t)) * radius)
        if let last, let q { segments += [last, q] }
        last = q
      }

      return segments
    }

    func circle(_ c: CGPoint, _ radius: CGFloat) -> [CGPoint]
    {
      var segments: [CGPoint] = []
      for k in 0 ..< 32
      {
        let a = CGFloat(k) / 32 * 2 * .pi, b = CGFloat(k + 1) / 32 * 2 * .pi
        segments += [CGPoint(x: c.x + cos(a) * radius, y: c.y + sin(a) * radius),
                     CGPoint(x: c.x + cos(b) * radius, y: c.y + sin(b) * radius)]
      }

      return segments
    }

    /// The active tool's handles around the selection, as segments on screen.
    func handles() -> [(Handle, [CGPoint], NSColor)]
    {
      guard modal == nil, let camera, let pivot = layout.pivot,
            [.move, .rotate, .scale, .transform].contains(layout.tool),
            let center = camera.project(pivot)
      else { return [] }
      let length = gizmoLength(camera, pivot)
      var list: [(Handle, [CGPoint], NSColor)] = []
      let tool = layout.tool
      for i in 0 ..< 3
      {
        let a = axis(i), color = Self.axisColors[i]
        if tool == .move || tool == .transform,
           let s = camera.project(pivot + a * length * 0.2), let e = camera.project(pivot + a * length)
        {
          list.append((.move(i), [s, e], color))
          let u = axis((i + 1) % 3), v = axis((i + 2) % 3)
          let corners = [u * 0.25 + v * 0.25, u * 0.4 + v * 0.25, u * 0.4 + v * 0.4, u * 0.25 + v * 0.4]
            .compactMap { camera.project(pivot + $0 * length) }
          if corners.count == 4
          {
            list.append((.plane(i), [corners[0], corners[1], corners[1], corners[2], corners[2], corners[3],
                                     corners[3], corners[0]], color))
          }
        }

        if tool == .rotate || tool == .transform
        {
          list.append((.rotate(i), ring(camera, pivot, axis((i + 1) % 3), axis((i + 2) % 3), length * 0.8), color))
        }

        if tool == .scale || tool == .transform,
           let e = camera.project(pivot + a * length * (tool == .transform ? 0.6 : 1))
        {
          let r: CGFloat = 4
          let s = camera.project(pivot) ?? center
          list.append((.scale(i), [s, e, CGPoint(x: e.x - r, y: e.y - r), CGPoint(x: e.x + r, y: e.y - r),
                                   CGPoint(x: e.x + r, y: e.y - r), CGPoint(x: e.x + r, y: e.y + r),
                                   CGPoint(x: e.x + r, y: e.y + r), CGPoint(x: e.x - r, y: e.y + r),
                                   CGPoint(x: e.x - r, y: e.y + r), CGPoint(x: e.x - r, y: e.y - r)], color))
        }
      }

      switch tool
      {
        case .move: list.append((.free, circle(center, 10), .white))
        case .rotate: list.append((.view, circle(center, CGFloat(length * 0.95 / camera.pixelSize(at: pivot))), .white))
        case .scale: list.append((.uniform, circle(center, CGFloat(length * 1.05 / camera.pixelSize(at: pivot))), .white))
        case .transform: list.append((.free, circle(center, 10), .white))
        default: break
      }

      return list
    }

    func handle(at p: CGPoint) -> Handle?
    {
      var best: (Handle, CGFloat)?
      for (handle, segments, _) in handles()
      {
        let d = Self.distance(p, segments)
        if d < 7, d < (best?.1 ?? .infinity) { best = (handle, d) }
      }

      return best?.0
    }
  }
#endif
