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
import SwiftCrossUI
#if os(macOS)
  import AppKit
#endif

#if os(macOS)
  extension Kraken.LayoutView
  {
    enum Menu
    {
      case add, delete, snap, shading, context, merge, view, select, object, mesh, mode, layer
    }

    final class Action: NSMenuItem
    {
      private let run: () -> Void

      init(_ title: String, _ key: String = "", _ modifiers: NSEvent.ModifierFlags = [], run: @escaping () -> Void)
      {
        self.run = run
        super.init(title: title, action: #selector(fire), keyEquivalent: key)
        keyEquivalentModifierMask = modifiers
        target = self
      }

      @available(*, unavailable)
      required init(coder _: NSCoder)
      {
        fatalError("init(coder:) is not supported")
      }

      @objc private func fire()
      {
        run()
      }
    }

    private static func submenu(_ title: String, _ items: [NSMenuItem]) -> NSMenuItem
    {
      let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      let menu = NSMenu(title: title)
      items.forEach(menu.addItem)
      item.submenu = menu
      return item
    }

    func menu(_ kind: Menu) -> NSMenu
    {
      let l = layout
      let edit = l.mode == .edit
      let menu = NSMenu()
      menu.autoenablesItems = false
      var items: [NSMenuItem] = []
      let snap: [NSMenuItem] = [Action("Cursor to Selected") { l.cursorToSelected() },
                  Action("Cursor to World Origin") { l.cursorToOrigin() },
                  Action("Selection to Cursor") { l.selectionToCursor() }]
      let transform: [NSMenuItem] = [Action("Move", "g") { [weak self] in self?.begin(.translate) },
                       Action("Rotate", "r") { [weak self] in self?.begin(.rotate) },
                       Action("Scale", "s") { [weak self] in self?.begin(.scale) }]
      let deletes: [NSMenuItem] = [Action("Vertices") { l.editMesh { mesh, _ in mesh.delete(.vertices) } },
                     Action("Edges") { l.editMesh { mesh, _ in mesh.delete(.edges) } },
                     Action("Faces") { l.editMesh { mesh, _ in mesh.delete(.faces) } },
                     Action("Only Faces") { l.editMesh { mesh, _ in mesh.delete(.faces) } }]
      let merges: [NSMenuItem] = [Action("At Center") { l.editMesh { mesh, _ in mesh.merge(at: nil) } },
                    Action("At Cursor") { [weak self] in self?.mergeAtCursor() },
                    Action("Collapse") { l.editMesh { mesh, _ in mesh.merge(at: nil) } },
                    Action("By Distance") { l.editMesh { mesh, _ in mesh.mergeByDistance(Float(0.0001 * l.unit)) } }]
      switch kind
      {
        case .add:
          items.append(header(edit ? "Add Mesh" : "Add"))
          let meshes: [NSMenuItem] = Kraken.AddKind.meshes.map { kind in Action(kind.label) { [weak self] in self?.add(kind) } }
          if edit
          {
            items += meshes
          }
          else
          {
            items.append(Self.submenu("Mesh", meshes))
            let lights: [NSMenuItem] = Kraken.AddKind.lights.map { kind in Action(kind.label) { l.add(kind) } }
            items.append(Self.submenu("Light", lights))
            items.append(Action(Kraken.AddKind.camera.label) { l.add(.camera) })
            items.append(Self.submenu("Empty", [Action("Plain Axes") { l.add(.empty) }]))
          }
        case .delete:
          if edit
          {
            items.append(header("Delete"))
            items += deletes
          }
          else
          {
            items.append(Action("Delete") { l.deleteSelected() })
          }
        case .snap:
          items.append(header("Snap"))
          items += snap
        case .shading:
          items.append(header("Shading"))
          items += [("Wireframe", ViewportShading.wireframe), ("Solid", .solid),
                    ("Material Preview", .materialPreview), ("Rendered", .rendered)].map
          { title, mode -> NSMenuItem in
            let item = Action(title) { l.setShading(mode) }
            item.state = l.shading == mode ? .on : .off
            return item
          }
        case .merge:
          items.append(header("Merge"))
          items += merges
        case .context where edit:
          items.append(header("Context Menu"))
          items += [Action("Subdivide") { l.editMesh { mesh, _ in mesh.subdivide() } },
                    Action("Extrude", "e") { [weak self] in self?.extrude() },
                    Action("Inset Faces", "i") { [weak self] in self?.begin(.inset) },
                    Action("Loop Cut", "r", .control) { [weak self] in self?.armLoopCut() },
                    Action("Fill", "f") { l.editMesh { mesh, _ in _ = mesh.fill() } },
                    Action("Duplicate", "d", .shift) { [weak self] in self?.duplicate() },
                    Action("Select Linked", "l", .control) { l.editMesh { mesh, _ in mesh.selectLinked() } },
                    .separator(), Self.submenu("Merge", merges), Self.submenu("Delete", deletes),
                    Self.submenu("Snap", snap)]
        case .context:
          items.append(header("Object Context Menu"))
          items += [Action("Duplicate Objects", "d", .shift) { [weak self] in self?.duplicate() },
                    Action("Delete") { l.deleteSelected() },
                    .separator(), Self.submenu("Snap", snap),
                    Action("Hide Selected", "h") { l.hideSelected() },
                    Action("Show Hidden", "h", .option) { l.unhideAll() },
                    Action("Frame Selected") { l.frameSelected() }]
        case .view:
          let toolbar = Action("Toolbar", "t") { [weak self] in self?.layout.showsToolbar.toggle() }
          toolbar.state = layout.showsToolbar ? .on : .off
          items += [toolbar, .separator(),
                    Action("Frame Selected") { l.frameSelected() },
                    Action("Frame All") { l.frameAll() },
                    .separator(),
                    Action("Camera") { [weak self] in self?.toggleCamera() },
                    Action("Align Active Camera to View") { l.alignCameraToView() },
                    .separator(),
                    Action("Top") { l.hydra.setStandardView(.top) },
                    Action("Front") { l.hydra.setStandardView(.front) },
                    Action("Right") { l.hydra.setStandardView(.right) }]
        case .select:
          items += [Action("All", "a") { l.selectAll() },
                    Action("None", "a", .option) { l.deselectAll() },
                    Action("Invert", "i", .control) { l.invertSelection() },
                    .separator(),
                    Action("Box Select", "b") { [weak self] in self?.boxArmed = true }]
          if edit
          {
            items.append(Action("Select Linked", "l", .control) { l.editMesh { mesh, _ in mesh.selectLinked() } })
          }
        case .object:
          items += [Self.submenu("Transform", transform),
                    Self.submenu("Clear", [Action("Location", "g", .option) { l.clear(.location) },
                                           Action("Rotation", "r", .option) { l.clear(.rotation) },
                                           Action("Scale", "s", .option) { l.clear(.scale) }]),
                    Self.submenu("Snap", snap),
                    .separator(),
                    Action("Duplicate Objects", "d", .shift) { [weak self] in self?.duplicate() },
                    Action("Delete") { l.deleteSelected() },
                    .separator(),
                    Self.submenu("Show/Hide", [Action("Show Hidden", "h", .option) { l.unhideAll() },
                                               Action("Hide Selected", "h") { l.hideSelected() }])]
        case .mesh:
          items += [Self.submenu("Transform", transform),
                    Action("Extrude", "e") { [weak self] in self?.extrude() },
                    Action("Inset Faces", "i") { [weak self] in self?.begin(.inset) },
                    Action("Subdivide") { l.editMesh { mesh, _ in mesh.subdivide() } },
                    Action("Loop Cut", "r", .control) { [weak self] in self?.armLoopCut() },
                    Action("Fill", "f") { l.editMesh { mesh, _ in _ = mesh.fill() } },
                    Action("Duplicate", "d", .shift) { [weak self] in self?.duplicate() },
                    .separator(), Self.submenu("Merge", merges), Self.submenu("Delete", deletes),
                    Self.submenu("Snap", snap)]
        case .mode:
          let object = Action("Object Mode") { l.exitEdit() }
          object.state = edit ? .off : .on
          let editing = Action("Edit Mode") { l.enterEdit() }
          editing.state = edit ? .on : .off
          items += [object, editing]
        case .layer:
          items.append(header("Edit Layer"))
          for layer in l.layers
          {
            let item = Action(layer.name) { l.work(in: layer.identifier) }
            item.state = layer.identifier == l.department ? .on : .off
            items.append(item)
          }

          items.append(.separator())
          items.append(Self.submenu("New Department Layer", Kraken.Authoring.Department.allCases.map
          { department in Action(department.rawValue) { l.newDepartment(department) } }))
      }

      items.forEach(menu.addItem)
      return menu
    }

    private func header(_ title: String) -> NSMenuItem
    {
      let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
      item.isEnabled = false
      return item
    }

    func popUp(_ kind: Menu, at p: CGPoint)
    {
      Kraken.MenuPanel.show(menu(kind), at: p, in: self)
    }

    func saveAs()
    {
      layout.askSaveAs()
    }

    private func armLoopCut()
    {
      loopCutArmed = true
      updateLoopCut()
    }

    private func mergeAtCursor()
    {
      let cursor = layout.cursor
      layout.editMesh
      { mesh, world in
        let p = world.inverse * SIMD4(cursor, 1)
        mesh.merge(at: SIMD3<Float>(SIMD3(p.x, p.y, p.z)))
      }
    }

    func add(_ kind: Kraken.AddKind)
    {
      guard layout.mode == .edit else
      {
        layout.add(kind)
        return
      }

      let cursor = layout.cursor
      let hydra = layout.hydra
      hydra.performOnFrameQueue
      { [self] in
        let data = Kraken.SceneEdit.primitive(hydra.stage, kind)
        let flat = Array(data.points), counts = Array(data.counts).map(Int.init), indices = Array(data.indices).map(Int.init)
        let valid = data.valid
        DispatchQueue.main.async
        { [weak self] in
          guard let self, valid else { return }
          self.layout.editMesh
          { mesh, world in
            let inverse = world.inverse
            let points = stride(from: 0, to: flat.count - 2, by: 3).map
            { i -> SIMD3<Float> in
              let p = inverse * SIMD4(cursor + SIMD3(Double(flat[i]), Double(flat[i + 1]), Double(flat[i + 2])), 1)
              return SIMD3<Float>(SIMD3(p.x, p.y, p.z))
            }

            var offset = 0
            var loops: [[Int]] = []
            for count in counts
            {
              loops.append(Array(indices[offset ..< offset + count]))
              offset += count
            }

            let made = mesh.add(points: points, faces: loops)
            mesh.select(faces: made)
          }
        }
      }
    }
  }
#endif
