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
import simd

extension Akari.ShadowAtlas
{
  func writeDataTexture(directional: [Cascade],
                        directionalSlots: [Int],
                        punctualFaces: [[PunctualFace]],
                        inverseView: Akari.Matrix4)
  {
    guard data != 0 else { return }

    dataPixels.withUnsafeMutableBufferPointer
    { buf in
      let pixels = buf.baseAddress!
      pixels.update(repeating: 0, count: buf.count)

      for lightIdx in 0 ..< Self.maxPunctualLights where punctualFaces[lightIdx].count == 6
      {
        for face in 0 ..< Self.facesPerLight
        {
          let slot = lightIdx * Self.facesPerLight + face
          let punctual = punctualFaces[lightIdx][face]
          Self.writeRow(pixels, row: slot, matrix: punctual.viewProjection, slotColumn: nil,
                        depthOffset: punctual.near, zScale: punctual.far)
        }
      }

      for (i, offset) in directionalSlots.enumerated()
      {
        let row = Self.directionalTilemapBase + i
        Self.writeRow(pixels, row: row, matrix: directional[i].viewProjection * inverseView,
                      slotColumn: Float(Self.directionalTilemapBase + offset),
                      tileOffset: directional[i].tileOffset,
                      depthOffset: directional[i].depthOffset,
                      zScale: directional[i].zScale,
                      zBias: directional[i].zBias)
      }

      data = frame.data
      gl.bindTexture(target: GL_TEXTURE_2D, texture: data)
      gl.texSubImage2D(target: GL_TEXTURE_2D,
                       level: 0,
                       xOffset: 0,
                       yOffset: 0,
                       width: GLsizei(Self.dataTextureWidth),
                       height: GLsizei(Self.maxTilemaps),
                       format: GL_RGBA,
                       type: GL_FLOAT,
                       pixels: pixels)
    }
  }

  private static func writeRow(_ pixels: UnsafeMutablePointer<Float>,
                               row: Int,
                               matrix: Akari.Matrix4,
                               slotColumn: Float?,
                               tileOffset: SIMD2<Float> = .zero,
                               depthOffset: Float = 0,
                               zScale: Float = 0,
                               zBias: Float = 0)
  {
    let o = pixels + row * dataTextureWidth * 4
    UnsafeMutableRawPointer(o).storeBytes(of: matrix.simd, as: simd_float4x4.self)
    if let slotColumn { o[16] = slotColumn }
    o[17] = tileOffset.x
    o[18] = tileOffset.y
    o[20] = depthOffset
    o[21] = zScale
    o[22] = zBias
  }

  /// Each directional level's light space, for tagging which tile to update.
  func uploadLevelParams(directional: [Cascade], directionalSlots: [Int], inverseView: Akari.Matrix4)
  {
    guard let p = gl.mapBuffer(frame.levelParams) else { return }
    let out = p.assumingMemoryBound(to: Float.self)
    out.update(repeating: 0, count: Self.maxDirectionalTilemaps * Self.levelParamsStride)

    let camera = SIMD3(inverseView[3, 0], inverseView[3, 1], inverseView[3, 2])
    for (i, offset) in directionalSlots.enumerated()
    {
      let level = directional[i]
      let o = out + offset * Self.levelParamsStride
      let r = (level.view.simd * inverseView.simd)
      o[0] = r.columns.0.x; o[1] = r.columns.1.x; o[2] = r.columns.2.x
      o[3] = r.columns.0.y; o[4] = r.columns.1.y; o[5] = r.columns.2.y
      o[6] = r.columns.0.z; o[7] = r.columns.1.z; o[8] = r.columns.2.z

      let lightCamera = level.view.transform(camera)
      o[9] = lightCamera.x
      o[10] = lightCamera.y
      o[11] = lightCamera.z
      o[12] = 2 * (Self.coverageGet(Int(level.absoluteLevel)) / 2) / Float(Self.tilemapRes)
      o[13] = level.zScale
      o[14] = level.zBias
      o[15] = 1
    }
    gl.unmapBuffer(frame.levelParams)

    withMappedBuffer(frame.slotOfView, as: Int32.self)
    { slots in
      slots.update(repeating: -1, count: Self.maxDirectionalTilemaps)
      for (i, offset) in directionalSlots.enumerated() where i < Self.maxDirectionalTilemaps
      {
        slots[i] = Int32(Self.directionalTilemapBase + offset)
      }
    }
  }

