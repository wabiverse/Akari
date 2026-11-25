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

/// a coarse quality tier, presets pick feature sets and internal resolutions and features can still be toggled after
public enum RenderQuality: String, Sendable, CaseIterable
{
  /// mobile, ibl, shadows and taa
  case low
  /// balances quality with performance.
  case medium
  /// full screen space stack at native resolution.
  case high
  /// everything, including realtime ray tracing.
  case cinematic

  public init?(_ text: some StringProtocol)
  {
    self.init(rawValue: String(text))
  }
}

/// brings the scene from its render resolution up to the target's.
public enum Upscaler: String, Sendable, CaseIterable
{
  /// taa resolve, or a bilinear stretch with taa off.
  case taaResolve
  /// metalfx temporal upscaling with taa on, spatial with it off
  case metalFX
}

/// how the viewport draws the scene, four shading modes.
public enum ViewportShading: Int, Sendable, CaseIterable
{
  case wireframe
  case solid
  case materialPreview
  case rendered

  /// the features a mode keeps of the ones turned on.
  public var features: RenderFeatures
  {
    switch self
    {
      case .wireframe, .solid: [.temporalAA, .dynamicResolution]
      case .materialPreview: [.imageBasedLighting, .temporalAA, .dynamicResolution, .screenSpaceReflections]
      case .rendered: RenderFeatures(rawValue: ~0)
    }
  }
}

/// the complete description of how akari should render a frame.
public struct RenderSettings: Sendable
{
  /// quality tier the feature set was derived from.
  public var quality: RenderQuality = .medium
  /// the lighting, shading and post features turned on
  public var features: RenderFeatures = RenderSettings.features(for: .medium)
  /// scene exposure and the display view transform, agx by default
  public var color: Akari.Color.Pipeline = .init()
  /// scene light settings.
  public var light: LightSettings = .init()
  /// scene volume settings.
  public var volume: VolumeSettings = .init()
  /// screen space reflection settings.
  public var reflection: ReflectionSettings = .init()
  /// bloom settings.
  public var bloom: BloomSettings = .init()
  /// depth of field settings.
  public var depthOfField: DepthOfFieldSettings = .init()
  /// light probe settings.
  public var probes: LightProbeSettings = .init()
  /// frame rate the interactive pipeline budgets toward.
  public var targetFrameRate: Int = 60
  /// viewport samples, 16 by default
  public var samples: Int = 16
  /// final render samples, 64 by default
  public var renderSamples: Int = 64
  /// how far subdivision surfaces refine in the viewport.
  public var subdivision: Int = 0
  /// how far subdivision surfaces refine in final renders.
  public var renderSubdivision: Int = 0

  /// the hydra complexity that refines subdivision surfaces to a level from 0 to 8.
  public static func complexity(subdivision level: Int) -> Float
  {
    1 + Float(min(max(level, 0), 8)) / 10
  }
  /// maximum cloud ray-march steps in the interactive viewport.
  public var planetCloudMarchSteps: Int = 32
  /// maximum cloud ray-march steps in final renders.
  public var renderPlanetCloudMarchSteps: Int = 32
  /// the gpu backend, metal, opengl or vulkan
  public var backend: Akari.GPU.Backend = .preferredForCurrentPlatform
  /// upscales resolution with the selected technique.
  public var upscaler: Upscaler = .metalFX
  /// resolution multiplier and downsamples, 1 is off.
  public var supersampling: Float = 1
  /// the viewport's shading mode, a final render is always `.rendered`.
  public var shading: ViewportShading = .rendered
  /// draws the viewport's floor grid and axes.
  public var overlays = false

  /// the supersampling factors, per axis: 1.78x, 2.25x and 4x the pixels.
  public static let supersamplingSteps: [Float] = [1, 4 / 3, 1.5, 2]

  /// `factor` snapped to the nearest of `supersamplingSteps`.
  public static func supersamplingStep(_ factor: Float) -> Float
  {
    supersamplingSteps.min { abs($0 - factor) < abs($1 - factor) } ?? 1
  }

  public init()
  {}

  public init(quality: RenderQuality = .medium,
              features: RenderFeatures? = nil,
              color: Akari.Color.Pipeline = Akari.Color.Pipeline(),
              light: LightSettings = LightSettings(),
              volume: VolumeSettings = VolumeSettings(),
              reflection: ReflectionSettings = ReflectionSettings(),
              probes: LightProbeSettings = LightProbeSettings(),
              targetFrameRate: Int = 60,
              samples: Int = 16,
              renderSamples: Int = 64,
              backend: Akari.GPU.Backend = .preferredForCurrentPlatform,
              planetCloudMarchSteps: Int = 32,
              renderPlanetCloudMarchSteps: Int = 32)
  {
    self.quality = quality
    self.features = features ?? Self.features(for: quality)
    self.color = color
    self.light = light
    self.volume = volume
    self.reflection = reflection
    self.probes = probes
    self.targetFrameRate = targetFrameRate
    self.samples = samples
    self.renderSamples = renderSamples
    self.planetCloudMarchSteps = planetCloudMarchSteps
    self.renderPlanetCloudMarchSteps = renderPlanetCloudMarchSteps
    self.backend = backend
  }

  /// default feature set for a quality tier.
  public static func features(for quality: RenderQuality) -> RenderFeatures
  {
    switch quality
    {
      case .low:
        [.imageBasedLighting, .shadowMaps, .temporalAA, .dynamicResolution]
      case .medium:
        .game60fps
      case .high:
        .fullFidelity
      case .cinematic:
        RenderFeatures.fullFidelity.union([.volumetrics, .hardwareRayTracing])
    }
  }
}

extension RenderQuality: CustomStringConvertible
{
  /// the label pickers and the hud show
  public var description: String
  {
    switch self
    {
      case .low: "Low"
      case .medium: "Medium"
      case .high: "High"
      case .cinematic: "Cinematic"
    }
  }
}

extension Upscaler: CustomStringConvertible
{
  /// the label pickers and the hud show
  public var description: String
  {
    switch self
    {
      case .taaResolve: "TAA Resolve"
      case .metalFX: "MetalFX"
    }
  }
}
