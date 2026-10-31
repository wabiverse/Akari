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

extension AkariDemo
{
  /// Edits the procedural atmosphere and planet primvars on the Hydra frame queue.
  @MainActor
  final class PlanetPropertiesState: ObservableObject
  {
    @Published var floats: [String: Double] = [:]
    @Published var booleans: [String: Bool] = [:]
    @Published var colors: [String: SIMD3<Double>] = [:]
    @Published var assets: [String: String] = [:]

    let primPath: String?

    private let hydra: Hydra.RenderEngine

    private static let floatDefaults: [String: Double] = [
      "radius": 1,
      "primvars:akari:atmosphere:thickness": 100,
      "primvars:akari:atmosphere:rayleighScaleHeight": 8,
      "primvars:akari:atmosphere:mieScaleHeight": 1.2,
      "primvars:akari:atmosphere:mieAnisotropy": 0.8,
      "primvars:akari:atmosphere:ozoneCenter": 25,
      "primvars:akari:atmosphere:ozoneWidth": 30,
      "primvars:akari:atmosphere:nightIntensity": 1,
      "primvars:akari:atmosphere:aerialPerspectiveDistance": 128,
      "primvars:akari:atmosphere:skyIntensity": 1,
      "primvars:akari:planet:seed": 0,
      "primvars:akari:planet:seaLevel": 0.62,
      "primvars:akari:planet:continentScale": 2,
      "primvars:akari:planet:mountainHeight": 5,
      "primvars:akari:planet:vegetation": 0.7,
      "primvars:akari:planet:desert": 0.5,
      "primvars:akari:planet:iceCaps": 0.5,
      "primvars:akari:planet:oceanRoughness": 0.2,
      "primvars:akari:planet:cloudCoverage": 0.45,
      "primvars:akari:planet:cloudAltitude": 6,
      "primvars:akari:planet:cloudRotation": 0,
      "primvars:akari:planet:cloudEvolution": 0,
      "primvars:akari:planet:cloudOpacity": 0.95,
      "primvars:akari:planet:cloudScale": 1,
      "primvars:akari:planet:cloudThickness": 4,
      "primvars:akari:planet:cityIntensity": 0.02,
      "primvars:akari:planet:cityDensity": 0.5,
      "primvars:akari:planet:cloudSwirl": 0,
      "primvars:akari:planet:detail": 0,
      "primvars:akari:planet:cloudSoftness": 0,
      "primvars:akari:planet:cloudShading": 0,
      "primvars:akari:planet:waves": 0,
      "primvars:akari:planet:waveTime": 0,
      "primvars:akari:atmosphere:halo": 0,
      "primvars:akari:atmosphere:haloRadius": 0.25,
      "primvars:akari:atmosphere:haloStreaks": 0.15,
      "primvars:akari:atmosphere:haloShadow": 0.75,
      "primvars:akari:planet:fillIntensity": 0,
      "primvars:akari:planet:rimIntensity": 0,
      "primvars:akari:planet:bloomAmount": 0,
    ]

    private static let booleanDefaults: [String: Bool] = [
      "primvars:akari:atmosphere": true,
      "primvars:akari:planet": false,
    ]

    private static let colorDefaults: [String: SIMD3<Double>] = [
      "primvars:akari:atmosphere:rayleighScattering": SIMD3(0.005802, 0.013558, 0.0331),
      "primvars:akari:atmosphere:mieScattering": SIMD3(repeating: 0.003996),
      "primvars:akari:atmosphere:mieAbsorption": SIMD3(repeating: 0.0044),
      "primvars:akari:atmosphere:ozoneAbsorption": SIMD3(0.00065, 0.001881, 0.000085),
      "primvars:akari:atmosphere:groundAlbedo": SIMD3(repeating: 0.3),
      "primvars:akari:planet:oceanColor": SIMD3(0.004, 0.016, 0.035),
      "primvars:akari:planet:landColorLow": SIMD3(repeating: -1),
      "primvars:akari:planet:landColorHigh": SIMD3(repeating: -1),
      "primvars:akari:planet:forestColor": SIMD3(repeating: -1),
      "primvars:akari:planet:desertColor": SIMD3(repeating: -1),
      "primvars:akari:planet:shallowColor": SIMD3(repeating: -1),
      "primvars:akari:planet:rockColor": SIMD3(repeating: -1),
      "primvars:akari:planet:snowColor": SIMD3(repeating: -1),
      "primvars:akari:planet:bloomColor": SIMD3(repeating: -1),
      "primvars:akari:atmosphere:haloColor": SIMD3(0.45, 0.72, 1),
      "primvars:akari:planet:fillColor": SIMD3(0.55, 0.65, 1),
      "primvars:akari:planet:rimColor": SIMD3(0.6, 0.8, 1),
    ]

