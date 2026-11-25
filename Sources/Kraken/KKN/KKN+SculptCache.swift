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
  /// a sculpt's surface as usd keeps it, everything the volume can be rebuilt from
  struct SculptSurface: Sendable
  {
    var points: [SIMD3<Float>] = []
    var normals: [SIMD3<Float>] = []
    var triangles: [Int32] = []
    /// display paint in rgb with gloss in alpha, one per point
    var colors: [SIMD4<UInt8>] = []
    /// the mask one per point, empty when nothing is masked
    var mask: [UInt8] = []
  }

  /// the volumes behind sculpts cached by surface hash, rebuilt from the usd surface when missing and expired by age, count and size
  enum SculptCache
  {
    /// how many volumes the folder keeps at most
    static let count = 64

    /// how many bytes the folder keeps at most
    static let bytes = 2 << 30

    /// how long a volume nobody opens is kept
    static let age: TimeInterval = 30 * 24 * 60 * 60

    /// the entry each sculpt wrote last that no save or open has claimed, the one its next write replaces
    nonisolated(unsafe) private static var pending: [String: String] = [:]

    /// the entries a save or an open claimed this run, never taken as some sculpt's stale write
    nonisolated(unsafe) private static var claimed: Set<String> = []
    private static let lock = NSLock()

    static var folder: URL
    {
      let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first ?? FileManager.default.temporaryDirectory
      return caches.appendingPathComponent("foundation.wabi.usd", isDirectory: true).appendingPathComponent("Sculpts", isDirectory: true)
    }

    /// a stable hash of the arrays a surface is written as, the same on every run and machine
    static func key(points: [Float], indices: [Int32], colors: [Float], gloss: [Float], mask: [Float]) -> String
    {
      var a: UInt64 = 0xCBF2_9CE4_8422_2325, b: UInt64 = 0x8422_2325_CBF2_9CE4
      func mix(_ word: UInt64)
      {
        a = (a ^ word) &* 0x0000_0100_0000_01B3
        b = (b ^ (word &* 0x9E37_79B9_7F4A_7C15)) &* 0x0000_0100_0000_01B3
        b = (b << 31) | (b >> 33)
      }

      func feed(_ bytes: UnsafeRawBufferPointer)
      {
        mix(UInt64(bytes.count))
        var at = 0
        while at + 8 <= bytes.count
        {
          mix(bytes.loadUnaligned(fromByteOffset: at, as: UInt64.self))
          at += 8
        }

        var tail: UInt64 = 0
        var shift: UInt64 = 0
        while at < bytes.count
        {
          tail |= UInt64(bytes[at]) << shift
          shift += 8
          at += 1
        }
        mix(tail)
      }

      points.withUnsafeBytes(feed)
      indices.withUnsafeBytes(feed)
      colors.withUnsafeBytes(feed)
      gloss.withUnsafeBytes(feed)
      mask.withUnsafeBytes(feed)
      return String(format: "%016llx%016llx", a, b)
    }

    static func url(_ key: String) -> URL
    {
      folder.appendingPathComponent("\(key).akvol")
    }

    /// keeps a volume under its key, saved or opened writes are claimed and stay, others replace the sculpt's previous one
    static func store(_ data: Data, key: String, owner: String, claim: Bool)
    {
      try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      try? data.write(to: url(key), options: .atomic)

      lock.lock()
      let previous = pending[owner]
      if claim
      {
        claimed.insert(key)
        pending[owner] = nil
      }
      else
      {
        pending[owner] = key
      }
      let stale = previous.flatMap { $0 != key && !claimed.contains($0) ? $0 : nil }
      lock.unlock()

      if let stale { try? FileManager.default.removeItem(at: url(stale)) }
      prune()
    }

    /// claims every sculpt's latest write, for a save that now points at them
    static func claimPending()
    {
      lock.lock()
      claimed.formUnion(pending.values)
      pending.removeAll()
      lock.unlock()
    }

    /// the volume kept under a key, nil when it was never kept or has been cleared
    static func load(_ key: String) -> Kraken.SculptVolume?
    {
      let file = url(key)
      guard let data = try? Data(contentsOf: file) else { return nil }

      // an opened volume counts as used, so it is claimed for this run and its month starts over
      lock.lock()
      claimed.insert(key)
      lock.unlock()
      try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: file.path)
      return Kraken.SculptVolume.decode(data)
    }

    /// drops what has not been used for a month, then the least recently used past the count or the size
    static func prune()
    {
      let manager = FileManager.default
      let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
      guard let files = try? manager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return }

      let now = Date()
      var entries: [(file: URL, used: Date, size: Int)] = []
      for file in files where file.pathExtension == "akvol"
      {
        let values = try? file.resourceValues(forKeys: Set(keys))
        let used = values?.contentModificationDate ?? .distantPast
        if now.timeIntervalSince(used) > age
        {
          try? manager.removeItem(at: file)
          continue
        }
        entries.append((file, used, values?.fileSize ?? 0))
      }

      var total = 0
      for (i, entry) in entries.sorted(by: { $0.used > $1.used }).enumerated()
      {
        total += entry.size
        if i >= count || total > bytes { try? manager.removeItem(at: entry.file) }
      }
    }
  }
}

