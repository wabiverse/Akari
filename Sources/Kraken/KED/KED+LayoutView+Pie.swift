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
import Foundation
#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

extension Kraken.LayoutView
{
  /// a radial menu opened at the pointer, its item picked by the way the pointer heads from there
  struct Pie
  {
    struct Item
    {
      var title: String
      var on = false
      var run: () -> Void
    }

    var center: CGPoint
    /// left, right, bottom and top, then the corners
    var items: [Item]
    var opened = Date()
    /// the key that opened it, which picks the highlighted item when let go after a drag
    var key: UInt16
  }

  static let pieRadius: CGFloat = 104
  static let pieDeadZone: CGFloat = 20
  /// how long a key has to be held before letting it go picks, so a tap leaves the pie open
  static let pieHold: TimeInterval = 0.25

  /// the way each slot lies from the middle, with the view's y running down
  static func pieDirection(_ slot: Int) -> CGVector
  {
    let s = CGFloat(0.5).squareRoot()
    let directions = [CGVector(dx: -1, dy: 0), CGVector(dx: 1, dy: 0), CGVector(dx: 0, dy: 1), CGVector(dx: 0, dy: -1),
                      CGVector(dx: -s, dy: -s), CGVector(dx: s, dy: -s), CGVector(dx: -s, dy: s), CGVector(dx: s, dy: s)]

    return directions[slot % directions.count]
  }

  /// z switches the viewport shading
  func openShadingPie(key: UInt16)
  {
    let l = layout
    let modes: [(String, ViewportShading)] = [("Wireframe", .wireframe), ("Solid", .solid),
                                              ("Material Preview", .materialPreview), ("Rendered", .rendered)]
    let items = modes.map { title, mode in Pie.Item(title: title, on: l.shading == mode) { l.setShading(mode) } }

    pie = Pie(center: mouse, items: items, key: key)
    invalidate()
  }

  /// the item the pointer heads toward, none while it stays near the middle
  var pieChoice: Int?
  {
    guard let pie else { return nil }

    let dx = mouse.x - pie.center.x
    let dy = mouse.y - pie.center.y
    guard hypot(dx, dy) > Self.pieDeadZone else { return nil }

    return pie.items.indices.max
    {
      let a = Self.pieDirection($0)
      let b = Self.pieDirection($1)
      return a.dx * dx + a.dy * dy < b.dx * dx + b.dy * dy
    }
  }

  /// runs the highlighted item, or just closes the pie when there is none
  func choosePie()
  {
    let item = pieChoice.flatMap { pie?.items[$0] }

    pie = nil
    invalidate()
    item?.run()
  }

  func closePie()
  {
    pie = nil
    invalidate()
  }

  #if os(macOS)
    /// letting go of the key that opened it after holding it picks what it heads toward
    func pieKeyUp(_ event: NSEvent) -> Bool
    {
      guard let pie, event.keyCode == pie.key else { return false }

      if Date().timeIntervalSince(pie.opened) > Self.pieHold, pieChoice != nil { choosePie() }

      return true
    }
  #endif

  func drawPie()
  {
    guard let pie else { return }

    let c = pie.center
    let choice = pieChoice
    dot(c, Self.pieDeadZone - 6, PlatformColor(white: 0.12, alpha: 0.85), outline: PlatformColor(white: 1, alpha: 0.25))

    if choice != nil
    {
      // a short arc on the ring points the way the pointer heads
      let angle = atan2(mouse.y - c.y, mouse.x - c.x)
      let arc = PlatformBezierPath()
      arc.appendArc(withCenter: c, radius: Self.pieDeadZone - 6, startAngle: (angle - 0.5) * 180 / .pi,
                    endAngle: (angle + 0.5) * 180 / .pi)
      arc.lineWidth = 3
      Self.accent.setStroke()
      arc.stroke()
    }

    let font = PlatformFont.systemFont(ofSize: 12, weight: .medium)

    for (i, item) in pie.items.enumerated()
    {
      let d = Self.pieDirection(i)
      let size = (item.title as NSString).size(withAttributes: [.font: font])
      let width = size.width + 28
      let height: CGFloat = 24

      // side slots hang off the ring by their near edge, top and bottom ones sit centered on it
      let middle = CGPoint(x: c.x + d.dx * (Self.pieRadius + abs(d.dx) * width / 2 - abs(d.dx) * 40),
                           y: c.y + d.dy * Self.pieRadius)
      let rect = CGRect(x: middle.x - width / 2, y: middle.y - height / 2, width: width, height: height)
      let path = PlatformBezierPath(roundedRect: rect, xRadius: 6, yRadius: 6)

      (i == choice ? Self.accent : PlatformColor(white: 0.16, alpha: 0.92)).setFill()
      path.fill()
      PlatformColor(white: 1, alpha: 0.12).setStroke()
      path.lineWidth = 1
      path.stroke()

      if item.on { dot(CGPoint(x: rect.minX + 11, y: rect.midY), 3, PlatformColor(white: 1, alpha: 0.9)) }
      text(item.title, at: CGPoint(x: rect.midX + (item.on ? 5 : 0), y: rect.midY - size.height / 2), size: 12,
           centered: true, shadow: false)
    }
  }
}
