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
import SwiftCrossUI
#if os(macOS)
  import AppKit
#else
  import UIKit
#endif

// the native types kraken draws its custom views with, so one drawing body serves AppKit and UIKit.
#if os(macOS)
  typealias PlatformView = NSView
  typealias PlatformColor = NSColor
  typealias PlatformFont = NSFont
  typealias PlatformBezierPath = NSBezierPath
#else
  typealias PlatformView = UIView
  typealias PlatformColor = UIColor
  typealias PlatformFont = UIFont
  typealias PlatformBezierPath = UIBezierPath
#endif

extension Kraken
{
  /// how kraken is held and pointed at, which picks the workspace layout and control sizes.
  enum FormFactor
  {
    /// a mouse or trackpad, with a keyboard close by.
    case desktop
    /// fingers on glass.
    case touch

    static let current: FormFactor =
    {
      #if os(macOS)
        .desktop
      #else
        .touch
      #endif
    }()

    static var isTouch: Bool { current == .touch }

    /// the smallest side a control a finger has to hit should have.
    static var hitTarget: Double { isTouch ? 44 : 22 }
  }
}

extension PlatformView
{
  /// asks for the view to draw again.
  func invalidate()
  {
    #if os(macOS)
      needsDisplay = true
    #else
      setNeedsDisplay()
    #endif
  }

  /// the context the view is drawing into, inside `draw(_:)`.
  var drawingContext: CGContext?
  {
    #if os(macOS)
      NSGraphicsContext.current?.cgContext
    #else
      UIGraphicsGetCurrentContext()
    #endif
  }

  /// runs `draw` with the graphics state saved, so a clip or transform inside it stays inside it.
  func withSavedState(_ draw: () -> Void)
  {
    drawingContext?.saveGState()
    draw()
    drawingContext?.restoreGState()
  }
}

#if !os(macOS)
  // UIKit spellings of the AppKit drawing calls the shared views use.

  extension UIBezierPath
  {
    convenience init(roundedRect rect: CGRect, xRadius: CGFloat, yRadius _: CGFloat)
    {
      self.init(roundedRect: rect, cornerRadius: xRadius)
    }

    func line(to point: CGPoint)
    {
      addLine(to: point)
    }

    func curve(to point: CGPoint, controlPoint1: CGPoint, controlPoint2: CGPoint)
    {
      addCurve(to: point, controlPoint1: controlPoint1, controlPoint2: controlPoint2)
    }

    /// angles in degrees, sweeping the way AppKit does in a flipped view.
    func appendArc(withCenter center: CGPoint, radius: CGFloat, startAngle: CGFloat, endAngle: CGFloat,
                   clockwise: Bool = false)
    {
      addArc(withCenter: center, radius: radius, startAngle: startAngle * .pi / 180, endAngle: endAngle * .pi / 180,
             clockwise: !clockwise)
    }
  }

  extension UIColor
  {
    /// the color mixed toward white by `level`, from 0 to 1.
    func highlight(withLevel level: CGFloat) -> UIColor?
    {
      var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
      guard getRed(&r, green: &g, blue: &b, alpha: &a) else { return nil }
      return UIColor(red: r + (1 - r) * level, green: g + (1 - g) * level, blue: b + (1 - b) * level, alpha: a)
    }

    convenience init(srgbRed red: CGFloat, green: CGFloat, blue: CGFloat, alpha: CGFloat)
    {
      self.init(red: red, green: green, blue: blue, alpha: alpha)
    }
  }

  extension CGRect
  {
    /// fills the rectangle with the current fill color.
    func fill()
    {
      UIRectFill(self)
    }
  }
#endif
