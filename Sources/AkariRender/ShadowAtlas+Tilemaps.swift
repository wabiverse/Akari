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
    guard let p = gl.mapBuffer(frame[.levelParams]) else { return }
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

    gl.unmapBuffer(frame[.levelParams])

    withMappedBuffer(frame[.slotOfView], as: Int32.self)
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
    withMappedBuffer(frame[.gridShift], as: Int32.self)
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

    kernels[.tilemapShift].bind(buffers[.tiles], buffers[.pagesCached], frame[.gridShift])
    kernels[.tilemapShift].dispatch(Self.maxDirectionalTilemaps)
  }

  /// What a scene change left stale, uploading the moved casters boxes to this frame.
  func findCasterRedraw(_ casters: [Casters]) -> CasterRedraw
  {
    guard
      frame[.movedBoxes] != 0,
      let moved = casterMotion.movedBoxes(casters, limit: Self.maxMovedCasters)
    else { return .all }
    guard !moved.isEmpty else { return .boxes(0) }

    withMappedBuffer(frame[.movedBoxes], as: Float.self)
    { ptr in
      moved.withUnsafeBufferPointer { ptr.update(from: $0.baseAddress!, count: $0.count) }
    }

    return .boxes(moved.count / 6)
  }

  /// The moved static caster boxes, uploaded to this frame, nil when every static page has to redraw.
  func findStaticRedraw(_ casters: [Casters]) -> Int?
  {
    guard
      frame[.movedStaticBoxes] != 0,
      let moved = staticMotion.movedBoxes(casters, limit: Self.maxMovedCasters)
    else { return nil }
    guard !moved.isEmpty else { return 0 }

    withMappedBuffer(frame[.movedStaticBoxes], as: Float.self)
    { ptr in
      moved.withUnsafeBufferPointer { ptr.update(from: $0.baseAddress!, count: $0.count) }
    }

    return moved.count / 6
  }

  func dispatchTileMapMaintenance(casters parts: [Casters], slotCount: Int,
                                  lightZ: SIMD3<Float>,
                                  cameraWorld: SIMD3<Float>,
                                  castersMoved: Bool,
                                  redraw: CasterRedraw,
                                  staticRedraw: Int)
  {
    guard
      kernels[.clipmapClear].isBuilt,
      buffers[.tilemapsClip] != 0
    else { return }

    kernels[.clipmapClear].bind(buffers[.tilemapsClip])
    kernels[.clipmapClear].dispatch((Self.maxTilemaps + 63) / 64)

    let casterCount = parts.reduce(0) { $0 + $1.bounds.count / 6 }
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
      var offset = 0
      for part in parts
      {
        part.bounds.withUnsafeBytes
        {
          guard let base = $0.baseAddress else { return }
          (p + offset).copyMemory(from: base, byteCount: $0.count)
          offset += $0.count
        }
      }

      gl.unmapBuffer(casters.buffer)
    }

    if kernels[.tilemapBounds].isBuilt
    {
      let kernel = kernels[.tilemapBounds]
      kernel.set(.casterCount, Int32(casterCount))
      kernel.set(.slotCount, Int32(slotCount))
      kernel.set(.lightZ, lightZ)
      kernel.bind(casters.buffer, buffers[.tilemapsClip])
      kernel.dispatch((casterCount + 63) / 64)
    }

    // a full redraw already shifted every tile stale.
    if case let .boxes(movedCount) = redraw
    {
      tagUpdate(kernels[.tagUpdate], boxes: frame[.movedBoxes], count: movedCount, slotCount: slotCount, cameraWorld: cameraWorld)
      tagUpdate(kernels[.tagUpdateStatic], boxes: frame[.movedStaticBoxes], count: staticRedraw, slotCount: slotCount,
                cameraWorld: cameraWorld)
    }

    if kernels[.tagPropagate].isBuilt
    {
      kernels[.tagPropagate].bind(buffers[.tiles], buffers[.tiles])
      kernels[.tagPropagate].dispatch(1, 1, Self.maxTilemaps)
    }
  }

  /// Tags the directional tiles under `count` of `boxes`, with whichever update `kernel` sets.
  private func tagUpdate(_ kernel: Akari.ComputeKernel, boxes: GLuint, count movedCount: Int, slotCount: Int, cameraWorld: SIMD3<Float>)
  {
    if kernel.isBuilt, movedCount > 0, slotCount > 0
    {
      let r = sun.rotation
      kernel.set(.casterCount, Int32(movedCount))
      kernel.set(.slotCount, Int32(slotCount))
      kernel.set(.lightX, SIMD3<Float>(r[0, 0], r[1, 0], r[2, 0]))
      kernel.set(.lightY, SIMD3<Float>(r[0, 1], r[1, 1], r[2, 1]))
      kernel.set(.cameraWorld, cameraWorld)
      kernel.bind(boxes, frame[.levelParams], buffers[.tiles])
      kernel.dispatch((movedCount * slotCount + 63) / 64)
    }
  }

  /// Picks this frame's dirty views from live tile state, `budget` static tiles of them at most.
  func dispatchSelectViews(budget: Int)
  {
    let kernel = kernels[.buildRenderViews]
    let readback = renderViewReadback

    guard
      kernel.isBuilt,
      kernels[.countDirty].isBuilt,
      kernels[.allotBudget].isBuilt,
      readback != 0
    else { return }

    kernels[.countDirty].bind(buffers[.tiles], frame[.slotOfView], buffers[.dirtyCount])
    kernels[.countDirty].dispatch((Self.maxViews + 63) / 64)

    kernels[.allotBudget].set(.budget, Int32(budget))
    kernels[.allotBudget].bind(frame[.slotOfView], buffers[.dirtyCount], buffers[.allowance])
    kernels[.allotBudget].dispatch(1)

    kernel.bind(buffers[.tiles], frame[.slotOfView], gl.computeReadbackCurrentBuffer(readback))
    kernel.readback(readback, at: 2)
    kernel.bind(buffers[.clearArgs], buffers[.renderRect], buffers[.renderRectStatic], buffers[.clearArgsStatic], buffers[.dirtyCount], buffers[.allowance], at: 3)
    kernel.dispatch((Self.maxViews + 63) / 64)
  }

  func dispatchPageTable()
  {
    guard kernels[.pageTable].isBuilt, pageTable != 0 else { return }
    for map in [buffers[.renderMap], buffers[.renderMapStatic]]
    {
      kernels[.renderMapClear].bind(map)
      kernels[.renderMapClear].dispatch((Self.maxViews * Self.tilemapRes * Self.tilemapRes + 63) / 64)
    }

    kernels[.pageTable].bind(buffers[.tiles])
    kernels[.pageTable].bind(buffers[.renderMap], frame[.slotOfView], buffers[.renderMapStatic], buffers[.renderRect], buffers[.renderRectStatic], at: 2)
    kernels[.pageTable].image(pageTable, at: 0, format: GLenum(GL_RGBA16F))
    kernels[.pageTable].dispatch((Self.maxTiles + 63) / 64)
  }
}
