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
import LabFX
import LabGL
import simd

extension Akari.LabFXEngine
{
  /// Changes whenever the item moves or deforms, for the shadows' moved caster test.
  static func casterKey(_ item: Akari.Geom.Recorder.Item) -> UInt64
  {
    var key = (14_695_981_039_346_656_037 ^ item.dataRevision) &* 1_099_511_628_211
    for value in item.worldMatrix
    {
      key = (key ^ UInt64(value.bitPattern)) &* 1_099_511_628_211
    }
    // which instances a set keeps is in each instance cell's key instead.
    for draw in item.instanceDraws
    {
      key = (key ^ draw.key) &* 1_099_511_628_211
    }

    return key
  }

  /// Hash of what a mesh looks like in the world, changes whenever it animates.
  static func changeKey(_ mesh: Akari.Geom.Recorder.RawMesh) -> UInt64
  {
    var key: UInt64 = 14_695_981_039_346_656_037
    func mix(_ bits: UInt64)
    {
      key = (key ^ bits) &* 1_099_511_628_211
    }

    mix(mesh.dataRevision)
    mix(mesh.flipWinding ? 1 : 0)
    for value in mesh.worldMatrix
    {
      mix(UInt64(value.bitPattern))
    }

    mix(mesh.instancesKey)
    return key
  }

  /// Merges instanced prototypes whose object space geometry, material and
  /// own transform hash the same into one prototype, drawn once per each
  /// instance set.
  static func binInstances(_ meshes: [Akari.Geom.Recorder.RawMesh], budget: Int,
                                   camera: RecordCamera?)
    -> (meshes: [(mesh: Akari.Geom.Recorder.RawMesh, triangles: Int)], detail: Float)
  {
    var slots: [UInt64: Int] = [:]
    var binned: [Akari.Geom.Recorder.RawMesh] = []
    for mesh in meshes.sorted(by: { $0.key < $1.key })
    {
      let draw = Akari.Geom.Recorder.InstanceDraw(key: mesh.instancesKey, transforms: mesh.instances,
                                                  count: mesh.instances.count / 16, livePrototype: mesh.livePrototype)
      let key = mesh.contentKey == 0 ? mesh.key : geometryKey(mesh)
      if let slot = slots[key]
      {
        if !binned[slot].instanceDraws.contains(where: { $0.key == draw.key }) { binned[slot].instanceDraws.append(draw) }
        continue
      }

      var prototype = mesh
      if mesh.contentKey != 0
      {
        // named by its content, so its cached build survives whichever mesh represents it.
        prototype.id = "content:\(key)"
        prototype.dataRevision = key
        prototype.topologyRevision = key
      }

      prototype.instanceDraws = [draw]
      slots[key] = binned.count
      binned.append(prototype)
    }

    guard let camera
    else
    {
      return (instanceLevels(budgetGeometry(binned, budget: budget, area: binned.map { screenPixels($0, camera: nil) })).meshes, 1)
    }

    let (visible, area) = cullInstances(binned, camera: camera)
    return instanceLevels(budgetGeometry(visible, budget: budget, area: area), camera: camera)
  }

  /// A meshes bounding sphere, under its own transform.
  static func boundingSphere(_ mesh: Akari.Geom.Recorder.RawMesh) -> (center: SIMD3<Float>, radius: Float)
  {
    var b = [Float](repeating: 0, count: 6)
    b.withUnsafeMutableBufferPointer { Pixar.HdAkariPointsBounds(mesh.points, $0.baseAddress!) }
    let m = mesh.worldMatrix
    let local = SIMD3(b[0] + b[3], b[1] + b[4], b[2] + b[5]) * 0.5
    let center = SIMD3(m[0] * local.x + m[4] * local.y + m[8] * local.z + m[12],
                       m[1] * local.x + m[5] * local.y + m[9] * local.z + m[13],
                       m[2] * local.x + m[6] * local.y + m[10] * local.z + m[14])
    return (center, simd_length(SIMD3(b[3] - b[0], b[4] - b[1], b[5] - b[2])) * 0.5 * maxScale(m, 0))
  }

  static func maxScale<M: RandomAccessCollection>(_ m: M, _ o: Int) -> Float where M.Element == Float, M.Index == Int
  {
    max((m[o] * m[o] + m[o + 1] * m[o + 1] + m[o + 2] * m[o + 2]).squareRoot(),
        (m[o + 4] * m[o + 4] + m[o + 5] * m[o + 5] + m[o + 6] * m[o + 6]).squareRoot(),
        (m[o + 8] * m[o + 8] + m[o + 9] * m[o + 9] + m[o + 10] * m[o + 10]).squareRoot())
  }

  /// The screen a mesh drawn once covers, in pixels, and the most of it any one instance does,
  /// without a camera its size and no level of detail.
  static func screenPixels(_ mesh: Akari.Geom.Recorder.RawMesh, camera: RecordCamera?)
    -> (total: Double, largest: Double?)
  {
    let sphere = boundingSphere(mesh)
    guard let camera else { return (Double(sphere.radius * sphere.radius), nil) }
    let px = Double(camera.pixels(center: sphere.center, radius: sphere.radius))
    return (Double.pi * px * px, Double.pi * px * px)
  }

