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

/// The lighting / shading / post features Akari can enable per frame.
public struct RenderFeatures: OptionSet, Sendable
{
  public let rawValue: Int
  public init(rawValue: Int)
  {
    self.rawValue = rawValue
  }

  /// Image based lighting from an environment map
  /// (prefiltered specular + irradiance + BRDF LUT).
  public static let imageBasedLighting = RenderFeatures(rawValue: 1 << 0)
  /// Baked/streamed light probes + irradiance volumes for indirect diffuse.
  public static let lightProbes = RenderFeatures(rawValue: 1 << 1)
  /// Shadow maps for punctual / area lights (cascades for sun).
  public static let shadowMaps = RenderFeatures(rawValue: 1 << 2)
  /// Screen space contact shadows that fill the gap shadow maps miss.
  public static let contactShadows = RenderFeatures(rawValue: 1 << 3)
  /// Ground truth ambient occlusion (GTAO).
  public static let ambientOcclusion = RenderFeatures(rawValue: 1 << 4)
  /// Screen space reflections.
  public static let screenSpaceReflections = RenderFeatures(rawValue: 1 << 5)
  /// Screen space global illumination (horizon scan GI).
  public static let screenSpaceGI = RenderFeatures(rawValue: 1 << 6)
  /// Temporal anti aliasing / reprojection (also stabilizes the SS fx).
  public static let temporalAA = RenderFeatures(rawValue: 1 << 7)
  /// Bloom.
  public static let bloom = RenderFeatures(rawValue: 1 << 8)
  /// Depth of field.
  public static let depthOfField = RenderFeatures(rawValue: 1 << 9)
  /// Participating media volumetrics (froxel based).
  public static let volumetrics = RenderFeatures(rawValue: 1 << 10)
  /// Hardware ray tracing (aka "realtime ray tracing") for reflections,
  /// shadows, and one bounce GI where screen space fails.
  public static let hardwareRayTracing = RenderFeatures(rawValue: 1 << 11)

  /// The complete realtime fidelity stack (screen space, no hardware RT).
  public static let fullFidelity: RenderFeatures = [
    .imageBasedLighting, .lightProbes, .shadowMaps, .contactShadows,
    .ambientOcclusion, .screenSpaceReflections, .screenSpaceGI,
    .temporalAA, .bloom, .depthOfField
  ]

  /// A leaner set tuned to high fps in an interactive viewport.
  public static let game60fps: RenderFeatures = [
    .imageBasedLighting, .shadowMaps,
    .ambientOcclusion, .screenSpaceReflections,
    .temporalAA, .bloom
  ]
}