    private static let assetDefaults: [String: String] = [
      "primvars:akari:atmosphere:groundTexture": "",
      "primvars:akari:atmosphere:nightTexture": "",
    ]

    init(hydra: Hydra.RenderEngine)
    {
      self.hydra = hydra

      guard let prim = hydra.stage.traverse().first(where: {
        $0.attribute(named: "primvars:akari:atmosphere") != nil ||
          $0.attribute(named: "primvars:akari:planet") != nil
      })
      else { primPath = nil; return }

      primPath = prim.path.string

      for (name, fallback) in Self.floatDefaults
      {
        var value = Float(fallback)
        if name == "radius"
        {
          var radius = fallback
          if let attribute = prim.attribute(named: name) { attribute.Get(&radius, UsdTimeCode.Default()) }
          floats[name] = radius
        }
        else
        {
          if let attribute = prim.attribute(named: name)
          {
            if !attribute.Get(&value, UsdTimeCode.Default())
            {
              var doubleValue = fallback
              if attribute.Get(&doubleValue, UsdTimeCode.Default()) { value = Float(doubleValue) }
            }
          }
          floats[name] = Double(value)
        }
      }
      for (name, fallback) in Self.booleanDefaults
      {
        var value = fallback
        if let attribute = prim.attribute(named: name)
        {
          if !attribute.Get(&value, UsdTimeCode.Default())
          {
            var intValue: Int32 = 0
            if attribute.Get(&intValue, UsdTimeCode.Default()) { value = intValue != 0 }
            else
            {
              var floatValue: Float = 0
              if attribute.Get(&floatValue, UsdTimeCode.Default()) { value = floatValue != 0 }
            }
          }
        }
        booleans[name] = value
      }
      for (name, fallback) in Self.colorDefaults
      {
        var value = Pixar.GfVec3f(Float(fallback.x), Float(fallback.y), Float(fallback.z))
        if let attribute = prim.attribute(named: name)
        {
          if !attribute.Get(&value, UsdTimeCode.Default())
          {
            var doubleValue = Pixar.GfVec3d(fallback.x, fallback.y, fallback.z)
            if attribute.Get(&doubleValue, UsdTimeCode.Default())
            {
              value = Pixar.GfVec3f(Float(doubleValue[0]), Float(doubleValue[1]), Float(doubleValue[2]))
            }
          }
        }
        colors[name] = SIMD3(Double(value[0]), Double(value[1]), Double(value[2]))
      }
      for (name, fallback) in Self.assetDefaults
      {
        var value = Pixar.SdfAssetPath()
        var path = ""
        if let attribute = prim.attribute(named: name)
        {
          if attribute.Get(&value, UsdTimeCode.Default())
          {
            #if compiler(>=6.4)
              let resolved = String(value.GetResolvedPathConsuming())
              path = resolved.isEmpty ? String(value.GetAssetPathConsuming()) : resolved
            #else
              let resolved = String(value.GetResolvedPath())
              path = resolved.isEmpty ? String(value.GetAssetPath()) : resolved
            #endif
          }
          else
          {
            var stringValue = std.string()
            if attribute.Get(&stringValue, UsdTimeCode.Default()) { path = String(stringValue) }
          }
        }
        assets[name] = path.isEmpty ? fallback : path
      }
    }

