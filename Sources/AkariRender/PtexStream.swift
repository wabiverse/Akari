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

public extension Akari.Geom
{
  /// The recorded draws triangles' streamed Ptex faces, a region a draw,
  /// which its base instance points the gbuffer shader at.
  final class PtexFaces
  {
    /// The first stands for the draws without any, base instance 0.
    public private(set) var entries: [UInt32] = [.max]
    public private(set) var count = 1
    public private(set) var revision = 0

    public init() {}

    public func reset()
    {
      entries = [.max]
      count = 1
      revision += 1
    }

    /// Adds a draw's faces, returning the base instance it draws with.
    public func add(_ faces: ArraySlice<UInt32>) -> UInt32
    {
      let base = UInt32(count)
      entries += faces
      count += faces.count
      revision += 1
      return base
    }

    public func take() -> [UInt32]
    {
      entries
    }
  }
}

extension Akari
{
  /// Streams Ptex color tiles into a fixed size GPU cache as the frames ask
  /// for them, after Lee, Zeichner and Li, "A Texture Streaming Pipeline for
  /// Real-Time GPU Ray Tracing" (SIGGRAPH 2025): slabs of an atlas a tile
  /// size apiece, a hash table from tile to slot the shader probes, the
  /// gbuffer's requests read back to load what's missing and keep what's
  /// drawn, and the least recently drawn evicted once it's full.
  final class PtexStream
  {
    let faces = Geom.PtexFaces()

    /// What the atlas takes, 512 MB with 16 GB of memory and scaling with it.
    static var cacheBytes: Int
    {
      min(max(Int(ProcessInfo.processInfo.physicalMemory / 32), 256 << 20), 4 << 30)
    }

    private static let layerSize = 8192
    private static let slabSize = 264
    private static let slabsAcross = layerSize / slabSize
    private static let slabsPerLayer = slabsAcross * slabsAcross
    private static let ring = 3
    private static let stagingTexels = 2 << 20
    private static let maxTiles = 512
    private static let maxUpdates = 1 << 18
    private static let maxSamples = 1 << 15
    private static let inFlight: UInt32 = 3

    private struct Slab
    {
      var size = -1
      var across = 0
      var keys: [UInt64] = []
      var used: [UInt32] = []
      var free: [UInt16] = []
      var places: [Int32] = []
      var newest: UInt32 = 0
    }

    private var slabs: [Slab] = []
    private var freeSlabs: [Int] = []
    private var open = [[Int]](repeating: [], count: 25)
    private var residents = [[UInt32]](repeating: [], count: 25)
    private var resident: [UInt64: UInt32] = [:]
    private var stale: [Int]?

    private var hashA: [UInt32] = []
    private var hashB: [UInt32] = []
    private var hashSlot: [UInt32] = []
    private var mask: UInt32 = 0
    private var probes: UInt32 = 0
    private var dirty = Set<Int>()

    private var frame: UInt32 = inFlight + 1
    private var quiet = 0
    private var stride = 4
    private var tableRevision = -1

    private var atlas: GLuint = 0
    private var hash: GLuint = 0
    private var table: GLuint = 0
    private var tableBuffer: GLuint = 0
    private var placeholder: GLuint = 0
    private var kernels = Akari.ComputeKernels<Kernel>()
    private var staging: [GLuint] = []
    private var copies: [GLuint] = []
    private var updates: [GLuint] = []
    private var updateCapacity: [Int] = []
    private var readback: GLuint = 0

    var allocated: Int
    {
      atlas == 0 ? 0 : Self.cacheBytes + hashA.count * 16
    }

    /// Whether the frame still waits on tiles, a final render draws until it doesn't.
    var isStreaming: Bool
    {
      atlas != 0 && (Pixar.HdAkariPtexPendingTiles() > 0 || quiet < stride * stride + 2)
    }

