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
  /// the sculpting brushes, each with its icon and key
  enum SculptBrush: String, CaseIterable, Sendable
  {
    case draw = "Draw"
    case clay = "Clay"
    case blob = "Blob"
    case inflate = "Inflate"
    case smooth = "Smooth"
    case crease = "Crease"
    case pinch = "Pinch"
    case flatten = "Flatten"
    case scrape = "Scrape"
    case grab = "Grab"
    case snake = "Snake Hook"
    case tube = "Tube"
    case paint = "Paint"
    case mask = "Mask"
    case pencil = "Pencil"

    var symbol: String
    {
      switch self
      {
        case .draw: "scribble"
        case .clay: "square.stack.3d.up.fill"
        case .blob: "circle.fill"
        case .inflate: "circle.dashed.inset.filled"
        case .smooth: "drop.fill"
        case .crease: "chevron.down"
        case .pinch: "arrow.down.right.and.arrow.up.left"
        case .flatten: "rectangle.compress.vertical"
        case .scrape: "minus.rectangle"
        case .grab: "hand.raised.fill"
        case .snake: "point.topleft.down.to.point.bottomright.curvepath"
        case .tube: "cable.connector"
        case .paint: "paintbrush.fill"
        case .mask: "theatermasks.fill"
        case .pencil: "pencil.tip"
      }
    }

    /// the key that picks the brush on a keyboard
    var key: Character
    {
      switch self
      {
        case .draw: "d"
        case .clay: "c"
        case .blob: "b"
        case .inflate: "i"
        case .smooth: "s"
        case .crease: "e"
        case .pinch: "p"
        case .flatten: "t"
        case .scrape: "r"
        case .grab: "g"
        case .snake: "k"
        case .tube: "u"
        case .paint: "v"
        case .mask: "m"
        case .pencil: "n"
      }
    }

    /// how strong the brush starts out
    var defaultStrength: Double
    {
      switch self
      {
        case .grab, .snake, .blob, .tube: 1
        case .smooth: 0.6
        case .paint, .mask, .pencil: 0.8
        default: 0.5
      }
    }

    /// brushes that follow the drag rather than laying dabs along it
    var drags: Bool
    {
      self == .grab || self == .snake
    }

    /// brushes that keep their dabs closer together along a stroke
    var spacing: Float
    {
      switch self
      {
        case .tube, .snake: 0.05
        case .blob: 0.35
        default: 0.12
      }
    }

    /// brushes that lay down volume
    var adds: Bool
    {
      switch self
      {
        case .draw, .clay, .blob, .inflate, .tube: true
        default: false
      }
    }

    /// the groups the tool shelf shows them in
    static let groups: [[SculptBrush]] = [
      [.draw, .clay, .blob, .inflate],
      [.smooth, .crease, .pinch, .flatten, .scrape],
      [.grab, .snake, .tube],
      [.paint, .mask, .pencil],
    ]
  }

  /// how a brush fades from its center to its rim
  enum SculptFalloff: String, CaseIterable, Sendable
  {
    case smooth = "Smooth"
    case sphere = "Sphere"
    case sharp = "Sharp"
    case root = "Root"
    case linear = "Linear"
    case constant = "Constant"

    @inline(__always)
    func callAsFunction(_ t: Float) -> Float
    {
      guard t < 1 else { return 0 }
      let x = max(t, 0)
      switch self
      {
        case .smooth: return 1 - x * x * (3 - 2 * x)
        case .sphere: return (1 - x * x).squareRoot()
        case .sharp: return (1 - x) * (1 - x)
        case .root: return 1 - x.squareRoot()
        case .linear: return 1 - x
        case .constant: return 1
      }
    }
  }

  /// the primitive shapes that can be put into a sculpt
  enum SculptShape: String, CaseIterable, Sendable
  {
    case sphere = "Sphere"
    case box = "Box"
    case cylinder = "Cylinder"
    case capsule = "Capsule"
    case torus = "Torus"

    var symbol: String
    {
      switch self
      {
        case .sphere: "circle"
        case .box: "cube"
        case .cylinder: "cylinder"
        case .capsule: "capsule"
        case .torus: "circle.circle"
      }
    }

    /// the signed distance to the shape in its own frame, unit sized with `size` stretching it
    @inline(__always)
    func distance(_ p: SIMD3<Float>, _ size: SIMD3<Float>) -> Float
    {
      switch self
      {
        case .sphere:
          // a stretched sphere, scaled back so the distance stays close to true
          let q = p / size
          return (simd_length(q) - 1) * simd_reduce_min(size)
        case .box:
          let round = simd_reduce_min(size) * 0.12
          let q = abs(p) - (size - round)
          return simd_length(simd_max(q, .zero)) + min(simd_reduce_max(q), 0) - round
        case .cylinder:
          let r = simd_length(SIMD2(p.x, p.z) / SIMD2(size.x, size.z)) * min(size.x, size.z) - min(size.x, size.z)
          let h = abs(p.y) - size.y
          return min(max(r, h), 0) + simd_length(simd_max(SIMD2(r, h), .zero))
        case .capsule:
          let r = min(size.x, size.z)
          let y = max(abs(p.y) - max(size.y - r, 0), 0)
          return simd_length(SIMD3(p.x, y, p.z)) - r
        case .torus:
          let minor = min(size.y, size.x * 0.5)
          let q = SIMD2(simd_length(SIMD2(p.x, p.z)) - (size.x - minor), p.y)
          return simd_length(q) - minor
      }
    }
  }

  /// how a shape combines with the sculpt
  enum SculptCombine: String, CaseIterable, Sendable
  {
    case add = "Add"
    case subtract = "Subtract"
    case intersect = "Intersect"
  }

  /// one dab of a brush, everything a kernel needs to change the voxels it reaches
  struct SculptDab: Sendable
  {
    var brush: SculptBrush
    var center: SIMD3<Float>
    var normal: SIMD3<Float>
    var radius: Float
    /// already scaled by pressure, negative when inverted
    var strength: Float
    var falloff: SculptFalloff
    /// how far the drag moved, for grab since the stroke began and for snake hook since the last dab
    var delta = SIMD3<Float>.zero
    /// where the stroke began, for grab
    var anchor = SIMD3<Float>.zero
    /// the previous dab, for tube segments
    var previous = SIMD3<Float>.zero
    var color = SIMD4<UInt8>(255, 255, 255, 40)
    /// how much an adding brush paints as it goes
    var paints: Float = 0
    var ignoresMask = false
  }

  /// keeps a brick's state before a stroke first changes it, the state is only made when it is wanted
  typealias SculptRecorder = (SIMD3<Int32>, () -> SculptBrickState) -> Void

  /// distances a kernel reads while the bricks it writes change under it
  protocol SculptField
  {
    var voxel: Float { get }
    func distance(_ g: SIMD3<Int32>) -> Float
  }

  /// the distances bricks held before this dab, falling back on the volume for the ones it doesn't touch
  struct SculptSnapshot: SculptField, @unchecked Sendable
  {
    /// the copies in one block of memory with a flat grid over their box, read through plain pointers
    final class Copies: @unchecked Sendable
    {
      /// each copy keeps one extra layer past its high faces so the eight points around any spot sit in one copy
      static let span = Int(SculptBrick.side) + 1
      static let size = span * span * span

      let lo: SIMD3<Int32>
      let extent: SIMD3<Int32>
      /// where each grid cell's copy starts in `values`, minus one for none
      let table: UnsafeMutableBufferPointer<Int32>
      let values: UnsafeMutableBufferPointer<Float>

      @inline(__always)
      static func index(_ x: Int32, _ y: Int32, _ z: Int32) -> Int
      {
        Int(x) + span * (Int(y) + span * Int(z))
      }

      /// what a brick beside a copy holds, read the way the snapshot reads anything it holds no copy of
      private enum Beside
      {
        case values([Float])
        case fill(Float)
      }

      init(_ copies: [(SIMD3<Int32>, [Float])], states: [SIMD3<Int32>: SculptBrickState], volume: SculptVolume)
      {
        var lo = copies.first?.0 ?? .zero, hi = lo
        for (k, _) in copies
        {
          lo = simd_min(lo, k)
          hi = simd_max(hi, k)
        }

        let extent = copies.isEmpty ? .zero : hi &- lo &+ 1
        self.lo = lo
        self.extent = extent
        table = .allocate(capacity: Int(extent.x) * Int(extent.y) * Int(extent.z))
        table.initialize(repeating: -1)
        values = .allocate(capacity: max(copies.count * Self.size, 1))

        for (n, (k, _)) in copies.enumerated()
        {
          let o = k &- lo
          table[Int(o.x) + Int(extent.x) * (Int(o.y) + Int(extent.y) * Int(o.z))] = Int32(n * Self.size)
        }

        let band = volume.band
        let bricks = volume.bricks
        let inside = volume.inside
        let cells = table, store = values, low = lo
        func beside(_ k: SIMD3<Int32>) -> Beside
        {
          let o = k &- low
          if o.x >= 0, o.y >= 0, o.z >= 0, o.x < extent.x, o.y < extent.y, o.z < extent.z
          {
            let start = cells[Int(o.x) + Int(extent.x) * (Int(o.y) + Int(extent.y) * Int(o.z))]
            if start >= 0 { return .values(copies[Int(start) / Self.size].1) }
          }

          if !states.isEmpty, let state = states[k]
          {
            switch state
            {
              case .absent: return .fill(band)
              case .inside: return .fill(-band)
              case let .dense(brick): return .values(brick.distance)
            }
          }

          if let brick = bricks[k] { return .values(brick.distance) }
          return .fill(inside.contains(k) ? -band : band)
        }

        let steps: [SIMD3<Int32>] = [SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(1, 1, 0), SIMD3(0, 0, 1), SIMD3(1, 0, 1),
                                     SIMD3(0, 1, 1), SIMD3(1, 1, 1)]
        let side = SculptBrick.side
        DispatchQueue.concurrentPerform(iterations: copies.count)
        { n in
          let (k, own) = copies[n]
          let out = store.baseAddress! + n * Self.size
          own.withUnsafeBufferPointer
          { own in
            for z in 0 ..< side
            {
              for y in 0 ..< side
              {
                (out + Self.index(0, y, z)).update(from: own.baseAddress! + SculptBrick.index(0, y, z), count: Int(side))
              }
            }
          }

          // the layer past the high faces, from whichever of the seven bricks beyond holds each point
          for step in steps
          {
            let xs = step.x == 1 ? side ... side : 0 ... side - 1
            let ys = step.y == 1 ? side ... side : 0 ... side - 1
            let zs = step.z == 1 ? side ... side : 0 ... side - 1
            switch beside(k &+ step)
            {
              case let .values(theirs):
                theirs.withUnsafeBufferPointer
                { theirs in
                  for z in zs
                  {
                    for y in ys
                    {
                      for x in xs { out[Self.index(x, y, z)] = theirs[SculptBrick.index(x & 7, y & 7, z & 7)] }
                    }
                  }
                }
              case let .fill(value):
                for z in zs
                {
                  for y in ys
                  {
                    for x in xs { out[Self.index(x, y, z)] = value }
                  }
                }
            }
          }
        }
      }

      deinit
      {
        table.deallocate()
        values.deallocate()
      }

      /// the copy kept for a brick, nil when the dab didn't keep one
      @inline(__always)
      func copy(_ k: SIMD3<Int32>) -> UnsafeMutablePointer<Float>?
      {
        let o = k &- lo
        guard o.x >= 0, o.y >= 0, o.z >= 0, o.x < extent.x, o.y < extent.y, o.z < extent.z else { return nil }
        let start = table[Int(o.x) + Int(extent.x) * (Int(o.y) + Int(extent.y) * Int(o.z))]
        return start < 0 ? nil : values.baseAddress! + Int(start)
      }
    }

    let copies: Copies
    let states: [SIMD3<Int32>: SculptBrickState]
    let volume: SculptVolume

    init(copies: [SIMD3<Int32>: [Float]], states: [SIMD3<Int32>: SculptBrickState], volume: SculptVolume)
    {
      self.init(Copies(copies.map { ($0.key, $0.value) }, states: states, volume: volume), states: states, volume: volume)
    }

    init(_ copies: Copies, states: [SIMD3<Int32>: SculptBrickState], volume: SculptVolume)
    {
      self.copies = copies
      self.states = states
      self.volume = volume
    }

    var voxel: Float
    {
      volume.voxel
    }

    @inline(__always)
    func distance(_ g: SIMD3<Int32>) -> Float
    {
      let k = SculptVolume.key(g)
      let l = SculptVolume.local(g)
      if let copy = copies.copy(k) { return copy[Copies.index(l.x, l.y, l.z)] }

      if !states.isEmpty, let state = states[k]
      {
        switch state
        {
          case .absent: return volume.band
          case .inside: return -volume.band
          case let .dense(brick): return brick.distance[SculptBrick.index(l.x, l.y, l.z)]
        }
      }

      return volume.distance(g)
    }
  }
}

