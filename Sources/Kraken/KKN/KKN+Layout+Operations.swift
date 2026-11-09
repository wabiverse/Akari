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
  func add(_ kind: Kraken.AddKind)
  {
    if mode == .edit { exitEdit() }
    checkpoint()
    let at = [cursor.x, cursor.y, cursor.z]
    onStage
    { [self] stage in
      let path = Kraken.SceneEdit.add(stage, kind, at: SIMD3(at[0], at[1], at[2]))
      DispatchQueue.main.async
      { [weak self] in
        guard let self, !path.isEmpty else { return }
        self.primsChanged()
        self.select([path])
      }
    }
  }

  func deleteSelected()
  {
    guard !selection.isEmpty else { return }
    checkpoint()
    let paths = selection
    onStage { stage in for path in paths { Kraken.SceneEdit.remove(stage, path) } }
    status = "Deleted \(paths.count) object\(paths.count == 1 ? "" : "s")"
    select([])
    primsChanged()
  }

  func duplicateSelected(_ then: @escaping @MainActor @Sendable () -> Void)
  {
    guard !selection.isEmpty else { return }
    checkpoint()
    let paths = selection
    let time = hydra.currentTimeCode
    onStage
    { [self] stage in
      let copies = paths.map { Kraken.SceneEdit.duplicate(stage, $0) }.filter { !$0.isEmpty }
      var placements: [String: Placement] = [:]
      for copy in copies { placements[copy] = Self.placement(stage, copy, time) }
      DispatchQueue.main.async
      { [weak self] in
        guard let self else { return }
        self.placements.merge(placements) { $1 }
        self.primsChanged()
        self.select(copies)
        then()
      }
    }
  }


  func hideSelected()
  {
    guard !selection.isEmpty else { return }
    checkpoint()
    let paths = selection
    hidden += paths
    onStage { stage in for path in paths { Kraken.SceneEdit.setHidden(stage, path, true) } }
    select([])
    primsChanged()
  }

  func unhideAll()
  {
    guard !hidden.isEmpty else { return }
    checkpoint()
    let paths = hidden
    hidden = []
    onStage { stage in for path in paths { Kraken.SceneEdit.setHidden(stage, path, false) } }
    select(paths)
    primsChanged()
  }

  /// Writes new local transforms, `commit` marks the end of a drag.
  func setLocals(_ locals: [String: simd_double4x4])
  {
    for (path, local) in locals { placements[path]?.local = local }
    let arrays = locals.mapValues(Self.array)
    transformWriter.submit(hydra)
    { stage in
      for (path, local) in arrays { Kraken.SceneEdit.setTransform(stage, path, local) }
    }
  }

  /// A light's size, rect height and cone angle (degrees), as its handles drag them.
  func setLight(_ path: String, size: Double, size2: Double, angle: Double)
  {
    if let i = widgets.firstIndex(where: { $0.path == path })
    {
      widgets[i].size = size
      widgets[i].size2 = size2
      if angle > 0 { widgets[i].angle = angle }
    }

    lightWriter.submit(hydra) { stage in Kraken.SceneEdit.setLight(stage, path, size: size, size2: size2, angle: angle) }
  }

  enum Clear
  {
    case location, rotation, scale
  }

  func clear(_ what: Clear)
  {
    guard !selection.isEmpty else { return }
    checkpoint()
    var locals: [String: simd_double4x4] = [:]
    for path in selection
    {
      guard let p = placements[path] else { continue }
      var (t, r, s) = Self.decompose(p.local)
      switch what
      {
        case .location: t = .zero
        case .rotation: r = simd_quatd(ix: 0, iy: 0, iz: 0, r: 1)
        case .scale: s = SIMD3(repeating: 1)
      }

      locals[path] = Self.compose(t, r, s)
    }

    setLocals(locals)
  }

  nonisolated static func decompose(_ m: simd_double4x4) -> (SIMD3<Double>, simd_quatd, SIMD3<Double>)
  {
    let t = SIMD3(m.columns.3.x, m.columns.3.y, m.columns.3.z)
    var x = SIMD3(m.columns.0.x, m.columns.0.y, m.columns.0.z)
    var y = SIMD3(m.columns.1.x, m.columns.1.y, m.columns.1.z)
    var z = SIMD3(m.columns.2.x, m.columns.2.y, m.columns.2.z)
    var s = SIMD3(simd_length(x), simd_length(y), simd_length(z))
    if simd_dot(simd_cross(x, y), z) < 0 { s.x = -s.x }
    x /= s.x == 0 ? 1 : s.x
    y /= s.y == 0 ? 1 : s.y
    z /= s.z == 0 ? 1 : s.z
    let r = simd_quatd(simd_double3x3(columns: (x, y, z)))
    return (t, r, s)
  }

  nonisolated static func compose(_ t: SIMD3<Double>, _ r: simd_quatd, _ s: SIMD3<Double>) -> simd_double4x4
  {
    let m = simd_double3x3(r) * simd_double3x3(diagonal: s)
    return simd_double4x4(columns: (SIMD4(m.columns.0, 0), SIMD4(m.columns.1, 0), SIMD4(m.columns.2, 0), SIMD4(t, 1)))
  }

  /// The selection's middle in the world, its origins in object mode, its verts in edit mode.
  var pivot: SIMD3<Double>?
  {
    if mode == .edit
    {
      guard let mesh, let m = mesh.median else { return nil }
      let p = meshWorld * SIMD4(SIMD3<Double>(m), 1)
      return SIMD3(p.x, p.y, p.z)
    }

    let origins = selection.compactMap { placements[$0].map { SIMD3($0.world.columns.3.x, $0.world.columns.3.y, $0.world.columns.3.z) } }
    guard !origins.isEmpty else { return nil }
    return origins.reduce(.zero, +) / Double(origins.count)
  }
}
