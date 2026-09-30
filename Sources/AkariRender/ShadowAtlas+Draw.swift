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
import LabGL
import simd

extension Akari.ShadowAtlas
{
  /// The views in `forced` plus those the GPU last reported with tiles to render.
  func drawViews(capture: OpaquePointer, directional: [Cascade], directionalSlots: [Int],
                 punctualFaces: [[PunctualFace]], forced: Set<Int>, forcePunctual: Bool) -> [Int]
  {
    let lightCount = punctualFaces.prefix(while: { $0.count == Self.facesPerLight }).count
    let punctualViews = Self.punctualViewBase ..< Self.punctualViewBase
      + lightCount * Self.facesPerLight * Self.lodCount
    var views = Array(directional.indices) + Array(punctualViews)

    var size: GLsizei = 0
    if
      let raw = gl.computeReadbackLatest(buffers.renderViewReadback, size: &size),
      size == GLsizei(Self.maxViews * MemoryLayout<UInt32>.size)
    {
      let published = raw.assumingMemoryBound(to: UInt32.self)
      var dirty = Set<UInt32>()
      for i in 0 ..< Self.maxDirectionalTilemaps where published[i] != .max
      {
        dirty.insert(published[i])
      }
      views = directional.indices.filter
      {
        forced.contains(directionalSlots[$0]) ||
          dirty.contains(UInt32(Self.directionalTilemapBase + directionalSlots[$0]))
      }
      views += forcePunctual ? Array(punctualViews) : punctualViews.filter { published[$0] != .max }
    }
    guard !views.isEmpty else { return [] }

    func viewProjection(_ view: Int) -> Akari.Matrix4
    {
      guard view >= Self.punctualViewBase else { return directional[view].viewProjection }
      let slot = (view - Self.punctualViewBase) / Self.lodCount
      return punctualFaces[slot / Self.facesPerLight][slot % Self.facesPerLight].viewProjection
    }

    let punctualSelected = views.filter { $0 >= Self.punctualViewBase }
    var runs = Self.buildRuns(views.filter { $0 < Self.punctualViewBase })
    var culled = cullRuns(capture: capture, runs: runs, viewProjection: viewProjection)
    let instanced = culled &&
      !punctualSelected.isEmpty &&
      cullPunctual(capture: capture, views: punctualSelected, slot: runs.count, viewProjection: viewProjection)
    if !instanced, !punctualSelected.isEmpty
    {
      runs += Self.buildRuns(punctualSelected)
      culled = cullRuns(capture: capture, runs: runs, viewProjection: viewProjection)
    }
    dispatchPageClear()

    let res = GLsizei(Self.tilemapRes * Self.pageResolution)
    beginAtlasPass()
    gl.viewport(x: 0, y: 0, width: res, height: res)
    gl.scissor(x: 0, y: 0, width: res, height: res)
    gl.useShader(depthShader)
    gl.setShaderBuffer(depthShader, index: 0, buffer: buffers.renderMap)
    gl.setShaderImageArgument(depthShader, bufferIndex: 1, texture: atlas)
    gl.setShaderBuffer(depthShader, index: 4, buffer: frame.slotOfView)
    gl.setShaderVertexBuffer(depthShader, index: 5, buffer: buffers.renderRect)
    gl.setShaderVertexBuffer(depthShader, index: 7, buffer: frame.viewXf)
    gl.setShaderVertexBuffer(depthShader, index: 8,
                             buffer: culling.instanceView != 0 ? culling.instanceView : frame.viewXf)

    for (r, run) in runs.enumerated()
    {
      var transforms: [Float] = []
      var rects: [Int32] = []
      for view in run
      {
        let viewRes = view < Self.punctualViewBase
          ? Int32(res)
          : Int32((Self.tilemapRes >> ((view - Self.punctualViewBase) % Self.lodCount)) * Self.pageResolution)
        viewProjection(view).withUnsafeFloats { transforms.append(contentsOf: $0) }
        rects += [0, 0, viewRes, viewRes]
      }
      setAmplification(transforms: transforms, viewports: rects, viewBase: Int32(run[0]), count: run.count)
      if culled { labgl.capturePlaybackCulled(capture, slot: UInt32(r)) }
      else { labgl.capturePlaybackIndirectDraws(capture) }
      gl.disableVertexAmplification()
    }
    if instanced
    {
      var identity: [Float] = []
      Akari.Matrix4.identity.withUnsafeFloats { identity.append(contentsOf: $0) }
      setAmplification(transforms: identity, viewports: [0, 0, Int32(res), Int32(res)], viewBase: -1, count: 1)
      labgl.capturePlaybackCulled(capture, slot: UInt32(runs.count))
      gl.disableVertexAmplification()
    }
    gl.useShader(0)
    endAtlasPass()

    return views
  }

