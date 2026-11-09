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

extension Kraken
{
  /// The render settings, docked beside the viewport.
  @MainActor
  struct HUD: View
  {
    @State private var state: Kraken.HUDState
    @State private var job: Kraken.RenderJob
    @State private var tab = Tab.render
    @State private var inspector: Kraken.Inspector

    /// Properties tabs, top to bottom.
    enum Tab: CaseIterable, Hashable
    {
      case render, output, scene, world, object, data, material

      var title: String
      {
        switch self
        {
          case .render: "Render"
          case .output: "Output"
          case .scene: "Scene"
          case .world: "World"
          case .object: "Object"
          case .data: "Object Data"
          case .material: "Material"
        }
      }
    }

    /// `width` is the space the sidebar gives the panel. Controls stretch to fill it.
    init(state: Kraken.HUDState, job: Kraken.RenderJob, inspector: Kraken.Inspector, width: Int = Properties.width)
    {
      Properties.panelWidth = max(width, Properties.width)
      _state = State(wrappedValue: state)
      _job = State(wrappedValue: job)
      _inspector = State(wrappedValue: inspector)
    }

    /// A prim's tabs only show while one is active,
    /// its data tab for a camera or light, its material
    /// tab for geometry.
    private var tabs: [Tab]
    {
      Tab.allCases.filter
      { t in
        switch t
        {
          case .object: inspector.path != nil
          case .data: inspector.path != nil && (inspector.isCamera || inspector.isLight)
          case .material: inspector.path != nil && inspector.geometry
          default: true
        }
      }
    }

    private var shown: Tab
    {
      tabs.contains(tab) ? tab : [.data, .material].contains(tab) && tabs.contains(.object) ? .object : .render
    }

