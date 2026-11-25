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
import protocol SwiftCrossUI.ObservableObject
#if os(macOS)
  import AppKit
  import UniformTypeIdentifiers
#endif
import class SwiftCrossUI.Published

extension Kraken.Layout
{
  func setShading(_ next: ViewportShading)
  {
    shading = next
    tabShading[tab] = next
    var settings = engine.settings
    settings.shading = next
    engine.settings = settings
  }

  func applyOverlays()
  {
    var settings = engine.settings
    settings.overlays = overlays
    engine.settings = settings
  }

  func toggleShading(_ next: ViewportShading)
  {
    setShading(shading == next && next != .solid ? .solid : next)
  }

  func open(_ next: Tab)
  {
    // the view moves with you between the tabs, as one viewport would
    if tab == .sculpting, next != .sculpting
    {
      sculpt.flush()
      sculpt.viewport?.resumeScene()
      if let camera = sculpt.viewCamera { adoptSculptCamera(camera, upright: sculpt.upright) }
    }

    let arriving = next == .sculpting && tab != .sculpting
    tab = next
    setShading(tabShading[next] ?? .solid)
    if next == .modeling { enterEdit() } else if mode == .edit { exitEdit() }
    if next == .sculpting { enterSculpt() }
    if arriving { refreshSculptScene(takesCamera: true) }
  }

  /// sculpts the selected mesh in place, with nothing selected it opens the default prim or the biggest piece of geometry
  func enterSculpt()
  {
    guard let path = active else { return pickSculptTarget() }
    guard path != sculpt.primPath, path != sculpt.opening else { return }
    sculpt.flush()
    loadSculpt(path)
  }

  /// selects what sculpting opens when nothing is selected and no sculpt is open, so the tab shows a mesh ready to sculpt
  private func pickSculptTarget()
  {
    guard sculpt.primPath == nil, sculpt.opening == nil else { return }
    let time = hydra.currentTimeCode

    onStage
    { [weak self] stage in
      let target = Kraken.SculptUSD.defaultTarget(stage, time)
      DispatchQueue.main.async
      {
        guard let self, self.tab == .sculpting, self.active == nil, self.sculpt.primPath == nil, self.sculpt.opening == nil
        else { return }
        guard let target else
        {
          self.status = "Add a mesh to sculpt"
          return
        }

        self.select([target])
      }
    }
  }

  func toggleEdit()
  {
    mode == .edit ? exitEdit() : enterEdit()
  }

  func enterEdit()
  {
    guard mode != .edit else { return }
    guard let path = active else
    {
      status = "Select a mesh to edit"
      return
    }

    let time = hydra.currentTimeCode
    let selectMode = selectMode
    let converts = !widgets.contains { $0.path == path }
    if converts { checkpoint() }

    onStage
    { [self] stage in
      if converts { Kraken.SceneEdit.makeMesh(stage, path, time) }
      let loaded = Self.readMesh(stage, path, time)
      let placement = Self.placement(stage, path, time)

      // a stack makes the surface something other than the cage, so it is dimmed while the cage is edited
      Kraken.SceneEdit.ghost(stage, path, on: !Kraken.Modifiers.read(stage, path).isEmpty)

      DispatchQueue.main.async
      { [weak self] in
        guard let self else { return }
        guard var loaded else
        {
          self.status = "\(path.split(separator: "/").last ?? "") is not a mesh"
          return
        }

        loaded.mode = selectMode
        loaded.selectAll(true)
        self.mesh = loaded
        self.primsChanged()
        self.meshWorld = placement?.world ?? matrix_identity_double4x4
        self.mode = .edit
      }
    }
  }

  func exitEdit()
  {
    let path = mesh?.path
    mode = .object
    mesh = nil

    guard let path else { return }

    onStage { stage in Kraken.SceneEdit.ghost(stage, path, on: false) }
  }

  func setSelectMode(_ next: Kraken.SelectMode)
  {
    selectMode = next
    mesh?.setMode(next)
  }
}
