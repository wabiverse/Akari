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
#endif

extension Kraken
{
  /// A number slider, the value centered over a fill.
  @MainActor
  struct SliderField: View
  {
    let value: Binding<Double>
    let range: ClosedRange<Double>
    let step: Double
    let format: (Double) -> String

    #if !os(macOS)
      @State private var hovered = false

      private static let segments = 36
    #endif

    init(value: Binding<Double>, range: ClosedRange<Double>, step: Double, format: @escaping (Double) -> String)
    {
      self.value = value
      self.range = range
      self.step = step
      self.format = format
    }

    var body: some View
    {
      VStack(spacing: 0)
      {
        #if os(macOS)
          NativeSlider(value: value, range: range, step: step, format: format)
        #else
          tapSlider
        #endif
      }
    }

    #if !os(macOS)
      /// Without drags, clicked anywhere to jump there.
      private var tapSlider: some View
      {
        let width = Double(Properties.controlWidth)
        let v = value.wrappedValue
        let fraction = min(max((v - range.lowerBound) / (range.upperBound - range.lowerBound), 0), 1)
        let arrow = Double(SliderMetrics.arrow)
        let segment = (width - 2 * arrow) / Double(Self.segments)

        return RoundedRectangle(cornerRadius: 4)
          .fill(hovered ? Properties.fieldHover : Properties.field)
          .frame(width: width, height: Double(Properties.rowHeight))
          .overlay(alignment: .leading)
          {
            RoundedRectangle(cornerRadius: 4)
              .fill(Properties.accent)
              .frame(width: (width * fraction).rounded(), height: Double(Properties.rowHeight))
          }
          .overlay
          {
            Text(format(v))
              .font(Properties.font)
              .foregroundColor(Properties.text)
          }
          .onHover { hovered = $0 }
          .overlay
          {
            HStack(spacing: 0)
            {
              stepZone("‹", by: -step)
              ForEach(Array(0 ..< Self.segments), id: \.self)
              { i in
                Rectangle()
                  .fill(Color.clear)
                  .frame(width: segment, height: Double(Properties.rowHeight))
                  .onTapGesture
                  {
                    set(range.lowerBound + (range.upperBound - range.lowerBound) * Double(i) / Double(Self.segments - 1))
                  }
              }

              stepZone("›", by: step)
            }
          }
      }

      private func stepZone(_ glyph: String, by delta: Double) -> some View
      {
        Text(hovered ? glyph : "")
          .font(.system(size: 13))
          .foregroundColor(Properties.text)
          .frame(width: SliderMetrics.arrow, height: Properties.rowHeight)
          .onTapGesture { set(value.wrappedValue + delta) }
      }

      private func set(_ v: Double)
      {
        value.wrappedValue = SliderMetrics.snap(v, step: step, range: range)
      }
    #endif
  }

  enum SliderMetrics
  {
    /// The width of each end that steps the value.
    static let arrow = 16

    static func snap(_ v: Double, step: Double, range: ClosedRange<Double>) -> Double
    {
      min(max((v / step).rounded() * step, range.lowerBound), range.upperBound)
    }
  }

  #if os(macOS)
    /// The slider as an AppKit view,
    /// SwiftCrossUI has no drags.
    struct NativeSlider: NSViewRepresentable
    {
      let value: Binding<Double>
      let range: ClosedRange<Double>
      let step: Double
      let format: (Double) -> String

      func makeNSView(context _: Context) -> SliderView
      {
        SliderView()
      }

      func updateNSView(_ view: SliderView, context _: Context)
      {
        view.value = value.wrappedValue
        view.range = range
        view.step = step
        view.format = format
        view.onChange = { value.wrappedValue = $0 }
        view.needsDisplay = true
      }

      func sizeThatFits(_: ProposedViewSize, nsView _: SliderView, context _: Context) -> ViewSize
      {
        ViewSize(Double(Properties.controlWidth), Double(Properties.rowHeight))
      }
    }

    /// Drags set the value where the pointer
    /// is, shift drags nudge it finely.
    final class SliderView: NSView
    {
      var value = 0.0
      var range = 0.0 ... 1.0
      var step = 0.01
      var format: (Double) -> String = { "\($0)" }
      var onChange: (Double) -> Void = { _ in }

      private var hovered = false
      private var drag: (x: CGFloat, value: Double)?
      private var trackingArea: NSTrackingArea?

      private static let field = NSColor(white: 0.33, alpha: 1)
      private static let fieldHover = NSColor(white: 0.4, alpha: 1)
      private static let accent = NSColor(srgbRed: 0.278, green: 0.447, blue: 0.702, alpha: 1)
      private static let text: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 11),
        .foregroundColor: NSColor(white: 0.9, alpha: 1),
      ]
      private static let arrow: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 13),
        .foregroundColor: NSColor(white: 0.9, alpha: 1),
      ]

      override var isFlipped: Bool
      {
        true
      }

      override func acceptsFirstMouse(for _: NSEvent?) -> Bool
      {
        true
      }

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
        needsDisplay = true
      }

      override func mouseExited(with _: NSEvent)
      {
        hovered = false
        needsDisplay = true
      }

      override func mouseDown(with event: NSEvent)
      {
        let x = convert(event.locationInWindow, from: nil).x
        let arrow = CGFloat(SliderMetrics.arrow)
        if x < arrow || x > bounds.width - arrow
        {
          drag = nil
          set(value + (x < arrow ? -step : step))
          return
        }

        drag = (x, value)
        if !event.modifierFlags.contains(.shift) { set(at: x) }
      }

      override func mouseDragged(with event: NSEvent)
      {
        guard let drag else { return }
        let x = convert(event.locationInWindow, from: nil).x
        if event.modifierFlags.contains(.shift)
        {
          let span = range.upperBound - range.lowerBound
          set(drag.value + Double((x - drag.x) / max(bounds.width, 1)) * span * 0.1)
        }
        else
        {
          set(at: x)
        }
      }

      override func mouseUp(with _: NSEvent)
      {
        drag = nil
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
        needsDisplay = true
        onChange(snapped)
      }

      override func draw(_: NSRect)
      {
        let shape = NSBezierPath(roundedRect: bounds, xRadius: 4, yRadius: 4)
        (hovered ? Self.fieldHover : Self.field).setFill()
        shape.fill()

        let span = range.upperBound - range.lowerBound
        let fraction = span > 0 ? min(max((value - range.lowerBound) / span, 0), 1) : 0
        NSGraphicsContext.saveGraphicsState()
        shape.addClip()
        Self.accent.setFill()
        NSRect(x: 0, y: 0, width: bounds.width * CGFloat(fraction), height: bounds.height).fill()
        NSGraphicsContext.restoreGraphicsState()

        let label = format(value) as NSString
        let size = label.size(withAttributes: Self.text)
        label.draw(at: NSPoint(x: (bounds.width - size.width) / 2, y: (bounds.height - size.height) / 2),
                   withAttributes: Self.text)

        guard hovered, drag == nil else { return }
        let arrow = CGFloat(SliderMetrics.arrow)
        for (glyph, x) in [("‹", CGFloat(0)), ("›", bounds.width - arrow)]
        {
          let g = glyph as NSString
          let s = g.size(withAttributes: Self.arrow)
          g.draw(at: NSPoint(x: x + (arrow - s.width) / 2, y: (bounds.height - s.height) / 2), withAttributes: Self.arrow)
        }
      }
    }
  #endif
}