// MARK: rebuilding

extension Kraken.SculptVolume
{
  /// the nearest point of a triangle to p, with the weights of b and c there
  @inline(__always)
  static func closest(_ p: SIMD3<Float>, _ a: SIMD3<Float>, _ b: SIMD3<Float>, _ c: SIMD3<Float>) -> (point: SIMD3<Float>, v: Float, w: Float)
  {
    let ab = b - a, ac = c - a, ap = p - a
    let d1 = simd_dot(ab, ap), d2 = simd_dot(ac, ap)
    if d1 <= 0, d2 <= 0 { return (a, 0, 0) }

    let bp = p - b
    let d3 = simd_dot(ab, bp), d4 = simd_dot(ac, bp)
    if d3 >= 0, d4 <= d3 { return (b, 1, 0) }

    let vc = d1 * d4 - d3 * d2
    if vc <= 0, d1 >= 0, d3 <= 0
    {
      let v = d1 / (d1 - d3)
      return (a + ab * v, v, 0)
    }

    let cp = p - c
    let d5 = simd_dot(ab, cp), d6 = simd_dot(ac, cp)
    if d6 >= 0, d5 <= d6 { return (c, 0, 1) }

    let vb = d5 * d2 - d1 * d6
    if vb <= 0, d2 >= 0, d6 <= 0
    {
      let w = d2 / (d2 - d6)
      return (a + ac * w, 0, w)
    }

    let va = d3 * d6 - d5 * d4
    if va <= 0, d4 - d3 >= 0, d5 - d6 >= 0
    {
      let w = (d4 - d3) / ((d4 - d3) + (d5 - d6))
      return (b + (c - b) * w, 1 - w, w)
    }

    let sum = va + vb + vc
    guard sum > 1e-20 else { return (a, 0, 0) }
    let v = vb / sum, w = vc / sum
    return (a + ab * v + ac * w, v, w)
  }

  /// what a run of triangles found for the grid points of one brick
  private struct Found
  {
    var distance = [Float](repeating: .infinity, count: Kraken.SculptBrick.count)
    var signed = [Float](repeating: 0, count: Kraken.SculptBrick.count)
    var color = [SIMD4<UInt8>](repeating: .zero, count: Kraken.SculptBrick.count)
    var mask = [UInt8](repeating: 0, count: Kraken.SculptBrick.count)

    /// writes one grid point in place, a copy taken out of the dictionary would copy all four arrays on every write
    mutating func set(_ i: Int, distance d: Float, signed: Float, color c: SIMD4<UInt8>, mask m: UInt8)
    {
      distance[i] = d
      self.signed[i] = signed
      color[i] = c
      mask[i] = m
    }

    /// keeps whichever of the two found each point nearer
    mutating func take(_ other: Found)
    {
      for i in 0 ..< Kraken.SculptBrick.count where other.distance[i] < distance[i]
      {
        distance[i] = other.distance[i]
        signed[i] = other.signed[i]
        color[i] = other.color[i]
        mask[i] = other.mask[i]
      }
    }
  }

