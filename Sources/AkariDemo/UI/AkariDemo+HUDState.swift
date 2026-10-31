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
import AkariRender
import HdAkari
import HydraKit
import protocol SwiftCrossUI.ObservableObject
import class SwiftCrossUI.Published
#if os(macOS)
  import AppKit
#endif

extension AkariDemo
{
  /// The live render settings the HUD edits.
  @MainActor
  final class HUDState: ObservableObject
  {
    @Published var viewTransform: Akari.Color.ViewTransform?
    @Published var look: Akari.Color.Look?
    @Published var quality: RenderQuality?
    @Published var upscaler: Upscaler?
    @Published var supersampling: Double
    @Published var exposure: Double
    @Published var gamma: Double
    @Published var samples: Double
    @Published var renderSamples: Double
    @Published var planetCloudMarchSteps: Double
    @Published var renderPlanetCloudMarchSteps: Double
    @Published var environmentSunHeight: Double
    @Published var environmentSunAngle: Double
    @Published var shadowMaxDistance: Double
    @Published var shadowLevelLodBias: Double
    @Published var volumeDensity: Double
    @Published var volumeAnisotropy: Double
    @Published var volumeMaxDistance: Double
    @Published var volumeShadows: Bool
    @Published var reflectionMaxRoughness: Double
    @Published var bloomThreshold: Double
    @Published var bloomSmoothness: Double
    @Published var bloomMaximum: Double
    @Published var bloomStrength: Double
    @Published var bloomSaturation: Double
    @Published var bloomTint: SIMD3<Float>
    @Published var bloomStreaks: Double
    @Published var bloomGhosts: Double
    @Published var focusObject: String
    @Published var focusDistance: Double
    @Published var fStop: Double
    @Published var dofMaxSize: Double
    /// The eyedropper is waiting for a click in the viewport.
    @Published var pickingFocus = false
    @Published var features: RenderFeatures

    private let engine: Akari.RenderEngine
    private let hydra: Hydra.RenderEngine
    private var focusPoint = SIMD3<Double>.zero
    private var lensEdited = false
    let planet: PlanetPropertiesState

    init(engine: Akari.RenderEngine, hydra: Hydra.RenderEngine)
    {
      self.engine = engine
      self.hydra = hydra
      planet = PlanetPropertiesState(hydra: hydra)
      let s = engine.settings
      viewTransform = s.color.viewTransform
      look = s.color.look
      quality = s.quality
      upscaler = s.upscaler
      supersampling = Double(s.supersampling)
      exposure = Double(s.color.exposure)
      gamma = Double(s.color.gamma)
      samples = Double(s.samples)
      renderSamples = Double(s.renderSamples)
      planetCloudMarchSteps = Double(s.planetCloudMarchSteps)
      renderPlanetCloudMarchSteps = Double(s.renderPlanetCloudMarchSteps)
      environmentSunHeight = Double(s.light.sunHeight)
      environmentSunAngle = Double(s.light.sunAngle) * 180 / .pi
      shadowMaxDistance = Double(s.light.shadow.maxDistance)
      shadowLevelLodBias = Double(s.light.shadow.levelLodBias)
      volumeDensity = Double(s.volume.density)
      volumeAnisotropy = Double(s.volume.anisotropy)
      volumeMaxDistance = Double(s.volume.maxDistance)
      volumeShadows = s.volume.shadows
      reflectionMaxRoughness = Double(s.reflection.maxRoughness)
      bloomThreshold = Double(s.bloom.threshold)
      bloomSmoothness = Double(s.bloom.smoothness)
      bloomMaximum = Double(s.bloom.maximum)
      bloomStrength = Double(s.bloom.strength)
      bloomSaturation = Double(s.bloom.saturation)
      bloomTint = s.bloom.tint
      bloomStreaks = Double(s.bloom.streaks)
      bloomGhosts = Double(s.bloom.ghosts)
      focusObject = s.depthOfField.focusObject
      focusPoint = s.depthOfField.focusPoint
      focusDistance = Double(s.depthOfField.focusDistance)
      fStop = Double(s.depthOfField.fStop)
      dofMaxSize = Double(s.depthOfField.maxSize)
      lensEdited = s.depthOfField.overridesCamera
      features = s.features
    }

    /// The focus object's name, as the field shows it.
    var focusObjectName: String
    {
      focusObject.split(separator: "/").last.map(String.init) ?? ""
    }

    /// Pushes a lens edit, which from then on replaces the USD camera's own.
    func applyLens()
    {
      lensEdited = true
      apply()
    }

