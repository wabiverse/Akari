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
  /// transparent materials, weighted blended over the resolve with refraction
  struct Transparency
  {
    var passesActive = true

    /// every glass pass starts on in the graph so each is turned off the first frame it has nothing to do
    var glassPassesActive: [Akari.LabFXEngine.Pass: Bool] = [:]

    /// this frame's glass lights in the order the glass maps draw them
    var glass: [Akari.LabFXEngine.GlassFrame] = []
    var glassTextures = Akari.LabFXEngine.GlassTextures()

    /// each glass light's map matrix and light, one row per tile, see `GlassAtlas.dataWidth`
    var glassLights: GLuint = 0

    /// a hash of everything the caustic trace reads so rays already traced are reused instead of traced again
    var causticKey: UInt64 = 0

    /// whether the waiting rays came from every light and not just a share of them while the view moved
    var causticsFull = false

    /// whether any light has rays waiting, false until the first trace lands
    var causticsTraced = false

    /// the camera the gbuffer was drawn with, which the caustic trace marches against
    var view: Akari.Matrix4 = .identity
    var projection: Akari.Matrix4 = .identity

    /// what the glass maps are drawn from, which excludes the camera so moving the view keeps the existing maps
    var glassMapKey: UInt64 = 0
    var glassMapsDrawn = false
    var waterTime: Double = 0
  }

  /// the clear always runs so motion blur never reads a transparent surface's motion from a past shot
  static let transparencyPasses: [Pass] = [.transparent, .transparentComposite, .transparentApply]

  /// the timeline time in seconds that the water waves move with
  public var waterTime: Double
  {
    get { transparency.waterTime }
    set { transparency.waterTime = newValue }
  }

  /// the index of refraction every transparent material uses
  static let transparencyIOR: Float = 1.5

  /// a large flat transparent sheet like an ocean or a lake, which the composite shades as a plane at `level`
  struct WaterPlane
  {
    var level: Float
    var lo: SIMD2<Float>
    var hi: SIMD2<Float>
    var color: SIMD3<Float>
    var roughness: Float
    var detail = 0
  }

  /// the water plane `mesh` makes, nil unless it is at least 20 m across with small waves, resting at the median height
  func waterPlane(_ mesh: Akari.Geom.Recorder.RawMesh) -> WaterPlane?
  {
    var sample = [Float](repeating: 0, count: 65536 * 3)
    let count = sample.withUnsafeMutableBufferPointer { Pixar.HdAkariPointsSample(mesh.points, $0.baseAddress!, 65536) }
    guard count > 2 else { return nil }

    let matrix = mesh.worldMatrix
    let up = stageIsZUp ? 2 : 1, across0 = 0, across1 = stageIsZUp ? 1 : 2
    var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
    var heights = [Float](repeating: 0, count: count)
    for index in 0 ..< count
    {
      let local = SIMD3(sample[index * 3], sample[index * 3 + 1], sample[index * 3 + 2])
      let world = SIMD3(matrix[0] * local.x + matrix[4] * local.y + matrix[8] * local.z + matrix[12],
                        matrix[1] * local.x + matrix[5] * local.y + matrix[9] * local.z + matrix[13],
                        matrix[2] * local.x + matrix[6] * local.y + matrix[10] * local.z + matrix[14])
      lo = pointwiseMin(lo, SIMD2(world[across0], world[across1]))
      hi = pointwiseMax(hi, SIMD2(world[across0], world[across1]))
      heights[index] = world[up]
    }

    heights.sort()
    let across = max(hi.x - lo.x, hi.y - lo.y)
    let swell = heights[count * 19 / 20] - heights[count / 20]
    guard across * stageMetersPerUnit >= 20, swell <= across * 0.02 else { return nil }

    return WaterPlane(level: heights[count / 2], lo: lo, hi: hi, color: mesh.color, roughness: mesh.roughness,
                      detail: mesh.points.size())
  }

  func applyTransparency(projection: Akari.Matrix4, view: Akari.Matrix4)
  {
    transparency.view = view
    transparency.projection = projection

    let active = !geometry.flags.transparent.isEmpty || water != nil
    if active != transparency.passesActive
    {
      setPasses(Self.transparencyPasses, active: active)
      transparency.passesActive = active
    }

    setVector(.transparency, SIMD4(stageMetersPerUnit, Self.transparencyIOR, 0.6, Float(projection[1, 1])))

    let plane = water ?? WaterPlane(level: 0, lo: .zero, hi: .zero, color: .zero, roughness: 0)
    setVector(.water, SIMD4(plane.level, water == nil ? 0 : 1, 1.33, plane.roughness))
    setVector(.waterColor, SIMD4(plane.color, stageMetersPerUnit))
    setVector(.waterBounds, SIMD4(plane.lo.x, plane.lo.y, plane.hi.x, plane.hi.y))
    setVector(.waterWaves, SIMD4(Float(transparency.waterTime.truncatingRemainder(dividingBy: 3600)), 0, 0, 0))
    setMatrix(.waterView, view)
    setMatrix(.waterInvView, view.inverse())
  }
}
