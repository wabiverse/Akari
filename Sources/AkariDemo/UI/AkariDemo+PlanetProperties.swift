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
  /// Akari's procedural sky and planet primvars, `primvars:akari:atmosphere:*` and `:planet:*`, and the sphere's radius.
  enum PlanetPrimvar: String, CaseIterable, Sendable
  {
    case radius, atmosphere, planet
    case thickness, rayleighScaleHeight, mieScaleHeight, mieAnisotropy, ozoneCenter, ozoneWidth
    case nightIntensity, aerialPerspectiveDistance, skyIntensity, halo, haloRadius, haloStreaks, haloShadow
    case rayleighScattering, mieScattering, mieAbsorption, ozoneAbsorption, groundAlbedo, haloColor
    case groundTexture, nightTexture
    case seed, seaLevel, continentScale, mountainHeight, vegetation, desert, iceCaps, oceanRoughness
    case cloudCoverage, cloudAltitude, cloudRotation, cloudEvolution, cloudOpacity, cloudScale
    case cloudThickness, cityIntensity, cityDensity, cloudSwirl, detail, cloudSoftness, cloudShading, waves
    case waveTime, fillIntensity, rimIntensity, bloomAmount, oceanColor, landColorLow, landColorHigh
    case forestColor, desertColor, shallowColor, rockColor, snowColor, bloomColor, fillColor, rimColor

    private static let atmosphereInputs: Set<PlanetPrimvar> = [
      .thickness, .rayleighScaleHeight, .mieScaleHeight, .mieAnisotropy, .ozoneCenter, .ozoneWidth, .nightIntensity,
      .aerialPerspectiveDistance, .skyIntensity, .halo, .haloRadius, .haloStreaks, .haloShadow, .rayleighScattering,
      .mieScattering, .mieAbsorption, .ozoneAbsorption, .groundAlbedo, .haloColor, .groundTexture, .nightTexture,
    ]

    var token: Tf.Token
    {
      switch self
      {
        case .radius: .radius
        case .atmosphere, .planet: Tf.Token("primvars:akari:" + rawValue)
        default: Tf.Token("primvars:akari:" + (Self.atmosphereInputs.contains(self) ? "atmosphere:" : "planet:") + rawValue)
      }
    }
  }

  /// Edits the procedural atmosphere and planet primvars on the Hydra frame queue.
  @MainActor
  final class PlanetPropertiesState: ObservableObject
  {
    @Published var floats: [PlanetPrimvar: Double] = [:]
    @Published var booleans: [PlanetPrimvar: Bool] = [:]
    @Published var colors: [PlanetPrimvar: SIMD3<Double>] = [:]
    @Published var assets: [PlanetPrimvar: String] = [:]

    let primPath: String?

    private let hydra: Hydra.RenderEngine

    private static let floatDefaults: [PlanetPrimvar: Double] = [
      .radius: 1,
      .thickness: 100,
      .rayleighScaleHeight: 8,
      .mieScaleHeight: 1.2,
      .mieAnisotropy: 0.8,
      .ozoneCenter: 25,
      .ozoneWidth: 30,
      .nightIntensity: 1,
      .aerialPerspectiveDistance: 128,
      .skyIntensity: 1,
      .seed: 0,
      .seaLevel: 0.62,
      .continentScale: 2,
      .mountainHeight: 5,
      .vegetation: 0.7,
      .desert: 0.5,
      .iceCaps: 0.5,
      .oceanRoughness: 0.2,
      .cloudCoverage: 0.45,
      .cloudAltitude: 6,
      .cloudRotation: 0,
      .cloudEvolution: 0,
      .cloudOpacity: 0.95,
      .cloudScale: 1,
      .cloudThickness: 4,
      .cityIntensity: 0.02,
      .cityDensity: 0.5,
      .cloudSwirl: 0,
      .detail: 0,
      .cloudSoftness: 0,
      .cloudShading: 0,
      .waves: 0,
      .waveTime: 0,
      .halo: 0,
      .haloRadius: 0.25,
      .haloStreaks: 0.15,
      .haloShadow: 0.75,
      .fillIntensity: 0,
      .rimIntensity: 0,
      .bloomAmount: 0,
    ]

    private static let booleanDefaults: [PlanetPrimvar: Bool] = [
      .atmosphere: true,
      .planet: false,
    ]

    private static let colorDefaults: [PlanetPrimvar: SIMD3<Double>] = [
      .rayleighScattering: SIMD3(0.005802, 0.013558, 0.0331),
      .mieScattering: SIMD3(repeating: 0.003996),
      .mieAbsorption: SIMD3(repeating: 0.0044),
      .ozoneAbsorption: SIMD3(0.00065, 0.001881, 0.000085),
      .groundAlbedo: SIMD3(repeating: 0.3),
      .oceanColor: SIMD3(0.004, 0.016, 0.035),
      .landColorLow: SIMD3(repeating: -1),
      .landColorHigh: SIMD3(repeating: -1),
      .forestColor: SIMD3(repeating: -1),
      .desertColor: SIMD3(repeating: -1),
      .shallowColor: SIMD3(repeating: -1),
      .rockColor: SIMD3(repeating: -1),
      .snowColor: SIMD3(repeating: -1),
      .bloomColor: SIMD3(repeating: -1),
      .haloColor: SIMD3(0.45, 0.72, 1),
      .fillColor: SIMD3(0.55, 0.65, 1),
      .rimColor: SIMD3(0.6, 0.8, 1),
    ]

    private static let assetDefaults: [PlanetPrimvar: String] = [
      .groundTexture: "",
      .nightTexture: "",
    ]

    init(hydra: Hydra.RenderEngine)
    {
      self.hydra = hydra

      guard let prim = hydra.stage.traverse().first(where: {
        $0.attribute(named: PlanetPrimvar.atmosphere.token) != nil ||
          $0.attribute(named: PlanetPrimvar.planet.token) != nil
      })
      else { primPath = nil; return }

      primPath = prim.path.string

      for (name, fallback) in Self.floatDefaults
      {
        var value = Float(fallback)
        if name == .radius
        {
          var radius = fallback
          if let attribute = prim.attribute(named: name.token) { attribute.Get(&radius, UsdTimeCode.Default()) }
          floats[name] = radius
        }
        else
        {
          if let attribute = prim.attribute(named: name.token)
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
        if let attribute = prim.attribute(named: name.token)
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
        if let attribute = prim.attribute(named: name.token)
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
        if let attribute = prim.attribute(named: name.token)
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

    func floatBinding(_ name: PlanetPrimvar) -> Binding<Double>
    {
      Binding(get: { self.floats[name] ?? Self.floatDefaults[name] ?? 0 },
              set: { self.setFloat(name, $0) })
    }

    func boolBinding(_ name: PlanetPrimvar) -> Binding<Bool>
    {
      Binding(get: { self.booleans[name] ?? Self.booleanDefaults[name] ?? false },
              set: { self.setBool(name, $0) })
    }

    func colorBinding(_ name: PlanetPrimvar, in environment: EnvironmentValues) -> Binding<Color>
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

    func assetBinding(_ name: PlanetPrimvar) -> Binding<String>
    {
      Binding(get: { self.assets[name] ?? "" },
              set:
              { value in
                self.assets[name] = value
                self.writeAsset(name, value)
              })
    }

    private func setFloat(_ name: PlanetPrimvar, _ value: Double)
    {
      floats[name] = value
      let path = primPath

      hydra.performOnFrameQueue
      { [self] in
        guard let path else { return }
        let prim = hydra.stage.getPrim(at: path)

        let previous = hydra.stage.editTarget
        hydra.stage.SetEditTarget(Pixar.UsdEditTarget(hydra.stage.GetSessionLayer(), Pixar.SdfLayerOffset(offset: 0, scale: 1)))
        defer { hydra.stage.SetEditTarget(previous) }

        let type: Pixar.SdfValueTypeNameType = name == .radius ? .double : .float
        guard let attribute = prim.attribute(named: name.token)
          ?? prim.createAttribute(name: name.token, typeName: Sdf.getValueType(for: type), custom: true)
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

    private func setBool(_ name: PlanetPrimvar, _ value: Bool)
    {
      booleans[name] = value
      let path = primPath
      hydra.performOnFrameQueue
      { [self] in
        guard let path else { return }
        let prim = hydra.stage.getPrim(at: path)

        let previous = hydra.stage.editTarget
        hydra.stage.SetEditTarget(Pixar.UsdEditTarget(hydra.stage.GetSessionLayer(), Pixar.SdfLayerOffset(offset: 0, scale: 1)))
        defer { hydra.stage.SetEditTarget(previous) }

        guard let attribute = prim.attribute(named: name.token)
          ?? prim.createAttribute(name: name.token, typeName: .bool, custom: true)
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

    func writeColor(_ name: PlanetPrimvar, _ value: SIMD3<Double>)
    {
      let path = primPath
      hydra.performOnFrameQueue
      { [self] in
        guard let path else { return }
        let prim = hydra.stage.getPrim(at: path)

        let previous = hydra.stage.editTarget
        hydra.stage.SetEditTarget(Pixar.UsdEditTarget(hydra.stage.GetSessionLayer(), Pixar.SdfLayerOffset(offset: 0, scale: 1)))
        defer { hydra.stage.SetEditTarget(previous) }

        guard let attribute = prim.attribute(named: name.token)
          ?? prim.createAttribute(name: name.token, typeName: .color3f, custom: true)
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

    private func writeAsset(_ name: PlanetPrimvar, _ value: String)
    {
      let path = primPath
      hydra.performOnFrameQueue
      { [self] in
        guard let path else { return }
        let prim = hydra.stage.getPrim(at: path)

        let previous = hydra.stage.editTarget
        hydra.stage.SetEditTarget(Pixar.UsdEditTarget(hydra.stage.GetSessionLayer(), Pixar.SdfLayerOffset(offset: 0, scale: 1)))
        defer { hydra.stage.SetEditTarget(previous) }

        guard let attribute = prim.attribute(named: name.token)
          ?? prim.createAttribute(name: name.token, typeName: .asset, custom: true)
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
              floatRow("Viewport Steps", value: renderSettings.binding(\.planetCloudMarchSteps),
                       range: 8 ... 128, step: 1, format: { "\(Int($0))" })
              floatRow("Final Render Steps", value: renderSettings.binding(\.renderPlanetCloudMarchSteps),
                       range: 8 ... 128, step: 1, format: { "\(Int($0))" })
            }

            PropertiesPanel("Atmosphere", toggle: state.boolBinding(.atmosphere))
            {
              floatRow("Thickness", key: .thickness, range: 0.01 ... 1000,
                       step: 1, unit: "km")
              colorRow("Rayleigh", key: .rayleighScattering)
              floatRow("Rayleigh Height", key: .rayleighScaleHeight, range: 0.01 ... 100,
                       step: 0.1, unit: "km")
              colorRow("Mie Scattering", key: .mieScattering)
              colorRow("Mie Absorption", key: .mieAbsorption)
              floatRow("Mie Height", key: .mieScaleHeight, range: 0.01 ... 100,
                       step: 0.1, unit: "km")
              floatRow("Mie Anisotropy", key: .mieAnisotropy, range: -0.99 ... 0.99,
                       step: 0.01)
              colorRow("Ozone Absorption", key: .ozoneAbsorption)
              floatRow("Ozone Center", key: .ozoneCenter, range: 0 ... 100,
                       step: 0.1, unit: "km")
              floatRow("Ozone Width", key: .ozoneWidth, range: 0.01 ... 100,
                       step: 0.1, unit: "km")
              colorRow("Ground Albedo", key: .groundAlbedo)
              assetRow("Ground Texture", key: .groundTexture)
              assetRow("Night Texture", key: .nightTexture)
              floatRow("Night Intensity", key: .nightIntensity, range: 0 ... 100,
                       step: 0.1)
              floatRow("Aerial Distance", key: .aerialPerspectiveDistance,
                       range: 0.01 ... 10000, step: 1, unit: "km")
              floatRow("Sky Intensity", key: .skyIntensity, range: 0 ... 100,
                       step: 0.1)
            }

            PropertiesPanel("Planet", toggle: state.boolBinding(.planet))
            {
              floatRow("Radius", key: .radius, range: 0.001 ... 1e10, step: 100,
                       unit: "units", format: { String(format: "%.0f", $0) })
              floatRow("Seed", key: .seed, range: -100_000 ... 100_000,
                       step: 1, format: { String(format: "%.0f", $0) })
              floatRow("Sea Level", key: .seaLevel, range: 0 ... 1, step: 0.01)
              floatRow("Continent Scale", key: .continentScale, range: 0.01 ... 20, step: 0.01)
              floatRow("Mountain Height", key: .mountainHeight, range: 0 ... 100, step: 0.1, unit: "km")
              floatRow("Vegetation", key: .vegetation, range: 0 ... 1, step: 0.01)
              floatRow("Desert", key: .desert, range: 0 ... 1, step: 0.01)
              floatRow("Ice Caps", key: .iceCaps, range: 0 ... 1, step: 0.01)
              colorRow("Ocean Color", key: .oceanColor)
              floatRow("Ocean Roughness", key: .oceanRoughness, range: 0.02 ... 1, step: 0.01)
            }

            PropertiesPanel("Clouds")
            {
              floatRow("Coverage", key: .cloudCoverage, range: 0 ... 1, step: 0.01)
              floatRow("Altitude", key: .cloudAltitude, range: 0 ... 1000, step: 1, unit: "km")
              floatRow("Thickness", key: .cloudThickness, range: 0.01 ... 1000, step: 1, unit: "km")
              floatRow("Opacity", key: .cloudOpacity, range: 0 ... 1, step: 0.01)
              floatRow("Scale", key: .cloudScale, range: 0.01 ... 20, step: 0.01)
              floatRow("Rotation", key: .cloudRotation, range: -360 ... 360, step: 1, unit: "°")
              floatRow("Evolution", key: .cloudEvolution, range: -10000 ... 10000, step: 0.1)
              floatRow("Swirl", key: .cloudSwirl, range: 0 ... 2, step: 0.01)
              floatRow("Softness", key: .cloudSoftness, range: 0 ... 1, step: 0.01)
              floatRow("Shading", key: .cloudShading, range: 0 ... 1, step: 0.01)
            }

            PropertiesPanel("Surface Detail")
            {
              floatRow("Detail", key: .detail, range: 0 ... 2, step: 0.01)
              floatRow("Waves", key: .waves, range: 0 ... 2, step: 0.01)
              floatRow("Wave Time", key: .waveTime, range: -10000 ... 10000, step: 0.1, unit: "s")
              floatRow("City Intensity", key: .cityIntensity, range: 0 ... 100, step: 0.01)
              floatRow("City Density", key: .cityDensity, range: 0 ... 1, step: 0.01)
            }

            PropertiesPanel("Planet Palette")
            {
              colorRow("Land Low", key: .landColorLow)
              colorRow("Land High", key: .landColorHigh)
              colorRow("Forest", key: .forestColor)
              colorRow("Desert", key: .desertColor)
              colorRow("Shallow Water", key: .shallowColor)
              colorRow("Rock", key: .rockColor)
              colorRow("Snow", key: .snowColor)
              colorRow("Bloom", key: .bloomColor)
              floatRow("Bloom Amount", key: .bloomAmount, range: 0 ... 1, step: 0.01)
            }

            PropertiesPanel("Halo, Fill & Rim")
            {
              floatRow("Halo", key: .halo, range: 0 ... 4, step: 0.01)
              colorRow("Halo Color", key: .haloColor)
              floatRow("Halo Radius", key: .haloRadius, range: 0 ... 4, step: 0.01)
              floatRow("Halo Streaks", key: .haloStreaks, range: 0 ... 1, step: 0.01)
              floatRow("Halo Shadow", key: .haloShadow, range: 0 ... 1, step: 0.01)
              floatRow("Fill Intensity", key: .fillIntensity, range: 0 ... 10, step: 0.01)
              colorRow("Fill Color", key: .fillColor)
              floatRow("Rim Intensity", key: .rimIntensity, range: 0 ... 1, step: 0.01)
              colorRow("Rim Color", key: .rimColor)
            }
          }
      }
    }

    private func floatRow(_ label: String,
                          key: PlanetPrimvar,
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
                          format: @escaping (Double) -> String) -> some View
    {
      Properties.row(label)
      {
        SliderField(value: value, range: range, step: step, format: format)
      }
    }

    private func colorRow(_ label: String, key: PlanetPrimvar) -> some View
    {
      Properties.row(label)
      {
        ColorPicker(selection: state.colorBinding(key, in: environment)) {}
          .font(.system(size: 11))
          .frame(width: Double(Properties.controlWidth))
      }
    }

    private func assetRow(_ label: String, key: PlanetPrimvar) -> some View
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