    var body: some View
    {
      HStack(spacing: 0)
      {
        VStack(spacing: 2)
        {
          ForEach(tabs, id: \.self)
          { t in
            tabIcon(t, selected: shown == t)
              .frame(width: 24, height: 24)
              .background(RoundedRectangle(cornerRadius: 4).fill(shown == t ? Properties.tabActive : Properties.tabButton))
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
            tabIcon(shown, selected: true)
            Text(shown == .data && inspector.isCamera ? "Camera" : shown == .data ? "Light" : shown.title)
              .font(.system(size: 11))
              .foregroundColor(Properties.text)
            Spacer()
            Text("AKARI 灯り")
              .font(.system(size: 10, weight: .semibold))
              .foregroundColor(Properties.label)
          }
          .padding(.horizontal, 12)
          .padding(.vertical, 7)

          if shown == .output
          {
            OutputProperties(job: job)
          }
          else if shown == .scene
          {
            SceneProperties(job: job)
          }
          else if shown == .world
          {
            ScrollView
            {
              VStack(alignment: .leading, spacing: 4)
              {
                PropertiesPanel("Surface")
                {
                  slider("Sun Height", state.binding(\.light.sunHeight, marking: \.light.overridesStageSun), in: -1 ... 1, step: 0.01)
                  {
                    String(format: "%.2f", $0)
                  }

                  slider("Sun Angle", state.binding(\.light.sunAngle, scale: 180 / .pi, marking: \.light.overridesStageSun), in: 0 ... 20, step: 0.1)
                  {
                    String(format: "%.1f°", $0)
                  }

                  Properties.check("Image Based Lighting", state.binding(for: .imageBasedLighting))
                  Properties.check("Light Probes", state.binding(for: .lightProbes))
                }

                PropertiesPanel("Volume", toggle: state.binding(for: .volumetrics))
                {
                  slider("Density", state.binding(\.volume.density), in: 0 ... 0.2, step: 0.001)
                  {
                    String(format: "%.3f", $0)
                  }

                  slider("Anisotropy", state.binding(\.volume.anisotropy), in: -0.9 ... 0.9, step: 0.01)
                  {
                    String(format: "%+.2f", $0)
                  }

                  slider("Max Distance", state.binding(\.volume.maxDistance), in: 5 ... 500, step: 1)
                  {
                    String(format: "%.0f m", $0)
                  }

                  Properties.check("Shadows", state.volumeShadowsBinding)
                }

                PlanetProperties(state: state.planet, renderSettings: state)
              }
              .padding(6)
            }
          }
          else if shown == .object
          {
            ObjectProperties(inspector: inspector)
          }
          else if shown == .data
          {
            DataProperties(inspector: inspector)
          }
          else if shown == .material
          {
            MaterialProperties(inspector: inspector)
          }
          else
          {
            ScrollView
            {
              VStack(alignment: .leading, spacing: 4)
              {
                Properties.row("Quality")
                {
                  Dropdown(options: RenderQuality.allCases, selection: state.qualitySelection)
                }
                .padding(.vertical, 4)

                PropertiesPanel("Sampling")
                {
                  PropertiesPanel("Viewport", nested: true)
                  {
                    slider("Samples", state.binding(\.samples), in: 1 ... 64, step: 1) { "\(Int($0))" }
                    Properties.check("Temporal Reprojection", state.binding(for: .temporalAA))
                  }

                  PropertiesPanel("Render", nested: true)
                  {
                    slider("Samples", state.binding(\.renderSamples), in: 1 ... 128, step: 1) { "\(Int($0))" }
                  }
                }

                PropertiesPanel("Performance")
                {
                  Properties.row("Upscaler")
                  {
                    Dropdown(options: Upscaler.allCases, selection: state.selection(\.upscaler))
                  }

                  slider("Supersampling", state.binding(\.supersampling), in: 1 ... 2, step: 0.01)
                  {
                    String(format: "%.2f×", RenderSettings.supersamplingStep(Float($0)))
                  }

                  Properties.check("Dynamic Resolution", state.binding(for: .dynamicResolution))
                }

                PropertiesPanel("Shadows", toggle: state.binding(for: .shadowMaps))
                {
                  slider("Clipmap LOD Bias", state.binding(\.light.shadow.levelLodBias), in: -4 ... 4, step: 1)
                  {
                    String(format: "%+.0f", $0)
                  }

                  slider("Max Distance", state.binding(\.light.shadow.maxDistance), in: 2 ... 200, step: 1)
                  {
                    String(format: "%.0f m", $0)
                  }
                }

                PropertiesPanel("Raytracing", expanded: false, toggle: state.binding(for: .hardwareRayTracing))
                {
                  Properties.check("Screen Space Reflections", state.binding(for: .screenSpaceReflections))
                  slider("Max Roughness", state.binding(\.reflection.maxRoughness), in: 0 ... 1, step: 0.01)
                  {
                    String(format: "%.2f", $0)
                  }

                  Properties.check("Screen Space GI", state.binding(for: .screenSpaceGI))
                }

                PropertiesPanel("Bloom", expanded: false, toggle: state.binding(for: .bloom))
                {
                  slider("Threshold", state.binding(\.bloom.threshold), in: 0 ... 10, step: 0.01) { String(format: "%.2f", $0) }
                  slider("Smoothness", state.binding(\.bloom.smoothness), in: 0 ... 1, step: 0.01) { String(format: "%.2f", $0) }
                  slider("Maximum", state.binding(\.bloom.maximum), in: 0 ... 100, step: 0.1)
                  {
                    $0 > 0 ? String(format: "%.1f", $0) : "None"
                  }

                  slider("Strength", state.binding(\.bloom.strength), in: 0 ... 4, step: 0.01) { String(format: "%.2f", $0) }
                  slider("Saturation", state.binding(\.bloom.saturation), in: 0 ... 2, step: 0.01) { String(format: "%.2f", $0) }
                  Properties.row("Tint")
                  {
                    ColorField(color: state.binding(\.bloom.tint))
                  }

                  slider("Streaks", state.binding(\.bloom.streaks), in: 0 ... 1, step: 0.01) { String(format: "%.2f", $0) }
                  slider("Ghosts", state.binding(\.bloom.ghosts), in: 0 ... 1, step: 0.01) { String(format: "%.2f", $0) }
                }

                PropertiesPanel("Depth of Field", expanded: false, toggle: state.binding(for: .depthOfField))
                {
                  Properties.row("Focus Object")
                  {
                    ObjectField(name: state.focusObjectName, picking: state.pickingFocus,
                                pick: { state.pickFocusObject() }, clear: { state.clearFocusObject() })
                  }

                  slider("Focus Distance", state.binding(\.depthOfField.focusDistance, marking: \.depthOfField.overridesCamera), in: 0.1 ... 200, step: 0.1)
                  {
                    String(format: "%.1f m", $0)
                  }

                  PropertiesPanel("Aperture", nested: true)
                  {
                    slider("F-Stop", state.binding(\.depthOfField.fStop, marking: \.depthOfField.overridesCamera), in: 0.5 ... 32, step: 0.1) { String(format: "%.1f", $0) }
                  }

                  slider("Max Size", state.binding(\.depthOfField.maxSize), in: 4 ... 48, step: 1) { String(format: "%.0f px", $0) }
                }

                PropertiesPanel("Color Management")
                {
                  Properties.row("View")
                  {
                    Dropdown(options: Akari.Color.ViewTransform.allCases,
                             selection: state.selection(\.color.viewTransform))
                  }

                  Properties.row("Look")
                  {
                    Dropdown(options: Akari.Color.Look.allCases,
                             selection: state.selection(\.color.look))
                  }

                  slider("Exposure", state.binding(\.color.exposure), in: -4 ... 4, step: 0.1)
                  {
                    String(format: "%+.1f EV", $0)
                  }

                  slider("Gamma", state.binding(\.color.gamma), in: 0.4 ... 2.5, step: 0.01)
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
        .frame(width: Double(Properties.panelWidth))
        .background(Properties.region)
      }
    }

    @ViewBuilder
    private func tabIcon(_ t: Tab, selected: Bool) -> some View
    {
      switch t
      {
        case .render: TabIcon(kind: .render, background: selected ? Properties.tabActiveWhite : Properties.tabButtonWhite)
        case .output: TabIcon(kind: .output, background: selected ? Properties.tabActiveWhite : Properties.tabButtonWhite)
        case .scene: TabIcon(kind: .scene, background: selected ? Properties.tabActiveWhite : Properties.tabButtonWhite)
        case .world: TabIcon(kind: .world, background: selected ? Properties.tabActiveWhite : Properties.tabButtonWhite)
        case .object: TabIcon(kind: .object, background: selected ? Properties.tabActiveWhite : Properties.tabButtonWhite)
        case .data: TabIcon(kind: inspector.isLight ? .light : .camera,
                            background: selected ? Properties.tabActiveWhite : Properties.tabButtonWhite)
        case .material: TabIcon(kind: .material, background: selected ? Properties.tabActiveWhite : Properties.tabButtonWhite)
      }
    }

    private func slider(_ label: String,
                        _ binding: Binding<Double>,
                        in range: ClosedRange<Double>,
                        step: Double,
                        _ format: @escaping (Double) -> String) -> some View
    {
      Properties.row(label)
      {
        SliderField(value: binding, range: range, step: step, format: format)
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
      .padding(.vertical, 16)
      .padding(.trailing, 16)
      .padding(.leading, 48)
    }
  }
}