    /// Loads what the last frames asked for and returns what the gbuffer
    /// binds, `keys` its request textures still holding the last frame.
    func update(keys: (GLuint, GLuint), width: Int, height: Int)
      -> (table: GLuint, atlas: GLuint, hash: GLuint, params: SIMD4<Int32>)
    {
      if kernels.isEmpty { kernels = .precompile() }
      guard faces.count > 1, kernels[.copy].isBuilt, atlas != 0 || allocate()
      else
      {
        if placeholder == 0 { placeholder = gl.createTextureArray(width: 4, height: 1, layers: 1, format: GLenum(GL_R32UI)) }
        return (placeholder, placeholder, placeholder, .zero)
      }

      frame += 1
      stale = nil
      if tableRevision != faces.revision { uploadTable() }
      readRequests()
      let r = Int(frame) % Self.ring
      let placed = takeTiles(into: r)
      if placed > 0 { dispatch(kernels[.copy], count: placed, buffers: [copies[r], staging[r]], image: atlas, groups: placed) }
      if !dirty.isEmpty { dispatchHashUpdates(into: r) }
      if keys.0 != 0, keys.1 != 0 { gather(keys, width: width, height: height) }
      return (table, atlas, hash, SIMD4(Int32(bitPattern: mask), Int32(probes), 0, 1))
    }

    private func allocate() -> Bool
    {
      let layers = max(Self.cacheBytes / (Self.layerSize * Self.layerSize * 4), 1)
      let entries = max(1 << 18, 1 << (Int.bitWidth - (Self.cacheBytes / 512 - 1).leadingZeroBitCount))
      atlas = gl.createTextureArray(width: GLsizei(Self.layerSize), height: GLsizei(Self.layerSize), layers: GLsizei(layers),
                                    format: GLenum(GL_R32UI))
      hash = gl.createTextureArray(width: 4096, height: GLsizei(entries / 1024), layers: 1, format: GLenum(GL_R32UI))
      guard atlas != 0, hash != 0 else { return false }
      mask = UInt32(entries - 1)
      hashA = [UInt32](repeating: 0, count: entries)
      hashB = hashA
      hashSlot = hashA
      slabs = [Slab](repeating: Slab(), count: layers * Self.slabsPerLayer)
      freeSlabs = Array((0 ..< slabs.count).reversed())
      let usage = GLuint(LGL_BUFFER_COMPUTE_READ | LGL_BUFFER_MAP_WRITE)
      staging = (0 ..< Self.ring).map { _ in gl.createBuffer(usage: usage, sizeBytes: GLsizei(Self.stagingTexels * 4)) }
      copies = (0 ..< Self.ring).map { _ in gl.createBuffer(usage: usage, sizeBytes: GLsizei(Self.maxTiles * 16)) }
      updates = (0 ..< Self.ring).map { _ in gl.createBuffer(usage: usage, sizeBytes: GLsizei(Self.maxUpdates * 16)) }
      updateCapacity = [Int](repeating: Self.maxUpdates, count: Self.ring)
      readback = gl.createComputeReadback(sizeBytes: GLsizei(Self.maxSamples * 8), ringSize: 3)
      // the hash table starts empty, a texture starts as whatever its memory held.
      kernels[.clear].set(.params, SIMD4<Int32>(4096, Int32(entries / 1024), 0, 0))
      kernels[.clear].layeredImage(hash, at: 0, format: GLenum(GL_R32UI))
      kernels[.clear].dispatch(4096 / 16, entries / 1024 / 16)
      return true
    }

    /// The table, 8192 entries a row, copied on the GPU from a file mapped buffer into a texture the shader reads.
    private func uploadTable()
    {
      tableRevision = faces.revision
      let entries = faces.take()
      guard entries.count == faces.count else { return }
      let rows = (entries.count + 8191) / 8192
      if table != 0 { gl.deleteTextures(count: 1, textures: &table) }
      if tableBuffer != 0 { gl.deleteBuffer(tableBuffer) }
      table = gl.createTextureArray(width: 8192, height: GLsizei(min(rows, 8192)), layers: GLsizei((rows + 8191) / 8192),
                                    format: GLenum(GL_R32UI))
      tableBuffer = entries.withUnsafeBytes
      { bytes in
        let mapped = Geom.GeometryCache.shared.mappedBuffer(usage: GLuint(LGL_BUFFER_COMPUTE_READ), [bytes])
        if mapped != 0 { return mapped }
        let buffer = gl.createBuffer(usage: GLuint(LGL_BUFFER_COMPUTE_READ | LGL_BUFFER_MAP_WRITE), sizeBytes: GLsizei(bytes.count))
        gl.mapBuffer(buffer)?.copyMemory(from: bytes.baseAddress!, byteCount: bytes.count)
        return buffer
      }

      if table != 0, tableBuffer != 0
      {
        dispatch(kernels[.table], count: entries.count, buffers: [tableBuffer], image: table, groups: (entries.count + 63) / 64)
      }
    }

