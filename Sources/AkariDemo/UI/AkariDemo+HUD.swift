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
import Foundation
import SwiftCrossUI

extension AkariDemo
{
  /// The interactive settings panel overlaid on the viewport.
  @MainActor
  struct HUD: View
  {
    @State private var state: AkariDemo.HUDState

    public init(engine: Akari.RenderEngine)
    {
      _state = State(wrappedValue: AkariDemo.HUDState(engine: engine))
    }

    public var body: some View
    {
      VStack(alignment: .leading, spacing: 3)
      {
        Text("AKARI 灯り")
          .font(.system(size: 12, weight: .semibold))
          .foregroundColor(Color(white: 0.62))
        Text("\(state.activePassCount)")
          .font(.system(size: 30, weight: .bold).monospaced())
        Text("frame graph passes active")
          .font(.system(size: 12))
          .foregroundColor(Color(white: 0.62))

        sectionHeader("COLOR PIPELINE")
        viewTransformRow
        qualityRow
        exposureRow
        gammaRow

        sectionHeader("SAMPLING")
        samplesRow
        renderSamplesRow

        sectionHeader("FEATURES")
        featuresSection

        Text("edits rebuild the frame graph live")
          .font(.system(size: 10))
          .foregroundColor(Color(white: 0.5))
      }
      .padding(14)
      .background(Color(white: 0.14, opacity: 0.66))
      .cornerRadius(10)
      .foregroundColor(Color(white: 0.96))
      .padding(16)
    }

    private var viewTransformRow: some View
    {
      HStack(spacing: 6)
      {
        key("View transform")
        Picker(of: ViewTransform.allCases,
               selection: state.$viewTransform.onChange { _ in state.apply() })
      }
    }

    private var qualityRow: some View
    {
      HStack(spacing: 6)
      {
        key("Quality")
        Picker(of: RenderQuality.allCases,
               selection: state.$quality.onChange
               { q in
                 if let q { state.applyPreset(q) }
                 state.apply()
               })
      }
    }

    private var exposureRow: some View
    {
      VStack(alignment: .leading, spacing: 2)
      {
        HStack(spacing: 6)
        {
          key("Exposure")
          value(String(format: "%+.1f EV", state.exposure))
        }
        Slider(value: state.$exposure.onChange { _ in state.apply() }, in: -4 ... 4)
          .frame(width: 160)
      }
    }

    private var gammaRow: some View
    {
      VStack(alignment: .leading, spacing: 2)
      {
        HStack(spacing: 6)
        {
          key("Gamma")
          value(String(format: "%.2f", state.gamma))
        }
        Slider(value: state.$gamma.onChange { _ in state.apply() }, in: 0.4 ... 2.5)
          .frame(width: 160)
      }
    }

    private var samplesRow: some View
    {
      VStack(alignment: .leading, spacing: 2)
      {
        HStack(spacing: 6)
        {
          key("Samples")
          value(String(format: "%d", Int(state.samples)))
        }
        Slider(value: state.$samples.onChange { _ in state.apply() },
               in: 1 ... 64)
          .frame(width: 160)
      }
    }

    private var renderSamplesRow: some View
    {
      VStack(alignment: .leading, spacing: 2)
      {
        HStack(spacing: 6)
        {
          key("Render Samples")
          value(String(format: "%d", Int(state.renderSamples)))
        }
        Slider(value: state.$renderSamples.onChange { _ in state.apply() },
               in: 1 ... 128)
          .frame(width: 160)
      }
    }

    private var featuresSection: some View
    {
      HStack(alignment: .top, spacing: 16)
      {
        VStack(alignment: .leading, spacing: 3)
        {
          featureToggle(.imageBasedLighting, "IBL")
          featureToggle(.lightProbes, "Light probes")
          featureToggle(.shadowMaps, "Shadow maps")
          featureToggle(.contactShadows, "Contact shadows")
          featureToggle(.ambientOcclusion, "Ambient occlusion")
          featureToggle(.screenSpaceReflections, "Screen space reflections")
        }
        VStack(alignment: .leading, spacing: 3)
        {
          featureToggle(.screenSpaceGI, "Screen space GI")
          featureToggle(.temporalAA, "TAA")
          featureToggle(.bloom, "Bloom")
          featureToggle(.depthOfField, "Depth of field")
          featureToggle(.volumetrics, "Volumetrics")
          featureToggle(.hardwareRayTracing, "Hardware RT")
        }
      }
    }

    private func sectionHeader(_ title: String) -> some View
    {
      Text(title)
        .font(.system(size: 10, weight: .bold))
        .foregroundColor(Color(white: 0.55))
        .padding(.top, 8)
    }

    private func key(_ title: String) -> some View
    {
      Text(title)
        .font(.system(size: 11))
        .foregroundColor(Color(white: 0.58))
    }

    private func value(_ text: String) -> some View
    {
      Text(text)
        .font(.system(size: 11, weight: .medium).monospaced())
    }

    private func featureToggle(_ feature: RenderFeatures, _ label: String) -> some View
    {
      Toggle(label, isOn: state.binding(for: feature))
    }
  }
}
