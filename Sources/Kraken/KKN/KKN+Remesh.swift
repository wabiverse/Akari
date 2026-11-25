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

import Dispatch
import Foundation
import simd

extension Kraken
{
  /// turns any polygon mesh into clean quads following its shape, sharp edges and boundaries, always finishing within a fixed budget
  enum Remesh
  {
    typealias V = SIMD3<Float>

    struct Options: Sendable
    {
      /// how many faces the result should have, roughly
      var faces = 5000

      /// edge length to aim for instead of a face count, when above zero
      var edge: Float = 0

      /// edges whose faces meet at more than this many degrees become lines of the result, zero turns it off
      var sharpAngle: Float = 40

      /// how strongly the loops follow the bends of the surface
      var curvature: Float = 0

      /// mirrors the result across the plane through the origin facing this local axis, 0 x, 1 y, 2 z
      var symmetry: Int? = nil

      /// splits every face once so the result is nothing but quads
      var pureQuads = true

      /// relaxing passes that even out the result on the surface
      var smoothing = 8

      /// seconds after which every stage hurries to the end
      var timeLimit: Double = 30

      /// curves the loops should run along, like rings around eyes and mouth
      var guides: [[SIMD3<Float>]] = []

      init() {}
    }

    struct Result: Sendable
    {
      var points: [SIMD3<Float>] = []
      var counts: [Int32] = []
      var indices: [Int32] = []

      /// verts of every edge that runs along a sharp edge of the input, two at a time
      var sharp: [Int32] = []

      var stats = Stats()
    }

    struct Stats: Sendable, CustomStringConvertible
    {
      var inputFaces = 0
      var inputTriangles = 0
      var fieldVerts = 0
      var surfaceVerts = 0
      var levels = 0
      var quads = 0
      var others = 0
      var irregular = 0
      var boundaryEdges = 0
      var stages: [Stage] = []
      var hurried = false

      struct Stage: Sendable
      {
        var name: String
        var seconds: Double
      }

      var seconds: Double { stages.reduce(0) { $0 + $1.seconds } }

      var description: String
      {
        let times = stages.map { "\($0.name) \(String(format: "%.0f", $0.seconds * 1000))" }.joined(separator: ", ")
        return "\(inputTriangles) tris -> \(quads) quads + \(others) other, \(irregular) irregular verts, "
          + "\(boundaryEdges) open edges, field \(fieldVerts)/\(surfaceVerts) verts on \(levels) levels, "
          + String(format: "%.2f s", seconds) + (hurried ? " (hurried)" : "") + " [\(times) ms]"
      }
    }

    /// wall clock for the time bound, and the per stage timings for the report
    final class Clock: @unchecked Sendable
    {
      let start = DispatchTime.now().uptimeNanoseconds
      var mark = DispatchTime.now().uptimeNanoseconds
      let limit: Double
      var stages: [Stats.Stage] = []
      var hurried = false

      init(_ limit: Double)
      {
        self.limit = max(limit, 0.5)
      }

      var elapsed: Double { Double(DispatchTime.now().uptimeNanoseconds - start) * 1e-9 }

      /// true once the run has used up the given share of its time
      func over(_ share: Double = 1) -> Bool
      {
        let late = elapsed > limit * share
        if late { hurried = true }
        return late
      }

      func lap(_ name: String)
      {
        let now = DispatchTime.now().uptimeNanoseconds
        stages.append(.init(name: name, seconds: Double(now - mark) * 1e-9))
        mark = now
      }
    }

    /// remeshes a polygon mesh given as flat xyz points, face sizes and face corners
    static func run(points: [Float], counts: [Int32], indices: [Int32], options: Options) -> Result?
    {
      var p: [V] = []
      p.reserveCapacity(points.count / 3)
      for i in stride(from: 0, to: points.count - 2, by: 3) { p.append(V(points[i], points[i + 1], points[i + 2])) }
      return run(points: p, counts: counts, indices: indices, options: options)
    }

    static func run(points input: [V], counts: [Int32], indices: [Int32], options: Options) -> Result?
    {
      guard let first = attempt(points: input, counts: counts, indices: indices, options: options) else { return nil }

      // thin parts and holes lose faces, so a short result gets one more try aimed higher when time allows, the closer one wins
      let got = first.counts.count, want = options.faces
      let spent = first.stats.seconds
      guard options.edge <= 0, got > 0, Double(got) < Double(want) * 0.85, spent * 2.5 < options.timeLimit else { return first }

      var again = options
      again.faces = Int(Double(want) * min(Double(want) / Double(got), 2.5))
      again.timeLimit = options.timeLimit - spent
      guard var second = attempt(points: input, counts: counts, indices: indices, options: again) else { return first }

      second.stats.stages.insert(.init(name: "first try", seconds: spent), at: 0)
      return abs(second.counts.count - want) < abs(got - want) ? second : first
    }

