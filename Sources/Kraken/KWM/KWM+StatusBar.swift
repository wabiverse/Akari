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
import Foundation
import Metal
import SwiftCrossUI
#if os(macOS)
  import AppKit
  import AppKitBackend
  import MetalKit
#endif

extension Kraken
{
  /// The strip along the window's bottom: the hotkeys of whatever the pointer is
  /// over at its left, the scene's memory and Akari's version at its right.
  struct StatusBar
  {
    var layout: Layout?
  }

  #if os(macOS)
    final class StatusView: NSView
    {
      enum Glyph
      {
        case click, drag, scroll
        case key(String)
      }

      typealias Hint = (glyphs: [Glyph], label: String)

      static let height: CGFloat = 22
      private static let background = NSColor(white: 0.11, alpha: 1)
      private static let ink = NSColor(white: 0.76, alpha: 1)
      private static let text: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 10),
        .foregroundColor: ink,
      ]
      private static let keyText: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 8, weight: .medium),
        .foregroundColor: ink,
      ]
      private static let digits: [NSAttributedString.Key: Any] = [
        .font: NSFont.monospacedDigitSystemFont(ofSize: 10, weight: .regular),
        .foregroundColor: ink,
      ]

      private let device = MTLCreateSystemDefaultDevice()
      weak var layout: Layout?
      private var timer: Timer?
      private var hints: [Hint] = []
      private var memory = ""
      private var tick = 0

      override init(frame: NSRect)
      {
        super.init(frame: frame)
        refresh()
        let timer = Timer(timeInterval: 0.1, target: self, selector: #selector(refresh), userInfo: nil, repeats: true)
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

      private static func gibibytes(_ bytes: UInt64) -> String
      {
        String(format: "%.1f GiB", Double(bytes) / Double(1 << 30))
      }

      private static var footprint: UInt64
      {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
        let result = withUnsafeMutablePointer(to: &info)
        {
          $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
        }

        return result == KERN_SUCCESS ? info.phys_footprint : 0
      }

      private weak var viewport: NSView?
      private weak var ruler: NSView?
      private weak var dopeSheet: NSView?

      private static func find(_ view: NSView, _ match: (NSView) -> Bool) -> NSView?
      {
        if match(view) { return view }
        for child in view.subviews
        {
          if let found = find(child, match) { return found }
        }

        return nil
      }

      private static func contains(_ view: NSView?, _ screen: NSPoint) -> Bool
      {
        guard let view, let window = view.window, !view.isHiddenOrHasHiddenAncestor else { return false }
        return view.bounds.contains(view.convert(window.convertPoint(fromScreen: screen), from: nil))
      }

      /// What the pointer is over decides the hints, the viewport's change while a modifier is held.
      private func currentHints() -> [Hint]
      {
        guard let content = window?.contentView else { return [] }
        if viewport == nil { viewport = Self.find(content) { $0 is MTKView } }
        if ruler == nil { ruler = Self.find(content) { $0 is Kraken.RulerView } }
        let mouse = NSEvent.mouseLocation
        if Self.contains(ruler, mouse) { return [([.click], "Set Frame"), ([.drag], "Scrub")] }
        if Kraken.Keyframes.hovered != nil
        {
          return [([.key("I")], "Insert Keyframe"), ([.key("⌥"), .key("I")], "Delete Keyframe"),
                  ([.key("⇧"), .key("⌥"), .key("I")], "Clear Keyframes"), ([.key("RMB")], "Keyframe Menu")]
        }
        if dopeSheet == nil { dopeSheet = Self.find(content) { $0 is Kraken.DopeSheetView } }
        if Self.contains(dopeSheet, mouse)
        {
          return [([.click], "Select"), ([.drag], "Box Select"), ([.key("G")], "Move"), ([.key("S")], "Scale"),
                  ([.key("⇧"), .key("D")], "Duplicate"), ([.key("X")], "Delete"), ([.key("I")], "Insert Keyframe"),
                  ([.key("↑"), .key("↓")], "Jump to Keyframe"), ([.scroll], "Zoom"), ([.key("⌃"), .key("C")], "Copy"),
                  ([.key("⌃"), .key("V")], "Paste")]
        }
        if Self.contains(viewport, mouse)
        {
          let flags = NSEvent.modifierFlags
          if flags.contains(.shift) { return [([.click], "Extend"), ([.scroll], "Pan View"), ([.key("A")], "Add")] }
          if flags.contains(.control) { return [([.scroll], "Zoom View")] }
          if flags.contains(.option) { return [([.drag], "Rotate View")] }
          let navigation: [Hint] = [([.click], "Select"), ([.drag], "Box Select"), ([.scroll], "Rotate View")]
          guard let layout else { return navigation }
          if layout.mode == .edit
          {
            let any = !(layout.mesh?.verts.isEmpty ?? true)
            let loop: [Hint] = [([.key("⌥"), .click], "Select Loop")]
            guard any else { return navigation + loop + [([.key("A")], "Select All"), ([.key("⇥")], "Object Mode")] }
            return navigation + loop + [([.key("G")], "Move"), ([.key("E")], "Extrude"), ([.key("I")], "Inset"),
                                        ([.key("⌃"), .key("R")], "Loop Cut"), ([.key("X")], "Delete"),
                                        ([.key("⌥"), .key("A")], "Deselect All"), ([.key("⇥")], "Object Mode")]
          }

          guard !layout.selection.isEmpty else
          {
            return navigation + [([.key("⇧"), .key("A")], "Add"), ([.key("A")], "Select All")]
          }

          return navigation + [([.key("G")], "Move"), ([.key("R")], "Rotate"), ([.key("S")], "Scale"),
                               ([.key("I")], "Insert Keyframe"),
                               ([.key("X")], "Delete"), ([.key("⇧"), .key("D")], "Duplicate"),
                               ([.key("⌥"), .key("A")], "Deselect All"), ([.key("⇥")], "Edit Mode")]
        }

        return [([.key("F12")], "Render Image"), ([.key("⌃F12")], "Render Animation"), ([.key("F11")], "View Render")]
      }

      @objc private func refresh()
      {
        var changed = false
        let next = currentHints()
        if next.map(\.label) != hints.map(\.label) || next.count != hints.count
        {
          hints = next
          changed = true
        }

        if tick % 10 == 0
        {
          let text = "Memory: \(Self.gibibytes(Self.footprint)) | VRAM: \(Self.gibibytes(UInt64(device?.currentAllocatedSize ?? 0))) | Akari \(Akari.version)"
          if text != memory
          {
            memory = text
            changed = true
          }
        }

        tick += 1
        if changed { needsDisplay = true }
      }

      private func drawMouse(at x: CGFloat, _ glyph: Glyph) -> CGFloat
      {
        let body = NSRect(x: x, y: 5, width: 8, height: 12)
        let outline = NSBezierPath(roundedRect: body, xRadius: 4, yRadius: 4)
        Self.ink.setStroke()
        outline.lineWidth = 1
        outline.stroke()
        switch glyph
        {
          case .click, .drag:
            NSGraphicsContext.saveGraphicsState()
            outline.addClip()
            Self.ink.setFill()
            NSRect(x: x, y: 5, width: 4, height: 5).fill()
            NSGraphicsContext.restoreGraphicsState()
          case .scroll:
            Self.ink.setFill()
            NSBezierPath(roundedRect: NSRect(x: x + 3, y: 7, width: 2, height: 4), xRadius: 1, yRadius: 1).fill()
          case .key:
            break
        }

        guard case .drag = glyph else { return x + 10 }
        let arrows = NSBezierPath()
        arrows.move(to: NSPoint(x: x + 10, y: 8))
        arrows.line(to: NSPoint(x: x + 14, y: 8))
        arrows.move(to: NSPoint(x: x + 10, y: 14))
        arrows.line(to: NSPoint(x: x + 14, y: 14))
        arrows.move(to: NSPoint(x: x + 12, y: 6))
        arrows.line(to: NSPoint(x: x + 14, y: 8))
        arrows.line(to: NSPoint(x: x + 12, y: 10))
        arrows.move(to: NSPoint(x: x + 12, y: 12))
        arrows.line(to: NSPoint(x: x + 10, y: 14))
        arrows.line(to: NSPoint(x: x + 12, y: 16))
        arrows.lineWidth = 1
        arrows.stroke()
        return x + 16
      }

      private func drawKey(at x: CGFloat, _ name: String) -> CGFloat
      {
        let size = (name as NSString).size(withAttributes: Self.keyText)
        let cap = NSRect(x: x, y: 4, width: max(size.width + 6, 14), height: 14)
        Self.ink.setStroke()
        let path = NSBezierPath(roundedRect: cap.insetBy(dx: 0.5, dy: 0.5), xRadius: 3, yRadius: 3)
        path.lineWidth = 1
        path.stroke()
        (name as NSString).draw(at: NSPoint(x: cap.midX - size.width / 2, y: cap.midY - size.height / 2), withAttributes: Self.keyText)
        return cap.maxX + 2
      }

      override func draw(_: NSRect)
      {
        Self.background.setFill()
        bounds.fill()

        var x: CGFloat = 8
        for hint in hints
        {
          for glyph in hint.glyphs
          {
            if case let .key(name) = glyph { x = drawKey(at: x, name) } else { x = drawMouse(at: x, glyph) }
          }

          let label = hint.label as NSString
          let size = label.size(withAttributes: Self.text)
          label.draw(at: NSPoint(x: x + 2, y: (Self.height - size.height) / 2), withAttributes: Self.text)
          x += size.width + 16
        }

        let size = (memory as NSString).size(withAttributes: Self.digits)
        (memory as NSString).draw(at: NSPoint(x: bounds.width - size.width - 10, y: (Self.height - size.height) / 2),
                                  withAttributes: Self.digits)
      }
    }
  #endif
}

#if os(macOS)
  extension Kraken.StatusBar: NSViewRepresentable
  {
    func makeNSView(context _: Context) -> Kraken.StatusView
    {
      let view = Kraken.StatusView(frame: .zero)
      view.layout = layout
      return view
    }

    func updateNSView(_: Kraken.StatusView, context _: Context)
    {}

    func sizeThatFits(_ proposal: ProposedViewSize, nsView _: Kraken.StatusView, context _: Context) -> ViewSize
    {
      ViewSize(proposal.width ?? 800, Double(Kraken.StatusView.height))
    }

    static func dismantleNSView(_ nsView: Kraken.StatusView, coordinator _: Void)
    {
      MainActor.assumeIsolated { nsView.stop() }
    }
  }
#else
  extension Kraken.StatusBar: View
  {
    var body: some View
    {
      EmptyView()
    }
  }
#endif
