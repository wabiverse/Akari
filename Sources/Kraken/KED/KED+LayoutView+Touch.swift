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

import Foundation
import HydraKit
#if !os(macOS)
  import UIKit

  /// the viewport under fingers, one finger orbits or drags, two pan and pinch, a tap selects and multi finger taps undo and redo
  extension Kraken.LayoutView
  {
    struct TouchState
    {
      enum Drag
      {
        case none, orbit, press, pie
      }

      var drag = Drag.none
    }

    /// taps add to the selection while the toggle for it is on.
    private var extending: Bool
    {
      layout.extendsSelection
    }

    func installGestures()
    {
      let drag = UIPanGestureRecognizer(target: self, action: #selector(dragged(_:)))
      drag.maximumNumberOfTouches = 1

      let pan = UIPanGestureRecognizer(target: self, action: #selector(panned(_:)))
      pan.minimumNumberOfTouches = 2
      pan.maximumNumberOfTouches = 2
      pan.delegate = self

      let pinch = UIPinchGestureRecognizer(target: self, action: #selector(pinched(_:)))
      pinch.delegate = self

      let tap = UITapGestureRecognizer(target: self, action: #selector(tapped(_:)))
      let doubleTap = UITapGestureRecognizer(target: self, action: #selector(doubleTapped(_:)))
      doubleTap.numberOfTapsRequired = 2

      let undo = UITapGestureRecognizer(target: self, action: #selector(undoTapped))
      undo.numberOfTouchesRequired = 2
      let redo = UITapGestureRecognizer(target: self, action: #selector(redoTapped))
      redo.numberOfTouchesRequired = 3

      [drag, pan, pinch, tap, doubleTap, undo, redo].forEach(addGestureRecognizer)
      addInteraction(UIContextMenuInteraction(delegate: self))
    }

    // MARK: one finger

    @objc private func dragged(_ gesture: UIPanGestureRecognizer)
    {
      let p = gesture.location(in: self)
      switch gesture.state
      {
        case .began:
          layout.hydra.stopFlick()
          let translation = gesture.translation(in: self)
          beginDrag(at: CGPoint(x: p.x - translation.x, y: p.y - translation.y))
          gesture.setTranslation(CGPoint(x: p.x - mouse.x, y: p.y - mouse.y), in: self)
          moveDrag(gesture, to: p)
        case .changed:
          moveDrag(gesture, to: p)
        case .ended:
          endDrag(gesture)
        case .cancelled, .failed:
          if modal != nil { cancel() }
          press = nil
          box = nil
          touch.drag = .none
        default:
          break
      }
    }

    /// picks what a drag works on from where the finger first landed.
    private func beginDrag(at start: CGPoint)
    {
      mouse = start
      if pie != nil
      {
        touch.drag = .pie
      }
      else if var modal
      {
        // a transform started from a menu follows the finger from where it lands.
        modal.start = start
        modal.confirmOnRelease = true
        self.modal = modal
        touch.drag = .press
      }
      else if !boxArmed, let light = lightHandle(at: start)
      {
        beginLightDrag(light)
        touch.drag = .press
      }
      else if !boxArmed, let grabbed = handle(at: start)
      {
        begin(grabbed)
        touch.drag = .press
      }
      else if boxArmed
      {
        press = (start, extending)
        touch.drag = .press
      }
      else
      {
        touch.drag = .orbit
      }
    }

    private func moveDrag(_ gesture: UIPanGestureRecognizer, to p: CGPoint)
    {
      switch touch.drag
      {
        case .orbit:
          let d = gesture.translation(in: self)
          gesture.setTranslation(.zero, in: self)
          layout.hydra.orbit(deltaYaw: Double(d.x) * 0.4, deltaPitch: Double(d.y) * 0.4)
        case .press:
          _ = pressMoved(to: p)
        case .pie:
          mouse = p
          invalidate()
        case .none:
          break
      }
    }

    private func endDrag(_ gesture: UIPanGestureRecognizer)
    {
      switch touch.drag
      {
        case .orbit:
          // the release speed keeps the view turning, as a coast at the flick timer's rate.
          let velocity = gesture.velocity(in: self)
          layout.hydra.flick(deltaYaw: Double(velocity.x) / 60 * 0.4, deltaPitch: Double(velocity.y) / 60 * 0.4)
        case .press:
          _ = pressEnded()
        case .pie:
          choosePie()
        case .none:
          break
      }

      touch.drag = .none
    }

    // MARK: taps

    @objc private func tapped(_ gesture: UITapGestureRecognizer)
    {
      let p = gesture.location(in: self)
      mouse = p
      if pie != nil { return choosePie() }
      if isPicking() { return pickForProperty(at: p) }
      if modal != nil || loopCutArmed
      {
        _ = pressBegan(at: p, extend: extending)
        return
      }

      if navigationHit(p) { return }
      click(p, extend: extending)
    }

    /// in edit mode a double tap picks the edge loop under it, otherwise it frames the selection.
    @objc private func doubleTapped(_ gesture: UITapGestureRecognizer)
    {
      let p = gesture.location(in: self)
      if layout.mode == .edit { selectLoop(at: p, extend: extending) }
      else { layout.frameSelected() }
    }

    @objc private func undoTapped()
    {
      if !cancelPending() { layout.undo() }
    }

    @objc private func redoTapped()
    {
      layout.redo()
    }

    /// hands the tap to a property waiting to pick a point in the scene, focus distance and such.
    private func pickForProperty(at p: CGPoint)
    {
      let hydra = layout.hydra

      // the pick reads the point y up.
      hydra.pick(at: CGPoint(x: p.x, y: bounds.height - p.y), viewSize: bounds.size)
      { result in
        hydra.onPick?(result)
      }
    }

    // MARK: two fingers

    @objc private func panned(_ gesture: UIPanGestureRecognizer)
    {
      guard gesture.state == .changed || gesture.state == .began else { return }
      layout.hydra.stopFlick()
      let d = gesture.translation(in: self)
      gesture.setTranslation(.zero, in: self)
      layout.hydra.pan(deltaX: Double(d.x), deltaY: Double(d.y), viewHeight: Double(bounds.height))
    }

    @objc private func pinched(_ gesture: UIPinchGestureRecognizer)
    {
      guard gesture.state == .changed || gesture.state == .began, gesture.scale > 0 else { return }

      // spreading the fingers by a factor brings the camera that much closer.
      layout.hydra.dolly(by: Double(1 / gesture.scale) - 1)
      gesture.scale = 1
    }
  }

  extension Kraken.LayoutView: UIGestureRecognizerDelegate
  {
    /// two fingers pan and pinch at once.
    func gestureRecognizer(_: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool
    {
      other is UIPinchGestureRecognizer || (other as? UIPanGestureRecognizer)?.minimumNumberOfTouches == 2
    }
  }

  extension Kraken.LayoutView: UIContextMenuInteractionDelegate
  {
    func contextMenuInteraction(_: UIContextMenuInteraction,
                                configurationForMenuAtLocation location: CGPoint) -> UIContextMenuConfiguration?
    {
      guard modal == nil, pie == nil, touch.drag == .none else { return nil }

      // a long press on an object works on it, as long as nothing is selected yet.
      if layout.selection.isEmpty, layout.mode == .object { click(location, extend: false) }
      return UIContextMenuConfiguration(identifier: nil, previewProvider: nil)
      { [weak self] _ in
        MainActor.assumeIsolated
        {
          guard let self else { return nil }
          let entries = self.entries(.context) + [
            .separator,
            Entry("Place 3D Cursor Here") { [weak self] in self?.placeCursor(location) },
            Entry.submenu("Add", self.entries(.add).filter { !$0.isHeader }),
            Entry.submenu("Select", self.entries(.select)),
          ]
          return Kraken.MenuEntry.menu(entries)
        }
      }
    }

    /// the menu opens from a point under the finger, not a lifted copy of the whole viewport.
    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configuration _: UIContextMenuConfiguration,
                                highlightPreviewForItemWithIdentifier _: any NSCopying) -> UITargetedPreview?
    {
      targetedPreview(at: interaction.location(in: self))
    }

    func contextMenuInteraction(_ interaction: UIContextMenuInteraction,
                                configuration _: UIContextMenuConfiguration,
                                dismissalPreviewForItemWithIdentifier _: any NSCopying) -> UITargetedPreview?
    {
      targetedPreview(at: interaction.location(in: self))
    }

    private func targetedPreview(at point: CGPoint) -> UITargetedPreview
    {
      let marker = UIView(frame: CGRect(x: 0, y: 0, width: 24, height: 24))
      marker.backgroundColor = UIColor(white: 1, alpha: 0.25)
      marker.layer.cornerRadius = 12
      let parameters = UIPreviewParameters()
      parameters.backgroundColor = .clear
      parameters.visiblePath = UIBezierPath(ovalIn: marker.bounds)
      return UITargetedPreview(view: marker, parameters: parameters, target: UIPreviewTarget(container: self, center: point))
    }
  }
#endif