    private func readRequests()
    {
      var size: GLsizei = 0
      guard readback != 0, let raw = gl.computeReadbackLatest(readback, size: &size) else { return }
      let samples = raw.assumingMemoryBound(to: UInt32.self)
      var wanted = Set<UInt64>()
      for i in 0 ..< Int(size) / 8
      {
        let a = samples[i * 2], b = samples[i * 2 + 1]
        guard a != 0 else { continue }
        let key = UInt64(a) << 32 | UInt64(b & 0x7FFF_FFFF)
        if let slot = resident[key]
        {
          touch(slot)
        }
        else if b & 0x8000_0000 == 0
        {
          wanted.insert(key)
        }
      }

      quiet = wanted.isEmpty ? quiet + 1 : 0
      let keys = Array(wanted)
      keys.withUnsafeBufferPointer { Pixar.HdAkariPtexRequestTiles($0.baseAddress, Int32($0.count)) }
    }

    private func takeTiles(into r: Int) -> Int
    {
      guard let texels = gl.mapBuffer(staging[r])?.assumingMemoryBound(to: UInt32.self) else { return 0 }
      var keys = [UInt64](repeating: 0, count: Self.maxTiles)
      var sizes = [UInt32](repeating: 0, count: Self.maxTiles)
      var offsets = [UInt32](repeating: 0, count: Self.maxTiles)
      let taken = Int(Pixar.HdAkariPtexTakeTiles(&keys, &sizes, &offsets, texels, Int32(Self.maxTiles), Int32(Self.stagingTexels)))
      gl.unmapBuffer(staging[r])
      guard taken > 0, let commands = gl.mapBuffer(copies[r])?.assumingMemoryBound(to: SIMD4<UInt32>.self) else { return 0 }
      var placed = 0
      for i in 0 ..< taken where resident[keys[i]] == nil && dirty.count < Self.maxUpdates - 8192
      {
        let width = Int(sizes[i] & 0xFFFF), height = Int(sizes[i] >> 16)
        guard let slot = place(keys[i], width: width, height: height) else { continue }
        commands[placed] = SIMD4(offsets[i], origin(slot), UInt32(width + 2) | UInt32(height + 2) << 16, 0)
        placed += 1
      }

      gl.unmapBuffer(copies[r])
      return placed
    }

    private func dispatchHashUpdates(into r: Int)
    {
      // a slab's worth of evictions can shift more entries than a frame's buffer holds.
      if dirty.count > updateCapacity[r]
      {
        gl.deleteBuffer(updates[r])
        updateCapacity[r] = 1 << (Int.bitWidth - (dirty.count - 1).leadingZeroBitCount)
        updates[r] = gl.createBuffer(usage: GLuint(LGL_BUFFER_COMPUTE_READ | LGL_BUFFER_MAP_WRITE),
                                     sizeBytes: GLsizei(updateCapacity[r] * 16))
      }

      guard let out = gl.mapBuffer(updates[r])?.assumingMemoryBound(to: SIMD4<UInt32>.self) else { return }
      var count = 0
      for index in dirty
      {
        out[count] = SIMD4(UInt32(index), hashA[index], hashB[index], hashSlot[index])
        count += 1
      }

      gl.unmapBuffer(updates[r])
      dirty.removeAll(keepingCapacity: true)
      dispatch(kernels[.hash], count: count, buffers: [updates[r]], image: hash, groups: (count + 63) / 64)
    }