    func floatBinding(_ name: String) -> Binding<Double>
    {
      Binding(get: { self.floats[name] ?? Self.floatDefaults[name] ?? 0 },
              set: { self.setFloat(name, $0) })
    }

    func boolBinding(_ name: String) -> Binding<Bool>
    {
      Binding(get: { self.booleans[name] ?? Self.booleanDefaults[name] ?? false },
              set: { self.setBool(name, $0) })
    }

    func colorBinding(_ name: String, in environment: EnvironmentValues) -> Binding<Color>
    {
      Binding(get:
        {
          let c = self.colors[name, default: Self.colorDefaults[name] ?? .zero]
          return Color(red: c.x, green: c.y, blue: c.z)
        },
        set:
        { value in
          let resolved = value.resolve(in: environment)
          let color = SIMD3<Double>(Double(resolved.red), Double(resolved.green), Double(resolved.blue))
          self.colors[name] = color
          self.writeColor(name, color)
        })
    }

    func assetBinding(_ name: String) -> Binding<String>
    {
      Binding(get: { self.assets[name] ?? "" },
              set:
              { value in
                self.assets[name] = value
                self.writeAsset(name, value)
              })
    }

    private func setFloat(_ name: String, _ value: Double)
    {
      floats[name] = value
      let path = primPath

      hydra.performOnFrameQueue
      { [self] in
        guard let path else { return }
        let prim = hydra.stage.getPrim(at: path)

        hydra.stage.SetEditTarget(Pixar.UsdEditTarget(hydra.stage.GetSessionLayer(), Pixar.SdfLayerOffset(offset: 0, scale: 1)))
        defer { hydra.stage.SetEditTarget(Pixar.UsdEditTarget(hydra.stage.getRootLayer(), Pixar.SdfLayerOffset(offset: 0, scale: 1))) }

        let type: Pixar.SdfValueTypeNameType = name == "radius" ? .double : .float
        guard let attribute = prim.attribute(named: name)
          ?? prim.createAttribute(name: name, typeName: type, custom: true)
        else { return }

        switch attribute.typeName
        {
          case .double:
            attribute.set(value)
          default:
            attribute.set(Float(value))
        }
      }
    }

    private func setBool(_ name: String, _ value: Bool)
    {
      booleans[name] = value
      let path = primPath
      hydra.performOnFrameQueue
      { [self] in
        guard let path else { return }
        let prim = hydra.stage.getPrim(at: path)

        hydra.stage.SetEditTarget(Pixar.UsdEditTarget(hydra.stage.GetSessionLayer(), Pixar.SdfLayerOffset(offset: 0, scale: 1)))
        defer { hydra.stage.SetEditTarget(Pixar.UsdEditTarget(hydra.stage.getRootLayer(), Pixar.SdfLayerOffset(offset: 0, scale: 1))) }

        guard let attribute = prim.attribute(named: name)
          ?? prim.createAttribute(name: name, typeName: .bool, custom: true)
        else { return }

        switch attribute.typeName
        {
          case .bool: attribute.set(value)
          case .int: attribute.set(Int32(value ? 1 : 0))
          case .float: attribute.set(Float(value ? 1 : 0))
          case .double: attribute.set(Double(value ? 1 : 0))
          default: attribute.set(value)
        }
      }
    }

    func writeColor(_ name: String, _ value: SIMD3<Double>)
    {
      let path = primPath
      hydra.performOnFrameQueue
      { [self] in
        guard let path else { return }
        let prim = hydra.stage.getPrim(at: path)

        hydra.stage.SetEditTarget(Pixar.UsdEditTarget(hydra.stage.GetSessionLayer(), Pixar.SdfLayerOffset(offset: 0, scale: 1)))
        defer { hydra.stage.SetEditTarget(Pixar.UsdEditTarget(hydra.stage.getRootLayer(), Pixar.SdfLayerOffset(offset: 0, scale: 1))) }

        guard let attribute = prim.attribute(named: name)
          ?? prim.createAttribute(name: name, typeName: .color3f, custom: true)
        else { return }

        switch attribute.typeName
        {
          case .color3f:
            attribute.set(Pixar.GfVec3f(Float(value.x), Float(value.y), Float(value.z)))
          case .color3d:
            attribute.set(Pixar.GfVec3d(value.x, value.y, value.z))
          case .vector3f:
            attribute.set(Pixar.GfVec3f(Float(value.x), Float(value.y), Float(value.z)))
          case .vector3d:
            attribute.set(Pixar.GfVec3d(value.x, value.y, value.z))
          default:
            break
        }
      }
    }

