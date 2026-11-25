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

extension Kraken
{
  /// one brick of the sculpt volume, distances paint and mask at its 8 by 8 by 8 grid points
  final class SculptBrick: @unchecked Sendable
  {
    static let side: Int32 = 8
    static let count = 512

    var distance: [Float]
    var color: [SIMD4<UInt8>]
    var mask: [UInt8]

    /// the generation in which a band repair last left this brick unchanged, so the next repair can skip it
    var settled = 0

    init(fill: Float, color: SIMD4<UInt8>)
    {
      distance = [Float](repeating: fill, count: Self.count)
      self.color = [SIMD4<UInt8>](repeating: color, count: Self.count)
      mask = [UInt8](repeating: 0, count: Self.count)
    }

    init(copy: SculptBrick)
    {
      distance = copy.distance
      color = copy.color
      mask = copy.mask
    }

    @inline(__always)
    static func index(_ x: Int32, _ y: Int32, _ z: Int32) -> Int
    {
      Int(x | (y << 3) | (z << 6))
    }
  }

  /// what a brick was before a stroke touched it, for undo
  enum SculptBrickState
  {
    case absent
    case inside
    case dense(SculptBrick)
  }

  /// a sparse narrow band signed distance volume in bricks, negative inside, missing bricks outside unless listed inside
  final class SculptVolume: @unchecked Sendable
  {
    /// the world size of one voxel
    var voxel: Float

    var bricks: [SIMD3<Int32>: SculptBrick] = [:]
    var inside: Set<SIMD3<Int32>> = []

    /// the bricks edits really changed and the faces near those changes, so only they and the neighbors they reach are meshed again
    var changed: [SIMD3<Int32>: UInt8] = [:]

    /// every face of a brick, for changes that reach all of it
    static let allFaces: UInt8 = 0x3F

    /// the faces a changed grid point lies within two points of, low x high x low y high y low z high z
    @inline(__always)
    static func faces(_ x: Int32, _ y: Int32, _ z: Int32) -> UInt8
    {
      let edge = SculptBrick.side - 2
      var out: UInt8 = 0
      if x < 2 { out |= 1 }
      if x >= edge { out |= 2 }
      if y < 2 { out |= 4 }
      if y >= edge { out |= 8 }
      if z < 2 { out |= 16 }
      if z >= edge { out |= 32 }
      return out
    }

    /// notes a change to a brick near some of its faces
    @inline(__always)
    func noteChange(_ k: SIMD3<Int32>, _ faces: UInt8)
    {
      changed[k, default: 0] |= faces
    }

    /// bumped at the start of every stroke, so a brick settled before some other edit is never trusted
    var generation = 1

    private static let faces: [SIMD3<Int32>] = [SIMD3(-1, 0, 0), SIMD3(1, 0, 0), SIMD3(0, -1, 0), SIMD3(0, 1, 0),
                                                SIMD3(0, 0, -1), SIMD3(0, 0, 1)]

    /// a brick changed, so it and the face neighbors that read it need their band repaired again
    func unsettle(_ k: SIMD3<Int32>)
    {
      bricks[k]?.settled = 0
      for step in Self.faces { bricks[k &+ step]?.settled = 0 }
    }

    /// the color new surface takes, rgb paint with gloss in alpha
    var base = SIMD4<UInt8>(196, 184, 172, 40)

    init(voxel: Float)
    {
      self.voxel = voxel
    }

    /// how many voxels from the surface distances are kept, wider while shapes blend together
    var bandVoxels: Float = 3

    /// the widest a brush reaches in voxels, so a zoomed out stroke doesn't grind through tens of thousands of bricks
    static let brushVoxels: Float = 48

    /// the widest brush radius this volume takes
    var widestBrush: Float
    {
      voxel * Self.brushVoxels
    }

    /// how far from the surface distances are kept, past it they clamp
    var band: Float
    {
      voxel * bandVoxels
    }

    /// narrows the band back after building with a wide one, dropping the bricks it no longer needs
    func narrow(to voxels: Float)
    {
      bandVoxels = voxels
      let band = band
      for brick in bricks.values
      {
        for i in 0 ..< SculptBrick.count { brick.distance[i] = max(min(brick.distance[i], band), -band) }
      }

      compact(Array(bricks.keys))
    }

    var isEmpty: Bool
    {
      bricks.isEmpty && inside.isEmpty
    }

    // MARK: lookup

    /// rounded grid coordinates converted one lane at a time, the vector conversion is slow
    @inline(__always)
    static func whole(_ f: SIMD3<Float>) -> SIMD3<Int32>
    {
      SIMD3(Int32(f.x), Int32(f.y), Int32(f.z))
    }

    @inline(__always)
    static func key(_ g: SIMD3<Int32>) -> SIMD3<Int32>
    {
      g &>> 3
    }

    @inline(__always)
    static func local(_ g: SIMD3<Int32>) -> SIMD3<Int32>
    {
      g & 7
    }

