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
import Foundation
import SwiftCrossUI
#if os(macOS)
  import AppKit
  import AppKitBackend
#endif

extension Kraken
{
  /// Playback controls over a ruler of frames to scrub.
  @MainActor
  struct TimelineView: View
  {
    @State private var timeline: Timeline
    @State private var job: RenderJob
    @State private var keyframes: Keyframes
    let layout: Layout
    /// Height below the header. 0 when collapsed to just the header.
    let bodyHeight: Double
    /// Called when switching editors, with true for the dope sheet.
    var editorChanged: (Bool) -> Void = { _ in }
    let openPlayback: () -> Void

    static let headerHeight = 26
    static let rulerHeight = 46
    static let height = headerHeight + rulerHeight

    init(timeline: Timeline, job: RenderJob, layout: Layout, bodyHeight: Double = Double(TimelineView.rulerHeight),
         editorChanged: @escaping (Bool) -> Void = { _ in }, openPlayback: @escaping () -> Void)
    {
      self.bodyHeight = bodyHeight
      self.editorChanged = editorChanged
      _timeline = State(wrappedValue: timeline)
      _job = State(wrappedValue: job)
      _keyframes = State(wrappedValue: layout.keyframes)
      self.layout = layout
      self.openPlayback = openPlayback
    }

    /// Switches between the timeline ruler and the dope sheet.
    private var editorToggle: some View
    {
      HStack(spacing: 1)
      {
        ForEach([false, true], id: \.self)
        { dope in
          Group
          {
            if dope
            {
              ZStack
              {
                DopeSheetIcon.Rows().stroke(Properties.label, style: StrokeStyle(width: 1))
                DopeSheetIcon.Keys().fill(Properties.text)
              }
            }
            else
            {
              TimelineIcon().stroke(Properties.text, style: StrokeStyle(width: 1.3))
            }
          }
          .frame(width: 14, height: 14)
          .frame(width: 26, height: 20)
          .background(RoundedRectangle(cornerRadius: 4)
            .fill(timeline.showsDopeSheet == dope ? Properties.accent : Properties.field))
            .onTapGesture
            {
              timeline.showsDopeSheet = dope
              editorChanged(dope)
            }
        }
      }
    }

    /// Auto Keying keys every edit on the current frame.
    private var autoKeyButton: some View
    {
      Circle()
        .fill(keyframes.autoKey ? Color(red: 0.88, green: 0.27, blue: 0.27) : Color(white: 0.55))
        .frame(width: 9, height: 9)
        .frame(width: 24, height: 20)
        .background(RoundedRectangle(cornerRadius: 4).fill(keyframes.autoKey ? Color(white: 0.42) : Properties.field))
        .onTapGesture { keyframes.autoKey.toggle() }
    }

    var body: some View
    {
      VStack(spacing: 0)
      {
        HStack(spacing: 6)
        {
          HStack(spacing: 4)
          {
            Text("Playback")
              .font(Properties.font)
              .foregroundColor(Properties.text)
            DisclosureChevron(expanded: true)
              .stroke(Properties.label, style: StrokeStyle(width: 1.2))
              .frame(width: 7, height: 7)
          }
          .padding(.horizontal, 6)
          .frame(height: 20)
          .onTapGesture { openPlayback() }

          editorToggle

          Spacer()

          HStack(spacing: 1)
          {
            TransportButton("backward.end.fill") { timeline.jump(toEnd: false) }
            TransportButton("backward.frame.fill") { timeline.step(by: -1) }
            TransportButton(timeline.isPlaying && timeline.isReversed ? "pause.fill" : "arrowtriangle.left.fill",
                            active: timeline.isPlaying && timeline.isReversed) { timeline.toggle(reverse: true) }
            TransportButton(timeline.isPlaying && !timeline.isReversed ? "pause.fill" : "arrowtriangle.right.fill",
                            active: timeline.isPlaying && !timeline.isReversed) { timeline.toggle() }
            TransportButton("forward.frame.fill") { timeline.step(by: 1) }
            TransportButton("forward.end.fill") { timeline.jump(toEnd: true) }
            autoKeyButton
          }

          Spacer()

          NumberField(value: Binding(get: { timeline.frame }, set: { timeline.seek(to: $0) }), width: 64, live: true)
          HStack(spacing: 1)
          {
            NumberField(value: job.$frameStart, label: "Start", width: 92)
            NumberField(value: job.$frameEnd, label: "End", width: 92)
          }
          .cornerRadius(4)
        }
        .padding(.horizontal, 6)
        .frame(height: Double(Self.headerHeight))
        .background(Properties.region)

        if bodyHeight > 0, timeline.showsDopeSheet
        {
          #if os(macOS)
            NativeDopeSheet(layout: layout, timeline: timeline, start: { job.frameStart }, end: { job.frameEnd })
              .frame(height: bodyHeight)
          #endif
        }
        else if bodyHeight > 0
        {
          TimelineRuler(frame: timeline.frame, start: job.frameStart, end: job.frameEnd)
          { timeline.seek(to: $0) }
          .frame(height: bodyHeight)
        }
      }
    }
  }

