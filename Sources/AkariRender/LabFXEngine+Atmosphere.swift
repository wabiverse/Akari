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
import Foundation
import HdAkari
import LabGL
import simd

extension Akari.LabFXEngine
{
  /// The stage's planet, a sphere with `primvars:akari:atmosphere`, lit by the sun.
  struct Atmosphere
  {
    struct Planet: Equatable
    {
      /// The ground's center and radius, in stage units.
      var center: SIMD3<Double>
      var radius: Double
      var fromWorld: simd_float3x3
      /// Thickness and every length after it in kilometers, coefficients per kilometer.
      var thickness: Float
      var rayleigh: SIMD4<Float>
      var mie: SIMD4<Float>
      var mieExtra: SIMD4<Float>
      var ozone: SIMD4<Float>
      var ground: SIMD4<Float>
      var aerialDistance: Float
      var skyIntensity: Float
      var nightIntensity: Float
      var groundTexture: String
      var nightTexture: String
      /// The procedural surface, zero `procedural.x` when the planet uses its albedo or textures.
      var procedural: SIMD4<Float>
      var terrain: SIMD4<Float>
      var ocean: SIMD4<Float>
      var clouds: SIMD4<Float>
      var cities: SIMD4<Float>
      /// The cloud slab's thickness in km.
      var cloudShape: SIMD4<Float>
      /// The surface palette, a color per column with w 1 where authored
      /// (land low, land high, forest, desert, shallows, rock, snow, bloom (its w the bloom amount)).
      var paletteA: simd_float4x4
      var paletteB: simd_float4x4
      /// Halo (color, strength), (radius as a fraction of the planet's, streaks, night side shadow, 0), fill, rim.
      var look: simd_float4x4
      /// Wave strength, wave time in seconds, cloud shading.
      var style: SIMD4<Float>
    }

    struct Map
    {
      var file = ""
      var texture: GLuint = 0
    }

    var revision: UInt64 = .max
    var planet: Planet?
    var eye = SIMD3<Float>(repeating: 0)
    var ground = Map()
    var night = Map()
    var placeholder: GLuint = 0
    var bakedLUTs: [Float] = []
    /// What the planet's cloud map was last baked from, and whether it bakes this frame.
    var bakedCloudMap: [Float] = []
    var cloudMapThisFrame = true
    var lutsThisFrame = true
    var skyViewActive = true
    var aerialActive = true
    var bakedAltitude = Double.nan
    var bakedSun = SIMD3<Int32>(repeating: .min)
    /// The sun's transmittance down to the eye, for what lights without the per pixel lookup.
    var sunTransmittance = SIMD3<Float>(repeating: 1)
  }

  static let atmosphereLUTPasses: [Pass] = [.atmosphereTransmittance, .atmosphereMultiscatter]

  /// The sun's illuminance when the stage has an atmosphere but no distant light.
  static let atmosphereDefaultSun = SIMD3<Float>(repeating: 3)