extension Kraken.SculptVolume: Kraken.SculptField {}

extension Kraken
{
  /// the eight grid points around a point from one brick's distances, nil when they straddle a brick edge
  @inline(__always)
  nonisolated static func blendedInside(_ distance: [Float], _ l: SIMD3<Int32>, _ t: SIMD3<Float>) -> Float
  {
    distance.withUnsafeBufferPointer { blendedInside($0.baseAddress!, l, t) }
  }

  @inline(__always)
  nonisolated static func blendedInside(_ distance: UnsafePointer<Float>, _ l: SIMD3<Int32>, _ t: SIMD3<Float>) -> Float
  {
    let i = SculptBrick.index(l.x, l.y, l.z)
    let x00 = distance[i] + (distance[i + 1] - distance[i]) * t.x
    let x10 = distance[i + 8] + (distance[i + 9] - distance[i + 8]) * t.x
    let x01 = distance[i + 64] + (distance[i + 65] - distance[i + 64]) * t.x
    let x11 = distance[i + 72] + (distance[i + 73] - distance[i + 72]) * t.x
    let y0 = x00 + (x10 - x00) * t.y
    let y1 = x01 + (x11 - x01) * t.y
    return y0 + (y1 - y0) * t.z
  }
}

extension Kraken.SculptSnapshot
{
  /// the distance anywhere, one brick lookup when the eight grid points share a brick
  @inline(__always)
  func blended(_ p: SIMD3<Float>) -> Float
  {
    let q = p / voxel
    let f = floor(q)
    let g = Kraken.SculptVolume.whole(f)
    if let copy = copies.copy(Kraken.SculptVolume.key(g))
    {
      // the same blend as the slow path, in the padded copy's layout
      let l = Kraken.SculptVolume.local(g), t = q - f
      let s = Copies.span
      let i = Copies.index(l.x, l.y, l.z)
      let x00 = copy[i] + (copy[i + 1] - copy[i]) * t.x
      let x10 = copy[i + s] + (copy[i + s + 1] - copy[i + s]) * t.x
      let x01 = copy[i + s * s] + (copy[i + s * s + 1] - copy[i + s * s]) * t.x
      let x11 = copy[i + s * s + s] + (copy[i + s * s + s + 1] - copy[i + s * s + s]) * t.x
      let y0 = x00 + (x10 - x00) * t.y
      let y1 = x01 + (x11 - x01) * t.y
      return y0 + (y1 - y0) * t.z
    }

    return slowBlended(g, q - f)
  }

