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

extension AkariDemo
{
  /// Properties editor, with a dark theme and widget metrics.
  enum Properties
  {
    static let region = Color(white: 0.188)
    static let tabs = Color(white: 0.137)
    static let tabButtonWhite = 0.169
    static let tabActiveWhite = 0.259
    static let tabButton = Color(white: tabButtonWhite)
    static let tabActive = Color(white: tabActiveWhite)
    static let panel = Color(white: 0.24)
    static let subpanel = Color(white: 0.215)
    static let field = Color(white: 0.349)
    static let fieldHover = Color(white: 0.41)
    static let menu = Color(white: 0.169)
    static let popup = Color(white: 0.11)
    static let menuHover = Color(white: 0.22)
    static let accent = Color(red: 0.278, green: 0.447, blue: 0.702)
    static let text = Color(white: 0.894)
    static let label = Color(white: 0.79)
    static let width = 340
    static let labelWidth = 110
    static let controlWidth = 176
    static let rowHeight = 20
    static let font = Font.system(size: 11)

    /// A label in the left column, right
    /// aligned, beside its control.
    @MainActor
    static func row(_ label: String, @ViewBuilder _ control: () -> some View) -> some View
    {
      HStack(spacing: 8)
      {
        Text(label)
          .font(font)
          .foregroundColor(Self.label)
          .frame(width: Double(labelWidth), alignment: .trailing)
        control()
      }
    }

    /// A checkbox in the control column,
    /// for boolean properties.
    @MainActor
    static func check(_ label: String, _ isOn: Binding<Bool>) -> some View
    {
      HStack(spacing: 8)
      {
        Spacer().frame(width: Double(labelWidth))
        Checkbox(label: label, isOn: isOn)
      }
    }
  }

  /// A collapsible panel, its header optionally
  /// carrying the toggle that enables it.
  @MainActor
  struct PropertiesPanel<Content: View>: View
  {
    let title: String
    let toggle: Binding<Bool>?
    let nested: Bool
    let content: Content

    @State private var expanded: Bool

    init(_ title: String, expanded: Bool = true, toggle: Binding<Bool>? = nil, nested: Bool = false,
         @ViewBuilder content: () -> Content)
    {
      self.title = title
      self.toggle = toggle
      self.nested = nested
      self.content = content()
      _expanded = State(wrappedValue: expanded)
    }

    var body: some View
    {
      VStack(alignment: .leading, spacing: 0)
      {
        HStack(spacing: 6)
        {
          DisclosureChevron(expanded: expanded)
            .stroke(Properties.label, style: StrokeStyle(width: 1.3))
            .frame(width: 8, height: 8)
            .frame(width: 12, height: 22)
            .onTapGesture { expanded.toggle() }
          if let toggle
          {
            CheckboxBox(isOn: toggle)
          }

          Text(title)
            .font(.system(size: 11, weight: nested ? .regular : .medium))
            .foregroundColor(Properties.text)
            .frame(minWidth: 0.0, maxWidth: .infinity, alignment: .leading)
            .frame(height: 22)
            .onTapGesture { expanded.toggle() }
        }
        .padding(.horizontal, 6)

        if expanded
        {
          VStack(alignment: .leading, spacing: 4)
          {
            content
          }
          .padding(.horizontal, 6)
          .padding(.bottom, 8)
        }
      }
      .background(RoundedRectangle(cornerRadius: 4).fill(nested ? Properties.subpanel : Properties.panel))
    }
  }
}
