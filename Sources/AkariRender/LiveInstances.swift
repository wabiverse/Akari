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

public extension Akari
{
  /// Instance matrices something else writes every frame, a simulation on
  /// the GPU say, drawn from the buffer it writes rather than recorded.
  enum LiveInstances
  {
    public struct Slot
    {
      /// Row major 4x4 float matrices, `count` of them.
      public var base: UnsafeMutableRawPointer?
      public var count: Int
      /// Bumped whenever a recording allocates a new buffer.
      public var version: Int
    }

    private static let lock = NSLock()
    private nonisolated(unsafe) static var slots: [String: Slot] = [:]

    /// Claims a prototype's instances, before the stage is first drawn.
    public static func register(prototype path: String, count: Int)
    {
      lock.lock()
      slots[path] = Slot(base: nil, count: count, version: 0)
      lock.unlock()
    }

    /// Whether any prototype's instances move without a rerecord.
    static var isEmpty: Bool
    {
      lock.lock()
      defer { lock.unlock() }
      return slots.isEmpty
    }

    public static func slot(_ path: String) -> Slot?
    {
      lock.lock()
      defer { lock.unlock() }
      return slots[path]
    }

    /// The prototype a rprim draws, hydra names it under the prototype's path.
    static func prototype(of rprim: String) -> (path: String, slot: Slot)?
    {
      lock.lock()
      defer { lock.unlock() }
      return slots.first { rprim == $0.key || rprim.hasPrefix($0.key + "/") }.map { ($0.key, $0.value) }
    }

    static func publish(_ path: String, base: UnsafeMutableRawPointer)
    {
      lock.lock()
      if var slot = slots[path]
      {
        slot.base = base
        slot.version += 1
        slots[path] = slot
      }

      lock.unlock()
    }
  }
}
