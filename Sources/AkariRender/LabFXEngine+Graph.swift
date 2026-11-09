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
import HydraKit
import LabFX
import LabGL

extension Akari.LabFXEngine
{
  /// The deferred graph's uniforms, and the ones LabGL's tonemap and IBL shaders declare.
  enum Uniform: String, CaseIterable
  {
    case agxLut = "u_agx_lut"
    case agxLutShaper = "u_agx_lut_shaper"
    case agxLutSize = "u_agx_lut_size"
    case aovProjection = "u_aovProjection"
    case atmosCamera = "u_atmosCamera"
    case atmosFrame = "u_atmosFrame"
    case atmosGround = "u_atmosGround"
    case atmosGroundMap = "u_atmosGroundMap"
    case atmosMie = "u_atmosMie"
    case atmosMieExtra = "u_atmosMieExtra"
    case atmosNightMap = "u_atmosNightMap"
    case atmosOzone = "u_atmosOzone"
    case atmosphere = "u_atmosphere"
    case atmosPlanetFromWorld = "u_atmosPlanetFromWorld"
    case atmosRayleigh = "u_atmosRayleigh"
    case atmosSun = "u_atmosSun"
    case bloom = "u_bloom"
    case bloomFilter = "u_bloomFilter"
    case bloomTint = "u_bloomTint"
    case colorAtlas = "u_color_atlas"
    case currViewProj = "u_currViewProj"
    case directionalRefOffset = "u_directionalRefOffset"
    case dof = "u_dof"
    case dofSampling = "u_dofSampling"
    case domeColor = "u_domeColor"
    case iblTint = "u_iblTint"
    case domeEnabled = "u_domeEnabled"
    case domeFromSky = "u_domeFromSky"
    case domeFromWorld = "u_domeFromWorld"
    case domeMap = "u_domeMap"
    case domeSun = "u_domeSun"
    case emissiveAtlas = "u_emissive_atlas"
    case exposure
    case eyeToLightRotation = "u_eyeToLightRotation"
    case eyeToWorld = "u_eyeToWorld"
    case fogDisturbers = "u_fogDisturbers"
    case fogSim = "u_fogSim"
    case fogSimMax = "u_fogSimMax"
    case fogSimMin = "u_fogSimMin"
    case fogSimVelocity = "u_fogSimVelocity"
    case fogSimVisibility = "u_fogSimVisibility"
    case frameIndex
    case froxelDepth = "u_froxelDepth"
    case froxelHistory = "u_froxelHistory"
    case gamma
    case halfScale = "u_halfScale"
    case horizonScan = "u_horizonScan"
    case iblEnabled = "u_iblEnabled"
    case invProj = "u_invProj"
    case materialAtlas = "u_material_atlas"
    case materialConstants = "u_materialConstants"
    case motionBlur = "u_motionBlur"
    case motionSize = "u_motionSize"
    case normalAtlas = "u_normal_atlas"
    case outline = "u_outline"
    case outlineColor = "u_outlineColor"
    case outlineLabels = "u_outlineLabels"
    case planet = "u_planet"
    case planetCity = "u_planetCity"
    case planetCloudMarchSteps = "u_planetCloudMarchSteps"
    case planetClouds = "u_planetClouds"
    case planetCloudShape = "u_planetCloudShape"
    case planetLook = "u_planetLook"
    case planetOcean = "u_planetOcean"
    case planetPaletteA = "u_planetPaletteA"
    case planetPaletteB = "u_planetPaletteB"
    case planetStyle = "u_planetStyle"
    case planetTerrain = "u_planetTerrain"
    case pointLightColorRadius0 = "u_pointLightColorRadius0"
    case pointLightColorRadius1 = "u_pointLightColorRadius1"
    case pointLightColorRadius2 = "u_pointLightColorRadius2"
    case pointLightColorRadius3 = "u_pointLightColorRadius3"
    case pointLightCount = "u_pointLightCount"
    case pointLightData = "u_pointLightData"
    case pointLightPosIntensity0 = "u_pointLightPosIntensity0"
    case pointLightPosIntensity1 = "u_pointLightPosIntensity1"
    case pointLightPosIntensity2 = "u_pointLightPosIntensity2"
    case pointLightPosIntensity3 = "u_pointLightPosIntensity3"
    case prevViewProj = "u_prevViewProj"
    case primStyle = "u_primStyle"
    case probeGridMax = "u_probeGridMax"
    case probeGridMin = "u_probeGridMin"
    case probeGridSize = "u_probeGridSize"
    case probeInfo = "u_probe_info"
    case probeSphere = "u_probe_sphere"
    case probeVolume = "u_probe_volume"
    case proj = "u_proj"
    case ptexAtlas = "u_ptexAtlas"
    case ptexHash = "u_ptexHash"
    case ptexParams = "u_ptexParams"
    case ptexTable = "u_ptexTable"
    case punctualShadowEnabled = "u_punctualShadowEnabled"
    case renderScale = "u_renderScale"
    case roughnessScale
    case shadowAtlas = "u_shadow_atlas"
    case shadowBias = "u_shadowBias"
    case shadowData = "u_shadow_data"
    case shadowedPointLightCount = "u_shadowedPointLightCount"
    case shadowEnabled = "u_shadowEnabled"
    case shadowLevelCount = "u_shadowLevelCount"
    case shadowLodRange = "u_shadowLodRange"
    case shadowPagetable = "u_shadow_pagetable"
    case ssgi = "u_ssgi"
    case ssgiSize = "u_ssgiSize"
    case ssr = "u_ssr"
    case sunDirection = "u_sunDirection"
    case sunHeight
    case sunOverride = "u_sunOverride"
    case supersampleScale = "u_supersampleScale"
    case taa = "u_taa"
    case taaJitter = "u_taaJitter"
    case transparency = "u_transparency"
    case viewGrid = "u_viewGrid"
    case viewShading = "u_viewShading"
    case volume = "u_volume"
    case volumeAlbedo = "u_volumeAlbedo"
    case volumeDensity = "u_volumeDensity"
    case volumeFlow = "u_volumeFlow"
    case volumeHistory = "u_volumeHistory"
    case volumeLayer = "u_volumeLayer"
    case volumeLook = "u_volumeLook"
    case volumeNoise = "u_volumeNoise"
    case volumeParams = "u_volumeParams"
    case volumePrevViewProj = "u_volumePrevViewProj"
    case volumeRange = "u_volumeRange"
    case volumeSun = "u_volumeSun"
    case volumeSunLevelBias = "u_volumeSunLevelBias"
    case volumeTextureFromWorld = "u_volumeTextureFromWorld"
    case volumeWorldFromTexture = "u_volumeWorldFromTexture"
    case water = "u_water"
    case waterBounds = "u_waterBounds"
    case waterColor = "u_waterColor"
    case waterInvView = "u_waterInvView"
    case waterView = "u_waterView"
    case waterWaves = "u_waterWaves"
    case zUp = "u_zUp"

