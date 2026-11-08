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
import HdAkari
import LabFX
import LabGL

extension Akari.LabFXEngine
{
  struct Volumetrics
  {
    var stage: Pixar.HdAkariStageVolume?
    /// The fog disturbers this frame, eight floats each (see `HdAkariFogDisturbersAt`).
    var disturbers: [Float] = []
    var disturberTexture: GLuint = 0
    var emptySim: GLuint = 0
    var simRequest: (() -> Void)?
    var simPassActive = true
    var thisFrame = false
    var passesActive = true
    /// This frame's froxel grid, for the shadow pass volume usage tagging.
    var froxels: Akari.ShadowAtlas.VolumeFroxels?
    /// The `u_volume` / `u_volumeRange` this frame wants, and what the graph last received.
    var pending = SIMD4<Float>(repeating: 0)
    var pendingRange = SIMD4<Float>(repeating: 0)
    var uploaded = SIMD4<Float>(repeating: .nan)
    var uploadedRange = SIMD4<Float>(repeating: .nan)
    var pendingSunLevelBias: Float = 0
    var uploadedSunLevelBias: Float = .nan
    var boundFroxelDepth: GLuint = 0
    /// Read by the `volume-integrate` callback.
    var grid = SIMD2<Int>(0, 0)
    var scatterTexture: GLuint = 0
    var integratedTexture: GLuint = 0
    /// This frame's view projection, and last frame's while its scatter is still valid history.
    var viewProjection = Akari.Matrix4.identity
    var previousViewProjection: Akari.Matrix4?
  }

  private static let volumePassNames: [Pass] = [
    .volumeScatter,
    .volumeIntegrate
  ]

  /// The froxel grid is 8x8 depth slices packed into the half resolution volume atlas.
  private static let volumeSliceColumns = 8
  private static let volumeAtlasScale = 2

  /// Turns on froxel volumetrics for this frame.
  public func setVolumetrics(camera: Akari.Camera, volume settings: VolumeSettings)
  {
    volumetrics.simRequest?()
    var volume = settings
    if let stage = usdVolume
    {
      if stage.hasDensity { volume.density = Float(stage.density) }
      if stage.hasAnisotropy { volume.anisotropy = Float(stage.anisotropy) }
      if stage.hasMaxDistance { volume.maxDistance = Float(stage.maxDistance) }
    }

    guard camera.projection[2, 3] < -0.5 else { return }
    let a = camera.projection[2, 2]
    let b = camera.projection[3, 2]

    let clipNear = abs(b / (a - 1))
    let clipFar = abs(a + 1) > 1e-7 ? abs(b / (a + 1)) : .infinity
    let reach = camera.world(meters: volume.maxDistance)
    let far = clipFar.isFinite ? min(clipFar, reach) : reach
    guard clipNear.isFinite, far.isFinite, far > clipNear else { return }

    let tileDivisor = Self.volumeAtlasScale * Self.volumeSliceColumns
    let grid = SIMD2<Float>(Float(max(sizes.half.width * 2 / tileDivisor, 1)),
                            Float(max(sizes.half.height * 2 / tileDivisor, 1)))

    let unitsPerMeter = camera.world(meters: 1)
    let density = max(volume.density, 0) / unitsPerMeter
    let haze = Float(max(usdVolume?.hazeDensity ?? 0, 0)) / unitsPerMeter
    guard density > 0 || haze > 0 else { return }
    applyFogShape(unitsPerMeter: unitsPerMeter, haze: haze)

    let gridSize = SIMD2<Int>(Int(grid.x), Int(grid.y))
    let gbufferPosition = runtime.texture(.gbuffer, named: .position)
    guard froxelVolume.reduceDepth(gbufferPosition: gbufferPosition,
                                   gridWidth: gridSize.x,
                                   gridHeight: gridSize.y,
                                   screenWidth: sizes.render.width,
                                   screenHeight: sizes.render.height)
    else { return }
    if froxelVolume.depthTexture != volumetrics.boundFroxelDepth
    {
      volumetrics.boundFroxelDepth = froxelVolume.depthTexture
      setSampler(.froxelDepth, volumetrics.boundFroxelDepth)
    }

    let sunLevelBias = max(volume.sunShadowLevelBias, 0)

    volumetrics.pending = SIMD4(density,
                                min(max(volume.anisotropy, -0.95), 0.95),
                                1,
                                volume.shadows ? 1 : 0)
    volumetrics.pendingRange = SIMD4(clipNear, far, grid.x, grid.y)
    volumetrics.pendingSunLevelBias = Float(sunLevelBias)
    volumetrics.grid = gridSize
    volumetrics.viewProjection = camera.projection * camera.view
    volumetrics.thisFrame = true
    volumetrics.froxels = Akari.ShadowAtlas.VolumeFroxels(gridWidth: gridSize.x,
                                                          gridHeight: gridSize.y,
                                                          near: clipNear,
                                                          far: far,
                                                          inverseProjection: camera.projection.inverse(),
                                                          depthTexture: froxelVolume.depthTexture,
                                                          sunLevelBias: sunLevelBias)
  }

