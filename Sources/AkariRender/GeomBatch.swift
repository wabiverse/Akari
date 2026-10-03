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

public extension Akari.Geom
{
  /// Accumulates packed interleaved vertex/index data across meshes and
  /// flushes to a GPU buffer pair + draw call whenever either buffer would
  /// overflow, or on an explicit final `draw()`.
  final class Batch
  {
    public static let vertexFloats = 14
    public static let vertexStride = vertexFloats * MemoryLayout<Float>.stride // 56

    private let maxVerts: Int
    private let maxIndices: Int
    /// The buffer pair being filled, mapped while appending and handed
    /// to the recording capture on `draw()`.
    private var vb: GLuint = 0
    private var ib: GLuint = 0
    private var vertBuf: UnsafeMutablePointer<Float>?
    private var idxBuf: UnsafeMutablePointer<Int32>?
    private var vOff = 0
    private var iOff = 0
    /// Index ranges drawn separately so the shadow pass can cull by chunk.
    private static let chunkIndices = 6000
    private var chunkStarts: [Int] = [0]
    /// World bounds per chunk, min then max.
    private var chunkBounds: [Float] = Batch.emptyBounds
    private static let emptyBounds: [Float] = [.greatestFiniteMagnitude, .greatestFiniteMagnitude,
                                               .greatestFiniteMagnitude, -.greatestFiniteMagnitude,
                                               -.greatestFiniteMagnitude, -.greatestFiniteMagnitude]
    private var boundsMin = SIMD3<Float>(repeating: .greatestFiniteMagnitude)
    private var boundsMax = SIMD3<Float>(repeating: -.greatestFiniteMagnitude)
    /// One world AABB per appended mesh, min then max, six floats each.
    public private(set) var casterBounds: [Float] = []
    /// Per caster, a key that changes whenever it moves or deforms.
    public private(set) var casterKeys: [UInt64] = []

    public init(estimatedTriangles: Int)
    {
      // one vert and one index per triangle corner.
      let worstCase = max(estimatedTriangles, 1) * 3

      maxVerts = min(worstCase, Int(Int32.max) / Self.vertexStride)
      maxIndices = min(worstCase, Int(Int32.max) / MemoryLayout<Int32>.stride)
    }

    deinit
    {
      // never drawn, so no capture took them.
      if vb != 0 { gl.deleteBuffer(vb) }
      if ib != 0 { gl.deleteBuffer(ib) }
    }

    private var vertexCount: Int
    {
      vOff / Self.vertexFloats
    }

    public var indexCount: Int
    {
      iOff
    }

    /// World space bounds of everything appended so far,
    /// `nil` until the first vertex lands.
    public var worldBounds: (min: SIMD3<Float>, max: SIMD3<Float>)?
    {
      boundsMin.x <= boundsMax.x ? (boundsMin, boundsMax) : nil
    }

    private func ensureBuffers() -> Bool
    {
      if vertBuf != nil, idxBuf != nil { return true }
      vb = gl.createBuffer(usage: LGL_BUFFER_VERTEX | LGL_BUFFER_MAP_WRITE | LGL_BUFFER_CAPTURE_ADOPT,
                           sizeBytes: GLsizei(maxVerts * Self.vertexStride))
      ib = gl.createBuffer(usage: LGL_BUFFER_INDEX | LGL_BUFFER_MAP_WRITE | LGL_BUFFER_CAPTURE_ADOPT,
                           sizeBytes: GLsizei(maxIndices * MemoryLayout<Int32>.stride))
      guard
        let v = gl.mapBuffer(vb),
        let i = gl.mapBuffer(ib)
      else { return false }
      vertBuf = v.assumingMemoryBound(to: Float.self)
      idxBuf = i.assumingMemoryBound(to: Int32.self)
      return true
    }

