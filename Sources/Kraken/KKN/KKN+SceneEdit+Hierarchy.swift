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

extension Kraken.SceneEdit
{
  /// a variant set with its selection and variants
  struct VariantSet: Equatable, Sendable
  {
    var name: String
    var selection: String
    var variants: [String]
  }

  /// runs `body` aimed at the department layer, inside the variant being edited when the path is under it
  nonisolated private static func aimed<T>(_ stage: UsdStage, at path: String, variant: Bool = true, _ body: () -> T) -> T
  {
    let department = Kraken.Authoring.department(stage)
    Pixar.HdAkariJournalWatch(department)
    let previous = Kraken.Authoring.editTarget(stage)

    stage.SetEditTarget(variant ? Kraken.Authoring.departmentTarget(stage, for: Sdf.Path(path))
      : Kraken.Authoring.target(department))
    defer { stage.SetEditTarget(previous) }
    return body()
  }

  /// renames a prim and repoints what targets it, giving back its new path
  nonisolated static func rename(_ stage: UsdStage, _ path: String, _ name: String) -> String
  {
    guard let prim = prim(stage, path), !prim.IsInstanceProxy(), !name.isEmpty else { return "" }
    if prim.name.string == name { return path }

    let target = uniqueChild(stage, prim.GetPath().GetParentPath(), name)
    return aimed(stage, at: path) { String(Pixar.HdAkariMovePrim(stage, std.string(path), std.string(target.string))) }
  }

  /// moves a prim under a new parent keeping it in place, giving back its new path
  nonisolated static func reparent(_ stage: UsdStage, _ path: String, under parent: String, _ time: Double) -> String
  {
    guard let prim = prim(stage, path), !prim.IsInstanceProxy() else { return "" }
    let root = parent.isEmpty || parent == "/"
    let parentPath = root ? Sdf.Path.absoluteRootPath() : Sdf.Path(parent)
    guard root || stage.GetPrimAtPath(parentPath).isValid else { return "" }
    guard parentPath.string != prim.GetPath().GetParentPath().string else { return path }
    guard !(parent + "/").hasPrefix(path + "/") else { return "" }

    let before = transform(stage, path, time)
    let world = before.map { Kraken.Layout.matrix($0.parent) * Kraken.Layout.matrix($0.local) }
    let target = uniqueChild(stage, parentPath, prim.name.string)
    let moved = aimed(stage, at: path) { String(Pixar.HdAkariMovePrim(stage, std.string(path), std.string(target.string))) }
    guard !moved.isEmpty else { return "" }

    if let world, let after = transform(stage, moved, time)
    {
      setTransform(stage, moved, Kraken.Layout.array(Kraken.Layout.matrix(after.parent).inverse * world))
    }

    return moved
  }

  /// the variant sets of a prim
  nonisolated static func variantSets(_ stage: UsdStage, _ path: String) -> [VariantSet]
  {
    Pixar.HdAkariVariantSets(stage, std.string(path)).map
    { entry -> VariantSet in
      let parts = String(entry).components(separatedBy: "\t")
      return VariantSet(name: parts.first ?? "", selection: parts.count > 1 ? parts[1] : "",
                        variants: parts.count > 2 ? Array(parts[2...]) : [])
    }
  }

  /// adds a variant and its set when new in the department layer
  @discardableResult
  nonisolated static func addVariant(_ stage: UsdStage, _ path: String, set: String, variant: String, select: Bool) -> Bool
  {
    aimed(stage, at: path, variant: false)
    {
      Pixar.HdAkariAddVariant(stage, std.string(path), std.string(set), std.string(variant), select)
    }
  }

  @discardableResult
  nonisolated static func selectVariant(_ stage: UsdStage, _ path: String, set: String, variant: String) -> Bool
  {
    aimed(stage, at: path, variant: false)
    {
      Pixar.HdAkariSelectVariant(stage, std.string(path), std.string(set), std.string(variant))
    }
  }

  /// sets the root layer up axis, default prim and documentation, leaving empty ones alone
  @discardableResult
  nonisolated static func setStageMetadata(_ stage: UsdStage, upAxis: String = "", defaultPrim: String = "",
                                           documentation: String = "") -> Bool
  {
    Pixar.HdAkariJournalWatch(stage.getRootLayer())
    return Pixar.HdAkariSetStageMetadata(stage, std.string(upAxis), std.string(defaultPrim), std.string(documentation))
  }
}