  /// the eight grid points around a point one at a time, where they straddle bricks
  private func slowBlended(_ g: SIMD3<Int32>, _ t: SIMD3<Float>) -> Float
  {
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
}

extension Kraken.SculptVolume
{
  /// the distance anywhere, one brick lookup when the eight grid points share a dense brick
  @inline(__always)
  func blended(_ p: SIMD3<Float>) -> Float
  {
    let q = p / voxel
    let f = floor(q)
    let g = Kraken.SculptVolume.whole(f)
    let l = Self.local(g)
    if l.x < 7, l.y < 7, l.z < 7, let brick = bricks[Self.key(g)]
    {
      return Kraken.blendedInside(brick.distance, l, q - f)
    }

    return (self as any Kraken.SculptField).blended(p)
  }
}

extension Kraken.SculptField
{
  /// the distance anywhere, blended between the grid points around it
  @inline(__always)
  func blended(_ p: SIMD3<Float>) -> Float
  {
    let q = p / voxel
    let f = floor(q)
    let t = q - f
    let g = Kraken.SculptVolume.whole(f)

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
}

extension Kraken.SculptField
{
  /// where a ray first meets the surface inside a box, for fields other than the live volume
  func raycast(origin: SIMD3<Float>, direction: SIMD3<Float>, within box: (lo: SIMD3<Float>, hi: SIMD3<Float>)) -> SIMD3<Float>?
  {
    let inv = 1 / direction
    let t0 = (box.lo - origin) * inv, t1 = (box.hi - origin) * inv
    var t = max(simd_reduce_max(simd_min(t0, t1)), 0)
    let far = simd_reduce_min(simd_max(t0, t1))
    guard far > t else { return nil }

    var previous = blended(origin + direction * t)
    guard previous >= 0 else { return nil }

    let minimum = voxel * 0.35
    for _ in 0 ..< 20_000 where t < far
    {
      let next = t + max(previous * 0.9, minimum)
      let d = blended(origin + direction * next)
      if d < 0
      {
        var a = t, b = next
        for _ in 0 ..< 8
        {
          let m = (a + b) * 0.5
          if blended(origin + direction * m) < 0 { b = m } else { a = m }
        }

        return origin + direction * b
      }

      t = next
      previous = d
    }

    return nil
  }
}

extension Kraken.SculptVolume
{
  typealias Snapshot = Kraken.SculptSnapshot

  /// one voxel as a kernel sees and changes it
  struct Voxel
  {
    var g: SIMD3<Int32>
    var p: SIMD3<Float>
    var d: Float
    var color: SIMD4<UInt8>
    var mask: UInt8
  }

  /// whether any grid point is nearer the surface than a limit, sixteen points at a time
  @inline(__always)
  static func holdsSurface(_ distance: [Float], within limit: Float) -> Bool
  {
    distance.withUnsafeBufferPointer
    { p in
      let raw = UnsafeRawPointer(p.baseAddress!)
      var i = 0
      while i + 16 <= p.count
      {
        let v = raw.loadUnaligned(fromByteOffset: i * 4, as: SIMD16<Float>.self)
        if any((v .< limit) .& (v .> -limit)) { return true }
        i += 16
      }

      while i < p.count
      {
        if abs(p[i]) < limit { return true }
        i += 1
      }

      return false
    }
  }

  /// whether every grid point holds exactly one value
  @inline(__always)
  static func holdsOnly(_ distance: [Float], _ value: Float) -> Bool
  {
    distance.withUnsafeBufferPointer
    { p in
      let raw = UnsafeRawPointer(p.baseAddress!)
      var i = 0
      while i + 16 <= p.count
      {
        let v = raw.loadUnaligned(fromByteOffset: i * 4, as: SIMD16<Float>.self)
        if any(v .!= value) { return false }
        i += 16
      }

      while i < p.count
      {
        if p[i] != value { return false }
        i += 1
      }

      return true
    }
  }

  /// whether any grid point lies as far from the surface as a limit or further
  @inline(__always)
  static func holdsClamped(_ distance: [Float], at limit: Float) -> Bool
  {
    distance.withUnsafeBufferPointer
    { p in
      let raw = UnsafeRawPointer(p.baseAddress!)
      var i = 0
      while i + 16 <= p.count
      {
        let v = raw.loadUnaligned(fromByteOffset: i * 4, as: SIMD16<Float>.self)
        if any((v .>= limit) .| (v .<= -limit)) { return true }
        i += 16
      }

      while i < p.count
      {
        if abs(p[i]) >= limit { return true }
        i += 1
      }

      return false
    }
  }