  @MainActor
  struct TransportButton: View
  {
    let symbol: () -> String
    let active: Bool
    let action: () -> Void

    @State private var hovered = false

    init(_ symbol: @autoclosure @escaping () -> String, active: Bool = false, action: @escaping () -> Void)
    {
      self.symbol = symbol
      self.active = active
      self.action = action
    }

    var body: some View
    {
      SymbolIcon(symbol(), size: 9, white: 0.85)
        .frame(width: 24, height: 20)
        .background(RoundedRectangle(cornerRadius: 4)
          .fill(active ? Properties.accent : hovered ? Properties.fieldHover : Properties.field))
        .onHover { hovered = $0 }
        .onTapGesture { action() }
    }
  }

  /// Frame numbers along the top, the playhead over them, a click or drag moves it.
  @MainActor
  struct TimelineRuler: View
  {
    let frame: () -> Int
    let start: () -> Int
    let end: () -> Int
    let scrub: (Int) -> Void

    init(frame: @autoclosure @escaping () -> Int, start: @autoclosure @escaping () -> Int,
         end: @autoclosure @escaping () -> Int, scrub: @escaping (Int) -> Void)
    {
      self.frame = frame
      self.start = start
      self.end = end
      self.scrub = scrub
    }

    var body: some View
    {
      VStack(spacing: 0)
      {
        #if os(macOS)
          NativeRuler(frame: frame, start: start, end: end, scrub: scrub)
        #endif
      }
    }
  }

  #if os(macOS)
    struct NativeRuler: NSViewRepresentable
    {
      let frame: () -> Int
      let start: () -> Int
      let end: () -> Int
      let scrub: (Int) -> Void

      func makeNSView(context _: Context) -> RulerView
      {
        RulerView()
      }

      func updateNSView(_ view: RulerView, context _: Context)
      {
        view.read = { (frame(), start(), max(end(), start())) }
        view.onScrub = scrub
        view.poll()
      }

      func sizeThatFits(_ proposal: ProposedViewSize, nsView _: RulerView, context _: Context) -> ViewSize
      {
        ViewSize(proposal.width ?? 400, proposal.height ?? Double(TimelineView.rulerHeight))
      }
    }

    final class RulerView: NSView
    {
      var current = 0
      var start = 1
      var end = 250
      var read: () -> (frame: Int, start: Int, end: Int) = { (0, 1, 250) }
      var onScrub: (Int) -> Void = { _ in }

      private let ticker = Ticker()

      override func viewDidMoveToWindow()
      {
        super.viewDidMoveToWindow()
        ticker.run(window != nil) { [weak self] in self?.poll() }
      }

      /// Redraws only when what it shows changed.
      func poll()
      {
        let now = read()
        guard now.frame != current || now.start != start || now.end != end else { return }
        (current, start, end) = now
        needsDisplay = true
      }

