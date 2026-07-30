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

/// Coarse quality tier. Presets pick sensible feature sets
/// and internal resolutions, individual features can still
/// be toggled afterward.
public enum RenderQuality: String, Sendable, CaseIterable
{
  /// Mobile, IBL + shadows + AO, half res SS fx.
  case low
  /// Balances quality with performance.
  case medium
  /// Full screen space stack at native resolution.
  case high
  /// Everything, including realtime ray tracing.
  case cinematic
}

/// The complete description of how Akari should render a frame.
public struct RenderSettings: Sendable
{
  /// Quality tier the feature set was derived from.
  public var quality: RenderQuality = .medium
  /// The active lighting/shading/post features.
  public var features: RenderFeatures = RenderSettings.features(for: .medium)
  /// Scene exposure + display view transform (AgX by default).
  public var color: ColorPipeline = .init()
  /// Frame rate the interactive pipeline budgets toward.
  public var targetFrameRate: Int = 60
  /// Viewport sample count (defaults to 16).
  public var samples: Int = 16
  /// Final render sample count (defaults 64).
  public var renderSamples: Int = 64
  /// GPU backend (`Metal`, `OpenGL`, `Vulkan`).
  public var backend: GpuBackend = .preferredForCurrentPlatform

  public init()
  {}

  public init(quality: RenderQuality = .medium,
              features: RenderFeatures? = nil,
              color: ColorPipeline = ColorPipeline(),
              targetFrameRate: Int = 60,
              samples: Int = 16,
              renderSamples: Int = 64,
              backend: GpuBackend = .preferredForCurrentPlatform)
  {
    self.quality = quality
    self.features = features ?? Self.features(for: quality)
    self.color = color
    self.targetFrameRate = targetFrameRate
    self.samples = samples
    self.renderSamples = renderSamples
    self.backend = backend
  }

  /// Default feature set for a quality tier.
  public static func features(for quality: RenderQuality) -> RenderFeatures
  {
    switch quality
    {
      case .low:
        [.imageBasedLighting, .shadowMaps, .ambientOcclusion, .temporalAA]
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
  /// Human label for UI (pickers, HUD).
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