  /// Keeps each set's instances the camera sees, largest on screen first, against a sphere around
  /// every prototype drawn with it, so a draw that takes only part of a set keeps what matters most.
  /// Each prototype is worth the screen its set covers, scaled to its own size, per triangle.
  private static func cullInstances(_ meshes: [Akari.Geom.Recorder.RawMesh], camera: RecordCamera)
    -> (meshes: [Akari.Geom.Recorder.RawMesh], area: [(total: Double, largest: Double?)])
  {
    let spheres = meshes.map(boundingSphere)
    var bounds: [UInt64: (lo: SIMD3<Float>, hi: SIMD3<Float>)] = [:]
    var transforms: [UInt64: Akari.Geom.Matrices] = [:]
    for (mesh, sphere) in zip(meshes, spheres)
    {
      for draw in mesh.instanceDraws where draw.livePrototype == nil
      {
        let lo = sphere.center - sphere.radius, hi = sphere.center + sphere.radius
        let entry = bounds[draw.key] ?? (lo, hi)
        bounds[draw.key] = (simd_min(entry.lo, lo), simd_max(entry.hi, hi))
        transforms[draw.key] = draw.transforms
      }
    }

    var culled: [UInt64: Akari.Geom.Recorder.InstanceDraw] = [:]
    var area: [UInt64: (pixels: Double, largest: Double, radius: Float)] = [:]
    for (key, box) in bounds
    {
      guard let xf = transforms[key] else { continue }
      let center = (box.lo + box.hi) * 0.5, radius = simd_length(box.hi - box.lo) * 0.5
      var seen: [(index: Int, pixels: Float)] = []
      for i in 0 ..< xf.count / 16
      {
        let o = i * 16
        let c = SIMD3(xf[o] * center.x + xf[o + 4] * center.y + xf[o + 8] * center.z + xf[o + 12],
                      xf[o + 1] * center.x + xf[o + 5] * center.y + xf[o + 9] * center.z + xf[o + 13],
                      xf[o + 2] * center.x + xf[o + 6] * center.y + xf[o + 10] * center.z + xf[o + 14])
        let px = camera.pixels(center: c, radius: radius * maxScale(xf, o))
        if px > 0 { seen.append((i, px)) }
      }

      guard !seen.isEmpty else { continue }
      seen.sort { $0.pixels > $1.pixels }
      var kept = [Float](repeating: 0, count: seen.count * 16)
      for (slot, instance) in seen.enumerated()
      {
        for k in 0 ..< 16
        {
          kept[slot * 16 + k] = xf[instance.index * 16 + k]
        }
      }

      culled[key] = Akari.Geom.Recorder.InstanceDraw(key: (key ^ 0x9E37_79B9_7F4A_7C15) &* 1_099_511_628_211,
                                                     transforms: Akari.Geom.Matrices(kept), count: seen.count)
      area[key] = (seen.reduce(0) { $0 + Double.pi * Double($1.pixels * $1.pixels) },
                   Double.pi * Double(seen[0].pixels * seen[0].pixels), radius)
    }

    var visible: [Akari.Geom.Recorder.RawMesh] = []
    var screen: [(total: Double, largest: Double?)] = []
    for (mesh, sphere) in zip(meshes, spheres)
    {
      var mesh = mesh
      var total = 0.0, largest = 0.0
      mesh.instanceDraws = mesh.instanceDraws.compactMap
      { draw in
        if draw.livePrototype != nil
        {
          total = .greatestFiniteMagnitude
          largest = .greatestFiniteMagnitude
          return draw
        }

        guard
          let kept = culled[draw.key],
          let covered = area[draw.key]
        else { return nil }

        let share = Double(sphere.radius / max(covered.radius, 1e-6))
        guard share < 0.5
        else
        {
          total += covered.pixels * share * share
          largest = max(largest, covered.largest * share * share)
          return kept
        }
        // a mesh small against its set's bounds, like one of the many sharing an identity set,
        // covers what its own sphere does through each instance, not a share of the set's.
        let xf = kept.transforms, counted = min(kept.count, maxMeasuredInstances)
        var own = 0.0
        for i in 0 ..< counted
        {
          let o = i * 16, l = sphere.center
          let c = SIMD3(xf[o] * l.x + xf[o + 4] * l.y + xf[o + 8] * l.z + xf[o + 12],
                        xf[o + 1] * l.x + xf[o + 5] * l.y + xf[o + 9] * l.z + xf[o + 13],
                        xf[o + 2] * l.x + xf[o + 6] * l.y + xf[o + 10] * l.z + xf[o + 14])
          let px = Double(camera.pixels(center: c, radius: sphere.radius * maxScale(xf, o)))
          own += Double.pi * px * px
          largest = max(largest, Double.pi * px * px)
        }

        total += own * Double(kept.count) / Double(max(counted, 1))
        return kept
      }

      guard !mesh.instanceDraws.isEmpty else { continue }
      visible.append(mesh)
      screen.append((total, largest))
    }

    return (visible, screen)
  }

  /// A prototype's content and the transform its vertices are recorded under.
  private static func geometryKey(_ mesh: Akari.Geom.Recorder.RawMesh) -> UInt64
  {
    var key = mesh.contentKey
    for value in mesh.worldMatrix
    {
      key = (key ^ UInt64(value.bitPattern)) &* 1_099_511_628_211
    }

    return (key ^ (mesh.flipWinding ? 1 : 0)) &* 1_099_511_628_211
  }

  static func hashFloats(_ values: [Float]) -> UInt64
  {
    var key: UInt64 = 14_695_981_039_346_656_037
    for value in values
    {
      key = (key ^ UInt64(value.bitPattern)) &* 1_099_511_628_211
    }

    return key
  }

  static func environmentBudget(_ name: String, _ fallback: Int) -> Int
  {
    if let value = ProcessInfo.processInfo.environment[name], let budget = Int(value), budget > 0
    {
      return budget
    }

    return fallback
  }
}
