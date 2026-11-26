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

extension Akari.RenderGraph
{
  /// uniforms the deferred graph's shaders declare, each typed once for every shader that reads it.
  enum Uniforms
  {
    static let aovProjection = Uniform<SIMD4<Float>>("u_aovProjection")
    static let atmosCamera = Uniform<SIMD4<Float>>("u_atmosCamera")
    static let atmosFrame = Uniform<SIMD4<Float>>("u_atmosFrame")
    static let atmosGround = Uniform<SIMD4<Float>>("u_atmosGround")
    static let atmosMie = Uniform<SIMD4<Float>>("u_atmosMie")
    static let atmosMieExtra = Uniform<SIMD4<Float>>("u_atmosMieExtra")
    static let atmosOzone = Uniform<SIMD4<Float>>("u_atmosOzone")
    static let atmosphere = Uniform<SIMD4<Float>>("u_atmosphere")
    static let atmosPlanetFromWorld = Uniform<Akari.Matrix4>("u_atmosPlanetFromWorld")
    static let atmosRayleigh = Uniform<SIMD4<Float>>("u_atmosRayleigh")
    static let atmosSun = Uniform<SIMD4<Float>>("u_atmosSun")
    static let bloom = Uniform<SIMD4<Float>>("u_bloom")
    static let bloomFilter = Uniform<SIMD4<Float>>("u_bloomFilter")
    static let bloomTint = Uniform<SIMD4<Float>>("u_bloomTint")
    static let currViewProj = Uniform<Akari.Matrix4>("u_currViewProj")
    static let directionalRefOffset = Uniform<SIMD4<Float>>("u_directionalRefOffset")
    static let dof = Uniform<SIMD4<Float>>("u_dof")
    static let dofSampling = Uniform<SIMD4<Float>>("u_dofSampling")
    static let domeColor = Uniform<SIMD4<Float>>("u_domeColor")
    static let domeEnabled = Uniform<Float>("u_domeEnabled")
    static let domeFromSky = Uniform<Akari.Matrix4>("u_domeFromSky")
    static let domeFromWorld = Uniform<Akari.Matrix4>("u_domeFromWorld")
    static let domeSun = Uniform<SIMD4<Float>>("u_domeSun")
    static let eyeToLightRotation = Uniform<Akari.Matrix4>("u_eyeToLightRotation")
    static let eyeToWorld = Uniform<Akari.Matrix4>("u_eyeToWorld")
    static let fogSimMax = Uniform<SIMD4<Float>>("u_fogSimMax")
    static let fogSimMin = Uniform<SIMD4<Float>>("u_fogSimMin")
    static let frameIndex = Uniform<Int32>("frameIndex")
    /// whether the sun has glass maps this frame in x, whether any local light does in y, and whether there is glass to see through in z.
    static let glass = Uniform<SIMD4<Float>>("u_glass")
    static let gridInvProj = Uniform<Akari.Matrix4>("u_gridInvProj")
    static let halfScale = Uniform<SIMD4<Float>>("u_halfScale")
    static let horizonScan = Uniform<SIMD4<Float>>("u_horizonScan")
    static let iblEnabled = Uniform<Float>("u_iblEnabled")
    static let iblTint = Uniform<SIMD4<Float>>("u_iblTint")
    static let invProj = Uniform<Akari.Matrix4>("u_invProj")
    static let motionBlur = Uniform<SIMD4<Float>>("u_motionBlur")
    static let motionSize = Uniform<SIMD4<Float>>("u_motionSize")
    static let outline = Uniform<SIMD4<Float>>("u_outline")
    static let outlineColor = Uniform<SIMD4<Float>>("u_outlineColor")
    static let planet = Uniform<SIMD4<Float>>("u_planet")
    static let planetCity = Uniform<SIMD4<Float>>("u_planetCity")
    static let planetCloudMarchSteps = Uniform<Float>("u_planetCloudMarchSteps")
    static let planetClouds = Uniform<SIMD4<Float>>("u_planetClouds")
    static let planetCloudShape = Uniform<SIMD4<Float>>("u_planetCloudShape")
    static let planetLook = Uniform<Akari.Matrix4>("u_planetLook")
    static let planetOcean = Uniform<SIMD4<Float>>("u_planetOcean")
    static let planetPaletteA = Uniform<Akari.Matrix4>("u_planetPaletteA")
    static let planetPaletteB = Uniform<Akari.Matrix4>("u_planetPaletteB")
    static let planetStyle = Uniform<SIMD4<Float>>("u_planetStyle")
    static let planetTerrain = Uniform<SIMD4<Float>>("u_planetTerrain")
    static let pointLightColorRadius0 = Uniform<SIMD4<Float>>("u_pointLightColorRadius0")
    static let pointLightColorRadius1 = Uniform<SIMD4<Float>>("u_pointLightColorRadius1")
    static let pointLightColorRadius2 = Uniform<SIMD4<Float>>("u_pointLightColorRadius2")
    static let pointLightColorRadius3 = Uniform<SIMD4<Float>>("u_pointLightColorRadius3")
    static let pointLightCount = Uniform<Float>("u_pointLightCount")
    static let pointLightPosIntensity0 = Uniform<SIMD4<Float>>("u_pointLightPosIntensity0")
    static let pointLightPosIntensity1 = Uniform<SIMD4<Float>>("u_pointLightPosIntensity1")
    static let pointLightPosIntensity2 = Uniform<SIMD4<Float>>("u_pointLightPosIntensity2")
    static let pointLightPosIntensity3 = Uniform<SIMD4<Float>>("u_pointLightPosIntensity3")
    static let prevViewProj = Uniform<Akari.Matrix4>("u_prevViewProj")
    static let probeGridMax = Uniform<SIMD4<Float>>("u_probeGridMax")
    static let probeGridMin = Uniform<SIMD4<Float>>("u_probeGridMin")
    static let probeGridSize = Uniform<SIMD4<Float>>("u_probeGridSize")
    static let proj = Uniform<Akari.Matrix4>("u_proj")
    static let ptexParams = Uniform<SIMD4<Int32>>("u_ptexParams")
    static let punctualShadowEnabled = Uniform<Float>("u_punctualShadowEnabled")
    static let renderScale = Uniform<SIMD4<Float>>("u_renderScale")
    static let shadowBias = Uniform<SIMD4<Float>>("u_shadowBias")
    static let shadowedPointLightCount = Uniform<Float>("u_shadowedPointLightCount")
    static let shadowEnabled = Uniform<Float>("u_shadowEnabled")
    static let shadowLevelCount = Uniform<Float>("u_shadowLevelCount")
    static let shadowLodRange = Uniform<SIMD4<Float>>("u_shadowLodRange")
    static let ssgi = Uniform<SIMD4<Float>>("u_ssgi")
    static let ssgiSize = Uniform<SIMD4<Float>>("u_ssgiSize")
    static let ssr = Uniform<SIMD4<Float>>("u_ssr")
    static let sunDirection = Uniform<SIMD4<Float>>("u_sunDirection")
    static let sunAzimuth = Uniform<Float>("sunAzimuth")
    static let sunHeight = Uniform<Float>("sunHeight")
    static let sunOverride = Uniform<SIMD4<Float>>("u_sunOverride")
    static let supersampleScale = Uniform<SIMD4<Float>>("u_supersampleScale")
    static let taa = Uniform<SIMD4<Float>>("u_taa")
    static let taaJitter = Uniform<SIMD4<Float>>("u_taaJitter")
    static let transparency = Uniform<SIMD4<Float>>("u_transparency")
    static let view = Uniform<Akari.Matrix4>("u_view", auto: .viewMatrix)
    static let viewGrid = Uniform<SIMD4<Float>>("u_viewGrid")
    static let viewShading = Uniform<SIMD4<Float>>("u_viewShading")
    static let volume = Uniform<SIMD4<Float>>("u_volume")
    static let volumeAlbedo = Uniform<SIMD4<Float>>("u_volumeAlbedo")
    static let volumeFlow = Uniform<SIMD4<Float>>("u_volumeFlow")
    static let volumeHistory = Uniform<Float>("u_volumeHistory")
    static let volumeLayer = Uniform<SIMD4<Float>>("u_volumeLayer")
    static let volumeLook = Uniform<SIMD4<Float>>("u_volumeLook")
    static let volumeNoise = Uniform<SIMD4<Float>>("u_volumeNoise")
    static let volumeParams = Uniform<SIMD4<Float>>("u_volumeParams")
    static let volumePrevViewProj = Uniform<Akari.Matrix4>("u_volumePrevViewProj")
    static let volumeRange = Uniform<SIMD4<Float>>("u_volumeRange")
    static let volumeSun = Uniform<SIMD4<Float>>("u_volumeSun")
    static let volumeSunLevelBias = Uniform<Float>("u_volumeSunLevelBias")
    static let volumeTextureFromWorld = Uniform<Akari.Matrix4>("u_volumeTextureFromWorld")
    static let volumeWorldFromTexture = Uniform<Akari.Matrix4>("u_volumeWorldFromTexture")
    static let water = Uniform<SIMD4<Float>>("u_water")
    static let waterBounds = Uniform<SIMD4<Float>>("u_waterBounds")
    static let waterColor = Uniform<SIMD4<Float>>("u_waterColor")
    static let waterInvView = Uniform<Akari.Matrix4>("u_waterInvView")
    static let waterView = Uniform<Akari.Matrix4>("u_waterView")
    static let waterWaves = Uniform<SIMD4<Float>>("u_waterWaves")
    static let zUp = Uniform<Float>("u_zUp")
  }

