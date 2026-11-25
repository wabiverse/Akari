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

/// the lighting, shading and post features akari can turn on per frame
public struct RenderFeatures: OptionSet, Sendable
{
  public let rawValue: Int
  public init(rawValue: Int)
  {
    self.rawValue = rawValue
  }

  /// image based lighting from an environment map, prefiltered specular, irradiance and the brdf table
  public static let imageBasedLighting = RenderFeatures(rawValue: 1 << 0)
  /// baked or streamed light probes and irradiance volumes for indirect diffuse
  public static let lightProbes = RenderFeatures(rawValue: 1 << 1)
  /// shadow maps for punctual and area lights, cascades for the sun
  public static let shadowMaps = RenderFeatures(rawValue: 1 << 2)
  /// screen space reflections.
  public static let screenSpaceReflections = RenderFeatures(rawValue: 1 << 5)
  /// screen space global illumination, a horizon scan
  public static let screenSpaceGI = RenderFeatures(rawValue: 1 << 6)
  /// temporal anti aliasing and reprojection, it also steadies the screen space effects
  public static let temporalAA = RenderFeatures(rawValue: 1 << 7)
  /// bloom.
  public static let bloom = RenderFeatures(rawValue: 1 << 8)
  /// depth of field.
  public static let depthOfField = RenderFeatures(rawValue: 1 << 9)
  /// participating media through froxel volumetrics
  public static let volumetrics = RenderFeatures(rawValue: 1 << 10)
  /// hardware ray tracing for reflections, shadows and one bounce of gi where screen space falls short
  public static let hardwareRayTracing = RenderFeatures(rawValue: 1 << 11)
  /// moves the scene's render resolution with whatever the gpu hardware can support.
  public static let dynamicResolution = RenderFeatures(rawValue: 1 << 13)
  /// motion blur over the camera's shutter open and close
  public static let motionBlur = RenderFeatures(rawValue: 1 << 14)

  /// the whole realtime stack, screen space and no hardware ray tracing
  public static let fullFidelity: RenderFeatures = [
    .imageBasedLighting, .lightProbes, .shadowMaps,
    .screenSpaceReflections, .screenSpaceGI,
    .temporalAA, .bloom, .depthOfField,
    .dynamicResolution, .motionBlur
  ]

  /// a leaner set tuned to high fps in an interactive viewport.
  public static let game60fps: RenderFeatures = [
    .imageBasedLighting, .shadowMaps,
    .screenSpaceReflections,
    .temporalAA, .bloom,
    .dynamicResolution
  ]
}
