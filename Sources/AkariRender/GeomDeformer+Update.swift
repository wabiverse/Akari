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

extension Akari.Geom.Deformer
{
  /// Uploads this frame's points and matrices and deforms on the GPU.
  /// Returns the bounds, per mesh caster bounds and keys, in draw order.
  public func update(_ meshes: [Akari.Geom.Recorder.RawMesh]) -> (bounds: (min: SIMD3<Float>, max: SIMD3<Float>)?,
                                                       casterBounds: [Float], casterKeys: [UInt64])
  {
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

    let indexOf = Dictionary(meshes.indices.map { (meshes[$0].key, $0) }, uniquingKeysWith: { a, _ in a })
    var casterBounds: [Float] = []
    var casterKeys: [UInt64] = []
    casterBounds.reserveCapacity(self.meshes.count * 6)
    var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo

    for (index, laidOut) in self.meshes.enumerated()
    {
      // a mesh laid out but not given this frame collapses to a point, so it draws nothing.
      guard let i = indexOf[laidOut.key]
      else
      {
        (xfPtr + index * Self.xfStride).update(repeating: 0, count: Self.xfStride)
        xfPtr[index * Self.xfStride + 37] = 1
        continue
      }

      var local = [Float](repeating: 0, count: 6)
      if laidOut.jointCount > 0, let palettePtr, meshes[i].skinPalette.count == laidOut.jointCount * 12
      {
        meshes[i].skinPalette.withUnsafeBufferPointer
        {
          (palettePtr + laidOut.jointBase * 12).update(from: $0.baseAddress!, count: $0.count)
        }

        local = meshes[i].skinBounds
      }
      else
      {
        // its palette changed size since the layout, relay out rather than skin with the old one.
        if laidOut.jointCount > 0 { relayout = true }
        Pixar.HdAkariCopyPoints(meshes[i].points, pointPtr + laidOut.pointBase * 3, &local)
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
      casterBounds += [wlo.x, wlo.y, wlo.z, whi.x, whi.y, whi.z]
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
    if palettePtr != nil { gl.unmapBuffer(buffers.palettes[cursor]) }

    dispatch()
    return (lo.x <= hi.x ? (lo, hi) : nil, casterBounds, casterKeys)
  }

  private func dispatch()
  {
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
                        buffers.pointMesh, buffers.transforms[cursor], buffers.vertices)
    kernels[.emit].dispatch((cornerCount + 63) / 64)

    guard buffers.shadowVertices != 0 else { return }
    setCount(kernels[.shadow], pointCount)
    kernels[.shadow].bind(buffers.points[cursor], buffers.pointMesh, buffers.transforms[cursor], buffers.shadowVertices)
    kernels[.shadow].dispatch((pointCount + 63) / 64)
  }

  /// Records one draw per mesh, by its corner range of `indices`, against a vertex
  /// buffer compute fills, the capture takes both over at their unmap. Returns that buffer.
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

  /// The first of any meshes sharing an id.
  static func unique(_ meshes: [Akari.Geom.Recorder.RawMesh]) -> [Akari.Geom.Recorder.RawMesh]
  {
    var seen = Set<UInt64>()
    return meshes.filter { seen.insert($0.key).inserted }
  }

  /// Zeroes the motion of a frame nothing deformed in, once.
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

  /// Everything but `vertices`, which the capture owns and frees on its clear.
  func releaseBuffers()
  {
    for buffer in [buffers.faces, buffers.corners, buffers.uvs, buffers.faceStart, buffers.faceList, buffers.pointMesh, buffers.faceNormals, buffers.pointNormals,
                   buffers.restPoints, buffers.skinRanges, buffers.skinWeights]
      + buffers.points + buffers.transforms + buffers.palettes where buffer != 0
    {
      gl.deleteBuffer(buffer)
    }

    buffers.faces = 0; buffers.corners = 0; buffers.uvs = 0; buffers.faceStart = 0; buffers.faceList = 0; buffers.pointMesh = 0
    buffers.faceNormals = 0; buffers.pointNormals = 0; buffers.points = []; buffers.transforms = []; buffers.vertices = 0; buffers.shadowVertices = 0
    buffers.restPoints = 0; buffers.skinRanges = 0; buffers.skinWeights = 0; buffers.palettes = []
    pointCount = 0; faceCount = 0; cornerCount = 0; jointCount = 0
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
