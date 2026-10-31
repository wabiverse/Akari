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
import HydraKit
import SwiftCrossUI

extension AkariDemo
{
  /// The render settings, docked beside the viewport.
  @MainActor
  struct HUD: View
  {
    @State private var state: AkariDemo.HUDState
    @State private var job: AkariDemo.RenderJob
    @State private var tab = Tab.render

    /// Properties tabs, top to bottom.
    enum Tab: CaseIterable, Hashable
    {
      case render, output, scene, planet

      var title: String
      {
        switch self
        {
          case .render: "Render"
          case .output: "Output"
          case .scene: "Scene"
          case .planet: "Planet"
        }
      }
    }

    init(state: AkariDemo.HUDState, job: AkariDemo.RenderJob)
    {
      _state = State(wrappedValue: state)
      _job = State(wrappedValue: job)
    }

    var body: some View
    {
      HStack(spacing: 0)
      {
        VStack(spacing: 2)
        {
          ForEach(Tab.allCases, id: \.self)
          { t in
            tabIcon(t, selected: tab == t)
              .frame(width: 24, height: 24)
              .background(RoundedRectangle(cornerRadius: 4).fill(tab == t ? Properties.region : Color.clear))
              .onTapGesture { tab = t }
          }
          Spacer()
        }
        .padding(.vertical, 6)
        .frame(width: 30)
        .background(Properties.tabs)

        VStack(alignment: .leading, spacing: 0)
        {
          HStack(spacing: 6)
          {
            tabIcon(tab, selected: true)
            Text(tab.title)
              .font(.system(size: 11))
              .foregroundColor(Properties.text)
            Spacer()
            Text("AKARI 灯り")
              .font(.system(size: 10, weight: .semibold))
              .foregroundColor(Properties.label)
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 7)

          if tab == .output
          {
            OutputProperties(job: job)
          }
          else if tab == .scene
          {
            SceneProperties(job: job)
          }
          else if tab == .planet
          {
            PlanetProperties(state: state.planet, renderSettings: state)
          }
          else
          {
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
                  slider("Threshold", state.$bloomThreshold, in: 0 ... 10, step: 0.01) { String(format: "%.2f", $0) }
                  slider("Smoothness", state.$bloomSmoothness, in: 0 ... 1, step: 0.01) { String(format: "%.2f", $0) }
                  slider("Maximum", state.$bloomMaximum, in: 0 ... 100, step: 0.1)
                  {
                    $0 > 0 ? String(format: "%.1f", $0) : "None"
                  }
                  slider("Strength", state.$bloomStrength, in: 0 ... 4, step: 0.01) { String(format: "%.2f", $0) }
                  slider("Saturation", state.$bloomSaturation, in: 0 ... 2, step: 0.01) { String(format: "%.2f", $0) }
                  Properties.row("Tint")
                  {
                    ColorField(color: state.$bloomTint.onChange { _ in state.apply() })
                  }
                  slider("Streaks", state.$bloomStreaks, in: 0 ... 1, step: 0.01) { String(format: "%.2f", $0) }
                  slider("Ghosts", state.$bloomGhosts, in: 0 ... 1, step: 0.01) { String(format: "%.2f", $0) }
                }

                PropertiesPanel("Depth of Field", expanded: false, toggle: state.binding(for: .depthOfField))
                {
                  Properties.row("Focus Object")
                  {
                    ObjectField(name: state.focusObjectName, picking: state.pickingFocus,
                                pick: { state.pickFocusObject() }, clear: { state.clearFocusObject() })
                  }
                  lensSlider("Focus Distance", state.$focusDistance, in: 0.1 ... 200, step: 0.1)
                  {
                    String(format: "%.1f m", $0)
                  }
                  PropertiesPanel("Aperture", nested: true)
                  {
                    lensSlider("F-Stop", state.$fStop, in: 0.5 ... 32, step: 0.1) { String(format: "%.1f", $0) }
                  }
                  slider("Max Size", state.$dofMaxSize, in: 4 ... 48, step: 1) { String(format: "%.0f px", $0) }
                }

                PropertiesPanel("Color Management")
                {
                  Properties.row("View")
                  {
                    Dropdown(options: Akari.Color.ViewTransform.allCases,
                             selection: state.$viewTransform.onChange { _ in state.apply() })
                  }
                  Properties.row("Look")
                  {
                    Dropdown(options: Akari.Color.Look.allCases,
                             selection: state.$look.onChange { _ in state.apply() })
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
        }
        .frame(width: Double(Properties.width))
        .background(Properties.region)
      }
    }

    @ViewBuilder
    private func tabIcon(_ t: Tab, selected: Bool) -> some View
    {
      switch t
      {
        case .render: SymbolIcon("camera.fill", size: 12, white: 0.8)
        case .output: SymbolIcon("printer.fill", size: 12, white: 0.8)
        case .scene: SceneIcon(size: 15, background: selected ? 0.188 : 0.114)
        case .planet: SymbolIcon("globe.americas.fill", size: 12, white: 0.8)
      }
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

    /// A slider for the lens, an edit replacing the USD camera's own from then on.
    private func lensSlider(_ label: String,
                            _ binding: Binding<Double>,
                            in range: ClosedRange<Double>,
                            step: Double,
                            _ format: @escaping (Double) -> String) -> some View
    {
      Properties.row(label)
      {
        SliderField(value: binding.onChange { _ in state.applyLens() }, range: range, step: step, format: format)
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