    /// the distance at a grid point
    @inline(__always)
    func distance(_ g: SIMD3<Int32>) -> Float
    {
      let k = Self.key(g)
      if let brick = bricks[k]
      {
        let l = Self.local(g)
        return brick.distance[SculptBrick.index(l.x, l.y, l.z)]
      }

      return inside.contains(k) ? -band : band
    }

    /// the paint at a grid point
    @inline(__always)
    func color(_ g: SIMD3<Int32>) -> SIMD4<UInt8>
    {
      guard let brick = bricks[Self.key(g)] else { return base }
      let l = Self.local(g)
      return brick.color[SculptBrick.index(l.x, l.y, l.z)]
    }

    /// the world position of a grid point
    @inline(__always)
    func world(_ g: SIMD3<Int32>) -> SIMD3<Float>
    {
      SIMD3<Float>(g) * voxel
    }

    /// the distance anywhere, blended between the grid points around it
    func sample(_ p: SIMD3<Float>) -> Float
    {
      let q = p / voxel
      let f = floor(q)
      let t = q - f
      let g = Self.whole(f)

      let c000 = distance(g)
      let c100 = distance(g &+ SIMD3(1, 0, 0))
      let c010 = distance(g &+ SIMD3(0, 1, 0))
      let c110 = distance(g &+ SIMD3(1, 1, 0))
      let c001 = distance(g &+ SIMD3(0, 0, 1))
      let c101 = distance(g &+ SIMD3(1, 0, 1))
      let c011 = distance(g &+ SIMD3(0, 1, 1))
      let c111 = distance(g &+ SIMD3(1, 1, 1))

      let x00 = c000 + (c100 - c000) * t.x
      let x10 = c010 + (c110 - c010) * t.x
      let x01 = c001 + (c101 - c001) * t.x
      let x11 = c011 + (c111 - c011) * t.x
      let y0 = x00 + (x10 - x00) * t.y
      let y1 = x01 + (x11 - x01) * t.y
      return y0 + (y1 - y0) * t.z
    }

    /// the surface direction at a point, from the distance gradient
    func normal(_ p: SIMD3<Float>) -> SIMD3<Float>
    {
      let e = voxel * 0.75
      let n = SIMD3(sample(p + SIMD3(e, 0, 0)) - sample(p - SIMD3(e, 0, 0)),
                    sample(p + SIMD3(0, e, 0)) - sample(p - SIMD3(0, e, 0)),
                    sample(p + SIMD3(0, 0, e)) - sample(p - SIMD3(0, 0, e)))
      let length = simd_length(n)
      return length > 1e-9 ? n / length : SIMD3(0, 1, 0)
    }

    /// the paint nearest a point
    func paint(_ p: SIMD3<Float>) -> SIMD4<UInt8>
    {
      color(SIMD3<Int32>((p / voxel).rounded(.toNearestOrAwayFromZero)))
    }

    /// the world box around every brick, nil while empty
    var bounds: (lo: SIMD3<Float>, hi: SIMD3<Float>)?
    {
      var keys = Array(bricks.keys)
      keys.append(contentsOf: inside)
      guard let first = keys.first else { return nil }

      var lo = first, hi = first
      for k in keys
      {
        lo = simd_min(lo, k)
        hi = simd_max(hi, k)
      }

      let size = Float(SculptBrick.side) * voxel
      return (SIMD3<Float>(lo) * size, SIMD3<Float>(hi &+ 1) * size)
    }

    // MARK: editing

    /// the bricks a world box touches
    func keys(from lo: SIMD3<Float>, to hi: SIMD3<Float>) -> [SIMD3<Int32>]
    {
      let size = Float(SculptBrick.side) * voxel
      let a = Self.whole(floor(lo / size))
      let b = Self.whole(floor(hi / size))
      var out: [SIMD3<Int32>] = []
      out.reserveCapacity(Int((b.x - a.x + 1) * (b.y - a.y + 1) * (b.z - a.z + 1)))

      for z in a.z ... b.z
      {
        for y in a.y ... b.y
        {
          for x in a.x ... b.x { out.append(SIMD3(x, y, z)) }
        }
      }

      return out
    }

    /// the state of a brick as undo keeps it
    func state(_ k: SIMD3<Int32>) -> SculptBrickState
    {
      if let brick = bricks[k] { return .dense(SculptBrick(copy: brick)) }
      return inside.contains(k) ? .inside : .absent
    }

    /// puts a brick back the way undo kept it
    func restore(_ k: SIMD3<Int32>, _ state: SculptBrickState)
    {
      switch state
      {
        case .absent:
          bricks[k] = nil
          inside.remove(k)
        case .inside:
          bricks[k] = nil
          inside.insert(k)
        case let .dense(brick):
          bricks[k] = SculptBrick(copy: brick)
          inside.remove(k)
      }
    }

