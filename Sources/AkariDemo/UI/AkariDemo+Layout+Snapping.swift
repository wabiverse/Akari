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

extension AkariDemo.Layout
{
  func cursorToSelected()
  {
    if let pivot { cursor = pivot }
  }

  func cursorToOrigin()
  {
    cursor = .zero
  }

  func selectionToCursor()
  {
    if mode == .edit
    {
      editMesh
      { mesh, world in
        let local = world.inverse * SIMD4(self.cursor, 1)
        for v in mesh.verts { mesh.points[v] = SIMD3<Float>(SIMD3(local.x, local.y, local.z)) }
      }

      return
    }

    guard !selection.isEmpty else { return }
    checkpoint()
    var locals: [String: simd_double4x4] = [:]
    for path in selection
    {
      guard let p = placements[path] else { continue }
      var world = p.world
      world.columns.3 = SIMD4(cursor, 1)
      locals[path] = p.parent.inverse * world
    }

    setLocals(locals)
  }

  func frameSelected()
  {
    guard let target = pivot else
    {
      hydra.frameAll()
      return
    }

    let hydra = hydra
    let paths = mode == .edit ? [] : selection
    let time = hydra.currentTimeCode
    let world = meshWorld
    let radius = mode == .edit ? (mesh?.verts.map
    { v -> Double in
      let p = world * SIMD4(SIMD3<Double>(self.mesh!.points[v]), 1)
      return simd_distance(SIMD3(p.x, p.y, p.z), target)
    }.max() ?? 0) : 0
    onStage
    { stage in
      var size = radius * 2
      var center = target
      if !paths.isEmpty
      {
        var lo = SIMD3(repeating: Double.infinity), hi = -lo
        for path in paths
        {
          guard let box = AkariDemo.SceneEdit.worldBounds(stage, path, time) else { continue }
          lo = simd_min(lo, SIMD3(box[0], box[1], box[2]))
          hi = simd_max(hi, SIMD3(box[3], box[4], box[5]))
        }

        if lo.x.isFinite
        {
          center = (lo + hi) / 2
          size = simd_distance(lo, hi)
        }
      }

      hydra.stopFlick()
      hydra.viewCamera.focus = Pixar.GfVec3d(center.x, center.y, center.z)
      hydra.viewCamera.distance = max(size * 1.2, 0.05)
    }
  }

  func frameAll()
  {
    hydra.frameAll()
  }

  /// Points the active camera along the view.
  func alignCameraToView()
  {
    guard let path = active, widgets.contains(where: { $0.path == path && $0.kind == .camera }),
          let placement = placements[path], let camera = engine.viewportCamera
    else
    {
      status = "Select a camera to align"
      return
    }

    checkpoint()
    let view = simd_double4x4(columns: (SIMD4<Double>(camera.view.columns.0), SIMD4<Double>(camera.view.columns.1),
                                        SIMD4<Double>(camera.view.columns.2), SIMD4<Double>(camera.view.columns.3)))
    setLocals([path: placement.parent.inverse * view.inverse])
  }
}
