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
  /// The primitive mesh shapes for material
  /// previews, y up, about two units across.
  enum PreviewShape: CaseIterable, Sendable
  {
    case flat, sphere, cube, hair, teapot, cloth, fluid

    var label: String
    {
      switch self
      {
        case .flat: "Flat"
        case .sphere: "Sphere"
        case .cube: "Cube"
        case .hair: "Hair"
        case .teapot: "Teapot"
        case .cloth: "Cloth"
        case .fluid: "Fluid"
      }
    }

    struct Mesh
    {
      var points: [SIMD3<Float>] = []
      var faces: [[Int]] = []
      /// Per face corner, in the order the faces list them.
      var uvs: [SIMD2<Float>] = []
      var smooth = true
    }

    struct Curves
    {
      var points: [SIMD3<Float>] = []
      var counts: [Int] = []
      var width: Float = 0.01
      /// One per point when set, in place of `width`.
      var widths: [Float] = []
    }

    enum Part
    {
      case mesh(Mesh)
      case curves(Curves)
    }

    var parts: [Part]
    {
      switch self
      {
        case .flat: [.mesh(Self.grid(2, 2) { u, v in SIMD3(u * 2 - 1, v * 2 - 1, 0) })]
        case .sphere: [.mesh(Self.sphere(1))]
        case .cube: [.mesh(Self.cube(0.75))]
        case .hair: [.curves(Self.hair())]
        case .teapot: [.mesh(Self.teapot())]
        case .cloth: [.mesh(Self.cloth())]
        case .fluid: Self.fluid().map(Part.mesh)
      }
    }

    /// Gathers quads with their corners uvs,
    /// welding points that land on each other
    /// so a smooth surface shades across its
    /// seams, and dropping the corners a weld
    /// folds onto their neighbors.
    private struct Builder
    {
      var mesh = Mesh()
      var weld = true
      private var index: [SIMD3<Int32>: Int] = [:]

      private mutating func point(_ p: SIMD3<Float>) -> Int
      {
        guard weld else
        {
          mesh.points.append(p)
          return mesh.points.count - 1
        }

        let key = SIMD3<Int32>((p * 1e4).rounded(.toNearestOrAwayFromZero))
        if let i = index[key] { return i }
        mesh.points.append(p)
        index[key] = mesh.points.count - 1
        return mesh.points.count - 1
      }

      mutating func face(_ corners: [(SIMD3<Float>, SIMD2<Float>)])
      {
        var loop: [Int] = [], uvs: [SIMD2<Float>] = []
        for (p, uv) in corners
        {
          let i = point(p)
          if loop.last == i { continue }
          loop.append(i)
          uvs.append(uv)
        }

        if loop.count > 1, loop.first == loop.last
        {
          loop.removeLast()
          uvs.removeLast()
        }

        guard loop.count >= 3 else { return }
        mesh.faces.append(loop)
        mesh.uvs += uvs
      }

      /// A `columns` by `rows` grid over `at`, its uv the grid's.
      mutating func grid(_ columns: Int, _ rows: Int, _ at: (Float, Float) -> SIMD3<Float>)
      {
        for j in 0 ..< rows
        {
          for i in 0 ..< columns
          {
            let corners = [(i, j), (i + 1, j), (i + 1, j + 1), (i, j + 1)].map
            { c -> (SIMD3<Float>, SIMD2<Float>) in
              let uv = SIMD2(Float(c.0) / Float(columns), Float(c.1) / Float(rows))
              return (at(uv.x, uv.y), uv)
            }

            face(corners)
          }
        }
      }
    }

    private static func grid(_ columns: Int, _ rows: Int, _ at: (Float, Float) -> SIMD3<Float>) -> Mesh
    {
      var b = Builder()
      b.grid(columns, rows, at)
      return b.mesh
    }

    private static func sphere(_ r: Float) -> Mesh
    {
      grid(64, 32)
      { u, v in
        let phi = u * 2 * .pi, theta = v * .pi
        return SIMD3(-sin(theta) * cos(phi), -cos(theta), sin(theta) * sin(phi)) * r
      }
    }

    private static func cube(_ h: Float) -> Mesh
    {
      var b = Builder()
      b.weld = false
      b.mesh.smooth = false
      // turned a corner toward the view and tipped forward, so its top and two sides show.
      let turn = simd_quatf(angle: .pi / 7, axis: SIMD3(1, 0, 0)) * simd_quatf(angle: .pi / 5, axis: SIMD3(0, 1, 0))
      for axis in 0 ..< 3
      {
        for sign: Float in [-1, 1]
        {
          b.grid(1, 1)
          { u, v in
            var p = SIMD3<Float>(repeating: 0)
            p[axis] = sign * h
            p[(axis + 1) % 3] = (u * 2 - 1) * h * sign
            p[(axis + 2) % 3] = (v * 2 - 1) * h
            return turn.act(p)
          }
        }
      }

      return b.mesh
    }

    /// A tuft of strands rooted in a patch at the bottom, rising and curling over to one side,
    /// each one tapering to its tip.
    private static func hair() -> Curves
    {
      var c = Curves()
      let strands = 2600, segments = 24
      for s in 0 ..< strands
      {
        func random(_ k: Int) -> Float
        {
          let x = sin(Double(s * 11 + k) * 12.9898) * 43758.5453
          return Float(x - x.rounded(.down))
        }

        let around = random(0) * 2 * .pi, out = random(1).squareRoot()
        var p = SIMD3<Float>(-0.45 + cos(around) * out * 0.32, -1.1, sin(around) * out * 0.22)
        let length = 2.1 * (0.85 + 0.25 * random(2))
        let curl = (95 + 30 * random(3)) * .pi / 180
        let lean = (random(4) - 0.5) * 0.35
        let phase = random(5) * 2 * .pi
        let step = length / Float(segments)

        for k in 0 ... segments
        {
          let t = Float(k) / Float(segments)
          c.points.append(p + SIMD3(0, 0, 0.05 * sin(t * 8 + phase) * t))
          c.widths.append(0.007 * (1 - 0.8 * t))
          let angle = curl * t * t
          p += SIMD3(sin(angle), cos(angle), lean) * step
        }

        c.counts.append(segments + 1)
      }

      return c
    }

    /// A floor curving up into a back wall behind the shapes, in checker squares split light and dark.
    static func backdrop() -> (light: Mesh, dark: Mesh)
    {
      let floorY: Float = -1.35, front: Float = 5, bendZ: Float = -1.5, radius: Float = 1.2, top: Float = 6
      let floorLength = front - bendZ, bendLength = radius * .pi / 2
      let wallLength = top - (floorY + radius)
      let length = floorLength + bendLength + wallLength
      let square: Float = 0.8, halfWidth: Float = 6.4

      /// Along the profile from the front of the floor, up the bend, to the top of the wall.
      func profile(_ s: Float) -> SIMD2<Float>
      {
        if s <= floorLength { return SIMD2(floorY, front - s) }
        if s <= floorLength + bendLength
        {
          let a = (s - floorLength) / radius
          return SIMD2(floorY + radius - radius * cos(a), bendZ - radius * sin(a))
        }

        return SIMD2(floorY + radius + s - floorLength - bendLength, bendZ - radius)
      }

      var light = Builder(), dark = Builder()
      let columns = Int(halfWidth * 2 / square), rows = Int((length / square).rounded(.up)) * 4
      for j in 0 ..< rows
      {
        let s0 = Float(j) / Float(rows) * length, s1 = Float(j + 1) / Float(rows) * length
        let a = profile(s0), b = profile(s1)
        for i in 0 ..< columns
        {
          let x0 = -halfWidth + Float(i) * square, x1 = x0 + square
          let corners = [(x0, a, s0), (x1, a, s0), (x1, b, s1), (x0, b, s1)].map
          { x, yz, s in (SIMD3(x, yz.x, yz.y), SIMD2(x / square, s / square)) }

          if (i + Int((s0 + s1) * 0.5 / square)) % 2 == 0 { light.face(corners) } else { dark.face(corners) }
        }
      }

      return (light.mesh, dark.mesh)
    }

    /// Newell's patches tessellated, stood on its base about the middle.
    private static func teapot() -> Mesh
    {
      var b = Builder()
      let n = 14
      func bernstein(_ t: Float) -> SIMD4<Float>
      {
        let s = 1 - t
        return SIMD4(s * s * s, 3 * t * s * s, 3 * t * t * s, t * t * t)
      }

      for patch in Teapot.patches
      {
        let control = patch.map { Teapot.points[$0] }
        b.grid(n, n)
        { u, v in
          let bu = bernstein(u), bv = bernstein(v)
          var p = SIMD3<Float>.zero
          for row in 0 ..< 4 { for column in 0 ..< 4 { p += control[row * 4 + column] * bu[row] * bv[column] } }
          return (p - SIMD3(0, 1.575, 0)) * 0.55
        }
      }

      return b.mesh
    }

    /// A sheet dropped over a ball, falling off its sides into folds.
    private static func cloth() -> Mesh
    {
      grid(96, 96)
      { u, v in
        let x = (u * 2 - 1) * 1.5, z = (1 - v * 2) * 1.5
        let d = (x * x + z * z).squareRoot(), r: Float = 0.75
        let cap = (max(r * r - min(d, r) * min(d, r), 0)).squareRoot()
        let past = max(d - r, 0)
        let folds = sin(atan2(z, x) * 9) * 0.09 * min(past * 2, 1)
        let fall = -past * 1.25 + folds
        return SIMD3(x * (1 - past * 0.18), max(cap + fall, -0.95), z * (1 - past * 0.18))
      }
    }

    /// A drop's splash creating a crown thrown up
    /// off a rippling pool with the drop above it.
    private static func fluid() -> [Mesh]
    {
      let pool = grid(160, 48)
      { u, v in
        let angle = u * 2 * .pi, r = v * 1.4
        let crown = exp(-pow((r - 0.75) / 0.13, 2)) * 0.42 * (1 + 0.45 * sin(angle * 14))
        let ripple = cos(r * 18) * 0.025 * exp(-r * 1.5)
        return SIMD3(r * cos(angle), crown + ripple - 0.45, r * sin(angle))
      }

      var drop = sphere(0.14)
      drop.points = drop.points.map { SIMD3($0.x, $0.y * 1.25 + 0.55, $0.z) }
      return [pool, drop]
    }
  }
}