    static let pointLightPosIntensity: [Uniform] = [.pointLightPosIntensity0, .pointLightPosIntensity1,
                                                    .pointLightPosIntensity2, .pointLightPosIntensity3]
    static let pointLightColorRadius: [Uniform] = [.pointLightColorRadius0, .pointLightColorRadius1,
                                                   .pointLightColorRadius2, .pointLightColorRadius3]
  }

  /// The deferred graph's passes, plus the IBL and DFG passes the runtime adds itself.
  enum Pass: String, CaseIterable
  {
    case atmosphereAerial = "atmosphere aerial"
    case atmosphereBackground = "atmosphere background"
    case atmosphereEnv = "atmosphere env"
    case atmosphereMultiscatter = "atmosphere multiscatter"
    case atmosphereSkyView = "atmosphere sky view"
    case atmosphereTransmittance = "atmosphere transmittance"
    case bloomComposite = "bloom composite"
    case bloomDown0 = "bloom down 0"
    case bloomDown1 = "bloom down 1"
    case bloomDown2 = "bloom down 2"
    case bloomDown3 = "bloom down 3"
    case bloomDown4 = "bloom down 4"
    case bloomDown5 = "bloom down 5"
    case bloomUp0 = "bloom up 0"
    case bloomUp1 = "bloom up 1"
    case bloomUp2 = "bloom up 2"
    case bloomUp3 = "bloom up 3"
    case bloomUp4 = "bloom up 4"
    case clearGbuffer = "clear gbuffer"
    case depthOfField = "depth of field"
    case depthOfFieldApply = "depth of field apply"
    case depthOfFieldDepth = "depth of field depth"
    case depthOfFieldDownsample = "depth of field downsample"
    case depthOfFieldHalf = "depth of field half"
    case depthOfFieldNeighbors = "depth of field neighbors"
    case depthOfFieldTiles = "depth of field tiles"
    case depthOfFieldTiles8 = "depth of field tiles 8"
    case dfg
    case dome
    case downsample
    case fogSimComposite = "fog sim composite"
    case fogSimMarch = "fog sim march"
    case geometry
    case geometryDynamic = "geometry dynamic"
    case geometryInstanced = "geometry instanced"
    case irradiance
    case lensGhosts = "lens ghosts"
    case lensStreak = "lens streak"
    case lensStreakLong = "lens streak long"
    case lensStreakWide = "lens streak wide"
    case motionBlur = "motion blur"
    case motionBlurApply = "motion blur apply"
    case motionBlurPre = "motion blur pre"
    case motionBlurPreApply = "motion blur pre apply"
    case motionNeighbors = "motion neighbors"
    case motionNeighborsPre = "motion neighbors pre"
    case motionTiles = "motion tiles"
    case motionTiles8 = "motion tiles 8"
    case motionTilesPre = "motion tiles pre"
    case motionTilesPre8 = "motion tiles pre 8"
    case outline
    case outlineEdge = "outline edge"
    case outlineMask = "outline mask"
    case outlineSpan = "outline span"
    case planetCloudMap = "planet cloud map"
    case prefilter
    case sky
    case ssgi
    case ssgiHistory = "ssgi history"
    case ssgiPrep = "ssgi prep"
    case ssgiPyramid = "ssgi pyramid"
    case ssgiTemporal = "ssgi temporal"
    case ssr
    case ssrHistory = "ssr history"
    case ssrTemporal = "ssr temporal"
    case taa
    case tonemap
    case transparent
    case transparentApply = "transparent apply"
    case transparentComposite = "transparent composite"
    case upscale
    case upscaleSanitize = "upscale sanitize"
    case upscaleSupersample = "upscale supersample"
    case volumeIntegrate = "volume integrate"
    case volumeMarch = "volume march"
    case volumeScatter = "volume scatter"
    case volumeShadow = "volume shadow"
  }