  /// a volume rebuilt from a sculpt's surface, true distances and the paint, gloss and mask within the band
  static func fromMesh(_ surface: Kraken.SculptSurface, voxel: Float, base: SIMD4<UInt8>) -> Kraken.SculptVolume
  {
    let volume = Kraken.SculptVolume(voxel: voxel)
    volume.base = base
    let points = surface.points, tris = surface.triangles
    let count = tris.count / 3
    guard count > 0, voxel > 0 else { return volume }

    let reach = volume.band
    let hasNormals = surface.normals.count == points.count
    let hasColors = surface.colors.count == points.count
    let hasMask = surface.mask.count == points.count

    // runs of neighboring triangles, the mesher writes them brick by brick so a run stays in one place
    var runs: [Range<Int>] = []
    var start = 0
    var lo = SIMD3<Float>(repeating: .infinity), hi = SIMD3<Float>(repeating: -.infinity)
    for t in 0 ..< count
    {
      let a = points[Int(tris[t * 3])], b = points[Int(tris[t * 3 + 1])], c = points[Int(tris[t * 3 + 2])]
      let nlo = simd_min(lo, simd_min(a, simd_min(b, c))), nhi = simd_max(hi, simd_max(a, simd_max(b, c)))
      if t > start, simd_reduce_max(nhi - nlo) > voxel * 16 || t - start >= 2048
      {
        runs.append(start ..< t)
        start = t
        lo = simd_min(a, simd_min(b, c))
        hi = simd_max(a, simd_max(b, c))
      }
      else
      {
        lo = nlo
        hi = nhi
      }
    }
    runs.append(start ..< count)

    var merged: [SIMD3<Int32>: Found] = [:]
    let lock = NSLock()

    DispatchQueue.concurrentPerform(iterations: runs.count)
    { r in
      let run = runs[r]
      var rlo = SIMD3<Float>(repeating: .infinity), rhi = SIMD3<Float>(repeating: -.infinity)
      for t in run
      {
        for k in 0 ..< 3
        {
          let p = points[Int(tris[t * 3 + k])]
          rlo = simd_min(rlo, p)
          rhi = simd_max(rhi, p)
        }
      }

      let glo = SIMD3<Int32>(((rlo - reach) / voxel).rounded(.down))
      let ghi = SIMD3<Int32>(((rhi + reach) / voxel).rounded(.up))
      let size = ghi &- glo &+ 1
      let cells = Int(size.x) * Int(size.y) * Int(size.z)
      var best = [Float](repeating: .infinity, count: cells)
      var which = [Int32](repeating: -1, count: cells)
      var weights = [SIMD2<Float>](repeating: .zero, count: cells)
      let reach2 = reach * reach

      for t in run
      {
        let a = points[Int(tris[t * 3])], b = points[Int(tris[t * 3 + 1])], c = points[Int(tris[t * 3 + 2])]
        let tlo = simd_max(Kraken.SculptVolume.whole(((simd_min(a, simd_min(b, c)) - reach) / voxel).rounded(.down)), glo)
        let thi = simd_min(Kraken.SculptVolume.whole(((simd_max(a, simd_max(b, c)) + reach) / voxel).rounded(.up)), ghi)
        guard tlo.x <= thi.x, tlo.y <= thi.y, tlo.z <= thi.z else { continue }

        for z in tlo.z ... thi.z
        {
          for y in tlo.y ... thi.y
          {
            for x in tlo.x ... thi.x
            {
              let g = SIMD3<Int32>(x, y, z)
              let p = SIMD3<Float>(g) * voxel
              let found = closest(p, a, b, c)
              let d2 = simd_length_squared(p - found.point)
              guard d2 <= reach2 else { continue }

              let l = g &- glo
              let i = Int(l.x) + Int(size.x) * (Int(l.y) + Int(size.y) * Int(l.z))
              guard d2 < best[i] else { continue }
              best[i] = d2
              which[i] = Int32(t)
              weights[i] = SIMD2(found.v, found.w)
            }
          }
        }
      }

      // what the run found, sorted into the bricks it falls in
      var runFound: [SIMD3<Int32>: Found] = [:]
      for i in 0 ..< cells where which[i] >= 0
      {
        let lz = Int32(i / (Int(size.x) * Int(size.y)))
        let ly = Int32((i / Int(size.x)) % Int(size.y))
        let lx = Int32(i % Int(size.x))
        let g = glo &+ SIMD3(lx, ly, lz)
        let p = SIMD3<Float>(g) * voxel

        let t = Int(which[i])
        let ia = Int(tris[t * 3]), ib = Int(tris[t * 3 + 1]), ic = Int(tris[t * 3 + 2])
        let v = weights[i].x, w = weights[i].y, u = 1 - v - w
        let q = points[ia] * u + points[ib] * v + points[ic] * w

        // the side a point is on follows the surface's own normal where it lands, which holds at edges and corners
        var n = hasNormals ? surface.normals[ia] * u + surface.normals[ib] * v + surface.normals[ic] * w : .zero
        if simd_length_squared(n) < 1e-12 { n = simd_cross(points[ib] - points[ia], points[ic] - points[ia]) }
        let distance = best[i].squareRoot()
        let signed = simd_dot(p - q, n) < 0 ? -distance : distance

        let k = key(g), at = local(g)
        let index = Kraken.SculptBrick.index(at.x, at.y, at.z)
        var color = base
        if hasColors
        {
          let blend = SIMD4<Float>(surface.colors[ia]) * u + SIMD4<Float>(surface.colors[ib]) * v + SIMD4<Float>(surface.colors[ic]) * w
          color = SIMD4<UInt8>(simd_clamp(blend, SIMD4(repeating: 0), SIMD4(repeating: 255)).rounded(.toNearestOrAwayFromZero))
        }

        var mask: UInt8 = 0
        if hasMask
        {
          let nearest = u >= v && u >= w ? ia : v >= w ? ib : ic
          mask = surface.mask[nearest]
        }

        runFound[k, default: Found()].set(index, distance: distance, signed: signed, color: color, mask: mask)
      }

      lock.lock()
      for (k, found) in runFound
      {
        if merged[k] == nil { merged[k] = found } else { merged[k]!.take(found) }
      }
      lock.unlock()
    }

    sides(surface, voxel: voxel, &merged)

    let band = volume.band
    var known: [SIMD3<Int32>: [Bool]] = [:]
    known.reserveCapacity(merged.count)
    for (k, found) in merged
    {
      let brick = volume.densify(k)
      var flags = [Bool](repeating: false, count: Kraken.SculptBrick.count)
      for i in 0 ..< Kraken.SculptBrick.count where found.distance[i].isFinite
      {
        brick.distance[i] = max(min(found.signed[i], band), -band)
        brick.color[i] = found.color[i]
        brick.mask[i] = found.mask[i]
        flags[i] = true
      }
      known[k] = flags
    }

    settle(volume, known: known, seeded: true)
    return volume
  }

