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
  /// The render settings, docked beside the viewport.
  @MainActor
  struct HUD: View
  {
    @State private var state: AkariDemo.HUDState

    init(state: AkariDemo.HUDState)
    {
      _state = State(wrappedValue: state)
    }

    var body: some View
    {
      VStack(alignment: .leading, spacing: 0)
      {
        HStack(spacing: 6)
        {
          Text("Render")
            .font(.system(size: 11, weight: .medium))
            .foregroundColor(Properties.text)
            .frame(minWidth: 0.0, maxWidth: .infinity, alignment: .leading)
          Text("AKARI 灯り")
            .font(.system(size: 10, weight: .semibold))
            .foregroundColor(Properties.label)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)

        ScrollView
        {
          VStack(alignment: .leading, spacing: 4)
          {
            Properties.row("Quality")
            {
              Dropdown(options: RenderQuality.allCases,
                       selection: state.$quality.onChange
                       { q in
                         if let q { state.applyPreset(q) }
                         state.apply()
                       })
            }
            .padding(.vertical, 4)

            PropertiesPanel("Sampling")
            {
              PropertiesPanel("Viewport", nested: true)
              {
                slider("Samples", state.$samples, in: 1 ... 64, step: 1) { "\(Int($0))" }
                Properties.check("Temporal Reprojection", state.binding(for: .temporalAA))
              }
              PropertiesPanel("Render", nested: true)
              {
                slider("Samples", state.$renderSamples, in: 1 ... 128, step: 1) { "\(Int($0))" }
              }
            }

            PropertiesPanel("Performance")
            {
              Properties.row("Upscaler")
              {
                Dropdown(options: Upscaler.allCases, selection: state.$upscaler.onChange { _ in state.apply() })
              }
              slider("Supersampling", state.$supersampling, in: 1 ... 2, step: 0.01)
              {
                String(format: "%.2f×", RenderSettings.supersamplingStep(Float($0)))
              }
              Properties.check("Dynamic Resolution", state.binding(for: .dynamicResolution))
            }

            PropertiesPanel("Shadows", toggle: state.binding(for: .shadowMaps))
            {
              slider("Clipmap LOD Bias", state.$shadowLevelLodBias, in: -4 ... 4, step: 1)
              {
                String(format: "%+.0f", $0)
              }
              slider("Max Distance", state.$shadowMaxDistance, in: 2 ... 200, step: 1)
              {
                String(format: "%.0f m", $0)
              }
            }

            PropertiesPanel("Raytracing", expanded: false, toggle: state.binding(for: .hardwareRayTracing))
            {
              Properties.check("Screen Space Reflections", state.binding(for: .screenSpaceReflections))
              slider("Max Roughness", state.$reflectionMaxRoughness, in: 0 ... 1, step: 0.01)
              {
                String(format: "%.2f", $0)
              }
              Properties.check("Screen Space GI", state.binding(for: .screenSpaceGI))
            }

            PropertiesPanel("World")
            {
              slider("Sun Height", state.$environmentSunHeight, in: -1 ... 1, step: 0.01)
              {
                String(format: "%.2f", $0)
              }
              slider("Sun Angle", state.$environmentSunAngle, in: 0 ... 20, step: 0.1)
              {
                String(format: "%.1f°", $0)
              }
              Properties.check("Image Based Lighting", state.binding(for: .imageBasedLighting))
              Properties.check("Light Probes", state.binding(for: .lightProbes))
            }

            PropertiesPanel("Volumes", toggle: state.binding(for: .volumetrics))
            {
              slider("Density", state.$volumeDensity, in: 0 ... 0.2, step: 0.001)
              {
                String(format: "%.3f", $0)
              }
              slider("Anisotropy", state.$volumeAnisotropy, in: -0.9 ... 0.9, step: 0.01)
              {
                String(format: "%+.2f", $0)
              }
              slider("Max Distance", state.$volumeMaxDistance, in: 5 ... 500, step: 1)
              {
                String(format: "%.0f m", $0)
              }
              Properties.check("Shadows", state.volumeShadowsBinding)
            }

            PropertiesPanel("Bloom", expanded: false, toggle: state.binding(for: .bloom))
            {
              note("Glow around the brightest highlights.")
            }

            PropertiesPanel("Depth of Field", expanded: false, toggle: state.binding(for: .depthOfField))
            {
              note("Focus blur from the camera's lens.")
            }

            PropertiesPanel("Color Management")
            {
              Properties.row("View")
              {
                Dropdown(options: Akari.Color.ViewTransform.allCases,
                         selection: state.$viewTransform.onChange { _ in state.apply() })
              }
              slider("Exposure", state.$exposure, in: -4 ... 4, step: 0.1)
              {
                String(format: "%+.1f EV", $0)
              }
              slider("Gamma", state.$gamma, in: 0.4 ... 2.5, step: 0.01)
              {
                String(format: "%.2f", $0)
              }
            }

            Text("\(state.activePassCount) frame graph passes, edits rebuild live")
              .font(.system(size: 10))
              .foregroundColor(Color(white: 0.5))
              .padding(.top, 4)
              .padding(.leading, 6)
          }
          .padding(6)
        }
      }
      .frame(width: Double(Properties.width))
      .background(Properties.region)
    }

    /// A slider row that pushes the edit into the engine on change.
    private func slider(_ label: String,
                        _ binding: Binding<Double>,
                        in range: ClosedRange<Double>,
                        step: Double,
                        _ format: @escaping (Double) -> String) -> some View
    {
      Properties.row(label)
      {
        SliderField(value: binding.onChange { _ in state.apply() }, range: range, step: step, format: format)
      }
    }

    private func note(_ text: String) -> some View
    {
      HStack(spacing: 8)
      {
        Spacer().frame(width: Double(Properties.labelWidth))
        Text(text)
          .font(.system(size: 10))
          .foregroundColor(Color(white: 0.55))
      }
    }
  }

  /// The viewport's corner readout, as overlay text.
  @MainActor
  struct ViewportOverlay: View
  {
    let driver: any Akari.HydraFrameDriver

    var body: some View
    {
      VStack(alignment: .leading, spacing: 0)
      {
        FPSCounter(driver: driver)
      }
      .padding(16)
    }
  }
}
