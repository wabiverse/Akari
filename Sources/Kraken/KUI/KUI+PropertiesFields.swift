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
    /// The property to key when I is pressed over this field.
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
    /// The property to key when I is pressed over this field.
    var key: KeyTarget?

    var body: some View
    {
      VStack(spacing: 0)
      {
        #if os(macOS)
          NativeColorWell(color: color, width: Double(Properties.controlWidth), key: key)
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

  /// A value shown as text in the control column.
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
