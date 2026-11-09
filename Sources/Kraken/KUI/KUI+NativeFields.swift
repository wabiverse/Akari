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
import SwiftCrossUI
#if os(macOS)
  import AppKit
  import AppKitBackend
#endif

extension Kraken
{
  #if os(macOS)
    struct NativePassepartout: NSViewRepresentable
    {
      let aspect: () -> Double

      func makeNSView(context _: Context) -> PassepartoutView
      {
        PassepartoutView()
      }

      func updateNSView(_ view: PassepartoutView, context _: Context)
      {
        view.aspect = aspect()
        view.needsDisplay = true
      }

      func sizeThatFits(_ proposal: ProposedViewSize, nsView _: PassepartoutView, context _: Context) -> ViewSize
      {
        ViewSize(proposal.width ?? 0, proposal.height ?? 0)
      }
    }

    /// Drawn over the viewport, clicks pass through to it.
    final class PassepartoutView: NSView
    {
      var aspect = 16.0 / 9.0

      override func hitTest(_: NSPoint) -> NSView?
      {
        nil
      }

      override func draw(_: NSRect)
      {
        guard bounds.width > 0, bounds.height > 0 else { return }
        let height = bounds.height * Akari.CameraView.frameHeight(viewAspect: bounds.width / bounds.height, aspect: aspect)
        let width = height * aspect
        let frame = NSRect(x: (bounds.width - width) / 2, y: (bounds.height - height) / 2, width: width, height: height)

        let outside = NSBezierPath(rect: bounds)
        outside.append(NSBezierPath(rect: frame))
        outside.windingRule = .evenOdd
        NSColor(white: 0, alpha: 0.5).setFill()
        outside.fill()

        let border = NSBezierPath(rect: frame.insetBy(dx: -0.5, dy: -0.5))
        border.lineWidth = 1
        NSColor(white: 0, alpha: 1).setStroke()
        border.stroke()
      }
    }

    struct NativeNumberField: NSViewRepresentable
    {
      let value: Binding<Double>
      let range: ClosedRange<Double>
      let step: Double
      let format: (Double) -> String
      let label: String
      let width: Int
      let live: Bool
      var key: KeyTarget?

      func makeNSView(context _: Context) -> NumberView
      {
        NumberView()
      }

      func updateNSView(_ view: NumberView, context _: Context)
      {
        view.read = live ? { value.wrappedValue } : nil
        view.value = value.wrappedValue
        view.range = range
        view.step = step
        view.format = format
        view.label = label
        view.onChange = { value.wrappedValue = $0 }
        view.keyTarget = key
        view.needsDisplay = true
      }

      func sizeThatFits(_: ProposedViewSize, nsView _: NumberView, context _: Context) -> ViewSize
      {
        ViewSize(Double(width), Double(Properties.rowHeight))
      }
    }

    /// Drags scrub by a step every few points, shift drags finely,
    /// a click without a drag swaps in a text field to type into.
    final class NumberView: NSView, NSTextFieldDelegate
    {
      var value = 0.0
      var range = -1e9 ... 1e9
      var step = 1.0
      var format: (Double) -> String = { "\($0)" }
      var label = ""
      var onChange: (Double) -> Void = { _ in }
      /// The property to key when I is pressed over this field.
      var keyTarget: KeyTarget?
      var read: (() -> Double)?
      {
        didSet { ticker.run(read != nil && window != nil) { [weak self] in self?.poll() } }
      }

      private let ticker = Ticker()
      private var hovered = false
      private var drag: (x: CGFloat, value: Double, moved: Bool)?
      private var editor: NSTextField?
      private var cancelled = false
      private var trackingArea: NSTrackingArea?

