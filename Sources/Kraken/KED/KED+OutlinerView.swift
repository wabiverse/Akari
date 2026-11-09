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
import SwiftCrossUI
#if os(macOS)
  import AppKit
  import AppKitBackend
#endif

extension Kraken
{
  #if os(macOS)
    final class PrimOutlinerView: NSView
    {
      private let layout: Layout
      private var timer: Timer?
      private var rows: [OutlinerRow] = []
      private var expanded: Set<String> = []
      private var seeded = false
      private var revision = -1
      private var scanning = false
      private var offset: CGFloat = 0
      private var hovered: CGPoint?
      private var tracking: NSTrackingArea?
      private var revealed: String?
      private var pendingReveal: String?

      private static let rowHeight: CGFloat = 20
      private static let header: CGFloat = 26
      private static let indent: CGFloat = 16
      private static let background = NSColor(white: 0.157, alpha: 1)
      private static let alternate = NSColor(white: 0.172, alpha: 1)
      private static let bar = NSColor(white: 0.19, alpha: 1)
      private static let selected = NSColor(red: 0.2, green: 0.3, blue: 0.5, alpha: 1)
      private static let active = NSColor(red: 0.278, green: 0.447, blue: 0.702, alpha: 1)
      private static let ink = NSColor(white: 0.88, alpha: 1)
      private static let dim = NSColor(white: 0.5, alpha: 1)
      private static let font = NSFont.systemFont(ofSize: 11)
      private static let badgeFont = NSFont.systemFont(ofSize: 8, weight: .bold)

      init(layout: Layout)
      {
        self.layout = layout
        super.init(frame: .zero)
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
          MainActor.assumeIsolated { self?.tick() }
        }

        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
      }

      @available(*, unavailable)
      required init?(coder _: NSCoder)
      {
        fatalError("init(coder:) is not supported")
      }

      override var isFlipped: Bool { true }

      func stop()
      {
        timer?.invalidate()
        timer = nil
      }

      private func tick()
      {
        if layout.sceneRevision != revision || (rows.isEmpty && !scanning) { rescan() }
        if let active = layout.selection.last, active != revealed
        {
          revealed = active
          reveal(active)
        }

        needsDisplay = true
      }

      /// Opens the parents of a newly selected prim and scrolls to it, so the outliner follows a viewport pick.
      private func reveal(_ path: String)
      {
        var parent = ""
        var opened = false
        for component in path.split(separator: "/").dropLast()
        {
          parent += "/" + component
          if !expanded.contains(parent)
          {
            expanded.insert(parent)
            opened = true
          }
        }

        if opened
        {
          pendingReveal = path
          rescan()
        }
        else
        {
          scroll(to: path)
        }
      }

      private func scroll(to path: String)
      {
        guard let i = rows.firstIndex(where: { $0.path == path }) else { return }
        let top = CGFloat(i) * Self.rowHeight
        let visible = bounds.height - Self.header
        if top < offset || top + Self.rowHeight > offset + visible
        {
          offset = top - (visible - Self.rowHeight) / 2
          clampOffset()
        }
      }

      private func rescan()
      {
        guard !scanning else
        {
          revision = -1
          return
        }

        scanning = true
        revision = layout.sceneRevision
        let expanded = expanded, seeded = seeded
        layout.onStage
        { [self] stage in
          var open = expanded
          if !seeded
          {
            let home = stage.GetDefaultPrim()
            if home.isValid { open.insert(home.path.string) }
            let roots = OutlinerScan.children(stage.getPseudoRoot())
            if roots.count == 1, let root = roots.first { open.insert(root.path.string) }
          }

          let rows = OutlinerScan.rows(stage, expanded: open)
          DispatchQueue.main.async
          { [weak self] in
            guard let self else { return }
            self.scanning = false
            if !rows.isEmpty, !self.seeded
            {
              self.seeded = true
              self.expanded = open
            }

            self.rows = rows
            self.clampOffset()
            if let path = self.pendingReveal, rows.contains(where: { $0.path == path })
            {
              self.pendingReveal = nil
              self.scroll(to: path)
            }

            self.needsDisplay = true
          }
        }
      }

