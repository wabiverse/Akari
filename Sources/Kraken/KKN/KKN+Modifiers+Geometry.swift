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

extension Kraken.Modifiers
{
  /// a mesh moving through the stack, keeping where each piece came from on the cage so primvars and creases follow
  struct Geometry
  {
    var points: [SIMD3<Float>] = []
    var counts: [Int32] = []
    var indices: [Int32] = []

    /// the cage point each of ours came from, one per point
    var pointSource: [Int32] = []
    /// the cage face each of ours came from, one per face, negative for a face the stack made up
    var faceSource: [Int32] = []
    /// the cage corner each of ours came from, one per corner, negative for a corner the stack made up
    var cornerSource: [Int32] = []

    /// each creased edge as its two points, with one sharpness each
    var creases: [Int32] = []
    var creaseSharpness: [Float] = []
    /// each edge marked sharp, as its two points
    var sharp: [Int32] = []

    var faceCount: Int { counts.count }

    /// the corner each face starts at
    var faceStarts: [Int]
    {
      var starts: [Int] = []
      starts.reserveCapacity(counts.count)

      var at = 0
      for n in counts
      {
        starts.append(at)
        at += Int(n)
      }

      return starts
    }

    /// the mesh as it comes off the cage, every piece of it its own source
    static func cage(points: [SIMD3<Float>], counts: [Int32], indices: [Int32], creases: [Int32],
                     creaseSharpness: [Float], sharp: [Int32]) -> Geometry
    {
      Geometry(points: points, counts: counts, indices: indices,
               pointSource: (0 ..< points.count).map(Int32.init),
               faceSource: (0 ..< counts.count).map(Int32.init),
               cornerSource: (0 ..< indices.count).map(Int32.init),
               creases: creases, creaseSharpness: creaseSharpness, sharp: sharp)
    }

    var bounds: (min: SIMD3<Float>, max: SIMD3<Float>)
    {
      guard let first = points.first else { return (.zero, .zero) }

      var low = first, high = first
      for p in points
      {
        low = simd_min(low, p)
        high = simd_max(high, p)
      }

      return (low, high)
    }
  }

  /// runs the stack over the cage for the viewport or a final render, nil when nothing in it changes the mesh
  nonisolated static func evaluate(_ cage: Geometry, _ stack: [Entry], render: Bool) -> Geometry?
  {
    var out = cage
    var ran = false

    for entry in stack where entry.shows(render: render) && !entry.kind.isRefinement
    {
      out = apply(entry, to: out)
      ran = true
    }

    return ran ? out : nil
  }

  nonisolated static func apply(_ entry: Entry, to input: Geometry) -> Geometry
  {
    switch entry.kind
    {
      case .subdivision: input
      case .mirror: mirror(input, entry)
      case .array: array(input, entry)
      case .solidify: solidify(input, entry)
      case .weld: weld(input, by: Float(entry.number("mergeThreshold", 0.001)))
      case .smooth: smooth(input, entry)
      case .triangulate: triangulate(input, entry)
    }
  }

  // MARK: mirror

  nonisolated static func mirror(_ input: Geometry, _ entry: Entry) -> Geometry
  {
    var out = input
    let merge = entry.flag("merge", true)
    let threshold = Float(entry.number("mergeThreshold", 0.001))

    for (axis, key) in ["axisX", "axisY", "axisZ"].enumerated() where entry.flag(key, axis == 0)
    {
      out = mirror(out, axis: axis, merge: merge, threshold: threshold)
    }

    return out
  }

