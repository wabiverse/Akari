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

/// Scene light settings.
public struct LightSettings: Sendable
{
  /// Sun height, for day/night approximation.
  public var sunHeight: Float = 0
  /// Shadow atlas configuration.
  public var shadow = ShadowSettings()

  public init()
  {}

  public init(sunHeight: Float, shadow: ShadowSettings = ShadowSettings())
  {
    self.sunHeight = sunHeight
    self.shadow = shadow
  }

  /// World space direction toward the dominant celestial body, swinging
  /// from the sun to the moon across dusk. The deferred shader reads this
  /// as a uniform, and the shadow cascades are fitted to it, so both stay
  /// on the same light no matter how `sunHeight` is driven.
  public var sunDirection: SIMD3<Float>
  {
    let angle = min(max(abs(sunHeight) + 0.01, 0), 1) * 75 * .pi / 180
    let c = cos(angle)
    let sun = Self.normalize(SIMD3<Float>(0.4 * c, sin(angle), -0.5 * c))
    let moon = SIMD3<Float>(-sun.x, sun.y, -sun.z)

    let t = Self.smoothstep(-0.3, 0.05, sunHeight)
    return Self.normalize(moon + (sun - moon) * t)
  }
}

public extension LightSettings
{
  private static func normalize(_ v: SIMD3<Float>) -> SIMD3<Float>
  {
    let length = (v * v).sum().squareRoot()
    return length > 1e-6 ? v / length : SIMD3<Float>(0, 1, 0)
  }

  private static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float
  {
    let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
    return t * t * (3 - 2 * t)
  }
}