    /// A pixel in `stride` each way, a different one each frame.
    private func gather(_ keys: (GLuint, GLuint), width: Int, height: Int)
    {
      stride = max(4, Int((Double(width * height) / Double(Self.maxSamples)).squareRoot().rounded(.up)))
      let columns = (width + stride - 1) / stride, rows = (height + stride - 1) / stride
      let step = Int(frame) % (stride * stride)
      kernels[.gather].set(.params, SIMD4(Int32(stride), Int32(step % stride | (step / stride) << 8), Int32(columns), Int32(rows)))
      kernels[.gather].sample(keys.0, at: 0)
      kernels[.gather].sample(keys.1, at: 1)
      kernels[.gather].bind(gl.computeReadbackCurrentBuffer(readback))
      kernels[.gather].readback(readback, at: 0)
      kernels[.gather].dispatch(Self.maxSamples / 64)
    }

    private func dispatch(_ kernel: Akari.ComputeKernel, count: Int, buffers: [GLuint], image: GLuint, groups: Int)
    {
      kernel.set(.params, SIMD4(Int32(count), 0, 0, 0))
      kernel.bind(buffers)

      kernel.layeredImage(image, at: 0, format: GLenum(GL_R32UI))
      kernel.dispatch(groups)
    }

    private static func sizeClass(_ width: Int, _ height: Int) -> Int
    {
      (max(width, 4).trailingZeroBitCount - 2) * 5 + max(height, 4).trailingZeroBitCount - 2
    }

    private static func slotSize(_ size: Int) -> (width: Int, height: Int)
    {
      ((1 << (size / 5 + 2)) + 2, (1 << (size % 5 + 2)) + 2)
    }

    private func origin(_ slot: UInt32) -> UInt32
    {
      let s = Int(slot >> 12), local = Int(slot & 0xFFF)
      let slab = slabs[s]
      let (w, h) = Self.slotSize(slab.size)
      let inLayer = s % Self.slabsPerLayer
      let x = inLayer % Self.slabsAcross * Self.slabSize + local % slab.across * w
      let y = inLayer / Self.slabsAcross * Self.slabSize + local / slab.across * h
      return UInt32(s / Self.slabsPerLayer) << 28 | UInt32(y) << 14 | UInt32(x)
    }

    private func touch(_ slot: UInt32)
    {
      let s = Int(slot >> 12)
      slabs[s].used[Int(slot & 0xFFF)] = frame
      slabs[s].newest = frame
    }

    private func place(_ key: UInt64, width: Int, height: Int) -> UInt32?
    {
      let size = Self.sizeClass(width, height)
      // past half full, the hash table's probes grow long.
      if resident.count >= Int(mask / 2), let victim = oldest(size) ?? residents.lazy.compactMap({ self.oldest(in: $0) }).first
      {
        evict(victim)
      }

      guard let slot = freeSlot(size) else { return nil }
      let s = Int(slot >> 12), local = Int(slot & 0xFFF)
      slabs[s].keys[local] = key
      slabs[s].used[local] = frame
      slabs[s].newest = frame
      slabs[s].places[local] = Int32(residents[size].count)
      residents[size].append(slot)
      resident[key] = slot
      insert(key, slot: origin(slot))
      return slot
    }

    private func freeSlot(_ size: Int) -> UInt32?
    {
      while let s = open[size].last
      {
        if let local = slabs[s].free.popLast()
        {
          if slabs[s].free.isEmpty { open[size].removeLast() }
          return UInt32(s) << 12 | UInt32(local)
        }

        open[size].removeLast()
      }

      if let s = freeSlabs.popLast()
      {
        assign(s, size)
        return freeSlot(size)
      }

      if let victim = oldest(size)
      {
        evict(victim)
        return freeSlot(size)
      }
      // no tile this size is old enough, a whole slab of another size goes instead.
      if stale == nil
      {
        stale = slabs.indices.filter { slabs[$0].size >= 0 && slabs[$0].newest + Self.inFlight < frame }
          .sorted { slabs[$0].newest > slabs[$1].newest }
      }
      while let s = stale?.popLast()
      {
        guard slabs[s].newest + Self.inFlight < frame else { continue }
        for local in slabs[s].keys.indices where slabs[s].keys[local] != 0
        {
          evict(UInt32(s) << 12 | UInt32(local))
        }

        open[slabs[s].size].removeAll { $0 == s }
        assign(s, size)
        return freeSlot(size)
      }

      return nil
    }

