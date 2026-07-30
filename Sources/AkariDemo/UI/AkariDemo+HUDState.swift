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
import SwiftCrossUI

extension AkariDemo
{
  /// The live render settings the HUD edits.
  @MainActor
  final class HUDState: ObservableObject
  {
    @Published var viewTransform: ViewTransform?
    @Published var quality: RenderQuality?
    @Published var exposure: Double
    @Published var gamma: Double
    @Published var samples: Double
    @Published var renderSamples: Double
    @Published var features: RenderFeatures

    private let engine: Akari.RenderEngine

    init(engine: Akari.RenderEngine)
    {
      self.engine = engine
      let s = engine.settings
      viewTransform = s.color.viewTransform
      quality = s.quality
      exposure = Double(s.color.exposure)
      gamma = Double(s.color.gamma)
      samples = Double(s.samples)
      renderSamples = Double(s.renderSamples)
      features = s.features
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
      settings.color.viewTransform = viewTransform ?? .agx
      settings.color.exposure = Float(exposure)
      settings.color.gamma = Float(gamma)
      settings.samples = Int(samples)
      settings.renderSamples = Int(renderSamples)
      engine.settings = settings
    }

    /// Snap the feature toggles to a quality tier's default feature set.
    func applyPreset(_ q: RenderQuality)
    {
      quality = q
      features = RenderSettings.features(for: q)
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
