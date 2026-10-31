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

public extension Akari
{
  enum Lux
  {
    /// One Akari point light from the scene.
    public struct PointLight: Sendable
    {
      /// World-space position.
      public var position: SIMD3<Float>
      /// Illuminated linear color.
      public var color: SIMD3<Float>
      /// Radiant intensity.
      public var intensity: Float
      /// Sphere radius in world units.
      public var radius: Float
      /// Scales its diffuse and specular lobes, UsdLux's `diffuse` and `specular`.
      public var diffuse: Float
      public var specular: Float
      /// A tube light's half length along its axis in world units, and its radius, zero for a sphere.
      public var halfAxis: SIMD3<Float>
      public var tubeRadius: Float
      /// A rect light's half extents in world units, emitting away from their cross product, zero for the rest.
      public var halfWidth: SIMD3<Float> = .zero
      public var halfHeight: SIMD3<Float> = .zero
      /// How far it moved since the last frame, its shadow maps may still be from there.
      public var moved: Float = 0
      /// False when its glow shouldn't show to the camera, it still lights.
      public var cameraVisible = true
      /// False leaves it out of the light probes bounce.
      public var probes = true
      /// The irradiance under which its shadow no longer shows.
      public var shadowFloor: Float = 1e-3

      public init(position: SIMD3<Float>, color: SIMD3<Float>, intensity: Float, radius: Float,
                  diffuse: Float = 1, specular: Float = 1, halfAxis: SIMD3<Float> = .zero, tubeRadius: Float = 0)
      {
        self.position = position
        self.color = color
        self.intensity = intensity
        self.radius = radius
        self.diffuse = diffuse
        self.specular = specular
        self.halfAxis = halfAxis
        self.tubeRadius = tubeRadius
      }

      /// Where the light's irradiance, intensity * (radius / distance)^2,
      /// falls under `shadowFloor`, the farthest its shadow can show.
      public var reach: Float
      {
        radius * (max(intensity, 0) * max(max(color.x, color.y), color.z) / max(shadowFloor, 1e-6)).squareRoot()
      }
    }
  }
}
