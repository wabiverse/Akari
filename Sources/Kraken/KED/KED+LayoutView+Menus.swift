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

extension Kraken.LayoutView
{
  typealias Entry = Kraken.MenuEntry

  enum Menu
  {
    case add, delete, snap, shading, context, merge, view, select, object, mesh, edge, mode, layer, sculptView, sculpt, mask, sculptAdd
  }

  func entries(_ kind: Menu) -> [Entry]
  {
    let l = layout
    let edit = l.mode == .edit
    var items: [Entry] = []

    let snap: [Entry] = [Entry("Cursor to Selected") { l.cursorToSelected() },
                         Entry("Cursor to World Origin") { l.cursorToOrigin() },
                         Entry("Selection to Cursor") { l.selectionToCursor() }]
    let transform: [Entry] = [Entry("Move", "g") { [weak self] in self?.begin(.translate) },
                              Entry("Rotate", "r") { [weak self] in self?.begin(.rotate) },
                              Entry("Scale", "s") { [weak self] in self?.begin(.scale) }]
    let deletes: [Entry] = [Entry("Vertices") { l.editMesh { mesh, _ in mesh.delete(.vertices) } },
                            Entry("Edges") { l.editMesh { mesh, _ in mesh.delete(.edges) } },
                            Entry("Faces") { l.editMesh { mesh, _ in mesh.delete(.faces) } },
                            Entry("Only Faces") { l.editMesh { mesh, _ in mesh.delete(.faces) } }]
    let edges: [Entry] = [Entry("Edge Crease", "e", .shift) { [weak self] in self?.begin(.crease) },
                          Entry("Mark Sharp") { l.editMesh { mesh, _ in mesh.markSharp(true) } },
                          Entry("Clear Sharp") { l.editMesh { mesh, _ in mesh.markSharp(false) } }]
    let subdivisions: [Entry] = [Entry("None", "0", .control) { l.setSubdivision(level: 0) }]
      + (1 ... 6).map { level in Entry("Level \(level)", "\(level)", .control) { l.setSubdivision(level: level) } }
    let merges: [Entry] = [Entry("At Center") { l.editMesh { mesh, _ in mesh.merge(at: nil) } },
                           Entry("At Cursor") { [weak self] in self?.mergeAtCursor() },
                           Entry("Collapse") { l.editMesh { mesh, _ in mesh.merge(at: nil) } },
                           Entry("By Distance") { l.editMesh { mesh, _ in mesh.mergeByDistance(Float(0.0001 * l.unit)) } }]

    // edit mode writes its mesh back first so the remesh reads the latest shape
    let remesh = { (faces: Int, symmetry: Int?) in
      if l.mode == .edit { l.exitEdit() }
      l.remesh(faces: faces, symmetry: symmetry)
    }
    let remeshes: [Entry] = [Entry("Low, 2k Faces") { remesh(2000, nil) },
                             Entry("Medium, 8k Faces") { remesh(8000, nil) },
                             Entry("High, 24k Faces") { remesh(24000, nil) },
                             Entry.separator,
                             Entry("Symmetric X, 8k Faces") { remesh(8000, 0) }]

    switch kind
    {
      case .add:
        items.append(Entry.header(edit ? "Add Mesh" : "Add"))

        let meshes: [Entry] = Kraken.AddKind.meshes.map { kind in Entry(kind.label) { [weak self] in self?.add(kind) } }
        if edit
        {
          items += meshes
        }
        else
        {
          items.append(Entry.submenu("Mesh", meshes))
          let lights: [Entry] = Kraken.AddKind.lights.map { kind in Entry(kind.label) { l.add(kind) } }
          items.append(Entry.submenu("Light", lights))
          items.append(Entry(Kraken.AddKind.camera.label) { l.add(.camera) })
          items.append(Entry.submenu("Empty", [Entry("Plain Axes") { l.add(.empty) }]))
        }
      case .delete:
        if edit
        {
          items.append(Entry.header("Delete"))
          items += deletes
        }
        else
        {
          items.append(Entry("Delete") { l.deleteSelected() })
        }
      case .snap:
        items.append(Entry.header("Snap"))
        items += snap
      case .shading:
        items.append(Entry.header("Shading"))
        items += [("Wireframe", ViewportShading.wireframe), ("Solid", .solid),
                  ("Material Preview", .materialPreview), ("Rendered", .rendered)].map
        { title, mode -> Entry in
          var item = Entry(title) { l.setShading(mode) }
          item.checked = l.shading == mode
          return item
        }
      case .merge:
        items.append(Entry.header("Merge"))
        items += merges
      case .context where edit:
        items.append(Entry.header("Context Menu"))
        items += [Entry("Subdivide") { l.editMesh { mesh, _ in mesh.subdivide() } },
                  Entry("Extrude", "e") { [weak self] in self?.extrude() },
                  Entry("Inset Faces", "i") { [weak self] in self?.begin(.inset) },
                  Entry("Loop Cut", "r", .control) { [weak self] in self?.armLoopCut() },
                  Entry("Fill", "f") { l.editMesh { mesh, _ in _ = mesh.fill() } },
                  Entry("Duplicate", "d", .shift) { [weak self] in self?.duplicate() },
                  Entry("Select Linked", "l", .control) { l.editMesh { mesh, _ in mesh.selectLinked() } },
                  Entry("Checker Deselect") { l.editMesh { mesh, _ in mesh.checkerDeselect() } },
                  Entry.separator] + edges + [
                  Entry.separator, Entry.submenu("Merge", merges), Entry.submenu("Delete", deletes),
                  Entry.submenu("Snap", snap)]
      case .context:
        items.append(Entry.header("Object Context Menu"))
        items += [Entry("Shade Smooth") { l.shade(smooth: true) },
                  Entry("Shade Flat") { l.shade(smooth: false) },
                  Entry.separator,
                  Entry.submenu("Subdivision", subdivisions),
                  Entry.submenu("Remesh", remeshes),
                  Entry.separator,
                  Entry("Duplicate Objects", "d", .shift) { [weak self] in self?.duplicate() },
                  Entry("Delete") { l.deleteSelected() },
                  Entry.separator, Entry.submenu("Snap", snap),
                  Entry("Hide Selected", "h") { l.hideSelected() },
                  Entry("Show Hidden", "h", .option) { l.unhideAll() },
                  Entry("Frame Selected") { l.frameSelected() }]
      case .view:
        var toolbar = Entry("Toolbar", "t") { [weak self] in self?.layout.showsToolbar.toggle() }
        toolbar.checked = layout.showsToolbar

        items += [toolbar, Entry.separator,
                  Entry("Frame Selected") { l.frameSelected() },
                  Entry("Frame All") { l.frameAll() },
                  Entry.separator,
                  Entry("Camera") { [weak self] in self?.toggleCamera() },
                  Entry("Align Active Camera to View") { l.alignCameraToView() },
                  Entry.separator,
                  Entry("Top") { l.hydra.setStandardView(.top) },
                  Entry("Front") { l.hydra.setStandardView(.front) },
                  Entry("Right") { l.hydra.setStandardView(.right) }]
      case .select:
        items += [Entry("All", "a") { l.selectAll() },
                  Entry("None", "a", .option) { l.deselectAll() },
                  Entry("Invert", "i", .control) { l.invertSelection() },
                  Entry.separator,
                  Entry("Box Select", "b") { [weak self] in self?.boxArmed = true }]

        if edit
        {
          items.append(Entry("Select Linked", "l", .control) { l.editMesh { mesh, _ in mesh.selectLinked() } })
          items.append(Entry("Checker Deselect") { l.editMesh { mesh, _ in mesh.checkerDeselect() } })
          items.append(Entry("Select Sharp Edges") { l.editMesh { mesh, _ in mesh.selectSharp() } })
        }
        else
        {
          items.append(Entry("Select Hierarchy", "]") { l.selectHierarchy() })
        }
      case .object:
        items += [Entry.submenu("Transform", transform),
                  Entry.submenu("Shading", [Entry("Shade Smooth") { l.shade(smooth: true) },
                                            Entry("Shade Flat") { l.shade(smooth: false) }]),
                  Entry.submenu("Subdivision", subdivisions),
                  Entry.submenu("Remesh", remeshes),
                  Entry.submenu("Clear", [Entry("Location", "g", .option) { l.clear(.location) },
                                         Entry("Rotation", "r", .option) { l.clear(.rotation) },
                                         Entry("Scale", "s", .option) { l.clear(.scale) }]),
                  Entry.submenu("Snap", snap),
                  Entry.separator,
                  Entry("Duplicate Objects", "d", .shift) { [weak self] in self?.duplicate() },
                  Entry("Delete") { l.deleteSelected() },
                  Entry("Join", "j", .control) { l.joinSelected() },
                  Entry.separator,
                  Entry("Parent to Active", "p", .control) { l.parentSelected() },
                  Entry.separator,
                  Entry.submenu("Show/Hide", [Entry("Show Hidden", "h", .option) { l.unhideAll() },
                                             Entry("Hide Selected", "h") { l.hideSelected() }])]
      case .mesh:
        items += [Entry.submenu("Transform", transform),
                  Entry("Extrude", "e") { [weak self] in self?.extrude() },
                  Entry("Inset Faces", "i") { [weak self] in self?.begin(.inset) },
                  Entry("Subdivide") { l.editMesh { mesh, _ in mesh.subdivide() } },
                  Entry("Loop Cut", "r", .control) { [weak self] in self?.armLoopCut() },
                  Entry("Fill", "f") { l.editMesh { mesh, _ in _ = mesh.fill() } },
                  Entry("Duplicate", "d", .shift) { [weak self] in self?.duplicate() },
                  Entry.separator, Entry.submenu("Merge", merges), Entry.submenu("Delete", deletes),
                  Entry.submenu("Snap", snap), Entry.separator, Entry.submenu("Remesh", remeshes)]
      case .edge:
        items.append(Entry.header("Edge"))
        items += edges + [Entry.separator,
                          Entry("Loop Cut", "r", .control) { [weak self] in self?.armLoopCut() },
                          Entry("Subdivide") { l.editMesh { mesh, _ in mesh.subdivide() } }]
      case .mode:
        let sculpting = l.tab == .sculpting
        var object = Entry("Object Mode") { if l.tab == .sculpting { l.open(.layout) } else { l.exitEdit() } }
        object.checked = !edit && !sculpting
        object.symbol = Kraken.Layout.objectSymbol

        var editing = Entry("Edit Mode") { if l.tab == .sculpting { l.open(.modeling) } else { l.enterEdit() } }
        editing.checked = edit && !sculpting
        editing.symbol = Kraken.Layout.editSymbol

        var sculpt = Entry("Sculpt Mode") { l.open(.sculpting) }
        sculpt.checked = sculpting
        sculpt.symbol = Kraken.Layout.sculptSymbol

        items += [object, editing, sculpt]
      case .sculptView:
        let sculpt = l.sculpt
        var toolbar = Entry("Toolbar") { l.showsToolbar.toggle() }
        toolbar.checked = l.showsToolbar
        var shelf = Entry("Asset Shelf") { sculpt.showsShelf.toggle() }
        shelf.checked = sculpt.showsShelf
        items += [toolbar, shelf, Entry.separator, Entry("Frame All", "f") { sculpt.viewport?.frameAll() }, Entry.separator]

        for look in Kraken.SculptShading.allCases
        {
          var item = Entry(look.rawValue) { sculpt.shading = look }
          item.checked = sculpt.shading == look
          items.append(item)
        }
      case .sculpt:
        let sculpt = l.sculpt
        items += [Entry("Smooth All") { sculpt.smoothAll() },
                  Entry("Fill Surface With Paint") { sculpt.fillPaint() },
                  Entry.submenu("Add Shape", Kraken.SculptShape.allCases.map
                  { shape in
                    Entry(shape.rawValue)
                    {
                      sculpt.shape = shape
                      sculpt.insertShape()
                    }
                  }),
                  Entry.separator,
                  Entry.submenu("Remesh", sculpt.remeshEntries),
                  Entry("Add Detail", "r", [.control]) { sculpt.addDetail() },
                  Entry("Reduce Detail", "r", [.control, .shift]) { sculpt.reduceDetail() },
                  Entry.separator,
                  Entry("Write to Scene Now") { sculpt.writeNow() }]
      case .sculptAdd:
        items.append(Entry.header("Add Mesh"))
        items += Kraken.AddKind.meshes.map { kind in Entry(kind.label) { l.add(kind) } }
      case .mask:
        let sculpt = l.sculpt
        var shows = Entry("Show Mask") { sculpt.showsMask.toggle() }
        shows.checked = sculpt.showsMask
        items += [Entry("Invert Mask") { sculpt.invertMask() },
                  Entry("Clear Mask") { sculpt.clearMask() },
                  Entry.separator,
                  shows]
      case .layer:
        items.append(Entry.header("Edit Layer"))

        for layer in l.layers
        {
          var item = Entry(layer.name) { l.work(in: layer.identifier) }
          item.checked = layer.identifier == l.department
          items.append(item)
        }

        items.append(Entry.separator)
        items.append(Entry.submenu("New Department Layer", Kraken.Authoring.Department.allCases.map
        { department in Entry(department.rawValue) { l.newDepartment(department) } }))
    }

    return items
  }

  /// opens a menu at `p` drawn the native way
  func popUp(_ kind: Menu, at p: CGPoint)
  {
    #if os(macOS)
      Kraken.MenuPanel.show(menu(kind), at: p, in: self)
    #else
      Entry.present(entries(kind), from: self, at: p)
    #endif
  }

  #if os(macOS)
    /// a menu item that runs a closure, used by the outliner's own menus
    typealias Action = Kraken.MenuAction

    func menu(_ kind: Menu) -> NSMenu
    {
      Entry.menu(entries(kind))
    }
  #endif

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

  func add(_ kind: Kraken.AddKind, options: Kraken.AddOptions = .standard)
  {
    guard layout.mode == .edit else
    {
      layout.add(kind, options: options)
      return
    }

    let cursor = layout.cursor
    let hydra = layout.hydra

    hydra.performOnFrameQueue
    { [self] in
      let data = Kraken.SceneEdit.primitive(hydra.stage, kind, options)
      let flat = Array(data.points)
      let counts = Array(data.counts).map(Int.init)
      let indices = Array(data.indices).map(Int.init)
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
