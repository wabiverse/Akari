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
import CxxStdlib
import Foundation
import HdAkari
import HydraKit
import simd

extension Kraken.Layout
{
  /// joins every selected mesh, and every mesh under a selected prim, into the active mesh as one undo step
  func joinSelected()
  {
    guard !selection.isEmpty else { return }

    if mode == .edit { exitEdit() }
    checkpoint()
    let paths = selection
    let active = active
    let time = hydra.currentTimeCode
    onStage
    { [self] stage in
      let result = Kraken.SceneEdit.join(stage, paths, active: active, time)

      DispatchQueue.main.async
      { [weak self] in
        guard let self else { return }
        guard !result.failed else
        {
          self.status = result.target.isEmpty ? "Nothing to join into, select a mesh" : "Select more meshes to join"
          return
        }

        let gone = Set(result.removed)
        self.hidden.removeAll { path in gone.contains { Kraken.SceneEdit.within(path, $0) } }
        self.placements = [:]
        self.status = "Joined \(result.joined) meshes into \(result.target.split(separator: "/").last ?? "")"
        self.primsChanged()
        self.select([result.target])
      }
    }
  }

  /// selects every mesh under the selected prims, keeping the active one's meshes last so it stays active
  func selectHierarchy()
  {
    guard !selection.isEmpty else { return }

    let paths = selection.filter { $0 != active } + (active.map { [$0] } ?? [])
    let time = hydra.currentTimeCode
    onStage
    { [self] stage in
      let found = Kraken.SceneEdit.hierarchy(stage, paths, time)

      DispatchQueue.main.async
      { [weak self] in
        guard let self, !found.isEmpty else { return }
        self.status = "Selected \(found.count) mesh\(found.count == 1 ? "" : "es")"
        self.select(found)
      }
    }
  }
}