  /// Groups consecutive views of the same tilemap into amplified runs.
  private static func buildRuns(_ views: [Int]) -> [[Int]]
  {
    func face(_ view: Int) -> Int
    {
      view < punctualViewBase
        ? -1 - view
        : (view - punctualViewBase) / lodCount
    }

    var runs: [[Int]] = []
    for view in views
    {
      if
        let last = runs.last?.last,
        view == last + 1,
        face(view) == face(last),
        runs[runs.count - 1].count < maxAmplificationViews
      {
        runs[runs.count - 1].append(view)
      }
      else
      {
        runs.append([view])
      }
    }

    return runs
  }

  private func setAmplification(transforms: [Float], viewports: [Int32], viewBase: Int32, count: Int)
  {
    transforms.withUnsafeBufferPointer
    { buf in
      gl.instanceTransformsData(handle: amplification.views,
                                size: GLsizei(buf.count * MemoryLayout<Float>.size),
                                transforms: buf.baseAddress, cullRadius: 0, usage: GL_STATIC_DRAW)
    }
    viewports.withUnsafeBufferPointer
    { buf in
      gl.instanceViewportsData(handle: amplification.viewports,
                               size: GLsizei(buf.count * MemoryLayout<Int32>.size),
                               viewports: buf.baseAddress, usage: GL_STATIC_DRAW)
    }

    var base = viewBase
    gl.setShaderUniform(depthShader, name: "u_viewBase", type: GL_INT, data: &base)
    gl.setVertexAmplification(viewsHandle: amplification.views,
                              viewportsHandle: amplification.viewports,
                              count: GLsizei(count))
  }

  private func cullRuns(capture: OpaquePointer, runs: [[Int]], viewProjection: (Int) -> Akari.Matrix4) -> Bool
  {
    guard
      kernels.cull != 0,
      runs.count <= Self.maxRuns,
      ensureDrawBounds(capture: capture)
    else { return false }

    guard !runs.isEmpty else { return true }

    guard let viewsPtr = gl.mapBuffer(frame.runViews) else { return false }
    let runViews = viewsPtr.assumingMemoryBound(to: Int32.self)
    runViews.update(repeating: -1, count: Self.maxRuns * Self.maxAmplificationViews)
    for (r, run) in runs.enumerated()
    {
      for (k, view) in run.enumerated()
      {
        runViews[r * Self.maxAmplificationViews + k] = Int32(view)
      }
    }
    gl.unmapBuffer(frame.runViews)

    guard let xfPtr = gl.mapBuffer(frame.runXf) else { return false }
    for (r, run) in runs.enumerated()
    {
      for (k, view) in run.enumerated()
      {
        (xfPtr + (r * Self.maxAmplificationViews + k) * 64).storeBytes(of: viewProjection(view).simd,
                                                                       as: simd_float4x4.self)
      }
    }
    gl.unmapBuffer(frame.runXf)

    let kernel = kernels.cull
    setUniform(kernel, "u_params", GL_INT_VEC4, SIMD4<Int32>(Int32(culling.count), Int32(runs.count), 0, 0))
    gl.setComputeShaderBuffer(kernel, binding: 0, buffer: culling.bounds)
    gl.setComputeShaderBuffer(kernel, binding: 1, buffer: frame.runViews)
    gl.setComputeShaderBuffer(kernel, binding: 2, buffer: frame.runXf)
    gl.setComputeShaderBuffer(kernel, binding: 3, buffer: buffers.renderRect)
    gl.setComputeShaderBuffer(kernel, binding: 4, buffer: culling.visibility)
    gl.dispatchCompute(kernel,
                       groupsX: GLuint((culling.count * runs.count + 63) / 64),
                       groupsY: 1, groupsZ: 1)

    for r in runs.indices
    {
      guard labgl.captureEncodeCulled(capture, visibility: culling.visibility,
                                      offset: Int32(r * culling.count * MemoryLayout<UInt32>.size),
                                      slot: UInt32(r), instanceStride: 0) != 0
      else { return false }
    }

    return true
  }