    private func assign(_ s: Int, _ size: Int)
    {
      let (w, h) = Self.slotSize(size)
      let across = Self.slabSize / w, count = across * (Self.slabSize / h)
      slabs[s] = Slab(size: size, across: across, keys: [UInt64](repeating: 0, count: count),
                      used: [UInt32](repeating: 0, count: count), free: Array((0 ..< UInt16(count)).reversed()),
                      places: [Int32](repeating: -1, count: count), newest: frame)
      open[size].append(s)
    }

    private func oldest(_ size: Int) -> UInt32?
    {
      oldest(in: residents[size])
    }

    private func oldest(in slots: [UInt32]) -> UInt32?
    {
      guard !slots.isEmpty else { return nil }
      var best: UInt32?
      var bestUsed = UInt32.max
      for _ in 0 ..< min(32, slots.count)
      {
        let slot = slots[Int.random(in: 0 ..< slots.count)]
        let used = slabs[Int(slot >> 12)].used[Int(slot & 0xFFF)]
        if used < bestUsed { best = slot; bestUsed = used }
      }

      return bestUsed + Self.inFlight < frame ? best : nil
    }

    private func evict(_ slot: UInt32)
    {
      let s = Int(slot >> 12), local = Int(slot & 0xFFF)
      let size = slabs[s].size
      let key = slabs[s].keys[local]
      resident[key] = nil
      remove(key)
      let place = Int(slabs[s].places[local])
      let last = residents[size].removeLast()
      if last != slot
      {
        residents[size][place] = last
        slabs[Int(last >> 12)].places[Int(last & 0xFFF)] = Int32(place)
      }

      slabs[s].keys[local] = 0
      slabs[s].places[local] = -1
      slabs[s].free.append(UInt16(local))
      if slabs[s].free.count == 1 { open[size].append(s) }
    }

    /// The shader's `ptexSlot` hashes the same.
    private static func hashOf(_ a: UInt32, _ b: UInt32) -> UInt32
    {
      var h = (a &* 0x9E37_79B1) ^ ((b &+ 0x7F4A_7C15) &* 0x85EB_CA77)
      h ^= h >> 15
      h = h &* 0x2C1B_3C6D
      h ^= h >> 12
      return h
    }

    private func insert(_ key: UInt64, slot: UInt32)
    {
      let a = UInt32(key >> 32), b = UInt32(truncatingIfNeeded: key)
      var i = Self.hashOf(a, b) & mask
      var distance: UInt32 = 0
      while hashA[Int(i)] != 0
      {
        i = (i + 1) & mask
        distance += 1
      }

      hashA[Int(i)] = a
      hashB[Int(i)] = b
      hashSlot[Int(i)] = slot
      dirty.insert(Int(i))
      probes = max(probes, distance)
    }

    private func remove(_ key: UInt64)
    {
      let a = UInt32(key >> 32), b = UInt32(truncatingIfNeeded: key)
      var i = Self.hashOf(a, b) & mask
      while hashA[Int(i)] != a || hashB[Int(i)] != b
      {
        guard hashA[Int(i)] != 0 else { return }
        i = (i + 1) & mask
      }

      var j = i
      while true
      {
        j = (j + 1) & mask
        guard hashA[Int(j)] != 0 else { break }
        let home = Self.hashOf(hashA[Int(j)], hashB[Int(j)]) & mask
        // an entry stays when its home lies cyclically within (i, j].
        if i <= j ? (home > i && home <= j) : (home > i || home <= j) { continue }
        hashA[Int(i)] = hashA[Int(j)]
        hashB[Int(i)] = hashB[Int(j)]
        hashSlot[Int(i)] = hashSlot[Int(j)]
        dirty.insert(Int(i))
        i = j
      }

      hashA[Int(i)] = 0
      hashB[Int(i)] = 0
      hashSlot[Int(i)] = 0
      dirty.insert(Int(i))
    }

    private enum Kernel: Akari.ComputeKernelName
    {
      case table, copy, hash, clear, gather

      static let label = "ptex"

      var glsl: String
      {
        "#version 430\nvoid main() {}\n"
      }

      var msl: String
      {
        switch self
        {
          case .table: prologue + tableMSL
          case .copy: prologue + copyMSL
          case .hash: prologue + hashMSL
          case .clear: prologue + clearMSL
          case .gather: prologue + gatherMSL
        }
      }