  /// Picks up the stage's planet, `eye` is where this frame's camera sits in the world.
  func syncAtmosphere(_ scene: Pixar.HdAkariScene, eye: SIMD3<Float>, cloudMarchSteps: Int)
  {
    atmosphere.eye = eye
    setFloat(.planetCloudMarchSteps, Float(min(max(cloudMarchSteps, 1), 128)))
    let revision = scene.AtmosphereRevision()
    guard revision != atmosphere.revision else { return }
    atmosphere.revision = revision

    var data = Pixar.HdAkariAtmosphereData()
    guard scene.AtmosphereSnapshot(&data), let p = data.transform.GetArray()
    else
    {
      atmosphere.planet = nil
      return
    }

    let rows = (0 ..< 3).map { SIMD3(p[$0 * 4], p[$0 * 4 + 1], p[$0 * 4 + 2]) }
    let scale = Akari.Math.length(rows[0])
    let fromWorld = simd_float3x3(rows: rows.map { SIMD3<Float>(Akari.Math.normalize($0)) })
    atmosphere.planet = Atmosphere.Planet(
      center: SIMD3(p[12], p[13], p[14]),
      radius: data.radius * scale,
      fromWorld: fromWorld,
      thickness: max(data.thickness, 1e-3),
      rayleigh: SIMD4(data.rayleighR, data.rayleighG, data.rayleighB, max(data.rayleighScaleHeight, 1e-3)),
      mie: SIMD4(data.mieR, data.mieG, data.mieB, max(data.mieScaleHeight, 1e-3)),
      mieExtra: SIMD4(data.mieAbsorptionR, data.mieAbsorptionG, data.mieAbsorptionB, min(max(data.mieAnisotropy, -0.99), 0.99)),
      ozone: SIMD4(data.ozoneR, data.ozoneG, data.ozoneB, data.ozoneCenter),
      ground: SIMD4(data.groundAlbedoR, data.groundAlbedoG, data.groundAlbedoB, max(data.ozoneWidth, 1e-3)),
      aerialDistance: max(data.aerialPerspectiveDistance, 1e-3),
      skyIntensity: data.skyIntensity,
      nightIntensity: data.nightIntensity,
      groundTexture: String(data.groundTexture),
      nightTexture: String(data.nightTexture),
      procedural: SIMD4(data.planet ? 1 : 0, data.planetSeed, data.seaLevel, max(data.continentScale, 0.01)),
      terrain: SIMD4(data.mountainHeight, data.vegetation, data.desert, data.iceCaps),
      ocean: SIMD4(data.oceanR, data.oceanG, data.oceanB, data.oceanRoughness),
      clouds: SIMD4(data.planet ? data.cloudCoverage : 0, data.cloudAltitude, data.cloudRotation * .pi / 180, data.cloudEvolution),
      cities: SIMD4(data.cityIntensity, data.cityDensity, data.cloudOpacity, max(data.cloudScale, 0.01)),
      cloudShape: SIMD4(max(data.cloudThickness, 0), max(data.cloudSwirl, 0), max(data.detail, 0), min(max(data.cloudSoftness, 0), 1)),
      paletteA: simd_float4x4(columns: (Self.paletteColor(data.landColorLow), Self.paletteColor(data.landColorHigh),
                                        Self.paletteColor(data.forestColor), Self.paletteColor(data.desertColor))),
      paletteB: simd_float4x4(columns: (Self.paletteColor(data.shallowColor), Self.paletteColor(data.rockColor),
                                        Self.paletteColor(data.snowColor),
                                        Self.paletteColor(data.bloomColor) * SIMD4(1, 1, 1, 0) + SIMD4(0, 0, 0, max(data.bloomAmount, 0)))),
      look: simd_float4x4(columns: (SIMD4(data.haloColor.0, data.haloColor.1, data.haloColor.2, max(data.haloIntensity, 0)),
                                    SIMD4(max(data.haloRadius, 1e-3), min(max(data.haloStreaks, 0), 1), min(max(data.haloShadow, 0), 1), 0),
                                    SIMD4(data.fillColor.0, data.fillColor.1, data.fillColor.2, max(data.fillIntensity, 0)),
                                    SIMD4(data.rimColor.0, data.rimColor.1, data.rimColor.2, max(data.rimIntensity, 0)))),
      style: SIMD4(max(data.waves, 0), data.waveTime, min(max(data.cloudShading, 0), 1), 0)
    )
  }

  /// Whether `key` differs from what was baked by more than the rounding a held USD key interpolates with.
  private static func moved(_ key: [Float], from baked: [Float]) -> Bool
  {
    key.count != baked.count || zip(key, baked).contains { abs($0 - $1) > 1e-5 * max(abs($0), abs($1)) }
  }

  /// A palette color from its USD triple, w 1 when authored.
  private static func paletteColor(_ c: (Float, Float, Float)) -> SIMD4<Float>
  {
    c.0 < 0 ? .zero : SIMD4(c.0, c.1, c.2, 1)
  }