  /// which side of the surface each grid point is on, read exactly off a mesher made surface so thin wires come back the same
  private static func sides(_ surface: Kraken.SculptSurface, voxel: Float, _ merged: inout [SIMD3<Int32>: Found])
  {
    let points = surface.points, tris = surface.triangles
    let count = tris.count / 3
    let hasNormals = surface.normals.count == points.count
    var crossed = Set<SIMD4<Int32>>()
    var votes: [SIMD3<Int32>: Int32] = [:]
    crossed.reserveCapacity(count / 2)
    votes.reserveCapacity(count)

    var matched = 0
    for t in 0 ..< count
    {
      let ia = Int(tris[t * 3]), ib = Int(tris[t * 3 + 1]), ic = Int(tris[t * 3 + 2])
      let ca = Kraken.SculptVolume.whole((points[ia] / voxel).rounded(.down))
      let cb = Kraken.SculptVolume.whole((points[ib] / voxel).rounded(.down))
      let cc = Kraken.SculptVolume.whole((points[ic] / voxel).rounded(.down))

      // the axis all three cells share is the edge's, and across the other two they sit just below its corner
      var axis = -1
      for k in 0 ..< 3 where ca[k] == cb[k] && cb[k] == cc[k]
      {
        axis = k
        break
      }
      guard axis >= 0 else { continue }

      var g = ca
      var fits = true
      for k in 0 ..< 3 where k != axis
      {
        let top = max(ca[k], max(cb[k], cc[k])), bottom = min(ca[k], min(cb[k], cc[k]))
        if top - bottom != 1 { fits = false }
        g[k] = top
      }
      guard fits else { continue }

      var n = hasNormals ? surface.normals[ia] + surface.normals[ib] + surface.normals[ic] : .zero
      if simd_length_squared(n) < 1e-12 { n = simd_cross(points[ib] - points[ia], points[ic] - points[ia]) }
      guard abs(n[axis]) > 1e-9 else { continue }

      var step = SIMD3<Int32>.zero
      step[axis] = 1
      let outward: Int32 = n[axis] > 0 ? 1 : -1
      votes[g &+ step, default: 0] += outward
      votes[g, default: 0] -= outward
      crossed.insert(SIMD4(g.x, g.y, g.z, Int32(axis)))
      matched += 1
    }

    // a surface that did not come from this grid matches only by chance
    guard matched * 10 >= count * 9 else { return }

    func reached(_ g: SIMD3<Int32>) -> Bool
    {
      let l = local(g)
      return merged[key(g)]?.distance[Kraken.SculptBrick.index(l.x, l.y, l.z)].isFinite ?? false
    }

    var inside: [SIMD3<Int32>: Bool] = [:]
    inside.reserveCapacity(votes.count * 4)
    var queue: [SIMD3<Int32>] = []
    for (g, vote) in votes where vote != 0 && reached(g)
    {
      inside[g] = vote < 0
      queue.append(g)
    }

    var head = 0
    while head < queue.count
    {
      let g = queue[head]
      head += 1
      let here = inside[g]!
      for axis in 0 ..< 3
      {
        for direction: Int32 in [1, -1]
        {
          var step = SIMD3<Int32>.zero
          step[axis] = direction
          let q = g &+ step
          guard inside[q] == nil, reached(q) else { continue }

          let low = direction > 0 ? g : q
          let flips = crossed.contains(SIMD4(low.x, low.y, low.z, Int32(axis)))
          inside[q] = flips ? !here : here
          queue.append(q)
        }
      }
    }

    for (g, flag) in inside
    {
      let k = key(g), l = local(g)
      let i = Kraken.SculptBrick.index(l.x, l.y, l.z)
      guard let d = merged[k]?.distance[i] else { continue }
      merged[k]!.signed[i] = flag ? -d : d
    }
  }

