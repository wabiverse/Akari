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

extension AkariDemo
{
  /// A number field, the value centered in it. Drags scrub
  /// the value, the ends step it, and a click types a new
  /// one in.
  @MainActor
  struct NumberField: View
  {
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    let label: String
    let width: Int
    /// Polls the value itself, for one that changes every frame.
    let live: Bool

    init(value: Binding<Double>, range: ClosedRange<Double> = -1e9 ... 1e9, step: Double = 1, label: String = "",
         width: Int = Properties.controlWidth, live: Bool = false, format: @escaping (Double) -> String)
    {
      self.value = value
      self.range = range
      self.step = step
      self.format = format
      self.label = label
      self.width = width
      self.live = live
    }

    init(value: Binding<Int>, range: ClosedRange<Int> = -1_000_000_000 ... 1_000_000_000, unit: String = "",
         label: String = "", width: Int = Properties.controlWidth, live: Bool = false)
    {
      self.init(value: Binding(get: { Double(value.wrappedValue) }, set: { value.wrappedValue = Int($0.rounded()) }),
                range: Double(range.lowerBound) ... Double(range.upperBound), step: 1, label: label, width: width,
                live: live, format: { unit.isEmpty ? "\(Int($0))" : "\(Int($0)) \(unit)" })
    }

    var body: some View
    {
      VStack(spacing: 0)
      {
        #if os(macOS)
          NativeNumberField(value: value, range: range, step: step, format: format, label: label, width: width, live: live)
        #else
          TextField(label, text: Binding(get: { format(value.wrappedValue) },
                                         set: { text in NumberField.parse(text).map { value.wrappedValue = $0 } }))
            .font(Properties.font)
            .frame(width: Double(width))
        #endif
      }
    }

    /// The number a typed entry starts with, its unit ignored.
    nonisolated static func parse(_ text: String) -> Double?
    {
      let number = text.trimmingCharacters(in: .whitespaces).prefix { "0123456789.-+eE".contains($0) }
      return Double(number)
    }
  }

  /// Options side by side, the selected one highlighted.
  @MainActor
  struct Segmented<Value: Equatable & CustomStringConvertible>: View
  {
    let options: [Value]
    let selection: Binding<Value?>

    init(options: [Value], selection: Binding<Value?>)
    {
      self.options = options
      self.selection = selection
    }

    var body: some View
    {
      let width = Double(Properties.controlWidth - (options.count - 1)) / Double(max(options.count, 1))
      return HStack(spacing: 1)
      {
        ForEach(Array(options.indices), id: \.self)
        { i in
          Segment(title: "\(options[i])", selected: selection.wrappedValue == options[i], width: width)
            .onTapGesture { selection.wrappedValue = options[i] }
        }
      }
      .cornerRadius(4)
    }
  }

  @MainActor
  struct Segment: View
  {
    let title: String
    let selected: Bool
    let width: Double

    @State private var hovered = false

    init(title: String, selected: Bool, width: Double)
    {
      self.title = title
      self.selected = selected
      self.width = width
    }

    var body: some View
    {
      Text(title)
        .font(Properties.font)
        .foregroundColor(Properties.text)
        .frame(width: width, height: Double(Properties.rowHeight))
        .background(Rectangle().fill(selected ? Properties.accent : hovered ? Properties.fieldHover : Properties.field))
        .onHover { hovered = $0 }
    }
  }

  /// A file path the full width of the panel, a folder button picks its directory.
  @MainActor
  struct PathField: View
  {
    let text: Binding<String>

    var body: some View
    {
      let width = Double(Properties.labelWidth + 8 + Properties.controlWidth)
      return HStack(spacing: 4)
      {
        #if os(macOS)
          NativeTextField(text: text, width: width - 24)
        #else
          TextField("", text: text)
            .font(Properties.font)
            .frame(width: width - 24)
        #endif
        SymbolIcon("folder.fill", size: 11, white: 0.76)
          .frame(width: 20, height: Double(Properties.rowHeight))
          .background(RoundedRectangle(cornerRadius: 4).fill(Properties.field))
          .onTapGesture { chooseDirectory() }
      }
    }

