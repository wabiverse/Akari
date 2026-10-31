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
import LabGL

extension Akari.LabFXEngine
{
  /// Transparent materials, weighted blended over the resolve with refraction.
  struct Transparency
  {
    var passesActive = true
    var waterTime: Double = 0
  }

  /// The clear always runs, so the motion blur never reads a transparent surface's motion from a past shot.
  static let transparencyPasses = ["transparent", "transparent composite", "transparent apply"]

  /// The timeline's time in seconds, what the water's waves move with.
  public var waterTime: Double
  {
    get { transparency.waterTime }
    set { transparency.waterTime = newValue }
  }

  /// The index of refraction every transparent material refracts with.
  static let transparencyIOR: Float = 1.5

  /// A large flat transparent sheet, an ocean or a lake, which the composite
  /// shades as a plane at `level`.
  struct WaterPlane
  {
    var level: Float
    var lo: SIMD2<Float>
    var hi: SIMD2<Float>
    var color: SIMD3<Float>
    var roughness: Float
    var detail = 0
  }

  /// The water plane `mesh` makes, nil unless it's at least 20m across and
  /// its waves stay within a fiftieth of that. It sits at the median height,
  /// what a sea modeled with swells, or sloping off past the horizon, rests at.
  func waterPlane(_ mesh: Akari.Geom.Recorder.RawMesh) -> WaterPlane?
  {
    var sample = [Float](repeating: 0, count: 65536 * 3)
    let n = sample.withUnsafeMutableBufferPointer { Pixar.HdAkariPointsSample(mesh.points, $0.baseAddress!, 65536) }
    guard n > 2 else { return nil }
    let m = mesh.worldMatrix
    let up = stageIsZUp ? 2 : 1, a = 0, c = stageIsZUp ? 1 : 2
    var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
    var heights = [Float](repeating: 0, count: n)
    for i in 0 ..< n
    {
      let p = SIMD3(sample[i * 3], sample[i * 3 + 1], sample[i * 3 + 2])
      let w = SIMD3(m[0] * p.x + m[4] * p.y + m[8] * p.z + m[12],
                    m[1] * p.x + m[5] * p.y + m[9] * p.z + m[13],
                    m[2] * p.x + m[6] * p.y + m[10] * p.z + m[14])
      lo = pointwiseMin(lo, SIMD2(w[a], w[c]))
      hi = pointwiseMax(hi, SIMD2(w[a], w[c]))
      heights[i] = w[up]
    }
    heights.sort()
    let across = max(hi.x - lo.x, hi.y - lo.y)
    let swell = heights[n * 19 / 20] - heights[n / 20]
    guard across * stageMetersPerUnit >= 20, swell <= across * 0.02 else { return nil }
    return WaterPlane(level: heights[n / 2], lo: lo, hi: hi, color: mesh.color, roughness: mesh.roughness,
                      detail: mesh.points.size())
  }

  func applyTransparency(projection: Akari.Matrix4, view: Akari.Matrix4)
  {
    let active = !geometry.transparent.isEmpty || water != nil
    if active != transparency.passesActive
    {
      setPasses(Self.transparencyPasses, active: active)
      transparency.passesActive = active
    }
    setVector("u_transparency", SIMD4(stageMetersPerUnit, Self.transparencyIOR, 0.6, Float(projection[1, 1])))
    let plane = water ?? WaterPlane(level: 0, lo: .zero, hi: .zero, color: .zero, roughness: 0)
    setVector("u_water", SIMD4(plane.level, water == nil ? 0 : 1, 1.33, plane.roughness))
    setVector("u_waterColor", SIMD4(plane.color, stageMetersPerUnit))
    setVector("u_waterBounds", SIMD4(plane.lo.x, plane.lo.y, plane.hi.x, plane.hi.y))
    setVector("u_waterWaves", SIMD4(Float(transparency.waterTime.truncatingRemainder(dividingBy: 3600)), 0, 0, 0))
    setMatrix("u_waterView", view)
    setMatrix("u_waterInvView", view.inverse())
  }
}