  /// Binds the planet for the frame, toggles its passes, and rebakes the LUTs or the
  /// environment once the atmosphere, the sun, or the eye's altitude has moved enough.
  func applyAtmosphere(sun: SIMD3<Float>)
  {
    guard let planet = atmosphere.planet
    else
    {
      setVector(.atmosphere, .zero)
      setAtmospherePasses(luts: false, skyView: false, aerial: false)
      atmosphere.bakedLUTs = []
      return
    }

    let kmPerUnit = Double(stageMetersPerUnit) / 1000
    let bottom = Float(planet.radius * kmPerUnit)
    let top = bottom + planet.thickness
    let offset = (SIMD3<Double>(atmosphere.eye) - planet.center) * kmPerUnit
    let distance = Akari.Math.length(offset)
    let altitude = distance - planet.radius * kmPerUnit
    let up = distance > 0 ? SIMD3<Float>(offset / distance) : SIMD3(0, 1, 0)
    let height = max(altitude, 1e-3)

    let shape = SIMD4(1, bottom, top, planet.aerialDistance)
    let lutKey = [bottom, top, planet.ozone.w, planet.ground.w]
      + [planet.rayleigh, planet.mie, planet.mieExtra, planet.ozone, planet.ground].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    if environment.iblNeedsBake { atmosphere.bakedLUTs = [] }
    let luts = Self.moved(lutKey, from: atmosphere.bakedLUTs)
    if luts { atmosphere.bakedLUTs = lutKey }
    // the cloud cover only changes with the clouds' own settings, not with the camera.
    let cloudKey = [bottom] + [planet.procedural, planet.clouds, planet.cities, planet.cloudShape].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    let cloudMap = Self.moved(cloudKey, from: atmosphere.bakedCloudMap)
    if cloudMap { atmosphere.bakedCloudMap = cloudKey }
    if cloudMap != atmosphere.cloudMapThisFrame
    {
      runtime.setPassActive(.planetCloudMap, active: cloudMap)
      atmosphere.cloudMapThisFrame = cloudMap
    }

    setVector(.atmosphere, shape)
    setVector(.atmosRayleigh, planet.rayleigh)
    setVector(.atmosMie, planet.mie)
    setVector(.atmosMieExtra, planet.mieExtra)
    setVector(.atmosOzone, planet.ozone)
    setVector(.atmosGround, planet.ground)
    setVector(.planet, planet.procedural)
    setVector(.planetTerrain, planet.terrain)
    setVector(.planetOcean, planet.ocean)
    setVector(.planetClouds, planet.clouds)
    setVector(.planetCity, planet.cities)
    setVector(.planetCloudShape, planet.cloudShape)
    setMatrix(.planetPaletteA, Akari.Matrix4(planet.paletteA))
    setMatrix(.planetPaletteB, Akari.Matrix4(planet.paletteB))
    setMatrix(.planetLook, Akari.Matrix4(planet.look))
    setVector(.planetStyle, planet.style)
    setVector(.atmosCamera, SIMD4(up * (bottom + Float(height)), Float(altitude)))

    let sunE = environment.distantSun?.irradiance ?? Self.atmosphereDefaultSun
    setVector(.atmosSun, SIMD4(sunE, planet.skyIntensity))

    atmosphere.ground = loadAtmosphereMap(planet.groundTexture, into: atmosphere.ground)
    atmosphere.night = loadAtmosphereMap(planet.nightTexture, into: atmosphere.night)
    setSampler(.atmosGroundMap, atmosphere.ground.texture != 0 ? atmosphere.ground.texture : atmospherePlaceholder())
    setSampler(.atmosNightMap, atmosphere.night.texture != 0 ? atmosphere.night.texture : atmospherePlaceholder())
    setVector(.atmosFrame, SIMD4(Float(kmPerUnit),
                                    atmosphere.ground.texture != 0 ? 1 : 0,
                                    atmosphere.night.texture != 0 ? 1 : 0,
                                    planet.nightIntensity))
    setMatrix(.atmosPlanetFromWorld, Akari.Matrix4(simd_float4x4(columns: (SIMD4(planet.fromWorld.columns.0, 0),
                                                                              SIMD4(planet.fromWorld.columns.1, 0),
                                                                              SIMD4(planet.fromWorld.columns.2, 0),
                                                                              SIMD4(0, 0, 0, 1)))))

    atmosphere.sunTransmittance = Self.atmosphereSunTransmittance(planet,
                                                                  bottom: bottom,
                                                                  top: top,
                                                                  r: bottom + Float(height),
                                                                  mu: Akari.Math.dot(up, Akari.Math.normalize(sun)))
    setVector(.sunOverride, SIMD4(sunE * atmosphere.sunTransmittance, 1))

    setAtmospherePasses(luts: luts, skyView: bottom + Float(height) < top, aerial: true)

    // the sky only rebakes when the camera crosses into another altitude band (3 % wide, never
    // narrower than ~60 m near the ground) or the sun turns ~0.05°: fixed bands, so a frame bakes the
    // same sky whichever frame a render started from.
    // above the atmosphere the sky is the planet's disk, it changes far more slowly with height.
    let thickness = Double(top - bottom)
    let band = altitude < thickness
      ? (log((max(altitude, 0) + 2) / 2) / 0.03).rounded(.down)
      : 1e6 + (log(altitude / thickness) / 0.25).rounded(.down)
    let sunBand = SIMD3<Int32>(Akari.Math.normalize(sun) * 1000, rounding: .toNearestOrEven)
    if luts || band != atmosphere.bakedAltitude || sunBand != atmosphere.bakedSun
    {
      atmosphere.bakedAltitude = band
      atmosphere.bakedSun = sunBand
      environment.iblNeedsBake = true
      environment.revision += 1
    }
  }

  /// The LUTs bake once, on the frame after they changed.
  func finishAtmosphereFrame()
  {
    if volumes.shadowThisFrame
    {
      runtime.setPassActive(.volumeShadow, active: false)
      volumes.shadowThisFrame = false
    }

    if atmosphere.lutsThisFrame
    {
      setPasses(Self.atmosphereLUTPasses, active: false)
      atmosphere.lutsThisFrame = false
    }

    if atmosphere.cloudMapThisFrame
    {
      runtime.setPassActive(.planetCloudMap, active: false)
      atmosphere.cloudMapThisFrame = false
    }
  }

