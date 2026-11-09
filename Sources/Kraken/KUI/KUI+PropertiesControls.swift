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

import HydraKit
import SwiftCrossUI
#if os(macOS)
  import AppKit
  import AppKitBackend
#endif

extension Kraken
{
  /// An enum menu, a dark field lists its options beneath it.
  @MainActor
  struct Dropdown<Value: Equatable>: View
  {
    let options: [Value]
    let selection: Binding<Value?>

    @State private var open = false
    @State private var hovered = false

    init(options: [Value], selection: Binding<Value?>)
    {
      self.options = options
      self.selection = selection
    }

    var body: some View
    {
      VStack(alignment: .leading, spacing: 2)
      {
        HStack(spacing: 0)
        {
          Text(selection.wrappedValue.map { "\($0)" } ?? "")
            .font(Properties.font)
            .foregroundColor(Properties.text)
            .frame(minWidth: 0.0, maxWidth: .infinity, alignment: .leading)
          DisclosureChevron(expanded: true)
            .stroke(Properties.label, style: StrokeStyle(width: 1.2))
            .frame(width: 8, height: 8)
        }
        .padding(.horizontal, 7)
        .frame(width: Double(Properties.controlWidth), height: Double(Properties.rowHeight))
        .background(RoundedRectangle(cornerRadius: 4).fill(hovered || open ? Properties.menuHover : Properties.menu))
        .onHover { hovered = $0 }
        .onTapGesture { open.toggle() }

        if open
        {
          VStack(alignment: .leading, spacing: 0)
          {
            ForEach(Array(options.indices), id: \.self)
            { i in
              DropdownOption(title: "\(options[i])", selected: selection.wrappedValue == options[i])
                .onTapGesture
                {
                  selection.wrappedValue = options[i]
                  open = false
                }
            }
          }
          .padding(3)
          .background(RoundedRectangle(cornerRadius: 4).fill(Properties.menu))
        }
      }
    }
  }

  @MainActor
  struct DropdownOption: View
  {
    let title: String
    let selected: Bool

    @State private var hovered = false

    init(title: String, selected: Bool)
    {
      self.title = title
      self.selected = selected
    }

    var body: some View
    {
      VStack(spacing: 0)
      {
        Text(title)
          .font(Properties.font)
          .foregroundColor(Properties.text)
          .padding(.horizontal, 6)
          .frame(width: Double(Properties.controlWidth - 6), height: Double(Properties.rowHeight), alignment: .leading)
          .background(RoundedRectangle(cornerRadius: 3)
            .fill(hovered ? Properties.accent : selected ? Properties.menuHover : Color.clear))
          .onHover { hovered = $0 }
      }
    }
  }

  /// A checkbox with its label to the right,
  /// with the whole view being clickable.
  @MainActor
  struct Checkbox: View
  {
    let label: String
    let isOn: Binding<Bool>

    var body: some View
    {
      HStack(spacing: 6)
      {
        CheckboxBox(isOn: isOn)
        Text(label)
          .font(Properties.font)
          .foregroundColor(Properties.text)
          .onTapGesture { isOn.wrappedValue.toggle() }
      }
    }
  }

  @MainActor
  struct CheckboxBox: View
  {
    let isOn: Binding<Bool>

    @State private var hovered = false

    init(isOn: Binding<Bool>)
    {
      self.isOn = isOn
    }

    var body: some View
    {
      let fill = isOn.wrappedValue ? Properties.accent : hovered ? Properties.fieldHover : Properties.field
      return VStack(spacing: 0)
      {
        RoundedRectangle(cornerRadius: 3)
          .fill(fill)
          .frame(width: 14, height: 14)
          .overlay
          {
            if isOn.wrappedValue
            {
              CheckMark()
                .stroke(Color(white: 1), style: StrokeStyle(width: 1.6))
                .frame(width: 8, height: 7)
            }
          }
          .onHover { hovered = $0 }
          .onTapGesture { isOn.wrappedValue.toggle() }
      }
    }
  }

  /// A chevron pointing right when
  /// collapsed, down when expanded.
  struct DisclosureChevron: Shape
  {
    var expanded: Bool

    nonisolated func path(in bounds: Path.Rect) -> Path
    {
      expanded
        ? Path()
        .move(to: SIMD2(bounds.x, bounds.y + bounds.height * 0.25))
        .addLine(to: SIMD2(bounds.center.x, bounds.y + bounds.height * 0.75))
        .addLine(to: SIMD2(bounds.maxX, bounds.y + bounds.height * 0.25))
        : Path()
        .move(to: SIMD2(bounds.x + bounds.width * 0.25, bounds.y))
        .addLine(to: SIMD2(bounds.x + bounds.width * 0.75, bounds.center.y))
        .addLine(to: SIMD2(bounds.x + bounds.width * 0.25, bounds.maxY))
    }
  }

  struct CheckMark: Shape
  {
    nonisolated func path(in bounds: Path.Rect) -> Path
    {
      Path()
        .move(to: SIMD2(bounds.x, bounds.center.y))
        .addLine(to: SIMD2(bounds.x + bounds.width * 0.38, bounds.maxY))
        .addLine(to: SIMD2(bounds.maxX, bounds.y))
    }
  }
}
