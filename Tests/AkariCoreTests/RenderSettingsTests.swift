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

@Suite("Akari core settings")
struct RenderSettingsTests
{
  @Test("medium quality resolves to the 60fps game feature set + AgX")
  func mediumDefaults()
  {
    let s = RenderSettings(quality: .medium)
    #expect(s.features == .game60fps)
    #expect(s.color.viewTransform == .agx)
    #expect(s.targetFrameRate == 60)
  }

  @Test("cinematic adds hardware ray tracing, volumetrics and SSGI")
  func cinematicFeatures()
  {
    let f = RenderSettings.features(for: .cinematic)
    #expect(f.contains(.hardwareRayTracing))
    #expect(f.contains(.volumetrics))
    #expect(f.contains(.screenSpaceGI))
  }

  @Test("explicit features override the quality preset")
  func explicitOverride()
  {
    let s = RenderSettings(quality: .high, features: [.imageBasedLighting])
    #expect(s.features == [.imageBasedLighting])
  }

  @Test("the platform picks a sane default backend")
  func backendDefault()
  {
    #if os(macOS) || os(visionOS) || os(iOS) || os(tvOS) || os(watchOS)
      #expect(GpuBackend.preferredForCurrentPlatform == .metal)
    #else
      #expect(GpuBackend.preferredForCurrentPlatform == .openGL)
    #endif
  }
}
