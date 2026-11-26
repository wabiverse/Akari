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
import class SwiftCrossUI.Published

extension Kraken.Layout
{
  var isUntitled: Bool { sceneURL == nil }

  func askSaveAs(then done: (@MainActor () -> Void)? = nil)
  {
    Kraken.Dialogs.saveScene(named: sceneURL?.lastPathComponent ?? "untitled.usda", near: sceneURL?.deletingLastPathComponent())
    { [weak self] url in
      self?.save(as: url.path, then: done)
    }
  }

  /// file new, a scene that only lives in memory until it's saved
  func newScene()
  {
    replaceStage(with: nil, asking: true)
  }

  /// file open, for any usd scene
  func openScene()
  {
    Kraken.Dialogs.openScene(near: sceneURL?.deletingLastPathComponent())
    { [weak self] url in
      self?.replaceStage(with: url, asking: true)
    }
  }

  /// asks whether to go on past unsaved edits, saving them first when asked to
  private func confirmDiscard(then proceed: @escaping @MainActor () -> Void)
  {
    guard edited else { return proceed() }

    Kraken.Dialogs.confirmDiscard(sceneURL?.lastPathComponent ?? "untitled.usda")
    { [weak self] choice in
      switch choice
      {
        case .save: self?.save(then: proceed)
        case .discard: proceed()
        case .cancel: break
      }
    }
  }

  /// shows the scene at `url` or a new one in place of this, `done` runs once it's up and `keepView` keeps the camera
  func replaceStage(with url: URL?, asking: Bool, keepView: Bool = false, then done: (@MainActor () -> Void)? = nil)
  {
    let open = { @MainActor [weak self] in
      guard let self else { return }
      if let url, !Pixar.HdAkariLayerOpens(std.string(url.path))
      {
        self.status = "Couldn't open \(url.lastPathComponent)"
        done?()
        return
      }

      if self.mode == .edit { self.exitEdit() }
      nonisolated(unsafe) let engine = self.engine
      let hydra = self.hydra
      self.onStage
      { [self] _ in
        let stage = url.map { UsdStage.open($0.path) } ?? Kraken.StageManager.newStage()
        Kraken.SceneEdit.adoptLegacyBindings(stage)
        let view = keepView ? hydra.viewCamera : nil

        // akari reads what the meshes ask for off this stage, so it has to know it before hydra syncs anything
        Pixar.HdAkariSetSyncStage(stage)
        hydra.replaceStage(stage)
        if let view { hydra.viewCamera = view } else { Kraken.StageManager.frameStartView(hydra) }

        let zUp = UsdGeom.getUpAxis(for: stage) == .z
        let metersPerUnit = UsdGeom.getMetersPerUnit(for: stage)
        engine.labfx.setStageUpAxis(isZUp: zUp)
        engine.labfx.setStageMetersPerUnit(metersPerUnit)
        engine.adoptColorManagement(of: stage)
        Pixar.HdAkariJournalClear()
        Kraken.Authoring.watch(stage)
        Kraken.Modifiers.syncAll(stage, hydra.currentTimeCode)
        let probeTimes = Akari.Playback.probeBakeTimes(stage)

        DispatchQueue.main.async
        { [weak self] in
          guard let self else { return }

          self.sceneURL = url
          self.isZUp = zUp
          self.metersPerUnit = metersPerUnit

          Kraken.Authoring.variantEdit = nil
          self.editingVariant = nil
          self.edited = false
          self.undoStack.removeAll()
          self.redoStack.removeAll()
          self.hidden = []
          self.placements = [:]

          self.select([])
          self.inspector.load(nil)
          self.status = url.map { "Opened \($0.lastPathComponent)" } ?? "New scene"
          self.primsChanged()
          self.refreshLayers()

          // the scene's color management went to the engine, the panels show it
          self.settings?.refresh()
          self.adoptStage?(url, probeTimes)
          done?()
        }
      }
    }

    if asking { confirmDiscard(then: open) }
    else { open() }
  }

  func refreshLayers()
  {
    onStage
    { [self] stage in
      Kraken.Authoring.watch(stage)
      let layers = Kraken.Authoring.layers(stage)
      let department = Kraken.Authoring.identifier(Kraken.Authoring.department(stage))

      DispatchQueue.main.async
      { [weak self] in
        self?.layers = layers
        self?.department = department
      }
    }
  }

  /// sends edits from now on to the layer `identifier` names
  func work(in identifier: String)
  {
    onStage { stage in Kraken.Authoring.work(in: identifier, stage) }
    status = "Editing \(layers.first { $0.identifier == identifier }?.name ?? identifier)"
    refreshLayers()
  }