  /// The fog's noise, flow, ground layer and disturbers for the scatter pass, all in world units.
  private func applyFogShape(unitsPerMeter: Float, haze: Float)
  {
    let stage = usdVolume
    let amount = Float(min(max(stage?.noiseAmount ?? 0, 0), 1))
    let scale = Float(max(stage?.noiseScale ?? 1.5, 0.01)) * unitsPerMeter
    let octaves = Float(min(max(stage?.noiseOctaves ?? 4, 1), 6))
    let swirl = Float(min(max(stage?.swirl ?? 0, 0), 1))
    let wind = SIMD3(Float(stage?.windX ?? 0), Float(stage?.windY ?? 0), Float(stage?.windZ ?? 0)) * unitsPerMeter
    let falloff = Float(max(stage?.heightFalloff ?? 0, 0)) * unitsPerMeter
    let count = min(volumetrics.disturbers.count / 8, Self.maxFogDisturbers)
    setVector(.volumeNoise, SIMD4(amount, scale, octaves, swirl))
    setVector(.volumeFlow, SIMD4(wind, Float(stage?.seconds ?? 0)))
    setVector(.volumeLayer, SIMD4(Float(stage?.floorHeight ?? 0), falloff, haze, Float(count)))
    setVector(.volumeLook, SIMD4(Float(max(stage?.ambient ?? 1, 0)), Float(max(stage?.sunScatter ?? 1, 0)), 0, 0))
    fogSim.computeVisibility(lights: Array(pointLights.lit.prefix(4)))

    if volumetrics.disturberTexture == 0
    {
      gl.genTextures(count: 1, textures: &volumetrics.disturberTexture)
      gl.bindTexture(target: GL_TEXTURE_2D, texture: volumetrics.disturberTexture)
      gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_MIN_FILTER, param: GLint(GL_NEAREST))
      gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_MAG_FILTER, param: GLint(GL_NEAREST))
      gl.texImage2D(target: GL_TEXTURE_2D, level: 0, internalFormat: GL_RGBA32F,
                    width: 2, height: GLsizei(Self.maxFogDisturbers), border: 0,
                    format: GL_RGBA, type: GL_FLOAT, pixels: nil)
    }

    if count > 0
    {
      var texels = Array(volumetrics.disturbers.prefix(count * 8))
      // radii arrive in meters.
      for i in 0 ..< count
      {
        texels[i * 8 + 3] *= unitsPerMeter
      }

      gl.bindTexture(target: GL_TEXTURE_2D, texture: volumetrics.disturberTexture)
      gl.texSubImage2D(target: GL_TEXTURE_2D, level: 0, xOffset: 0, yOffset: 0, width: 2, height: GLsizei(count),
                       format: GL_RGBA, type: GL_FLOAT, pixels: texels)
    }

    setSampler(.fogDisturbers, volumetrics.disturberTexture)

    var simTexture = fogSim.isActive ? fogSim.texture : 0
    if simTexture == 0
    {
      if volumetrics.emptySim == 0
      {
        gl.genTextures(count: 1, textures: &volumetrics.emptySim)
        gl.bindTexture(target: GLenum(GL_TEXTURE_3D), texture: volumetrics.emptySim)
        gl.texImage3D(target: GLenum(GL_TEXTURE_3D), level: 0, internalFormat: GLint(GL_R16F),
                      width: 1, height: 1, depth: 1, border: 0, format: GLenum(GL_RED), type: GLenum(GL_HALF_FLOAT),
                      pixels: [UInt16(0)])
      }

      simTexture = volumetrics.emptySim
    }

    runtime.setUniform(.fogSim, type: GLenum(GL_SAMPLER_3D), data: &simTexture)
    var simVelocity = fogSim.isActive && fogSim.velocityTexture != 0 ? fogSim.velocityTexture : volumetrics.emptySim
    runtime.setUniform(.fogSimVelocity, type: GLenum(GL_SAMPLER_3D), data: &simVelocity)
    var simVisibility = fogSim.isActive && fogSim.visibilityTexture != 0 ? fogSim.visibilityTexture : volumetrics.emptySim
    runtime.setUniform(.fogSimVisibility, type: GLenum(GL_SAMPLER_3D), data: &simVisibility)
    setVector(.fogSimMin, SIMD4(fogSim.boundsMin, fogSim.isActive ? 1 : 0))
    setVector(.fogSimMax, SIMD4(fogSim.boundsMax, fogSim.densityCellSize))
    if fogSim.isActive != volumetrics.simPassActive
    {
      runtime.setPassActive(.fogSimMarch, active: fogSim.isActive)
      runtime.setPassActive(.fogSimComposite, active: fogSim.isActive)
      volumetrics.simPassActive = fogSim.isActive
    }
  }

  static let maxFogDisturbers = 8

  /// Brings the fog simulation to this frame, run inside the next render once the GPU is up.
  public var fogSimRequest: (() -> Void)?
  {
    get { volumetrics.simRequest }
    set { volumetrics.simRequest = newValue }
  }

  /// The fog disturbers the stage authors this frame, eight floats each.
  public var usdFogDisturbers: [Float]
  {
    get { volumetrics.disturbers }
    set { volumetrics.disturbers = newValue }
  }

  /// The fog the stage's `/World/RenderSettings` authors this frame, over the render settings own.
  public var usdVolume: Pixar.HdAkariStageVolume?
  {
    get { volumetrics.stage }
    set { volumetrics.stage = newValue }
  }

  func attachVolumetrics()
  {
    runtime.setPassCallback(.volumeIntegrate, callback: akariVolumeIntegrateCallback,
                            userdata: Unmanaged.passUnretained(self).toOpaque())
  }

  /// Pushes this frame's volume state into the graph before it renders.
  func syncVolumetrics()
  {
    let thisFrame = volumetrics.thisFrame
    if thisFrame != volumetrics.passesActive
    {
      setPasses(Self.volumePassNames, active: thisFrame)
      volumetrics.passesActive = thisFrame
      volumetrics.previousViewProjection = nil
    }

    let volume = thisFrame ? volumetrics.pending : .zero
    if volume != volumetrics.uploaded
    {
      setVector(.volume, volume)
      volumetrics.uploaded = volume
    }

    if thisFrame
    {
      if volumetrics.pendingRange != volumetrics.uploadedRange
      {
        setVector(.volumeRange, volumetrics.pendingRange)
        volumetrics.uploadedRange = volumetrics.pendingRange
      }

      if volumetrics.pendingSunLevelBias != volumetrics.uploadedSunLevelBias
      {
        setFloat(.volumeSunLevelBias, volumetrics.pendingSunLevelBias)
        volumetrics.uploadedSunLevelBias = volumetrics.pendingSunLevelBias
      }

      let previous = froxelVolume.hasHistory ? volumetrics.previousViewProjection : nil
      setSampler(.froxelHistory, froxelVolume.historyTexture)
      setMatrix(.volumePrevViewProj, previous ?? volumetrics.viewProjection)
      setFloat(.volumeHistory, previous == nil ? 0 : 1)
      volumetrics.previousViewProjection = volumetrics.viewProjection
      volumetrics.scatterTexture = runtime.texture(.volumeScatter, named: .volumeScatter)
      volumetrics.integratedTexture = runtime.texture(.volumeIntegrated, named: .volumeIntegrated)
    }
  }

  fileprivate func integrateVolume()
  {
    froxelVolume.integrate(scatter: volumetrics.scatterTexture,
                           integrated: volumetrics.integratedTexture,
                           gridWidth: volumetrics.grid.x,
                           gridHeight: volumetrics.grid.y)
  }
}

private func akariVolumeIntegrateCallback(_ userdata: UnsafeMutableRawPointer?, _: Int32, _: Int32)
{
  guard let userdata else { return }
  Unmanaged<Akari.LabFXEngine>.fromOpaque(userdata).takeUnretainedValue().integrateVolume()
}
