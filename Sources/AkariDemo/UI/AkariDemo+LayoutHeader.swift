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
import SwiftCrossUI
#if os(macOS)
  import AppKit
  import AppKitBackend
#endif

extension AkariDemo
{
  /// The 3D viewport's header: the mode, the View, Select, Add and Object menus, and the shading buttons.
  struct LayoutHeader
  {
    let layout: AkariDemo.Layout
  }

  #if os(macOS)
    final class LayoutHeaderView: NSView
    {
      static let height: CGFloat = 26

      private let layout: Layout
      private var timer: Timer?
      private var targets: [(CGRect, () -> Void)] = []
      private var hovered: CGPoint?
      private var tracking: NSTrackingArea?
      private var askedLayers = false

      private static let background = NSColor(white: 0.19, alpha: 1)
      private static let button = NSColor(white: 0.27, alpha: 1)
      private static let ink = NSColor(white: 0.88, alpha: 1)
      private static let accent = NSColor(red: 0.278, green: 0.447, blue: 0.702, alpha: 1)
      private static let font = NSFont.systemFont(ofSize: 11)

      init(layout: Layout)
      {
        self.layout = layout
        super.init(frame: .zero)
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
          MainActor.assumeIsolated { self?.needsDisplay = true }
        }

        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
      }

      @available(*, unavailable)
      required init?(coder _: NSCoder)
      {
        fatalError("init(coder:) is not supported")
      }

      override var isFlipped: Bool
      {
        true
      }

      func stop()
      {
        timer?.invalidate()
        timer = nil
      }

      override func updateTrackingAreas()
      {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
      }

      override func mouseMoved(with event: NSEvent)
      {
        hovered = convert(event.locationInWindow, from: nil)
        needsDisplay = true
      }

      override func mouseExited(with _: NSEvent)
      {
        hovered = nil
        needsDisplay = true
      }

      override func mouseDown(with event: NSEvent)
      {
        let p = convert(event.locationInWindow, from: nil)
        targets.first { $0.0.contains(p) }?.1()
        needsDisplay = true
      }

      private func pop(_ kind: LayoutView.Menu, under r: CGRect)
      {
        guard let viewport = layout.viewport else { return }
        MenuPanel.show(viewport.menu(kind), at: CGPoint(x: r.minX + 12, y: r.maxY + 12), in: self)
      }

