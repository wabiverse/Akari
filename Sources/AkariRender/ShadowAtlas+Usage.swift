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
import LabGL

extension Akari.ShadowAtlas
{
  private static let lightPosRadiusNames = (0 ..< maxPunctualLights).map { "u_lightPosRadius\($0)" }

  /// Clears whether a tile is used everywhere and forces an
  /// update for any dirty cube face's allocated tiles.
  func dispatchBeginFrame(dirty: Int32)
  {
    gl.setComputeShaderBuffer(kernels.beginFrame, binding: 0, buffer: buffers.tiles)
    setUniform(kernels.beginFrame, "u_dirty", GL_INT, dirty)
    gl.dispatchCompute(kernels.beginFrame,
                       groupsX: GLuint((Self.maxTiles + 63) / 64),
                       groupsY: 1,
                       groupsZ: 1)
  }

  func dispatchTagUsageDirectional(gbufferPosition: GLuint,
                                   eyeToFitEye: Akari.Matrix4,
                                   screenWidth: Int,
                                   screenHeight: Int)
  {
    let kernel = kernels.tagUsageDirectional
    setUniform(kernel, "u_eyeToFitEye", eyeToFitEye)
    setUniform(kernel, "u_eyeToLightRotation", sun.eyeToLightRotation)
    setUniform(kernel, "u_directionalRefOffset", GL_FLOAT_VEC4,
               SIMD4<Float>(sun.refOffset.x,
                            sun.refOffset.y,
                            sun.refOffset.z,
                            sun.lodBias))
    setUniform(kernel, "u_params", GL_INT_VEC4,
               SIMD4<Int32>(Int32(screenWidth),
                            Int32(screenHeight),
                            Int32(directionalHistory.slots.count),
                            sun.isClipmap ? 1 : 0))
    setUniform(kernel, "u_lodRange", GL_INT_VEC4,
               SIMD4<Int32>(sun.lodMin,
                            sun.lodMax,
                            0,
                            0))

    gl.setComputeShaderSampler(kernel, index: 0, texture: gbufferPosition, samplerIndex: 0)
    gl.setComputeShaderSampler(kernel, index: 1, texture: data, samplerIndex: 0)
    gl.setComputeShaderBuffer(kernel, binding: 0, buffer: buffers.tiles)
    gl.dispatchCompute(kernel,
                       groupsX: GLuint((screenWidth + 7) / 8),
                       groupsY: GLuint((screenHeight + 7) / 8),
                       groupsZ: 1)

    gl.setComputeShaderBuffer(kernels.dilateUsageDirectional, binding: 0, buffer: buffers.tiles)
    gl.dispatchCompute(kernels.dilateUsageDirectional,
                       groupsX: GLuint(Self.maxDirectionalTilemaps),
                       groupsY: 1,
                       groupsZ: 1)
  }

  func dispatchTagUsagePunctual(gbufferPosition: GLuint,
                                invView: Akari.Matrix4,
                                screenWidth: Int,
                                screenHeight: Int,
                                camera: Akari.Camera,
                                lights: [Akari.Lux.PointLight],
                                lightCount: Int)
  {
    let kernel = kernels.tagUsagePunctual
    setUniform(kernel, "u_invView", invView)
    setLightPositions(kernel, lights: lights, lightCount: lightCount)
    let filmPixelRadius: Float = camera.projection[1, 1] > 1e-6
      ? 2 / (camera.projection[1, 1] * Float(screenHeight))
      : 0
    setUniform(kernel, "u_params", GL_FLOAT_VEC4,
               SIMD4<Float>(filmPixelRadius,
                            Float(screenWidth),
                            Float(screenHeight),
                            Float(lightCount)))

    gl.setComputeShaderSampler(kernel, index: 0, texture: gbufferPosition, samplerIndex: 0)
    gl.setComputeShaderBuffer(kernel, binding: 0, buffer: buffers.tiles)
    gl.dispatchCompute(kernel,
                       groupsX: GLuint((screenWidth + 7) / 8),
                       groupsY: GLuint((screenHeight + 7) / 8),
                       groupsZ: 1)

    gl.setComputeShaderBuffer(kernels.dilateUsagePunctual, binding: 0, buffer: buffers.tiles)
    gl.dispatchCompute(kernels.dilateUsagePunctual,
                       groupsX: GLuint(lightCount * Self.facesPerLight),
                       groupsY: 1,
                       groupsZ: 1)
  }