      private static let numbers = 20.0
      private static let background = NSColor(white: 0.157, alpha: 1)
      private static let band = NSColor(white: 0.19, alpha: 1)
      private static let outside = NSColor(white: 0, alpha: 0.18)
      private static let tick = NSColor(white: 0.24, alpha: 1)
      private static let accent = NSColor(srgbRed: 0.278, green: 0.447, blue: 0.702, alpha: 1)
      private static let label: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 10),
        .foregroundColor: NSColor(white: 0.7, alpha: 1),
      ]
      private static let playhead: [NSAttributedString.Key: Any] = [
        .font: NSFont.systemFont(ofSize: 10, weight: .medium),
        .foregroundColor: NSColor.white,
      ]

      override var isFlipped: Bool
      {
        true
      }

      override func acceptsFirstMouse(for _: NSEvent?) -> Bool
      {
        true
      }

      /// The frames shown, the scene's range with a little room either side.
      private var shown: (lo: Double, hi: Double)
      {
        let pad = max(Double(end - start) * 0.02, 2)
        return (Double(start) - pad, Double(end) + pad)
      }

      private func x(_ frame: Double) -> CGFloat
      {
        let shown = shown
        return CGFloat((frame - shown.lo) / (shown.hi - shown.lo)) * bounds.width
      }

      override func mouseDown(with event: NSEvent)
      {
        scrub(at: event)
      }

      override func mouseDragged(with event: NSEvent)
      {
        scrub(at: event)
      }

      private func scrub(at event: NSEvent)
      {
        let shown = shown
        let fraction = Double(convert(event.locationInWindow, from: nil).x / max(bounds.width, 1))
        let frame = Int((shown.lo + fraction * (shown.hi - shown.lo)).rounded())
        guard frame != current else { return }
        current = frame
        needsDisplay = true
        onScrub(frame)
      }

      override func draw(_: NSRect)
      {
        Self.background.setFill()
        bounds.fill()
        Self.band.setFill()
        NSRect(x: 0, y: 0, width: bounds.width, height: Self.numbers).fill()

        let pixelsPerFrame = Double(bounds.width) / (shown.hi - shown.lo)
        let steps = [1, 2, 5, 10, 20, 25, 50, 100, 200, 250, 500, 1000, 2000, 5000, 10000]
        let step = steps.first { Double($0) * pixelsPerFrame >= 56 } ?? 10000
        var frame = (Int(shown.lo.rounded(.up)) / step) * step
        while Double(frame) <= shown.hi
        {
          let px = x(Double(frame)).rounded() + 0.5
          Self.tick.setFill()
          NSRect(x: px - 0.5, y: Self.numbers, width: 1, height: bounds.height - Self.numbers).fill()
          let text = "\(frame)" as NSString
          let size = text.size(withAttributes: Self.label)
          text.draw(at: NSPoint(x: px - size.width / 2, y: (Self.numbers - size.height) / 2), withAttributes: Self.label)
          frame += step
        }

        Self.outside.setFill()
        NSRect(x: 0, y: Self.numbers, width: x(Double(start)), height: bounds.height - Self.numbers).fill()
        let endX = x(Double(end) + 1)
        NSRect(x: endX, y: Self.numbers, width: bounds.width - endX, height: bounds.height - Self.numbers).fill()

        let px = x(Double(current)).rounded()
        Self.accent.setFill()
        NSRect(x: px - 1, y: Self.numbers, width: 2, height: bounds.height - Self.numbers).fill()
        let text = "\(current)" as NSString
        let size = text.size(withAttributes: Self.playhead)
        let tag = NSRect(x: px - size.width / 2 - 6, y: 1, width: size.width + 12, height: Self.numbers - 2)
        NSBezierPath(roundedRect: tag, xRadius: 4, yRadius: 4).fill()
        text.draw(at: NSPoint(x: tag.midX - size.width / 2, y: tag.midY - size.height / 2), withAttributes: Self.playhead)
      }
    }
  #endif

  /// The Timeline editor icon, a clock.
  struct TimelineIcon: Shape
  {
    nonisolated func path(in bounds: Path.Rect) -> Path
    {
      let c = bounds.center
      let r = 0.45 * min(bounds.width, bounds.height)
      return Path()
        .addCircle(center: c, radius: r)
        .move(to: c)
        .addLine(to: SIMD2(c.x, c.y - 0.62 * r))
        .move(to: c)
        .addLine(to: SIMD2(c.x + 0.5 * r, c.y))
    }
  }

  /// The Dope Sheet editor icon, with key diamonds on two rows.
  enum DopeSheetIcon
  {
    static let rows = [0.3, 0.72]
    /// Each key as (x, row), in fractions of the icon.
    static let keys = [(0.3, 0), (0.75, 0), (0.55, 1)]

    struct Rows: Shape
    {
      nonisolated func path(in bounds: Path.Rect) -> Path
      {
        DopeSheetIcon.rows.reduce(Path())
        { path, row in
          let y = bounds.y + row * bounds.height
          return path.move(to: SIMD2(bounds.x, y)).addLine(to: SIMD2(bounds.x + bounds.width, y))
        }
      }
    }

    struct Keys: Shape
    {
      nonisolated func path(in bounds: Path.Rect) -> Path
      {
        let r = 0.2 * min(bounds.width, bounds.height)
        return DopeSheetIcon.keys.reduce(Path())
        { path, key in
          let c = SIMD2(bounds.x + key.0 * bounds.width, bounds.y + DopeSheetIcon.rows[key.1] * bounds.height)
          return path
            .move(to: SIMD2(c.x, c.y - r))
            .addLine(to: SIMD2(c.x + r, c.y))
            .addLine(to: SIMD2(c.x, c.y + r))
            .addLine(to: SIMD2(c.x - r, c.y))
            .addLine(to: SIMD2(c.x, c.y - r))
        }
      }
    }
  }
}
