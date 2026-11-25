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
import LabGL
import simd

extension Akari.Geom.Deformer
{
  /// uploads this frame's points and matrices and deforms them on the gpu, returning the bounds and each mesh's caster bounds and keys
  public func update(_ meshes: [Akari.Geom.Recorder.RawMesh]) -> (bounds: (min: SIMD3<Float>, max: SIMD3<Float>)?,
                                                       casterBounds: [Float], casterKeys: [UInt64])
  {
    glassBounds = []
    guard
      cornerCount > 0,
      !buffers.points.isEmpty
    else { return (nil, [], []) }

    let given = Set(meshes.lazy.map(\.key))
    let hidden = Set(self.meshes.lazy.map(\.key).filter { !given.contains($0) })
    if hidden != undrawn, let capture
    {
      undrawn = hidden
      labgl.captureClear(capture)
      buffers.vertices = record(into: capture, vertexCount: cornerCount, indices: Array(0 ..< Int32(cornerCount)))
      if let shadowCapture
      {
        labgl.captureClear(shadowCapture)
        buffers.shadowVertices = record(into: shadowCapture, vertexCount: pointCount, indices: arrays.shadow)
      }

      hasHistory = false
    }

    cursor = (cursor + 1) % Self.ring
    guard
      let pointPtr = gl.mapBuffer(buffers.points[cursor])?.assumingMemoryBound(to: Float.self),
      let xfPtr = gl.mapBuffer(buffers.transforms[cursor])?.assumingMemoryBound(to: Float.self)
    else { return (nil, [], []) }
    let palettePtr = buffers.palettes.isEmpty ? nil : gl.mapBuffer(buffers.palettes[cursor])?.assumingMemoryBound(to: Float.self)
    let cagePtr = buffers.cages.isEmpty ? nil : gl.mapBuffer(buffers.cages[cursor])?.assumingMemoryBound(to: Float.self)

    let indexOf = Dictionary(meshes.indices.map { (meshes[$0].key, $0) }, uniquingKeysWith: { a, _ in a })
    var casterBounds: [Float] = []
    var casterKeys: [UInt64] = []
    casterBounds.reserveCapacity(self.meshes.count * 6)
    var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
    let laidOutCount = self.meshes.count
    if written.count != Self.ring * laidOutCount
    {
      written = [UInt64](repeating: .max, count: Self.ring * laidOutCount)
      pointBounds = [Float](repeating: 0, count: laidOutCount * 6)
    }

    let glassPtr = buffers.glassDraws.isEmpty ? nil : gl.mapBuffer(buffers.glassDraws[cursor])?.assumingMemoryBound(to: UInt32.self)
    var draw = 0
    drawBounds.removeAll(keepingCapacity: true)
    drawBounded.removeAll(keepingCapacity: true)
    glassDrawIndices.removeAll(keepingCapacity: true)
    var local = [Float](repeating: 0, count: 6)

    // copies a mesh's points into this ring slot only when it holds an older revision of them.
    let upload = { (index: Int, revision: UInt64, copy: (UnsafeMutablePointer<Float>) -> Void) in
      let slot = self.cursor * laidOutCount + index
      self.pointBounds.withUnsafeMutableBufferPointer
      { cached in
        let bounds = cached.baseAddress! + index * 6
        if self.written[slot] != revision
        {
          copy(bounds)
          self.written[slot] = revision
        }

        local.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: bounds, count: 6) }
      }
    }

    for (index, laidOut) in self.meshes.enumerated()
    {
      let drawn = !undrawn.contains(laidOut.key)

      // a mesh laid out but not given this frame collapses to a point, so it draws nothing.
      guard let i = indexOf[laidOut.key]
      else
      {
        if drawn
        {
          glassPtr?[draw] = 0
          drawBounds += Self.nowhere

          // collapsed to a point it draws nothing anywhere
          drawBounded.append(true)
          draw += 1
        }

        (xfPtr + index * Self.xfStride).update(repeating: 0, count: Self.xfStride)
        xfPtr[index * Self.xfStride + 37] = 1
        continue
      }

      let drawIndex = drawn ? draw : -1
      if drawn
      {
        glassPtr?[draw] = meshes[i].transparent ? 1 : 0
        if meshes[i].transparent { glassDrawIndices.append(draw) }
        draw += 1
      }

      if laidOut.jointCount > 0, let palettePtr, meshes[i].skinPalette.count == laidOut.jointCount * 12
      {
        meshes[i].skinPalette.withUnsafeBufferPointer
        {
          (palettePtr + laidOut.jointBase * 12).update(from: $0.baseAddress!, count: $0.count)
        }

        local = meshes[i].skinBounds
      }
      else if laidOut.cageCount > 0, let cagePtr, meshes[i].cagePoints.size() == laidOut.cageCount
      {
        // a refined mesh uploads only its cage, the subdivide kernel builds its points from it.
        upload(index, meshes[i].dataRevision)
        { Pixar.HdAkariCopyPoints(meshes[i].cagePoints, cagePtr + laidOut.cageBase * 3, $0) }
      }
      else
      {
        // its palette changed size since the layout, relay out rather than skin with the old one.
        if laidOut.jointCount > 0 { relayout = true }
        upload(index, meshes[i].dataRevision)
        { Pixar.HdAkariCopyPoints(meshes[i].points, pointPtr + laidOut.pointBase * 3, $0) }
      }

      let xf = xfPtr + index * Self.xfStride
      let m = meshes[i].worldMatrix
      for k in 0 ..< 16
      {
        xf[k] = m[k]
      }

      for k in 0 ..< 9
      {
        xf[16 + k] = meshes[i].normalMatrix[k]
      }

      xf[25] = Float(meshes[i].primId)

      var wlo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), whi = -wlo
      for corner in 0 ..< 8
      {
        let p = SIMD3(corner & 1 != 0 ? local[3] : local[0],
                      corner & 2 != 0 ? local[4] : local[1],
                      corner & 4 != 0 ? local[5] : local[2])
        let w = SIMD3(m[0] * p.x + m[4] * p.y + m[8] * p.z + m[12],
                      m[1] * p.x + m[5] * p.y + m[9] * p.z + m[13],
                      m[2] * p.x + m[6] * p.y + m[10] * p.z + m[14])
        wlo = pointwiseMin(wlo, w)
        whi = pointwiseMax(whi, w)
      }

      let assemble = assembly[meshes[i].primId] ?? SIMD4(1, 0, 0, 0)
      let size = assemblySize[meshes[i].primId] ?? -0.4
      let center = size < 0 ? (wlo + whi) * 0.5 : SIMD3(assemble.y, assemble.z, assemble.w)
      xf[26] = assemble.x
      xf[27] = center.x
      xf[28] = center.y
      xf[29] = center.z
      xf[30] = abs(size)
      xf[31] = zUp ? 1 : 0
      xf[32] = eye.x
      xf[33] = eye.y
      xf[34] = eye.z
      xf[35] = Float(laidOut.cornerBase / 3)
      xf[36] = Float(laidOut.cornerCount / 3)
      xf[37] = 0
      xf[38] = Self.shading(meshes[i])
      casterBounds += [wlo.x, wlo.y, wlo.z, whi.x, whi.y, whi.z]
      if drawIndex >= 0
      {
        drawBounds += [wlo.x, wlo.y, wlo.z, whi.x, whi.y, whi.z]
        drawBounded.append(assemble.x >= 0.9999)
      }

      // read from this frame's mesh since a material edit can make it glass, a glowing shell is light and casts no tinted light
      if meshes[i].transparent, !meshes[i].emitter { glassBounds.append((wlo, whi)) }
      lo = pointwiseMin(lo, wlo)
      hi = pointwiseMax(hi, whi)

      var key = (14_695_981_039_346_656_037 ^ meshes[i].dataRevision) &* 1_099_511_628_211
      for value in m
      {
        key = (key ^ UInt64(value.bitPattern)) &* 1_099_511_628_211
      }

      casterKeys.append(key)
    }

    gl.unmapBuffer(buffers.points[cursor])
    gl.unmapBuffer(buffers.transforms[cursor])
    if glassPtr != nil
    {
      gl.unmapBuffer(buffers.glassDraws[cursor])
      glassDraws = buffers.glassDraws[cursor]
    }
    if palettePtr != nil { gl.unmapBuffer(buffers.palettes[cursor]) }
    if cagePtr != nil { gl.unmapBuffer(buffers.cages[cursor]) }

    dispatch()
    return (lo.x <= hi.x ? (lo, hi) : nil, casterBounds, casterKeys)
  }

  /// marks the draws whose bounds reach into the camera's slightly widened frustum, nil when there are none, so replays draw exactly as before
  public func cameraVisibility(_ viewProjection: Akari.Matrix4) -> GLuint?
  {
    let count = drawBounds.count / 6
    guard count > 0, drawBounded.count == count else { return nil }

    if buffers.cameraDraws.isEmpty { buffers.cameraDraws = [GLuint](repeating: 0, count: Self.ring) }
    if count > cameraCapacity
    {
      for i in 0 ..< Self.ring
      {
        if buffers.cameraDraws[i] != 0 { gl.deleteBuffer(buffers.cameraDraws[i]) }
        buffers.cameraDraws[i] = gl.createBuffer(usage: LGL_BUFFER_COMPUTE_READ | LGL_BUFFER_MAP_WRITE,
                                                 sizeBytes: GLsizei(count * MemoryLayout<UInt32>.size))
      }

      cameraCapacity = count
    }

    cameraCursor = (cameraCursor + 1) % Self.ring
    let buffer = buffers.cameraDraws[cameraCursor]
    guard buffer != 0, let mask = gl.mapBuffer(buffer)?.assumingMemoryBound(to: UInt32.self) else { return nil }

    let margin: Float = 1.02
    let matrix = viewProjection.simd
    for draw in 0 ..< count
    {
      let b = draw * 6
      let lo = SIMD3(drawBounds[b], drawBounds[b + 1], drawBounds[b + 2])
      let hi = SIMD3(drawBounds[b + 3], drawBounds[b + 4], drawBounds[b + 5])

      // a box is outside when all eight of its corners are past the same plane
      var outside = [Int](repeating: 0, count: 6)
      for corner in 0 ..< 8
      {
        let point = SIMD4(corner & 1 != 0 ? hi.x : lo.x, corner & 2 != 0 ? hi.y : lo.y, corner & 4 != 0 ? hi.z : lo.z, 1)
        let p = matrix * point
        let w = p.w * margin
        if p.x < -w { outside[0] += 1 }
        if p.x > w { outside[1] += 1 }
        if p.y < -w { outside[2] += 1 }
        if p.y > w { outside[3] += 1 }
        if p.z < -w { outside[4] += 1 }
        if p.z > w { outside[5] += 1 }
      }

      let culled = drawBounded[draw] && outside.contains(8)
      mask[draw] = culled ? 0 : 1
    }

    gl.unmapBuffer(buffer)
    return buffer
  }

  private func dispatch()
  {
    let stencilRows = arrays.stencilTargets.count
    if stencilRows > 0, !buffers.cages.isEmpty
    {
      setCount(kernels[.subdivide], stencilRows)
      kernels[.subdivide].bind(buffers.stencilTargets, buffers.stencilStarts, buffers.stencilIndices, buffers.stencilWeights,
                               buffers.cages[cursor], buffers.points[cursor])
      kernels[.subdivide].dispatch((stencilRows + 63) / 64)
    }

    if jointCount > 0
    {
      setCount(kernels[.skin], pointCount)
      kernels[.skin].bind(buffers.skinRanges, buffers.skinWeights, buffers.palettes[cursor], buffers.restPoints,
                          buffers.points[cursor])
      kernels[.skin].dispatch((pointCount + 63) / 64)
    }

    setCount(kernels[.face], faceCount)
    kernels[.face].bind(buffers.faces, buffers.points[cursor], buffers.faceNormals)
    kernels[.face].dispatch((faceCount + 63) / 64)

    setCount(kernels[.point], pointCount)
    kernels[.point].bind(buffers.faceStart, buffers.faceList, buffers.faceNormals, buffers.pointNormals)
    kernels[.point].dispatch((pointCount + 63) / 64)

    setCount(kernels[.emit], cornerCount, flag: hasHistory)
    hasHistory = true
    settled = false
    kernels[.emit].bind(buffers.corners, buffers.uvs, buffers.points[cursor], buffers.pointNormals, buffers.faceNormals,
                        buffers.pointMesh, buffers.transforms[cursor], buffers.vertices, buffers.cornerNormals,
                        buffers.restNormals)
    kernels[.emit].dispatch((cornerCount + 63) / 64)

    guard buffers.shadowVertices != 0 else { return }
    setCount(kernels[.shadow], pointCount)
    kernels[.shadow].bind(buffers.points[cursor], buffers.pointMesh, buffers.transforms[cursor], buffers.shadowVertices)
    kernels[.shadow].dispatch((pointCount + 63) / 64)
  }

  /// records one draw per mesh against a vertex buffer compute fills and returns that buffer, the capture takes both at their unmap
  func record(into capture: OpaquePointer, vertexCount: Int, indices indexData: [Int32]) -> GLuint
  {
    let stride = Akari.Geom.Batch.vertexStride
    let vertices = gl.createBuffer(usage: LGL_BUFFER_VERTEX | LGL_BUFFER_COMPUTE_WRITE | LGL_BUFFER_MAP_WRITE
      | LGL_BUFFER_CAPTURE_ADOPT,
      sizeBytes: GLsizei(max(vertexCount, 1) * stride))
    let indices = gl.createBuffer(usage: LGL_BUFFER_INDEX | LGL_BUFFER_MAP_WRITE | LGL_BUFFER_CAPTURE_ADOPT,
                                  sizeBytes: GLsizei(max(indexData.count, 1) * 4))
    guard vertices != 0, indices != 0 else { return 0 }
    if let p = gl.mapBuffer(indices)
    {
      indexData.withUnsafeBytes { p.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
    }

    gl.bindTexture(target: GL_TEXTURE_2D, texture: 0)
    labgl.captureStart(capture)
    _ = gl.mapBuffer(vertices)
    gl.unmapBuffer(vertices)
    gl.unmapBuffer(indices)

    gl.enable(GL_DEPTH_TEST)
    gl.depthFunc(GLenum(GL_GREATER))
    gl.disable(GL_CULL_FACE)
    gl.frontFace(GL_CCW)

    gl.bindBuffer(target: GL_ARRAY_BUFFER, buffer: vertices)
    gl.bindBuffer(target: GL_ELEMENT_ARRAY_BUFFER, buffer: indices)
    gl.enableClientState(GL_VERTEX_ARRAY)
    gl.enableClientState(GL_COLOR_ARRAY)
    gl.enableClientState(GL_TEXTURE_COORD_ARRAY)
    gl.enableClientState(GL_NORMAL_ARRAY)
    let floatBytes = MemoryLayout<Float>.stride
    gl.vertexPointer(size: 4, type: GL_FLOAT, stride: GLsizei(stride), pointer: .init(bitPattern: 0 * floatBytes))
    gl.colorPointer(size: 4, type: GL_FLOAT, stride: GLsizei(stride), pointer: .init(bitPattern: 4 * floatBytes))
    gl.texCoordPointer(size: 2, type: GL_FLOAT, stride: GLsizei(stride), pointer: .init(bitPattern: 8 * floatBytes))
    gl.normalPointer(type: GL_FLOAT, stride: GLsizei(stride), pointer: .init(bitPattern: 10 * floatBytes))

    // the real bounds arrive per frame, these only keep the capture from scanning.
    let unbounded: [Float] = [-1e30, -1e30, -1e30, 1e30, 1e30, 1e30]
    for mesh in meshes where !undrawn.contains(mesh.key)
    {
      unbounded.withUnsafeBufferPointer { labgl.captureNextDrawBounds($0.baseAddress!) }
      gl.drawElements(mode: GL_TRIANGLES,
                      count: Int32(mesh.cornerCount),
                      type: GL_UNSIGNED_INT,
                      indices: .init(bitPattern: mesh.cornerBase * 4))
    }

    gl.disableClientState(GL_NORMAL_ARRAY)
    gl.disableClientState(GL_TEXTURE_COORD_ARRAY)
    gl.disableClientState(GL_COLOR_ARRAY)
    gl.disableClientState(GL_VERTEX_ARRAY)
    gl.bindBuffer(target: GL_ARRAY_BUFFER, buffer: 0)
    gl.bindBuffer(target: GL_ELEMENT_ARRAY_BUFFER, buffer: 0)
    labgl.captureStop()
    return vertices
  }

  /// the first of any meshes sharing an id.
  static func unique(_ meshes: [Akari.Geom.Recorder.RawMesh]) -> [Akari.Geom.Recorder.RawMesh]
  {
    var seen = Set<UInt64>()
    return meshes.filter { seen.insert($0.key).inserted }
  }

  /// zeroes the motion of a frame nothing deformed in, once.
  public func settle()
  {
    guard !settled, hasHistory, kernels[.settle].isBuilt, buffers.vertices != 0, cornerCount > 0 else { return }
    settled = true
    setCount(kernels[.settle], cornerCount)
    kernels[.settle].bind(buffers.vertices)
    kernels[.settle].dispatch((cornerCount + 63) / 64)
  }

  private func setCount(_ kernel: Akari.ComputeKernel, _ count: Int, flag: Bool = false)
  {
    kernel.set(.params, SIMD4<Int32>(Int32(count), flag ? 1 : 0, 0, 0))
  }

  /// everything but `vertices`, which the capture owns and frees on its clear.
  func releaseBuffers()
  {
    for buffer in [buffers.faces, buffers.corners, buffers.uvs, buffers.faceStart, buffers.faceList, buffers.pointMesh, buffers.faceNormals, buffers.pointNormals,
                   buffers.cornerNormals, buffers.restNormals,
                   buffers.restPoints, buffers.skinRanges, buffers.skinWeights,
                   buffers.stencilTargets, buffers.stencilStarts, buffers.stencilIndices, buffers.stencilWeights]
      + buffers.points + buffers.transforms + buffers.palettes + buffers.cages + buffers.glassDraws + buffers.cameraDraws where buffer != 0
    {
      gl.deleteBuffer(buffer)
    }

    buffers.faces = 0; buffers.corners = 0; buffers.uvs = 0; buffers.faceStart = 0; buffers.faceList = 0; buffers.pointMesh = 0
    buffers.faceNormals = 0; buffers.pointNormals = 0; buffers.cornerNormals = 0; buffers.restNormals = 0; buffers.points = []; buffers.transforms = []; buffers.vertices = 0; buffers.shadowVertices = 0
    buffers.restPoints = 0; buffers.skinRanges = 0; buffers.skinWeights = 0; buffers.palettes = []
    buffers.stencilTargets = 0; buffers.stencilStarts = 0; buffers.stencilIndices = 0; buffers.stencilWeights = 0; buffers.cages = []
    buffers.glassDraws = []; glassDraws = 0; written = []
    buffers.cameraDraws = []; cameraCapacity = 0
    pointCount = 0; faceCount = 0; cornerCount = 0; jointCount = 0; cagePointCount = 0
    capacities = [:]
  }

  func ensureKernels() -> Bool
  {
    if kernels.isEmpty
    {
      kernels = .precompile()
      _ = kernels.wait()
    }

    return kernels.allBuilt
  }
}