  nonisolated private static func mirror(_ input: Geometry, axis: Int, merge: Bool, threshold: Float) -> Geometry
  {
    let n = input.points.count
    guard n > 0 else { return input }

    // a point sitting on the mirror plane stands in for its own reflection, so the halves meet seamlessly
    var twin = [Int32](repeating: 0, count: n)
    for i in 0 ..< n
    {
      twin[i] = merge && abs(input.points[i][axis]) <= threshold ? Int32(i) : Int32(n + i)
    }

    var out = input
    out.points.reserveCapacity(n * 2)
    out.pointSource.reserveCapacity(n * 2)

    for i in 0 ..< n
    {
      var p = input.points[i]
      p[axis] = -p[axis]
      out.points.append(p)
      out.pointSource.append(input.pointSource[i])
    }

    // the reflection turns every face inside out, so its corners are wound the other way round
    let starts = input.faceStarts
    for (f, count) in input.counts.enumerated()
    {
      let start = starts[f], size = Int(count)
      out.counts.append(count)
      out.faceSource.append(input.faceSource[f])

      for k in stride(from: size - 1, through: 0, by: -1)
      {
        out.indices.append(twin[Int(input.indices[start + k])])
        out.cornerSource.append(input.cornerSource[start + k])
      }
    }

    out.creases += input.creases.map { twin[Int($0)] }
    out.creaseSharpness += input.creaseSharpness
    out.sharp += input.sharp.map { twin[Int($0)] }

    return compact(out)
  }

  // MARK: array

  nonisolated static func array(_ input: Geometry, _ entry: Entry) -> Geometry
  {
    let copies = max(Int(entry.number("count", 2).rounded()), 1)
    guard copies > 1, !input.points.isEmpty else { return input }

    let (low, high) = input.bounds
    let size = high - low
    let step = entry.vector("relativeOffset", SIMD3(1, 0, 0)) * size + entry.vector("constantOffset")

    var out = Geometry(points: input.points, counts: input.counts, indices: input.indices,
                       pointSource: input.pointSource, faceSource: input.faceSource,
                       cornerSource: input.cornerSource, creases: input.creases,
                       creaseSharpness: input.creaseSharpness, sharp: input.sharp)
    let n = Int32(input.points.count)

    for copy in 1 ..< copies
    {
      let shift = step * Float(copy)
      let base = Int32(copy) * n

      out.points += input.points.map { $0 + shift }
      out.pointSource += input.pointSource
      out.counts += input.counts
      out.faceSource += input.faceSource
      out.indices += input.indices.map { $0 + base }
      out.cornerSource += input.cornerSource
      out.creases += input.creases.map { $0 + base }
      out.creaseSharpness += input.creaseSharpness
      out.sharp += input.sharp.map { $0 + base }
    }

    guard entry.flag("merge", true) else { return out }

    return weld(out, by: Float(entry.number("mergeThreshold", 0.001)))
  }

  // MARK: solidify

  nonisolated static func solidify(_ input: Geometry, _ entry: Entry) -> Geometry
  {
    let thickness = Float(entry.number("thickness", 0.01))
    guard thickness != 0, !input.points.isEmpty else { return input }

    let offset = Float(entry.number("offset", -1))
    let outward = thickness * (1 + offset) / 2
    let inward = thickness * (1 - offset) / 2
    let normals = vertexNormals(input)

    var out = Geometry()
    let n = input.points.count
    out.points = input.points.enumerated().map { $0.element + normals[$0.offset] * outward }
    out.points += input.points.enumerated().map { $0.element - normals[$0.offset] * inward }
    out.pointSource = input.pointSource + input.pointSource

    let starts = input.faceStarts
    out.counts = input.counts
    out.indices = input.indices
    out.faceSource = input.faceSource
    out.cornerSource = input.cornerSource

    // the inner shell faces the other way, so its corners run backwards
    for (f, count) in input.counts.enumerated()
    {
      let start = starts[f], size = Int(count)
      out.counts.append(count)
      out.faceSource.append(input.faceSource[f])

      for k in stride(from: size - 1, through: 0, by: -1)
      {
        out.indices.append(input.indices[start + k] + Int32(n))
        out.cornerSource.append(input.cornerSource[start + k])
      }
    }

    out.creases = input.creases + input.creases.map { $0 + Int32(n) }
    out.creaseSharpness = input.creaseSharpness + input.creaseSharpness
    out.sharp = input.sharp + input.sharp.map { $0 + Int32(n) }

    guard entry.flag("rim", true) else { return out }

    for edge in boundary(input)
    {
      out.counts.append(4)
      out.faceSource.append(-1)
      out.indices += [edge.1, edge.0, edge.0 + Int32(n), edge.1 + Int32(n)]
      out.cornerSource += [-1, -1, -1, -1]
    }

    return out
  }

