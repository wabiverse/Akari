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
    public static let vertexStride = vertexFloats * MemoryLayout<Float>.size // 56

    private let maxVerts: Int
    private let maxIndices: Int
    private let vertBuf: UnsafeMutableBufferPointer<Float>
    private let idxBuf: UnsafeMutableBufferPointer<Int32>
    private var vOff = 0
    private var iOff = 0

    public init(estimatedTriangles: Int)
    {
      let worstCaseVerts = max(estimatedTriangles, 1) * 3
      let worstCaseIndices = max(estimatedTriangles, 1) * 3

      maxVerts = min(worstCaseVerts, Int(Int32.max) / Batch.vertexStride)
      maxIndices = min(worstCaseIndices, Int(Int32.max) / MemoryLayout<Int32>.size)
      vertBuf = .allocate(capacity: maxVerts * Self.vertexFloats)
      idxBuf = .allocate(capacity: maxIndices)
    }

    deinit
    {
      vertBuf.deallocate()
      idxBuf.deallocate()
    }

    private var vertexCount: Int
    {
      vOff / Self.vertexFloats
    }

    public var indexCount: Int { iOff }

    /// Appends one mesh's local-space vertex/index data,
    /// transforming positions/normals into world space
    /// as it writes.
    public func append(localVerts: [Float], localIndices: [Int32],
                       worldMatrix m: UnsafePointer<Float>,
                       normalMatrix n: [Float])
    {
      let vertCount = localVerts.count / 8
      if vOff + vertCount * Self.vertexFloats > maxVerts * Self.vertexFloats || iOff + localIndices.count > maxIndices
      {
        draw()
      }

      let baseVertex = Int32(vertexCount)

      for v in 0 ..< vertCount
      {
        let s = v * 8
        let d = vOff + v * Self.vertexFloats
        let px = localVerts[s + 0]; let py = localVerts[s + 1]; let pz = localVerts[s + 2]
        let nx = localVerts[s + 3]; let ny = localVerts[s + 4]; let nz = localVerts[s + 5]
        let uu = localVerts[s + 6]; let vv = localVerts[s + 7]

        vertBuf[d + 0] = m[0] * px + m[4] * py + m[8] * pz + m[12]
        vertBuf[d + 1] = m[1] * px + m[5] * py + m[9] * pz + m[13]
        vertBuf[d + 2] = m[2] * px + m[6] * py + m[10] * pz + m[14]
        vertBuf[d + 3] = 1.0

        vertBuf[d + 4] = 1.0
        vertBuf[d + 5] = 1.0
        vertBuf[d + 6] = 1.0
        vertBuf[d + 7] = 1.0

        vertBuf[d + 8] = uu
        vertBuf[d + 9] = vv

        vertBuf[d + 10] = n[0] * nx + n[1] * ny + n[2] * nz
        vertBuf[d + 11] = n[3] * nx + n[4] * ny + n[5] * nz
        vertBuf[d + 12] = n[6] * nx + n[7] * ny + n[8] * nz

        vertBuf[d + 13] = 0.0
      }
      vOff += vertCount * Self.vertexFloats

      for j in 0 ..< localIndices.count
      {
        idxBuf[iOff + j] = localIndices[j] + baseVertex
      }
      iOff += localIndices.count
    }

    /// Uploads the accumulated batch as one GPU buffer pair
    /// and issues a single draw call, then resets for the
    /// next batch.
    public func draw()
    {
      guard vOff > 0 else { return }
      let vbSize = GLsizei(vOff * MemoryLayout<Float>.stride)
      let ibSize = GLsizei(iOff * MemoryLayout<Int32>.stride)

      let vb = gl.createBuffer(usage: GLuint(LGL_BUFFER_VERTEX | LGL_BUFFER_MAP_WRITE), sizeBytes: vbSize)
      let ib = gl.createBuffer(usage: GLuint(LGL_BUFFER_INDEX | LGL_BUFFER_MAP_WRITE), sizeBytes: ibSize)

      if let vPtr = gl.mapBuffer(vb)
      {
        memcpy(vPtr, vertBuf.baseAddress!, vOff * MemoryLayout<Float>.stride)
        gl.unmapBuffer(vb)
      }
      if let iPtr = gl.mapBuffer(ib)
      {
        memcpy(iPtr, idxBuf.baseAddress!, iOff * MemoryLayout<Int32>.stride)
        gl.unmapBuffer(ib)
      }

      gl.bindBuffer(target: GL_ARRAY_BUFFER, buffer: vb)
      gl.bindBuffer(target: GL_ELEMENT_ARRAY_BUFFER, buffer: ib)

      gl.enableClientState(GL_VERTEX_ARRAY)
      gl.enableClientState(GL_COLOR_ARRAY)
      gl.enableClientState(GL_TEXTURE_COORD_ARRAY)
      gl.enableClientState(GL_NORMAL_ARRAY)

      gl.vertexPointer(size: 4, type: GL_FLOAT, stride: GLsizei(Batch.vertexStride), pointer: UnsafeRawPointer(bitPattern: 0))
      gl.colorPointer(size: 4, type: GL_FLOAT, stride: GLsizei(Batch.vertexStride), pointer: UnsafeRawPointer(bitPattern: 16))
      gl.texCoordPointer(size: 2, type: GL_FLOAT, stride: GLsizei(Batch.vertexStride), pointer: UnsafeRawPointer(bitPattern: 32))
      gl.normalPointer(type: GL_FLOAT, stride: GLsizei(Batch.vertexStride), pointer: UnsafeRawPointer(bitPattern: 40))

      gl.drawElements(mode: GL_TRIANGLES,
                      count: Int32(iOff),
                      type: GL_UNSIGNED_INT,
                      indices: UnsafeRawPointer(bitPattern: 0))

      gl.disableClientState(GL_NORMAL_ARRAY)
      gl.disableClientState(GL_TEXTURE_COORD_ARRAY)
      gl.disableClientState(GL_COLOR_ARRAY)
      gl.disableClientState(GL_VERTEX_ARRAY)

      vOff = 0
      iOff = 0
    }
  }
}
