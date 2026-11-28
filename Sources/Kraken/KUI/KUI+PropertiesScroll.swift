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
#endif

extension Kraken
{
  /// posted once a scene has opened and its panels are refreshed
  static let sceneOpened = Notification.Name("KrakenSceneOpened")

  /// a vertical scroll view that keeps its place from the top when its content grows or shrinks
  @MainActor
  struct PropertiesScroll<Content: View>: View
  {
    let content: Content

    init(@ViewBuilder content: () -> Content)
    {
      self.content = content()
    }

    var body: some View
    {
      ScrollView
      {
        #if os(macOS)
          content.background(ScrollTopAnchor())
        #else
          content
        #endif
      }
    }
  }
}

#if os(macOS)
  extension Kraken
  {
    /// the backend's scroll document isn't flipped, so appkit holds its place from the bottom and a taller panel pushes the top out of view
    struct ScrollTopAnchor: NSViewRepresentable
    {
      func makeNSView(context _: Context) -> ScrollTopAnchorView
      {
        ScrollTopAnchorView()
      }

      func updateNSView(_: ScrollTopAnchorView, context _: Context)
      {}

      func sizeThatFits(_: ProposedViewSize, nsView _: ScrollTopAnchorView, context _: Context) -> ViewSize
      {
        ViewSize(0, 0)
      }
    }

    /// flips its scroll view's document so it holds its place from the top, and goes back to the top whenever a scene opens
    final class ScrollTopAnchorView: NSView
    {
      nonisolated(unsafe) private var observer: NSObjectProtocol?

      override func viewDidMoveToWindow()
      {
        super.viewDidMoveToWindow()
        guard window != nil, let scrollView = enclosingScrollView else { return }

        if let document = scrollView.documentView as? NSStackView, !document.isFlipped
        {
          object_setClass(document, FlippedStackView.self)
          document.needsLayout = true
        }

        scrollToTop()
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: Kraken.sceneOpened, object: nil, queue: .main)
        { [weak self] _ in
          // the panels relayout for the new scene first, so this waits a turn of the run loop
          DispatchQueue.main.async { self?.scrollToTop() }
        }
      }

      private func scrollToTop()
      {
        guard let scrollView = enclosingScrollView else { return }
        scrollView.contentView.scroll(to: .zero)
        scrollView.reflectScrolledClipView(scrollView.contentView)
      }

      deinit
      {
        if let observer { NotificationCenter.default.removeObserver(observer) }
      }
    }

    /// the same stack view with its origin at the top
    final class FlippedStackView: NSStackView
    {
      override var isFlipped: Bool
      {
        true
      }
    }
  }
#endif
