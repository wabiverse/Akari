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

public extension Akari
{
  /// BC7 compression (one RGBA pair per block, 4 bit indices).
  enum BC7
  {
    /// Bytes a 4x4 block encodes to.
    public static let blockBytes = 16

    private static let weights: [Float] = [0, 4, 9, 13, 17, 21, 26, 30, 34, 38, 43, 47, 51, 55, 60, 64]

    /// Encodes a `width` by `height` region of BGRA8 `pixels`,
    /// as LabGL's 8 bit textures hold them, rows `stride` pixels
    /// apart and both sizes multiples of 4, into `blocks`, a row
    /// of blocks after another.
    public static func encode(_ pixels: UnsafePointer<UInt8>,
                              stride: Int, width: Int, height: Int,
                              into blocks: UnsafeMutablePointer<UInt8>)
    {
      let blocksWide = width / 4
      nonisolated(unsafe) let pixels = pixels, blocks = blocks
      DispatchQueue.concurrentPerform(iterations: height / 4)
      { by in
        withUnsafeTemporaryAllocation(of: SIMD4<Float>.self, capacity: 32)
        { vectors in
          withUnsafeTemporaryAllocation(of: Int32.self, capacity: 32 + 65)
          { ints in
            withUnsafeTemporaryAllocation(of: Float.self, capacity: 16)
            { floats in
              let scratch = Scratch(texels: vectors.baseAddress!, palette: vectors.baseAddress! + 16,
                                    indices: ints.baseAddress!, candidate: ints.baseAddress! + 16,
                                    nearest: ints.baseAddress! + 32, weights: floats.baseAddress!)
              for k in 0 ..< 16 { scratch.weights[k] = weights[k] }
              for v in 0 ... 64 { scratch.nearest[v] = Int32(nearestWeight[v]) }
              for bx in 0 ..< blocksWide
              {
                for i in 0 ..< 16
                {
                  let p = pixels + ((by * 4 + i / 4) * stride + bx * 4 + i % 4) * 4
                  scratch.texels[i] = SIMD4(Float(p[2]), Float(p[1]), Float(p[0]), Float(p[3]))
                }
                encodeBlock(scratch, into: blocks + (by * blocksWide + bx) * blockBytes)
              }
            }
          }
        }
      }
    }

    /// Decodes blocks `encode` wrote back to BGRA8,
    /// rows of `pixels` `stride` pixels apart.
    public static func decode(_ blocks: UnsafePointer<UInt8>,
                              width: Int, height: Int,
                              into pixels: UnsafeMutablePointer<UInt8>,
                              stride: Int)
    {
      let blocksWide = width / 4
      nonisolated(unsafe) let blocks = blocks, pixels = pixels
      DispatchQueue.concurrentPerform(iterations: height / 4)
      { by in
        for bx in 0 ..< blocksWide
        {
          let b = blocks + (by * blocksWide + bx) * blockBytes
          var lo: UInt64 = 0, hi: UInt64 = 0
          for i in 0 ..< 8
          {
            lo |= UInt64(b[i]) << UInt64(8 * i)
            hi |= UInt64(b[8 + i]) << UInt64(8 * i)
          }
          var position = 0
          func take(_ count: Int) -> Int
          {
            var v: UInt64 = 0
            for k in 0 ..< count
            {
              let at = position + k
              let bit = at < 64 ? (lo >> UInt64(at)) & 1 : (hi >> UInt64(at - 64)) & 1
              v |= bit << UInt64(k)
            }
            position += count
            return Int(v)
          }
          let mode = take(7)
          var q0 = SIMD4<Int>.zero, q1 = SIMD4<Int>.zero
          for c in 0 ..< 4
          {
            q0[c] = take(7)
            q1[c] = take(7)
          }
          let e0 = q0 &* 2 &+ take(1), e1 = q1 &* 2 &+ take(1)
          for i in 0 ..< 16
          {
            let index = take(i == 0 ? 3 : 4)
            let w = Int(weights[index])
            let c = mode == 1 << 6 ? (e0 &* (64 - w) &+ e1 &* w &+ 32) &>> 6 : .zero
            let p = pixels + ((by * 4 + i / 4) * stride + bx * 4 + i % 4) * 4
            p[0] = UInt8(clamping: c.z)
            p[1] = UInt8(clamping: c.y)
            p[2] = UInt8(clamping: c.x)
            p[3] = UInt8(clamping: c.w)
          }
        }
      }
    }