  /// samplers that read textures the engine binds itself rather than graph buffers.
  enum Samplers
  {
    static let atmosGroundMap = Sampler("u_atmosGroundMap", .sampler2D)
    static let atmosNightMap = Sampler("u_atmosNightMap", .sampler2D)
    static let colorAtlas = Sampler("u_color_atlas", .sampler2D)
    static let domeMap = Sampler("u_domeMap", .sampler2D)
    static let emissiveAtlas = Sampler("u_emissive_atlas", .sampler2D)
    static let fogDisturbers = Sampler("u_fogDisturbers", .sampler2D)
    static let fogSim = Sampler("u_fogSim", .sampler3D)
    static let fogSimVelocity = Sampler("u_fogSimVelocity", .sampler3D)
    static let fogSimVisibility = Sampler("u_fogSimVisibility", .sampler3D)
    static let froxelDepth = Sampler("u_froxelDepth", .sampler2D)
    static let froxelHistory = Sampler("u_froxelHistory", .sampler2D)
    static let glassLights = Sampler("u_glassLights", .sampler2D)
    static let materialAtlas = Sampler("u_material_atlas", .sampler2D)
    static let materialConstants = Sampler("u_materialConstants", .sampler2D)
    static let normalAtlas = Sampler("u_normal_atlas", .sampler2D)
    static let outlineLabels = Sampler("u_outlineLabels", .sampler2D)
    static let pointLightData = Sampler("u_pointLightData", .sampler2D)
    static let ltcMatrix = Sampler("u_ltcMatrix", .sampler2D)
    static let ltcAmplitude = Sampler("u_ltcAmplitude", .sampler2D)
    static let primStyle = Sampler("u_primStyle", .sampler2D)
    static let probeInfo = Sampler("u_probe_info", .sampler2D)
    static let probeSphere = Sampler("u_probe_sphere", .sampler2D)
    static let probeVolume = Sampler("u_probe_volume", .sampler2D)
    static let ptexAtlas = Sampler("u_ptexAtlas", .usampler2DArray)
    static let ptexHash = Sampler("u_ptexHash", .usampler2DArray)
    static let ptexTable = Sampler("u_ptexTable", .usampler2DArray)
    static let shadowAtlas = Sampler("u_shadow_atlas", .usampler2DArray)
    static let shadowData = Sampler("u_shadow_data", .sampler2D)
    static let shadowPagetable = Sampler("u_shadow_pagetable", .sampler2D)
    static let volumeDensity = Sampler("u_volumeDensity", .sampler3D)
  }
}