  /// readies the bricks in a world box for writing, keeping each one's earlier state with `record` first
  func prepare(from lo: SIMD3<Float>, to hi: SIMD3<Float>, record: Kraken.SculptRecorder)
    -> [SIMD3<Int32>]
  {
    let keys = keys(from: lo, to: hi)
    for k in keys
    {
      record(k) { state(k) }
      densify(k)
    }

    return keys
  }

  /// copies of the distances in some bricks, for kernels that read around the voxel they write
  func snapshot(_ keys: [SIMD3<Int32>], states: [SIMD3<Int32>: Kraken.SculptBrickState] = [:]) -> Snapshot
  {
    let copies = keys.compactMap { k in bricks[k].map { (k, $0.distance) } }
    return Snapshot(Snapshot.Copies(copies, states: states, volume: self), states: states, volume: self)
  }

  /// runs a kernel over many dense bricks at once, `skip` passing over bricks it wouldn't change, `reach` and `gate` limiting which voxels run it
  @inline(__always)
  func edit(_ keys: [SIMD3<Int32>], skip: ((SIMD3<Int32>, Kraken.SculptBrick) -> Bool)? = nil,
            reach: (center: SIMD3<Float>, squared: Float)? = nil, gate: Float? = nil, _ kernel: (inout Voxel) -> Void)
  {
    let side = Kraken.SculptBrick.side
    let band = band, voxel = voxel

    // which bricks to pass over is told before anything is written, on every core
    let dense = keys.compactMap { k in bricks[k].map { (k, $0) } }
    var passes = [Bool](repeating: false, count: dense.count)
    if let skip
    {
      passes.withUnsafeMutableBufferPointer
      { passes in
        DispatchQueue.concurrentPerform(iterations: dense.count) { i in passes[i] = skip(dense[i].0, dense[i].1) }
      }
    }

    let targets = zip(dense, passes).compactMap { $1 ? nil : $0 }
    var moved = [UInt8](repeating: 0, count: targets.count)

    // rows outside the sphere and the ends of the rest are found with a voxel to spare so rounding never skips one
    let spare = voxel * voxel * 3
    moved.withUnsafeMutableBufferPointer
    { moved in
      DispatchQueue.concurrentPerform(iterations: targets.count)
      { i in
        let (k, brick) = targets[i]
        let origin = k &* side
        var faces: UInt8 = 0

        brick.distance.withUnsafeMutableBufferPointer
        { distance in
          brick.color.withUnsafeMutableBufferPointer
          { color in
            brick.mask.withUnsafeMutableBufferPointer
            { mask in
              @inline(__always) func clamp(_ index: Int, _ x: Int32, _ y: Int32, _ z: Int32)
              {
                let d = distance[index]
                let clamped = max(min(d, band), -band)
                if clamped != d
                {
                  distance[index] = clamped
                  faces |= Self.faces(x, y, z) | 0x80
                }
              }

              for z in 0 ..< side
              {
                for y in 0 ..< side
                {
                  var first: Int32 = 0, last: Int32 = side - 1
                  if let reach
                  {
                    let py = Float(origin.y + y) * voxel - reach.center.y
                    let pz = Float(origin.z + z) * voxel - reach.center.z
                    let room = reach.squared - py * py - pz * pz
                    if room < -spare
                    {
                      first = side
                    }
                    else
                    {
                      let half = max(room, 0).squareRoot()
                      let lo = Int32(((reach.center.x - half) / voxel).rounded(.down)) - 1 - origin.x
                      let hi = Int32(((reach.center.x + half) / voxel).rounded(.up)) + 1 - origin.x
                      first = max(lo, 0)
                      last = min(hi, side - 1)
                    }
                  }

                  for x in 0 ..< side
                  {
                    let index = Kraken.SculptBrick.index(x, y, z)
                    if x < first || x > last
                    {
                      clamp(index, x, y, z)
                      continue
                    }

                    if let gate, !(abs(distance[index]) < gate)
                    {
                      clamp(index, x, y, z)
                      continue
                    }

                    let g = origin &+ SIMD3(x, y, z)
                    var v = Voxel(g: g, p: SIMD3<Float>(g) * voxel, d: distance[index], color: color[index], mask: mask[index])
                    kernel(&v)
                    let d = max(min(v.d, band), -band)
                    if d != distance[index] || v.color != color[index] || v.mask != mask[index]
                    {
                      faces |= Self.faces(x, y, z) | 0x80
                    }
                    distance[index] = d
                    color[index] = v.color
                    mask[index] = v.mask
                  }
                }
              }
            }
          }
        }

        moved[i] = faces
      }
    }

    // the high bit only says the brick changed at all
    for (i, target) in targets.enumerated() where moved[i] != 0
    {
      noteChange(target.0, moved[i] & Self.allFaces)
      unsettle(target.0)
    }
  }

  /// whether a brick and the points within `margin` of it hold one clamped distance, so a blending kernel leaves it alone
  func isQuiet(_ k: SIMD3<Int32>, _ brick: Kraken.SculptBrick, margin: Int32) -> Bool
  {
    let c = brick.distance[0]
    guard c == band || c == -band, Self.holdsOnly(brick.distance, c) else { return false }

    let side = Kraken.SculptBrick.side, w = min(margin, side)
    for dz: Int32 in -1 ... 1
    {
      for dy: Int32 in -1 ... 1
      {
        for dx: Int32 in -1 ... 1 where dx != 0 || dy != 0 || dz != 0
        {
          let n = k &+ SIMD3(dx, dy, dz)
          guard let theirs = bricks[n]?.distance else
          {
            if (inside.contains(n) ? -band : band) != c { return false }
            continue
          }

          @inline(__always) func span(_ d: Int32) -> ClosedRange<Int32>
          {
            d < 0 ? side - w ... side - 1 : d > 0 ? 0 ... w - 1 : 0 ... side - 1
          }

          for z in span(dz)
          {
            for y in span(dy)
            {
              for x in span(dx) where theirs[Kraken.SculptBrick.index(x, y, z)] != c { return false }
            }
          }
        }
      }
    }

    return true
  }