    private func writeAsset(_ name: String, _ value: String)
    {
      let path = primPath
      hydra.performOnFrameQueue
      { [self] in
        guard let path else { return }
        let prim = hydra.stage.getPrim(at: path)

        hydra.stage.SetEditTarget(Pixar.UsdEditTarget(hydra.stage.GetSessionLayer(), Pixar.SdfLayerOffset(offset: 0, scale: 1)))
        defer { hydra.stage.SetEditTarget(Pixar.UsdEditTarget(hydra.stage.getRootLayer(), Pixar.SdfLayerOffset(offset: 0, scale: 1))) }

        guard let attribute = prim.attribute(named: name)
          ?? prim.createAttribute(name: name, typeName: .asset, custom: true)
        else { return }

        switch attribute.typeName
        {
          case .string:
            attribute.set(value)
          default:
            attribute.set(Pixar.SdfAssetPath(value))
        }
      }
    }
  }

  /// The scene-authored atmosphere and procedural planet controls.
  @MainActor
  struct PlanetProperties: View
  {
    @Environment(\.self) private var environment

    @State private var state: PlanetPropertiesState
    @State private var renderSettings: HUDState

    init(state: PlanetPropertiesState, renderSettings: HUDState)
    {
      _state = State(wrappedValue: state)
      _renderSettings = State(wrappedValue: renderSettings)
    }