      private static let field = NSColor(white: 0.33, alpha: 1)
      private static let fieldHover = NSColor(white: 0.4, alpha: 1)
      private static let editing = NSColor(white: 0.157, alpha: 1)
      private static let text: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11),
        .foregroundColor: NSColor(white: 0.9, alpha: 1),
      ]
      private static let arrow: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13),
        .foregroundColor: NSColor(white: 0.9, alpha: 1),
      ]

      override var isFlipped: Bool
      {
        true
      }

      override func acceptsFirstMouse(for _: NSEvent?) -> Bool
      {
        true
      }

      override func viewDidMoveToWindow()
      {
        super.viewDidMoveToWindow()
        ticker.run(read != nil && window != nil) { [weak self] in self?.poll() }
      }

      private func poll()
      {
        guard let read, editor == nil, drag == nil else { return }
        let now = read()
        guard now != value else { return }
        value = now
        needsDisplay = true
      }

      override func updateTrackingAreas()
      {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
      }

      override func mouseEntered(with _: NSEvent)
      {
        hovered = true
        if let keyTarget { Keyframes.hovered = keyTarget }
        needsDisplay = true
      }

      override func mouseExited(with _: NSEvent)
      {
        hovered = false
        if keyTarget != nil, Keyframes.hovered == keyTarget { Keyframes.hovered = nil }
        needsDisplay = true
      }

      override func mouseDown(with event: NSEvent)
      {
        guard editor == nil else { return }
        let x = convert(event.locationInWindow, from: nil).x
        let arrow = CGFloat(SliderMetrics.arrow)
        if x < arrow || x > bounds.width - arrow
        {
          drag = nil
          set(value + (x < arrow ? -step : step))
          return
        }

        drag = (x, value, false)
      }

      override func mouseDragged(with event: NSEvent)
      {
        guard var drag else { return }
        let dx = convert(event.locationInWindow, from: nil).x - drag.x
        guard drag.moved || abs(dx) > 3 else { return }
        drag.moved = true
        self.drag = drag
        let fine = event.modifierFlags.contains(.shift) ? 0.1 : 1
        set(drag.value + (Double(dx) / 4).rounded(.towardZero) * step * fine)
      }

      override func mouseUp(with _: NSEvent)
      {
        if let drag, !drag.moved { beginEditing() }
        drag = nil
        needsDisplay = true
      }

      private func beginEditing()
      {
        let field = NSTextField(frame: NSRect(x: 6, y: (bounds.height - 15) / 2, width: bounds.width - 12, height: 15))
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: 11)
        field.textColor = NSColor(white: 0.9, alpha: 1)
        field.stringValue = step >= 1 && value == value.rounded() ? "\(Int(value))" : String(format: "%g", value)
        field.delegate = self
        addSubview(field)
        editor = field
        cancelled = false
        needsDisplay = true
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
      }

      func controlTextDidEndEditing(_: Notification)
      {
        guard let editor else { return }
        self.editor = nil
        editor.delegate = nil
        editor.removeFromSuperview()
        if !cancelled, let typed = NumberField.parse(editor.stringValue) { set(typed) }
        needsDisplay = true
      }

      func control(_: NSControl, textView _: NSTextView, doCommandBy selector: Selector) -> Bool
      {
        guard selector == #selector(NSResponder.cancelOperation(_:)) else { return false }
        cancelled = true
        window?.makeFirstResponder(nil)
        return true
      }

      private func set(_ v: Double)
      {
        let clamped = min(max(v, range.lowerBound), range.upperBound)
        guard clamped != value else { return }
        value = clamped
        needsDisplay = true
        onChange(clamped)
      }

      override func draw(_: NSRect)
      {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4)
        (editor != nil ? Self.editing : hovered ? Self.fieldHover : Self.field).setFill()
        shape.fill()
        guard editor == nil else { return }

        let text = format(value) as NSString
        let size = text.size(withAttributes: Self.text)
        if label.isEmpty
        {
          text.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                    withAttributes: Self.text)
        }
        else
        {
          let inset = CGFloat(SliderMetrics.arrow)
          (label as NSString).draw(at: NSPoint(x: inset, y: (bounds.height - size.height) / 2), withAttributes: Self.text)
          text.draw(at: NSPoint(x: bounds.width - inset - size.width, y: (bounds.height - size.height) / 2),
                    withAttributes: Self.text)
        }

        guard hovered, drag?.moved != true else { return }
        let arrow = CGFloat(SliderMetrics.arrow)
        for (glyph, x) in [("‹", CGFloat(0)), ("›", bounds.width - arrow)]
        {
          let g = glyph as NSString
          let s = g.size(withAttributes: Self.arrow)
          g.draw(at: NSPoint(x: x + (arrow - s.width) / 2, y: (bounds.height - s.height) / 2), withAttributes: Self.arrow)
        }
      }
    }

    struct NativeTextField: NSViewRepresentable
    {
      let text: Binding<String>
      let width: Double

      func makeNSView(context _: Context) -> TextBoxView
      {
        TextBoxView()
      }

      func updateNSView(_ view: TextBoxView, context _: Context)
      {
        view.onChange = { text.wrappedValue = $0 }
        if view.field.currentEditor() == nil, view.field.stringValue != text.wrappedValue
        {
          view.field.stringValue = text.wrappedValue
        }
      }

      func sizeThatFits(_: ProposedViewSize, nsView _: TextBoxView, context _: Context) -> ViewSize
      {
        ViewSize(width, Double(Properties.rowHeight))
      }
    }

    /// A dark, borderless text field in a rounded box.
    final class TextBoxView: NSView, NSTextFieldDelegate
    {
      let field = NSTextField()
      var onChange: (String) -> Void = { _ in }

      override var isFlipped: Bool
      {
        true
      }

      init()
      {
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 4
        layer?.backgroundColor = NSColor(white: 0.157, alpha: 1).cgColor
        field.isBordered = false
        field.drawsBackground = false
        field.focusRingType = .none
        field.font = NSFont.systemFont(ofSize: 11)
        field.textColor = NSColor(white: 0.9, alpha: 1)
        field.lineBreakMode = .byTruncatingHead
        field.cell?.usesSingleLineMode = true
        field.delegate = self
        addSubview(field)
      }

      @available(*, unavailable)
      required init?(coder _: NSCoder)
      {
        fatalError()
      }

      override func layout()
      {
        super.layout()
        field.frame = NSRect(x: 6, y: (bounds.height - 15) / 2, width: bounds.width - 12, height: 15)
      }

      func controlTextDidChange(_: Notification)
      {
        onChange(field.stringValue)
      }
    }

    struct NativeColorWell: NSViewRepresentable
    {
      let color: Binding<SIMD3<Float>>
      let width: Double
      var key: KeyTarget?

      func makeNSView(context _: Context) -> SwatchView
      {
        SwatchView()
      }

      func updateNSView(_ view: SwatchView, context _: Context)
      {
        view.onChange = { color.wrappedValue = $0 }
        view.keyTarget = key
        let c = color.wrappedValue
        let ns = NSColor(srgbRed: CGFloat(c.x), green: CGFloat(c.y), blue: CGFloat(c.z), alpha: 1)
        if view.well.color != ns { view.well.color = ns }
      }

      func sizeThatFits(_: ProposedViewSize, nsView _: SwatchView, context _: Context) -> ViewSize
      {
        ViewSize(width, Double(Properties.rowHeight))
      }
    }

    final class SwatchView: NSView
    {
      let well = NSColorWell(style: .minimal)
      var onChange: (SIMD3<Float>) -> Void = { _ in }
      /// The property to key when I is pressed over this field.
      var keyTarget: KeyTarget?

      override func updateTrackingAreas()
      {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                       owner: self, userInfo: nil))
      }

      override func mouseEntered(with _: NSEvent)
      {
        if let keyTarget { Keyframes.hovered = keyTarget }
      }

      override func mouseExited(with _: NSEvent)
      {
        if keyTarget != nil, Keyframes.hovered == keyTarget { Keyframes.hovered = nil }
      }

      override var isFlipped: Bool
      {
        true
      }

      init()
      {
        super.init(frame: .zero)
        well.target = self
        well.action = #selector(changed)
        addSubview(well)
      }

      @available(*, unavailable)
      required init?(coder _: NSCoder)
      {
        fatalError()
      }

      override func layout()
      {
        super.layout()
        well.frame = bounds
      }

      @objc private func changed()
      {
        guard let c = well.color.usingColorSpace(.sRGB) else { return }
        onChange(SIMD3(Float(c.redComponent), Float(c.greenComponent), Float(c.blueComponent)))
      }
    }

    final class SymbolView: NSImageView
    {
      var symbol: String?
    }

    /// Calls back about thirty times a second while running, for
    /// views that follow playback without a SwiftUI style update.
    final class Ticker
    {
      private var timer: Timer?

      func run(_ running: Bool, _ tick: @escaping @MainActor () -> Void)
      {
        guard running != (timer != nil) else { return }
        timer?.invalidate()
        timer = nil
        guard running else { return }
        let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { _ in MainActor.assumeIsolated { tick() } }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
      }

      deinit
      {
        timer?.invalidate()
      }
    }

    struct NativeSymbol: NSViewRepresentable
    {
      let name: () -> String
      let size: Double
      let white: Double

      func makeNSView(context _: Context) -> SymbolView
      {
        let view = SymbolView()
        view.imageScaling = .scaleProportionallyDown
        return view
      }

      func updateNSView(_ view: SymbolView, context _: Context)
      {
        let name = name()
        guard name != view.symbol else { return }
        view.symbol = name
        let config = NSImage.SymbolConfiguration(pointSize: size, weight: .regular)
        view.image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config)
        view.contentTintColor = NSColor(white: white, alpha: 1)
      }

      func sizeThatFits(_: ProposedViewSize, nsView _: SymbolView, context _: Context) -> ViewSize
      {
        ViewSize(size + 4, size + 4)
      }
    }
  #endif
}