    private func chooseDirectory()
    {
      #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        let current = (text.wrappedValue as NSString).expandingTildeInPath
        let name = current.hasSuffix("/") ? "" : (current as NSString).lastPathComponent
        panel.directoryURL = URL(fileURLWithPath: name.isEmpty ? current : (current as NSString).deletingLastPathComponent)
        guard panel.runModal() == .OK, let directory = panel.url else { return }
        text.wrappedValue = directory.path + "/" + name
      #endif
    }
  }

  /// A color swatch the width of a control, clicking it opens the color picker.
  @MainActor
  struct ColorField: View
  {
    let color: Binding<SIMD3<Float>>

    var body: some View
    {
      VStack(spacing: 0)
      {
        #if os(macOS)
          NativeColorWell(color: color, width: Double(Properties.controlWidth))
        #else
          Rectangle()
            .fill(Color(red: Double(color.wrappedValue.x), green: Double(color.wrappedValue.y), blue: Double(color.wrappedValue.z)))
            .frame(width: Double(Properties.controlWidth), height: Double(Properties.rowHeight))
        #endif
      }
    }
  }

  /// The picked prim's name, an eyedropper that picks
  /// one in the viewport, and a cross that clears it.
  @MainActor
  struct ObjectField: View
  {
    let name: String
    let picking: Bool
    let pick: () -> Void
    let clear: () -> Void

    var body: some View
    {
      HStack(spacing: 2)
      {
        HStack(spacing: 4)
        {
          SymbolIcon("cube.fill", size: 9, white: name.isEmpty ? 0.45 : 0.8)
          Text(name)
            .font(Properties.font)
            .foregroundColor(Properties.text)
          Spacer()
          if !name.isEmpty
          {
            SymbolIcon("xmark", size: 8, white: 0.7)
              .onTapGesture { clear() }
          }
        }
        .padding(.horizontal, 4)
        .frame(width: Double(Properties.controlWidth - 24), height: Double(Properties.rowHeight))
        .background(RoundedRectangle(cornerRadius: 4).fill(Properties.menu))
        SymbolIcon("eyedropper", size: 10, white: 0.85)
          .frame(width: 22, height: Double(Properties.rowHeight))
          .background(RoundedRectangle(cornerRadius: 4).fill(picking ? Properties.accent : Properties.field))
          .onTapGesture { pick() }
      }
    }
  }

  /// A gray SF Symbol, or its first letter where there are none,
  /// the name is read as the icon updates, AppKit's representables
  /// keep the values they were made with.
  @MainActor
  struct SymbolIcon: View
  {
    let name: () -> String
    let size: Double
    let white: Double

    init(_ name: @autoclosure @escaping () -> String, size: Double, white: Double)
    {
      self.name = name
      self.size = size
      self.white = white
    }

    var body: some View
    {
      VStack(spacing: 0)
      {
        #if os(macOS)
          NativeSymbol(name: name, size: size, white: white)
        #else
          Text(String(name().prefix(1)).uppercased())
            .font(.system(size: Int(size), weight: .semibold))
            .foregroundColor(Color(white: white))
        #endif
      }
    }
  }

  /// A sphere, a cube and a cone, tinted as the theme
  /// tints it, on a `background` gray it cuts gaps into.
  @MainActor
  struct SceneIcon: View
  {
    let size: Double
    let background: Double

    private static let tint = 0.8

    var body: some View
    {
      let shade = { (opacity: Double) in Color(white: background + (Self.tint - background) * opacity) }
      let gap = StrokeStyle(width: size * 0.1)
      return ZStack
      {
        ScenePart(kind: .sphere).fill(shade(0.6))
        ScenePart(kind: .cube).stroke(Color(white: background), style: gap)
        ScenePart(kind: .cube).fill(shade(0.8))
        ScenePart(kind: .cone).stroke(Color(white: background), style: gap)
        ScenePart(kind: .cone).fill(shade(1))
      }
      .frame(width: size, height: size)
    }
  }

  struct ScenePart: Shape
  {
    enum Kind
    {
      case sphere, cube, cone
    }

    let kind: Kind

