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

import HydraKit
import SwiftCrossUI
#if os(macOS)
  import AppKit
  import AppKitBackend
#else
  import UIKit
#endif

extension Kraken
{
  /// a number slider, the value centered over a fill.
  @MainActor
  struct SliderField: View
  {
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let step: Double
    /// how wide it draws, the control column in a properties row or told explicitly anywhere else
    let width: Double?
    let format: (Double) -> String

    init(value: Binding<Double>, range: ClosedRange<Double>, step: Double, width: Double? = nil,
         format: @escaping (Double) -> String)
    {
      self.value = value
      self.range = range
      self.step = step
      self.width = width
      self.format = format
    }

    var body: some View
    {
      NativeView(make: { SliderView() },
                 update: { [value, range, step, format] view in
                   view.value = value.wrappedValue
                   view.range = range
                   view.step = step
                   view.format = format
                   view.onChange = { value.wrappedValue = $0 }
                   view.invalidate()
                 },
                 size: { [width] _ in ViewSize(width ?? Double(Properties.controlWidth), Double(Properties.rowHeight)) })
    }
  }

  enum SliderMetrics
  {
    /// the width of each end that steps the value.
    static let arrow = 16

    static func snap(_ v: Double, step: Double, range: ClosedRange<Double>) -> Double
    {
      min(max((v / step).rounded() * step, range.lowerBound), range.upperBound)
    }
  }

  /// drags set the value under the pointer and shift drags nudge it, under a finger a sideways drag nudges and a tap jumps
  final class SliderView: CanvasView
  {
    var value = 0.0
    var range = 0.0 ... 1.0
    var step = 0.01
    var format: (Double) -> String = { "\($0)" }
    var onChange: (Double) -> Void = { _ in }

    private var hovered = false
    private var drag: (x: CGFloat, value: Double, moved: Bool)?
    #if os(macOS)
      private var trackingArea: NSTrackingArea?
    #endif

    private static let field = PlatformColor(white: 0.33, alpha: 1)
    private static let fieldHover = PlatformColor(white: 0.4, alpha: 1)
    private static let accent = PlatformColor(srgbRed: 0.278, green: 0.447, blue: 0.702, alpha: 1)
    private static let text: [NSAttributedString.Key: Any] = [
      .font: PlatformFont.systemFont(ofSize: FormFactor.isTouch ? 13 : 11),
      .foregroundColor: PlatformColor(white: 0.9, alpha: 1),
    ]
    private static let arrow: [NSAttributedString.Key: Any] = [
      .font: PlatformFont.systemFont(ofSize: 13),
      .foregroundColor: PlatformColor(white: 0.9, alpha: 1),
    ]

    #if os(macOS)
      override func updateTrackingAreas()
      {
        super.updateTrackingAreas()
        if let trackingArea { removeTrackingArea(trackingArea) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
      }

      override func mouseEntered(with _: NSEvent)
      {
        hovered = true
        invalidate()
      }

      override func mouseExited(with _: NSEvent)
      {
        hovered = false
        invalidate()
      }

      private var fine: Bool
      {
        NSEvent.modifierFlags.contains(.shift)
      }
    #else
      /// a finger always nudges, it can't land precisely enough to set a value where it is.
      private var fine: Bool
      {
        true
      }
    #endif

    override func pointerDown(at point: CGPoint)
    {
      let arrow = CGFloat(SliderMetrics.arrow)
      if point.x < arrow || point.x > bounds.width - arrow
      {
        drag = nil
        set(value + (point.x < arrow ? -step : step))
        return
      }

      drag = (point.x, value, false)
      if !FormFactor.isTouch, !fine { set(at: point.x) }
    }

    override func pointerDragged(to point: CGPoint)
    {
      guard var drag else { return }
      drag.moved = drag.moved || abs(point.x - drag.x) > 4
      self.drag = drag
      guard drag.moved || !FormFactor.isTouch else { return }
      if fine
      {
        let span = range.upperBound - range.lowerBound

        // a finger sweeps the whole range across the slider, the shift key a tenth of it.
        let reach = FormFactor.isTouch ? 1.0 : 0.1
        set(drag.value + Double((point.x - drag.x) / max(bounds.width, 1)) * span * reach)
      }
      else
      {
        set(at: point.x)
      }
    }

    override func pointerUp(at point: CGPoint)
    {
      defer { drag = nil }
      if FormFactor.isTouch, let drag, !drag.moved { set(at: point.x) }
    }

    override func pointerCancelled()
    {
      drag = nil
      invalidate()
    }

    private func set(at x: CGFloat)
    {
      let fraction = Double(min(max(x / max(bounds.width, 1), 0), 1))
      set(range.lowerBound + fraction * (range.upperBound - range.lowerBound))
    }

    private func set(_ v: Double)
    {
      let snapped = SliderMetrics.snap(v, step: step, range: range)
      guard snapped != value else { return }
      value = snapped
      invalidate()
      onChange(snapped)
    }

    override func draw(_: CGRect)
    {
      let shape = PlatformBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4)
      (hovered ? Self.fieldHover : Self.field).setFill()
      shape.fill()

      let span = range.upperBound - range.lowerBound
      let fraction = span > 0 ? min(max((value - range.lowerBound) / span, 0), 1) : 0
      withSavedState
      {
        shape.addClip()
        Self.accent.setFill()
        CGRect(x: 0, y: 0, width: bounds.width * CGFloat(fraction), height: bounds.height).fill()
      }

      let label = format(value) as NSString
      let size = label.size(withAttributes: Self.text)
      label.draw(at: CGPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                 withAttributes: Self.text)

      guard hovered || FormFactor.isTouch, drag == nil else { return }
      let arrow = CGFloat(SliderMetrics.arrow)
      for (glyph, x) in [("‹", CGFloat(0)), ("›", bounds.width - arrow)]
      {
        let g = glyph as NSString
        let s = g.size(withAttributes: Self.arrow)
        g.draw(at: CGPoint(x: x + (arrow - s.width) / 2, y: (bounds.height - s.height) / 2), withAttributes: Self.arrow)
      }
    }
  }
}
