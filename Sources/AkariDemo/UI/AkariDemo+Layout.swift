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

extension AkariDemo
{
  /// The 3D viewport's editing state: modes, tools, the selection and the 3D cursor.
  @MainActor
  final class Layout: ObservableObject
  {
    enum Mode
    {
      case object, edit
    }

    enum Tool: Int, CaseIterable
    {
      case select, cursor, move, rotate, scale, transform
    }

    enum Tab: String, CaseIterable
    {
      case layout = "Layout"
      case modeling = "Modeling"
      case shading = "Shading"
    }

    struct Widget
    {
      var path: String
      var kind: AkariDemo.SceneEdit.WidgetKind
      var world: simd_double4x4
      var size: Double
      var size2: Double
      var angle: Double
      var focalLength: Double
      var horizontalAperture: Double
      var verticalAperture: Double
    }

    struct Placement
    {
      var local: simd_double4x4
      var parent: simd_double4x4

      var world: simd_double4x4
      {
        parent * local
      }
    }

    @Published var tab: Tab = .layout
    @Published var mode: Mode = .object
    @Published var shading: ViewportShading = .rendered
    @Published var tool: Tool = .select
    @Published var selectMode: SelectMode = .vertex
    @Published var selection: [String] = []
    @Published var overlays = true
    {
      didSet { applyOverlays() }
    }
    /// The shot's layers, strongest first, and the department layer edits go to.
    @Published var layers: [(identifier: String, name: String)] = []
    @Published var department = ""
    @Published var xray = false
    @Published var showsToolbar = true

    #if os(macOS)
      weak var viewport: LayoutView?
    #endif
    var cursor = SIMD3<Double>.zero
    var widgets: [Widget] = []
    var placements: [String: Placement] = [:]
    var mesh: EditMesh?
    var meshWorld = matrix_identity_double4x4
    var status = ""

    let hydra: Hydra.RenderEngine
    let engine: Akari.RenderEngine
    let inspector: Inspector
    let driver: Akari.FrameDriver?
    let isZUp: Bool
    let metersPerUnit: Double

    /// Edits since the scene was opened or last saved.
    var edited = false
    /// The scene's file, nil for a new scene only in memory.
    var sceneURL: URL?
    /// The app's part of a scene change: its title, render output, playback range and probes.
    var adoptStage: (@MainActor (URL?, [Double]) -> Void)?
    /// Bumped whenever the scene's prims change, for views listing them.
    var sceneRevision = 0
    /// Set while a modal transform owns the selection's placements, or a light handle its widget.
    var dragging: Drag?
    var hidden: [String] = []

    var widgetPaths: [String] = []
    var rescan = true
    var refreshing = false

    /// The session layer and what was selected, an undo step.
    struct Step: Sendable
    {
      var text: String
      var selection: [String]
      var verts: Set<Int>
      var edges: Set<Edge>
      var faces: Set<Int>
    }

    var undoStack: [Step] = []
    var redoStack: [Step] = []

    private var step: (selection: [String], verts: Set<Int>, edges: Set<Edge>, faces: Set<Int>)
    {
      (selection, mesh?.verts ?? [], mesh?.edges ?? [], mesh?.selectedFaces ?? [])
    }

    var tabShading: [Tab: ViewportShading] = [.layout: .solid, .modeling: .solid, .shading: .materialPreview]
    let transformWriter = Writer()
    private let meshWriter = Writer()
    let lightWriter = Writer()
    private var timer: Timer?

    init(engine: Akari.RenderEngine, hydra: Hydra.RenderEngine, driver: any Akari.HydraFrameDriver)
    {
      self.engine = engine
      self.hydra = hydra
      self.driver = driver as? Akari.FrameDriver
      inspector = Inspector(hydra: hydra)
      isZUp = UsdGeom.getUpAxis(for: hydra.stage) == .z
      metersPerUnit = UsdGeom.getMetersPerUnit(for: hydra.stage)
      self.driver?.select(objects: [])
      setShading(tabShading[tab] ?? .solid)
      applyOverlays()
      inspector.layout = self
      let timer = Timer(timeInterval: 0.2, repeats: true) { [weak self] _ in
        MainActor.assumeIsolated { self?.refresh() }
      }

      RunLoop.main.add(timer, forMode: .common)
      self.timer = timer
    }

    /// One meter, in the stage's units.
    var unit: Double
    {
      1 / max(metersPerUnit, 1e-9)
    }

    var active: String?
    {
      selection.last
    }

    var up: SIMD3<Double>
    {
      isZUp ? SIMD3(0, 0, 1) : SIMD3(0, 1, 0)
    }

    // MARK: stage access

