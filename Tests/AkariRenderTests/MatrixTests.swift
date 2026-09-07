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
@testable import AkariRender

@Suite("Matrix4")
struct MatrixTests
{
  @Test("identity round trips a point unchanged")
  func identityTransform()
  {
    let p = SIMD3<Float>(1, 2, 3)
    let out = Akari.Matrix4.identity.transform(p)
    #expect(abs(out.x - p.x) < 1e-5)
    #expect(abs(out.y - p.y) < 1e-5)
    #expect(abs(out.z - p.z) < 1e-5)
  }

  @Test("inverse undoes an arbitrary lookAt")
  func inverseRoundTrip()
  {
    let view = Akari.Matrix4.lookAt(eye: SIMD3(3, 4, 5), target: SIMD3(0, 0, 0), up: SIMD3(0, 1, 0))
    let roundTrip = view.inverse() * view
    for c in 0 ..< 4
    {
      for r in 0 ..< 4
      {
        let expected: Float = c == r ? 1 : 0
        #expect(abs(roundTrip[c, r] - expected) < 1e-4)
      }
    }
  }

  @Test("ortho maps the near-far box onto NDC [-1, 1]")
  func orthoProjectsBoxCorners()
  {
    let proj = Akari.Matrix4.ortho(left: -2, right: 2, bottom: -1, top: 1, near: 0.5, far: 10)
    let nearCorner = proj.transform(SIMD3(-2, -1, -0.5))
    #expect(abs(nearCorner.x - -1) < 1e-4)
    #expect(abs(nearCorner.y - -1) < 1e-4)
    #expect(abs(nearCorner.z - -1) < 1e-4)

    let farCorner = proj.transform(SIMD3(2, 1, -10))
    #expect(abs(farCorner.x - 1) < 1e-4)
    #expect(abs(farCorner.y - 1) < 1e-4)
    #expect(abs(farCorner.z - 1) < 1e-4)
  }

  @Test("atlasRect maps clip space onto its UV sub-rect")
  func atlasRectMapsCorners()
  {
    let rect = Akari.Matrix4.atlasRect(origin: SIMD2(0.25, 0.5), size: SIMD2(0.25, 0.25))
    let bottomLeft = rect.transform(SIMD3(-1, -1, 0))
    #expect(abs(bottomLeft.x - 0.25) < 1e-5)
    #expect(abs(bottomLeft.y - 0.5) < 1e-5)

    let topRight = rect.transform(SIMD3(1, 1, 0))
    #expect(abs(topRight.x - 0.5) < 1e-5)
    #expect(abs(topRight.y - 0.75) < 1e-5)
  }
}
