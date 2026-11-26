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

import Foundation
import simd

// fits a linearly transformed cosine to the ggx lobe per roughness and view angle, after heitz, dupuy, hill and neubelt 2016

typealias Vec = SIMD3<Double>

let size = 64
let samples = 32
let minAlpha = 1e-5

/// the ggx lobe with smith's height correlated masking and no fresnel, the brdf times the cosine and its sampling pdf
func brdf(_ v: Vec, _ l: Vec, alpha: Double) -> (value: Double, pdf: Double)
{
  guard l.z > 0 else { return (0, 0) }

  let h = simd_normalize(v + l)
  let a2 = alpha * alpha
  let d = a2 / (.pi * pow(h.z * h.z * (a2 - 1) + 1, 2))
  let lambda = { (c: Double) in (-1 + (1 + a2 * (1 - c * c) / (c * c)).squareRoot()) / 2 }
  let g2 = 1 / (1 + lambda(v.z) + lambda(l.z))
  return (d * g2 / (4 * v.z), d * h.z / (4 * simd_dot(v, h)))
}

/// a direction drawn in proportion to the ggx normal distribution
func sampleBRDF(_ v: Vec, alpha: Double, _ u1: Double, _ u2: Double) -> Vec
{
  let theta = atan(alpha * (u1 / (1 - u1)).squareRoot()), phi = 2 * .pi * u2
  let h = Vec(sin(theta) * cos(phi), sin(theta) * sin(phi), cos(theta))
  return 2 * simd_dot(v, h) * h - v
}

/// a clamped cosine stretched, skewed and turned by the matrix built from its frame and three parameters
struct LTC
{
  var m11 = 1.0, m22 = 1.0, m13 = 0.0
  var x = Vec(1, 0, 0), y = Vec(0, 1, 0), z = Vec(0, 0, 1)
  var magnitude = 1.0
  var m = matrix_identity_double3x3, inverse = matrix_identity_double3x3, determinant = 1.0

  mutating func update()
  {
    m = simd_double3x3(columns: (x, y, z)) * simd_double3x3(columns: (Vec(m11, 0, 0), Vec(0, m22, 0), Vec(m13, 0, 1)))
    inverse = m.inverse
    determinant = abs(m.determinant)
  }

  func eval(_ l: Vec) -> Double
  {
    let original = simd_normalize(inverse * l)
    let jacobian = determinant / pow(simd_length(m * original), 3)
    return magnitude * max(original.z, 0) / .pi / jacobian
  }

  func sample(_ u1: Double, _ u2: Double) -> Vec
  {
    let r = u1.squareRoot(), phi = 2 * .pi * u2
    return simd_normalize(m * Vec(r * cos(phi), r * sin(phi), (1 - u1).squareRoot()))
  }
}

/// the brdf's albedo without fresnel, its schlick fresnel part and its average direction
func averages(_ v: Vec, alpha: Double) -> (norm: Double, fresnel: Double, direction: Vec)
{
  var norm = 0.0, fresnel = 0.0, direction = Vec.zero
  for j in 0 ..< samples
  {
    for i in 0 ..< samples
    {
      let l = sampleBRDF(v, alpha: alpha, (Double(j) + 0.5) / Double(samples), (Double(i) + 0.5) / Double(samples))
      let (value, pdf) = brdf(v, l, alpha: alpha)
      guard pdf > 0 else { continue }

      let weight = value / pdf
      norm += weight
      fresnel += weight * pow(1 - max(simd_dot(v, simd_normalize(v + l)), 0), 5)
      direction += weight * l
    }
  }

  let count = Double(samples * samples)
  direction.y = 0
  return (norm / count, fresnel / count, simd_normalize(direction))
}

/// how far the fitted lobe is from the brdf, sampled from both so neither one's tails go unseen
func error(_ ltc: LTC, _ v: Vec, alpha: Double) -> Double
{
  var total = 0.0
  for j in 0 ..< samples
  {
    for i in 0 ..< samples
    {
      let u1 = (Double(j) + 0.5) / Double(samples), u2 = (Double(i) + 0.5) / Double(samples)
      for l in [ltc.sample(u1, u2), sampleBRDF(v, alpha: alpha, u1, u2)]
      {
        let (value, pdf) = brdf(v, l, alpha: alpha)
        let fitted = ltc.eval(l)
        let difference = abs(value - fitted)
        let denominator = fitted / ltc.magnitude + pdf
        if denominator > 0 { total += difference * difference * difference / denominator }
      }
    }
  }

  return total / Double(samples * samples)
}

