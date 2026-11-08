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

import SwiftCrossUI
#if os(macOS)
  import AppKit
  import AppKitBackend
#endif

#if os(macOS)
  extension AkariDemo
  {
    /// Hosts the layout overlay over the viewport.
    struct LayoutOverlay
    {
      let layout: AkariDemo.Layout
      let isPicking: @MainActor () -> Bool
      let isMenuOpen: @MainActor () -> Bool
      let toggleCamera: @MainActor () -> Void
    }
  }

  extension AkariDemo.LayoutOverlay: NSViewRepresentable
  {
    func makeNSView(context _: Context) -> AkariDemo.LayoutView
    {
      let view = AkariDemo.LayoutView(layout: layout)
      view.isPicking = isPicking
      view.isMenuOpen = isMenuOpen
      view.toggleCamera = toggleCamera
      return view
    }

    func updateNSView(_ view: AkariDemo.LayoutView, context _: Context)
    {
      // The view outlives a `Workspace` re-init, so it must follow the current
      // layout instead of keeping the one it was made with.
      view.layout = layout
      view.isPicking = isPicking
      view.isMenuOpen = isMenuOpen
      view.toggleCamera = toggleCamera
      layout.viewport = view
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView _: AkariDemo.LayoutView, context _: Context) -> ViewSize
    {
      ViewSize(proposal.width ?? 800, proposal.height ?? 600)
    }

    static func dismantleNSView(_ nsView: AkariDemo.LayoutView, coordinator _: Void)
    {
      MainActor.assumeIsolated { nsView.stop() }
    }
  }
#endif
