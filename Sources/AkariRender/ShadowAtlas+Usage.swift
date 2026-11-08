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
  /// Clears whether a tile is used everywhere and forces an
  /// update for any dirty cube face's allocated tiles.
  func dispatchBeginFrame(dirty: Int32)
  {
    kernels[.beginFrame].bind(buffers[.tiles])
    kernels[.beginFrame].set(.dirty, dirty)
    kernels[.beginFrame].dispatch((Self.maxTiles + 63) / 64)
  }

  func dispatchTagUsageDirectional(gbufferPosition: GLuint,
                                   eyeToFitEye: Akari.Matrix4,
                                   screenWidth: Int,
                                   screenHeight: Int)
  {
    let kernel = kernels[.tagUsageDirectional]
    kernel.set(.eyeToFitEye, eyeToFitEye)
    kernel.set(.eyeToLightRotation, sun.eyeToLightRotation)
    kernel.set(.directionalRefOffset, SIMD4<Float>(sun.refOffset.x, sun.refOffset.y, sun.refOffset.z, sun.lodBias))
    kernel.set(.params, SIMD4<Int32>(Int32(screenWidth), Int32(screenHeight), Int32(directionalHistory.slots.count), sun.isClipmap ? 1 : 0))
    kernel.set(.lodRange, SIMD4<Int32>(sun.lodMin, sun.lodMax, 0, 0))

    kernel.sample(gbufferPosition, at: 0)
    kernel.sample(data, at: 1)
    kernel.bind(buffers[.tiles])
    kernel.dispatch((screenWidth + 7) / 8, (screenHeight + 7) / 8)

    kernels[.dilateUsageDirectional].bind(buffers[.tiles])
    kernels[.dilateUsageDirectional].dispatch(Self.maxDirectionalTilemaps)
  }

  func dispatchTagUsagePunctual(gbufferPosition: GLuint,
                                invView: Akari.Matrix4,
                                screenWidth: Int,
                                screenHeight: Int,
                                footprintHeight: Int,
                                camera: Akari.Camera,
                                lights: [Akari.Lux.PointLight],
                                lightCount: Int)
  {
    let kernel = kernels[.tagUsagePunctual]
    kernel.set(.invView, invView)
    setLightPositions(kernel, lights: lights, lightCount: lightCount)
    let filmPixelRadius: Float = camera.projection[1, 1] > 1e-6
      ? 2 / (camera.projection[1, 1] * Float(footprintHeight))
      : 0
    kernel.set(.params, SIMD4<Float>(filmPixelRadius, Float(screenWidth), Float(screenHeight), Float(lightCount)))

    kernel.sample(gbufferPosition, at: 0)
    kernel.bind(buffers[.tiles])
    kernel.dispatch((screenWidth + 15) / 16, (screenHeight + 15) / 16)

    kernels[.dilateUsagePunctual].bind(buffers[.tiles])
    kernels[.dilateUsagePunctual].dispatch(lightCount * Self.facesPerLight)
  }

  /// Sets whether the volume froxels should sample a page.
  func dispatchTagUsageVolume(_ volume: VolumeFroxels,
                              invView: Akari.Matrix4,
                              camera: Akari.Camera,
                              lights: [Akari.Lux.PointLight],
                              lightCount: Int)
  {
    let kernel = kernels[.tagUsageVolume]
    guard
      kernel.isBuilt,
      volume.depthTexture != 0,
      volume.gridWidth > 0,
      volume.gridHeight > 0,
      volume.far > volume.near
    else { return }

    kernel.set(.invView, invView)
    kernel.set(.eyeToFitEye, directionalHistory.view * invView)
    kernel.set(.eyeToLightRotation, sun.eyeToLightRotation)
    kernel.set(.invProj, volume.inverseProjection)
    kernel.set(.directionalRefOffset, SIMD4<Float>(sun.refOffset.x, sun.refOffset.y, sun.refOffset.z, sun.lodBias))
    setLightPositions(kernel, lights: lights, lightCount: lightCount)
    kernel.set(.volume, SIMD4<Float>(volume.near, volume.far, Float(volume.gridWidth), Float(volume.gridHeight)))
    let froxelPixelRadius: Float = camera.projection[1, 1] > 1e-6
      ? 2 / (camera.projection[1, 1] * Float(volume.gridHeight))
      : 0
    kernel.set(.params, SIMD4<Float>(froxelPixelRadius, Float(lightCount), Float(directionalHistory.slots.count), sun.isClipmap ? 1 : 0))
    kernel.set(.lodRange, SIMD4<Float>(Float(sun.lodMin), Float(sun.lodMax), Float(max(volume.sunLevelBias, 0)), 0))

    kernel.sample(volume.depthTexture, at: 0)
    kernel.sample(data, at: 1)
    kernel.bind(buffers[.tiles])
    kernel.dispatch(volume.gridWidth, volume.gridHeight)
  }

  /// Marks the point light tiles the moved casters boxes cover, so only those redraw.
  func dispatchTagUpdatePunctual(boxCount: Int, lights: [Akari.Lux.PointLight], lightCount: Int)
  {
    let kernel = kernels[.tagUpdatePunctual]
    guard kernel.isBuilt, boxCount > 0, lightCount > 0 else { return }

    kernel.set(.boxCount, Int32(boxCount))
    kernel.set(.lightCount, Int32(lightCount))
    for slot in 0 ..< Self.maxPunctualLights
    {
      let position = slot < lightCount ? SIMD4(lights[slot].position, 0) : SIMD4<Float>(repeating: 0)
      kernel.set(.lightPos, index: slot, position)
    }

    kernel.bind(frame[.movedBoxes], buffers[.tiles])
    kernel.dispatch((boxCount * lightCount * 6 + 63) / 64)
  }

  /// Masks LODs covered by finer ones, then frees, defrags and allocates pages.
  func dispatchPageAllocation()
  {
    kernels[.maskLod].bind(buffers[.tiles])
    kernels[.maskLod].set(.maxViewPerTilemap, Int32(Self.lodCount))
    kernels[.maskLod].dispatch(Self.maxPunctualTilemaps)

    for (kernel, groups) in [(kernels[.free], Self.maxTilemaps), (kernels[.defrag], 1), (kernels[.allocate], Self.maxTilemaps)]
    {
      kernel.bind(buffers[.tiles], buffers[.pagesFree], buffers[.pagesInfo], buffers[.pagesCached])
      kernel.dispatch(groups)
    }
  }

  private func setLightPositions(_ kernel: Akari.ComputeKernel, lights: [Akari.Lux.PointLight], lightCount: Int)
  {
    for slot in 0 ..< Self.maxPunctualLights
    {
      let posRadius = slot < lightCount
        ? SIMD4(lights[slot].position.x,
                lights[slot].position.y,
                lights[slot].position.z,
                lights[slot].reach)
        : SIMD4<Float>(repeating: 0)
      kernel.set(.lightPosRadius, index: slot, posRadius)
    }
    // LabGL lays uniforms out in first set order, every position before any bias as in `U`.
    for slot in 0 ..< Self.maxPunctualLights
    {
      kernel.set(.lightLodBias, index: slot, SIMD4<Float>(lodBias(slot: slot), 0, 0, 0))
    }
  }
}