/// nelder and mead's downhill simplex
func minimize(_ start: [Double], step: Double, iterations: Int, _ f: ([Double]) -> Double) -> [Double]
{
  let n = start.count
  var simplex = [start] + (0 ..< n).map { i -> [Double] in var p = start; p[i] += step; return p }
  var values = simplex.map(f)

  for _ in 0 ..< iterations
  {
    let order = values.indices.sorted { values[$0] < values[$1] }
    simplex = order.map { simplex[$0] }
    values = order.map { values[$0] }
    if abs(values[n] - values[0]) < 1e-12 { break }

    let centroid = (0 ..< n).map { k in simplex.prefix(n).map { $0[k] }.reduce(0, +) / Double(n) }
    let along = { (t: Double) in (0 ..< n).map { centroid[$0] + t * (simplex[n][$0] - centroid[$0]) } }

    let reflected = along(-1), fr = f(reflected)
    if fr < values[0]
    {
      let expanded = along(-2), fe = f(expanded)
      (simplex[n], values[n]) = fe < fr ? (expanded, fe) : (reflected, fr)
    }
    else if fr < values[n - 1]
    {
      (simplex[n], values[n]) = (reflected, fr)
    }
    else
    {
      let contracted = along(fr < values[n] ? -0.5 : 0.5), fc = f(contracted)
      if fc < min(fr, values[n])
      {
        (simplex[n], values[n]) = (contracted, fc)
      }
      else
      {
        for i in 1 ... n
        {
          simplex[i] = (0 ..< n).map { simplex[0][$0] + 0.5 * (simplex[i][$0] - simplex[0][$0]) }
          values[i] = f(simplex[i])
        }
      }
    }
  }

  return simplex[values.indices.min { values[$0] < values[$1] }!]
}

var fitted = [simd_double3x3](repeating: matrix_identity_double3x3, count: size * size)
var amplitudes = [(Double, Double)](repeating: (1, 0), count: size * size)
var ltc = LTC()

let began = Date()
for a in stride(from: size - 1, through: 0, by: -1)
{
  for t in 0 ..< size
  {
    let x = Double(t) / Double(size - 1)
    let theta = min(1.57, acos(1 - x * x))
    let v = Vec(sin(theta), 0, cos(theta))
    let roughness = Double(a) / Double(size - 1)
    let alpha = max(roughness * roughness, minAlpha)

    let (norm, fresnel, direction) = averages(v, alpha: alpha)
    ltc.magnitude = norm

    // facing the view the lobe is round, otherwise it leans along its average direction and starts from the last fit
    let isotropic = t == 0
    if isotropic
    {
      (ltc.x, ltc.y, ltc.z) = (Vec(1, 0, 0), Vec(0, 1, 0), Vec(0, 0, 1))
      if a == size - 1
      {
        (ltc.m11, ltc.m22) = (1, 1)
      }
      else
      {
        (ltc.m11, ltc.m22) = (fitted[a + 1][0][0], fitted[a + 1][1][1])
      }

      ltc.m13 = 0
    }
    else
    {
      (ltc.x, ltc.y, ltc.z) = (Vec(direction.z, 0, -direction.x), Vec(0, 1, 0), direction)
    }

    ltc.update()
    let best = minimize([ltc.m11, ltc.m22, ltc.m13], step: 0.05, iterations: 200)
    { p in
      var trial = ltc
      trial.m11 = max(p[0], 1e-7)
      trial.m22 = isotropic ? trial.m11 : max(p[1], 1e-7)
      trial.m13 = isotropic ? 0 : p[2]
      trial.update()
      return error(trial, v, alpha: alpha)
    }

    ltc.m11 = max(best[0], 1e-7)
    ltc.m22 = isotropic ? ltc.m11 : max(best[1], 1e-7)
    ltc.m13 = isotropic ? 0 : best[2]
    ltc.update()

    fitted[a + t * size] = ltc.m
    amplitudes[a + t * size] = (norm, fresnel)
  }

  print(String(format: "roughness %.3f fitted, %.0fs", Double(a) / Double(size - 1), Date().timeIntervalSince(began)))
}

// the inverse matrix's four varying entries normalized by its middle one, then the amplitude and fresnel terms
var floats: [Float] = []
for i in 0 ..< size * size
{
  var inverse = fitted[i].inverse
  inverse = inverse * (1 / inverse[1][1])
  floats += [Float(inverse[0][0]), Float(inverse[0][2]), Float(inverse[2][0]), Float(inverse[2][2])]
}

for (norm, fresnel) in amplitudes
{
  floats += [Float(norm), Float(fresnel), 0, 1]
}

let here = URL(fileURLWithPath: #filePath)
let output = here.deletingLastPathComponent().appendingPathComponent("../../../../Sources/AkariRender/Resources/LTC_GGX.bin").standardized
try floats.withUnsafeBufferPointer { Data(buffer: $0) }.write(to: output)
print("wrote \(output.path), \(floats.count * 4) bytes")
