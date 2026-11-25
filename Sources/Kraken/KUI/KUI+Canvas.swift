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
  import AppKitBackend
#else
  import UIKit
  import UIKitBackend
#endif

extension Kraken
{
  /// a view that cleans up after itself once SwiftCrossUI takes it down, its timers or monitors.
  @MainActor
  protocol Dismantling: AnyObject
  {
    func dismantle()
  }

  /// a view that draws itself top down and follows one pointer, a mouse or the first finger
  class CanvasView: PlatformView
  {
    init()
    {
      super.init(frame: .zero)
      #if os(macOS)
        wantsLayer = true
      #else
        isOpaque = false
        backgroundColor = .clear
        contentMode = .redraw
      #endif
    }

    @available(*, unavailable)
    required init?(coder _: NSCoder)
    {
      fatalError("init(coder:) is not supported")
    }

    /// the pointer went down at `point`, in the view's top down coordinates.
    func pointerDown(at _: CGPoint) {}

    /// the pointer moved to `point` while down.
    func pointerDragged(to _: CGPoint) {}

    /// the pointer came up.
    func pointerUp(at _: CGPoint) {}

    /// the system took the touch away, a scroll around the view claimed it, so nothing it started should land.
    func pointerCancelled() {}

    /// two quick presses in the same place.
    func pointerDoubleTapped(at _: CGPoint) {}

    #if os(macOS)
      override var isFlipped: Bool { true }

      override func acceptsFirstMouse(for _: NSEvent?) -> Bool { true }

      private func location(_ event: NSEvent) -> CGPoint
      {
        convert(event.locationInWindow, from: nil)
      }

      override func mouseDown(with event: NSEvent)
      {
        if event.clickCount == 2 { pointerDoubleTapped(at: location(event)) }
        else { pointerDown(at: location(event)) }
      }

      override func mouseDragged(with event: NSEvent)
      {
        pointerDragged(to: location(event))
      }

      override func mouseUp(with event: NSEvent)
      {
        pointerUp(at: location(event))
      }
    #else
      private weak var tracked: UITouch?

      override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?)
      {
        guard tracked == nil, let touch = touches.first else { return super.touchesBegan(touches, with: event) }
        tracked = touch
        let point = touch.location(in: self)
        if touch.tapCount == 2 { pointerDoubleTapped(at: point) }
        else { pointerDown(at: point) }
      }

      override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?)
      {
        guard let tracked, touches.contains(tracked) else { return super.touchesMoved(touches, with: event) }
        pointerDragged(to: tracked.location(in: self))
      }

      override func touchesEnded(_ touches: Set<UITouch>, with event: UIEvent?)
      {
        guard let tracked, touches.contains(tracked) else { return super.touchesEnded(touches, with: event) }
        self.tracked = nil
        pointerUp(at: tracked.location(in: self))
      }

      override func touchesCancelled(_ touches: Set<UITouch>, with event: UIEvent?)
      {
        guard let tracked, touches.contains(tracked) else { return super.touchesCancelled(touches, with: event) }
        self.tracked = nil
        pointerCancelled()
      }
    #endif
  }

  /// calls back about thirty times a second while running, for views that follow playback
  final class Ticker
  {
    private var timer: Timer?

    func run(_ running: Bool, _ tick: @escaping @MainActor () -> Void)
    {
      guard running != (timer != nil) else { return }
      timer?.invalidate()
      timer = nil
      guard running else { return }
      let timer = Timer(timeInterval: 1.0 / 30.0, repeats: true) { _ in MainActor.assumeIsolated { tick() } }
      RunLoop.main.add(timer, forMode: .common)
      self.timer = timer
    }

    deinit
    {
      timer?.invalidate()
    }
  }

  /// hosts a native view in a SwiftCrossUI layout, made once and brought up to date on every update.
  struct NativeView<Content: PlatformView>
  {
    let make: @MainActor () -> Content
    var update: @MainActor (Content) -> Void = { _ in }
    /// the size the view takes from what it's offered.
    var size: @MainActor (ProposedViewSize) -> ViewSize = { ViewSize($0.width ?? 100, $0.height ?? 100) }
  }
}

#if os(macOS)
  extension Kraken.NativeView: NSViewRepresentable
  {
    func makeNSView(context _: Context) -> Content
    {
      make()
    }

    func updateNSView(_ view: Content, context _: Context)
    {
      update(view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView _: Content, context _: Context) -> ViewSize
    {
      size(proposal)
    }

    static func dismantleNSView(_ view: Content, coordinator _: Void)
    {
      MainActor.assumeIsolated { (view as? Kraken.Dismantling)?.dismantle() }
    }
  }
#else
  extension Kraken.NativeView: UIViewRepresentable
  {
    func makeUIView(context _: Context) -> Content
    {
      make()
    }

    func updateUIView(_ view: Content, context _: Context)
    {
      update(view)
    }

    func sizeThatFits(_ proposal: ProposedViewSize, uiView _: Content, context _: Context) -> ViewSize
    {
      size(proposal)
    }

    static func dismantleUIView(_ view: Content, coordinator _: Void)
    {
      MainActor.assumeIsolated { (view as? Kraken.Dismantling)?.dismantle() }
    }
  }
#endif