  /// Sets whether the volume froxels should sample a page.
  func dispatchTagUsageVolume(_ volume: VolumeFroxels,
                              invView: Akari.Matrix4,
                              camera: Akari.Camera,
                              lights: [Akari.Lux.PointLight],
                              lightCount: Int)
  {
    let kernel = kernels.tagUsageVolume
    guard
      kernel != 0,
      volume.depthTexture != 0,
      volume.gridWidth > 0,
      volume.gridHeight > 0,
      volume.far > volume.near
    else { return }

    setUniform(kernel, "u_invView", invView)
    setUniform(kernel, "u_eyeToFitEye", directionalHistory.view * invView)
    setUniform(kernel, "u_eyeToLightRotation", sun.eyeToLightRotation)
    setUniform(kernel, "u_invProj", volume.inverseProjection)
    setUniform(kernel, "u_directionalRefOffset", GL_FLOAT_VEC4,
               SIMD4<Float>(sun.refOffset.x,
                            sun.refOffset.y,
                            sun.refOffset.z,
                            sun.lodBias))
    setLightPositions(kernel, lights: lights, lightCount: lightCount)
    setUniform(kernel, "u_volume", GL_FLOAT_VEC4,
               SIMD4<Float>(volume.near,
                            volume.far,
                            Float(volume.gridWidth),
                            Float(volume.gridHeight)))
    let froxelPixelRadius: Float = camera.projection[1, 1] > 1e-6
      ? 2 / (camera.projection[1, 1] * Float(volume.gridHeight))
      : 0
    setUniform(kernel, "u_params", GL_FLOAT_VEC4,
               SIMD4<Float>(froxelPixelRadius,
                            Float(lightCount),
                            Float(directionalHistory.slots.count),
                            sun.isClipmap ? 1 : 0))
    setUniform(kernel, "u_lodRange", GL_FLOAT_VEC4,
               SIMD4<Float>(Float(sun.lodMin),
                            Float(sun.lodMax),
                            Float(max(volume.sunLevelBias, 0)),
                            0))

    gl.setComputeShaderSampler(kernel, index: 0, texture: volume.depthTexture, samplerIndex: 0)
    gl.setComputeShaderSampler(kernel, index: 1, texture: data, samplerIndex: 0)
    gl.setComputeShaderBuffer(kernel, binding: 0, buffer: buffers.tiles)
    gl.dispatchCompute(kernel,
                       groupsX: GLuint(volume.gridWidth),
                       groupsY: GLuint(volume.gridHeight),
                       groupsZ: 1)
  }

  /// Masks LODs covered by finer ones, then frees, defrags and allocates pages.
  func dispatchPageAllocation()
  {
    gl.setComputeShaderBuffer(kernels.maskLod, binding: 0, buffer: buffers.tiles)
    setUniform(kernels.maskLod, "u_max_view_per_tilemap", GL_INT, Int32(Self.lodCount))
    gl.dispatchCompute(kernels.maskLod,
                       groupsX: GLuint(Self.maxPunctualTilemaps),
                       groupsY: 1,
                       groupsZ: 1)

    for (kernel, groups) in [(kernels.free, Self.maxTilemaps), (kernels.defrag, 1), (kernels.allocate, Self.maxTilemaps)]
    {
      gl.setComputeShaderBuffer(kernel, binding: 0, buffer: buffers.tiles)
      gl.setComputeShaderBuffer(kernel, binding: 1, buffer: buffers.pagesFree)
      gl.setComputeShaderBuffer(kernel, binding: 2, buffer: buffers.pagesInfo)
      gl.setComputeShaderBuffer(kernel, binding: 3, buffer: buffers.pagesCached)
      gl.dispatchCompute(kernel,
                         groupsX: GLuint(groups),
                         groupsY: 1,
                         groupsZ: 1)
    }
  }

  func setUniform(_ kernel: GLuint, _ name: String, _ type: GLenum, _ value: some BitwiseCopyable)
  {
    withUnsafeBytes(of: value)
    { bytes in
      gl.setComputeShaderUniform(kernel, name: name, type: type, data: bytes.baseAddress)
    }
  }

  func setUniform(_ kernel: GLuint, _ name: String, _ matrix: Akari.Matrix4)
  {
    matrix.withUnsafeFloats
    { buf in
      gl.setComputeShaderUniform(kernel, name: name, type: GL_FLOAT_MAT4, data: buf.baseAddress)
    }
  }

  private func setLightPositions(_ kernel: GLuint, lights: [Akari.Lux.PointLight], lightCount: Int)
  {
    for slot in 0 ..< Self.maxPunctualLights
    {
      let posRadius = slot < lightCount
        ? SIMD4(lights[slot].position.x,
                lights[slot].position.y,
                lights[slot].position.z,
                lights[slot].radius)
        : SIMD4<Float>(repeating: 0)
      setUniform(kernel, Self.lightPosRadiusNames[slot], GL_FLOAT_VEC4, posRadius)
    }
  }
}