    var body: some View
    {
      ScrollView
      {
        VStack(alignment: .leading, spacing: 4)
        {
          if let path = state.primPath
          {
            Text(path)
              .font(.system(size: 10))
              .foregroundColor(Color(white: 0.58))
              .padding(.horizontal, 6)
              .padding(.vertical, 3)

            PropertiesPanel("Cloud March Quality")
            {
              floatRow("Viewport Steps", value: renderSettings.$planetCloudMarchSteps,
                       range: 8 ... 128, step: 1, format: { "\(Int($0))" }, changed: renderSettings.apply)
              floatRow("Final Render Steps", value: renderSettings.$renderPlanetCloudMarchSteps,
                       range: 8 ... 128, step: 1, format: { "\(Int($0))" }, changed: renderSettings.apply)
            }

            PropertiesPanel("Atmosphere", toggle: state.boolBinding("primvars:akari:atmosphere"))
            {
              floatRow("Thickness", key: "primvars:akari:atmosphere:thickness", range: 0.01 ... 1000,
                       step: 1, unit: "km")
              colorRow("Rayleigh", key: "primvars:akari:atmosphere:rayleighScattering")
              floatRow("Rayleigh Height", key: "primvars:akari:atmosphere:rayleighScaleHeight", range: 0.01 ... 100,
                       step: 0.1, unit: "km")
              colorRow("Mie Scattering", key: "primvars:akari:atmosphere:mieScattering")
              colorRow("Mie Absorption", key: "primvars:akari:atmosphere:mieAbsorption")
              floatRow("Mie Height", key: "primvars:akari:atmosphere:mieScaleHeight", range: 0.01 ... 100,
                       step: 0.1, unit: "km")
              floatRow("Mie Anisotropy", key: "primvars:akari:atmosphere:mieAnisotropy", range: -0.99 ... 0.99,
                       step: 0.01)
              colorRow("Ozone Absorption", key: "primvars:akari:atmosphere:ozoneAbsorption")
              floatRow("Ozone Center", key: "primvars:akari:atmosphere:ozoneCenter", range: 0 ... 100,
                       step: 0.1, unit: "km")
              floatRow("Ozone Width", key: "primvars:akari:atmosphere:ozoneWidth", range: 0.01 ... 100,
                       step: 0.1, unit: "km")
              colorRow("Ground Albedo", key: "primvars:akari:atmosphere:groundAlbedo")
              assetRow("Ground Texture", key: "primvars:akari:atmosphere:groundTexture")
              assetRow("Night Texture", key: "primvars:akari:atmosphere:nightTexture")
              floatRow("Night Intensity", key: "primvars:akari:atmosphere:nightIntensity", range: 0 ... 100,
                       step: 0.1)
              floatRow("Aerial Distance", key: "primvars:akari:atmosphere:aerialPerspectiveDistance",
                       range: 0.01 ... 10000, step: 1, unit: "km")
              floatRow("Sky Intensity", key: "primvars:akari:atmosphere:skyIntensity", range: 0 ... 100,
                       step: 0.1)
            }

            PropertiesPanel("Planet", toggle: state.boolBinding("primvars:akari:planet"))
            {
              floatRow("Radius", key: "radius", range: 0.001 ... 1e10, step: 100,
                       unit: "units", format: { String(format: "%.0f", $0) })
              floatRow("Seed", key: "primvars:akari:planet:seed", range: -100_000 ... 100_000,
                       step: 1, format: { String(format: "%.0f", $0) })
              floatRow("Sea Level", key: "primvars:akari:planet:seaLevel", range: 0 ... 1, step: 0.01)
              floatRow("Continent Scale", key: "primvars:akari:planet:continentScale", range: 0.01 ... 20, step: 0.01)
              floatRow("Mountain Height", key: "primvars:akari:planet:mountainHeight", range: 0 ... 100, step: 0.1, unit: "km")
              floatRow("Vegetation", key: "primvars:akari:planet:vegetation", range: 0 ... 1, step: 0.01)
              floatRow("Desert", key: "primvars:akari:planet:desert", range: 0 ... 1, step: 0.01)
              floatRow("Ice Caps", key: "primvars:akari:planet:iceCaps", range: 0 ... 1, step: 0.01)
              colorRow("Ocean Color", key: "primvars:akari:planet:oceanColor")
              floatRow("Ocean Roughness", key: "primvars:akari:planet:oceanRoughness", range: 0.02 ... 1, step: 0.01)
            }

            PropertiesPanel("Clouds")
            {
              floatRow("Coverage", key: "primvars:akari:planet:cloudCoverage", range: 0 ... 1, step: 0.01)
              floatRow("Altitude", key: "primvars:akari:planet:cloudAltitude", range: 0 ... 1000, step: 1, unit: "km")
              floatRow("Thickness", key: "primvars:akari:planet:cloudThickness", range: 0.01 ... 1000, step: 1, unit: "km")
              floatRow("Opacity", key: "primvars:akari:planet:cloudOpacity", range: 0 ... 1, step: 0.01)
              floatRow("Scale", key: "primvars:akari:planet:cloudScale", range: 0.01 ... 20, step: 0.01)
              floatRow("Rotation", key: "primvars:akari:planet:cloudRotation", range: -360 ... 360, step: 1, unit: "°")
              floatRow("Evolution", key: "primvars:akari:planet:cloudEvolution", range: -10000 ... 10000, step: 0.1)
              floatRow("Swirl", key: "primvars:akari:planet:cloudSwirl", range: 0 ... 2, step: 0.01)
              floatRow("Softness", key: "primvars:akari:planet:cloudSoftness", range: 0 ... 1, step: 0.01)
              floatRow("Shading", key: "primvars:akari:planet:cloudShading", range: 0 ... 1, step: 0.01)
            }

            PropertiesPanel("Surface Detail")
            {
              floatRow("Detail", key: "primvars:akari:planet:detail", range: 0 ... 2, step: 0.01)
              floatRow("Waves", key: "primvars:akari:planet:waves", range: 0 ... 2, step: 0.01)
              floatRow("Wave Time", key: "primvars:akari:planet:waveTime", range: -10000 ... 10000, step: 0.1, unit: "s")
              floatRow("City Intensity", key: "primvars:akari:planet:cityIntensity", range: 0 ... 100, step: 0.01)
              floatRow("City Density", key: "primvars:akari:planet:cityDensity", range: 0 ... 1, step: 0.01)
            }

            PropertiesPanel("Planet Palette")
            {
              colorRow("Land Low", key: "primvars:akari:planet:landColorLow")
              colorRow("Land High", key: "primvars:akari:planet:landColorHigh")
              colorRow("Forest", key: "primvars:akari:planet:forestColor")
              colorRow("Desert", key: "primvars:akari:planet:desertColor")
              colorRow("Shallow Water", key: "primvars:akari:planet:shallowColor")
              colorRow("Rock", key: "primvars:akari:planet:rockColor")
              colorRow("Snow", key: "primvars:akari:planet:snowColor")
              colorRow("Bloom", key: "primvars:akari:planet:bloomColor")
              floatRow("Bloom Amount", key: "primvars:akari:planet:bloomAmount", range: 0 ... 1, step: 0.01)
            }

            PropertiesPanel("Halo, Fill & Rim")
            {
              floatRow("Halo", key: "primvars:akari:atmosphere:halo", range: 0 ... 4, step: 0.01)
              colorRow("Halo Color", key: "primvars:akari:atmosphere:haloColor")
              floatRow("Halo Radius", key: "primvars:akari:atmosphere:haloRadius", range: 0 ... 4, step: 0.01)
              floatRow("Halo Streaks", key: "primvars:akari:atmosphere:haloStreaks", range: 0 ... 1, step: 0.01)
              floatRow("Halo Shadow", key: "primvars:akari:atmosphere:haloShadow", range: 0 ... 1, step: 0.01)
              floatRow("Fill Intensity", key: "primvars:akari:planet:fillIntensity", range: 0 ... 10, step: 0.01)
              colorRow("Fill Color", key: "primvars:akari:planet:fillColor")
              floatRow("Rim Intensity", key: "primvars:akari:planet:rimIntensity", range: 0 ... 1, step: 0.01)
              colorRow("Rim Color", key: "primvars:akari:planet:rimColor")
            }
          }
          else
          {
            Text("No prim with Akari atmosphere or planet attributes was found in this stage.")
              .font(.system(size: 11))
              .foregroundColor(Properties.label)
              .padding(10)
          }
        }
        .padding(6)
      }
    }