    /// Appends one mesh's local-space vertex/index data,
    /// transforming positions/normals into world space
    /// as it writes straight into the GPU buffers.
    public func append(localVerts: [Float], localIndices: [Int32],
                       worldMatrix m: UnsafePointer<Float>,
                       normalMatrix n: [Float],
                       primId: Int32,
                       key: UInt64)
    {
      let vertCount = localVerts.count / 8
      if vOff + vertCount * Self.vertexFloats > maxVerts * Self.vertexFloats || iOff + localIndices.count > maxIndices
      {
        draw()
      }
      guard ensureBuffers(), let vertBuf, let idxBuf else { return }

      let baseVertex = Int32(vertexCount)
      let (m0, m1, m2, m4, m5, m6) = (m[0], m[1], m[2], m[4], m[5], m[6])
      let (m8, m9, m10, m12, m13, m14) = (m[8], m[9], m[10], m[12], m[13], m[14])
      let (n0, n1, n2, n3, n4, n5, n6, n7, n8) = (n[0], n[1], n[2], n[3], n[4], n[5], n[6], n[7], n[8])
      // materials come from the atlas, so the color slot carries the prim id.
      let id = Float(primId)

      var minX = Float.greatestFiniteMagnitude, minY = minX, minZ = minX
      var maxX = -Float.greatestFiniteMagnitude, maxY = maxX, maxZ = maxX
      localVerts.withUnsafeBufferPointer
      { src in
        var d = vertBuf + vOff
        for v in 0 ..< vertCount
        {
          let s = v * 8
          let px = src[s + 0], py = src[s + 1], pz = src[s + 2]
          let nx = src[s + 3], ny = src[s + 4], nz = src[s + 5]

          let wx = m0 * px + m4 * py + m8 * pz + m12
          let wy = m1 * px + m5 * py + m9 * pz + m13
          let wz = m2 * px + m6 * py + m10 * pz + m14
          minX = wx < minX ? wx : minX; maxX = wx > maxX ? wx : maxX
          minY = wy < minY ? wy : minY; maxY = wy > maxY ? wy : maxY
          minZ = wz < minZ ? wz : minZ; maxZ = wz > maxZ ? wz : maxZ

          d[0] = wx
          d[1] = wy
          d[2] = wz
          d[3] = 1

          d[4] = id
          d[5] = 0
          d[6] = 0
          d[7] = 1

          d[8] = src[s + 6]
          d[9] = src[s + 7]

          d[10] = n0 * nx + n1 * ny + n2 * nz
          d[11] = n3 * nx + n4 * ny + n5 * nz
          d[12] = n6 * nx + n7 * ny + n8 * nz
          d[13] = 0

          d += Self.vertexFloats
        }
      }
      vOff += vertCount * Self.vertexFloats

      let hasBounds = minX <= maxX
      if hasBounds
      {
        boundsMin = pointwiseMin(boundsMin, SIMD3(minX, minY, minZ))
        boundsMax = pointwiseMax(boundsMax, SIMD3(maxX, maxY, maxZ))
        casterBounds += [minX, minY, minZ, maxX, maxY, maxZ]
        casterKeys.append(key)
      }

      localIndices.withUnsafeBufferPointer
      { src in
        let dst = idxBuf + iOff
        for j in 0 ..< src.count
        {
          dst[j] = src[j] &+ baseVertex
        }
      }
      if iOff - chunkStarts[chunkStarts.count - 1] >= Self.chunkIndices
      {
        chunkStarts.append(iOff)
        chunkBounds += Self.emptyBounds
      }
      if hasBounds
      {
        let o = chunkBounds.count - 6
        chunkBounds[o + 0] = min(chunkBounds[o + 0], minX)
        chunkBounds[o + 1] = min(chunkBounds[o + 1], minY)
        chunkBounds[o + 2] = min(chunkBounds[o + 2], minZ)
        chunkBounds[o + 3] = max(chunkBounds[o + 3], maxX)
        chunkBounds[o + 4] = max(chunkBounds[o + 4], maxY)
        chunkBounds[o + 5] = max(chunkBounds[o + 5], maxZ)
      }
      iOff += localIndices.count
    }

    /// Hands the filled buffer pair to the recording capture and issues
    /// one draw per chunk, then resets for the next batch.
    public func draw()
    {
      guard vOff > 0 else { return }

      // unmapping is where the recording capture takes the buffers over.
      gl.unmapBuffer(vb)
      gl.unmapBuffer(ib)

      gl.bindBuffer(target: GL_ARRAY_BUFFER, buffer: vb)
      gl.bindBuffer(target: GL_ELEMENT_ARRAY_BUFFER, buffer: ib)

      gl.enableClientState(GL_VERTEX_ARRAY)
      gl.enableClientState(GL_COLOR_ARRAY)
      gl.enableClientState(GL_TEXTURE_COORD_ARRAY)
      gl.enableClientState(GL_NORMAL_ARRAY)

      // float offsets into the interleaved vertex `append` writes.
      let stride = GLsizei(Self.vertexStride)
      let floatBytes = MemoryLayout<Float>.stride
      gl.vertexPointer(size: 4, type: GL_FLOAT, stride: stride, pointer: .init(bitPattern: 0 * floatBytes))
      gl.colorPointer(size: 4, type: GL_FLOAT, stride: stride, pointer: .init(bitPattern: 4 * floatBytes))
      gl.texCoordPointer(size: 2, type: GL_FLOAT, stride: stride, pointer: .init(bitPattern: 8 * floatBytes))
      gl.normalPointer(type: GL_FLOAT, stride: stride, pointer: .init(bitPattern: 10 * floatBytes))

      for (c, start) in chunkStarts.enumerated()
      {
        let end = c + 1 < chunkStarts.count ? chunkStarts[c + 1] : iOff
        guard end > start else { continue }
        chunkBounds.withUnsafeBufferPointer { labgl.captureNextDrawBounds($0.baseAddress! + c * 6) }
        gl.drawElements(mode: GL_TRIANGLES,
                        count: Int32(end - start),
                        type: GL_UNSIGNED_INT,
                        indices: .init(bitPattern: start * MemoryLayout<Int32>.stride))
      }

      gl.disableClientState(GL_NORMAL_ARRAY)
      gl.disableClientState(GL_TEXTURE_COORD_ARRAY)
      gl.disableClientState(GL_COLOR_ARRAY)
      gl.disableClientState(GL_VERTEX_ARRAY)

      gl.bindBuffer(target: GL_ARRAY_BUFFER, buffer: 0)
      gl.bindBuffer(target: GL_ELEMENT_ARRAY_BUFFER, buffer: 0)

      vb = 0
      ib = 0
      vertBuf = nil
      idxBuf = nil
      vOff = 0
      iOff = 0
      chunkStarts = [0]
      chunkBounds = Self.emptyBounds
    }
  }
}