  /// the world box a dab can change, padded by the band so new surface has room
  func reach(_ dab: Kraken.SculptDab) -> (lo: SIMD3<Float>, hi: SIMD3<Float>)
  {
    let pad = SIMD3<Float>(repeating: dab.radius + band + voxel)
    var lo = dab.center - pad, hi = dab.center + pad
    switch dab.brush
    {
      case .grab:
        lo = simd_min(lo, dab.anchor - pad)
        hi = simd_max(hi, dab.anchor + pad)
      case .tube:
        lo = simd_min(lo, dab.previous - pad)
        hi = simd_max(hi, dab.previous + pad)
      default:
        break
    }

    return (lo, hi)
  }

  /// clay, flatten and scrape work to a plane through the surface under the whole brush, other brushes take the dab's center
  func brushPlane(_ dab: Kraken.SculptDab) -> SIMD3<Float>
  {
    let c = dab.center, n = dab.normal, r = dab.radius
    guard dab.brush == .clay || dab.brush == .flatten || dab.brush == .scrape else { return c }

    let a = simd_normalize(abs(n.x) < 0.9 ? simd_cross(n, SIMD3(1, 0, 0)) : simd_cross(n, SIMD3(0, 1, 0)))
    let b = simd_cross(n, a)
    var height: Float = 0, weight: Float = 0
    for ring in 0 ... 4
    {
      let out = r * Float(ring) / 5
      let count = ring == 0 ? 1 : 6 * ring
      for k in 0 ..< count
      {
        let turn = Float(k) / Float(count) * 2 * .pi
        let d = blended(c + (a * cos(turn) + b * sin(turn)) * out)
        guard abs(d) < band * 0.99 else { continue }
        let w = dab.falloff(out / r)
        height -= d * w
        weight += w
      }
    }

    return weight > 0 ? c + n * (height / weight) : c
  }

  /// runs one dab, `origin` gives the volume as the stroke found it for grab
  func apply(_ dab: Kraken.SculptDab, origin makeOrigin: (() -> Snapshot)?, record: Kraken.SculptRecorder)
    -> [SIMD3<Int32>]
  {
    // moves the surface at most half the band in a dab so big brushes don't blend from clamped values into ledges
    let reach = abs(dab.strength) * dab.radius * 0.055 * (dab.brush == .clay ? 1.6 : 1)
    let steps: Bool = switch dab.brush
    {
      case .draw, .inflate, .clay, .crease: true
      default: false
    }

    let shapes: Bool = switch dab.brush
    {
      case .paint, .mask, .pencil: false
      default: true
    }

    // the gpu lays every brush that reads nothing but the volume as it stands, the same arithmetic voxel for voxel
    if makeOrigin == nil, let gpu = Kraken.SculptCompute.available, gpu.handles(dab.brush)
    {
      var used = dab
      let scaled = steps && reach > band * 0.5
      if scaled { used.strength = dab.strength * (band * 0.5 / reach) }

      let box = self.reach(used)
      let local: Bool = switch used.brush
      {
        case .grab, .snake, .blob, .tube: false
        default: true
      }

      let keys = local ? prepareSurface(from: box.lo, to: box.hi, record: record) : prepare(from: box.lo, to: box.hi, record: record)
      if gpu.run(self, used, keys: keys, box: box, plane: brushPlane(used), rebands: scaled || shapes) { return keys }
    }

    guard steps, reach > band * 0.5 else
    {
      let keys = applyOnce(dab, origin: makeOrigin, record: record)
      if shapes { reband(keys) }
      return keys
    }

    // a big brush moves the surface as far as one pass carries it rather than slicing into terraced passes
    var part = dab
    part.strength = dab.strength * (band * 0.5 / reach)
    let keys = applyOnce(part, origin: makeOrigin, record: record)
    reband(keys)
    return keys
  }

  /// readies only the bricks in a box that hold the surface and their neighbors, recording each one's earlier state first
  func prepareSurface(from lo: SIMD3<Float>, to hi: SIMD3<Float>, record: Kraken.SculptRecorder) -> [SIMD3<Int32>]
  {
    let size = Float(Kraken.SculptBrick.side) * voxel
    let a = Self.whole(floor(lo / size)), b = Self.whole(floor(hi / size))
    let limit = band * 0.99

    // the box's bricks as a flat grid, marking them costs an array write where a hashed set costs a hash each time
    let size3 = b &- a &+ 1
    guard size3.x > 0, size3.y > 0, size3.z > 0 else { return [] }
    var near = [Bool](repeating: false, count: Int(size3.x) * Int(size3.y) * Int(size3.z))

    // looks up the bricks around the box one by one when that beats walking the whole volume, a slab of the box per core
    let around = size3 &+ 2
    let lookups = Int(around.x) * Int(around.y) * Int(around.z)
    let bricks = bricks
    var surface: [SIMD3<Int32>] = []
    if lookups < bricks.count
    {
      var slabs = [[SIMD3<Int32>]](repeating: [], count: Int(around.z))
      slabs.withUnsafeMutableBufferPointer
      { slabs in
        DispatchQueue.concurrentPerform(iterations: slabs.count)
        { i in
          let z = a.z - 1 + Int32(i)
          var found: [SIMD3<Int32>] = []
          for y in a.y - 1 ... b.y + 1
          {
            for x in a.x - 1 ... b.x + 1
            {
              let k = SIMD3(x, y, z)
              if let brick = bricks[k], Self.holdsSurface(brick.distance, within: limit) { found.append(k) }
            }
          }
          slabs[i] = found
        }
      }

      surface = slabs.flatMap { $0 }
    }
    else
    {
      let candidates = bricks.filter
      { k, _ in
        k.x >= a.x - 1 && k.y >= a.y - 1 && k.z >= a.z - 1 && k.x <= b.x + 1 && k.y <= b.y + 1 && k.z <= b.z + 1
      }.map { ($0.key, $0.value) }

      var holds = [Bool](repeating: false, count: candidates.count)
      holds.withUnsafeMutableBufferPointer
      { holds in
        DispatchQueue.concurrentPerform(iterations: candidates.count)
        { i in holds[i] = Self.holdsSurface(candidates[i].1.distance, within: limit) }
      }

      surface = zip(candidates, holds).compactMap { $1 ? $0.0 : nil }
    }

    for k in surface
    {
      let from = simd_max(k &- 1, a), to = simd_min(k &+ 1, b)
      guard from.x <= to.x, from.y <= to.y, from.z <= to.z else { continue }
      for z in from.z ... to.z
      {
        for y in from.y ... to.y
        {
          for x in from.x ... to.x
          {
            near[Int(x - a.x) + Int(size3.x) * (Int(y - a.y) + Int(size3.y) * Int(z - a.z))] = true
          }
        }
      }
    }

    var keys: [SIMD3<Int32>] = []
    for (i, marked) in near.enumerated() where marked
    {
      let x = Int32(i % Int(size3.x)), y = Int32((i / Int(size3.x)) % Int(size3.y)), z = Int32(i / (Int(size3.x) * Int(size3.y)))
      keys.append(a &+ SIMD3(x, y, z))
    }

    for k in keys
    {
      record(k) { state(k) }
      densify(k)
    }

    return keys
  }