  /// The deferred graph's buffers.
  enum Buffer: String, CaseIterable
  {
    case aov
    case color
    case dofNeighbors
    case dofTiles
    case dofTiles8
    case dome
    case envCube
    case fogSimHalf
    case gbuffer
    case motionNeighbors
    case motionTiles
    case motionTiles8
    case outline
    case pointShadow
    case pointShadowBlur
    case pointShadowRaw
    case ssgi
    case ssgiAccum
    case ssgiHistory
    case ssgiPrep
    case ssgiPyramid
    case ssr
    case ssrAccum
    case ssrHistory
    case sunShadowAccum
    case sunShadowHistory
    case sunShadowRaw
    case supersample
    case taa
    case tonemap
    case transparentAccum
    case transparentResolved
    case upscaleInput
    case volumeIntegrated
    case volumeScatter
  }

  /// Textures inside the graph's buffers.
  enum Attachment: String, CaseIterable
  {
    case aovDepth
    case aovInstanceId
    case aovPrimId
    case dome
    case envCube
    case final
    case normal
    case outline
    case pointShadow0
    case pointShadow1
    case pointShadow2
    case pointShadow3
    case position
    case ptexA
    case ptexB
    case supersample
    case tonemap
    case upscaleColor
    case upscaleVelocity
    case volumeIntegrated
    case volumeScatter
  }

