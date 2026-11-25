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
  /// moves paths under one prim to under another
  private func repoint(_ paths: [String], _ from: String, _ to: String) -> [String]
  {
    paths.map
    { path in
      guard path != from else { return to }
      return path.hasPrefix(from + "/") ? to + path.dropFirst(from.count) : path
    }
  }

  /// renames a prim, the active one by default
  func rename(_ path: String? = nil, to name: String, then done: (@MainActor (String) -> Void)? = nil)
  {
    guard let path = path ?? active, !name.isEmpty else { return }

    if mode == .edit { exitEdit() }
    checkpoint()
    onStage
    { [self] stage in
      let renamed = Kraken.SceneEdit.rename(stage, path, name)

      DispatchQueue.main.async
      { [weak self] in
        guard let self else { return }
        guard !renamed.isEmpty else
        {
          self.status = "Couldn't rename \(path.split(separator: "/").last ?? "")"
          return
        }

        self.placements = self.placements.reduce(into: [:]) { $0[self.repoint([$1.key], path, renamed)[0]] = $1.value }
        self.hidden = self.repoint(self.hidden, path, renamed)

        self.status = "Renamed to \(renamed.split(separator: "/").last ?? "")"
        self.primsChanged()
        self.select(self.repoint(self.selection, path, renamed))
        self.inspector.load(self.active)
        done?(renamed)
      }
    }
  }

  /// parents the selected objects to a prim, the active one by default
  func parentSelected(to parent: String? = nil, then done: (@MainActor ([String]) -> Void)? = nil)
  {
    let target = parent ?? active
    let children = selection.filter { $0 != target }
    guard let target, !children.isEmpty else
    {
      status = "Select the children, then the parent last"
      return
    }

    if mode == .edit { exitEdit() }
    checkpoint()
    let time = hydra.currentTimeCode
    onStage
    { [self] stage in
      var moved: [(String, String)] = []

      // deepest first so a moved child never strands a grandchild
      for path in children.sorted(by: { $0.count > $1.count })
      {
        let next = Kraken.SceneEdit.reparent(stage, path, under: target, time)
        if !next.isEmpty { moved.append((path, next)) }
      }

      DispatchQueue.main.async
      { [weak self] in
        guard let self else { return }
        var selection = self.selection
        for (from, to) in moved { selection = self.repoint(selection, from, to) }

        self.status = moved.isEmpty ? "Couldn't parent" : "Parented \(moved.count) to \(target.split(separator: "/").last ?? "/")"
        self.placements = [:]
        self.primsChanged()
        self.select(selection)
        done?(moved.map(\.1))
      }
    }
  }

  /// adds a variant to the active prim and selects it
  func addVariant(set: String, variant: String)
  {
    guard let path = active, !set.isEmpty, !variant.isEmpty else { return }

    checkpoint()
    onStage
    { [self] stage in
      let added = Kraken.SceneEdit.addVariant(stage, path, set: set, variant: variant, select: true)

      DispatchQueue.main.async
      { [weak self] in
        guard let self else { return }
        self.status = added ? "Added \(set)=\(variant)" : "Couldn't add \(set)=\(variant)"
        self.primsChanged()
        self.inspector.load(path)
      }
    }
  }

  func selectVariant(set: String, variant: String, on path: String? = nil)
  {
    guard let path = path ?? active else { return }

    checkpoint()
    onStage
    { [self] stage in
      Kraken.SceneEdit.selectVariant(stage, path, set: set, variant: variant)

      DispatchQueue.main.async
      { [weak self] in
        guard let self else { return }

        // a variant switch can change everything under the prim
        self.placements = [:]
        self.primsChanged()
        self.inspector.load(path)
      }
    }
  }

  /// sends edits into a variant of the active prim, or back to the layer itself when `variant` is nil
  func editVariant(set: String, variant: String?, on path: String? = nil)
  {
    guard let variant else
    {
      onStage { _ in Kraken.Authoring.variantEdit = nil }
      editingVariant = nil
      status = "Editing \(departmentName)"
      inspector.reload()
      return
    }

    guard let path = path ?? active else { return }

    selectVariant(set: set, variant: variant, on: path)
    onStage { _ in Kraken.Authoring.variantEdit = (path, set, variant) }
    editingVariant = "\(path.split(separator: "/").last ?? ""){\(set)=\(variant)}"
    status = "Editing inside \(editingVariant ?? "")"
    inspector.reload()
  }

  /// sets the stage up axis, default prim and documentation, leaving empty ones alone
  func setStageMetadata(upAxis: String = "", defaultPrim: String = "", documentation: String = "")
  {
    checkpoint()
    nonisolated(unsafe) let engine = engine
    onStage
    { [self] stage in
      let wasZUp = UsdGeom.getUpAxis(for: stage) == .z
      let ok = Kraken.SceneEdit.setStageMetadata(stage, upAxis: upAxis, defaultPrim: defaultPrim, documentation: documentation)
      let zUp = UsdGeom.getUpAxis(for: stage) == .z
      engine.labfx.setStageUpAxis(isZUp: zUp)

      // the view camera only orbits the up axis it was made for, so make a new one and reframe
      if zUp != wasZUp
      {
        self.hydra.viewCamera = Hydra.Camera(isZUp: zUp)
        Kraken.StageManager.frameStartView(self.hydra)
      }

      DispatchQueue.main.async
      { [weak self] in
        guard let self else { return }
        self.isZUp = zUp
        if !ok { self.status = "Couldn't set the stage's metadata" }
        self.primsChanged()
      }
    }
  }
}
