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

extension AkariDemo
{
  /// Where scene edits land, the way a Presto shot routes them: each department works in its own
  /// sublayer of the shot, the stage's edit target, and overrides what it changes there. An edit
  /// under an instance broadcasts through the class the instance inherits when there's one, so it
  /// stays in the shot, and otherwise edits the asset through the arc bringing it in. A prim a
  /// variant of the department's layer defines is edited inside that variant. The session layer
  /// only keeps what the viewport shows, like hidden objects, and is never saved.
  enum Authoring
  {
    /// The prim to author an edit of `path` on, the stage it's on, aimed at where it lands, and a name for there.
    struct Site
    {
      var prim: UsdPrim
      var stage: UsdStage
      var target: Pixar.UsdEditTarget
      var layer: SdfLayerHandle
      var label: String
    }

    nonisolated static func layerName(_ layer: SdfLayerHandle) -> String
    {
      let name = String(layer.pointee.GetDisplayName())
      return name.isEmpty ? identifier(layer) : name
    }

    nonisolated static func identifier(_ layer: SdfLayerHandle) -> String
    {
      layer.identifier
    }

    nonisolated static func editTarget(_ stage: UsdStage) -> Pixar.UsdEditTarget
    {
      stage.editTarget
    }



    nonisolated static func target(_ layer: SdfLayerHandle) -> Pixar.UsdEditTarget
    {
      Pixar.UsdEditTarget(layer, Pixar.SdfLayerOffset(offset: 0, scale: 1))
    }

    /// The department layer edits go to, the stage's edit target.
    nonisolated static func department(_ stage: UsdStage) -> SdfLayerHandle
    {
      #if compiler(>=6.4)
        stage.editTarget.GetLayerConsuming()
      #else
        stage.editTarget.GetLayer()
      #endif
    }

    /// The shot's layers, strongest first, without the session layer.
    nonisolated static func layers(_ stage: UsdStage) -> [(identifier: String, name: String)]
    {
      stage.GetLayerStack(false).map { (identifier($0), layerName($0)) }
    }

    /// Makes the layer `identifier` names the department layer.
    nonisolated static func work(in identifier: String, _ stage: UsdStage)
    {
      guard let layer = stage.GetLayerStack(true).first(where: { Self.identifier($0) == identifier }) else { return }
      Pixar.HdAkariJournalWatch(layer)
      stage.SetEditTarget(target(layer))
    }

    /// A shot's departments, as Presto splits a shot's work into its layers.
    enum Department: String, CaseIterable, Sendable
    {
      case layout = "Layout", animation = "Animation", lookDev = "Look Dev", lighting = "Lighting", fx = "FX"
    }

    /// Adds a department sublayer next to the root layer, strongest, and works in it.
    nonisolated static func newDepartment(_ department: Department, _ stage: UsdStage) -> String?
    {
      let root = stage.getRootLayer()
      let rootLayer = root.pointee
      guard !rootLayer.IsAnonymous() else { return nil }
      let rootURL = URL(fileURLWithPath: root.realPath)
      let stem = rootURL.deletingPathExtension().lastPathComponent
      let file = "\(stem)_\(department.rawValue.lowercased().replacingOccurrences(of: " ", with: "_")).usda"
      let url = rootURL.deletingLastPathComponent().appendingPathComponent(file)
      let created = FileManager.default.fileExists(atPath: url.path)
        ? Pixar.SdfLayer.FindOrOpen(std.string(url.path), Pixar.SdfLayer.FileFormatArguments())
        : Pixar.SdfLayer.CreateNew(std.string(url.path), Pixar.SdfLayer.FileFormatArguments())
      let layer = created.pointee
      _ = layer.Save(false)
      if !layers(stage).contains(where: { URL(fileURLWithPath: $0.identifier).lastPathComponent == file })
      {
        rootLayer.InsertSubLayerPath(std.string("./\(file)"), 0)
      }

      departments.append(created)
      guard let identifier = layers(stage).first(where: { URL(fileURLWithPath: $0.identifier).lastPathComponent == file })?
        .identifier else { return nil }
      work(in: identifier, stage)
      return identifier
    }

    nonisolated(unsafe) private static var departments: [Pixar.SdfLayerRefPtr] = []
    nonisolated(unsafe) private static var assetStages: [String: Pixar.UsdStage] = [:]

    /// Journals the shot's layers for undo.
    nonisolated static func watch(_ stage: UsdStage)
    {
      for layer in stage.GetLayerStack(true) { Pixar.HdAkariJournalWatch(layer) }
    }

