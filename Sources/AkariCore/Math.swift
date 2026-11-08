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

public extension Akari
{
  /// Scalar math shared by the engine and the settings it renders.
  ///
  /// This is required because unfortunatley, simd.h is not available
  /// outside of Apple platforms, so we provide all the simd shading
  /// math utility functions that Akari needs here so all platforms
  /// use the same unified shading math.
  enum Math {}
}

public extension Akari.Math
{
  /// Computes the element-wise minimum of two SIMD3 vectors.
  @inlinable
  static func min<T: SIMDScalar & Comparable>(_ a: SIMD3<T>, _ b: SIMD3<T>) -> SIMD3<T>
  {
    pointwiseMin(a, b)
  }

  /// Computes the element-wise maximum of two SIMD3 vectors.
  @inlinable
  static func max<T: SIMDScalar & Comparable>(_ a: SIMD3<T>, _ b: SIMD3<T>) -> SIMD3<T>
  {
    pointwiseMax(a, b)
  }

  /// `value` limited to `lower ... upper`.
  @inlinable
  static func clamp<T: SIMDScalar & Comparable>(_ value: SIMD3<T>, _ lower: SIMD3<T>, _ upper: SIMD3<T>) -> SIMD3<T>
  {
    Self.min(Self.max(value, lower), upper)
  }

  /// `value` limited to `lower ... upper`.
  @inlinable
  static func clamp<Value: Comparable>(_ value: Value, _ lower: Value, _ upper: Value) -> Value
  {
    Swift.min(Swift.max(value, lower), upper)
  }

  /// `value` limited to `range`.
  @inlinable
  static func clamp<Value: Comparable>(_ value: Value, to range: ClosedRange<Value>) -> Value
  {
    clamp(value, range.lowerBound, range.upperBound)
  }

  /// `value` limited to `0 ... 1`.
  @inlinable
  static func saturate(_ value: Float) -> Float
  {
    clamp(value, 0, 1)
  }

  /// Linear interpolation from `a` to `b` by `t`.
  @inlinable
  static func mix(_ a: Float, _ b: Float, _ t: Float) -> Float
  {
    a + (b - a) * t
  }

  /// Hermite interpolation of `x` between `edge0` and `edge1`.
  @inlinable
  static func smoothstep(_ edge0: Float, _ edge1: Float, _ x: Float) -> Float
  {
    guard edge0 != edge1 else { return x < edge0 ? 0 : 1 }
    let t = saturate((x - edge0) / (edge1 - edge0))
    return t * t * (3 - 2 * t)
  }

  /// `degrees` in radians.
  @inlinable
  static func radians(_ degrees: Float) -> Float
  {
    degrees * .pi / 180
  }

  /// `radians` in degrees.
  @inlinable
  static func degrees(_ radians: Float) -> Float
  {
    radians * 180 / .pi
  }

  /// The squared length of `v`.
  @inlinable
  static func lengthSquared<T: FloatingPoint & SIMDScalar>(_ v: SIMD3<T>) -> T
  {
    (v * v).sum()
  }

  /// The length of `v`.
  @inlinable
  static func length<T: FloatingPoint & SIMDScalar>(_ v: SIMD3<T>) -> T
  {
    lengthSquared(v).squareRoot()
  }

  /// `v` scaled to unit length, or unchanged when it is (nearly) zero.
  @inlinable
  static func normalize<T: FloatingPoint & SIMDScalar>(_ v: SIMD3<T>) -> SIMD3<T>
  {
    let length = length(v)
    let epsilon = T.ulpOfOne * 10

    return length > epsilon ? v / length : v
  }

  /// The dot product of `a` and `b`.
  @inlinable
  static func dot<T: FloatingPoint & SIMDScalar>(_ a: SIMD3<T>, _ b: SIMD3<T>) -> T
  {
    (a * b).sum()
  }

  /// The cross product of `a` and `b`.
  @inlinable
  static func cross<T: FloatingPoint & SIMDScalar>(_ a: SIMD3<T>, _ b: SIMD3<T>) -> SIMD3<T>
  {
    SIMD3(a.y * b.z - a.z * b.y,
          a.z * b.x - a.x * b.z,
          a.x * b.y - a.y * b.x)
  }

  /// The `index`th value of the Halton sequence in `base`, in `0 ..< 1`.
  static func halton(_ index: UInt64, base: UInt64) -> Float
  {
    guard base > 1 else { return 0 }
    var result: Float = 0
    var fraction: Float = 1
    var i = index
    while i > 0
    {
      fraction /= Float(base)
      result += fraction * Float(i % base)
      i /= base
    }

    return result
  }
}
