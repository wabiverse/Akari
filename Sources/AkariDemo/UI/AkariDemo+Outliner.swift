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
import SwiftCrossUI
#if os(macOS)
  import AppKit
  import AppKitBackend
#endif

extension AkariDemo
{
  /// The outliner over the stage's prims: their hierarchy, types and composition, the viewport's
  /// selection, hiding a prim in the viewport, in the session layer, and deactivating it in the
  /// department layer.
  struct PrimOutliner
  {
    let layout: AkariDemo.Layout
    static let height: Double = 260
  }

  /// One prim in the outliner's list,
  /// what a row's icon shows it as.
  enum OutlinerKind: Sendable
  {
    case geometry, camera, light, shading, group, other
  }

  /// A composition arc on a row, badged as usdview does.
  enum OutlinerArc: CaseIterable, Sendable
  {
    case references, payloads, variants, inherits, specializes

    var letter: String
    {
      switch self
      {
        case .references: "R"
        case .payloads: "P"
        case .variants: "V"
        case .inherits: "I"
        case .specializes: "S"
      }
    }
  }

  struct OutlinerRow: Sendable
  {
    var path = ""
    var name = ""
    var kind = OutlinerKind.other
    var depth = 0
    var hasChildren = false
    var active = true
    var defined = true
    var hidden = false
    var instance = false
    var proxy = false
    var arcs: [OutlinerArc] = []
  }

  enum OutlinerScan
  {
    nonisolated static func children(_ prim: UsdPrim) -> [UsdPrim]
    {
      var range = prim.isInstance || prim.IsInstanceProxy()
        ? prim.GetFilteredChildren(Pixar.UsdTraverseInstanceProxies())
        : prim.GetAllChildren()
      var out: [UsdPrim] = []
      while let child = range.next() { out.append(child) }
      return out
    }

    nonisolated static func hasChildren(_ prim: UsdPrim) -> Bool
    {
      var range = prim.isInstance || prim.IsInstanceProxy()
        ? prim.GetFilteredChildren(Pixar.UsdTraverseInstanceProxies())
        : prim.GetAllChildren()
      return range.next() != nil
    }

    /// The rows under the expanded prims, in order, the pseudo root's children at depth 0.
    nonisolated static func rows(_ stage: UsdStage, expanded: Set<String>) -> [OutlinerRow]
    {
      let time = Pixar.UsdTimeCode.Default()
      var rows: [OutlinerRow] = []
      func visit(_ prim: UsdPrim, _ depth: Int)
      {
        for child in children(prim)
        {
          let path = child.GetPath().string
          var arcs: [OutlinerArc] = []
          if child.HasAuthoredReferences() { arcs.append(.references) }
          if child.HasAuthoredPayloads() { arcs.append(.payloads) }
          if child.HasVariantSets() { arcs.append(.variants) }
          if child.HasAuthoredInherits() { arcs.append(.inherits) }
          if child.HasAuthoredSpecializes() { arcs.append(.specializes) }
          let kind: OutlinerKind = child.isA(.camera) ? .camera : child.hasAPI(.lightAPI) ? .light
            : child.isA(.material) || child.isA(.shader) || child.isA(.nodeGraph) ? .shading
            : child.isA(.gprim) || child.isA(.pointInstancer) ? .geometry
            : child.isA(.scope) || child.typeName.IsEmpty() ? .group : .other
          let row = OutlinerRow(path: path, name: child.name.string, kind: kind, depth: depth,
                                hasChildren: hasChildren(child), active: child.IsActive(), defined: child.IsDefined(),
                                hidden: child.isA(.imageable) && SceneEdit.invisible(child, time),
                                instance: child.isInstance, proxy: child.IsInstanceProxy(), arcs: arcs)
          rows.append(row)
          if row.hasChildren, expanded.contains(path) { visit(child, depth + 1) }
        }
      }

      visit(stage.GetPseudoRoot(), 0)
      return rows
    }
  }
}

extension AkariDemo.OutlinerRow
{
  func expandedTitle(_ open: Bool) -> String
  {
    open ? "Collapse Hierarchy" : "Expand Hierarchy"
  }
}
