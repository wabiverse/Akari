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
import HydraKit
import LabFX
import LabGL
import simd

extension Akari.LabFXEngine
{
  /// sets the deferred lighting state, the split sum ibl toggle, the inverse projection and the sky parameters
  public func setLighting(iblEnabled: Bool,
                          projection: Akari.Matrix4,
                          view: Akari.Matrix4,
                          light: LightSettings,
                          shadowsEnabled: Bool,
                          shading: ViewportShading = .rendered,
                          grid: Bool = false,
                          gridProjection: Akari.Matrix4? = nil)
  {
    setFloat(.iblEnabled, iblEnabled ? 1 : 0)
    setMatrix(.proj, projection)
    setMatrix(.invProj, projection.inverse())

    adoptAuthoredSun()

    // the stage dome and sun hand over to the procedural sunset and then the moon as sun height goes down
    let sunHeight = effectiveSunHeight(light)
    environment.domeWeight = authoredSunDirection == nil || !light.overridesStageSun ? 1 : Akari.Math.smoothstep(0.05, 0.3, sunHeight)
    setFloat(.sunHeight, sunHeight)

    // only the procedural sky, or a dome the sliders rotate, bakes from sun height
    if atmosphere.planet == nil, dome == nil || light.overridesStageSun { lastSunHeight = sunHeight }

    let sun = worldSpaceSunDirection(light)
    setVector(.sunDirection, SIMD4(sun.x, sun.y, sun.z, effectiveSunAngle(light) * 0.5))
    setVector(.sunOverride, environment.distantSun.map { SIMD4($0.irradiance, environment.domeWeight) } ?? .zero)

    applyAtmosphere(sun: sun)
    applyVolumes(sun: sun)
    applyTransparency(projection: projection, view: view)

    // the viewport traces caustics toward the gliding shadow sun so they move with the shadows, final renders use their own time's sun
    let causticSun = shadows.glidesSun ? shadowAtlas.sunMotion.smoothDirection : sun
    applyGlassShadow(sun: causticSun, sunAngle: effectiveSunAngle(light) * 0.5, castsShadows: shadowsEnabled && shadows.ready)

    setFloat(.shadowEnabled, shadowsEnabled && shadows.ready ? 1 : 0)
    setFloat(.zUp, stageIsZUp ? 1 : 0)
    applyDome(light)

    setFloat(.punctualShadowEnabled, shadowsEnabled && shadows.ready ? 1 : 0)
    setFloat(.pointLightCount, Float(pointLights.lit.count))
    setFloat(.shadowedPointLightCount, Float(pointLights.shadowed.count))

    for slot in 0 ..< 4
    {
      let light = slot < pointLights.lit.count ? pointLights.lit[slot] : nil
      setVector(Uniform.pointLightPosIntensity[slot],
                SIMD4(light?.position.x ?? 0,
                      light?.position.y ?? 0,
                      light?.position.z ?? 0,
                      light?.intensity ?? 0))
      setVector(Uniform.pointLightColorRadius[slot],
                SIMD4(light?.color.x ?? 0,
                      light?.color.y ?? 0,
                      light?.color.z ?? 0,
                      light?.radius ?? 1))
    }

    uploadPointLights()

    setVector(.viewShading, SIMD4(Float(3 - shading.rawValue), 0.05, 0, 0))
    setVector(.viewGrid, SIMD4(grid ? 1 : 0, 1 / max(stageMetersPerUnit, 1e-6), 0, 0))

    // the grid draws over the final image with the unjittered camera so its lines hold still
    setMatrix(.gridInvProj, (gridProjection ?? projection).inverse())
    runtime.setPassActive(.gridOverlay, active: grid)
    guard shading != .rendered else { return }

    runtime.setPassActive(.atmosphereBackground, active: false)
    if shading == .materialPreview
    {
      let key = view.simd.inverse * SIMD4(simd_normalize(SIMD3<Float>(-0.45, 0.65, 0.6)), 0)
      setVector(.sunDirection, SIMD4(key.x, key.y, key.z, light.sunAngle * 0.5))
      setVector(.sunOverride, SIMD4(2.5, 2.5, 2.5, 1))
      setFloat(.pointLightCount, 0)
    }
  }

  /// texels per light, six for every light then a glowing mesh's outline points
  static let pointLightTexels = 6 + Akari.Lux.PointLight.maxOutlinePoints