  /// every edge with only one face on it, wound the way that face runs
  nonisolated private static func boundary(_ g: Geometry) -> [(Int32, Int32)]
  {
    var uses: [Kraken.Edge: Int] = [:]
    var wound: [Kraken.Edge: (Int32, Int32)] = [:]
    let starts = g.faceStarts

    for (f, count) in g.counts.enumerated()
    {
      let start = starts[f], size = Int(count)
      for k in 0 ..< size
      {
        let a = g.indices[start + k], b = g.indices[start + (k + 1) % size]
        let edge = Kraken.Edge(Int(a), Int(b))
        uses[edge, default: 0] += 1
        wound[edge] = (a, b)
      }
    }

    return uses.filter { $0.value == 1 }.compactMap { wound[$0.key] }
  }

  /// area weighted point normals, which is what a thickness follows
  nonisolated static func vertexNormals(_ g: Geometry) -> [SIMD3<Float>]
  {
    var normals = [SIMD3<Float>](repeating: .zero, count: g.points.count)
    let starts = g.faceStarts

    for (f, count) in g.counts.enumerated()
    {
      let start = starts[f], size = Int(count)
      guard size >= 3 else { continue }

      var n = SIMD3<Float>.zero
      for k in 0 ..< size
      {
        let a = g.points[Int(g.indices[start + k])], b = g.points[Int(g.indices[start + (k + 1) % size])]
        n += SIMD3((a.y - b.y) * (a.z + b.z), (a.z - b.z) * (a.x + b.x), (a.x - b.x) * (a.y + b.y))
      }

      for k in 0 ..< size { normals[Int(g.indices[start + k])] += n }
    }

    return normals.map
    { n in
      let length = simd_length(n)
      return length > 1e-12 ? n / length : SIMD3(0, 0, 1)
    }
  }

  // MARK: weld

  /// merges points closer together than distance and drops the faces that collapse with them
  nonisolated static func weld(_ input: Geometry, by distance: Float) -> Geometry
  {
    guard distance > 0, !input.points.isEmpty else { return input }

    let cell = Double(distance)
    var buckets: [SIMD3<Int32>: [Int]] = [:]
    var into = [Int32](repeating: 0, count: input.points.count)

    for (i, p) in input.points.enumerated()
    {
      let key = SIMD3<Int32>(Int32(floor(Double(p.x) / cell)), Int32(floor(Double(p.y) / cell)),
                             Int32(floor(Double(p.z) / cell)))
      var found = -1

      for dz in -1 ... 1 where found < 0
      {
        for dy in -1 ... 1 where found < 0
        {
          for dx in -1 ... 1 where found < 0
          {
            let near = key &+ SIMD3<Int32>(Int32(dx), Int32(dy), Int32(dz))
            for j in buckets[near] ?? [] where simd_distance(input.points[j], p) <= distance
            {
              found = j
              break
            }
          }
        }
      }

      into[i] = Int32(found >= 0 ? found : i)
      if found < 0 { buckets[key, default: []].append(i) }
    }

    var out = input
    out.counts = []
    out.indices = []
    out.faceSource = []
    out.cornerSource = []

    let starts = input.faceStarts
    for (f, count) in input.counts.enumerated()
    {
      let start = starts[f], size = Int(count)
      var corners: [Int32] = [], sources: [Int32] = []

      for k in 0 ..< size
      {
        let v = into[Int(input.indices[start + k])]
        guard v != corners.last, v != corners.first else { continue }

        corners.append(v)
        sources.append(input.cornerSource[start + k])
      }

      guard corners.count >= 3 else { continue }

      out.counts.append(Int32(corners.count))
      out.indices += corners
      out.cornerSource += sources
      out.faceSource.append(input.faceSource[f])
    }

    out.creases = input.creases.map { into[Int($0)] }
    out.sharp = input.sharp.map { into[Int($0)] }

    // an edge whose two points merged is no edge at all
    var creases: [Int32] = [], sharpness: [Float] = []
    for (k, s) in out.creaseSharpness.enumerated() where out.creases[2 * k] != out.creases[2 * k + 1]
    {
      creases += [out.creases[2 * k], out.creases[2 * k + 1]]
      sharpness.append(s)
    }

    out.creases = creases
    out.creaseSharpness = sharpness

    let welded = out.sharp
    out.sharp = stride(from: 0, to: welded.count - 1, by: 2)
      .filter { welded[$0] != welded[$0 + 1] }
      .flatMap { [welded[$0], welded[$0 + 1]] }

    return compact(out)
  }