  private func cullPunctual(capture: OpaquePointer, views: [Int], slot: Int,
                            viewProjection: (Int) -> Akari.Matrix4) -> Bool
  {
    guard
      kernels.cullPunctual != 0,
      culling.instanceView != 0,
      culling.count > 0,
      slot < Self.maxRuns,
      let viewsPtr = gl.mapBuffer(frame.punctualViews)
    else { return false }

    let list = viewsPtr.assumingMemoryBound(to: Int32.self)
    for (k, view) in views.enumerated()
    {
      list[k] = Int32(view)
    }
    gl.unmapBuffer(frame.punctualViews)

    guard let xfPtr = gl.mapBuffer(frame.viewXf) else { return false }
    for view in views
    {
      (xfPtr + view * 64).storeBytes(of: viewProjection(view).simd, as: simd_float4x4.self)
    }
    gl.unmapBuffer(frame.viewXf)

    let kernel = kernels.cullPunctual
    setUniform(kernel, "u_params", GL_INT_VEC4,
               SIMD4<Int32>(Int32(culling.count), Int32(views.count), Int32(slot * culling.count), 0))
    gl.setComputeShaderBuffer(kernel, binding: 0, buffer: culling.bounds)
    gl.setComputeShaderBuffer(kernel, binding: 1, buffer: frame.punctualViews)
    gl.setComputeShaderBuffer(kernel, binding: 2, buffer: frame.viewXf)
    gl.setComputeShaderBuffer(kernel, binding: 3, buffer: buffers.renderRect)
    gl.setComputeShaderBuffer(kernel, binding: 4, buffer: culling.visibility)
    gl.setComputeShaderBuffer(kernel, binding: 5, buffer: culling.instanceView)
    gl.dispatchCompute(kernel,
                       groupsX: GLuint((culling.count + 63) / 64),
                       groupsY: 1,
                       groupsZ: 1)

    return labgl.captureEncodeCulled(capture,
                                     visibility: culling.visibility,
                                     offset: Int32(slot * culling.count * MemoryLayout<UInt32>.size),
                                     slot: UInt32(slot),
                                     instanceStride: UInt32(Self.maxPunctualViews)) != 0
  }

