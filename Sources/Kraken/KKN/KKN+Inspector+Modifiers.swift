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

import CxxStdlib
import Foundation
import HdAkari
import HydraKit
import simd
import SwiftCrossUI

extension Kraken.Inspector
{
  /// whether the active prim is a mesh, the only thing a stack sits on
  var isMesh: Bool
  {
    typeName.string == "Mesh"
  }

  /// the modifier the panel offers to apply, the bottom one still waiting on the stack
  var appliable: String?
  {
    modifiers.first { !appliedModifiers.contains($0.name) && !$0.kind.isRefinement }?.name
  }

  /// runs an edit of the stack on the frame queue, evaluates it and reads the prim back
  private func edit(_ work: @escaping @Sendable (UsdStage, String) -> Void)
  {
    guard let path else { return }

    layout?.checkpoint()
    let engine = hydra
    let time = engine.currentTimeCode
    engine.performOnFrameQueue
    { [weak self] in
      work(engine.stage, path)
      Kraken.Modifiers.sync(engine.stage, path, time)

      DispatchQueue.main.async { self?.load(path) }
    }
  }

  func addModifier(_ kind: Kraken.Modifiers.Kind)
  {
    edit { stage, path in _ = Kraken.Modifiers.add(stage, path, kind) }
  }

  func removeModifier(_ name: String)
  {
    edit { stage, path in Kraken.Modifiers.remove(stage, path, name) }
  }

  func moveModifier(_ name: String, up: Bool)
  {
    edit { stage, path in Kraken.Modifiers.move(stage, path, name, up: up) }
  }

  /// bakes the bottom modifier into the mesh, which only reaches the shot when the scene is saved
  func applyModifier(_ name: String)
  {
    edit { stage, path in Kraken.Modifiers.apply(stage, path, name) }
    layout?.status = "\(name) applies when the scene is saved"
  }

  func modifierShown(_ name: String, render: Bool) -> Binding<Bool>
  {
    Binding(get: { self.modifiers.first { $0.name == name }.map { render ? $0.render : $0.viewport } ?? true },
            set: { on in self.edit { stage, path in Kraken.Modifiers.show(stage, path, name, render: render, on: on) } })
  }

  /// one number of one parameter, the row the panel draws it as
  func modifierNumber(_ name: String, _ parameter: Kraken.Modifiers.Parameter, _ i: Int = 0) -> Binding<Double>
  {
    Binding(get:
            {
              guard let entry = self.modifiers.first(where: { $0.name == name }) else { return parameter.fallback }

              return entry.number(parameter.key, parameter.defaults[min(i, parameter.defaults.count - 1)], i)
            },
            set:
            { value in
              guard let at = self.modifiers.firstIndex(where: { $0.name == name }) else { return }

              var written = self.modifiers[at].values[parameter.key] ?? parameter.defaults
              while written.count < parameter.components { written.append(0) }
              written[i] = value

              let values = written
              self.modifiers[at].values[parameter.key] = values
              self.edit { stage, path in Kraken.Modifiers.set(stage, path, name, parameter, values) }
            })
  }

  func modifierFlag(_ name: String, _ parameter: Kraken.Modifiers.Parameter) -> Binding<Bool>
  {
    let number = modifierNumber(name, parameter)
    return Binding(get: { number.wrappedValue != 0 }, set: { number.wrappedValue = $0 ? 1 : 0 })
  }

  func modifierChoice(_ name: String, _ parameter: Kraken.Modifiers.Parameter, _ labels: [String]) -> Binding<String?>
  {
    let number = modifierNumber(name, parameter)
    return Binding(get:
                   {
                     let i = Int(number.wrappedValue.rounded())
                     return labels.indices.contains(i) ? labels[i] : labels.first
                   },
                   set:
                   { label in
                     guard let label, let i = labels.firstIndex(of: label) else { return }

                     number.wrappedValue = Double(i)
                   })
  }
}