  /// uploads every lit point light for the lighting pass, a row of texels per light
  private func uploadPointLights()
  {
    if pointLights.texture == 0
    {
      gl.genTextures(count: 1, textures: &pointLights.texture)
      gl.bindTexture(target: GL_TEXTURE_2D, texture: pointLights.texture)
      gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_MIN_FILTER, param: GLint(GL_NEAREST))
      gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_MAG_FILTER, param: GLint(GL_NEAREST))
      gl.texImage2D(target: GL_TEXTURE_2D, level: 0, internalFormat: GL_RGBA32F,
                    width: GLsizei(Self.pointLightTexels), height: GLsizei(Self.maxPointLights), border: 0,
                    format: GL_RGBA, type: GL_FLOAT, pixels: nil)
    }

    guard pointLights.texture != 0 else { return }

    let texels: [Float] = pointLights.lit.enumerated().flatMap
    { slot, light in
      let shadowed = slot < pointLights.shadowed.count

      // a tube's half axis and radius, or a rect's half width and -1, -2 when an outline shades in its place, then a rect's half height
      let outline = light.outline.prefix(Akari.Lux.PointLight.maxOutlinePoints)
      let shape = light.halfWidth != .zero ? SIMD4(light.halfWidth, outline.isEmpty ? -1 : -2) : SIMD4(light.halfAxis, light.tubeRadius)
      let points: [Float] = outline.flatMap { [$0.x, $0.y, $0.z, 0] }
      let padding = [Float](repeating: 0, count: (Akari.Lux.PointLight.maxOutlinePoints - outline.count) * 4)
      let shapeTexels: [Float] = [shape.x, shape.y, shape.z, shape.w,
                                  light.halfHeight.x, light.halfHeight.y, light.halfHeight.z, light.moved,
                                  light.cameraVisible ? 1 : 0, Float(outline.count), light.twoSided ? 1 : 0, 0]

      let head: [Float] = [light.position.x, light.position.y, light.position.z, light.intensity,
                           light.color.x, light.color.y, light.color.z, light.radius,
                           light.diffuse, light.specular,
                           shadowed ? shadowAtlas.lodBias(slot: slot) : 0,
                           shadowed && shadowAtlas.mainSlots.contains(slot) ? 1 : 0]
      return head + shapeTexels + points + padding
    }

    if !texels.isEmpty
    {
      gl.bindTexture(target: GL_TEXTURE_2D, texture: pointLights.texture)
      gl.texSubImage2D(target: GL_TEXTURE_2D, level: 0, xOffset: 0, yOffset: 0,
                       width: GLsizei(Self.pointLightTexels), height: GLsizei(pointLights.lit.count),
                       format: GL_RGBA, type: GL_FLOAT, pixels: texels)
    }

    setSampler(.pointLightData, pointLights.texture)
    bindLTC()
  }

  /// the side of the ltc tables, a cell per roughness and view angle
  static let ltcSize = 64

  /// loads Tools/LTCFit's tables once and binds them, area lights fall back to the closest point highlight without them
  private func bindLTC()
  {
    if pointLights.ltc.matrix == 0
    {
      let n = Self.ltcSize
      guard
        let url = Bundle.akari.url(forResource: "LTC_GGX", withExtension: "bin"),
        let data = try? Data(contentsOf: url),
        data.count == n * n * 8 * MemoryLayout<Float>.size
      else { return }

      var names = [GLuint](repeating: 0, count: 2)
      gl.genTextures(count: 2, textures: &names)
      data.withUnsafeBytes
      { bytes in
        for (index, name) in names.enumerated()
        {
          gl.bindTexture(target: GL_TEXTURE_2D, texture: name)
          gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_MIN_FILTER, param: GLint(GL_LINEAR))
          gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_MAG_FILTER, param: GLint(GL_LINEAR))
          gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_WRAP_S, param: GLint(GL_CLAMP_TO_EDGE))
          gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_WRAP_T, param: GLint(GL_CLAMP_TO_EDGE))
          gl.texImage2D(target: GL_TEXTURE_2D, level: 0, internalFormat: GL_RGBA32F, width: GLsizei(n), height: GLsizei(n),
                        border: 0, format: GL_RGBA, type: GL_FLOAT, pixels: bytes.baseAddress! + index * n * n * 4 * MemoryLayout<Float>.size)
        }
      }

      pointLights.ltc = (names[0], names[1])
    }

    setSampler(.ltcMatrix, pointLights.ltc.matrix)
    setSampler(.ltcAmplitude, pointLights.ltc.amplitude)
  }
}