  private func ensureDrawBounds(capture: OpaquePointer) -> Bool
  {
    let generation = labgl.captureGeneration(capture)
    if generation != culling.generation
    {
      culling.generation = generation
      culling.count = 0

      var bounds: UnsafePointer<Float>? = nil
      let count = Int(labgl.captureIndirectDrawBounds(capture, bounds: &bounds))
      guard
        count > 0,
        let bounds
      else { return false }

      if count > culling.capacity
      {
        for buf in culling.buffers where buf != 0
        {
          gl.deleteBuffer(buf)
        }
        culling.bounds = makeBuffer(LGL_BUFFER_COMPUTE_READ | LGL_BUFFER_MAP_WRITE, Float.self,
                                    count: count * 6)
        culling.visibility = makeBuffer(LGL_BUFFER_COMPUTE_READ | LGL_BUFFER_COMPUTE_WRITE, UInt32.self,
                                        count: Self.maxRuns * count)
        culling.instanceView = makeBuffer(LGL_BUFFER_COMPUTE_READ | LGL_BUFFER_COMPUTE_WRITE, UInt32.self,
                                          count: Self.maxPunctualViews * count)
        culling.capacity = count
      }

      guard
        culling.bounds != 0,
        culling.visibility != 0,
        let p = gl.mapBuffer(culling.bounds)
      else { return false }

      memcpy(p, bounds, count * 6 * MemoryLayout<Float>.size)
      gl.unmapBuffer(culling.bounds)
      culling.count = count
    }

    return culling.count > 0
  }

  /// Retires every tile to render of the views just drawn, covered by a caster or not.
  func retireDrawn(views: [Int])
  {
    guard
      !views.isEmpty,
      kernels.retireDrawn != 0,
      let p = gl.mapBuffer(frame.drawnView)
    else { return }

    let drawn = p.assumingMemoryBound(to: Int32.self)
    drawn.update(repeating: 0, count: Self.maxViews)
    for view in views
    {
      drawn[view] = 1
    }
    gl.unmapBuffer(frame.drawnView)

    let kernel = kernels.retireDrawn
    gl.setComputeShaderBuffer(kernel, binding: 0, buffer: buffers.tiles)
    gl.setComputeShaderBuffer(kernel, binding: 1, buffer: frame.slotOfView)
    gl.setComputeShaderBuffer(kernel, binding: 2, buffer: frame.drawnView)
    gl.setComputeShaderBuffer(kernel, binding: 3, buffer: buffers.renderRect)
    gl.dispatchCompute(kernel,
                       groupsX: GLuint((Self.maxViews * Self.tilemapRes * Self.tilemapRes + 63) / 64),
                       groupsY: 1, groupsZ: 1)
  }

  /// Resets the pages about to be redrawn to the far value.
  private func dispatchPageClear()
  {
    guard
      kernels.pageClear != 0,
      kernels.buildClearList != 0,
      frame.clearList != 0,
      buffers.clearArgs != 0
    else { return }

    gl.setComputeShaderBuffer(kernels.buildClearList, binding: 0, buffer: buffers.renderMap)
    gl.setComputeShaderBuffer(kernels.buildClearList, binding: 1, buffer: frame.clearList)
    gl.setComputeShaderBuffer(kernels.buildClearList, binding: 2, buffer: buffers.clearArgs)
    gl.dispatchCompute(kernels.buildClearList,
                       groupsX: GLuint((Self.maxViews * Self.tilemapRes * Self.tilemapRes + 63) / 64),
                       groupsY: 1,
                       groupsZ: 1)

    gl.setComputeShaderBuffer(kernels.pageClear, binding: 0, buffer: frame.clearList)
    gl.setComputeShaderImage(kernels.pageClear,
                             index: 0,
                             texture: atlas,
                             format: GLenum(GL_R32UI),
                             level: 0)
    gl.dispatchComputeIndirect(kernels.pageClear,
                               argsBuffer: buffers.clearArgs,
                               offsetBytes: 0)
  }

  private func beginAtlasPass()
  {
    gl.bindRenderTarget(atlasTarget)
    gl.disable(GLenum(GL_BLEND))
    gl.disable(GL_CULL_FACE)
    gl.disable(GL_DEPTH_TEST)
    gl.depthMask(GLboolean(0))
    gl.enable(GLenum(GL_SCISSOR_TEST))
  }

  private func endAtlasPass()
  {
    gl.disable(GLenum(GL_SCISSOR_TEST))
    gl.enable(GL_CULL_FACE)
    gl.enable(GL_DEPTH_TEST)
    gl.depthMask(GLboolean(1))
    gl.bindRenderTarget(gl.rootRenderTarget())
  }
}
