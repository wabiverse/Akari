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
import HdAkari
import simd

public extension Akari
{
  /// A 4x4 matrix, column-major.
  struct Matrix4: Sendable
  {
    public var simd: simd_float4x4

    public init(_ simd: simd_float4x4)
    {
      self.simd = simd
    }

    public init(_ m: [Float])
    {
      simd = m.count == 16
        ? m.withUnsafeBytes { $0.loadUnaligned(as: simd_float4x4.self) }
        : simd_float4x4()
    }

    /// A copy of the 16 floats, for APIs that take an array.
    public var m: [Float]
    {
      withUnsafeFloats(Array.init)
    }

    public func withUnsafeFloats<R>(_ body: (UnsafeBufferPointer<Float>) throws -> R) rethrows -> R
    {
      try withUnsafeBytes(of: simd) { try body($0.bindMemory(to: Float.self)) }
    }

    public static let identity = Matrix4(matrix_identity_float4x4)

    /// Zero for a singular matrix.
    public func inverse() -> Matrix4
    {
      let inv = Matrix4(simd.inverse)
      return inv.withUnsafeFloats { $0.allSatisfy(\.isFinite) } ? inv : Matrix4(simd_float4x4())
    }

    /// Composed transform, `rhs` applies first.
    public static func * (lhs: Matrix4, rhs: Matrix4) -> Matrix4
    {
      Matrix4(lhs.simd * rhs.simd)
    }

    public subscript(column: Int, row: Int) -> Float
    {
      simd[column][row]
    }

    /// Applies the transform to a point, dividing through by w.
    public func transform(_ p: SIMD3<Float>) -> SIMD3<Float>
    {
      let v = simd * SIMD4(p, 1)
      return abs(v.w) > 1e-9 ? SIMD3(v.x, v.y, v.z) / v.w : SIMD3(v.x, v.y, v.z)
    }

    /// Right handed view matrix looking from `eye` toward `target`.
    public static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> Matrix4
    {
      let f = Akari.Matrix.normalize(target - eye)
      let s = Akari.Matrix.normalize(Akari.Matrix.cross(f, up))
      let u = Akari.Matrix.cross(s, f)
      return Matrix4(simd_float4x4(columns: (
        SIMD4(s.x, u.x, -f.x, 0),
        SIMD4(s.y, u.y, -f.y, 0),
        SIMD4(s.z, u.z, -f.z, 0),
        SIMD4(-Akari.Matrix.dot(s, eye), -Akari.Matrix.dot(u, eye), Akari.Matrix.dot(f, eye), 1)
      )))
    }

    public static func ortho(left: Float, right: Float, bottom: Float, top: Float,
                             near: Float, far: Float) -> Matrix4
    {
      let rl = right - left
      let tb = top - bottom
      let fn = far - near
      guard abs(rl) > 1e-9, abs(tb) > 1e-9, abs(fn) > 1e-9 else { return .identity }
      return Matrix4(simd_float4x4(columns: (
        SIMD4(2 / rl, 0, 0, 0),
        SIMD4(0, 2 / tb, 0, 0),
        SIMD4(0, 0, -2 / fn, 0),
        SIMD4(-(right + left) / rl, -(top + bottom) / tb, -(far + near) / fn, 1)
      )))
    }

    public static func perspective(left: Float, right: Float, bottom: Float, top: Float,
                                   near: Float, far: Float) -> Matrix4
    {
      let rl = right - left
      let tb = top - bottom
      let fn = far - near
      guard abs(rl) > 1e-9, abs(tb) > 1e-9, abs(fn) > 1e-9, near > 0 else { return .identity }
      return Matrix4(simd_float4x4(columns: (
        SIMD4(2 * near / rl, 0, 0, 0),
        SIMD4(0, 2 * near / tb, 0, 0),
        SIMD4((right + left) / rl, (top + bottom) / tb, -(far + near) / fn, -1),
        SIMD4(0, 0, -2 * far * near / fn, 0)
      )))
    }

    public static func translation(_ t: SIMD3<Float>) -> Matrix4
    {
      Matrix4(simd_float4x4(columns: (
        SIMD4(1, 0, 0, 0),
        SIMD4(0, 1, 0, 0),
        SIMD4(0, 0, 1, 0),
        SIMD4(t.x, t.y, t.z, 1)
      )))
    }

    /// Maps clip space onto an atlas sub rect, `origin` and `size` in UV.
    public static func atlasRect(origin: SIMD2<Float>, size: SIMD2<Float>) -> Matrix4
    {
      Matrix4(simd_float4x4(columns: (
        SIMD4(0.5 * size.x, 0, 0, 0),
        SIMD4(0, 0.5 * size.y, 0, 0),
        SIMD4(0, 0, 0.5, 0),
        SIMD4(origin.x + 0.5 * size.x, origin.y + 0.5 * size.y, 0.5, 1)
      )))
    }
  }
}

public extension Akari
{
  /// Akari matrix math utilities.
  enum Matrix
  {
    static func normalize(_ v: SIMD3<Float>) -> SIMD3<Float>
    {
      let length = (v * v).sum().squareRoot()
      return length > 1e-9 ? v / length : v
    }

    static func cross(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> SIMD3<Float>
    {
      SIMD3(a.y * b.z - a.z * b.y,
            a.z * b.x - a.x * b.z,
            a.x * b.y - a.y * b.x)
    }

    static func dot(_ a: SIMD3<Float>, _ b: SIMD3<Float>) -> Float
    {
      (a * b).sum()
    }

    /// Determinant of the 3x3 upper-left of a row-major 4x4. Goes
    /// negative when the transform mirrors, flipping its winding.
    static func determinant3x3(_ m: UnsafePointer<Float>) -> Float
    {
      m[0] * (m[5] * m[10] - m[6] * m[9])
        + m[1] * (m[6] * m[8] - m[4] * m[10])
        + m[2] * (m[4] * m[9] - m[5] * m[8])
    }

    /// Inverse transpose of the 3x3 upper-left of a row-major 4x4,
    /// returned as a column-major 3x3 (9 floats). Used to bake per
    /// mesh model normals into world space during geometry recording.
    static func normalMatrix3x3(_ m: UnsafePointer<Float>) -> [Float]
    {
      // extract 3x3 into column-major.
      let a0 = m[0]; let a1 = m[4]; let a2 = m[8] // column 0
      let a3 = m[1]; let a4 = m[5]; let a5 = m[9] // column 1
      let a6 = m[2]; let a7 = m[6]; let a8 = m[10] // column 2

      let det = Double(a0 * (a4 * a8 - a5 * a7) - a3 * (a1 * a8 - a2 * a7) + a6 * (a1 * a5 - a2 * a4))
      guard abs(det) > 1e-8 else { return [1, 0, 0, 0, 1, 0, 0, 0, 1] }
      let inv = 1.0 / det

      // inverse transpose, column-major layout.
      return [
        Float(inv * Double(a4 * a8 - a5 * a7)),
        Float(inv * Double(a6 * a5 - a3 * a8)),
        Float(inv * Double(a3 * a7 - a6 * a4)),
        Float(inv * Double(a2 * a7 - a8 * a1)),
        Float(inv * Double(a0 * a8 - a2 * a6)),
        Float(inv * Double(a6 * a1 - a0 * a7)),
        Float(inv * Double(a1 * a5 - a4 * a2)),
        Float(inv * Double(a3 * a2 - a0 * a5)),
        Float(inv * Double(a0 * a4 - a1 * a3))
      ]
    }
  }
}