  /// adds a department sublayer to the shot and works in it
  func newDepartment(_ department: Kraken.Authoring.Department)
  {
    let name = department.rawValue
    onStage
    { [self] stage in
      let made = Kraken.Authoring.newDepartment(department, stage) != nil

      DispatchQueue.main.async
      { [weak self] in
        guard let self else { return }
        self.status = made ? "Editing the \(name) layer" : "Couldn't add a \(name) layer"
        self.refreshLayers()
      }
    }
  }

  var departmentName: String
  {
    layers.first { $0.identifier == department }?.name ?? ""
  }

  func primsChanged()
  {
    sceneRevision += 1
    rescan = true
    driver?.primsChanged()
    refresh()
  }

  nonisolated static func readMesh(_ stage: UsdStage, _ path: String, _ time: Double) -> Kraken.EditMesh?
  {
    // modelling works on the mesh under the stack, the way the shot authors it, not on what it evaluates to
    let data = Kraken.Modifiers.cage(stage, path, time)
    guard data.valid else { return nil }

    let flat = Array(data.points)
    let points = stride(from: 0, to: flat.count - 2, by: 3).map { SIMD3(flat[$0], flat[$0 + 1], flat[$0 + 2]) }

    var faces: [[Int]] = []
    var offset = 0
    let indices = Array(data.indices).map(Int.init)
    for count in Array(data.counts).map(Int.init)
    {
      guard offset + count <= indices.count else { break }
      faces.append(Array(indices[offset ..< offset + count]))
      offset += count
    }

    var creases: [Kraken.Edge: Float] = [:]
    for (k, s) in data.creaseSharpness.enumerated()
    {
      creases[Kraken.Edge(Int(data.creases[2 * k]), Int(data.creases[2 * k + 1]))] = min(s / Kraken.EditMesh.creaseSharpness, 1)
    }

    let sharp = stride(from: 0, to: data.sharp.count - 1, by: 2).map { Kraken.Edge(Int(data.sharp[$0]), Int(data.sharp[$0 + 1])) }
    return Kraken.EditMesh(path: path, points: points, faces: faces, creases: creases, sharp: Set(sharp))
  }

  /// reads the widgets and the selection's transforms back from the stage
  func refresh()
  {
    guard !refreshing else { return }
    refreshing = true

    let rescan = rescan
    self.rescan = false
    let known = widgetPaths
    let selected = selection
    let editing = mode == .edit ? mesh?.path : nil
    let time = hydra.currentTimeCode
    onStage
    { [self] stage in
      let paths = rescan ? Kraken.SceneEdit.widgetPaths(stage) : known
      let widgets = Kraken.SceneEdit.widgets(stage, paths, time).map
      { o in
        Widget(path: String(o.path), kind: o.kind, world: Self.matrix(Array(o.world)), size: o.size,
               size2: o.size2, angle: o.angle, focalLength: o.focalLength,
               horizontalAperture: o.horizontalAperture, verticalAperture: o.verticalAperture)
      }

      var placements: [String: Placement] = [:]
      for path in selected + (editing.map { [$0] } ?? [])
      {
        if let placement = Self.placement(stage, path, time) { placements[path] = placement }
      }

      DispatchQueue.main.async
      { [weak self] in
        guard let self else { return }
        self.refreshing = false
        self.widgetPaths = paths
        if self.dragging != .light { self.widgets = widgets }

        for (path, placement) in placements where self.dragging == nil || !self.selection.contains(path)
        {
          self.placements[path] = placement
        }

        if let editing, let placement = placements[editing] { self.meshWorld = placement.world }
        if let path = self.active, path == self.inspector.path, let placement = self.placements[path]
        {
          self.inspector.follow(placement)
        }
      }
    }
  }

  enum Drag
  {
    case modal, light
  }

  nonisolated static func placement(_ stage: UsdStage, _ path: String, _ time: Double) -> Placement?
  {
    guard let placed = Kraken.SceneEdit.transform(stage, path, time) else { return nil }
    return Placement(local: matrix(placed.local), parent: matrix(placed.parent))
  }

  nonisolated static func matrix(_ a: [Double]) -> simd_double4x4
  {
    guard a.count == 16 else { return matrix_identity_double4x4 }
    return simd_double4x4(columns: (SIMD4(a[0], a[1], a[2], a[3]), SIMD4(a[4], a[5], a[6], a[7]),
                                    SIMD4(a[8], a[9], a[10], a[11]), SIMD4(a[12], a[13], a[14], a[15])))
  }

  nonisolated static func array(_ m: simd_double4x4) -> [Double]
  {
    [m.columns.0, m.columns.1, m.columns.2, m.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
  }
}