  private func setAtmospherePasses(luts: Bool, skyView: Bool, aerial: Bool)
  {
    if luts != atmosphere.lutsThisFrame
    {
      setPasses(Self.atmosphereLUTPasses, active: luts)
      atmosphere.lutsThisFrame = luts
    }

    if skyView != atmosphere.skyViewActive
    {
      runtime.setPassActive(.atmosphereSkyView, active: skyView)
      atmosphere.skyViewActive = skyView
    }

    if aerial != atmosphere.aerialActive
    {
      runtime.setPassActive(.atmosphereAerial, active: aerial)
      runtime.setPassActive(.atmosphereBackground, active: aerial)
      atmosphere.aerialActive = aerial
    }
  }

  private func atmospherePlaceholder() -> GLuint
  {
    if atmosphere.placeholder == 0
    {
      gl.genTextures(count: 1, textures: &atmosphere.placeholder)
      gl.bindTexture(target: GL_TEXTURE_2D, texture: atmosphere.placeholder)
      gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_MIN_FILTER, param: GLint(GL_LINEAR))
      gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_MAG_FILTER, param: GLint(GL_LINEAR))
      let pixels = [UInt8](repeating: 0, count: 4)
      gl.texImage2D(target: GL_TEXTURE_2D, level: 0, internalFormat: GL_RGBA8,
                    width: 1, height: 1, border: 0,
                    format: GL_RGBA, type: GL_UNSIGNED_BYTE, pixels: pixels)
    }

    return atmosphere.placeholder
  }

  private func loadAtmosphereMap(_ file: String, into map: Atmosphere.Map) -> Atmosphere.Map
  {
    guard file != map.file else { return map }
    var next = map
    next.file = file
    if next.texture != 0 { gl.deleteTextures(count: 1, textures: &next.texture); next.texture = 0 }
    guard !file.isEmpty, let image = Pixar.HdAkariLoadDomeImage(std.string(file), 16, 0, nil) else { return next }
    defer { Pixar.HdAkariFreeDomeImage(image) }
    let width = Int(Pixar.HdAkariDomeImageWidth(image)), height = Int(Pixar.HdAkariDomeImageHeight(image))
    let pixels = Array(UnsafeBufferPointer(start: Pixar.HdAkariDomeImagePixels(image), count: width * height * 4))
    gl.genTextures(count: 1, textures: &next.texture)
    gl.bindTexture(target: GL_TEXTURE_2D, texture: next.texture)
    gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_MIN_FILTER, param: GLint(GL_LINEAR_MIPMAP_LINEAR))
    gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_MAG_FILTER, param: GLint(GL_LINEAR))
    gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_WRAP_S, param: GLint(GL_REPEAT))
    gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_WRAP_T, param: GLint(GL_CLAMP_TO_EDGE))
    gl.texImage2D(target: GL_TEXTURE_2D, level: 0, internalFormat: GL_RGBA16F,
                  width: GLsizei(width), height: GLsizei(height), border: 0,
                  format: GL_RGBA, type: GLenum(GL_HALF_FLOAT), pixels: pixels)
    gl.generateMipmap(GL_TEXTURE_2D)
    return next
  }

  /// The sun's transmittance from `r` km toward `mu`, zero behind the planet.
  private static func atmosphereSunTransmittance(_ planet: Atmosphere.Planet, bottom: Float, top: Float,
                                                 r: Float, mu: Float) -> SIMD3<Float>
  {
    if mu < 0, r * r * mu * mu - (r - bottom) * (r + bottom) >= 0 { return .zero }
    let reach = max(-r * mu + max(r * r * mu * mu + (top - r) * (top + r), 0).squareRoot(), 0)
    let steps = 64
    let dt = reach / Float(steps)
    var depth = SIMD3<Float>(repeating: 0)
    for i in 0 ..< steps
    {
      let t = (Float(i) + 0.5) * dt
      let h = max((t * t + 2 * r * mu * t + r * r).squareRoot() - bottom, 0)
      let rayleigh = exp(-h / planet.rayleigh.w)
      let mie = exp(-h / planet.mie.w)
      let ozone = max(0, 1 - abs(h - planet.ozone.w) / (0.5 * planet.ground.w))
      let extinction = SIMD3(planet.rayleigh.x, planet.rayleigh.y, planet.rayleigh.z) * rayleigh
        + (SIMD3(planet.mie.x, planet.mie.y, planet.mie.z) + SIMD3(planet.mieExtra.x, planet.mieExtra.y, planet.mieExtra.z)) * mie
        + SIMD3(planet.ozone.x, planet.ozone.y, planet.ozone.z) * ozone
      depth += extinction * dt
    }

    return SIMD3(exp(-depth.x), exp(-depth.y), exp(-depth.z))
  }
}