      private func label(_ title: String, in r: CGRect, color: NSColor = ink)
      {
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font, .foregroundColor: color]
        let size = (title as NSString).size(withAttributes: attributes)
        (title as NSString).draw(at: CGPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2),
                                 withAttributes: attributes)
      }

      private func width(_ title: String) -> CGFloat
      {
        (title as NSString).size(withAttributes: [.font: Self.font]).width
      }

      private func fill(_ r: CGRect, _ color: NSColor, radius: CGFloat = 4)
      {
        color.setFill()
        NSBezierPath(roundedRect: r, xRadius: radius, yRadius: radius).fill()
      }

      private func isHovered(_ r: CGRect) -> Bool
      {
        hovered.map(r.contains) ?? false
      }

      override func draw(_: NSRect)
      {
        Self.background.setFill()
        bounds.fill()
        targets = []
        let y: CGFloat = 3, h: CGFloat = Self.height - 6
        var x: CGFloat = 6

        let mode = layout.mode == .edit ? "Edit Mode" : "Object Mode"
        let modeRect = CGRect(x: x, y: y, width: width(mode) + 30, height: h)
        fill(modeRect, isHovered(modeRect) ? Self.button.highlight(withLevel: 0.1) ?? Self.button : Self.button)
        label(mode + "  ▾", in: modeRect)
        targets.append((modeRect, { [weak self] in self?.pop(.mode, under: modeRect) }))
        x = modeRect.maxX + 10

        if layout.mode == .edit
        {
          for (i, select) in [SelectMode.vertex, .edge, .face].enumerated()
          {
            let r = CGRect(x: x + CGFloat(i) * 24, y: y, width: 24, height: h)
            fill(r, layout.selectMode == select ? Self.accent : isHovered(r) ? Self.button.highlight(withLevel: 0.1)! : Self.button,
                 radius: 3)
            drawSelectIcon(select, in: r.insetBy(dx: 6, dy: 4))
            targets.append((r, { [weak self] in self?.layout.setSelectMode(select) }))
          }

          x += 24 * 3 + 10
        }

        let menus: [(String, LayoutView.Menu)] = [("View", .view), ("Select", .select), ("Add", .add),
                                                  layout.mode == .edit ? ("Mesh", .mesh) : ("Object", .object)]
        for (title, kind) in menus
        {
          let r = CGRect(x: x, y: y, width: width(title) + 16, height: h)
          if isHovered(r) { fill(r, Self.button) }
          label(title, in: r)
          targets.append((r, { [weak self] in self?.pop(kind, under: r) }))
          x = r.maxX + 2
        }

        var right = bounds.maxX - 8
        let modes: [ViewportShading] = [.wireframe, .solid, .materialPreview, .rendered]
        let group = CGRect(x: right - 26 * 4, y: y, width: 26 * 4, height: h)
        fill(group, Self.button)
        for (i, shading) in modes.enumerated()
        {
          let r = CGRect(x: group.minX + CGFloat(i) * 26, y: y, width: 26, height: h)
          if layout.shading == shading { fill(r, Self.accent, radius: 3) }
          else if isHovered(r) { fill(r, Self.button.highlight(withLevel: 0.12)!, radius: 3) }
          drawShadingIcon(shading, in: CGRect(x: r.midX - 6.5, y: r.midY - 6.5, width: 13, height: 13))
          targets.append((r, { [weak self] in self?.layout.setShading(shading) }))
        }

        right = group.minX - 8

        let xray = CGRect(x: right - 26, y: y, width: 26, height: h)
        fill(xray, layout.xray ? Self.accent : Self.button)
        drawXrayIcon(in: xray.insetBy(dx: 7, dy: 4))
        targets.append((xray, { [weak self] in self?.layout.xray.toggle() }))
        right = xray.minX - 8

        let overlays = CGRect(x: right - 26, y: y, width: 26, height: h)
        fill(overlays, layout.overlays ? Self.accent : Self.button)
        drawOverlayIcon(in: overlays.insetBy(dx: 6, dy: 4))
        targets.append((overlays, { [weak self] in self?.layout.overlays.toggle() }))
        right = overlays.minX - 12

        if layout.layers.isEmpty, !askedLayers
        {
          askedLayers = true
          layout.refreshLayers()
        }

        let title = "Layer: \(layout.departmentName)  ▾"
        let layerRect = CGRect(x: right - width(title) - 20, y: y, width: width(title) + 20, height: h)
        if layerRect.minX > x
        {
          fill(layerRect, isHovered(layerRect) ? Self.button.highlight(withLevel: 0.1) ?? Self.button : Self.button)
          label(title, in: layerRect)
          targets.append((layerRect, { [weak self] in
            self?.layout.refreshLayers()
            self?.pop(.layer, under: layerRect)
          }))
        }
      }

      private func drawSelectIcon(_ mode: SelectMode, in r: CGRect)
      {
        let square = NSBezierPath(rect: r)
        Self.ink.withAlphaComponent(0.5).setStroke()
        square.lineWidth = 1
        square.stroke()
        Self.ink.setFill()
        Self.ink.setStroke()
        switch mode
        {
          case .vertex:
            NSBezierPath(ovalIn: CGRect(x: r.minX - 2.5, y: r.maxY - 2.5, width: 5, height: 5)).fill()
          case .edge:
            let edge = NSBezierPath()
            edge.move(to: CGPoint(x: r.minX, y: r.maxY))
            edge.line(to: CGPoint(x: r.maxX, y: r.maxY))
            edge.lineWidth = 2.5
            edge.stroke()
          case .face:
            NSBezierPath(rect: r.insetBy(dx: 2, dy: 2)).fill()
        }
      }

      private func drawShadingIcon(_ shading: ViewportShading, in r: CGRect)
      {
        let circle = NSBezierPath(ovalIn: r)
        circle.lineWidth = 1.2
        Self.ink.setStroke()
        switch shading
        {
          case .wireframe:
            circle.stroke()
            let lines = NSBezierPath(ovalIn: r.insetBy(dx: r.width * 0.3, dy: 0))
            lines.move(to: CGPoint(x: r.minX, y: r.midY))
            lines.line(to: CGPoint(x: r.maxX, y: r.midY))
            lines.lineWidth = 1
            lines.stroke()
          case .solid:
            Self.ink.setFill()
            circle.fill()
          case .materialPreview:
            circle.stroke()
            NSGraphicsContext.saveGraphicsState()
            circle.addClip()
            Self.ink.setFill()
            CGRect(x: r.minX, y: r.minY, width: r.width / 2, height: r.height / 2).fill()
            CGRect(x: r.midX, y: r.midY, width: r.width / 2, height: r.height / 2).fill()
            NSGraphicsContext.restoreGraphicsState()
          case .rendered:
            NSGradient(starting: NSColor.white, ending: NSColor(white: 0.35, alpha: 1))?
              .draw(in: circle, relativeCenterPosition: NSPoint(x: -0.4, y: 0.4))
        }
      }

      private func drawXrayIcon(in r: CGRect)
      {
        let back = NSBezierPath(rect: CGRect(x: r.minX + 4, y: r.minY, width: r.width - 4, height: r.height - 4))
        let front = NSBezierPath(rect: CGRect(x: r.minX, y: r.minY + 4, width: r.width - 4, height: r.height - 4))
        Self.ink.setStroke()
        back.lineWidth = 1
        back.stroke()
        Self.ink.withAlphaComponent(0.4).setFill()
        front.fill()
        front.stroke()
      }

      private func drawOverlayIcon(in r: CGRect)
      {
        Self.ink.setStroke()
        for dx in [0.0, r.width * 0.4]
        {
          let circle = NSBezierPath(ovalIn: CGRect(x: r.minX + dx, y: r.minY + 1, width: r.width * 0.6, height: r.width * 0.6))
          circle.lineWidth = 1.2
          circle.stroke()
        }
      }
    }
  #endif
}

#if os(macOS)
  extension AkariDemo.LayoutHeader: NSViewRepresentable
  {
    func makeNSView(context _: Context) -> AkariDemo.LayoutHeaderView
    {
      AkariDemo.LayoutHeaderView(layout: layout)
    }

    func updateNSView(_ view: AkariDemo.LayoutHeaderView, context _: Context)
    {
      view.needsDisplay = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView _: AkariDemo.LayoutHeaderView, context _: Context) -> ViewSize
    {
      ViewSize(proposal.width ?? 800, Double(AkariDemo.LayoutHeaderView.height))
    }

    static func dismantleNSView(_ nsView: AkariDemo.LayoutHeaderView, coordinator _: Void)
    {
      MainActor.assumeIsolated { nsView.stop() }
    }
  }
#else
  extension AkariDemo.LayoutHeader: View
  {
    var body: some View
    {
      EmptyView()
    }
  }
#endif
