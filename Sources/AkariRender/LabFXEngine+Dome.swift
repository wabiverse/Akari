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
  /// the stage sun and image based lighting, and what they were last baked from.
  struct Environment
  {
    /// the brightest distant light on the stage, used as the sun instead of the dome or sky sun.
    var distantSun: (direction: SIMD3<Float>, irradiance: SIMD3<Float>, angle: Float)?
    /// how much of the stage dome and sun show through the sun height sky, all of it by day and none after sunset.
    var domeWeight: Float = 1
    /// the stage sun the hud sun sliders were last started from.
    var authoredSun = StageSun.none
    /// the rect light used as `distantSun` and left out of the local lights.
    var rectSunKey: LightKey?
    /// union of every bounds the chosen geometry has had, a rect light far outside it counts as the sun.
    var sunSceneBounds: (min: SIMD3<Float>, max: SIMD3<Float>)?
    var domeRevision: UInt64 = .max
    /// whether the procedural sky was on at the last dome sync, the flat world stands in for it when off
    var domeShowedSky = true
    /// the dome file and frame the image based lighting was last baked from.
    var domeBakeKey: (file: String, values: [Float]) = ("\u{0}", [])
    /// the dome color rounded to a sixteenth of a stop, the light probes relight when it changes
    var domeColorBand: [Float] = []
    /// the dome color the image based lighting was baked with, color changes rescale it instead of rebaking.
    var bakedDomeColor = SIMD3<Float>(repeating: 1)
    /// bumped when the environment changes so the light probes relight.
    var revision: UInt64 = 0
    /// ibl is expensive, so this flags it to bake once.
    var iblNeedsBake = true
    /// the dfg table only depends on the brdf, so it only bakes again after the buffers are rebuilt.
    var dfgNeedsBake = true
    /// revision the env cube was last baked at
    var bakedRevision: UInt64 = .max
  }

  /// a dome light environment, uploaded when it changes.
  struct Dome
  {
    var file: String
    var map: GLuint
    /// the box filtered copy the environment cube bakes from, with its sun taken out to shade as the sun.
    var small: [UInt16]
    /// the same copy with the sun left in, baked while a distant light acts as the sun instead.
    var smallFull: [UInt16]
    var smallSize: SIMD2<Int>
    var fromWorld: Akari.Matrix4
    var fromSky: Akari.Matrix4
    var color: SIMD3<Float>
    /// the sun extracted from the dome in dome space, with irradiance before `color` and its spread angle.
    var sun: (direction: SIMD3<Float>, irradiance: SIMD3<Float>, angle: Float)?
    var sunDirection: SIMD3<Float>?
    /// shown behind the scene, a dome kept out of it still lights
    var cameraVisible = true
  }

  /// default world sun threshold.
  static let domeSunThreshold = Pixar.HdAkariDomeSunThreshold

  static let domeSmallWidth = Int(Pixar.HdAkariDomeSmallWidth)

  /// picks up the stage dome light, which replaces the procedural sky while it exists.
  func syncDome(_ scene: Pixar.HdAkariScene, showsSky: Bool = true)
  {
    defer
    {
      reloadProgress = 1
      reloadPending = false
    }

    if forceDomeReload
    {
      forceDomeReload = false
      environment.domeRevision = .max
      dome?.file = "\u{0}"
    }

    let revision = scene.DomeRevision()
    guard revision != environment.domeRevision || showsSky != environment.domeShowedSky else { return }

    environment.domeRevision = revision
    environment.domeShowedSky = showsSky

    var data = Pixar.HdAkariDomeData()
    guard scene.DomeSnapshot(&data)
    else
    {
      // with the sky off and no dome on the stage a flat grey world lights the scene and shows behind it
      if !showsSky { return adoptWorld() }

      if let dome
      {
        var map = dome.map
        gl.deleteTextures(count: 1, textures: &map)
        self.dome = nil
        domeChanged()
      }

      return
    }

    let file = String(data.textureFile)
    var next = dome ?? Dome(file: "\u{0}", map: 0, small: [], smallFull: [], smallSize: .zero, fromWorld: Akari.Matrix4(matrix_identity_float4x4),
                            fromSky: Akari.Matrix4(matrix_identity_float4x4), color: .one, sun: nil, sunDirection: nil)

    if file != next.file
    {
      next.file = file
      if next.map != 0
      {
        gl.deleteTextures(count: 1, textures: &next.map)
        next.map = 0
      }

      var width = 2
      var height = 1
      var pixels = [UInt16](repeating: Self.halfOne, count: 8)
      next.small = [UInt16](repeating: Self.halfOne, count: Self.domeSmallWidth * Self.domeSmallWidth / 2 * 4)
      next.smallFull = next.small
      next.smallSize = SIMD2(Self.domeSmallWidth, Self.domeSmallWidth / 2)
      next.sun = nil

      if !file.isEmpty, let image = Pixar.HdAkariLoadDomeImage(std.string(file),
                                                               Int32(Self.domeSmallWidth),
                                                               Self.domeSunThreshold,
                                                               &reloadState.pointee.progress)
      {
        defer { Pixar.HdAkariFreeDomeImage(image) }
        width = Int(Pixar.HdAkariDomeImageWidth(image))
        height = Int(Pixar.HdAkariDomeImageHeight(image))
        pixels = Array(UnsafeBufferPointer(start: Pixar.HdAkariDomeImagePixels(image), count: width * height * 4))

        let sw = Int(Pixar.HdAkariDomeImageSmallWidth(image))
        let sh = Int(Pixar.HdAkariDomeImageSmallHeight(image))
        next.small = Array(UnsafeBufferPointer(start: Pixar.HdAkariDomeImageSmall(image), count: sw * sh * 4))
        next.smallFull = Array(UnsafeBufferPointer(start: Pixar.HdAkariDomeImageSmallFull(image), count: sw * sh * 4))
        next.smallSize = SIMD2(sw, sh)

        if Pixar.HdAkariDomeImageHasSun(image)
        {
          let v = (0 ..< 7).map { Pixar.HdAkariDomeImageSun(image, Int32($0)) }
          next.sun = (SIMD3(v[0], v[1], v[2]), SIMD3(v[3], v[4], v[5]), v[6])
        }
      }

      // the full size image is freed but the allocator would otherwise hold on to it.
      malloc_zone_pressure_relief(nil, 0)

      gl.genTextures(count: 1, textures: &next.map)
      gl.bindTexture(target: GL_TEXTURE_2D, texture: next.map)
      gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_MIN_FILTER, param: GLint(GL_LINEAR))
      gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_MAG_FILTER, param: GLint(GL_LINEAR))
      gl.texImage2D(target: GL_TEXTURE_2D, level: 0, internalFormat: GL_RGBA16F,
                    width: GLsizei(width), height: GLsizei(height), border: 0,
                    format: GL_RGBA, type: GLenum(GL_HALF_FLOAT), pixels: pixels)
    }

    let m = Pixar.GfMatrix4f(data.transform)
    if let p = m.GetArray()
    {
      let rows = (0 ..< 3).map { Akari.Math.normalize(SIMD3(p[$0 * 4], p[$0 * 4 + 1], p[$0 * 4 + 2])) }
      let fromWorld = simd_float3x3(rows: rows)
      let skyToWorld = stageIsZUp ? simd_float3x3(rows: [SIMD3(1, 0, 0), SIMD3(0, 0, -1), SIMD3(0, 1, 0)])
        : matrix_identity_float3x3
      next.fromWorld = Akari.Matrix4(Self.expand(fromWorld))
      next.fromSky = Akari.Matrix4(Self.expand(fromWorld * skyToWorld))
      next.sunDirection = next.sun.map { Akari.Math.normalize(fromWorld.transpose * $0.direction) }
    }

    next.color = SIMD3(data.colorR, data.colorG, data.colorB) * data.intensity * exp2(data.exposure)
    next.cameraVisible = data.cameraVisible
    dome = next

    // baked lighting scales with the dome color so a color change only updates the tint, a new image or frame rebakes
    var values: [Float] = []
    next.fromWorld.withUnsafeFloats { values = $0.map { ($0 * 1000).rounded() } }
    let key = (file: next.file, values: values)
    let colorBand = (0 ..< 3).map { Self.band(next.color[$0]) }

    if key.file != environment.domeBakeKey.file || key.values != environment.domeBakeKey.values
      || environment.bakedDomeColor.min() < 1e-4
    {
      environment.domeBakeKey = key
      environment.domeColorBand = colorBand
      domeChanged()
    }
    else if colorBand != environment.domeColorBand
    {
      environment.domeColorBand = colorBand
    }
  }

  /// `value` in bands of a sixteenth of a stop.
  static func band(_ value: Float) -> Float
  {
    value <= 0 ? -1e9 : (log2(value) * 16).rounded()
  }

  /// the flat world that stands in for the sky when it is turned off, a dome with no sun in it
  private func adoptWorld()
  {
    guard dome?.file != Self.worldFile else { return }
    if var map = dome?.map, map != 0 { gl.deleteTextures(count: 1, textures: &map) }

    let size = SIMD2(Self.domeSmallWidth, Self.domeSmallWidth / 2)
    let texel: [UInt16] = [Self.worldGrey, Self.worldGrey, Self.worldGrey, Self.halfOne]
    let small = Array([[UInt16]](repeating: texel, count: size.x * size.y).joined())
    var next = Dome(file: Self.worldFile, map: 0, small: small, smallFull: small, smallSize: size,
                    fromWorld: Akari.Matrix4(matrix_identity_float4x4), fromSky: Akari.Matrix4(matrix_identity_float4x4), color: .one,
                    sun: nil, sunDirection: nil)

    gl.genTextures(count: 1, textures: &next.map)
    gl.bindTexture(target: GL_TEXTURE_2D, texture: next.map)
    gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_MIN_FILTER, param: GLint(GL_LINEAR))
    gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_MAG_FILTER, param: GLint(GL_LINEAR))
    gl.texImage2D(target: GL_TEXTURE_2D, level: 0, internalFormat: GL_RGBA16F, width: 2, height: 1, border: 0,
                  format: GL_RGBA, type: GLenum(GL_HALF_FLOAT), pixels: texel + texel)

    dome = next
    environment.domeBakeKey = (Self.worldFile, [])
    environment.domeColorBand = [0, 0, 0]
    domeChanged()
  }

  /// the name the flat world goes by in place of a dome file, no file on disk is called this
  static let worldFile = "\u{1}world"
  /// the flat world's grey as a half float, 0.05 linear like an empty world elsewhere
  private static let worldGrey: UInt16 = 0x2A66

  /// what lights the scene as the sun, the sky's sun or the dome's, nothing without ibl or under a dome with no sun in it
  func sunColor(iblEnabled: Bool) -> SIMD4<Float>
  {
    if let distantSun = environment.distantSun { return SIMD4(distantSun.irradiance * atmosphere.sunTransmittance, 2) }
    if atmosphere.planet != nil { return SIMD4(Self.atmosphereDefaultSun * atmosphere.sunTransmittance, 2) }

    guard iblEnabled else { return .zero }
    guard let dome else { return SIMD4(0, 0, 0, 1) }

    return SIMD4((dome.sun?.irradiance ?? .zero) * dome.color, 2)
  }

  /// picks up the brightest distant light on the stage, the sun every surface sees from one direction.
  func syncDistant(_ scene: Pixar.HdAkariScene)
  {
    var data = Pixar.HdAkariDistantData()
    var next: (direction: SIMD3<Float>, irradiance: SIMD3<Float>, angle: Float)?
    environment.rectSunKey = nil

    if scene.DistantSnapshot(&data), let p = Pixar.GfMatrix4f(data.transform).GetArray()
    {
      next = (Akari.Math.normalize(SIMD3(p[8], p[9], p[10])),
              SIMD3(data.colorR, data.colorG, data.colorB) * data.intensity * exp2(data.exposure),
              data.angle * .pi / 180)
    }
    else if let chosen = sceneBounds
    {
      let bounds = environment.sunSceneBounds.map { (min: pointwiseMin($0.min, chosen.min), max: pointwiseMax($0.max, chosen.max)) } ?? chosen
      environment.sunSceneBounds = bounds

      // a rect light aimed in from far outside the scene is a sun shining down its own axis.
      let center = (bounds.min + bounds.max) * 0.5
      let radius = simd_length(bounds.max - bounds.min) * 0.5
      var best: Float = 0

      for light in scene.LightSnapshot() where light.visible && light.width > 0 && light.height > 0
      {
        guard let p = Pixar.GfMatrix4f(light.transform).GetArray() else { continue }
        let offset = SIMD3(p[12], p[13], p[14]) - center
        let d = simd_length(offset)
        guard d > radius * 2 else { continue }

        let toward = offset / d
        let area = light.width * light.height * simd_length(SIMD3(p[0], p[1], p[2])) * simd_length(SIMD3(p[4], p[5], p[6]))
        let axis = Akari.Math.normalize(SIMD3(p[8], p[9], p[10]))
        let facing = simd_dot(axis, toward)
        guard facing > 0.5 else { continue }

        let irradiance = SIMD3(light.colorR, light.colorG, light.colorB) * light.intensity * exp2(light.exposure)
          * area * facing / (d * d)
        guard irradiance.max() > best else { continue }

        best = irradiance.max()
        next = (axis, irradiance, 2 * atan((area / .pi).squareRoot() / d))
        environment.rectSunKey = Pixar.HdAkariPathKey(light.id)
      }
    }

    // the dome bakes with its own sun left in while a distant light takes over as the sun.
    if (next == nil) != (environment.distantSun == nil), dome?.sun != nil
    {
      environment.iblNeedsBake = true
      environment.revision += 1
    }

    environment.distantSun = next
  }

  /// rereads the dome image on the next sync after it changed on disk.
  public func reloadTextures()
  {
    reloadProgress = 0
    reloadPending = true
    forceDomeReload = true
  }

  /// binds the dome for the frame, or turns it off.
  func applyDome(_ light: LightSettings)
  {
    setFloat(.domeEnabled, dome == nil ? 0 : environment.domeWeight)
    setFloat(.domeBackground, dome?.cameraVisible == false ? 0 : 1)
    setVector(.iblTint, SIMD4(iblTint, 1))
    guard let dome else { return }

    // turned so the sun the dome was shot with sits where sun height puts it.
    var fromWorld = dome.fromWorld
    if let authored = authoredSunDirection, let swung = swungSun(light)
    {
      let turn = Akari.Matrix4(simd_float4x4(simd_quatf(from: authored, to: swung.sun)))
      fromWorld = dome.fromWorld * turn.inverse()
    }

    setSampler(.domeMap, dome.map)
    setMatrix(.domeFromWorld, fromWorld)
    setMatrix(.domeFromSky, fromWorld * (dome.fromWorld.inverse() * dome.fromSky))
    setVector(.domeColor, SIMD4(dome.color, 1))
    setVector(.domeSun, SIMD4((dome.sun?.irradiance ?? .zero) * dome.color, 0))
  }

  /// whether the environment is baked from the dome instead of the procedural sky.
  var bakesDome: Bool
  {
    dome != nil && environment.domeWeight >= 1 && atmosphere.planet == nil
  }

  /// the current dome color relative to the baked color, or 1 without a dome.
  var iblTint: SIMD3<Float>
  {
    guard bakesDome, let dome else { return SIMD3(repeating: 1) }
    return dome.color / pointwiseMax(environment.bakedDomeColor, SIMD3(repeating: 1e-6))
  }

  /// the ibl tint rounded to a sixteenth of a stop for the light probes
  var probeSkyTint: SIMD3<Float>
  {
    guard bakesDome, environment.domeColorBand.count == 3 else { return SIMD3(repeating: 1) }

    let banded = SIMD3(exp2(environment.domeColorBand[0] / 16), exp2(environment.domeColorBand[1] / 16),
                       exp2(environment.domeColorBand[2] / 16))
    return banded / pointwiseMax(environment.bakedDomeColor, SIMD3(repeating: 1e-6))
  }

  /// the passes an ibl bake runs, using the dome instead of the procedural sky when there is one.
  func setIBLPasses(active: Bool)
  {
    setPasses([.prefilter, .irradiance], active: active)
    runtime.setPassActive(.dfg, active: active && environment.dfgNeedsBake)

    // the environment bakes from the procedural sky while the dome is handing over to it.
    let bakesDome = dome != nil && environment.domeWeight >= 1
    runtime.setPassActive(.sky, active: active && !bakesDome && atmosphere.planet == nil)
    runtime.setPassActive(.dome, active: active && bakesDome && atmosphere.planet == nil)
    runtime.setPassActive(.atmosphereEnv, active: active && atmosphere.planet != nil)

    guard active, bakesDome, let dome else { return }

    // the bake draws the dome with the color of this frame.
    environment.bakedDomeColor = dome.color
    setVector(.iblTint, SIMD4(1, 1, 1, 1))

    gl.bindTexture(target: GL_TEXTURE_2D, texture: runtime.texture(.dome, named: .dome))
    gl.texSubImage2D(target: GL_TEXTURE_2D, level: 0, xOffset: 0, yOffset: 0,
                     width: GLsizei(dome.smallSize.x), height: GLsizei(dome.smallSize.y),
                     format: GL_RGBA, type: GLenum(GL_HALF_FLOAT), pixels: environment.distantSun == nil ? dome.small : dome.smallFull)
  }

  private func domeChanged()
  {
    environment.iblNeedsBake = true
    environment.revision += 1
  }

  private static let halfOne: UInt16 = 0x3C00

  private static func expand(_ m: simd_float3x3) -> simd_float4x4
  {
    simd_float4x4(columns: (SIMD4(m.columns.0, 0), SIMD4(m.columns.1, 0), SIMD4(m.columns.2, 0), SIMD4(0, 0, 0, 1)))
  }
}