  func dispatchTilemapShift(forceFullShift: Bool)
  {
    withMappedBuffer(frame.gridShift, as: Int32.self)
    { ptr in
      for offset in 0 ..< Self.maxDirectionalTilemaps
      {
        let shift = forceFullShift
          ? SIMD2<Int32>(Int32(Self.tilemapRes), Int32(Self.tilemapRes))
          : directionalHistory.pendingShift[offset]
        ptr[offset * 2 + 0] = shift.x
        ptr[offset * 2 + 1] = shift.y
      }
    }

    gl.setComputeShaderBuffer(kernels.tilemapShift, binding: 0, buffer: buffers.tiles)
    gl.setComputeShaderBuffer(kernels.tilemapShift, binding: 1, buffer: buffers.pagesCached)
    gl.setComputeShaderBuffer(kernels.tilemapShift, binding: 2, buffer: frame.gridShift)
    gl.dispatchCompute(kernels.tilemapShift,
                       groupsX: GLuint(Self.maxDirectionalTilemaps),
                       groupsY: 1,
                       groupsZ: 1)
  }

  func dispatchTileMapMaintenance(casterBounds: [Float], slotCount: Int,
                                  lightZ: SIMD3<Float>,
                                  cameraWorld: SIMD3<Float>,
                                  castersMoved: Bool)
  {
    guard
      kernels.clipmapClear != 0,
      buffers.tilemapsClip != 0
    else { return }

    gl.setComputeShaderBuffer(kernels.clipmapClear, binding: 0, buffer: buffers.tilemapsClip)
    gl.dispatchCompute(kernels.clipmapClear,
                       groupsX: GLuint((Self.maxTilemaps + 63) / 64),
                       groupsY: 1,
                       groupsZ: 1)

    let casterCount = casterBounds.count / 6
    guard casterCount > 0, slotCount > 0 else { return }

    var upload = castersMoved
    if casterCount > casters.capacity
    {
      if casters.buffer != 0 { gl.deleteBuffer(casters.buffer) }
      casters.capacity = max(casterCount * 2, 1024)
      casters.buffer = makeBuffer(LGL_BUFFER_COMPUTE_READ | LGL_BUFFER_MAP_WRITE, Float.self,
                                  count: casters.capacity * 6)
      upload = true
    }
    guard casters.buffer != 0 else { return }
    if upload, let p = gl.mapBuffer(casters.buffer)
    {
      casterBounds.withUnsafeBytes { p.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
      gl.unmapBuffer(casters.buffer)
    }

    if kernels.tilemapBounds != 0
    {
      let kernel = kernels.tilemapBounds
      setUniform(kernel, "u_casterCount", GL_INT, Int32(casterCount))
      setUniform(kernel, "u_slotCount", GL_INT, Int32(slotCount))
      setUniform(kernel, "u_lightZ", GLenum(GL_FLOAT_VEC3), lightZ)
      gl.setComputeShaderBuffer(kernel, binding: 0, buffer: casters.buffer)
      gl.setComputeShaderBuffer(kernel, binding: 1, buffer: buffers.tilemapsClip)
      gl.dispatchCompute(kernel,
                         groupsX: GLuint((casterCount + 63) / 64),
                         groupsY: 1,
                         groupsZ: 1)
    }

    if kernels.tagUpdate != 0, castersMoved
    {
      let kernel = kernels.tagUpdate
      let r = sun.rotation
      setUniform(kernel, "u_casterCount", GL_INT, Int32(casterCount))
      setUniform(kernel, "u_slotCount", GL_INT, Int32(slotCount))
      setUniform(kernel, "u_lightX", GLenum(GL_FLOAT_VEC3), SIMD3<Float>(r[0, 0], r[1, 0], r[2, 0]))
      setUniform(kernel, "u_lightY", GLenum(GL_FLOAT_VEC3), SIMD3<Float>(r[0, 1], r[1, 1], r[2, 1]))
      setUniform(kernel, "u_cameraWorld", GLenum(GL_FLOAT_VEC3), cameraWorld)
      gl.setComputeShaderBuffer(kernel, binding: 0, buffer: casters.buffer)
      gl.setComputeShaderBuffer(kernel, binding: 1, buffer: frame.levelParams)
      gl.setComputeShaderBuffer(kernel, binding: 2, buffer: buffers.tiles)
      gl.dispatchCompute(kernel,
                         groupsX: GLuint((casterCount * slotCount + 63) / 64),
                         groupsY: 1,
                         groupsZ: 1)
    }

    if kernels.tagPropagate != 0
    {
      gl.setComputeShaderBuffer(kernels.tagPropagate, binding: 0, buffer: buffers.tiles)
      gl.setComputeShaderBuffer(kernels.tagPropagate, binding: 1, buffer: buffers.tiles)
      gl.dispatchCompute(kernels.tagPropagate,
                         groupsX: 1,
                         groupsY: 1,
                         groupsZ: GLuint(Self.maxTilemaps))
    }
  }

  /// Picks this frame's dirty views from live tile state.
  func dispatchSelectViews()
  {
    let kernel = kernels.buildRenderViews
    let readback = buffers.renderViewReadback

    guard
      kernel != 0,
      readback != 0
    else { return }

    gl.setComputeShaderBuffer(kernel, binding: 0, buffer: buffers.tiles)
    gl.setComputeShaderBuffer(kernel, binding: 1, buffer: frame.slotOfView)
    gl.setComputeShaderBuffer(kernel, binding: 2, buffer: gl.computeReadbackCurrentBuffer(readback))
    gl.setComputeShaderReadback(kernel, bindingIndex: 2, readback: readback)
    gl.setComputeShaderBuffer(kernel, binding: 3, buffer: buffers.clearArgs)
    gl.setComputeShaderBuffer(kernel, binding: 4, buffer: buffers.renderRect)
    gl.dispatchCompute(kernel,
                       groupsX: GLuint((Self.maxViews + 63) / 64),
                       groupsY: 1,
                       groupsZ: 1)
  }

  func dispatchPageTable()
  {
    guard kernels.pageTable != 0, pageTable != 0 else { return }
    gl.setComputeShaderBuffer(kernels.renderMapClear, binding: 0, buffer: buffers.renderMap)
    gl.dispatchCompute(kernels.renderMapClear,
                       groupsX: GLuint((Self.maxViews * Self.tilemapRes * Self.tilemapRes + 63) / 64),
                       groupsY: 1,
                       groupsZ: 1)
    gl.setComputeShaderBuffer(kernels.pageTable, binding: 0, buffer: buffers.tiles)
    gl.setComputeShaderBuffer(kernels.pageTable, binding: 2, buffer: buffers.renderMap)
    gl.setComputeShaderBuffer(kernels.pageTable, binding: 3, buffer: frame.slotOfView)
    gl.setComputeShaderImage(kernels.pageTable,
                             index: 0,
                             texture: pageTable,
                             format: GLenum(GL_RGBA16F),
                             level: 0)
    gl.dispatchCompute(kernels.pageTable,
                       groupsX: GLuint((Self.maxTiles + 63) / 64),
                       groupsY: 1,
                       groupsZ: 1)
  }
}