    private func floatRow(_ label: String,
                          key: String,
                          range: ClosedRange<Double>,
                          step: Double,
                          unit: String = "",
                          format: ((Double) -> String)? = nil) -> some View
    {
      let display = format ?? { value in
        if !unit.isEmpty { return String(format: "%.2f %@", value, unit) }
        return String(format: "%.3f", value)
      }
      return floatRow(label, value: state.floatBinding(key), range: range, step: step, format: display)
    }

    private func floatRow(_ label: String,
                          value: Binding<Double>,
                          range: ClosedRange<Double>,
                          step: Double,
                          format: @escaping (Double) -> String,
                          changed: (@MainActor () -> Void)? = nil) -> some View
    {
      Properties.row(label)
      {
        SliderField(value: value.onChange { _ in changed?() }, range: range, step: step, format: format)
      }
    }

    private func colorRow(_ label: String, key: String) -> some View
    {
      Properties.row(label)
      {
        ColorPicker(selection: state.colorBinding(key, in: environment)) {}
          .font(.system(size: 11))
          .frame(width: Double(Properties.controlWidth))
      }
    }

    private func assetRow(_ label: String, key: String) -> some View
    {
      Properties.row(label)
      {
        #if os(macOS)
          NativeTextField(text: state.assetBinding(key), width: Double(Properties.controlWidth))
        #else
          TextField("", text: state.assetBinding(key))
            .font(Properties.font)
            .frame(width: Double(Properties.controlWidth))
        #endif
      }
    }
  }
}
