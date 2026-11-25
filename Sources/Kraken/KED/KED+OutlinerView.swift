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
#else
  import UIKit
#endif

extension Kraken
{
  final class PrimOutlinerView: CanvasView
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
    #if os(macOS)
      private var tracking: NSTrackingArea?
      /// a row pressed and where, it drags once the pointer moves a few points
      private var grab: (path: String, start: CGPoint, dragging: Bool)?
      /// where a dragged prim lands, a row to nest under or the stage root below every row
      private var landing: String?
    #endif
    private var revealed: String?
    private var pendingReveal: String?

    private static let touch = FormFactor.isTouch
    private static let rowHeight: CGFloat = touch ? 36 : 20
    private static let header: CGFloat = touch ? 34 : 26
    private static let indent: CGFloat = touch ? 18 : 16
    /// the side of the eye and checkbox columns, wide enough to tap.
    private static let column: CGFloat = touch ? 40 : 20
    private static let background = PlatformColor(white: 0.157, alpha: 1)
    private static let alternate = PlatformColor(white: 0.172, alpha: 1)
    private static let bar = PlatformColor(white: 0.19, alpha: 1)
    private static let selected = PlatformColor(red: 0.2, green: 0.3, blue: 0.5, alpha: 1)
    private static let active = PlatformColor(red: 0.278, green: 0.447, blue: 0.702, alpha: 1)
    private static let ink = PlatformColor(white: 0.88, alpha: 1)
    private static let dim = PlatformColor(white: 0.5, alpha: 1)
    private static let font = PlatformFont.systemFont(ofSize: touch ? 14 : 11)
    private static let badgeFont = PlatformFont.systemFont(ofSize: 8, weight: .bold)

