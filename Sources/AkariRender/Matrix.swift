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

public extension Akari
{
  /// A 4x4 matrix as 16 row-major floats.
  struct Matrix4: Sendable
  {
    public var m: [Float]
    public init(_ m: [Float])
    {
      self.m = m.count == 16 ? m : Array(repeating: 0, count: 16)
    }

    public static let identity = Matrix4([1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1])

    /// Inverse via Gauss-Jordan elimination.
    public func inverse() -> Matrix4
    {
      var a = m
      var inv: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
      for col in 0 ..< 4
      {
        var pivot = col
        var best = abs(a[col * 4 + col])
        for r in (col + 1) ..< 4 where abs(a[r * 4 + col]) > best
        {
          best = abs(a[r * 4 + col]); pivot = r
        }
        if best < 1e-9 { return Matrix4(Array(repeating: 0, count: 16)) }
        if pivot != col
        {
          for k in 0 ..< 4
          {
            a.swapAt(col * 4 + k, pivot * 4 + k)
            inv.swapAt(col * 4 + k, pivot * 4 + k)
          }
        }
        let d = a[col * 4 + col]
        for k in 0 ..< 4
        {
          a[col * 4 + k] /= d; inv[col * 4 + k] /= d
        }
        for r in 0 ..< 4 where r != col
        {
          let f = a[r * 4 + col]
          if f == 0 { continue }
          for k in 0 ..< 4
          {
            a[r * 4 + k] -= f * a[col * 4 + k]; inv[r * 4 + k] -= f * inv[col * 4 + k]
          }
        }
      }
      return Matrix4(inv)
    }

    /// Composed transform, `rhs` applies first.
    public static func * (lhs: Matrix4, rhs: Matrix4) -> Matrix4
    {
      var out = [Float](repeating: 0, count: 16)
      for c in 0 ..< 4
      {
        for r in 0 ..< 4
        {
          var sum: Float = 0
          for k in 0 ..< 4
          {
            sum += lhs[k, r] * rhs[c, k]
          }
          out[c * 4 + r] = sum
        }
      }
      return Matrix4(out)
    }

    public subscript(column: Int, row: Int) -> Float
    {
      m[column * 4 + row]
    }

    /// Applies the transform to a point, dividing through by w.
    public func transform(_ p: SIMD3<Float>) -> SIMD3<Float>
    {
      let x = self[0, 0] * p.x + self[1, 0] * p.y + self[2, 0] * p.z + self[3, 0]
      let y = self[0, 1] * p.x + self[1, 1] * p.y + self[2, 1] * p.z + self[3, 1]
      let z = self[0, 2] * p.x + self[1, 2] * p.y + self[2, 2] * p.z + self[3, 2]
      let w = self[0, 3] * p.x + self[1, 3] * p.y + self[2, 3] * p.z + self[3, 3]
      return abs(w) > 1e-9 ? SIMD3(x, y, z) / w : SIMD3(x, y, z)
    }

    /// Right handed view matrix looking from `eye` toward `target`.
    public static func lookAt(eye: SIMD3<Float>, target: SIMD3<Float>, up: SIMD3<Float>) -> Matrix4
    {
      let f = Akari.Matrix.normalize(target - eye)
      let s = Akari.Matrix.normalize(Akari.Matrix.cross(f, up))
      let u = Akari.Matrix.cross(s, f)
      return Matrix4([
        s.x, u.x, -f.x, 0,
        s.y, u.y, -f.y, 0,
        s.z, u.z, -f.z, 0,
        -Akari.Matrix.dot(s, eye), -Akari.Matrix.dot(u, eye), Akari.Matrix.dot(f, eye), 1
      ])
    }

    public static func ortho(left: Float, right: Float, bottom: Float, top: Float,
                             near: Float, far: Float) -> Matrix4
    {
      let rl = right - left
      let tb = top - bottom
      let fn = far - near
      guard abs(rl) > 1e-9, abs(tb) > 1e-9, abs(fn) > 1e-9 else { return .identity }
      return Matrix4([
        2 / rl, 0, 0, 0,
        0, 2 / tb, 0, 0,
        0, 0, -2 / fn, 0,
        -(right + left) / rl, -(top + bottom) / tb, -(far + near) / fn, 1
      ])
    }

    public static func translation(_ t: SIMD3<Float>) -> Matrix4
    {
      Matrix4([1, 0, 0, 0,
               0, 1, 0, 0,
               0, 0, 1, 0,
               t.x, t.y, t.z, 1])
    }

    /// Maps clip space onto an atlas sub rect, `origin` and `size` in UV.
    public static func atlasRect(origin: SIMD2<Float>, size: SIMD2<Float>) -> Matrix4
    {
      Matrix4([
        0.5 * size.x, 0, 0, 0,
        0, 0.5 * size.y, 0, 0,
        0, 0, 0.5, 0,
        origin.x + 0.5 * size.x, origin.y + 0.5 * size.y, 0.5, 1
      ])
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