  /// gives clamped points next to a moved surface their distance back, one voxel past their nearest neighbor
  func reband(_ keys: [SIMD3<Int32>])
  {
    let band = band, voxel = voxel
    let limit = band * 0.99

    guard let first = keys.first else { return }

    // the keys' box, one brick wider, as a flat grid so marks and lookups are array reads instead of hashes
    var lo = first, hi = first
    for k in keys
    {
      lo = simd_min(lo, k)
      hi = simd_max(hi, k)
    }

    lo = lo &- 1
    hi = hi &+ 1
    let extent = hi &- lo &+ 1
    @inline(__always) func slot(_ k: SIMD3<Int32>) -> Int
    {
      Int(k.x - lo.x) + Int(extent.x) * (Int(k.y - lo.y) + Int(extent.y) * Int(k.z - lo.z))
    }

    let cells = Int(extent.x) * Int(extent.y) * Int(extent.z)
    var table = [Kraken.SculptBrick?](repeating: nil, count: cells)
    var looked = [Bool](repeating: false, count: cells)
    func brick(_ k: SIMD3<Int32>) -> Kraken.SculptBrick?
    {
      let i = slot(k)
      if !looked[i]
      {
        looked[i] = true
        table[i] = bricks[k]
      }
      return table[i]
    }

    // only bricks holding the surface and their neighbors can have clamped points next to it
    var near = [Bool](repeating: false, count: cells)
    for k in keys
    {
      guard let found = brick(k), Self.holdsSurface(found.distance, within: limit) else { continue }
      for z: Int32 in -1 ... 1
      {
        for y: Int32 in -1 ... 1
        {
          for x: Int32 in -1 ... 1 { near[slot(k &+ SIMD3(x, y, z))] = true }
        }
      }
    }

    // a settled brick comes out of a repair exactly as it goes in
    let generation = generation
    let work = keys.filter { near[slot($0)] && brick($0).map { $0.settled != generation } == true }
    guard !work.isEmpty else { return }

    // each brick reads itself and the facing slabs of its six neighbors into one padded grid
    let side = Kraken.SculptBrick.side, span = Int(side) + 2
    let steps: [SIMD3<Int32>] = [SIMD3(-1, 0, 0), SIMD3(1, 0, 0), SIMD3(0, -1, 0), SIMD3(0, 1, 0), SIMD3(0, 0, -1), SIMD3(0, 0, 1)]

    // neighbors sit six to a brick in flat lists to avoid a heap allocation per brick
    var owners: [(key: SIMD3<Int32>, brick: Kraken.SculptBrick)] = []
    var neighbors: [Kraken.SculptBrick?] = []
    var edges: [Float] = []
    owners.reserveCapacity(work.count)
    neighbors.reserveCapacity(work.count * 6)
    edges.reserveCapacity(work.count * 6)
    for k in work
    {
      guard let own = brick(k) else { continue }
      owners.append((k, own))
      for step in steps
      {
        let n = k &+ step
        let neighbor = brick(n)
        neighbors.append(neighbor)
        edges.append(neighbor == nil && inside.contains(n) ? -band : band)
      }
    }

    let sides = owners, beside = neighbors, fills = edges
    @Sendable @inline(__always) func cell(_ x: Int32, _ y: Int32, _ z: Int32) -> Int
    {
      Int(x + 1) + span * (Int(y + 1) + span * Int(z + 1))
    }

    do
    {
      var results = [[Float]?](repeating: nil, count: sides.count)
      var faced = [UInt8](repeating: 0, count: sides.count)
      results.withUnsafeMutableBufferPointer
      { out in
        faced.withUnsafeMutableBufferPointer
        { faced in
          DispatchQueue.concurrentPerform(iterations: sides.count)
          { i in
            let brick = sides[i].brick
            let own = brick.distance

            // whatever leaves the brick as it was settles it until it or a neighbor changes
            var next: [Float]?
            defer { if next == nil { brick.settled = generation } }
            guard Self.holdsClamped(own, at: limit) else { return }

            // a clamped point moves only when a neighbor is nearer than the band, otherwise nothing in the brick changes
            if !Self.holdsSurface(own, within: limit)
            {
              var reads = false
              for f in 0 ..< 6
              {
                guard let theirs = beside[i * 6 + f]?.distance else { continue }
                let axis = f / 2, inner: Int32 = f % 2 == 0 ? side - 1 : 0
                for b in 0 ..< side where !reads
                {
                  for a in 0 ..< side where !reads
                  {
                    let from = axis == 0 ? SIMD3(inner, a, b) : axis == 1 ? SIMD3(a, inner, b) : SIMD3(a, b, inner)
                    if abs(theirs[Kraken.SculptBrick.index(from.x, from.y, from.z)]) < limit { reads = true }
                  }
                }
                if reads { break }
              }

              guard reads else { return }
            }

            var touched: UInt8 = 0
            withUnsafeTemporaryAllocation(of: Float.self, capacity: span * span * span)
            { grid in
              grid.initialize(repeating: band)
              own.withUnsafeBufferPointer
              { own in
                for z in 0 ..< side
                {
                  for y in 0 ..< side
                  {
                    for x in 0 ..< side { grid[cell(x, y, z)] = own[Kraken.SculptBrick.index(x, y, z)] }
                  }
                }
              }

              for f in 0 ..< 6
              {
                let axis = f / 2, low = f % 2 == 0
                let inner: Int32 = low ? side - 1 : 0, outer: Int32 = low ? -1 : side
                let theirs = beside[i * 6 + f]?.distance
                let fill = fills[i * 6 + f]
                for b in 0 ..< side
                {
                  for a in 0 ..< side
                  {
                    let from = axis == 0 ? SIMD3(inner, a, b) : axis == 1 ? SIMD3(a, inner, b) : SIMD3(a, b, inner)
                    let to = axis == 0 ? SIMD3(outer, a, b) : axis == 1 ? SIMD3(a, outer, b) : SIMD3(a, b, outer)
                    grid[cell(to.x, to.y, to.z)] = theirs.map { $0[Kraken.SculptBrick.index(from.x, from.y, from.z)] } ?? fill
                  }
                }
              }

              for z in 0 ..< side
              {
                for y in 0 ..< side
                {
                  for x in 0 ..< side
                  {
                    let c = cell(x, y, z)
                    let d = grid[c]
                    guard abs(d) >= limit else { continue }

                    let nearest = min(abs(grid[c - 1]), abs(grid[c + 1]), abs(grid[c - span]), abs(grid[c + span]),
                                      abs(grid[c - span * span]), abs(grid[c + span * span]))
                    let reached = nearest + voxel
                    guard reached < abs(d) else { continue }
                    if next == nil { next = own }
                    next![Kraken.SculptBrick.index(x, y, z)] = d < 0 ? -reached : reached
                    touched |= Self.faces(x, y, z)
                  }
                }
              }
            }

            out[i] = next
            faced[i] = touched
          }
        }
      }

      for (i, side) in sides.enumerated()
      {
        if let distance = results[i]
        {
          side.brick.distance = distance
          noteChange(side.key, faced[i])
          side.brick.settled = 0
          for f in 0 ..< 6 { beside[i * 6 + f]?.settled = 0 }
        }
      }
    }
  }

