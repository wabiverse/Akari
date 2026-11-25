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
  /// a mesh vertex as the sculpt viewport draws it, 32 bytes
  struct SculptVertex: Sendable
  {
    var x: Float, y: Float, z: Float
    var nx: Float, ny: Float, nz: Float
    var color: UInt32
    var mask: Float

    var position: SIMD3<Float>
    {
      SIMD3(x, y, z)
    }

    var normal: SIMD3<Float>
    {
      SIMD3(nx, ny, nz)
    }

    static let empty = SculptVertex(x: 0, y: 0, z: 0, nx: 0, ny: 0, nz: 0, color: 0, mask: 0)
  }

  /// the surface of one brick
  struct SculptChunk: Sendable
  {
    var vertices: [SculptVertex] = []
    var indices: [UInt32] = []

    var isEmpty: Bool
    {
      indices.isEmpty
    }
  }

  /// turns bricks of the sculpt volume into triangles with surface nets
  enum SculptMesher
  {
    /// the samples a brick meshes from, two grid points past each side
    static let apron: Int32 = 2
    static let span: Int32 = SculptBrick.side + apron * 2
    /// cells with a vertex, from one before the brick to its last
    static let cells: Int32 = SculptBrick.side + 1

    /// whether the sign of the distances changes anywhere in a brick or across its faces into the layer beside it
    private static func crosses(_ around: [SculptBrick?], _ solid: [Bool], band: Float, still: Float) -> Bool
    {
      guard let own = around[13] else { return false }
      let side = SculptBrick.side

      return own.distance.withUnsafeBufferPointer
      { d in
        // a point within the settling distance of zero counts as outside, the same as the mesher sees it
        @inline(__always) func inside(_ v: Float) -> Bool
        {
          v <= -still
        }

        let first = inside(d[0])
        for v in d where inside(v) != first { return true }

        // the layer of each face neighbor touching this brick, or what an absent neighbor stands for
        for (n, axis, layer) in [(12, 0, side - 1), (14, 0, Int32(0)), (10, 1, side - 1), (16, 1, Int32(0)),
                                 (4, 2, side - 1), (22, 2, Int32(0))]
        {
          guard let brick = around[n] else
          {
            if (solid[n] ? true : inside(band)) != first { return true }
            continue
          }

          let differs: Bool = brick.distance.withUnsafeBufferPointer
          { theirs in
            for b in 0 ..< side
            {
              for a in 0 ..< side
              {
                let index = axis == 0 ? SculptBrick.index(layer, a, b) : axis == 1 ? SculptBrick.index(a, layer, b)
                  : SculptBrick.index(a, b, layer)
                if inside(theirs[index]) != first { return true }
              }
            }

            return false
          }

          if differs { return true }
        }

        return false
      }
    }

    /// meshes one brick, nil when it holds no surface
    static func mesh(_ volume: SculptVolume, _ key: SIMD3<Int32>) -> SculptChunk?
    {
      guard volume.bricks[key] != nil else { return nil }

      let side = SculptBrick.side
      let span = Self.span, apron = Self.apron
      let count = Int(span * span * span)
      let band = volume.band

      // the brick and its neighbors around it, looked up once
      var around = [SculptBrick?](repeating: nil, count: 27)
      var solid = [Bool](repeating: false, count: 27)
      for z: Int32 in -1 ... 1
      {
        for y: Int32 in -1 ... 1
        {
          for x: Int32 in -1 ... 1
          {
            let k = key &+ SIMD3(x, y, z)
            let i = Int((x + 1) + (y + 1) * 3 + (z + 1) * 9)
            around[i] = volume.bricks[k]
            solid[i] = volume.inside.contains(k)
          }
        }
      }

      // a brick has no surface without a sign change on its edges, cheaper to tell from its own points than to mesh and find nothing
      guard crosses(around, solid, band: band, still: volume.voxel * 0.01) else { return nil }

      var samples = [Float](repeating: band, count: count)
      var paints = [SIMD4<UInt8>](repeating: volume.base, count: count)
      var masks = [UInt8](repeating: 0, count: count)

      // a point within a hundredth of a voxel of the surface counts as outside, so surfaces along grid planes settle flat instead of folding
      let still = volume.voxel * 0.01

      // each neighbor copies only the part the samples reach, read through plain pointers
      @inline(__always) func reach(_ o: Int32) -> ClosedRange<Int32>
      {
        o < 0 ? side - apron ... side - 1 : o == 0 ? 0 ... side - 1 : 0 ... apron - 1
      }

      samples.withUnsafeMutableBufferPointer
      { d in
        paints.withUnsafeMutableBufferPointer
        { color in
          masks.withUnsafeMutableBufferPointer
          { mask in
            for n in 0 ..< 27
            {
              let o = SIMD3<Int32>(Int32(n % 3) - 1, Int32(n / 3 % 3) - 1, Int32(n / 9) - 1)
              let shift = o &* side &+ apron
              let rx = reach(o.x), ry = reach(o.y), rz = reach(o.z)

              if let brick = around[n]
              {
                brick.distance.withUnsafeBufferPointer
                { from in
                  brick.color.withUnsafeBufferPointer
                  { paint in
                    brick.mask.withUnsafeBufferPointer
                    { masked in
                      for z in rz
                      {
                        for y in ry
                        {
                          for x in rx
                          {
                            let i = Int((x + shift.x) + ((y + shift.y) + (z + shift.z) * span) * span)
                            let index = SculptBrick.index(x, y, z)
                            let distance = from[index]
                            d[i] = abs(distance) < still ? still : distance
                            color[i] = paint[index]
                            mask[i] = masked[index]
                          }
                        }
                      }
                    }
                  }
                }
              }
              else if solid[n]
              {
                for z in rz
                {
                  for y in ry
                  {
                    for x in rx { d[Int((x + shift.x) + ((y + shift.y) + (z + shift.z) * span) * span)] = -band }
                  }
                }
              }
            }
          }
        }
      }

      let d = samples, color = paints, mask = masks

      // the signs of each row of samples as bits so rows without a crossing are skipped at once
      var signs = [UInt16](repeating: 0, count: Int(span * span))
      for (i, value) in d.enumerated() where value < 0 { signs[i / Int(span)] |= 1 << UInt16(i % Int(span)) }
      let full: UInt16 = (1 << UInt16(span)) - 1
      guard signs.contains(where: { $0 != 0 }), signs.contains(where: { $0 != full }) else { return nil }

      @inline(__always) func row(_ y: Int32, _ z: Int32) -> UInt16
      {
        signs[Int((y + apron) + (z + apron) * span)]
      }

      @inline(__always) func at(_ x: Int32, _ y: Int32, _ z: Int32) -> Int
      {
        Int((x + apron) + ((y + apron) + (z + apron) * span) * span)
      }

      @inline(__always) func gradient(_ x: Int32, _ y: Int32, _ z: Int32) -> SIMD3<Float>
      {
        SIMD3(d[at(x + 1, y, z)] - d[at(x - 1, y, z)],
              d[at(x, y + 1, z)] - d[at(x, y - 1, z)],
              d[at(x, y, z + 1)] - d[at(x, y, z - 1)])
      }

      // a vertex in every cell the surface passes through, cells from minus one to the brick's last
      let cells = Self.cells
      var vertexOf = [Int32](repeating: -1, count: Int(cells * cells * cells))
      var chunk = SculptChunk()
      chunk.vertices.reserveCapacity(160)
      chunk.indices.reserveCapacity(960)
      let corners: [SIMD3<Int32>] = [SIMD3(0, 0, 0), SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(1, 1, 0),
                                     SIMD3(0, 0, 1), SIMD3(1, 0, 1), SIMD3(0, 1, 1), SIMD3(1, 1, 1)]
      let edges: [(Int, Int)] = [(0, 1), (2, 3), (4, 5), (6, 7), (0, 2), (1, 3), (4, 6), (5, 7), (0, 4), (1, 5), (2, 6), (3, 7)]
      let voxel = volume.voxel
      let base = key &* side

      // cells from minus one to the brick's last, as bits from one to nine
      let cellBits: UInt16 = ((1 << UInt16(side + 1)) - 1) << UInt16(apron - 1)

      for z: Int32 in -1 ..< side
      {
        for y: Int32 in -1 ..< side
        {
          let r00 = row(y, z), r10 = row(y + 1, z), r01 = row(y, z + 1), r11 = row(y + 1, z + 1)
          let all = r00 & r10 & r01 & r11, any = r00 | r10 | r01 | r11
          var mixed = (any | any >> 1) & ~(all & all >> 1) & cellBits

          while mixed != 0
          {
            let x = Int32(mixed.trailingZeroBitCount) - apron
            mixed &= mixed - 1

            var value = SIMD8<Float>()
            var inside = 0
            for (i, c) in corners.enumerated()
            {
              value[i] = d[at(x + c.x, y + c.y, z + c.z)]
              if value[i] < 0 { inside += 1 }
            }

            guard inside > 0, inside < 8 else { continue }

            var sum = SIMD3<Float>.zero
            var crossings: Float = 0
            for (a, b) in edges where (value[a] < 0) != (value[b] < 0)
            {
              let t = value[a] / (value[a] - value[b])
              sum += SIMD3<Float>(corners[a]) + (SIMD3<Float>(corners[b]) - SIMD3<Float>(corners[a])) * t
              crossings += 1
            }

            let cell = SIMD3(x, y, z)

            // the average of the crossings stair steps on flat and tilted faces, so the vertex slides onto the blended surface
            var f = sum / crossings
            for _ in 0 ..< 2
            {
              let w0 = SIMD3<Float>(1, 1, 1) - f
              let c00 = value[0] * w0.x + value[1] * f.x, c10 = value[2] * w0.x + value[3] * f.x
              let c01 = value[4] * w0.x + value[5] * f.x, c11 = value[6] * w0.x + value[7] * f.x
              let level = (c00 * w0.y + c10 * f.y) * w0.z + (c01 * w0.y + c11 * f.y) * f.z
              let gx = ((value[1] - value[0]) * w0.y + (value[3] - value[2]) * f.y) * w0.z
                + ((value[5] - value[4]) * w0.y + (value[7] - value[6]) * f.y) * f.z
              let gy = (c10 - c00) * w0.z + (c11 - c01) * f.z
              let gz = (c01 * w0.y + c11 * f.y) - (c00 * w0.y + c10 * f.y)
              let g = SIMD3(gx, gy, gz)
              let length = simd_length_squared(g)
              guard length > 1e-12 else { break }
              f = simd_clamp(f - g * (level / length), .zero, SIMD3(repeating: 1))
            }

            // the normal and paint blend across the cell like the distances do
            var normal = SIMD3<Float>.zero
            var paint = SIMD4<Float>.zero
            var masked: Float = 0
            for c in corners
            {
              let w = (c.x == 0 ? 1 - f.x : f.x) * (c.y == 0 ? 1 - f.y : f.y) * (c.z == 0 ? 1 - f.z : f.z)
              let p = cell &+ c
              normal += gradient(p.x, p.y, p.z) * w
              paint += SIMD4<Float>(color[at(p.x, p.y, p.z)]) * w
              masked += Float(mask[at(p.x, p.y, p.z)]) * w
            }

            let length = simd_length(normal)
            normal = length > 1e-9 ? normal / length : SIMD3(0, 1, 0)
            let world = (SIMD3<Float>(base &+ cell) + f) * voxel
            let rgba = SIMD4<UInt8>(paint.rounded(.toNearestOrAwayFromZero))
            let packed = UInt32(rgba.x) | UInt32(rgba.y) << 8 | UInt32(rgba.z) << 16 | UInt32(rgba.w) << 24

            vertexOf[Int((x + 1) + ((y + 1) + (z + 1) * cells) * cells)] = Int32(chunk.vertices.count)
            chunk.vertices.append(SculptVertex(x: world.x, y: world.y, z: world.z, nx: normal.x, ny: normal.y, nz: normal.z,
                                               color: packed, mask: masked / 255))
          }
        }
      }

      @inline(__always) func vertex(_ c: SIMD3<Int32>) -> Int32
      {
        guard c.x >= -1, c.y >= -1, c.z >= -1, c.x < side, c.y < side, c.z < side else { return -1 }
        return vertexOf[Int((c.x + 1) + ((c.y + 1) + (c.z + 1) * cells) * cells)]
      }

      // the brick owns the edges leaving its grid points forward, and the ones reaching in from a side with no dense brick
      let units: [SIMD3<Int32>] = [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)]
      let openBelow = [around[12] == nil, around[10] == nil, around[4] == nil]

      for axis in 0 ..< 3
      {
        let e = units[axis], u = units[(axis + 1) % 3], v = units[(axis + 2) % 3]
        let start: Int32 = openBelow[axis] ? -1 : 0

        for z: Int32 in (axis == 2 ? start : 0) ..< side
        {
          for y: Int32 in (axis == 1 ? start : 0) ..< side
          {
            // the edges along this row whose ends differ in sign, as bits
            let r = row(y, z)
            let next = axis == 0 ? r >> 1 : axis == 1 ? row(y + 1, z) : row(y, z + 1)
            let from = (axis == 0 ? start : 0) + apron
            var crossing = (r ^ next) & (((1 << UInt16(side + apron)) - 1) & ~((1 << UInt16(from)) - 1))

            while crossing != 0
            {
              let x = Int32(crossing.trailingZeroBitCount) - apron
              crossing &= crossing - 1

              let p = SIMD3(x, y, z)
              let q = p &+ e
              let a = d[at(p.x, p.y, p.z)], b = d[at(q.x, q.y, q.z)]
              guard (a < 0) != (b < 0) else { continue }

              let v0 = vertex(p), v1 = vertex(p &- u), v2 = vertex(p &- u &- v), v3 = vertex(p &- v)
              guard v0 >= 0, v1 >= 0, v2 >= 0, v3 >= 0 else { continue }

              // winds the quad to face out of the solid side, decided by the whole quad since a corner can face the other way
              let outward = SIMD3<Float>(e) * (a < 0 ? 1 : -1)
              let p0 = chunk.vertices[Int(v0)].position, p1 = chunk.vertices[Int(v1)].position
              let p2 = chunk.vertices[Int(v2)].position, p3 = chunk.vertices[Int(v3)].position
              let area = simd_cross(p0, p1) + simd_cross(p1, p2) + simd_cross(p2, p3) + simd_cross(p3, p0)
              let facing = simd_dot(area, outward) > 0
              let (a0, a1, a2, a3) = facing ? (v0, v1, v2, v3) : (v0, v3, v2, v1)
              let (q0, q1, q2, q3) = facing ? (p0, p1, p2, p3) : (p0, p3, p2, p1)

              // splits along the diagonal that keeps both halves facing out, the shorter one when both do
              func out(_ x: SIMD3<Float>, _ y: SIMD3<Float>, _ z: SIMD3<Float>) -> Bool
              {
                simd_dot(simd_cross(y - x, z - x), outward) > 0
              }

              let first = out(q0, q1, q2) && out(q0, q2, q3)
              let second = out(q0, q1, q3) && out(q1, q2, q3)
              let shorter = first == second ? simd_distance_squared(q0, q2) <= simd_distance_squared(q1, q3) : first
              let (t0, t1, t2) = shorter ? (a0, a1, a2) : (a0, a1, a3)
              let (t3, t4, t5) = shorter ? (a0, a2, a3) : (a1, a2, a3)
              chunk.indices.append(UInt32(t0))
              chunk.indices.append(UInt32(t1))
              chunk.indices.append(UInt32(t2))
              chunk.indices.append(UInt32(t3))
              chunk.indices.append(UInt32(t4))
              chunk.indices.append(UInt32(t5))
            }
          }
        }
      }

      return chunk.isEmpty ? nil : chunk
    }

    /// meshes many bricks across every core
    static func mesh(_ volume: SculptVolume, _ keys: [SIMD3<Int32>]) -> [SculptChunk?]
    {
      var out = [SculptChunk?](repeating: nil, count: keys.count)
      out.withUnsafeMutableBufferPointer
      { out in
        DispatchQueue.concurrentPerform(iterations: keys.count) { i in out[i] = mesh(volume, keys[i]) }
      }

      return out
    }

    /// one welded mesh of the whole volume for usd, vertices shared where bricks meet
    static func welded(_ chunks: some Sequence<SculptChunk>, voxel: Float)
      -> (points: [SIMD3<Float>], normals: [SIMD3<Float>], colors: [SIMD4<UInt8>], indices: [Int32])
    {
      var points: [SIMD3<Float>] = []
      var normals: [SIMD3<Float>] = []
      var colors: [SIMD4<UInt8>] = []
      var indices: [Int32] = []
      var seen: [SIMD3<Int32>: Int32] = [:]
      let scale = 1 / (voxel * 0.01)

      for chunk in chunks
      {
        var remap = [Int32](repeating: 0, count: chunk.vertices.count)
        for (i, v) in chunk.vertices.enumerated()
        {
          // the same cell gives the same position in both bricks, so a fine grid finds the twin
          let key = SIMD3<Int32>((v.position * scale).rounded(.toNearestOrAwayFromZero))
          if let found = seen[key]
          {
            remap[i] = found
            continue
          }

          let index = Int32(points.count)
          seen[key] = index
          remap[i] = index
          points.append(v.position)
          normals.append(v.normal)
          colors.append(SIMD4(UInt8(v.color & 0xFF), UInt8(v.color >> 8 & 0xFF), UInt8(v.color >> 16 & 0xFF), UInt8(v.color >> 24)))
        }

        for t in stride(from: 0, to: chunk.indices.count - 2, by: 3)
        {
          let a = remap[Int(chunk.indices[t])], b = remap[Int(chunk.indices[t + 1])], c = remap[Int(chunk.indices[t + 2])]
          if a != b, b != c, a != c { indices += [a, b, c] }
        }
      }

      return (points, normals, colors, indices)
    }
  }
}
