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
  func select(_ paths: [String], extend: Bool = false)
  {
    if extend
    {
      var next = selection
      for path in paths
      {
        if next.last == path { next.removeLast() }
        else
        {
          next.removeAll { $0 == path }
          next.append(path)
        }
      }

      selection = next
    }
    else
    {
      selection = paths
    }

    driver?.select(objects: selection)
    if inspector.path != active { inspector.load(active) }
    refresh()
  }

  func selectAll()
  {
    if mode == .edit
    {
      mesh?.selectAll(true)
      return
    }

    selectable { [weak self] all in self?.select(all.map(\.path)) }
  }

  func deselectAll()
  {
    if mode == .edit { mesh?.clearSelection() }
    else { select([]) }
  }

  func invertSelection()
  {
    if mode == .edit
    {
      mesh?.invert()
      return
    }

    let current = Set(selection)
    selectable { [weak self] all in self?.select(all.map(\.path).filter { !current.contains($0) }) }
  }

  /// Every object a box or select all can take, with its middle in the world.
  func selectable(_ done: @escaping @MainActor @Sendable ([(path: String, center: SIMD3<Double>)]) -> Void)
  {
    let time = hydra.currentTimeCode
    onStage
    { stage in
      let all = Kraken.SceneEdit.selectable(stage, time).map
      { o -> (path: String, center: SIMD3<Double>) in
        let c = Array(o.center)
        return (String(o.path), c.count == 3 ? SIMD3(c[0], c[1], c[2]) : .zero)
      }

      DispatchQueue.main.async { done(all) }
    }
  }

  /// Selects what a viewport click hit, or clears the selection for `nil`. The first click
  /// selects the whole object, clicking it again selects the prim under the cursor.
  func picked(_ path: String?, extend: Bool)
  {
    guard let path else
    {
      if !extend { select([]) }
      return
    }

    onStage
    { [self] stage in
      let object = Kraken.SceneEdit.object(for: path, stage)
      let hit = Kraken.SceneEdit.hit(for: path, stage)
      DispatchQueue.main.async
      { [weak self] in
        guard let self else { return }
        self.select([extend ? object : self.drilled(object: object, hit: hit)], extend: extend)
      }
    }
  }

  /// `hit` if the object or one of its prims is already selected, otherwise `object`.
  private func drilled(object: String, hit: String) -> String
  {
    guard hit != object, selection.count == 1, let active,
          Kraken.SceneEdit.within(active, object),
          Kraken.SceneEdit.within(hit, active)
    else { return object }

    return hit
  }
}
