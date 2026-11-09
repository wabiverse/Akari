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
  /// Which way an area collapses.
  enum CollapseDirection
  {
    case up, down, left, right
  }

  /// The draggable edge between two workspace areas. Drag to resize, drag past an area's
  /// minimum to collapse it, and double click to reset both sizes.
  struct AreaEdge: View
  {
    enum Axis
    {
      /// Between side by side areas, dragged left and right.
      case vertical
      /// Between stacked areas, dragged up and down.
      case horizontal
    }

    let axis: Axis
    /// The name of the area this edge can collapse, and which way it goes.
    var collapses: String? = nil
    var direction = CollapseDirection.down
    /// Called with the distance moved in points, positive right or down. Returns how close the
    /// area is to collapsing, from 0 at its minimum to 1 when it collapses.
    let drag: (Double) -> Double
    let reset: () -> Void
    var ended: () -> Void = {}

    static let thickness = 4.0

    var body: some View
    {
      #if os(macOS)
        NativeAreaEdge(axis: axis, collapses: collapses, direction: direction, drag: drag, reset: reset, ended: ended)
      #else
        Rectangle()
          .fill(Color(white: 0.09))
          .frame(width: axis == .vertical ? 1 : nil, height: axis == .horizontal ? 1 : nil)
      #endif
    }
  }

  #if os(macOS)
    struct NativeAreaEdge: NSViewRepresentable
    {
      let axis: AreaEdge.Axis
      let collapses: String?
      let direction: CollapseDirection
      let drag: (Double) -> Double
      let reset: () -> Void
      let ended: () -> Void

      func makeNSView(context _: Context) -> AreaEdgeView
      {
        AreaEdgeView()
      }

      func updateNSView(_ view: AreaEdgeView, context _: Context)
      {
        view.vertical = axis == .vertical
        view.collapses = collapses
        view.direction = direction
        view.onDrag = drag
        view.onReset = reset
        view.onEnd = ended
        view.needsDisplay = true
      }

      func sizeThatFits(_ proposal: ProposedViewSize, nsView _: AreaEdgeView, context _: Context) -> ViewSize
      {
        axis == .vertical
          ? ViewSize(AreaEdge.thickness, proposal.height ?? 10)
          : ViewSize(proposal.width ?? 10, AreaEdge.thickness)
      }
    }

    final class AreaEdgeView: NSView
    {
      var vertical = true
      var collapses: String?
      var direction = CollapseDirection.down
      var onDrag: (Double) -> Double = { _ in 0 }
      var onReset: () -> Void = {}
      var onEnd: () -> Void = {}
      private var last: NSPoint?
      private var hovered = false
      private var pending = 0.0
      private var flushTimer: Timer?

      override var isFlipped: Bool
      {
        true
      }

      override func acceptsFirstMouse(for _: NSEvent?) -> Bool
      {
        true
      }

      override func resetCursorRects()
      {
        addCursorRect(bounds, cursor: vertical ? .resizeLeftRight : .resizeUpDown)
      }

      override func updateTrackingAreas()
      {
        super.updateTrackingAreas()
        for area in trackingAreas where area.owner === self { removeTrackingArea(area) }
        addTrackingArea(NSTrackingArea(rect: bounds, options: [.mouseEnteredAndExited, .activeInKeyWindow],
                                       owner: self, userInfo: nil))
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
        if event.clickCount == 2
        {
          last = nil
          onReset()
          return
        }

        last = event.locationInWindow
        Akari.LabFXEngine.resizingArea = true

        let timer = Timer(timeInterval: 1.0 / 60.0, repeats: true)
        { [weak self] _ in
          MainActor.assumeIsolated
          {
            if NSEvent.pressedMouseButtons & 1 == 0 { self?.endDrag() } else { self?.flushPending() }
          }
        }
        RunLoop.main.add(timer, forMode: .common)
        flushTimer = timer
      }

      override func mouseDragged(with event: NSEvent)
      {
        guard let start = last else { return }
        let p = event.locationInWindow
        pending += vertical ? Double(p.x - start.x) : Double(start.y - p.y)
        last = p
      }

      override func mouseUp(with _: NSEvent)
      {
        endDrag()
      }

      override func viewWillMove(toWindow newWindow: NSWindow?)
      {
        super.viewWillMove(toWindow: newWindow)
        if newWindow == nil, last != nil { endDrag() }
      }

      private func endDrag()
      {
        guard last != nil else { return }
        flushPending()
        flushTimer?.invalidate()
        flushTimer = nil
        last = nil
        Akari.LabFXEngine.resizingArea = false
        CollapseArrowPanel.shared.hide()
        onEnd()
        needsDisplay = true
      }

      private func flushPending()
      {
        guard pending != 0 else { return }
        let delta = pending.rounded()
        guard delta != 0 else { return }
        pending -= delta
        let progress = onDrag(delta)
        if let collapses { CollapseArrowPanel.shared.show(over: collapses, direction: direction, progress: progress) }
      }

      override func draw(_: NSRect)
      {
        AreaChromeView.gap.setFill()
        bounds.fill()
        guard hovered || last != nil else { return }
        NSColor(white: 0.32, alpha: 1).setFill()
        vertical
          ? NSRect(x: bounds.midX - 0.5, y: 4, width: 1, height: max(bounds.height - 8, 0)).fill()
          : NSRect(x: 4, y: bounds.midY - 0.5, width: max(bounds.width - 8, 0), height: 1).fill()
      }
    }

    /// Rounds a workspace area's corners, and registers the area by name for the collapse arrow.
    struct AreaChrome: NSViewRepresentable
    {
      let name: String?

      func makeNSView(context _: Context) -> AreaChromeView
      {
        AreaChromeView()
      }

      func updateNSView(_ view: AreaChromeView, context _: Context)
      {
        view.name = name
        view.attach()
      }

      func sizeThatFits(_ proposal: ProposedViewSize, nsView _: AreaChromeView, context _: Context) -> ViewSize
      {
        ViewSize(proposal.width ?? 0, proposal.height ?? 0)
      }
    }

    final class AreaChromeView: NSView
    {
      static let gap = NSColor(white: 0.09, alpha: 1)
      static let radius: CGFloat = 6

      /// The named areas' containers, for the collapse arrow to cover.
      private static let areas = NSMapTable<NSString, NSView>.strongToWeakObjects()

      static func area(named name: String) -> NSView?
      {
        areas.object(forKey: name as NSString)
      }

      var name: String?

      override func hitTest(_: NSPoint) -> NSView?
      {
        nil
      }

      override func viewDidMoveToWindow()
      {
        super.viewDidMoveToWindow()
        attach()
      }

      /// The container shared with the area, skipping any wrappers around this view.
      private var container: NSView?
      {
        var view: NSView = self
        while let parent = view.superview, parent.subviews.count == 1 { view = parent }
        return view.superview
      }

      func attach()
      {
        guard window != nil, let container else { return }
        container.wantsLayer = true
        container.layer?.cornerRadius = Self.radius
        container.layer?.masksToBounds = true
        if let name { Self.areas.setObject(container, forKey: name as NSString) }
      }
    }

    /// The collapse arrow, shown over an area while its edge drags it toward collapsing.
    @MainActor
    final class CollapseArrowPanel
    {
      static let shared = CollapseArrowPanel()

      private let panel: NSPanel
      private let view = CollapseArrowView()
      private var watch: Timer?

      private init()
      {
        panel = NSPanel(contentRect: .zero, styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.ignoresMouseEvents = true
        panel.contentView = view
      }

      /// `progress` runs from 0 at the area's minimum to 1 when it collapses.
      func show(over name: String, direction: CollapseDirection, progress: Double)
      {
        guard progress > 0, progress < 1, let area = AreaChromeView.area(named: name), let window = area.window
        else { return hide() }

        panel.setFrame(window.convertToScreen(area.convert(area.bounds, to: nil)), display: false)
        view.direction = direction
        view.needsDisplay = true
        // Visible as soon as the edge passes the minimum, and fully a little before the area collapses.
        panel.alphaValue = CGFloat(0.3 + 0.7 * min(progress / 0.85, 1))
        if panel.parent !== window { window.addChildWindow(panel, ordered: .above) }

        // hides once the mouse button is up, even if nothing else says the drag ended.
        guard watch == nil else { return }
        let timer = Timer(timeInterval: 0.1, repeats: true)
        { [weak self] _ in
          MainActor.assumeIsolated { if NSEvent.pressedMouseButtons & 1 == 0 { self?.hide() } }
        }
        RunLoop.main.add(timer, forMode: .common)
        watch = timer
      }

      func hide()
      {
        watch?.invalidate()
        watch = nil
        panel.parent?.removeChildWindow(panel)
        panel.orderOut(nil)
      }
    }

    final class CollapseArrowView: NSView
    {
      var direction = CollapseDirection.down

      override init(frame: NSRect)
      {
        super.init(frame: frame)
        wantsLayer = true
      }

      required init?(coder: NSCoder)
      {
        super.init(coder: coder)
        wantsLayer = true
      }

      override var isFlipped: Bool
      {
        true
      }

      override func hitTest(_: NSPoint) -> NSView?
      {
        nil
      }

      override func draw(_: NSRect)
      {
        NSColor(white: 0, alpha: 0.4).setFill()
        bounds.fill()
        let size = min(48, min(bounds.width, bounds.height) * 0.6)
        guard size > 6 else { return }

        let c = NSPoint(x: bounds.midX, y: bounds.midY)
        // A down arrow, rotated to `direction`.
        let points: [(CGFloat, CGFloat)] = [(-0.18, -0.5), (0.18, -0.5), (0.18, 0.0), (0.5, 0.0), (0.0, 0.5), (-0.5, 0.0), (-0.18, 0.0)]
        let path = NSBezierPath()
        for (i, p) in points.enumerated()
        {
          let (x, y): (CGFloat, CGFloat) = switch direction
          {
            case .down: (p.0, p.1)
            case .up: (p.0, -p.1)
            case .right: (p.1, p.0)
            case .left: (-p.1, p.0)
          }
          let q = NSPoint(x: c.x + x * size, y: c.y + y * size)
          i == 0 ? path.move(to: q) : path.line(to: q)
        }
        path.close()
        NSColor(white: 1, alpha: 0.85).setFill()
        path.fill()
      }
    }
  #endif

}

extension View
{
  /// Styles a view as a workspace area with rounded corners. A `name` lets an edge show its collapse arrow over it.
  @MainActor
  func area(_ name: String? = nil) -> some View
  {
    #if os(macOS)
      background(Kraken.AreaChrome(name: name))
    #else
      self
    #endif
  }
}