  /// marks bricks no surface reached inside or out by flooding from outside, and fills unreached points from their neighbors
  static func settle(_ volume: Kraken.SculptVolume, known given: [SIMD3<Int32>: [Bool]], seeded: Bool = false)
  {
    let keys = Array(given.keys)
    guard var lo = keys.first, var hi = keys.first else { return }

    // unsided points in each brick take a side from their neighbors first, every brick independently so they run at once
    let side = Kraken.SculptBrick.side
    let fill = volume.band
    let around: [SIMD3<Int32>] = [SIMD3(1, 0, 0), SIMD3(-1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, -1, 0), SIMD3(0, 0, 1),
                                  SIMD3(0, 0, -1)]
    let owners = keys.map { volume.bricks[$0] }
    var knowns = keys.map { given[$0] }
    knowns.withUnsafeMutableBufferPointer
    { knowns in
      DispatchQueue.concurrentPerform(iterations: keys.count)
      { n in
        guard let brick = owners[n], var known = knowns[n] else { return }

        brick.distance.withUnsafeMutableBufferPointer
        { distance in
          known.withUnsafeMutableBufferPointer
          { known in
            for _ in 0 ..< Int(side)
            {
              var changed = false
              for z in 0 ..< side
              {
                for y in 0 ..< side
                {
                  for x in 0 ..< side
                  {
                    let i = Kraken.SculptBrick.index(x, y, z)
                    guard !known[i] else { continue }

                    for s in around
                    {
                      let q = SIMD3(x, y, z) &+ s
                      guard q.x >= 0, q.y >= 0, q.z >= 0, q.x < side, q.y < side, q.z < side else { continue }
                      let j = Kraken.SculptBrick.index(q.x, q.y, q.z)
                      guard known[j] else { continue }
                      distance[i] = distance[j] < 0 ? -fill : fill
                      known[i] = true
                      changed = true
                      break
                    }
                  }
                }
              }

              if !changed { break }
            }
          }
        }

        knowns[n] = known
      }
    }

    var start = given
    for (n, k) in keys.enumerated() where owners[n] != nil
    {
      if let known = knowns[n] { start[k] = known }
    }

    let band = volume.band
    let dense = Set(keys)
    for k in keys
    {
      lo = simd_min(lo, k)
      hi = simd_max(hi, k)
    }

    lo &-= 1
    hi &+= 1
    let steps: [SIMD3<Int32>] = [SIMD3(1, 0, 0), SIMD3(-1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, -1, 0), SIMD3(0, 0, 1), SIMD3(0, 0, -1)]
    func within(_ n: SIMD3<Int32>) -> Bool
    {
      n.x >= lo.x && n.y >= lo.y && n.z >= lo.z && n.x <= hi.x && n.y <= hi.y && n.z <= hi.z
    }

    if seeded
    {
      // each empty brick takes the side of the nearest surface, spreading from dense bricks' faces so an open edge can't turn a form inside out
      var votes: [SIMD3<Int32>: Int] = [:]
      for k in keys
      {
        guard let brick = volume.bricks[k], let known = start[k] else { continue }
        for s in steps
        {
          let n = k &+ s
          guard within(n), !dense.contains(n) else { continue }
          var vote = 0
          for a in 0 ..< side
          {
            for b in 0 ..< side
            {
              let face: Int32 = s.x + s.y + s.z > 0 ? side - 1 : 0
              let l = s.x != 0 ? SIMD3(face, a, b) : s.y != 0 ? SIMD3(a, face, b) : SIMD3(a, b, face)
              let i = Kraken.SculptBrick.index(l.x, l.y, l.z)
              guard known[i] else { continue }
              vote += brick.distance[i] < 0 ? 1 : -1
            }
          }
          votes[n, default: 0] += vote
        }
      }

      var inner: [SIMD3<Int32>: Bool] = [:]
      var queue: [SIMD3<Int32>] = []
      for (n, vote) in votes where vote != 0
      {
        inner[n] = vote > 0
        queue.append(n)
      }

      var head = 0
      while head < queue.count
      {
        let k = queue[head]
        head += 1
        let flag = inner[k] ?? false
        for s in steps
        {
          let n = k &+ s
          guard within(n), !dense.contains(n), inner[n] == nil else { continue }
          inner[n] = flag
          queue.append(n)
        }
      }

      for (k, flag) in inner where flag { volume.inside.insert(k) }
    }
    else
    {
      var outside: Set<SIMD3<Int32>> = [lo]
      var queue = [lo]
      while let k = queue.popLast()
      {
        for s in steps
        {
          let n = k &+ s
          guard within(n), !dense.contains(n), !outside.contains(n) else { continue }
          outside.insert(n)
          queue.append(n)
        }
      }

      for z in lo.z ... hi.z
      {
        for y in lo.y ... hi.y
        {
          for x in lo.x ... hi.x
          {
            let k = SIMD3(x, y, z)
            if !dense.contains(k), !outside.contains(k) { volume.inside.insert(k) }
          }
        }
      }
    }

    // whatever is still unknown follows the neighbor bricks, each brick on its own core again
    let insides = volume.inside
    let settled = start
    DispatchQueue.concurrentPerform(iterations: keys.count)
    { n in
      let k = keys[n]
      guard let brick = owners[n], let known = settled[k] else { return }

      brick.distance.withUnsafeMutableBufferPointer
      { distance in
        for z in 0 ..< side
        {
          for y in 0 ..< side
          {
            for x in 0 ..< side where !known[Kraken.SculptBrick.index(x, y, z)]
            {
              let g = k &* side &+ SIMD3(x, y, z)
              let nearby = steps.contains { insides.contains(key(g &+ $0 &* side)) }
              distance[Kraken.SculptBrick.index(x, y, z)] = nearby ? -band : band
            }
          }
        }
      }
    }

    volume.compact(keys)
  }
}