    nonisolated func path(in bounds: Path.Rect) -> Path
    {
      let point = { (x: Double, y: Double) in SIMD2(bounds.x + x * bounds.width, bounds.y + y * bounds.height) }
      switch kind
      {
        case .sphere:
          return Path().addCircle(center: point(0.31, 0.31), radius: 0.25 * bounds.width)
        case .cube:
          let (l, t, r, b, k) = (0.24, 0.45, 0.74, 0.95, 0.12)
          return Path()
            .move(to: point(l + k, t))
            .addLine(to: point(r - k, t))
            .addQuadCurve(control: point(r, t), to: point(r, t + k))
            .addLine(to: point(r, b - k))
            .addQuadCurve(control: point(r, b), to: point(r - k, b))
            .addLine(to: point(l + k, b))
            .addQuadCurve(control: point(l, b), to: point(l, b - k))
            .addLine(to: point(l, t + k))
            .addQuadCurve(control: point(l, t), to: point(l + k, t))
        case .cone:
          return Path()
            .move(to: point(0.70, 0.08))
            .addLine(to: point(0.97, 0.62))
            .addLine(to: point(0.43, 0.62))
            .addLine(to: point(0.70, 0.08))
      }
    }
  }

  /// A ring's outline from the top, clockwise, `progress` of the way around.
  struct ProgressRing: Shape
  {
    var progress: Double

    nonisolated func path(in bounds: Path.Rect) -> Path
    {
      let center = bounds.center
      let radius = min(bounds.width, bounds.height) / 2
      let top = 1.5 * Double.pi
      let end = top + 2 * Double.pi * min(max(progress, 0), 1)
      let start = center + SIMD2(0, -radius)
      guard end > 2 * Double.pi
      else
      {
        return Path().move(to: start).addArc(center: center, radius: radius, startAngle: top, endAngle: end, clockwise: true)
      }
      return Path().move(to: start)
        .addArc(center: center, radius: radius, startAngle: top, endAngle: 2 * Double.pi, clockwise: true)
        .addArc(center: center, radius: radius, startAngle: 0, endAngle: end - 2 * Double.pi, clockwise: true)
    }
  }

  /// Reloads the stage, its outline filling in with the reload's progress.
  @MainActor
  struct ReloadButton: View
  {
    let reload: () -> Void
    /// Whether the reload is still running, and how far along.
    let status: () -> (pending: Bool, progress: Double)

    @State private var reloading = false
    @State private var progress: Double?
    @State private var hovered = false

    var body: some View
    {
      ZStack
      {
        SymbolIcon("arrow.clockwise", size: 8, white: 0.85)
        RoundedRectangle(cornerRadius: 2)
          .fill((hovered ? Properties.fieldHover : Properties.menu).opacity(progress == nil ? 0 : 1))
          .frame(width: 12, height: 12)
        ProgressRing(progress: 1)
          .stroke(Color(white: 0.45, opacity: progress == nil ? 0 : 1), style: StrokeStyle(width: 2.5))
          .frame(width: 14, height: 14)
        ProgressRing(progress: progress ?? 0)
          .stroke(Properties.accent.opacity(progress == nil ? 0 : 1), style: StrokeStyle(width: 2.5, cap: .round))
          .frame(width: 14, height: 14)
      }
      .frame(width: 24, height: 20)
      .background(RoundedRectangle(cornerRadius: 4).fill(hovered ? Properties.fieldHover : Properties.menu))
      .onHover { hovered = $0 }
      .onTapGesture
      {
        guard !reloading else { return }
        reloading = true
        progress = 0
        reload()
      }
      .task(id: reloading)
      {
        guard reloading else { return }
        try? await Task.sleep(for: .milliseconds(30))
        while status().pending
        {
          progress = status().progress
          try? await Task.sleep(for: .milliseconds(33))
        }
        progress = 1
        try? await Task.sleep(for: .milliseconds(250))
        progress = nil
        reloading = false
      }
    }
  }

  /// The viewport dimmed outside the camera's render frame.
  @MainActor
  struct Passepartout: View
  {
    let aspect: () -> Double

    init(aspect: @autoclosure @escaping () -> Double)
    {
      self.aspect = aspect
    }

    var body: some View
    {
      VStack(spacing: 0)
      {
        #if os(macOS)
          NativePassepartout(aspect: aspect)
        #endif
      }
    }
  }

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
        needsDisplay = true
      }

      override func mouseExited(with _: NSEvent)
      {
        hovered = false
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

      func makeNSView(context _: Context) -> SwatchView
      {
        SwatchView()
      }

      func updateNSView(_ view: SwatchView, context _: Context)
      {
        view.onChange = { color.wrappedValue = $0 }
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
