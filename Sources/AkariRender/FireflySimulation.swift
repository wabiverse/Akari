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
  /// Firefly positions, computed on a dedicated background thread.
  final class FireflySimulation: @unchecked Sendable
  {
    public static let count = 32

    /// Per step delay, in milliseconds.
    public var stepDelayMS: Int = 0

    public private(set) var current: [SIMD4<Float>] = Array(repeating: .zero, count: FireflySimulation.count)

    private let lock = NSLock()
    private var pending: [SIMD4<Float>] = []
    private var pendingGeneration: UInt64 = 0
    private var consumedGeneration: UInt64 = 0
    private var running = false

    public init()
    {}

    /// Starts the background thread if it isn't already running.
    public func start()
    {
      guard !running else { return }
      running = true

      let thread = Thread { [weak self] in self?.runLoop() }
      thread.name = "akari.fireflies.sim"
      thread.start()
    }

    /// Signals the background thread to stop.
    public func stop()
    {
      running = false
    }

    public func refreshIfNeeded() -> Bool
    {
      lock.lock()
      guard pendingGeneration != consumedGeneration else { lock.unlock(); return false }
      let newData = pending
      consumedGeneration = pendingGeneration
      lock.unlock()

      current = newData
      return true
    }

    private func runLoop()
    {
      var t: Float = 0
      while running
      {
        let step = Self.computeStep(t: t)
        lock.lock()
        pending = step
        pendingGeneration += 1
        lock.unlock()

        t += 1.0 / 30.0
        Thread.sleep(forTimeInterval: Double(max(stepDelayMS, 33)) / 1000)
      }
    }

    /// Each firefly orbits a phase offset point in NDC-ish [-1, 1] space.
    private static func computeStep(t: Float) -> [SIMD4<Float>]
    {
      (0 ..< count).map
      { i in
        let phase = Float(i) * 0.31
        let x = sin(t * 0.7 + phase) * 0.8
        let y = cos(t * 0.5 + phase * 1.3) * 0.6
        return SIMD4(x, y, 0, 1)
      }
    }
  }
}
