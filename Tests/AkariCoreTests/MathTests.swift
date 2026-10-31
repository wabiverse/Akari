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

import Testing
@testable import AkariCore

@Suite("Akari math")
struct MathTests
{
  @Test("clamp limits values to both ends of a range")
  func clamp()
  {
    #expect(Akari.Math.clamp(-1, 0, 1) == 0)
    #expect(Akari.Math.clamp(0.5, 0, 1) == 0.5)
    #expect(Akari.Math.clamp(2, 0, 1) == 1)
    #expect(Akari.Math.clamp(7, to: 1 ... 5) == 5)
  }

  @Test("smoothstep eases between its edges and saturates outside them")
  func smoothstep()
  {
    #expect(Akari.Math.smoothstep(0, 1, -1) == 0)
    #expect(Akari.Math.smoothstep(0, 1, 0.5) == 0.5)
    #expect(Akari.Math.smoothstep(0, 1, 2) == 1)
    #expect(Akari.Math.smoothstep(1, 1, 0.5) == 0)
    #expect(Akari.Math.smoothstep(1, 1, 1.5) == 1)
  }

  @Test("radians and degrees round trip")
  func angleConversion()
  {
    #expect(abs(Akari.Math.radians(180) - .pi) < 1e-6)
    #expect(abs(Akari.Math.degrees(.pi) - 180) < 1e-6)
  }

  @Test("the Halton sequence stays inside the unit interval and starts at zero")
  func halton()
  {
    #expect(Akari.Math.halton(0, base: 2) == 0)
    #expect(Akari.Math.halton(0, base: 3) == 0)
    #expect(Akari.Math.halton(1, base: 2) == 0.5)
    #expect(abs(Akari.Math.halton(1, base: 3) - 1.0 / 3.0) < 1e-6)
    for index in 1 ... 64
    {
      #expect((0 ..< 1).contains(Akari.Math.halton(UInt64(index), base: 2)))
      #expect((0 ..< 1).contains(Akari.Math.halton(UInt64(index), base: 3)))
    }
  }
}