  // MARK: smooth

  nonisolated static func smooth(_ input: Geometry, _ entry: Entry) -> Geometry
  {
    let factor = Float(entry.number("factor", 0.5))
    let rounds = max(Int(entry.number("iterations", 1).rounded()), 1)
    guard factor != 0, !input.points.isEmpty else { return input }

    var neighbours = [[Int32]](repeating: [], count: input.points.count)
    let starts = input.faceStarts

    for (f, count) in input.counts.enumerated()
    {
      let start = starts[f], size = Int(count)
      for k in 0 ..< size
      {
        let a = Int(input.indices[start + k]), b = Int(input.indices[start + (k + 1) % size])
        neighbours[a].append(Int32(b))
        neighbours[b].append(Int32(a))
      }
    }

    var out = input
    for _ in 0 ..< rounds
    {
      var moved = out.points
      for (i, around) in neighbours.enumerated() where !around.isEmpty
      {
        let sum = around.reduce(SIMD3<Float>.zero) { $0 + out.points[Int($1)] }
        moved[i] = out.points[i] + (sum / Float(around.count) - out.points[i]) * factor
      }

      out.points = moved
    }

    return out
  }

  // MARK: triangulate

  nonisolated static func triangulate(_ input: Geometry, _ entry: Entry) -> Geometry
  {
    let minimum = max(Int(entry.number("minimumVertices", 4).rounded()), 3)
    let quads = entry.flag("quads", true)

    var out = input
    out.counts = []
    out.indices = []
    out.faceSource = []
    out.cornerSource = []

    let starts = input.faceStarts
    for (f, count) in input.counts.enumerated()
    {
      let start = starts[f], size = Int(count)
      let split = size >= minimum && (size != 4 || quads)

      guard size > 3, split else
      {
        out.counts.append(count)
        out.indices += input.indices[start ..< start + size]
        out.cornerSource += input.cornerSource[start ..< start + size]
        out.faceSource.append(input.faceSource[f])
        continue
      }

      // a quad splits along its shorter diagonal, anything larger fans from one corner
      var fan = 0
      if size == 4
      {
        let p = (0 ..< 4).map { input.points[Int(input.indices[start + $0])] }
        fan = simd_distance(p[0], p[2]) <= simd_distance(p[1], p[3]) ? 0 : 1
      }

      for k in 1 ..< size - 1
      {
        let corners = [fan, (fan + k) % size, (fan + k + 1) % size]
        out.counts.append(3)
        out.indices += corners.map { input.indices[start + $0] }
        out.cornerSource += corners.map { input.cornerSource[start + $0] }
        out.faceSource.append(input.faceSource[f])
      }
    }

    return out
  }

  // MARK: shared

  /// drops the points no face uses any more and renumbers everything onto what is left
  nonisolated static func compact(_ input: Geometry) -> Geometry
  {
    var used = [Bool](repeating: false, count: input.points.count)
    for i in input.indices where Int(i) < used.count { used[Int(i)] = true }
    for i in input.creases where Int(i) < used.count { used[Int(i)] = true }

    guard used.contains(false) else { return input }

    var into = [Int32](repeating: -1, count: input.points.count)
    var out = input
    out.points = []
    out.pointSource = []

    for (i, keep) in used.enumerated() where keep
    {
      into[i] = Int32(out.points.count)
      out.points.append(input.points[i])
      out.pointSource.append(input.pointSource[i])
    }

    out.indices = input.indices.map { into[Int($0)] }
    out.creases = input.creases.map { into[Int($0)] }

    let kept = input.sharp
    out.sharp = stride(from: 0, to: kept.count - 1, by: 2)
      .filter { into[Int(kept[$0])] >= 0 && into[Int(kept[$0 + 1])] >= 0 }
      .flatMap { [into[Int(kept[$0])], into[Int(kept[$0 + 1])]] }

    return out
  }
}