    /// Where an edit of the prim at `path` lands, nil when nothing can take it.
    nonisolated static func site(_ stage: UsdStage, _ path: String) -> Site?
    {
      let prim = stage.GetPrimAtPath(Sdf.Path(path))
      guard prim.isValid else { return nil }
      let department = department(stage)
      let name = layerName(department)
      guard prim.IsInstanceProxy() else
      {
        if let variant = variantTarget(prim, department)
        {
          return Site(prim: prim, stage: stage, target: variant.target, layer: department, label: "\(name) · \(variant.label)")
        }

        return Site(prim: prim, stage: stage, target: target(department), layer: department, label: name)
      }

      var instance = prim
      while instance.isValid, !instance.isInstance { instance = instance.parent }
      guard instance.isValid else { return nil }
      let relative = prim.path.makeRelativePath(to: instance.path)

      var inherits = Pixar.UsdPrimCompositionQuery.GetDirectInherits(instance)
      for arc in inherits.GetCompositionArcs()
      {
        let classPath = arc.GetTargetPrimPath()
        guard classPath.IsRootPrimPath() else { continue }
        let edit = Pixar.UsdEditTarget(department, Pixar.SdfLayerOffset(offset: 0, scale: 1))
        let previous = editTarget(stage)
        stage.SetEditTarget(edit)
        defer { stage.SetEditTarget(previous) }
        let fresh = !department.pointee.HasSpec(classPath)
        let root = stage.OverridePrim(classPath)
        if fresh { _ = root.SetSpecifier(Pixar.SdfSpecifierClass) }
        let target = stage.OverridePrim(classPath.append(path: relative))
        guard target.isValid else { continue }
        return Site(prim: target, stage: stage, target: edit, layer: department, label: "\(name) · class \(classPath.string.split(separator: "/").last.map(String.init) ?? "")")
      }

      var references = Pixar.UsdPrimCompositionQuery.GetDirectReferences(instance)
      for arc in references.GetCompositionArcs()
      {
        let layer = arc.GetTargetLayer()
        guard !layer.pointee.IsAnonymous() else { continue }
        let specPath = arc.GetTargetPrimPath().append(path: relative)
        guard !specPath.IsEmpty() else { continue }
        Pixar.HdAkariJournalWatch(layer)
        let key = identifier(layer)
        if assetStages[key] == nil
        {
          assetStages[key] = UsdStage.open(layer, load: .none)
        }

        guard let assetRef = assetStages[key] else { continue }
        let assetStage = assetRef
        let target = assetStage.overridePrim(path: specPath)
        guard target.isValid else { continue }
        return Site(prim: target, stage: assetStage, target: Self.target(layer), layer: layer, label: "\(layerName(layer)) (asset)")
      }

      return nil
    }

    /// The variant of the department's layer defining `prim`, if one does.
    nonisolated private static func variantTarget(_ prim: UsdPrim, _ department: SdfLayerHandle)
      -> (target: Pixar.UsdEditTarget, label: String)?
    {
      var filter = Pixar.UsdPrimCompositionQuery.Filter()
      filter.arcTypeFilter = .Variant
      let id = identifier(department)
      var query = Pixar.UsdPrimCompositionQuery(prim, filter)
      for arc in query.GetCompositionArcs()
      {
        let layer = arc.GetTargetLayer()
        guard identifier(layer) == id else { continue }
        let selectionPath = arc.GetTargetPrimPath()
        let owner = selectionPath.StripAllVariantSelections()
        let spec = selectionPath.append(path: prim.path.makeRelativePath(to: owner))
        guard layer.pointee.HasSpec(spec) else { continue }
        let selection = selectionPath.GetVariantSelection()
        return (Pixar.UsdEditTarget.ForLocalDirectVariant(layer, selectionPath),
                "{\(String(selection.first))=\(String(selection.second))}")
      }

      return nil
    }

    /// Runs `body` on where an edit of `path` lands, aimed there, journaled for undo.
    @discardableResult
    nonisolated static func edit(_ stage: UsdStage, _ path: String, _ body: (UsdPrim, UsdStage) -> Bool) -> Bool
    {
      guard let site = site(stage, path) else { return false }
      Pixar.HdAkariJournalWatch(site.layer)
      let previous = editTarget(site.stage)
      site.stage.SetEditTarget(site.target)
      defer { site.stage.SetEditTarget(previous) }
      return body(site.prim, site.stage)
    }

    /// Runs `body` aimed at the department layer.
    @discardableResult
    nonisolated static func inDepartment<T>(_ stage: UsdStage, _ body: () -> T) -> T
    {
      let department = department(stage)
      Pixar.HdAkariJournalWatch(department)
      let previous = editTarget(stage)
      stage.SetEditTarget(target(department))
      defer { stage.SetEditTarget(previous) }
      return body()
    }

    /// Runs `body` aimed at the session layer, for what only the viewport shows.
    nonisolated static func inSession(_ stage: UsdStage, _ body: () -> Void)
    {
      let session = stage.GetSessionLayer()
      Pixar.HdAkariJournalWatch(session)
      let previous = editTarget(stage)
      stage.SetEditTarget(target(session))
      defer { stage.SetEditTarget(previous) }
      body()
    }

    /// Saves every changed layer, the root layer to `path` instead when there's one.
    nonisolated static func save(_ stage: UsdStage, as path: String?) -> Bool
    {
      var saved = true
      let root = identifier(stage.getRootLayer())
      let session = identifier(stage.GetSessionLayer())
      for handle in stage.GetUsedLayers(true)
      {
        let layer = handle.pointee
        let id = identifier(handle)
        let exporting = id == root && path != nil
        guard exporting || (!layer.IsAnonymous() && layer.IsDirty()) else { continue }
        if id == session { continue }
        if id == root, let path
        {
          saved = layer.Export(std.string(path), std.string(), Pixar.SdfLayer.FileFormatArguments()) && saved
        }
        else
        {
          saved = layer.Save(false) && saved
        }
      }

      if saved { Pixar.HdAkariJournalClear() }
      return saved
    }
  }
}
