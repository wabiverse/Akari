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
#else
  import UIKit
#endif

extension Kraken
{
  /// a number field with the value centered, drags scrub it, the ends step it and a click types a new one
  @MainActor
  struct NumberField: View
  {
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String
    let label: String
    let width: Int
    /// polls the value itself, for one that changes every frame.
    let live: Bool
    /// the property to key when i is pressed over this field.
    var key: KeyTarget?

    init(value: Binding<Double>, range: ClosedRange<Double> = -1e9 ... 1e9, step: Double = 1, label: String = "",
         width: Int = Properties.controlWidth, live: Bool = false, key: KeyTarget? = nil,
         format: @escaping (Double) -> String)
    {
      self.key = key
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
          NativeNumberField(value: value, range: range, step: step, format: format, label: label, width: width, live: live,
                            key: key)
        #else
          TextField(label, text: Binding(get: { shownText }, set: { type($0) }))
            .font(Properties.font)
            .frame(width: Double(width))
            .onSubmit { draft = nil }
        #endif
      }
    }

    /// the number a typed entry starts with, its unit ignored and held in `range`, nil until it is a finite number
    nonisolated static func parse(_ text: String, in range: ClosedRange<Double>) -> Double?
    {
      let number = text.trimmingCharacters(in: .whitespaces).prefix { "0123456789.-+eE".contains($0) }
      guard let typed = Double(number), typed.isFinite else { return nil }
      return min(max(typed, range.lowerBound), range.upperBound)
    }

    #if !os(macOS)
      /// what's being typed, kept while it still reads as the value so a trailing point or a lone minus sign survives.
      @State private var draft: String?

      private var shownText: String
      {
        guard let draft else { return format(value.wrappedValue) }
        let typed = Self.parse(draft, in: range)
        return typed == nil || typed == value.wrappedValue ? draft : format(value.wrappedValue)
      }

      private func type(_ text: String)
      {
        draft = text
        if let typed = Self.parse(text, in: range), typed != value.wrappedValue { value.wrappedValue = typed }
      }
    #endif
  }

  /// options side by side, the selected one highlighted.
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

  /// a file path the full width of the panel, a folder button picks its directory.
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

  /// a color swatch the width of a control, clicking it opens the color picker.
  @MainActor
  struct ColorField: View
  {
    let color: Binding<SIMD3<Float>>
    /// the property to key when i is pressed over this field.
    var key: KeyTarget?

    var body: some View
    {
      VStack(spacing: 0)
      {
        #if os(macOS)
          NativeColorWell(color: color, width: Double(Properties.controlWidth), key: key)
        #else
          NativeView(make: { SwatchView() },
                     update: { [color] view in view.show(color.wrappedValue) { color.wrappedValue = $0 } },
                     size: { _ in ViewSize(Double(Properties.controlWidth), Double(Properties.rowHeight)) })
        #endif
      }
    }
  }

  #if !os(macOS)
    /// a swatch that opens the system color picker when tapped.
    final class SwatchView: UIView
    {
      private let well = UIColorWell()
      private let swatch = UIView()
      private var onChange: (SIMD3<Float>) -> Void = { _ in }

      init()
      {
        super.init(frame: .zero)
        swatch.layer.cornerRadius = 4
        swatch.isUserInteractionEnabled = false
        well.supportsAlpha = false

        // the well is see through over the swatch, so the whole row opens the picker.
        well.alpha = 0.02
        well.addTarget(self, action: #selector(picked), for: .valueChanged)
        addSubview(swatch)
        addSubview(well)
      }

      @available(*, unavailable)
      required init?(coder _: NSCoder)
      {
        fatalError("init(coder:) is not supported")
      }

      override func layoutSubviews()
      {
        super.layoutSubviews()
        swatch.frame = bounds
        well.frame = bounds
      }

      func show(_ color: SIMD3<Float>, onChange: @escaping (SIMD3<Float>) -> Void)
      {
        self.onChange = onChange
        let shown = UIColor(red: CGFloat(color.x), green: CGFloat(color.y), blue: CGFloat(color.z), alpha: 1)
        swatch.backgroundColor = shown
        if well.selectedColor != shown { well.selectedColor = shown }
      }

      @objc private func picked()
      {
        guard let color = well.selectedColor else { return }
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        guard color.getRed(&r, green: &g, blue: &b, alpha: &a) else { return }
        swatch.backgroundColor = color
        onChange(SIMD3(Float(r), Float(g), Float(b)))
      }
    }
  #endif

  /// the picked prim's name, an eyedropper to pick one in the viewport and a cross to clear it
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

  /// a value shown as text in the control column.
  @MainActor
  struct Readout: View
  {
    let text: String

    init(_ text: String)
    {
      self.text = text
    }

    var body: some View
    {
      Text(text)
        .font(Properties.font)
        .foregroundColor(Properties.label)
        .frame(width: Double(Properties.controlWidth), alignment: .leading)
    }
  }
}