  private func applyOnce(_ dab: Kraken.SculptDab, origin makeOrigin: (() -> Snapshot)?, record: Kraken.SculptRecorder)
    -> [SIMD3<Int32>]
  {
    // most brushes only change bricks holding the surface and their neighbors in one dab
    let box = reach(dab)
    let local: Bool = switch dab.brush
    {
      case .grab, .snake, .blob, .tube: false
      default: true
    }

    let keys = local ? prepareSurface(from: box.lo, to: box.hi, record: record) : prepare(from: box.lo, to: box.hi, record: record)
    let origin = makeOrigin?()
    let reads: Bool = switch dab.brush
    {
      case .draw, .smooth, .crease, .pinch, .snake: true
      default: false
    }

    let source = reads ? snapshot(keys) : nil
    let band = band, voxel = voxel
    let c = dab.center, n = dab.normal, r = dab.radius
    let reachSquared = (r + band) * (r + band)
    let amount = dab.strength * r * 0.055
    let paint = SIMD4<Float>(dab.color)

    func smin(_ a: Float, _ b: Float, _ k: Float) -> Float
    {
      let h = max(k - abs(a - b), 0) / k
      return min(a, b) - h * h * k * 0.25
    }

    let planeOrigin = brushPlane(dab)

    func blend(_ color: SIMD4<UInt8>, _ w: Float) -> SIMD4<UInt8>
    {
      let w = min(max(w, 0), 1)
      return SIMD4<UInt8>((SIMD4<Float>(color) * (1 - w) + paint * w).rounded(.toNearestOrAwayFromZero))
    }

    /// the tangent part of a vector, along the surface
    func tangent(_ v: SIMD3<Float>) -> SIMD3<Float>
    {
      v - n * simd_dot(v, n)
    }

    // a brick outside the brush's reach, or with nothing near the surface for surface brushes, comes out unchanged and is skipped
    let everywhere = dab.brush == .grab || dab.brush == .tube
    let surfaceOnly: Float? = switch dab.brush
    {
      case .clay, .inflate, .crease: band * 0.99
      case .paint, .mask: band
      default: nil
    }

    // draw blends distances within its amount, so bricks holding one clamped value there come out the same and are skipped
    let still: Int32? = dab.brush == .draw ? Int32((abs(amount) * 1.001 / voxel).rounded(.up)) + 1 : nil

    let span = Float(Kraken.SculptBrick.side - 1) * voxel
    let skip: (SIMD3<Int32>, Kraken.SculptBrick) -> Bool =
    { k, brick in
      if !everywhere
      {
        let lo = SIMD3<Float>(k &* Kraken.SculptBrick.side) * voxel
        let nearest = simd_clamp(c, lo, lo + span)
        if simd_length_squared(nearest - c) >= reachSquared { return true }
      }

      if let still, self.isQuiet(k, brick, margin: still) { return true }
      guard let gate = surfaceOnly else { return false }
      return !Self.holdsSurface(brick.distance, within: gate)
    }

    // brushes with a falloff leave voxels past the radius alone, the rest reach the band beyond it
    let fades: Bool = switch dab.brush
    {
      case .draw, .inflate, .smooth, .crease, .pinch, .flatten, .scrape, .snake, .paint, .mask: true
      default: false
    }

    // the kernel leaves voxels past the reach alone except for grab and tube, surface brushes leave those past their gate alone
    edit(keys, skip: skip, reach: everywhere ? nil : (c, fades ? r * r : reachSquared), gate: surfaceOnly)
    { v in
      let local = v.p - c
      let near = dab.brush == .grab || dab.brush == .tube || simd_length_squared(local) < reachSquared
      guard near else { return }

      let free = dab.ignoresMask ? 1 : 1 - Float(v.mask) / 255
      let f = dab.falloff(simd_length(local) / r) * free

      switch dab.brush
      {
        case .draw:
          guard f > 0, let source else { return }
          v.d = source.blended(v.p - n * amount * f)
          if dab.paints > 0, abs(v.d) < band { v.color = blend(v.color, f * dab.paints) }

        case .inflate:
          // only points near the surface move, the band repair carries the rest so air never grows blobs
          guard f > 0, abs(v.d) < band * 0.99 else { return }
          v.d -= amount * f
          if dab.paints > 0, abs(v.d) < band { v.color = blend(v.color, f * dab.paints) }

        case .clay:
          // builds up toward a plane just over the surface under the brush, flat topped like strips of clay
          let h = simd_dot(v.p - planeOrigin, n)
          let side = simd_length(tangent(local)) / r

          // only points near the surface move toward the plane, so a brush past an edge doesn't grow the sculpt sideways
          let w = dab.falloff(side) * free * max(1 - abs(h) / r, 0)
          guard w > 0, abs(v.d) < band * 0.99 else { return }
          let plane = h - abs(amount) * 1.6 * (amount < 0 ? -1 : 1)
          let target = amount >= 0 ? min(v.d, plane) : max(v.d, plane)
          v.d += (target - v.d) * min(w * 0.6, 1)
          if dab.paints > 0, abs(v.d) < band { v.color = blend(v.color, w * dab.paints) }

        case .blob:
          // the join rounds no wider than the band, where the distances it blends are still true
          let s = simd_length(local) - r * 0.55
          let w = min(abs(dab.strength), 1) * free
          guard w > 0 else { return }
          let round = min(r * 0.35, band * 0.9)
          let target = dab.strength >= 0 ? smin(v.d, s, round) : -smin(-v.d, -s, round)
          let next = dab.strength >= 0 ? target : max(v.d, -s)
          v.d += (next - v.d) * w
          if dab.paints > 0, s < voxel * 1.5 { v.color = blend(v.color, w * dab.paints) }

        case .smooth:
          guard f > 0, let source else { return }
          let g = v.g
          let sum = source.distance(g &+ SIMD3(1, 0, 0)) + source.distance(g &- SIMD3(1, 0, 0))
            + source.distance(g &+ SIMD3(0, 1, 0)) + source.distance(g &- SIMD3(0, 1, 0))
            + source.distance(g &+ SIMD3(0, 0, 1)) + source.distance(g &- SIMD3(0, 0, 1))
          v.d += (sum / 6 - v.d) * min(f * abs(dab.strength), 1)

        case .crease:
          guard f > 0, abs(v.d) < band * 0.99, let source else { return }
          let sharp = Kraken.SculptFalloff.sharp(simd_length(local) / r) * free
          let pull = tangent(-local) * f * 0.3 * min(abs(dab.strength), 1)
          v.d = source.blended(v.p - pull) + amount * 0.8 * sharp

        case .pinch:
          guard f > 0, let source else { return }
          let pull = tangent(-local) * f * 0.35 * dab.strength
          v.d = source.blended(v.p - pull)

        case .flatten, .scrape:
          // solid above the plane is cut however deep it sits, while filling only happens near the surface
          let plane = simd_dot(v.p - planeOrigin, n)
          guard f > 0, abs(plane) < r, abs(v.d) < band * 0.99 || (v.d < 0 && plane > 0) else { return }
          let target: Float = switch (dab.brush, dab.strength >= 0)
          {
            case (.scrape, true): max(v.d, plane)
            case (.scrape, false): min(v.d, plane)
            default: plane
          }

          // a big brush may sit far from its plane, so one dab moves the surface no further than the band holds
          let move = (target - v.d) * min(f * abs(dab.strength) * 0.5, 1)
          v.d += min(max(move, -band * 0.5), band * 0.5)

        case .grab:
          guard let origin else { return }
          let w = dab.falloff(simd_length(v.p - dab.anchor) / r) * free
          guard w > 0 else { return }
          v.d = origin.blended(v.p - dab.delta * w)

        case .snake:
          guard f > 0, let source else { return }
          let w = f * min(abs(dab.strength), 1)
          v.d = source.blended(v.p - dab.delta * w + tangent(-local) * w * 0.04)

        case .tube:
          // a capsule from the last dab to this one, the wire a stroke lays down
          let a = dab.previous, ba = c - a
          let t = min(max(simd_dot(v.p - a, ba) / max(simd_length_squared(ba), 1e-12), 0), 1)
          let s = simd_length(v.p - a - ba * t) - r
          guard s < band else { return }
          if dab.strength >= 0
          {
            // the join rounds no wider than the band, where the distances it blends are still true
            v.d = smin(v.d, s, min(r * 0.3, band * 0.9))
            if s < voxel * 2 { v.color = blend(v.color, min(1 - s / (voxel * 2), 1) * max(dab.paints, 0)) }
          }
          else
          {
            v.d = max(v.d, -s)
          }

        case .paint:
          guard f > 0, abs(v.d) < band else { return }
          v.color = blend(v.color, f * abs(dab.strength))

        case .mask:
          guard abs(v.d) < band else { return }
          let w = dab.falloff(simd_length(local) / r) * dab.strength * 255
          v.mask = UInt8(min(max(Float(v.mask) + w, 0), 255))

        case .pencil:
          break
      }
    }

    return keys
  }

