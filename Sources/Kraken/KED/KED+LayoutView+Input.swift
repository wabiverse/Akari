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
  import MetalKit
#endif

#if os(macOS)
  extension Kraken.LayoutView
  {
    // MARK: events

    private var textEditing: Bool
    {
      window?.firstResponder is NSText
    }

    private func pointerInside() -> Bool
    {
      guard let window, !isHiddenOrHasHiddenAncestor else { return false }
      return bounds.contains(convert(window.convertPoint(fromScreen: NSEvent.mouseLocation), from: nil))
    }

    private func focusViewport()
    {
      if metal == nil, let content = window?.contentView { metal = Self.find(content) { $0 is MTKView } }
      if let metal, window?.firstResponder !== metal { window?.makeFirstResponder(metal) }
    }

    static func find(_ view: NSView, _ match: (NSView) -> Bool) -> NSView?
    {
      if match(view) { return view }
      for child in view.subviews
      {
        if let found = find(child, match) { return found }
      }

      return nil
    }

    /// The SwiftCrossUI controls over the viewport, the toolbar and the outline button, take their own clicks.
    private func passesThrough(_ p: CGPoint) -> Bool
    {
      let toolbar = CGRect(x: 8, y: 8, width: 28, height: CGFloat(Kraken.Layout.Tool.allCases.count) * 30)
      let outline = CGRect(x: bounds.maxX - 72, y: 10, width: 64, height: 32)
      return (layout.showsToolbar && toolbar.contains(p)) || outline.contains(p)
    }

    /// Whether a mouse event hits the viewport itself, and not a control or area on top of it.
    private func owns(_ event: NSEvent) -> Bool
    {
      guard let content = window?.contentView else { return false }
      let point = content.superview?.convert(event.locationInWindow, from: nil) ?? event.locationInWindow
      guard let hit = content.hitTest(point) else { return true }
      return hit is MTKView || isDescendant(of: hit)
    }

    func handle(_ event: NSEvent) -> Bool
    {
      guard !Kraken.MenuPanel.isOpen, !isMenuOpen() else { return false }
      guard let window, event.window === window || event.type == .keyDown else { return false }
      let p = convert(event.locationInWindow, from: nil)
      let inside = bounds.contains(p) && !isHiddenOrHasHiddenAncestor && (event.type == .keyDown || owns(event))
      switch event.type
      {
        case .mouseMoved:
          return handleMouseMoved(to: p, inside: inside)
        case .flagsChanged:
          if modal != nil { update() }
          return false
        case .leftMouseDown:
          return handleLeftDown(event, at: p, inside: inside)
        case .leftMouseDragged:
          return handleLeftDrag(event, to: p)
        case .leftMouseUp:
          return handleLeftUp(event)
        case .rightMouseDown:
          return handleRightDown(event, at: p, inside: inside)
        case .rightMouseUp:
          return inside
        case .otherMouseDown:
          guard inside else { return false }
          focusViewport()
          orbiting = true
          layout.hydra.stopFlick()
          return true
        case .otherMouseDragged:
          guard orbiting else { return false }
          navigate(dx: Double(event.deltaX), dy: Double(event.deltaY), flags: event.modifierFlags, drag: true)
          return true
        case .otherMouseUp:
          defer { orbiting = false }
          return orbiting
        case .scrollWheel:
          return handleScroll(event, inside: inside)
        case .keyDown:
          guard !textEditing, modal != nil || pointerInside() else { return false }
          return key(event)
        default:
          return false
      }
    }

    private func handleMouseMoved(to p: CGPoint, inside: Bool) -> Bool
    {
      mouse = p
      if modal != nil { update() }
      else if inside
      {
        lightHover = lightHandle(at: p)
        hover = lightHover == nil ? handle(at: p) : nil
      }

      if loopCutArmed { updateLoopCut() }
      return false
    }

    /// Option picks an edge loop, otherwise a click confirms a modal, cuts an armed loop,
    /// grabs a gizmo or light handle, or starts a click or box select.
    private func handleLeftDown(_ event: NSEvent, at p: CGPoint, inside: Bool) -> Bool
    {
      guard inside, !passesThrough(p) else { return false }
      mouse = p
      if isPicking() { return false }
      focusViewport()
      if event.modifierFlags.contains(.option)
      {
        guard layout.mode == .edit else { return false }
        loopPress = p
        return true
      }

      if modal != nil
      {
        confirm()
        return true
      }

      if loopCutArmed
      {
        if let loopCut { layout.editMesh { mesh, _ in mesh.loopCut(loopCut.edge) } }
        loopCutArmed = false
        loopCut = nil
        return true
      }

      if navigationHit(p) { return true }
      if !boxArmed, let light = lightHandle(at: p)
      {
        beginLightDrag(light)
        return true
      }

      if !boxArmed, let grabbed = handle(at: p)
      {
        begin(grabbed)
        return true
      }

      press = (p, event.modifierFlags.contains(.shift))
      return true
    }

    private func handleLeftDrag(_ event: NSEvent, to p: CGPoint) -> Bool
    {
      mouse = p
      if let start = loopPress
      {
        if hypot(p.x - start.x, p.y - start.y) > 4 || loopOrbiting
        {
          loopOrbiting = true
          navigate(dx: Double(event.deltaX), dy: Double(event.deltaY), flags: [], drag: true)
        }

        return true
      }

      if modal != nil
      {
        update()
        return true
      }

      if lightDrag != nil
      {
        updateLightDrag()
        return true
      }

      guard let press else { return false }
      if box != nil || hypot(p.x - press.point.x, p.y - press.point.y) > 4
      {
        box = CGRect(x: min(p.x, press.point.x), y: min(p.y, press.point.y),
                     width: abs(p.x - press.point.x), height: abs(p.y - press.point.y))
      }

      return true
    }

    private func handleLeftUp(_ event: NSEvent) -> Bool
    {
      if let start = loopPress
      {
        loopPress = nil
        if !loopOrbiting { selectLoop(at: start, extend: event.modifierFlags.contains(.shift)) }
        loopOrbiting = false
        return true
      }

      if let modal, modal.confirmOnRelease
      {
        confirm()
        return true
      }

      if let drag = lightDrag
      {
        lightDrag = nil
        layout.dragging = nil
        layout.refresh()
        layout.inspector.load(drag.widget.path)
        return true
      }

      guard let press else { return false }
      self.press = nil
      if let box
      {
        select(in: box, extend: press.extend)
        self.box = nil
        boxArmed = false
      }
      else
      {
        click(press.point, extend: press.extend)
      }

      return true
    }

    /// Cancels a modal or an armed loop cut, Shift places the 3D cursor, otherwise the context menu.
    private func handleRightDown(_ event: NSEvent, at p: CGPoint, inside: Bool) -> Bool
    {
      guard inside else { return false }
      focusViewport()
      if modal != nil
      {
        cancel()
        return true
      }

      if loopCutArmed
      {
        loopCutArmed = false
        loopCut = nil
        return true
      }

      if event.modifierFlags.contains(.shift)
      {
        placeCursor(p)
        return true
      }

      popUp(.context, at: p)
      return true
    }

    private func handleScroll(_ event: NSEvent, inside: Bool) -> Bool
    {
      guard inside else { return false }
      if event.hasPreciseScrollingDeltas
      {
        let s: CGFloat = event.isDirectionInvertedFromDevice ? 1 : -1
        navigate(dx: Double(event.scrollingDeltaX * s), dy: Double(event.scrollingDeltaY * s),
                 flags: event.modifierFlags, drag: false)
      }
      else
      {
        layout.hydra.dolly(by: -Double(event.scrollingDeltaY) * 0.1)
      }

      return true
    }

    /// Viewport navigation: a middle drag or a two finger swipe orbits, Shift pans and Ctrl zooms.
    private func navigate(dx: Double, dy: Double, flags: NSEvent.ModifierFlags, drag: Bool)
    {
      let hydra = layout.hydra
      hydra.stopFlick()
      if flags.contains(.shift)
      {
        hydra.pan(deltaX: drag ? dx : -dx, deltaY: drag ? dy : -dy, viewHeight: Double(bounds.height))
      }
      else if flags.contains(.control) || flags.contains(.command)
      {
        hydra.dolly(by: dy * 0.01)
      }
      else
      {
        hydra.orbit(deltaYaw: dx * 0.4, deltaPitch: dy * 0.4)
      }
    }

    // MARK: keys

    func key(_ event: NSEvent) -> Bool
    {
      let flags = event.modifierFlags
      let shift = flags.contains(.shift), alt = flags.contains(.option)
      let ctrl = flags.contains(.control) || flags.contains(.command)
      let code = Int(event.keyCode)
      let char = (event.charactersIgnoringModifiers ?? "").lowercased()

      if modal != nil { return modalKey(code, char, shift: shift) }

      if code == 53, loopCutArmed || boxArmed
      {
        loopCutArmed = false
        loopCut = nil
        boxArmed = false
        return true
      }

      if ctrl, char == "z"
      {
        shift ? layout.redo() : layout.undo()
        return true
      }

      if flags.contains(.command) { return documentKey(char, shift: shift) }

      let edit = layout.mode == .edit
      switch (code, char)
      {
        case (48, _):
          layout.toggleEdit()
        case (51, _), (117, _):
          if edit { popUp(.delete, at: mouse) } else { layout.deleteSelected() }
        case (115, _):
          layout.frameAll()
        case (65, _), (_, "."):
          guard !shift else { fallthrough }
          layout.frameSelected()
        case (82, _), (29, _):
          guard !edit || ctrl else { fallthrough }
          if ctrl, alt
          {
            layout.alignCameraToView()
          }
          else
          {
            toggleCamera()
          }
        case (_, "a") where shift:
          popUp(.add, at: mouse)
        case (_, "a") where alt:
          layout.deselectAll()
        case (_, "a"):
          layout.selectAll()
        case (_, "i") where ctrl:
          layout.invertSelection()
        case (_, "i") where alt && !edit:
          layout.keyframes.deleteTransforms(layout.selection)
        case (_, "i") where !edit:
          layout.keyframes.insertTransforms(layout.selection)
        case (_, "b"):
          boxArmed = true
        case (_, "x"):
          popUp(.delete, at: mouse)
        case (_, "g") where alt && !edit:
          layout.clear(.location)
        case (_, "r") where alt && !edit:
          layout.clear(.rotation)
        case (_, "s") where alt && !edit:
          layout.clear(.scale)
        case (_, "s") where shift:
          popUp(.snap, at: mouse)
        case (_, "g"):
          begin(.translate)
        case (_, "r") where ctrl && edit:
          loopCutArmed = true
          updateLoopCut()
        case (_, "r"):
          begin(.rotate)
        case (_, "s"):
          begin(.scale)
        case (_, "d") where shift:
          duplicate()
        case (_, "h") where alt && !edit:
          layout.unhideAll()
        case (_, "h") where !edit:
          layout.hideSelected()
        case (_, "c") where shift:
          layout.cursorToOrigin()
          layout.frameAll()
        case (_, "z") where shift && alt:
          layout.overlays.toggle()
        case (_, "z") where alt:
          layout.xray.toggle()
        case (_, "z") where shift:
          layout.toggleShading(.wireframe)
        case (_, "z"):
          popUp(.shading, at: mouse)
        case (_, "t"):
          layout.showsToolbar.toggle()
        case (_, "f") where !edit:
          // nothing in object mode, kept from the Hydra view's own frame selected.
          break
        case (_, "e") where edit:
          extrude()
        case (_, "i") where edit:
          begin(.inset)
        case (_, "f") where edit:
          layout.editMesh { mesh, _ in _ = mesh.fill() }
        case (_, "m") where edit:
          popUp(.merge, at: mouse)
        case (_, "l") where edit && ctrl:
          layout.editMesh { mesh, _ in mesh.selectLinked() }
        case (_, "l") where edit:
          linkedUnderMouse()
        case (_, "1") where edit:
          layout.setSelectMode(.vertex)
        case (_, "2") where edit:
          layout.setSelectMode(.edge)
        case (_, "3") where edit:
          layout.setSelectMode(.face)
        case (_, "w") where edit:
          popUp(.context, at: mouse)
        default:
          return false
      }

      return true
    }

    /// Command S saves, with Shift as a new file, Command N starts a scene and Command O opens one.
    private func documentKey(_ char: String, shift: Bool) -> Bool
    {
      switch char
      {
        case "s": shift ? saveAs() : layout.save()
        case "n": layout.newScene()
        case "o": layout.openScene()
        default: return false
      }

      return true
    }

    private func modalKey(_ code: Int, _ char: String, shift: Bool) -> Bool
    {
      guard var modal else { return false }
      switch (code, char)
      {
        case (53, _):
          cancel()
          return true
        case (36, _), (76, _):
          confirm()
          return true
        case (51, _):
          if !modal.numeric.isEmpty { modal.numeric.removeLast() }
        case (_, "x"), (_, "y"), (_, "z"):
          guard modal.kind != .inset, modal.along == nil else { return true }
          let i = char == "x" ? 0 : char == "y" ? 1 : 2
          if modal.axis == i, modal.plane == shift
          {
            if modal.local { modal.axis = nil }
            modal.local.toggle()
          }
          else
          {
            modal.axis = i
            modal.plane = shift
            modal.local = false
          }
        case (_, "-"):
          modal.numeric = modal.numeric.hasPrefix("-") ? String(modal.numeric.dropFirst()) : "-" + modal.numeric
        case (_, let c) where c.count == 1 && "0123456789.".contains(c):
          modal.numeric += c
        default:
          return true
      }

      self.modal = modal
      update()
      return true
    }
  }
#endif