    static func attempt(points input: [V], counts: [Int32], indices: [Int32], options: Options) -> Result?
    {
      let clock = Clock(options.timeLimit)
      var stats = Stats()
      stats.inputFaces = counts.count

      var p = input.map { $0.x.isFinite && $0.y.isFinite && $0.z.isFinite ? $0 : V(repeating: 0) }
      var tri = triangulate(counts, indices, p.count)
      stats.inputTriangles = tri.count / 3
      weld(&p, &tri)
      guard tri.count >= 3 else { return nil }

      var plane: Float = 0
      if let axis = options.symmetry, (0 ... 2).contains(axis)
      {
        let lo = p.reduce(V(repeating: .infinity)) { simd_min($0, $1) }
        let hi = p.reduce(V(repeating: -.infinity)) { simd_max($0, $1) }
        plane = lo[axis] < 0 && hi[axis] > 0 ? 0 : (lo[axis] + hi[axis]) * 0.5
        cut(&p, &tri, axis: axis, at: plane)
        guard tri.count >= 3 else { return nil }
      }

      let area = totalArea(p, tri)
      guard area > 0, area.isFinite else { return nil }

      let half = options.symmetry != nil ? 0.5 : 1.0
      let faces = max(Double(options.faces) * half, 8)
      let edge = options.edge > 0 ? options.edge : Float((Double(area) / faces).squareRoot())
      let scale = options.pureQuads ? edge * 2 : edge
      dropSpecks(&p, &tri, below: scale * scale)
      clock.lap("prepare")

      refine(&p, &tri, longest: scale * 0.3, cap: 4_000_000)
      clock.lap("refine")

      let surface = Surface(p, tri, sharpAngle: options.sharpAngle, edge: edge, guides: options.guides)
      stats.surfaceVerts = surface.p.count
      clock.lap("surface")

      let levels = hierarchy(surface, scale: scale, clock: clock)
      let bottom = levels.lastIndex { $0.spacing <= scale * 0.25 } ?? 0
      stats.levels = levels.count
      stats.fieldVerts = levels[bottom].count
      clock.lap("hierarchy")

      orient(levels, bottom: bottom, scale: scale, curvature: options.curvature, clock: clock)
      clock.lap("orientation")

      position(levels, bottom: bottom, scale: scale, clock: clock)
      clock.lap("position")

      var mesh = extract(levels, bottom: bottom, scale: scale, surface: surface)
      guard mesh.faceCount > 0 else { return nil }
      untangle(&mesh, scale: scale, clock: clock)
      clock.lap("untangle")
      pairTriangles(&mesh)
      if options.pureQuads { mesh = split(mesh) }
      clock.lap("extract")

      relax(&mesh, surface, iterations: options.smoothing, edge: edge, clock: clock)
      let sharp = sharpEdges(mesh, surface, edge: edge)
      clock.lap("relax")

      var result = Result()
      result.points = mesh.p
      result.counts = mesh.counts
      result.indices = mesh.indices
      result.sharp = sharp
      if let axis = options.symmetry, (0 ... 2).contains(axis)
      {
        mirror(&result, axis: axis, at: plane, edge: edge)
      }
      clock.lap("finish")

      count(&stats, result)
      stats.stages = clock.stages
      stats.hurried = clock.hurried
      result.stats = stats
      return result.indices.isEmpty ? nil : result
    }

    /// face kinds, irregular verts and open edges of the result for the report
    static func count(_ stats: inout Stats, _ r: Result)
    {
      stats.quads = r.counts.filter { $0 == 4 }.count
      stats.others = r.counts.count - stats.quads
      var valence = [Int32](repeating: 0, count: r.points.count)
      var edges: [UInt64: Int32] = [:]
      var at = 0
      for c in r.counts
      {
        let c = Int(c)
        for k in 0 ..< c
        {
          let a = r.indices[at + k], b = r.indices[at + (k + 1) % c]
          edges[key(a, b), default: 0] += 1
        }
        at += c
      }

      var open = Set<Int32>()
      for (k, uses) in edges
      {
        let a = Int32(truncatingIfNeeded: k >> 32), b = Int32(truncatingIfNeeded: k & 0xffff_ffff)
        valence[Int(a)] += 1
        valence[Int(b)] += 1
        if uses == 1
        {
          stats.boundaryEdges += 1
          open.insert(a)
          open.insert(b)
        }
      }

      stats.irregular = valence.indices.filter { !open.contains(Int32($0)) && valence[$0] != 4 && valence[$0] > 0 }.count
    }