    private struct Scratch
    {
      let texels: UnsafeMutablePointer<SIMD4<Float>>
      let palette: UnsafeMutablePointer<SIMD4<Float>>
      let indices: UnsafeMutablePointer<Int32>
      let candidate: UnsafeMutablePointer<Int32>
      let nearest: UnsafeMutablePointer<Int32>
      let weights: UnsafeMutablePointer<Float>
    }

    /// 7 bit endpoints and their p bits,
    /// an 8 bit endpoint being `q * 2 + p`
    /// in every channel.
    private struct Endpoints
    {
      var q0: SIMD4<Float>
      var q1: SIMD4<Float>
      var p0: Float
      var p1: Float

      var e0: SIMD4<Float> { q0 * 2 + p0 }
      var e1: SIMD4<Float> { q1 * 2 + p1 }
    }

    private static func encodeBlock(_ s: Scratch, into out: UnsafeMutablePointer<UInt8>)
    {
      let t = s.texels
      var lo = t[0], hi = t[0], mean = SIMD4<Float>.zero
      for i in 0 ..< 16
      {
        lo = pointwiseMin(lo, t[i])
        hi = pointwiseMax(hi, t[i])
        mean += t[i]
      }
      mean /= 16

      if lo == hi
      {
        let e = quantize(lo)
        for i in 0 ..< 16 { s.indices[i] = 0 }
        write(Endpoints(q0: e.q, q1: e.q, p0: e.p, p1: e.p), s.indices, into: out)
        return
      }

      let axis = principalAxis(t, mean: mean, fallback: hi - lo)
      var tMin = Float.greatestFiniteMagnitude, tMax = -Float.greatestFiniteMagnitude
      for i in 0 ..< 16
      {
        let d = ((t[i] - mean) * axis).sum()
        tMin = min(tMin, d)
        tMax = max(tMax, d)
      }
      var best = endpoints(mean + axis * tMin, mean + axis * tMax)
      let bestError = assign(s, best, into: s.indices)

      // solve for the endpoints that best fit each texel
      // at the weight it got, keep them if they beat the
      // first pass.
      var aa: Float = 0, ab: Float = 0, bb: Float = 0
      var ax = SIMD4<Float>.zero, bx = SIMD4<Float>.zero
      for i in 0 ..< 16
      {
        let w = s.weights[Int(s.indices[i])] / 64
        let a = 1 - w
        aa += a * a
        ab += a * w
        bb += w * w
        ax += a * t[i]
        bx += w * t[i]
      }
      let det = aa * bb - ab * ab
      if abs(det) > 1e-6
      {
        let refit = endpoints((ax * bb - bx * ab) / det, (bx * aa - ax * ab) / det)
        if assign(s, refit, into: s.candidate) < bestError
        {
          best = refit
          for i in 0 ..< 16 { s.indices[i] = s.candidate[i] }
        }
      }

      // the first index's top bit isn't stored, it must be clear.
      if s.indices[0] >= 8
      {
        best = Endpoints(q0: best.q1, q1: best.q0, p0: best.p1, p1: best.p0)
        for i in 0 ..< 16 { s.indices[i] = 15 - s.indices[i] }
      }
      write(best, s.indices, into: out)
    }

    private static func principalAxis(_ t: UnsafeMutablePointer<SIMD4<Float>>, mean: SIMD4<Float>,
                                      fallback: SIMD4<Float>) -> SIMD4<Float>
    {
      var c0 = SIMD4<Float>.zero, c1 = SIMD4<Float>.zero, c2 = SIMD4<Float>.zero, c3 = SIMD4<Float>.zero
      for i in 0 ..< 16
      {
        let d = t[i] - mean
        c0 += d * d.x
        c1 += d * d.y
        c2 += d * d.z
        c3 += d * d.w
      }
      var v = fallback
      for _ in 0 ..< 4
      {
        let next = c0 * v.x + c1 * v.y + c2 * v.z + c3 * v.w
        let length = (next * next).sum().squareRoot()
        guard length > 1e-6 else { break }
        v = next / length
      }
      let length = (v * v).sum().squareRoot()
      return length > 1e-6 ? v / length : .zero
    }