    init(layout: Layout)
    {
      self.layout = layout
      super.init()
      let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.tick() }
      }

      RunLoop.main.add(timer, forMode: .common)
      self.timer = timer
    }

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

      invalidate()
    }

    /// opens the parents of a newly selected prim and scrolls to it, so the outliner follows a viewport pick.
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

          self.invalidate()
        }
      }
    }

    private func clampOffset()
    {
      let content = CGFloat(rows.count) * Self.rowHeight
      offset = max(0, min(offset, content - (bounds.height - Self.header)))
    }

    #if os(macOS)
      override func scrollWheel(with event: NSEvent)
      {
        offset -= event.scrollingDeltaY * (event.hasPreciseScrollingDeltas ? 1 : Self.rowHeight)
        clampOffset()
        invalidate()
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
        invalidate()
      }

      override func mouseExited(with _: NSEvent)
      {
        hovered = nil
        invalidate()
      }
    #endif

    private func row(at p: CGPoint) -> Int?
    {
      guard p.y >= Self.header else { return nil }
      let i = Int((p.y - Self.header + offset) / Self.rowHeight)
      return rows.indices.contains(i) ? i : nil
    }

    private func eyeRect(_ y: CGFloat) -> CGRect
    {
      CGRect(x: bounds.maxX - 2 * Self.column - 4, y: y, width: Self.column, height: Self.rowHeight)
    }

    private func checkRect(_ y: CGFloat) -> CGRect
    {
      CGRect(x: bounds.maxX - Self.column - 2, y: y, width: Self.column, height: Self.rowHeight)
    }

    /// the 20 point square a row's glyph is drawn in, centered in a wider tap column.
    private static func glyph(_ r: CGRect) -> CGRect
    {
      CGRect(x: r.midX - 10, y: r.midY - 10, width: 20, height: 20)
    }

    private func rowY(_ i: Int) -> CGFloat
    {
      Self.header + CGFloat(i) * Self.rowHeight - offset
    }

    /// a press on row `i` at `p`, a disclosure, eye or checkbox, or the row itself.
    private func activate(at p: CGPoint, extend: Bool, recursive: Bool, twice: Bool)
    {
      guard let i = row(at: p) else { return }
      let r = rows[i], y = rowY(i)
      let left = CGFloat(r.depth) * Self.indent
      let disclosure = Self.touch ? CGRect(x: left, y: y, width: 20 + Self.indent, height: Self.rowHeight)
        : CGRect(x: 6 + left, y: y, width: 14, height: Self.rowHeight)
      if r.hasChildren, disclosure.contains(p)
      {
        toggle(r.path, recursive: recursive)
      }
      else if eyeRect(y).contains(p)
      {
        setHidden(r.path, !r.hidden)
      }
      else if checkRect(y).contains(p), !r.proxy
      {
        setActive(r.path, !r.active)
      }
      else if twice
      {
        layout.select([r.path])
        layout.frameSelected()
      }
      else
      {
        layout.select([r.path], extend: extend)
      }

      invalidate()
    }

    /// the commands for the row under `p`, which joins the selection first.
    private func menuEntries(at p: CGPoint) -> [MenuEntry]
    {
      guard let i = row(at: p) else { return [] }
      let r = rows[i]
      if !layout.selection.contains(r.path) { layout.select([r.path]) }
      let l = layout
      let paths = layout.selection
      return [
        MenuEntry("View Selected") { l.frameSelected() },
        .separator,
        MenuEntry(r.expandedTitle(expanded.contains(r.path))) { [weak self] in self?.toggle(r.path, recursive: true) },
        MenuEntry("Hide in Viewport") { [weak self] in paths.forEach { self?.setHidden($0, true) } },
        MenuEntry("Show in Viewport") { [weak self] in paths.forEach { self?.setHidden($0, false) } },
        r.active ? MenuEntry("Deactivate") { [weak self] in paths.forEach { self?.setActive($0, false) } }
          : MenuEntry("Activate") { [weak self] in paths.forEach { self?.setActive($0, true) } },
        .separator,
        MenuEntry("Duplicate") { l.duplicateSelected {} },
        MenuEntry("Delete") { l.deleteSelected() },
      ]
    }

    #if os(macOS)
      override func mouseDown(with event: NSEvent)
      {
        let flags = event.modifierFlags
        let p = convert(event.locationInWindow, from: nil)
        activate(at: p, extend: flags.contains(.shift) || flags.contains(.command),
                 recursive: flags.contains(.shift), twice: event.clickCount == 2)

        // a press on the name can become a drag, not one on the eye or checkbox
        grab = nil
        if let i = row(at: p), !rows[i].proxy, p.x < eyeRect(rowY(i)).minX { grab = (rows[i].path, p, false) }
      }

      override func mouseDragged(with event: NSEvent)
      {
        guard var grab else { return }
        let p = convert(event.locationInWindow, from: nil)
        if !grab.dragging, hypot(p.x - grab.start.x, p.y - grab.start.y) < 4 { return }
        grab.dragging = true
        self.grab = grab
        landing = landing(at: p, moving: moving(grab.path))
        invalidate()
      }

      override func mouseUp(with _: NSEvent)
      {
        defer
        {
          grab = nil
          landing = nil
          invalidate()
        }

        guard let grab, grab.dragging, let landing else { return }
        layout.select(moving(grab.path))
        layout.parentSelected(to: landing)
        { [weak self] moved in
          guard let self, !moved.isEmpty, landing != "/" else { return }
          self.expanded.insert(landing)
          self.rescan()
        }
      }

      /// what a drag from `path` carries, the whole selection when the row is part of it
      private func moving(_ path: String) -> [String]
      {
        layout.selection.contains(path) ? layout.selection : [path]
      }

      /// the prim a drag at `p` nests under, the stage root below every row, nil where it can't go
      private func landing(at p: CGPoint, moving paths: [String]) -> String?
      {
        func parent(_ path: String) -> String
        {
          let up = (path as NSString).deletingLastPathComponent
          return up.isEmpty ? "/" : up
        }

        guard p.y >= Self.header else { return nil }
        guard let i = row(at: p) else { return paths.allSatisfy { parent($0) == "/" } ? nil : "/" }

        // never into itself or anything under it, nor into an instance's shared prims
        let target = rows[i]
        if target.proxy || paths.contains(where: { target.path == $0 || target.path.hasPrefix($0 + "/") }) { return nil }

        return paths.allSatisfy { parent($0) == target.path } ? nil : target.path
      }

      /// outlines the row a drag lands in, or a line under every row for the stage root
      private func drawLanding(_ target: String)
      {
        Self.active.setStroke()
        if target == "/"
        {
          let y = min(rowY(rows.count), bounds.maxY - 2)
          let line = PlatformBezierPath(rect: CGRect(x: 4, y: y, width: bounds.width - 8, height: 0))
          line.lineWidth = 2
          line.stroke()
          return
        }

        guard let i = rows.firstIndex(where: { $0.path == target }) else { return }
        let box = PlatformBezierPath(roundedRect: CGRect(x: 1, y: rowY(i) + 1, width: bounds.width - 2, height: Self.rowHeight - 2),
                                     xRadius: 3, yRadius: 3)
        box.lineWidth = 1.5
        box.stroke()
      }

      override func rightMouseDown(with event: NSEvent)
      {
        let p = convert(event.locationInWindow, from: nil)
        let entries = menuEntries(at: p)
        guard !entries.isEmpty else { return }
        MenuPanel.show(MenuEntry.menu(entries), at: CGPoint(x: p.x, y: p.y + 4), in: self)
      }
    #else
      /// where a finger landed and how far the list was scrolled then, a drag scrolls instead of picking.
      private var drag: (start: CGPoint, offset: CGFloat, scrolling: Bool)?

      override func pointerDown(at point: CGPoint)
      {
        drag = (point, offset, false)
      }

      override func pointerDragged(to point: CGPoint)
      {
        guard var drag else { return }
        drag.scrolling = drag.scrolling || abs(point.y - drag.start.y) > 6
        if drag.scrolling
        {
          offset = drag.offset - (point.y - drag.start.y)
          clampOffset()
          invalidate()
        }

        self.drag = drag
      }

      override func pointerUp(at _: CGPoint)
      {
        defer { drag = nil }
        guard let drag, !drag.scrolling else { return }
        activate(at: drag.start, extend: false, recursive: false, twice: false)
      }

      override func pointerCancelled()
      {
        drag = nil
      }

      override func pointerDoubleTapped(at point: CGPoint)
      {
        activate(at: point, extend: false, recursive: false, twice: true)
      }

      override func didMoveToWindow()
      {
        super.didMoveToWindow()
        if interactions.isEmpty { addInteraction(UIContextMenuInteraction(delegate: self)) }
      }
    #endif

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

    override func draw(_: CGRect)
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

      #if os(macOS)
        if let landing, grab?.dragging == true { drawLanding(landing) }
      #endif

      Self.bar.setFill()
      CGRect(x: 0, y: 0, width: bounds.width, height: Self.header).fill()
      PlatformColor(white: 0.09, alpha: 1).setFill()
      CGRect(x: 0, y: Self.header - 1, width: bounds.width, height: 1).fill()
      let middle = Self.header / 2
      drawStageIcon(in: CGRect(x: 10, y: middle - 6, width: 12, height: 12))
      let title = layout.departmentName.isEmpty ? "Stage" : "Stage · \(layout.departmentName)"
      (title as NSString).draw(at: CGPoint(x: 28, y: (middle - Self.font.pointSize / 2 - 2).rounded(.up)),
                               withAttributes: [.font: Self.font, .foregroundColor: Self.ink])
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
        PlatformColor(white: 1, alpha: 0.04).setFill()
        rect.fill()
      }

      // the row's glyphs sit on a 20 point line in the middle of the row.
      let y = y + (Self.rowHeight - 20) / 2
      var x = 6 + CGFloat(r.depth) * Self.indent
      if r.hasChildren { drawDisclosure(open: expanded.contains(r.path), in: CGRect(x: x + 2, y: y + 6, width: 8, height: 8)) }
      x += 14
      drawTypeIcon(r, in: CGRect(x: x, y: y + 4, width: 12, height: 12))
      x += 18

      let faded = !r.active || !r.defined || r.hidden
      let color = r.proxy ? PlatformColor(red: 0.55, green: 0.65, blue: 0.8, alpha: 1)
        : r.instance ? PlatformColor(red: 0.6, green: 0.78, blue: 1, alpha: 1) : Self.ink
      let attributes: [NSAttributedString.Key: Any] = [.font: Self.font,
                                                       .foregroundColor: faded ? color.withAlphaComponent(0.45) : color]
      let nameRight = bounds.maxX - 2 * Self.column - 10 - CGFloat(r.arcs.count) * 11
      let name = r.name as NSString
      let line = Self.font.pointSize + 4
      name.draw(with: CGRect(x: x, y: (y + 10 - line / 2).rounded(.up), width: max(0, nameRight - x), height: line),
                options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine], attributes: attributes, context: nil)

      var bx = nameRight + 2
      for arc in r.arcs
      {
        drawBadge(arc, in: CGRect(x: bx, y: y + 5, width: 10, height: 10))
        bx += 11
      }

      drawEye(open: !r.hidden, in: Self.glyph(eyeRect(y)).insetBy(dx: 3, dy: 5))
      if !r.proxy { drawCheck(on: r.active, in: Self.glyph(checkRect(y)).insetBy(dx: 4, dy: 4)) }
    }

    private func drawDisclosure(open: Bool, in r: CGRect)
    {
      let path = PlatformBezierPath()
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
      PlatformColor(white: 0.85, alpha: 1).setStroke()
      for k in 0 ..< 3
      {
        let layer = PlatformBezierPath(roundedRect: CGRect(x: r.minX, y: r.minY + CGFloat(k) * 4, width: r.width, height: 3),
                                 xRadius: 1, yRadius: 1)
        layer.lineWidth = 1
        layer.stroke()
      }
    }

    /// the outliner colors: objects orange, cameras and lights green and yellow, materials red, collections white.
    private func drawTypeIcon(_ row: OutlinerRow, in r: CGRect)
    {
      if row.kind == .camera
      {
        PlatformColor(red: 0.42, green: 0.8, blue: 0.42, alpha: 1).setFill()
        PlatformBezierPath(rect: CGRect(x: r.minX, y: r.minY + 3, width: 8, height: 7)).fill()
        let lens = PlatformBezierPath()
        lens.move(to: CGPoint(x: r.minX + 8, y: r.minY + 6.5))
        lens.line(to: CGPoint(x: r.maxX, y: r.minY + 3))
        lens.line(to: CGPoint(x: r.maxX, y: r.minY + 10))
        lens.close()
        lens.fill()
      }
      else if row.kind == .light
      {
        PlatformColor(red: 0.95, green: 0.82, blue: 0.35, alpha: 1).setFill()
        PlatformBezierPath(ovalIn: CGRect(x: r.minX + 2, y: r.minY, width: 8, height: 8)).fill()
        PlatformBezierPath(rect: CGRect(x: r.minX + 4, y: r.minY + 8, width: 4, height: 3)).fill()
      }
      else if row.kind == .shading
      {
        PlatformColor(red: 0.85, green: 0.42, blue: 0.42, alpha: 1).setFill()
        PlatformBezierPath(ovalIn: r.insetBy(dx: 1, dy: 1)).fill()
        PlatformColor(white: 1, alpha: 0.35).setFill()
        PlatformBezierPath(ovalIn: CGRect(x: r.minX + 3, y: r.minY + 3, width: 3, height: 3)).fill()
      }
      else if row.kind == .geometry
      {
        PlatformColor(red: 0.95, green: 0.6, blue: 0.3, alpha: 1).setFill()
        let tri = PlatformBezierPath()
        tri.move(to: CGPoint(x: r.midX, y: r.minY + 1))
        tri.line(to: CGPoint(x: r.maxX - 1, y: r.maxY - 1))
        tri.line(to: CGPoint(x: r.minX + 1, y: r.maxY - 1))
        tri.close()
        tri.fill()
      }
      else if row.instance || row.proxy
      {
        PlatformColor(red: 0.6, green: 0.78, blue: 1, alpha: 1).setStroke()
        for d in [0.0, 3.0]
        {
          let box = PlatformBezierPath(rect: CGRect(x: r.minX + d, y: r.minY + 3 - d, width: 8, height: 8))
          box.lineWidth = 1
          box.stroke()
        }
      }
      else if row.kind == .group
      {
        PlatformColor(white: 0.85, alpha: 1).setStroke()
        let box = PlatformBezierPath(roundedRect: r.insetBy(dx: 1, dy: 2), xRadius: 1.5, yRadius: 1.5)
        box.lineWidth = 1
        box.stroke()
      }
      else
      {
        PlatformColor(red: 0.95, green: 0.6, blue: 0.3, alpha: 1).setStroke()
        let axes = PlatformBezierPath()
        axes.move(to: CGPoint(x: r.midX, y: r.minY + 1))
        axes.line(to: CGPoint(x: r.midX, y: r.maxY - 1))
        axes.move(to: CGPoint(x: r.minX + 1, y: r.midY))
        axes.line(to: CGPoint(x: r.maxX - 1, y: r.midY))
        axes.lineWidth = 1.4
        axes.stroke()
      }
    }

    /// a composition arc's letter, colored as usdview's: references, payloads, variants, inherits, specializes.
    private func drawBadge(_ arc: OutlinerArc, in r: CGRect)
    {
      let color = switch arc
      {
        case .references: PlatformColor(red: 0.45, green: 0.62, blue: 0.95, alpha: 1)
        case .payloads: PlatformColor(red: 0.62, green: 0.48, blue: 0.9, alpha: 1)
        case .variants: PlatformColor(red: 0.4, green: 0.75, blue: 0.6, alpha: 1)
        case .inherits: PlatformColor(red: 0.9, green: 0.62, blue: 0.35, alpha: 1)
        case .specializes: PlatformColor(red: 0.85, green: 0.5, blue: 0.6, alpha: 1)
      }

      color.withAlphaComponent(0.85).setFill()
      let letter = arc.letter
      PlatformBezierPath(roundedRect: r, xRadius: 2, yRadius: 2).fill()
      let attributes: [NSAttributedString.Key: Any] = [.font: Self.badgeFont, .foregroundColor: PlatformColor(white: 0.08, alpha: 1)]
      let size = (letter as NSString).size(withAttributes: attributes)
      (letter as NSString).draw(at: CGPoint(x: r.midX - size.width / 2, y: r.midY - size.height / 2), withAttributes: attributes)
    }

    private func drawEye(open: Bool, in r: CGRect)
    {
      let color = open ? Self.ink : Self.dim
      color.setStroke()
      let lid = PlatformBezierPath()
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
        PlatformBezierPath(ovalIn: CGRect(x: r.midX - 2, y: r.midY - 2, width: 4, height: 4)).fill()
      }
    }

    private func drawCheck(on: Bool, in r: CGRect)
    {
      let box = PlatformBezierPath(roundedRect: r, xRadius: 2.5, yRadius: 2.5)
      (on ? Self.active : PlatformColor(white: 0.33, alpha: 1)).setFill()
      box.fill()
      guard on else { return }
      PlatformColor.white.setStroke()
      let tick = PlatformBezierPath()
      tick.move(to: CGPoint(x: r.minX + 2.5, y: r.midY))
      tick.line(to: CGPoint(x: r.midX - 0.5, y: r.maxY - 2.5))
      tick.line(to: CGPoint(x: r.maxX - 2, y: r.minY + 2.5))
      tick.lineWidth = 1.5
      tick.stroke()
    }
  }
}

extension Kraken.PrimOutlinerView: Kraken.Dismantling
{
  func dismantle()
  {
    stop()
  }
}

#if !os(macOS)
  extension Kraken.PrimOutlinerView: UIContextMenuInteractionDelegate
  {
    func contextMenuInteraction(_: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration?
    {
      let entries = menuEntries(at: location)
      guard !entries.isEmpty else { return nil }
      return UIContextMenuConfiguration(identifier: nil, previewProvider: nil) { _ in Kraken.MenuEntry.menu(entries) }
    }
  }
#endif

extension Kraken.PrimOutliner: View
{
  var body: some View
  {
    Kraken.NativeView(make: { [layout] in Kraken.PrimOutlinerView(layout: layout) },
                      update: { $0.invalidate() },
                      size: { ViewSize($0.width ?? Double(Kraken.Properties.width + 30), $0.height ?? Self.height) })
  }
}