    /// makes a brick dense so a brush can write it, filling it with what it stood for
    @discardableResult
    func densify(_ k: SIMD3<Int32>) -> SculptBrick
    {
      if let brick = bricks[k] { return brick }

      let wasInside = inside.remove(k) != nil
      let brick = SculptBrick(fill: wasInside ? -band : band, color: base)
      bricks[k] = brick
      noteChange(k, Self.allFaces)
      unsettle(k)
      return brick
    }

    /// drops bricks the surface left, keeping solid ones as inside markers
    func compact(_ keys: some Sequence<SIMD3<Int32>>)
    {
      let limit = band * 0.999
      for k in keys
      {
        guard let brick = bricks[k] else { continue }

        var allOut = true, allIn = true
        var masked = false
        for i in 0 ..< SculptBrick.count
        {
          let d = brick.distance[i]
          if d < limit { allOut = false }
          if d > -limit { allIn = false }
          if brick.mask[i] != 0 { masked = true }
          if !allOut && !allIn { break }
        }

        if allOut, !masked { bricks[k] = nil }
        else if allIn, !masked
        {
          bricks[k] = nil
          inside.insert(k)
        }
      }
    }

    // MARK: rays

    /// the first surface a ray meets, nil when it misses
    func raycast(origin: SIMD3<Float>, direction: SIMD3<Float>, maxDistance: Float = 1e5) -> SIMD3<Float>?
    {
      guard let box = bounds else { return nil }

      // clip the ray to the volume box first
      let inv = 1 / direction
      let t0 = (box.lo - origin) * inv
      let t1 = (box.hi - origin) * inv
      let near = simd_reduce_max(simd_min(t0, t1))
      let far = min(simd_reduce_min(simd_max(t0, t1)), maxDistance)
      guard far > max(near, 0) else { return nil }

      var t = max(near, 0)
      var previous = sample(origin + direction * t)
      if previous < 0 { return nil }

      let minimum = voxel * 0.35
      while t < far
      {
        let step = max(previous * 0.9, minimum)
        let next = t + step
        let d = sample(origin + direction * next)

        if d < 0
        {
          // narrow the crossing down between the last two steps
          var a = t, b = next
          for _ in 0 ..< 8
          {
            let m = (a + b) * 0.5
            if sample(origin + direction * m) < 0 { b = m } else { a = m }
          }

          return origin + direction * b
        }

        t = next
        previous = d
      }

      return nil
    }

    // MARK: resampling

    /// a copy of this volume at another voxel size, for changing resolution
    func resampled(voxel next: Float) -> SculptVolume
    {
      let out = SculptVolume(voxel: next)
      out.base = base
      guard !isEmpty else { return out }

      // only bricks of the new grid over the old band can hold surface, so the bounding box isn't swept
      let size = Float(SculptBrick.side) * voxel
      let pad = SIMD3<Float>(repeating: next * 2)
      var near = Set<SIMD3<Int32>>()
      for k in bricks.keys
      {
        let lo = SIMD3<Float>(k) * size
        near.formUnion(out.keys(from: lo - pad, to: lo + size + pad))
      }

      // past the old band distances clamp at its width, so a coarser grid tells in from out at that width
      let limit = min(out.band, band) * 0.999
      let keys = Array(near)
      let side = SculptBrick.side
      var made = [SculptBrick?](repeating: nil, count: keys.count)
      var solid = [Bool](repeating: false, count: keys.count)

      made.withUnsafeMutableBufferPointer
      { made in
        solid.withUnsafeMutableBufferPointer
        { solid in
          DispatchQueue.concurrentPerform(iterations: keys.count)
          { i in
            let k = keys[i]
            let brick = SculptBrick(fill: out.band, color: base)
            var anyIn = false, anyOut = false

            for z in 0 ..< side
            {
              for y in 0 ..< side
              {
                for x in 0 ..< side
                {
                  let g = k &* side &+ SIMD3(x, y, z)
                  let p = SIMD3<Float>(g) * next
                  let d = max(min(sample(p), out.band), -out.band)
                  let index = SculptBrick.index(x, y, z)
                  brick.distance[index] = d
                  brick.color[index] = paint(p)
                  if d > -limit { anyOut = true }
                  if d < limit { anyIn = true }
                }
              }
            }

            if anyIn && anyOut { made[i] = brick }
            else if anyIn { solid[i] = true }
          }
        }
      }

      for (i, k) in keys.enumerated()
      {
        if let brick = made[i] { out.bricks[k] = brick }
        else if solid[i] { out.inside.insert(k) }
      }

      // bricks of the new grid away from the band are wholly in or out, the solid ones lie over solid bricks
      var solidKeys = Set<SIMD3<Int32>>()
      for k in inside
      {
        let lo = SIMD3<Float>(k) * size
        solidKeys.formUnion(out.keys(from: lo, to: lo + size * 0.999))
      }

      let half = Float(side) * next * 0.5
      for k in solidKeys where !near.contains(k) && sample(SIMD3<Float>(k) * Float(side) * next + half) < 0
      {
        out.inside.insert(k)
      }

      return out
    }
  }
}