    /// Coalesces writes that only the latest of matters, a drag's transforms or points.
    final class Writer: @unchecked Sendable
    {
      private let lock = NSLock()
      private var pending: (@Sendable (UsdStage) -> Void)?
      private var scheduled = false

      func submit(_ hydra: Hydra.RenderEngine, _ work: @escaping @Sendable (UsdStage) -> Void)
      {
        let schedule = lock.withLock
        {
          pending = work
          defer { scheduled = true }
          return !scheduled
        }

        guard schedule else { return }
        hydra.performOnFrameQueue
        {
          let work = self.lock.withLock
          {
            defer
            {
              self.pending = nil
              self.scheduled = false
            }

            return self.pending
          }

          work?(hydra.stage)
        }
      }
    }

    func onStage(_ work: @escaping @Sendable (UsdStage) -> Void)
    {
      let hydra = hydra
      hydra.performOnFrameQueue { work(hydra.stage) }
    }

    /// Marks where the layer journal stands before an edit, for undo.
    func checkpoint()
    {
      edited = true
      let kept = step
      onStage
      { [self] stage in
        Authoring.watch(stage)
        let text = String(Pixar.HdAkariJournalPosition())
        DispatchQueue.main.async
        { [weak self] in
          guard let self else { return }
          self.undoStack.append(Step(text: text, selection: kept.selection, verts: kept.verts, edges: kept.edges,
                                     faces: kept.faces))
          if self.undoStack.count > 64 { self.undoStack.removeFirst() }
          self.redoStack.removeAll()
        }
      }
    }

    func undo()
    {
      guard let target = undoStack.popLast() else
      {
        status = "Nothing to undo"
        return
      }

      restore(target) { [weak self] current in self?.redoStack.append(current) }
    }

    func redo()
    {
      guard let target = redoStack.popLast() else
      {
        status = "Nothing to redo"
        return
      }

      restore(target) { [weak self] current in self?.undoStack.append(current) }
    }

    private func restore(_ target: Step, keep: @escaping @MainActor @Sendable (Step) -> Void)
    {
      let editing = mode == .edit ? mesh?.path : nil
      let time = hydra.currentTimeCode
      let now = step
      onStage
      { [self] stage in
        let current = String(Pixar.HdAkariJournalPosition())
        Pixar.HdAkariJournalSeek(Int(target.text) ?? 0)
        let reloaded = editing.map { Self.readMesh(stage, $0, time) } ?? nil
        DispatchQueue.main.async
        { [weak self] in
          guard let self else { return }
          keep(Step(text: current, selection: now.selection, verts: now.verts, edges: now.edges, faces: now.faces))
          if editing != nil
          {
            if var next = reloaded
            {
              next.mode = self.selectMode
              let count = next.points.count
              next.verts = target.verts.filter { $0 < count }
              next.edges = target.edges.filter { $0.b < count }
              next.selectedFaces = target.faces.filter { $0 < next.faces.count }
              self.mesh = next
            }
            else
            {
              self.exitEdit()
            }
          }

          self.primsChanged()
          self.select(target.selection)
        }
      }
    }

    /// Writes the scene's changed layers, a new scene to the file it asks for, `path` saving it as that file instead.
    func save(as path: String? = nil, then done: (@MainActor () -> Void)? = nil)
    {
      guard path != nil || !isUntitled else
      {
        askSaveAs(then: done)
        return
      }

      onStage
      { [self] stage in
        let saved = Authoring.save(stage, as: path)
        DispatchQueue.main.async
        { [weak self] in
          guard let self else { return }
          self.status = !saved ? "Couldn't save" : path.map { "Saved \(URL(fileURLWithPath: $0).lastPathComponent)" } ?? "Saved"
          guard saved else { return }
          self.edited = false
          self.undoStack.removeAll()
          self.redoStack.removeAll()
          // saved as another file, that file is the scene from now on.
          if let path { self.replaceStage(with: URL(fileURLWithPath: path), asking: false) }
          else { self.primsChanged() }
          done?()
        }
      }
    }

    // MARK: edit mode

    /// Runs `body` on the edit mesh as one undoable edit, then writes it.
    func editMesh(_ body: (inout EditMesh, simd_double4x4) -> Void)
    {
      guard var current = mesh else { return }
      checkpoint()
      body(&current, meshWorld)
      mesh = current
      writeMesh()
    }

    func writeMesh()
    {
      guard let mesh else { return }
      let path = mesh.path
      let flat = mesh.points.flatMap { [$0.x, $0.y, $0.z] }
      let counts = mesh.faces.map { Int32($0.count) }
      let indices = mesh.faces.flatMap { $0.map(Int32.init) }
      meshWriter.submit(hydra)
      { stage in
        SceneEdit.setMesh(stage, path, flat, counts, indices)
      }
    }
  }
}
