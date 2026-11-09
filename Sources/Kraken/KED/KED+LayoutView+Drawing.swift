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
    func stroke(_ segments: [CGPoint], _ color: NSColor, _ width: CGFloat, dash: [CGFloat] = [])
    {
      guard segments.count >= 2 else { return }
      let path = NSBezierPath()
      var i = 0
      while i + 1 < segments.count
      {
        path.move(to: segments[i])
        path.line(to: segments[i + 1])
        i += 2
      }

      path.lineWidth = width
      path.lineCapStyle = .round
      if !dash.isEmpty { path.setLineDash(dash, count: dash.count, phase: 0) }
      color.setStroke()
      path.stroke()
    }

    func dot(_ p: CGPoint, _ radius: CGFloat, _ color: NSColor, outline: NSColor? = nil)
    {
      let path = NSBezierPath(ovalIn: CGRect(x: p.x - radius, y: p.y - radius, width: radius * 2, height: radius * 2))
      color.setFill()
      path.fill()
      if let outline
      {
        outline.setStroke()
        path.lineWidth = 1
        path.stroke()
      }
    }

    func text(_ string: String, at p: CGPoint, size: CGFloat = 11, color: NSColor = .white,
                      centered: Bool = false, shadow: Bool = true)
    {
      let attributes: [NSAttributedString.Key: Any] = [.font: NSFont.systemFont(ofSize: size, weight: .medium),
                                                       .foregroundColor: color]
      let s = string as NSString
      let width = centered ? s.size(withAttributes: attributes).width : 0
      if shadow
      {
        s.draw(at: CGPoint(x: p.x - width / 2 + 1, y: p.y + 1),
               withAttributes: [.font: attributes[.font]!, .foregroundColor: NSColor(white: 0, alpha: 0.7)])
      }

      s.draw(at: CGPoint(x: p.x - width / 2, y: p.y), withAttributes: attributes)
    }

    override func draw(_: NSRect)
    {
      guard let camera else { return }
      if layout.overlays
      {
        drawWidgets(camera)
        if layout.mode == .edit { drawEditMesh(camera) } else { drawOrigins(camera) }
        drawCursor(camera)
      }

      if layout.overlays { drawLightHandles(camera) }
      for (handle, segments, color) in handles()
      {
        let hovered = handle == hover
        stroke(segments, hovered ? NSColor(white: 1, alpha: 1) : color, hovered ? 3 : 2)
        if case .move = handle, segments.count == 2 { arrowHead(segments[0], segments[1], hovered ? .white : color) }
      }

      if let modal, let axis = axisVector(modal), modal.kind != .inset
      {
        let color = modal.along != nil ? Self.activeColor : Self.axisColors[modal.axis ?? 0]
        let length = 1e4 * layout.unit
        var segments: [CGPoint] = []
        var last: CGPoint?
        for k in -40 ... 40
        {
          let q = camera.project(modal.pivot + axis * length * Double(k) / 40)
          if let last, let q { segments += [last, q] }
          last = q
        }

        if !modal.plane { stroke(segments, color.withAlphaComponent(0.8), 1) }
      }

      if let loopCut, loopCutArmed, let mesh = layout.mesh
      {
        let world = layout.meshWorld
        let points = loopCut.ring.compactMap
        { e -> CGPoint? in
          let m = world * SIMD4(SIMD3<Double>((mesh.points[e.a] + mesh.points[e.b]) * 0.5), 1)
          return camera.project(SIMD3(m.x, m.y, m.z))
        }

        var segments: [CGPoint] = []
        for i in points.indices.dropLast() { segments += [points[i], points[i + 1]] }
        if points.count > 2, let first = points.first, let last = points.last, closedRing(loopCut.ring, mesh)
        {
          segments += [last, first]
        }

        stroke(segments, NSColor(red: 1, green: 0.9, blue: 0.1, alpha: 1), 2)
      }

      if let box
      {
        stroke([box.origin, CGPoint(x: box.maxX, y: box.minY), CGPoint(x: box.maxX, y: box.minY),
                CGPoint(x: box.maxX, y: box.maxY), CGPoint(x: box.maxX, y: box.maxY),
                CGPoint(x: box.minX, y: box.maxY), CGPoint(x: box.minX, y: box.maxY), box.origin],
               NSColor(white: 1, alpha: 0.9), 1, dash: [4, 3])
      }

      drawNavigation(camera)
      drawStatus()
    }

    private func closedRing(_ ring: [Kraken.Edge], _ mesh: Kraken.EditMesh) -> Bool
    {
      guard let first = ring.first, let last = ring.last, ring.count > 2 else { return false }
      return mesh.faces.contains
      { face in
        face.count == 4 && Kraken.EditMesh.edges(of: face).contains(first) && Kraken.EditMesh.edges(of: face).contains(last)
      }
    }

    private func arrowHead(_ from: CGPoint, _ to: CGPoint, _ color: NSColor)
    {
      let dx = to.x - from.x, dy = to.y - from.y
      let length = max(hypot(dx, dy), 1e-3)
      let ux = dx / length, uy = dy / length
      let path = NSBezierPath()
      path.move(to: CGPoint(x: to.x + ux * 9, y: to.y + uy * 9))
      path.line(to: CGPoint(x: to.x - uy * 4.5, y: to.y + ux * 4.5))
      path.line(to: CGPoint(x: to.x + uy * 4.5, y: to.y - ux * 4.5))
      path.close()
      color.setFill()
      path.fill()
    }

    private func drawCursor(_ camera: Kraken.ViewCamera)
    {
      guard let c = camera.project(layout.cursor) else { return }
      for k in 0 ..< 8
      {
        let a = CGFloat(k) / 8 * 2 * .pi
        let path = NSBezierPath()
        path.appendArc(withCenter: c, radius: 10, startAngle: a * 180 / .pi, endAngle: (a + .pi / 4) * 180 / .pi)
        path.lineWidth = 2
        (k % 2 == 0 ? NSColor(red: 1, green: 0.1, blue: 0.1, alpha: 1) : NSColor.white).setStroke()
        path.stroke()
      }

      stroke([CGPoint(x: c.x - 18, y: c.y), CGPoint(x: c.x - 5, y: c.y), CGPoint(x: c.x + 5, y: c.y),
              CGPoint(x: c.x + 18, y: c.y), CGPoint(x: c.x, y: c.y - 18), CGPoint(x: c.x, y: c.y - 5),
              CGPoint(x: c.x, y: c.y + 5), CGPoint(x: c.x, y: c.y + 18)], .black, 1)
    }

    private func drawOrigins(_ camera: Kraken.ViewCamera)
    {
      for path in layout.selection
      {
        guard let world = layout.placements[path]?.world,
              let p = camera.project(SIMD3(world.columns.3.x, world.columns.3.y, world.columns.3.z))
        else { continue }
        dot(p, 3.5, path == layout.active ? Self.activeColor : Self.selected, outline: .black)
      }
    }

    /// The camera, light and empty drawings, in each one's own space.
    private func widgetLines(_ widget: Kraken.Layout.Widget) -> [SIMD3<Double>]
    {
      let u = layout.unit
      var lines: [SIMD3<Double>] = []
      func circle(_ radius: Double, z: Double = 0, count: Int = 24)
      {
        for k in 0 ..< count
        {
          let a = Double(k) / Double(count) * 2 * .pi, b = Double(k + 1) / Double(count) * 2 * .pi
          lines += [SIMD3(cos(a) * radius, sin(a) * radius, z), SIMD3(cos(b) * radius, sin(b) * radius, z)]
        }
      }

      switch widget.kind
      {
        case .camera:
          let depth = u
          let w = depth * 0.5 * widget.horizontalAperture / max(widget.focalLength, 1e-3)
          let h = w * widget.verticalAperture / max(widget.horizontalAperture, 1e-3)
          let corners = [SIMD3(-w, -h, -depth), SIMD3(w, -h, -depth), SIMD3(w, h, -depth), SIMD3(-w, h, -depth)]
          for i in 0 ..< 4
          {
            lines += [.zero, corners[i], corners[i], corners[(i + 1) % 4]]
          }

          lines += [SIMD3(-w * 0.7, h * 1.1, -depth), SIMD3(w * 0.7, h * 1.1, -depth),
                    SIMD3(w * 0.7, h * 1.1, -depth), SIMD3(0, h * 1.1 + w * 0.6, -depth),
                    SIMD3(0, h * 1.1 + w * 0.6, -depth), SIMD3(-w * 0.7, h * 1.1, -depth)]
        case .distantLight:
          for k in 0 ..< 8
          {
            let a = Double(k) / 8 * 2 * .pi
            lines += [SIMD3(cos(a), sin(a), 0) * 0.18 * u, SIMD3(cos(a), sin(a), 0) * 0.3 * u]
          }

          circle(0.12 * u)
          lines += [.zero, SIMD3(0, 0, -2 * u)]
        case .spotLight:
          let length = 2 * u
          let radius = length * tan(min(widget.angle, 89) * .pi / 180)
          circle(radius, z: -length, count: 32)
          for k in 0 ..< 4
          {
            let a = Double(k) / 4 * 2 * .pi
            lines += [.zero, SIMD3(cos(a) * radius, sin(a) * radius, -length)]
          }

          circle(0.1 * u)
        case .sphereLight:
          circle(max(widget.size, 0.05 * u))
          circle(0.1 * u)
          lines += [.zero, SIMD3(0, 0, -0.01 * u)]
        case .rectLight:
          let w = widget.size / 2, h = widget.size2 / 2
          lines += [SIMD3(-w, -h, 0), SIMD3(w, -h, 0), SIMD3(w, -h, 0), SIMD3(w, h, 0), SIMD3(w, h, 0),
                    SIMD3(-w, h, 0), SIMD3(-w, h, 0), SIMD3(-w, -h, 0), .zero, SIMD3(0, 0, -0.6 * u)]
        case .diskLight:
          circle(widget.size)
          lines += [.zero, SIMD3(0, 0, -0.6 * u)]
        case .cylinderLight:
          let half = widget.size / 2
          lines += [SIMD3(-half, 0, 0), SIMD3(half, 0, 0)]
          for x in [-half, half]
          {
            for k in 0 ..< 16
            {
              let a = Double(k) / 16 * 2 * .pi, b = Double(k + 1) / 16 * 2 * .pi
              lines += [SIMD3(x, cos(a) * widget.size2, sin(a) * widget.size2),
                        SIMD3(x, cos(b) * widget.size2, sin(b) * widget.size2)]
            }
          }
        case .other:
          lines += [SIMD3(-u, 0, 0), SIMD3(u, 0, 0), SIMD3(0, -u, 0), SIMD3(0, u, 0), SIMD3(0, 0, -u), SIMD3(0, 0, u)]
        default:
          break
      }

      return lines
    }

    private func drawWidgets(_ camera: Kraken.ViewCamera)
    {
      var hits: [(path: String, points: [CGPoint])] = []
      let selected = Set(layout.selection)
      for widget in layout.widgets where widget.kind != .domeLight
      {
        var world = widget.world
        let origin = SIMD3(world.columns.3.x, world.columns.3.y, world.columns.3.z)
        if widget.kind == .camera, simd_distance(origin, camera.eye) < 1e-3 * layout.unit { continue }
        if widget.kind.ignoresScale
        {
          let scale = SIMD3(simd_length(world.columns.0), simd_length(world.columns.1), simd_length(world.columns.2))
          world.columns.0 /= max(scale.x, 1e-12)
          world.columns.1 /= max(scale.y, 1e-12)
          world.columns.2 /= max(scale.z, 1e-12)
        }

        var segments: [CGPoint] = []
        let lines = widgetLines(widget)
        var i = 0
        while i + 1 < lines.count
        {
          let a = world * SIMD4(lines[i], 1), b = world * SIMD4(lines[i + 1], 1)
          if let p = camera.project(SIMD3(a.x, a.y, a.z)), let q = camera.project(SIMD3(b.x, b.y, b.z))
          {
            segments += [p, q]
          }

          i += 2
        }

        if let origin = camera.project(SIMD3(world.columns.3.x, world.columns.3.y, world.columns.3.z))
        {
          segments += [origin, origin]
        }

        let color = widget.path == layout.active && selected.contains(widget.path) ? Self.activeColor
          : selected.contains(widget.path) ? Self.selected : Self.wire
        stroke(segments, color, selected.contains(widget.path) ? 1.6 : 1.2)
        hits.append((widget.path, segments))
      }

      widgetHits = hits
    }

    private func drawEditMesh(_ camera: Kraken.ViewCamera)
    {
      guard let mesh = layout.mesh else { return }
      let view = EditView(mesh, layout.meshWorld, camera, xray: layout.xray)
      let selectedFaces = mesh.mode == .face ? mesh.selectedFaces
        : Set(mesh.faces.indices.filter { mesh.faces[$0].allSatisfy(mesh.verts.contains) })
      Self.selected.withAlphaComponent(0.18).setFill()
      for f in selectedFaces where f < mesh.faces.count && view.front[f]
      {
        let polygon = mesh.faces[f].compactMap { view.screen[$0] }
        guard polygon.count == mesh.faces[f].count, let first = polygon.first else { continue }
        let path = NSBezierPath()
        path.move(to: first)
        polygon.dropFirst().forEach(path.line)
        path.close()
        path.fill()
      }

      var plain: [CGPoint] = [], chosen: [CGPoint] = []
      for e in mesh.allEdges where view.sees(e)
      {
        guard let a = view.screen[e.a], let b = view.screen[e.b] else { continue }
        if mesh.edges.contains(e) { chosen += [a, b] } else { plain += [a, b] }
      }

      stroke(plain, Self.wire, 1)
      stroke(chosen, Self.selected, 2)
      switch mesh.mode
      {
        case .vertex:
          for v in mesh.points.indices where view.visible[v]
          {
            guard let q = view.screen[v] else { continue }
            dot(q, mesh.verts.contains(v) ? 3 : 2.5, mesh.verts.contains(v) ? Self.selected : .black)
          }
        case .face:
          for f in mesh.faces.indices where view.front[f]
          {
            guard let q = camera.project(view.centers[f]) else { continue }
            let on = selectedFaces.contains(f)
            (on ? Self.selected : NSColor.black).setFill()
            CGRect(x: q.x - 2, y: q.y - 2, width: 4, height: 4).fill()
          }
        case .edge:
          break
      }
    }

    private func drawNavigation(_ camera: Kraken.ViewCamera)
    {
      let c = navigationCenter
      if hypot(mouse.x - c.x, mouse.y - c.y) < 52
      {
        dot(c, 50, NSColor(white: 1, alpha: 0.08))
      }

      let names = ["X", "Y", "Z"]
      for ball in navigationBalls()
      {
        let color = Self.axisColors[ball.index]
        if ball.sign > 0
        {
          stroke([c, ball.point], color, 2)
          dot(ball.point, 9, color)
          text(names[ball.index], at: CGPoint(x: ball.point.x, y: ball.point.y - 7), size: 10, color: .black,
               centered: true, shadow: false)
        }
        else
        {
          dot(ball.point, 8, color.withAlphaComponent(0.35), outline: color)
        }
      }
    }

    private func drawStatus()
    {
      if layout.status != shownStatus
      {
        shownStatus = layout.status
        statusSince = Date()
      }

      if modal != nil
      {
        text(layout.status, at: CGPoint(x: bounds.midX, y: 10), size: 12, centered: true)
      }
      else if !shownStatus.isEmpty, Date().timeIntervalSince(statusSince) < 3
      {
        text(shownStatus, at: CGPoint(x: 12, y: bounds.maxY - 40), size: 12)
      }

      let mode = layout.mode == .edit ? "Edit Mode" : "Object Mode"
      let name = layout.active.map { " | " + ($0.split(separator: "/").last.map(String.init) ?? $0) } ?? ""
      text(mode + name, at: CGPoint(x: 12, y: bounds.maxY - 22), size: 11, color: NSColor(white: 0.9, alpha: 1))
    }
  }
#endif
