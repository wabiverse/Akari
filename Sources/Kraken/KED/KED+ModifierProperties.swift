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
import CxxStdlib
import Foundation
import HdAkari
import HydraKit
import simd
import SwiftCrossUI

extension Kraken
{
  /// the modifiers properties, the stack the active mesh carries
  @MainActor
  struct ModifierProperties: View
  {
    @State private var inspector: Inspector
    @State private var adding: String?

    init(inspector: Inspector)
    {
      _inspector = State(wrappedValue: inspector)
    }

    private var kinds: [String]
    {
      Modifiers.Kind.allCases.map(\.title)
    }

    var body: some View
    {
      ScrollView
      {
        VStack(alignment: .leading, spacing: 4)
        {
          Properties.row("Name") { Readout(inspector.name) }
          Properties.row("Add Modifier")
          {
            Dropdown(options: kinds, selection: $adding.onChange
            { title in
              guard let kind = Modifiers.Kind.allCases.first(where: { $0.title == title }) else { return }

              inspector.addModifier(kind)
              adding = nil
            })
          }

          if inspector.modifiers.isEmpty
          {
            note("the stack is empty, add one above")
          }

          ForEach(Array(inspector.modifiers.indices), id: \.self)
          { i in
            panel(inspector.modifiers[i], at: i)
          }
        }
        .padding(6)
      }
    }

    @ViewBuilder
    private func panel(_ entry: Modifiers.Entry, at i: Int) -> some View
    {
      let baked = inspector.appliedModifiers.contains(entry.name)
      let title = baked ? "\(entry.name) (applied)" : entry.name

      PropertiesPanel(title, toggle: inspector.modifierShown(entry.name, render: false))
      {
        Properties.row("Type") { Readout(entry.kind.title) }
        Properties.check("Show in Renders", inspector.modifierShown(entry.name, render: true))

        ForEach(Array(entry.kind.parameters.indices), id: \.self)
        { p in
          row(entry, entry.kind.parameters[p])
        }

        buttons(entry, at: i, baked: baked)
        note(baked ? "baked into the mesh, written out when the scene is saved" : entry.kind.note)
      }
    }

    @ViewBuilder
    private func row(_ entry: Modifiers.Entry, _ parameter: Modifiers.Parameter) -> some View
    {
      switch parameter.control
      {
        case let .whole(range):
          Properties.row(parameter.label)
          {
            SliderField(value: inspector.modifierNumber(entry.name, parameter), range: range, step: 1)
            { "\(Int($0))" }
          }
        case let .factor(range):
          Properties.row(parameter.label)
          {
            SliderField(value: inspector.modifierNumber(entry.name, parameter), range: range, step: 0.01)
            { String(format: "%.2f", $0) }
          }
        case let .distance(range):
          Properties.row(parameter.label)
          {
            NumberField(value: inspector.modifierNumber(entry.name, parameter), range: range, step: 0.001, live: true)
            { String(format: "%.4g", $0) }
          }
        case let .vector(range):
          VStack(alignment: .leading, spacing: 2)
          {
            ForEach([0, 1, 2], id: \.self)
            { k in
              Properties.row(k == 0 ? parameter.label : "")
              {
                NumberField(value: inspector.modifierNumber(entry.name, parameter, k), range: range, step: 0.01,
                            label: ["X", "Y", "Z"][k], live: true)
                { String(format: "%.4g", $0) }
              }
            }
          }
        case .toggle:
          Properties.check(parameter.label, inspector.modifierFlag(entry.name, parameter))
        case let .choice(labels):
          Properties.row(parameter.label)
          {
            Dropdown(options: labels, selection: inspector.modifierChoice(entry.name, parameter, labels))
          }
      }
    }

    @ViewBuilder
    private func buttons(_ entry: Modifiers.Entry, at i: Int, baked: Bool) -> some View
    {
      HStack(spacing: 4)
      {
        Spacer().frame(width: Double(Properties.labelWidth))
        IconButton("chevron.up", enabled: i > 0) { inspector.moveModifier(entry.name, up: false) }
        IconButton("chevron.down", enabled: i < inspector.modifiers.count - 1) { inspector.moveModifier(entry.name, up: true) }
        IconButton("checkmark.circle", enabled: !baked && inspector.appliable == entry.name)
        {
          inspector.applyModifier(entry.name)
        }

        IconButton("trash", enabled: !baked) { inspector.removeModifier(entry.name) }
        Spacer()
      }
    }

    private func note(_ text: String) -> some View
    {
      HStack(spacing: 8)
      {
        Spacer().frame(width: Double(Properties.labelWidth))
        Text(text)
          .font(.system(size: 10))
          .foregroundColor(Color(white: 0.55))
      }
    }
  }
}