  /// Graph passes Swift draws itself.
  enum Callback: String, CaseIterable
  {
    case drawDynamicGeometry = "draw-dynamic-geometry"
    case drawOutlineMask = "draw-outline-mask"
    case drawStaticInstancedGeometry = "draw-static-instanced-geometry"
    case metalfxUpscale = "metalfx-upscale"
    case volumeIntegrate = "volume-integrate"
  }

  /// Graph shaders the engine hands geometry captures to.
  enum Shader: String, CaseIterable
  {
    case meshStatic = "mesh-static"
  }
}

extension lab.fx.Runtime
{
  mutating func setUniform(_ uniform: Akari.LabFXEngine.Uniform, type: GLenum, data: UnsafeRawPointer?)
  {
    setUniform(uniform.rawValue, type: type, data: data)
  }

  mutating func setUniform(_ uniform: Akari.LabFXEngine.Uniform, _ value: some UniformValue)
  {
    withUnsafeBytes(of: value)
    {
      setUniform(uniform, type: type(of: value).glType, data: $0.baseAddress)
    }
  }

  mutating func setPassActive(_ pass: Akari.LabFXEngine.Pass, active: Bool)
  {
    setPassActive(pass.rawValue, active: active)
  }

  mutating func renderPass(_ pass: Akari.LabFXEngine.Pass)
  {
    renderPass(pass.rawValue)
  }

  mutating func setPassTonemap(_ pass: Akari.LabFXEngine.Pass, tonemap: GLenum)
  {
    setPassTonemap(pass.rawValue, tonemap: tonemap)
  }

  mutating func setPassCallback(_ callback: Akari.LabFXEngine.Callback,
                                callback fn: (@convention(c) (UnsafeMutableRawPointer?, Int32, Int32) -> Void)?,
                                userdata: UnsafeMutableRawPointer?)
  {
    setPassCallback(callback.rawValue, callback: fn, userdata: userdata)
  }

  mutating func setMeshCapture(_ shader: Akari.LabFXEngine.Shader, buffer: OpaquePointer?)
  {
    setMeshCapture(shader.rawValue, buffer: buffer)
  }

  mutating func setMeshCaptureCulledSlot(_ shader: Akari.LabFXEngine.Shader, slot: Int32)
  {
    setMeshCaptureCulledSlot(shader.rawValue, slot: slot)
  }

  mutating func rebuildBuffer(_ buffer: Akari.LabFXEngine.Buffer)
  {
    rebuildBuffer(buffer.rawValue)
  }

  mutating func stageBufferSize(_ buffer: Akari.LabFXEngine.Buffer, width: Int32, height: Int32)
  {
    stageBufferSize(buffer.rawValue, width: width, height: height)
  }

  func texture(_ buffer: Akari.LabFXEngine.Buffer, named attachment: Akari.LabFXEngine.Attachment) -> GLuint
  {
    texture(buffer.rawValue, named: attachment.rawValue)
  }

  func writeTexture(_ buffer: Akari.LabFXEngine.Buffer, named attachment: Akari.LabFXEngine.Attachment) -> GLuint
  {
    writeTexture(buffer.rawValue, named: attachment.rawValue)
  }

  func bufferDepth(_ buffer: Akari.LabFXEngine.Buffer) -> GLuint
  {
    bufferDepth(buffer.rawValue)
  }
}