    /// Arms the eyedropper, the next click in the viewport picks the focus object.
    func pickFocusObject()
    {
      guard !pickingFocus
      else
      {
        endPicking()
        return
      }
      pickingFocus = true
      #if os(macOS)
        NSCursor.crosshair.push()
      #endif
      hydra.onPick = { [weak self] result in
        MainActor.assumeIsolated
        {
          guard let self else { return }
          self.endPicking()
          if let result
          {
            // an instance holds still in its instancer, so the point follows the instancer.
            let path = String((result.isInstance ? result.instancerPath : result.primPath).GetAsString())
            // a prim Hydra made up has no place on the stage, its point stays where it was picked.
            var p = [result.worldPoint[0], result.worldPoint[1], result.worldPoint[2]]
            _ = Pixar.HdAkariPrimTransformPoint(self.hydra.stage, std.string(path), self.hydra.currentTimeCode, true, &p)
            self.setFocusObject(path, at: SIMD3(p[0], p[1], p[2]))
          }
          else
          {
            self.focusOnAovPick(tries: 20)
          }
        }
      }
    }

    /// Akari answers a click from its prim ID buffer a frame later, focusing on the prim's middle.
    private func focusOnAovPick(tries: Int)
    {
      guard let path = hydra.lastPickedPath.map({ String($0.GetAsString()) })
      else
      {
        guard tries > 0 else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.focusOnAovPick(tries: tries - 1) }
        return
      }
      var p = [0.0, 0.0, 0.0]
      _ = Pixar.HdAkariPrimLocalCenter(hydra.stage, std.string(path), hydra.currentTimeCode, &p)
      setFocusObject(path, at: SIMD3(p[0], p[1], p[2]))
    }

    private func setFocusObject(_ path: String, at point: SIMD3<Double>)
    {
      focusObject = path
      focusPoint = point
      applyLens()
    }

    func clearFocusObject()
    {
      focusObject = ""
      applyLens()
    }

    private func endPicking()
    {
      guard pickingFocus else { return }
      pickingFocus = false
      hydra.onPick = nil
      #if os(macOS)
        NSCursor.pop()
      #endif
    }

    /// How many frame graph passes the engine currently runs.
    var activePassCount: Int
    {
      engine.activePasses.count
    }

    /// Push the current HUD state into the engine.
    func apply()
    {
      var settings = engine.settings
      settings.quality = quality ?? .medium
      settings.features = features
      settings.upscaler = upscaler ?? .metalFX
      settings.supersampling = Float(supersampling)
      settings.color.viewTransform = viewTransform ?? .agx
      settings.color.look = look ?? .none
      settings.color.exposure = Float(exposure)
      settings.color.gamma = Float(gamma)
      settings.samples = Int(samples)
      settings.renderSamples = Int(renderSamples)
      settings.planetCloudMarchSteps = Int(planetCloudMarchSteps)
      settings.renderPlanetCloudMarchSteps = Int(renderPlanetCloudMarchSteps)
      settings.light.sunHeight = Float(environmentSunHeight)
      settings.light.sunAngle = Float(environmentSunAngle * .pi / 180)
      settings.light.shadow.maxDistance = Float(shadowMaxDistance)
      settings.light.shadow.levelLodBias = Float(shadowLevelLodBias)
      settings.volume.density = Float(volumeDensity)
      settings.volume.anisotropy = Float(volumeAnisotropy)
      settings.volume.maxDistance = Float(volumeMaxDistance)
      settings.volume.shadows = volumeShadows
      settings.reflection.maxRoughness = Float(reflectionMaxRoughness)
      settings.bloom.threshold = Float(bloomThreshold)
      settings.bloom.smoothness = Float(bloomSmoothness)
      settings.bloom.maximum = Float(bloomMaximum)
      settings.bloom.strength = Float(bloomStrength)
      settings.bloom.saturation = Float(bloomSaturation)
      settings.bloom.tint = bloomTint
      settings.bloom.streaks = Float(bloomStreaks)
      settings.bloom.ghosts = Float(bloomGhosts)
      settings.depthOfField.overridesCamera = lensEdited
      settings.depthOfField.focusObject = focusObject
      settings.depthOfField.focusPoint = focusPoint
      settings.depthOfField.focusDistance = Float(focusDistance)
      settings.depthOfField.fStop = Float(fStop)
      settings.depthOfField.maxSize = Float(dofMaxSize)
      engine.settings = settings
    }

    /// Snap the feature toggles to a quality tier's default feature set.
    func applyPreset(_ q: RenderQuality)
    {
      quality = q
      features = RenderSettings.features(for: q)
    }

    /// Volume shadows only tune the fog.
    var volumeShadowsBinding: Binding<Bool>
    {
      Binding(
        get: { self.volumeShadows },
        set: { on in
          self.volumeShadows = on
          if on { self.features.insert(.volumetrics) }
          self.apply()
        }
      )
    }

    /// A binding the HUD toggles write through for one feature.
    func binding(for feature: RenderFeatures) -> Binding<Bool>
    {
      Binding(
        get: { self.features.contains(feature) },
        set: { on in
          if on { self.features.insert(feature) }
          else { self.features.remove(feature) }
          self.apply()
        }
      )
    }
  }
}