      var threadgroup: SIMD3<Int>
      {
        self == .clear ? SIMD3(16, 16, 1) : SIMD3(64, 1, 1)
      }
    }

    private static let prologue = """
      #include <metal_stdlib>
      using namespace metal;
      struct U { int4 params; };

      """

    private static let tableMSL = """
      kernel void compute_main(constant U& u [[buffer(0)]],
                               device const uint* entries [[buffer(1)]],
                               texture2d_array<uint, access::write> table [[texture(0)]],
                               uint gid [[thread_position_in_grid]])
      {
        if (gid >= uint(u.params.x)) return;
        table.write(uint4(entries[gid]), uint2(gid & 8191u, (gid >> 13) & 8191u), gid >> 26);
      }
      """

    /// A threadgroup a tile: its staged texels' offset, the slot, and its bordered size.
    private static let copyMSL = """
      kernel void compute_main(constant U& u [[buffer(0)]],
                               device const uint4* tiles [[buffer(1)]],
                               device const uint* texels [[buffer(2)]],
                               texture2d_array<uint, access::write> atlas [[texture(0)]],
                               uint group [[threadgroup_position_in_grid]],
                               uint lane [[thread_position_in_threadgroup]])
      {
        if (group >= uint(u.params.x)) return;
        uint4 t = tiles[group];
        uint w = t.z & 0xFFFFu, h = t.z >> 16;
        uint2 origin = uint2(t.y & 16383u, (t.y >> 14) & 16383u);
        for (uint i = lane; i < w * h; i += 64u)
          atlas.write(uint4(texels[t.x + i]), origin + uint2(i % w, i / w), t.y >> 28);
      }
      """

    /// Four texels an entry: its key's halves and its slot.
    private static let hashMSL = """
      kernel void compute_main(constant U& u [[buffer(0)]],
                               device const uint4* updates [[buffer(1)]],
                               texture2d_array<uint, access::write> hash [[texture(0)]],
                               uint gid [[thread_position_in_grid]])
      {
        if (gid >= uint(u.params.x)) return;
        uint4 e = updates[gid];
        uint2 at = uint2((e.x & 1023u) * 4u, e.x >> 10);
        hash.write(uint4(e.y), at, 0);
        hash.write(uint4(e.z), at + uint2(1, 0), 0);
        hash.write(uint4(e.w), at + uint2(2, 0), 0);
      }
      """

    private static let clearMSL = """
      kernel void compute_main(constant U& u [[buffer(0)]],
                               texture2d_array<uint, access::write> hash [[texture(0)]],
                               uint2 gid [[thread_position_in_grid]])
      {
        if (gid.x >= uint(u.params.x) || gid.y >= uint(u.params.y)) return;
        hash.write(uint4(0u), gid, 0);
      }
      """

    private static let gatherMSL = """
      kernel void compute_main(constant U& u [[buffer(0)]],
                               device uint2* out [[buffer(1)]],
                               texture2d<int, access::read> keyA [[texture(0)]],
                               texture2d<int, access::read> keyB [[texture(1)]],
                               uint gid [[thread_position_in_grid]])
      {
        uint columns = uint(u.params.z), rows = uint(u.params.w), stride = uint(u.params.x);
        uint2 px = uint2(gid % max(columns, 1u), gid / max(columns, 1u)) * stride
                   + uint2(uint(u.params.y) & 255u, uint(u.params.y) >> 8);
        bool inside = gid < columns * rows && px.x < keyA.get_width() && px.y < keyA.get_height();
        out[gid] = inside ? uint2(as_type<uint>(keyA.read(px).x), as_type<uint>(keyB.read(px).x)) : uint2(0u);
      }
      """
  }
}

extension Akari.LabFXEngine
{
  /// Streams the Ptex tiles the last frames asked for and binds the cache for the gbuffer.
  func syncPtex()
  {
    let bound = ptex.update(keys: (runtime.texture(.gbuffer, named: .ptexA), runtime.texture(.gbuffer, named: .ptexB)),
                            width: sizes.render.width, height: sizes.render.height)
    setSampler(.ptexTable, bound.table)
    setSampler(.ptexAtlas, bound.atlas)
    setSampler(.ptexHash, bound.hash)
    runtime.setUniform(.ptexParams, bound.params)
  }
}
