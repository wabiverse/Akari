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
import SwiftCrossUI

extension AkariDemo
{
  /// The timeline's view of playback. Only play state is published, the frame is
  /// polled by the views that show it so playing doesn't rebuild the view tree.
  @MainActor
  final class Timeline: ObservableObject
  {
    @Published var isPlaying = false
    @Published var isReversed = false

    let playback: Akari.Playback

    private var poll: Task<Void, Never>?

    init(playback: Akari.Playback)
    {
      self.playback = playback
      refresh()
      poll = Task
      { [weak self] in
        while !Task.isCancelled
        {
          try? await Task.sleep(for: .milliseconds(50))
          self?.refresh()
        }
      }
    }

    var frame: Int
    {
      Int(playback.frame.rounded(.down))
    }

    func refresh()
    {
      let playing = playback.isPlaying
      if playing != isPlaying { isPlaying = playing }
      let reversed = playback.isReversed
      if reversed != isReversed { isReversed = reversed }
    }

    func toggle(reverse: Bool = false)
    {
      playback.toggle(reverse: reverse)
      refresh()
    }

    func seek(to frame: Int)
    {
      playback.seek(to: Double(frame))
      refresh()
    }

    func step(by frames: Int)
    {
      playback.step(by: frames)
      refresh()
    }

    func jump(toEnd: Bool)
    {
      playback.jump(toEnd: toEnd)
      refresh()
    }
  }
}
