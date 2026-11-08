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

import Foundation
#if os(macOS)
  import AppKit

  extension AkariDemo
  {
    /// A popup menu, drawn over the viewport from an `NSMenu`'s items.
    final class MenuPanel: NSPanel
    {
      private(set) static var open: [MenuPanel] = []
      private static var monitor: Any?

      static var isOpen: Bool
      {
        !open.isEmpty
      }

      fileprivate let items: [NSMenuItem]
      fileprivate var hovered: Int?
      private let content: MenuView

      static let background = NSColor(white: 0.094, alpha: 0.97)
      static let outline = NSColor(white: 0.24, alpha: 1)
      static let text = NSColor(white: 0.9, alpha: 1)
      static let dim = NSColor(white: 0.55, alpha: 1)
      static let highlight = NSColor(red: 0.278, green: 0.447, blue: 0.702, alpha: 1)
      static let font = NSFont.systemFont(ofSize: 12)
      static let rowHeight: CGFloat = 22
      static let separatorHeight: CGFloat = 7
      static let pad: CGFloat = 4

      /// Opens `menu` with its top left at `point` in `view`.
      static func show(_ menu: NSMenu, at point: CGPoint, in view: NSView)
      {
        closeAll()
        guard let window = view.window else { return }
        let screenPoint = window.convertPoint(toScreen: view.convert(point, to: nil))
        let panel = MenuPanel(items: menu.items)
        panel.place(topLeft: CGPoint(x: screenPoint.x - 12, y: screenPoint.y + 10))
        open = [panel]
        panel.orderFront(nil)
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown])
        { event in
          let consumed = MainActor.assumeIsolated { handle(event) }
          return consumed ? nil : event
        }
      }

      static func closeAll()
      {
        for panel in open { panel.orderOut(nil) }
        open = []
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
      }

      private static func handle(_ event: NSEvent) -> Bool
      {
        if event.type == .keyDown
        {
          guard let panel = open.last else { return false }
          switch Int(event.keyCode)
          {
            case 53: closeAll()
            case 126: panel.step(-1)
            case 125: panel.step(1)
            case 124: if let i = panel.hovered { panel.openChild(i, highlightFirst: true) }
            case 123:
              if open.count > 1
              {
                open.removeLast().orderOut(nil)
                open.last?.content.needsDisplay = true
              }
            case 36, 76: if let i = panel.hovered { panel.activate(i, highlightFirst: true) }
            default: break
          }

          return true
        }

        if open.contains(where: { $0 === event.window }) { return false }
        closeAll()
        return true
      }

      private init(items: [NSMenuItem])
      {
        self.items = items
        content = MenuView()
        super.init(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        acceptsMouseMovedEvents = true
        content.panel = self
        contentView = content
      }

      fileprivate func isHeader(_ item: NSMenuItem) -> Bool
      {
        !item.isEnabled && item.submenu == nil && !item.isSeparatorItem
      }

      fileprivate func height(_ item: NSMenuItem) -> CGFloat
      {
        item.isSeparatorItem ? Self.separatorHeight : Self.rowHeight
      }

      fileprivate func shortcut(_ item: NSMenuItem) -> String
      {
        guard !item.keyEquivalent.isEmpty else { return "" }
        let flags = item.keyEquivalentModifierMask
        var words: [String] = []
        if flags.contains(.control) { words.append("Ctrl") }
        if flags.contains(.option) { words.append("Alt") }
        if flags.contains(.shift) { words.append("Shift") }
        if flags.contains(.command) { words.append("Cmd") }
        words.append(item.keyEquivalent.uppercased())
        return words.joined(separator: " ")
      }

      private func place(topLeft: CGPoint)
      {
        let attributes: [NSAttributedString.Key: Any] = [.font: Self.font]
        var titles: CGFloat = 0, keys: CGFloat = 0
        for item in items
        {
          titles = max(titles, (item.title as NSString).size(withAttributes: attributes).width)
          keys = max(keys, (shortcut(item) as NSString).size(withAttributes: attributes).width)
        }

        let width = max(150, 26 + titles + (keys > 0 ? keys + 28 : 0) + (items.contains { $0.submenu != nil } ? 18 : 0))
        let height = items.reduce(0) { $0 + height($1) } + Self.pad * 2
        var origin = CGPoint(x: topLeft.x, y: topLeft.y - height)
        if let screen = NSScreen.screens.first(where: { $0.frame.contains(topLeft) }) ?? NSScreen.main
        {
          let visible = screen.visibleFrame
          origin.x = min(max(origin.x, visible.minX), visible.maxX - width)
          origin.y = min(max(origin.y, visible.minY), visible.maxY - height)
        }

        setFrame(CGRect(origin: origin, size: CGSize(width: width, height: height)), display: false)
      }

      fileprivate func rowRect(_ i: Int) -> CGRect
      {
        var y = Self.pad
        for k in 0 ..< i { y += height(items[k]) }
        return CGRect(x: Self.pad, y: y, width: frame.width - Self.pad * 2, height: height(items[i]))
      }

      fileprivate func row(at p: CGPoint) -> Int?
      {
        items.indices.first { rowRect($0).contains(p) && !items[$0].isSeparatorItem && !isHeader(items[$0]) }
      }

      private func step(_ direction: Int)
      {
        let selectable = items.indices.filter { !items[$0].isSeparatorItem && !isHeader(items[$0]) }
        guard !selectable.isEmpty else { return }
        let at = hovered.flatMap { selectable.firstIndex(of: $0) } ?? (direction > 0 ? -1 : selectable.count)
        hover(selectable[(at + direction + selectable.count) % selectable.count], opensChild: false)
      }

      fileprivate func hover(_ i: Int?, opensChild: Bool = true)
      {
        guard i != hovered else { return }
        hovered = i
        content.needsDisplay = true
        if let index = MenuPanel.open.firstIndex(where: { $0 === self }), index + 1 < MenuPanel.open.count
        {
          for panel in MenuPanel.open[(index + 1)...] { panel.orderOut(nil) }
          MenuPanel.open.removeSubrange((index + 1)...)
        }

        if opensChild, let i, items[i].submenu != nil { openChild(i, highlightFirst: false) }
      }

      private func openChild(_ i: Int, highlightFirst: Bool)
      {
        guard let submenu = items[i].submenu, MenuPanel.open.last === self else { return }
        let child = MenuPanel(items: submenu.items)
        let row = rowRect(i)
        child.place(topLeft: CGPoint(x: frame.maxX - 2, y: frame.maxY - row.minY + Self.pad))
        MenuPanel.open.append(child)
        child.orderFront(nil)
        if highlightFirst { child.step(1) }
      }

      fileprivate func activate(_ i: Int, highlightFirst: Bool = false)
      {
        let item = items[i]
        if item.submenu != nil
        {
          openChild(i, highlightFirst: highlightFirst)
          return
        }

        MenuPanel.closeAll()
        if let action = item.action { NSApp.sendAction(action, to: item.target, from: item) }
      }
    }

    fileprivate final class MenuView: NSView
    {
      weak var panel: MenuPanel?
      private var tracking: NSTrackingArea?

      override var isFlipped: Bool
      {
        true
      }

      override func updateTrackingAreas()
      {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeAlways],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
      }

      override func mouseMoved(with event: NSEvent)
      {
        guard let panel else { return }
        let p = convert(event.locationInWindow, from: nil)
        if let i = panel.row(at: p) { panel.hover(i) }
      }

      override func mouseDown(with event: NSEvent)
      {
        guard let panel, let i = panel.row(at: convert(event.locationInWindow, from: nil)) else { return }
        panel.activate(i)
      }

      override func draw(_: NSRect)
      {
        guard let panel else { return }
        let frame = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5), xRadius: 5, yRadius: 5)
        MenuPanel.background.setFill()
        frame.fill()
        MenuPanel.outline.setStroke()
        frame.lineWidth = 1
        frame.stroke()
        let text: [NSAttributedString.Key: Any] = [.font: MenuPanel.font, .foregroundColor: MenuPanel.text]
        let dim: [NSAttributedString.Key: Any] = [.font: MenuPanel.font, .foregroundColor: MenuPanel.dim]
        for (i, item) in panel.items.enumerated()
        {
          let r = panel.rowRect(i)
          if item.isSeparatorItem
          {
            MenuPanel.outline.setFill()
            CGRect(x: r.minX + 6, y: r.midY, width: r.width - 12, height: 1).fill()
            continue
          }

          let y = r.midY - (item.title as NSString).size(withAttributes: text).height / 2
          if panel.isHeader(item)
          {
            (item.title as NSString).draw(at: CGPoint(x: r.minX + 8, y: y), withAttributes: dim)
            MenuPanel.outline.setFill()
            CGRect(x: r.minX + 6, y: r.maxY - 1, width: r.width - 12, height: 1).fill()
            continue
          }

          let hot = panel.hovered == i
          if hot
          {
            MenuPanel.highlight.setFill()
            NSBezierPath(roundedRect: r, xRadius: 3, yRadius: 3).fill()
          }

          if item.state == .on
          {
            let dot = NSBezierPath(ovalIn: CGRect(x: r.minX + 7, y: r.midY - 3, width: 6, height: 6))
            MenuPanel.text.setFill()
            dot.fill()
          }

          (item.title as NSString).draw(at: CGPoint(x: r.minX + 20, y: y), withAttributes: text)
          let key = panel.shortcut(item) as NSString
          let keyWidth = key.size(withAttributes: dim).width
          key.draw(at: CGPoint(x: r.maxX - keyWidth - 10, y: y), withAttributes: hot ? text : dim)
          if item.submenu != nil
          {
            let arrow = NSBezierPath()
            arrow.move(to: CGPoint(x: r.maxX - 12, y: r.midY - 4))
            arrow.line(to: CGPoint(x: r.maxX - 8, y: r.midY))
            arrow.line(to: CGPoint(x: r.maxX - 12, y: r.midY + 4))
            arrow.lineWidth = 1.3
            (hot ? MenuPanel.text : MenuPanel.dim).setStroke()
            arrow.stroke()
          }
        }
      }
    }
  }
#endif
