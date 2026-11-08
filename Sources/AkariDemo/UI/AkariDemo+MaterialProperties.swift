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
import protocol SwiftCrossUI.ObservableObject
import class SwiftCrossUI.Published

extension AkariDemo
{
  /// The Material properties, the surface the active geometry is bound to.
  @MainActor
  struct MaterialProperties: View
  {
    @State private var inspector: Inspector

    init(inspector: Inspector)
    {
      _inspector = State(wrappedValue: inspector)
    }

    var body: some View
    {
      ScrollView
      {
        VStack(alignment: .leading, spacing: 4)
        {
          if inspector.material.isEmpty
          {
            Properties.row("Material")
            {
              Text("+ New")
                .font(Properties.font)
                .foregroundColor(Properties.text)
                .frame(width: Double(Properties.controlWidth), height: Double(Properties.rowHeight))
                .background(RoundedRectangle(cornerRadius: 4).fill(Properties.field))
                .onTapGesture { inspector.newMaterial() }
            }
          }
          else
          {
            Properties.row("Material") { Readout(inspector.material.split(separator: "/").last.map(String.init) ?? "") }
            Properties.row("Surface") { Readout(inspector.shader.split(separator: "/").last.map(String.init) ?? "—") }
            Properties.row("Edits To") { Readout(inspector.materialRoute) }
            PropertiesPanel("Preview")
            {
              MaterialPreviewView(preview: inspector.materialPreview())
            }

            let pages = inspector.pages
            if pages.isEmpty
            {
              PropertiesPanel("Surface")
              {
                ForEach(Array(inspector.inputs.indices), id: \.self)
                { i in
                  input(i)
                }
              }
            }
            else
            {
              ForEach(Array(pages.indices), id: \.self)
              { p in
                page(pages[p], expanded: p == 0)
              }
            }
          }
        }
        .padding(6)
      }
    }

    private func page(_ page: Inspector.Page, expanded: Bool) -> some View
    {
      PropertiesPanel(page.title, expanded: expanded)
      {
        ForEach(page.inputs, id: \.self)
        { i in
          input(i)
        }

        ForEach(Array(page.pages.indices), id: \.self)
        { p in
          PropertiesPanel(page.pages[p].title, expanded: false, nested: true)
          {
            ForEach(page.pages[p].inputs, id: \.self)
            { i in
              input(i)
            }
          }
        }
      }
    }

    @ViewBuilder
    private func input(_ i: Int) -> some View
    {
      let field = inspector.inputs[i]
      let label = field.label.isEmpty ? Inspector.label(field.name) : field.label
      if field.checkbox, field.texture.isEmpty
      {
        Properties.check(label, inspector.inputFlag(i))
      }
      else
      {
        Properties.row(label)
        {
          value(field, i)
        }
      }
    }

    @ViewBuilder
    private func value(_ field: Inspector.Field, _ i: Int) -> some View
    {
      if !field.texture.isEmpty
      {
        Readout("▣ " + field.texture)
      }
      else if !field.options.isEmpty
      {
        Dropdown(options: field.options, selection: inspector.inputOption(i))
      }
      else if field.components == 3, field.isColor
      {
        ColorField(color: inspector.inputColor(i))
      }
      else if field.components == 1
      {
        NumberField(value: inspector.input(i), step: 0.01) { String(format: "%.3f", $0) }
      }
      else
      {
        Readout(field.value)
      }
    }
  }
}
