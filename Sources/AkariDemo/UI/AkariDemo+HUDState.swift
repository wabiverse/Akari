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
  /// The live render settings the HUD edits, each edit written straight through to the engine.
  @MainActor
  final class HUDState: ObservableObject
  {
    /// The engine's settings as the HUD's last edit left them.
    @Published private(set) var current: RenderSettings
    /// The eyedropper is waiting for a click in the viewport.
    @Published var pickingFocus = false

    private let engine: Akari.RenderEngine
    private let hydra: Hydra.RenderEngine
    let planet: PlanetPropertiesState

    init(engine: Akari.RenderEngine, hydra: Hydra.RenderEngine)
    {
      self.engine = engine
      self.hydra = hydra
      planet = PlanetPropertiesState(hydra: hydra)
      current = engine.settings
      engine.labfx.onAuthoredSun = { [weak self] height, angle in
        DispatchQueue.main.async
        {
          self?.edit
          {
            $0.light.sunHeight = height
            $0.light.sunAngle = angle
            $0.light.overridesStageSun = false
          }
        }
      }
    }

    /// Changes the engine's settings as they are now, so edits made elsewhere stay.
    func edit(_ change: (inout RenderSettings) -> Void)
    {
      var settings = engine.settings
      change(&settings)
      engine.settings = settings
      current = settings
    }

    /// A control's binding to one setting, `scale` from the setting's units to the control's,
    /// `marking` a flag the edit sets, such as one replacing the stage's own sun from then on.
    func binding(_ keyPath: WritableKeyPath<RenderSettings, Float>, scale: Double = 1,
                 marking flag: WritableKeyPath<RenderSettings, Bool>? = nil) -> Binding<Double>
    {
      Binding(
        get: { Double(self.current[keyPath: keyPath]) * scale },
        set: { value in
          self.edit
          {
            $0[keyPath: keyPath] = Float(value / scale)
            if let flag { $0[keyPath: flag] = true }
          }
        }
      )
    }

    func binding(_ keyPath: WritableKeyPath<RenderSettings, Int>) -> Binding<Double>
    {
      Binding(
        get: { Double(self.current[keyPath: keyPath]) },
        set: { value in self.edit { $0[keyPath: keyPath] = Int(value) } }
      )
    }

    func binding<Value>(_ keyPath: WritableKeyPath<RenderSettings, Value>) -> Binding<Value>
    {
      Binding(
        get: { self.current[keyPath: keyPath] },
        set: { value in self.edit { $0[keyPath: keyPath] = value } }
      )
    }

    /// A dropdown's binding, clearing it leaves the setting as it is.
    func selection<Value>(_ keyPath: WritableKeyPath<RenderSettings, Value>) -> Binding<Value?>
    {
      Binding(
        get: { self.current[keyPath: keyPath] },
        set: { value in
          guard let value else { return }
          self.edit { $0[keyPath: keyPath] = value }
        }
      )
    }

    /// A binding the HUD toggles write through for one feature.
    func binding(for feature: RenderFeatures) -> Binding<Bool>
    {
      Binding(
        get: { self.current.features.contains(feature) },
        set: { on in
          self.edit
          {
            if on { $0.features.insert(feature) }
            else { $0.features.remove(feature) }
          }
        }
      )
    }

    /// Volume shadows only tune the fog.
    var volumeShadowsBinding: Binding<Bool>
    {
      Binding(
        get: { self.current.volume.shadows },
        set: { on in
          self.edit
          {
            $0.volume.shadows = on
            if on { $0.features.insert(.volumetrics) }
          }
        }
      )
    }

    /// Snap the feature toggles to a quality tier's default feature set.
    func applyPreset(_ quality: RenderQuality)
    {
      edit
      {
        $0.quality = quality
        $0.features = RenderSettings.features(for: quality)
      }
    }

    /// The quality dropdown, picking a tier snaps the features to its defaults.
    var qualitySelection: Binding<RenderQuality?>
    {
      Binding(
        get: { self.current.quality },
        set: { quality in
          guard let quality else { return }
          self.applyPreset(quality)
        }
      )
    }

    /// The focus object's name, as the field shows it.
    var focusObjectName: String
    {
      current.depthOfField.focusObject.split(separator: "/").last.map(String.init) ?? ""
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
      edit
      {
        $0.depthOfField.focusObject = path
        $0.depthOfField.focusPoint = point
        $0.depthOfField.overridesCamera = true
      }
    }

    func clearFocusObject()
    {
      edit
      {
        $0.depthOfField.focusObject = ""
        $0.depthOfField.overridesCamera = true
      }
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
  }
}