    /// The nearest 7 bit endpoint, and the p bit shared across its channels.
    private static func quantize(_ c: SIMD4<Float>) -> (q: SIMD4<Float>, p: Float)
    {
      let clamped = c.clamped(lowerBound: .zero, upperBound: SIMD4(repeating: 255))
      func fit(_ p: Float) -> (q: SIMD4<Float>, error: Float)
      {
        let q = ((clamped - p) / 2).rounded(.toNearestOrAwayFromZero)
          .clamped(lowerBound: .zero, upperBound: SIMD4(repeating: 127))
        let r = q * 2 + p - clamped
        return (q, (r * r).sum())
      }
      let even = fit(0), odd = fit(1)
      return even.error <= odd.error ? (even.q, 0) : (odd.q, 1)
    }

    private static func endpoints(_ a: SIMD4<Float>, _ b: SIMD4<Float>) -> Endpoints
    {
      let qa = quantize(a), qb = quantize(b)
      return Endpoints(q0: qa.q, q1: qb.q, p0: qa.p, p1: qb.p)
    }

    /// The weight index nearest each of 0...64, for a projection to start its search at.
    private static let nearestWeight: [Int] = (0 ... 64).map
    { v in
      weights.indices.min { abs(weights[$0] - Float(v)) < abs(weights[$1] - Float(v)) }!
    }

    /// Picks each texel's nearest of the 16 colors the endpoints decode to,
    /// searching around where it projects onto them, returns the squared error.
    private static func assign(_ s: Scratch, _ e: Endpoints, into indices: UnsafeMutablePointer<Int32>) -> Float
    {
      let a = e.e0, b = e.e1
      for k in 0 ..< 16
      {
        let w = s.weights[k]
        s.palette[k] = ((a * (64 - w) + b * w + 32) / 64).rounded(.down)
      }
      let axis = b - a
      let length = (axis * axis).sum()
      let scale = length > 0 ? 64 / length : 0
      var total: Float = 0
      for i in 0 ..< 16
      {
        let projected = Int((((s.texels[i] - a) * axis).sum() * scale).rounded())
        let start = Int(s.nearest[min(max(projected, 0), 64)])
        var best = start, bestError = Float.greatestFiniteMagnitude
        for k in max(start - 1, 0) ... min(start + 1, 15)
        {
          let d = s.texels[i] - s.palette[k]
          let error = (d * d).sum()
          if error < bestError
          {
            bestError = error
            best = k
          }
        }
        indices[i] = Int32(best)
        total += bestError
      }
      return total
    }

    private static func write(_ e: Endpoints, _ indices: UnsafeMutablePointer<Int32>,
                              into out: UnsafeMutablePointer<UInt8>)
    {
      var bits = BitWriter()
      bits.put(1 << 6, 7)
      for c in 0 ..< 4
      {
        bits.put(UInt64(e.q0[c]), 7)
        bits.put(UInt64(e.q1[c]), 7)
      }
      bits.put(UInt64(e.p0), 1)
      bits.put(UInt64(e.p1), 1)
      for i in 0 ..< 16
      {
        bits.put(UInt64(indices[i]), i == 0 ? 3 : 4)
      }
      for i in 0 ..< 8
      {
        out[i] = UInt8(truncatingIfNeeded: bits.lo >> UInt64(8 * i))
        out[8 + i] = UInt8(truncatingIfNeeded: bits.hi >> UInt64(8 * i))
      }
    }

    private struct BitWriter
    {
      var lo: UInt64 = 0
      var hi: UInt64 = 0
      var position = 0

      mutating func put(_ value: UInt64, _ count: Int)
      {
        let v = value & ((1 << UInt64(count)) - 1)
        if position < 64
        {
          lo |= v << UInt64(position)
          if position + count > 64 { hi |= v >> UInt64(64 - position) }
        }
        else
        {
          hi |= v << UInt64(position - 64)
        }
        position += count
      }
    }
  }
}