    /// drops loose parts smaller than a grid cell like wires and bolts, the biggest part always stays
    static func dropSpecks(_ p: inout [V], _ tri: inout [Int32], below limit: Float)
    {
      let nv = p.count, nt = tri.count / 3
      guard nt > 0 else { return }

      var root = [Int32](0 ..< Int32(nv))
      func find(_ x: Int32) -> Int32
      {
        var x = x
        while root[Int(x)] != x
        {
          root[Int(x)] = root[Int(root[Int(x)])]
          x = root[Int(x)]
        }
        return x
      }

      for t in 0 ..< nt
      {
        let a = find(tri[3 * t]), b = find(tri[3 * t + 1]), c = find(tri[3 * t + 2])
        let m = min(a, b, c)
        root[Int(a)] = m
        root[Int(b)] = m
        root[Int(c)] = m
      }

      var area = [Float](repeating: 0, count: nv)
      for t in 0 ..< nt
      {
        let a = p[Int(tri[3 * t])], b = p[Int(tri[3 * t + 1])], c = p[Int(tri[3 * t + 2])]
        area[Int(find(tri[3 * t]))] += simd_length(simd_cross(b - a, c - a)) * 0.5
      }

      let biggest = area.indices.max { area[$0] < area[$1] } ?? 0
      var kept: [Int32] = []
      kept.reserveCapacity(tri.count)
      for t in 0 ..< nt
      {
        let r = Int(find(tri[3 * t]))
        if r == biggest || area[r] >= limit { kept += [tri[3 * t], tri[3 * t + 1], tri[3 * t + 2]] }
      }

      guard kept.count < tri.count else { return }

      tri = kept
      weld(&p, &tri)
    }

    // MARK: helpers

    @inline(__always) static func key(_ a: Int32, _ b: Int32) -> UInt64
    {
      let lo = min(a, b), hi = max(a, b)
      return UInt64(UInt32(bitPattern: lo)) << 32 | UInt64(UInt32(bitPattern: hi))
    }

    /// runs body over slices of 0 ..< count spread across the cores
    static func parallel(_ count: Int, grain: Int = 2048, _ body: (Range<Int>) -> Void)
    {
      guard count > 0 else { return }
      let chunks = min((count + grain - 1) / grain, 512)
      if chunks <= 1
      {
        body(0 ..< count)
        return
      }

      let size = (count + chunks - 1) / chunks
      DispatchQueue.concurrentPerform(iterations: chunks)
      { c in
        let lo = c * size, hi = min(count, lo + size)
        if lo < hi { body(lo ..< hi) }
      }
    }

    @inline(__always) static func normalized(_ v: V, _ fallback: V) -> V
    {
      let l = simd_length(v)
      return l > 1e-20 && l.isFinite ? v / l : fallback
    }

    /// some unit vector at right angles to n
    @inline(__always) static func perpendicular(_ n: V) -> V
    {
      let a = abs(n.x) < 0.57 ? V(1, 0, 0) : (abs(n.y) < 0.57 ? V(0, 1, 0) : V(0, 0, 1))
      return normalized(simd_cross(n, a), V(1, 0, 0))
    }

    @inline(__always) static func tangent(_ v: V, _ n: V) -> V
    {
      v - n * simd_dot(n, v)
    }

    static func totalArea(_ p: [V], _ tri: [Int32]) -> Float
    {
      var sum: Double = 0
      for t in stride(from: 0, to: tri.count, by: 3)
      {
        let a = p[Int(tri[t])], b = p[Int(tri[t + 1])], c = p[Int(tri[t + 2])]
        sum += Double(simd_length(simd_cross(b - a, c - a))) * 0.5
      }
      return Float(sum)
    }

    /// closest point to x on the triangle abc, with its barycentric weights
    @inline(__always) static func closest(_ x: V, _ a: V, _ b: V, _ c: V) -> (V, V)
    {
      let ab = b - a, ac = c - a, ap = x - a
      let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
      if d1 <= 0 && d2 <= 0 { return (a, V(1, 0, 0)) }

      let bp = x - b
      let d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
      if d3 >= 0 && d4 <= d3 { return (b, V(0, 1, 0)) }

      let vc = d1 * d4 - d3 * d2
      if vc <= 0 && d1 >= 0 && d3 <= 0
      {
        let v = d1 / max(d1 - d3, 1e-30)
        return (a + ab * v, V(1 - v, v, 0))
      }

      let cp = x - c
      let d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
      if d6 >= 0 && d5 <= d6 { return (c, V(0, 0, 1)) }

      let vb = d5 * d2 - d1 * d6
      if vb <= 0 && d2 >= 0 && d6 <= 0
      {
        let w = d2 / max(d2 - d6, 1e-30)
        return (a + ac * w, V(1 - w, 0, w))
      }

      let va = d3 * d6 - d5 * d4
      if va <= 0 && (d4 - d3) >= 0 && (d5 - d6) >= 0
      {
        let w = (d4 - d3) / max((d4 - d3) + (d5 - d6), 1e-30)
        return (b + (c - b) * w, V(0, 1 - w, w))
      }

      let denom = 1 / max(va + vb + vc, 1e-30)
      let v = vb * denom, w = vc * denom
      return (a + ab * v + ac * w, V(1 - v - w, v, w))
    }

    /// closest point to x on the segment ab
    @inline(__always) static func closest(_ x: V, _ a: V, _ b: V) -> V
    {
      let d = b - a
      let t = simd_clamp(simd_dot(x - a, d) / max(simd_length_squared(d), 1e-30), 0, 1)
      return a + d * t
    }
  }
}