  /// puts a shape into the volume around a transform, `world` takes the shape's frame into the volume
  func insert(_ shape: Kraken.SculptShape, size: SIMD3<Float>, world: simd_float4x4, combine: Kraken.SculptCombine,
              color: SIMD4<UInt8>, paints: Bool, blend: Float = 0, record: Kraken.SculptRecorder) -> [SIMD3<Int32>]
  {
    // a blend wider than the band would read distances the band never kept
    let k = min(blend, band * 0.95)
    let reach = simd_length(size) + band * 2 + k
    let center = SIMD3(world.columns.3.x, world.columns.3.y, world.columns.3.z)
    let scale = simd_length(SIMD3(world.columns.0.x, world.columns.0.y, world.columns.0.z))
    let pad = SIMD3<Float>(repeating: reach * max(scale, 1e-6))
    let keys = prepare(from: center - pad, to: center + pad, record: record)
    let inverse = world.inverse
    let band = band, voxel = voxel
    let paint = SIMD4<Float>(color)

    edit(keys)
    { v in
      let q = inverse * SIMD4(v.p, 1)
      let s = shape.distance(SIMD3(q.x, q.y, q.z), size) * scale
      guard s < band + k || combine == .intersect else { return }

      switch combine
      {
        case .add:
          let before = v.d
          v.d = k > 0 ? smin(v.d, s, k) : min(v.d, s)
          let reach = voxel * 1.5 + k * 0.5
          if paints, s < reach, v.d < before + voxel
          {
            let w = min(max(1 - s / reach, 0), 1)
            v.color = SIMD4<UInt8>((SIMD4<Float>(v.color) * (1 - w) + paint * w).rounded(.toNearestOrAwayFromZero))
          }
        case .subtract:
          v.d = k > 0 ? -smin(-v.d, s, k) : max(v.d, -s)
        case .intersect:
          v.d = max(v.d, s)
      }
    }

    return keys
  }

  /// a union that rounds into a fillet `k` wide where the two meet
  @inline(__always)
  func smin(_ a: Float, _ b: Float, _ k: Float) -> Float
  {
    let h = max(k - abs(a - b), 0) / k
    return min(a, b) - h * h * k * 0.25
  }

  /// evens out distances that brushes stretched, so the field stays a distance and later brushes stay even
  func renormalize(_ keys: [SIMD3<Int32>])
  {
    let source = snapshot(keys)
    let band = band, voxel = voxel

    edit(keys)
    { v in
      guard abs(v.d) < band * 0.9 else { return }
      let g = v.g
      let around = [source.distance(g &+ SIMD3(1, 0, 0)), source.distance(g &- SIMD3(1, 0, 0)),
                    source.distance(g &+ SIMD3(0, 1, 0)), source.distance(g &- SIMD3(0, 1, 0)),
                    source.distance(g &+ SIMD3(0, 0, 1)), source.distance(g &- SIMD3(0, 0, 1))]

      // a neighbor past the band was clamped, so the slope it gives is too shallow and would bend the normals
      guard around.allSatisfy({ abs($0) < band * 0.999 }) else { return }
      let slope = simd_length(SIMD3(around[0] - around[1], around[2] - around[3], around[4] - around[5])) / (2 * voxel)
      guard slope > 0.2 else { return }
      v.d /= min(max(slope, 0.5), 2)
    }
  }
}
