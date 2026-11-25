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

/// a press, drag and release on the viewport, shared by the mouse and the finger
extension Kraken.LayoutView
{
  /// confirms a modal, cuts an armed loop, grabs a gizmo or light handle, or starts a click or box select
  func pressBegan(at p: CGPoint, extend: Bool) -> Bool
  {
    mouse = p

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

    press = (p, extend)
    return true
  }

  /// follows a modal, a light handle or a box select while the press moves
  func pressMoved(to p: CGPoint) -> Bool
  {
    mouse = p

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

  /// ends whatever the press started, a short press selects what is under it
  func pressEnded() -> Bool
  {
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

  /// leaves a modal, an armed loop cut or the pie without doing anything
  func cancelPending() -> Bool
  {
    if pie != nil
    {
      closePie()
      return true
    }

    if modal != nil
    {
      cancel()
      return true
    }

    if loopCutArmed || boxArmed
    {
      loopCutArmed = false
      loopCut = nil
      boxArmed = false
      return true
    }

    return false
  }
}