      private func clampOffset()
      {
        let content = CGFloat(rows.count) * Self.rowHeight
        offset = max(0, min(offset, content - (bounds.height - Self.header)))
      }

      override func scrollWheel(with event: NSEvent)
      {
        offset -= event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : Self.rowHeight)
        clampOffset()
        needsDisplay = true
      }

      override func updateTrackingAreas()
      {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInActiveApp, .inVisibleRect],
                                  owner: self)
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

      private func row(at p: CGPoint) -> Int?
      {
        guard p.y >= Self.header else { return nil }
        let i = Int((p.y - Self.header + offset) / Self.rowHeight)
        return rows.indices.contains(i) ? i : nil
      }

      private func eyeRect(_ y: CGFloat) -> CGRect
      {
        CGRect(x: bounds.maxX - 44, y: y, width: 20, height: Self.rowHeight)
      }

      private func checkRect(_ y: CGFloat) -> CGRect
      {
        CGRect(x: bounds.maxX - 22, y: y, width: 20, height: Self.rowHeight)
      }

      private func rowY(_ i: Int) -> CGFloat
      {
        Self.header + CGFloat(i) * Self.rowHeight - offset
      }

      override func mouseDown(with event: NSEvent)
      {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = row(at: p) else { return }
        let r = rows[i], y = rowY(i)
        let disclosure = CGRect(x: 6 + CGFloat(r.depth) * Self.indent, y: y, width: 14, height: Self.rowHeight)
        if r.hasChildren, disclosure.contains(p)
        {
          toggle(r.path, recursive: event.modifierFlags.contains(.shift))
        }
        else if eyeRect(y).contains(p)
        {
          setHidden(r.path, !r.hidden)
        }
        else if checkRect(y).contains(p), !r.proxy
        {
          setActive(r.path, !r.active)
        }
        else if event.clickCount == 2
        {
          layout.select([r.path])
          layout.frameSelected()
        }
        else
        {
          let extend = event.modifierFlags.contains(.shift) || event.modifierFlags.contains(.command)
          layout.select([r.path], extend: extend)
        }

        needsDisplay = true
      }

      override func rightMouseDown(with event: NSEvent)
      {
        let p = convert(event.locationInWindow, from: nil)
        guard let i = row(at: p) else { return }
        let r = rows[i]
        if !layout.selection.contains(r.path) { layout.select([r.path]) }
        let menu = NSMenu()
        let l = layout
        let paths = layout.selection
        let items: [NSMenuItem] = [
          LayoutView.Action("View Selected") { l.frameSelected() },
          .separator(),
          LayoutView.Action(r.expandedTitle(expanded.contains(r.path))) { [weak self] in self?.toggle(r.path, recursive: true) },
          LayoutView.Action("Hide in Viewport") { [weak self] in paths.forEach { self?.setHidden($0, true) } },
          LayoutView.Action("Show in Viewport") { [weak self] in paths.forEach { self?.setHidden($0, false) } },
          r.active ? LayoutView.Action("Deactivate") { [weak self] in paths.forEach { self?.setActive($0, false) } }
                   : LayoutView.Action("Activate") { [weak self] in paths.forEach { self?.setActive($0, true) } },
          .separator(),
          LayoutView.Action("Duplicate") { l.duplicateSelected {} },
          LayoutView.Action("Delete") { l.deleteSelected() },
        ]
        items.forEach(menu.addItem)
        MenuPanel.show(menu, at: CGPoint(x: p.x, y: p.y + 4), in: self)
      }

      private func toggle(_ path: String, recursive: Bool)
      {
        if expanded.contains(path)
        {
          expanded = expanded.filter { $0 != path && !(recursive && $0.hasPrefix(path + "/")) }
          rows = rows.filter { !$0.path.hasPrefix(path + "/") }
          clampOffset()
          return
        }

        expanded.insert(path)
        if recursive
        {
          for r in rows where r.path.hasPrefix(path + "/") && r.hasChildren { expanded.insert(r.path) }
        }

        rescan()
      }

      private func setHidden(_ path: String, _ hidden: Bool)
      {
        layout.checkpoint()
        layout.onStage { stage in SceneEdit.setHidden(stage, path, hidden) }
        layout.primsChanged()
      }

      private func setActive(_ path: String, _ active: Bool)
      {
        layout.checkpoint()
        layout.onStage { stage in SceneEdit.setActive(stage, path, active) }
        layout.primsChanged()
      }

      // MARK: drawing

      override func draw(_: NSRect)
      {
        Self.background.setFill()
        bounds.fill()
        let selection = Set(layout.selection)
        let first = max(0, Int(offset / Self.rowHeight))
        let last = min(rows.count, first + Int(bounds.height / Self.rowHeight) + 2)
        if first < last
        {
          for i in first ..< last
          {
            let r = rows[i]
            let inside = !expanded.contains(r.path) && layout.selection.contains { $0.hasPrefix(r.path + "/") }
            drawRow(r, at: rowY(i), index: i, selected: selection.contains(r.path), holdsSelection: inside)
          }
        }

        Self.bar.setFill()
        CGRect(x: 0, y: 0, width: bounds.width, height: Self.header).fill()
        NSColor(white: 0.09, alpha: 1).setFill()
        CGRect(x: 0, y: Self.header - 1, width: bounds.width, height: 1).fill()
        drawStageIcon(in: CGRect(x: 10, y: 7, width: 12, height: 12))
        let title = layout.departmentName.isEmpty ? "Stage" : "Stage · \(layout.departmentName)"
        (title as NSString).draw(at: CGPoint(x: 28, y: 6), withAttributes: [.font: Self.font, .foregroundColor: Self.ink])
      }

      private func drawRow(_ r: OutlinerRow, at y: CGFloat, index: Int, selected: Bool, holdsSelection: Bool)
      {
        let rect = CGRect(x: 0, y: y, width: bounds.width, height: Self.rowHeight)
        if selected
        {
          (layout.selection.last == r.path ? Self.active : Self.selected).setFill()
          rect.fill()
        }
        else if holdsSelection
        {
          Self.selected.withAlphaComponent(0.45).setFill()
          rect.fill()
        }
        else if index % 2 == 1
        {
          Self.alternate.setFill()
          rect.fill()
        }

        if let hovered, rect.contains(hovered), !selected
        {
          NSColor(white: 1, alpha: 0.04).setFill()
          rect.fill()
        }

        var x = 6 + CGFloat(r.depth) * Self.indent
        if r.hasChildren { drawDisclosure(open: expanded.contains(r.path), in: CGRect(x: x + 2, y: y + 6, width: 8, height: 8)) }
        x += 14
        drawTypeIcon(r, in: CGRect(x: x, y: y + 4, width: 12, height: 12))
        x += 18

        let faded = !r.active || !r.defined || r.hidden
        let color = r.proxy ? NSColor(red: 0.55, green: 0.65, blue: 0.8, alpha: 1)
          : r.instance ? NSColor(red: 0.6, green: 0.78, blue: 1, alpha: 1) : Self.ink
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font,
                                                         .foregroundColor: faded ? color.withAlphaComponent(0.45) : color]
        let nameRight = bounds.maxX - 50 - CGFloat(r.arcs.count) * 11
        let name = r.name as NSString
        name.draw(with: CGRect(x: x, y: y + 3, width: max(0, nameRight - x), height: 15),
                  options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes)

        var bx = nameRight + 2
        for arc in r.arcs
        {
          drawBadge(arc, in: CGRect(x: bx, y: y + 5, width: 10, height: 10))
          bx += 11
        }

        drawEye(open: !r.hidden, in: eyeRect(y).insetBy(dx: 3, dy: 5))
        if !r.proxy { drawCheck(on: r.active, in: checkRect(y).insetBy(dx: 4, dy: 4)) }
      }

      private func drawDisclosure(open: Bool, in r: CGRect)
      {
        let path = NSBezierPath()
        if open
        {
          path.move(to: CGPoint(x: r.minX, y: r.minY + 1))
          path.line(to: CGPoint(x: r.maxX, y: r.minY + 1))
          path.line(to: CGPoint(x: r.midX, y: r.maxY - 1))
        }
        else
        {
          path.move(to: CGPoint(x: r.minX + 1, y: r.minY))
          path.line(to: CGPoint(x: r.maxX - 1, y: r.midY))
          path.line(to: CGPoint(x: r.minX + 1, y: r.maxY))
        }

        path.close()
        Self.dim.setFill()
        path.fill()
      }

      private func drawStageIcon(in r: CGRect)
      {
        NSColor(white: 0.85, alpha: 1).setStroke()
        for k in 0 ..< 3
        {
          let layer = NSBezierPath(roundedRect: CGRect(x: r.minX, y: r.minY + CGFloat(k) * 4, width: r.width, height: 3),
                                   xRadius: 1, yRadius: 1)
          layer.lineWidth = 1
          layer.stroke()
        }
      }

      /// The outliner colors: objects orange, cameras and lights green and yellow, materials red, collections white.
      private func drawTypeIcon(_ row: OutlinerRow, in r: CGRect)
      {
        if row.kind == .camera
        {
          NSColor(red: 0.42, green: 0.8, blue: 0.42, alpha: 1).setFill()
          NSBezierPath(rect: CGRect(x: r.minX, y: r.minY + 3, width: 8, height: 7)).fill()
          let lens = NSBezierPath()
          lens.move(to: CGPoint(x: r.minX + 8, y: r.minY + 6.5))
          lens.line(to: CGPoint(x: r.maxX, y: r.minY + 3))
          lens.line(to: CGPoint(x: r.maxX, y: r.minY + 10))
          lens.close()
          lens.fill()
        }
        else if row.kind == .light
        {
          NSColor(red: 0.95, green: 0.82, blue: 0.35, alpha: 1).setFill()
          NSBezierPath(ovalIn: CGRect(x: r.minX + 2, y: r.minY, width: 8, height: 8)).fill()
          NSBezierPath(rect: CGRect(x: r.minX + 4, y: r.minY + 8, width: 4, height: 3)).fill()
        }
        else if row.kind == .shading
        {
          NSColor(red: 0.85, green: 0.42, blue: 0.42, alpha: 1).setFill()
          NSBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
          NSColor(white: 1, alpha: 0.35).setFill()
          NSBezierPath(ovalIn: CGRect(x: r.minX + 3, y: r.minY + 3, width: 3, height: 3)).fill()
        }
        else if row.kind == .geometry
        {
          NSColor(red: 0.95, green: 0.6, blue: 0.3, alpha: 1).setFill()
          let tri = NSBezierPath()
          tri.move(to: CGPoint(x: r.midX, y: r.minY + 1))
          tri.line(to: CGPoint(x: r.maxX - 1, y: r.maxY - 1))
          tri.line(to: CGPoint(x: r.minX + 1, y: r.maxY - 1))
          tri.close()
          tri.fill()
        }
        else if row.instance || row.proxy
        {
          NSColor(red: 0.6, green: 0.78, blue: 1, alpha: 1).setStroke()
          for d in [0.0, 3.0]
          {
            let box = NSBezierPath(rect: CGRect(x: r.minX + d, y: r.minY + 3 - d, width: 8, height: 8))
            box.lineWidth = 1
            box.stroke()
          }
        }
        else if row.kind == .group
        {
          NSColor(white: 0.85, alpha: 1).setStroke()
          let box = NSBezierPath(roundedRect: r.insetBy(dx: 1, dy: 2), xRadius: 1.5, yRadius: 1.5)
          box.lineWidth = 1
          box.stroke()
        }
        else
        {
          NSColor(red: 0.95, green: 0.6, blue: 0.3, alpha: 1).setStroke()
          let axes = NSBezierPath()
          axes.move(to: CGPoint(x: r.midX, y: r.minY + 1))
          axes.line(to: CGPoint(x: r.midX, y: r.maxY - 1))
          axes.move(to: CGPoint(x: r.minX + 1, y: r.midY))
          axes.line(to: CGPoint(x: r.maxX - 1, y: r.midY))
          axes.lineWidth = 1.4
          axes.stroke()
        }
      }

      /// A composition arc's letter, colored as usdview's: references, payloads, variants, inherits, specializes.
      private func drawBadge(_ arc: OutlinerArc, in r: CGRect)
      {
        let color = switch arc
        {
          case .references: NSColor(red: 0.45, green: 0.62, blue: 0.95, alpha: 1)
          case .payloads: NSColor(red: 0.62, green: 0.48, blue: 0.9, alpha: 1)
          case .variants: NSColor(red: 0.4, green: 0.75, blue: 0.6, alpha: 1)
          case .inherits: NSColor(red: 0.9, green: 0.62, blue: 0.35, alpha: 1)
          case .specializes: NSColor(red: 0.85, green: 0.5, blue: 0.6, alpha: 1)
        }

        color.withAlphaComponent(0.85).setFill()
        let letter = arc.letter
        NSBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.badgeFont, .foregroundColor: NSColor(white: 0.08, alpha: 1)]
        let size = (letter as NSString).size(withAttributes: attributes)
        (letter as NSString).draw(at: CGPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2), withAttributes: attributes)
      }

      private func drawEye(open: Bool, in r: CGRect)
      {
        let color = open ? Self.ink : Self.dim
        color.setStroke()
        let lid = NSBezierPath()
        lid.move(to: CGPoint(x: r.minX, y: r.midY))
        lid.curve(to: CGPoint(x: r.maxX, y: r.midY), controlPoint1: CGPoint(x: r.minX + r.width * 0.3, y: r.minY - 2),
                  controlPoint2: CGPoint(x: r.maxX - r.width * 0.3, y: r.minY - 2))
        if open
        {
          lid.curve(to: CGPoint(x: r.minX, y: r.midY), controlPoint1: CGPoint(x: r.maxX - r.width * 0.3, y: r.maxY + 2),
                    controlPoint2: CGPoint(x: r.minX + r.width * 0.3, y: r.maxY + 2))
        }

        lid.lineWidth = 1.1
        lid.stroke()
        if open
        {
          color.setFill()
          NSBezierPath(ovalIn: CGRect(x: r.midX - 2, y: r.midY - 2, width: 4, height: 4)).fill()
        }
      }

      private func drawCheck(on: Bool, in r: CGRect)
      {
        let box = NSBezierPath(roundedRect: r, xRadius: 2.5, yRadius: 2.5)
        (on ? Self.active : NSColor(white: 0.33, alpha: 1)).setFill()
        box.fill()
        guard on else { return }
        NSColor.white.setStroke()
        let tick = NSBezierPath()
        tick.move(to: CGPoint(x: r.minX + 2.5, y: r.midY))
        tick.line(to: CGPoint(x: r.midX - 0.5, y: r.maxY - 2.5))
        tick.line(to: CGPoint(x: r.maxX - 2, y: r.minY + 2.5))
        tick.lineWidth = 1.5
        tick.stroke()
      }
    }
  #endif
}

#if os(macOS)
  extension Kraken.PrimOutliner: NSViewRepresentable
  {
    func makeNSView(context _: Context) -> Kraken.PrimOutlinerView
    {
      Kraken.PrimOutlinerView(layout: layout)
    }

    func updateNSView(_ view: Kraken.PrimOutlinerView, context _: Context)
    {
      view.needsDisplay = true
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView _: Kraken.PrimOutlinerView, context _: Context) -> ViewSize
    {
      ViewSize(proposal.width ?? Double(Kraken.Properties.width + 30), proposal.height ?? Self.height)
    }

    static func dismantleNSView(_ nsView: Kraken.PrimOutlinerView, coordinator _: Void)
    {
      MainActor.assumeIsolated { nsView.stop() }
    }
  }
#else
  extension Kraken.PrimOutliner: View
  {
    var body: some View
    {
      EmptyView()
    }
  }
#endif
