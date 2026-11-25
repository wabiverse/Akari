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
import Metal
import simd

extension Kraken
{
  /// lays a dab on the gpu, the processor only finds the bricks and keeps the books, which lets a phone keep up with a stroke
  final class SculptCompute: @unchecked Sendable
  {
    /// off runs every dab on the processor, for comparing the two
    nonisolated(unsafe) static var enabled = true

    static let shared = SculptCompute()

    /// the gpu when it is there and turned on
    static var available: SculptCompute?
    {
      enabled ? shared : nil
    }

    private let device: MTLDevice
    private let queue: MTLCommandQueue
    private let brushPipeline: MTLComputePipelineState
    private let rebandPipeline: MTLComputePipelineState
    private let lock = NSLock()
    private var buffers: [Int: MTLBuffer] = [:]

    /// one brick of voxels, and the threads a group runs, half a brick so a simd group never spans two
    private static let voxels = SculptBrick.count
    private static let group = 256

    private init?()
    {
      guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }

      // the same arithmetic the processor does, no fast math shortcuts
      let options = MTLCompileOptions()
      options.mathMode = .safe
      options.mathFloatingPointFunctions = .precise
      guard let library = try? device.makeLibrary(source: Self.source, options: options),
            let brush = library.makeFunction(name: "sculptBrush"),
            let reband = library.makeFunction(name: "sculptReband"),
            let brushPipeline = try? device.makeComputePipelineState(function: brush),
            let rebandPipeline = try? device.makeComputePipelineState(function: reband),
            brushPipeline.maxTotalThreadsPerThreadgroup >= Self.group,
            rebandPipeline.maxTotalThreadsPerThreadgroup >= Self.group,
            brushPipeline.threadExecutionWidth <= Self.group, Self.group % brushPipeline.threadExecutionWidth == 0
      else { return nil }

      self.device = device
      self.queue = queue
      self.brushPipeline = brushPipeline
      self.rebandPipeline = rebandPipeline
    }

    /// the brushes the gpu lays, grab and snake hook read the volume as the stroke found it and stay on the processor
    func handles(_ brush: SculptBrush) -> Bool
    {
      Self.code(brush) != nil
    }

    private static func code(_ brush: SculptBrush) -> Int32?
    {
      switch brush
      {
        case .draw: 0
        case .clay: 1
        case .blob: 2
        case .inflate: 3
        case .smooth: 4
        case .crease: 5
        case .pinch: 6
        case .flatten: 7
        case .scrape: 8
        case .tube: 9
        case .paint: 10
        case .mask: 11
        case .grab, .snake, .pencil: nil
      }
    }

    private static func code(_ falloff: SculptFalloff) -> Int32
    {
      switch falloff
      {
        case .smooth: 0
        case .sphere: 1
        case .sharp: 2
        case .root: 3
        case .linear: 4
        case .constant: 5
      }
    }

    /// what every thread of a dab reads, laid out the same as the shader's
    private struct Params
    {
      /// center and radius
      var center: SIMD4<Float>
      /// normal and strength
      var normal: SIMD4<Float>
      /// unused and the amount a dab moves the surface
      var delta: SIMD4<Float>
      /// the previous dab and how much the brush paints
      var previous: SIMD4<Float>
      /// the plane clay, flatten and scrape work to, and the reach squared
      var plane: SIMD4<Float>
      /// the paint color in bytes
      var paint: SIMD4<Float>
      /// the table's low corner and how many bricks the dab writes
      var lo: SIMD4<Int32>
      /// the table's size and the brush
      var extent: SIMD4<Int32>
      /// band, voxel and the band repair's limit
      var misc: SIMD4<Float>
      /// falloff and whether the brush ignores the mask
      var flags: SIMD4<Int32>
    }

    private func buffer(_ slot: Int, _ length: Int) -> MTLBuffer?
    {
      let length = max(length, 16)
      if let kept = buffers[slot], kept.length >= length { return kept }
      let made = device.makeBuffer(length: length + length / 2, options: .storageModeShared)
      buffers[slot] = made
      return made
    }

    /// lays one dab over readied bricks as the processor's kernel and band repair would, false when the gpu couldn't
    func run(_ volume: SculptVolume, _ dab: SculptDab, keys: [SIMD3<Int32>], box: (lo: SIMD3<Float>, hi: SIMD3<Float>),
             plane: SIMD3<Float>, rebands: Bool) -> Bool
    {
      guard let brushCode = Self.code(dab.brush) else { return false }
      guard !keys.isEmpty else { return true }

      lock.lock()
      defer { lock.unlock() }

      let voxels = Self.voxels
      let band = volume.band, voxel = volume.voxel
      let count = keys.count

      // the table covers the dab's box and every brick it writes, one brick wider, so every read lands in it
      let size = Float(SculptBrick.side) * voxel
      var low = SculptVolume.whole(floor(box.lo / size)), high = SculptVolume.whole(floor(box.hi / size))
      for k in keys
      {
        low = simd_min(low, k)
        high = simd_max(high, k)
      }

      let lo = low &- 1, hi = high &+ 1
      let extent = hi &- lo &+ 1
      let cells = Int(extent.x) * Int(extent.y) * Int(extent.z)
      @Sendable @inline(__always) func cell(_ k: SIMD3<Int32>) -> Int
      {
        let o = k &- lo
        return Int(o.x) + Int(extent.x) * (Int(o.y) + Int(extent.y) * Int(o.z))
      }

      // the bricks the dab writes come first, then the dense ones it only reads, found a slab per core
      var table = [Int32](repeating: -1, count: cells)
      for (n, k) in keys.enumerated() { table[cell(k)] = Int32(n) }

      let bricks = volume.bricks, inside = volume.inside
      var slabs = [[(Int, SculptBrick)]](repeating: [], count: Int(extent.z))
      table.withUnsafeMutableBufferPointer
      { table in
        slabs.withUnsafeMutableBufferPointer
        { slabs in
          DispatchQueue.concurrentPerform(iterations: slabs.count)
          { i in
            var found: [(Int, SculptBrick)] = []
            let z = lo.z + Int32(i)
            for y in lo.y ... hi.y
            {
              for x in lo.x ... hi.x
              {
                let k = SIMD3(x, y, z)
                let c = cell(k)
                guard table[c] < 0 else { continue }
                if let brick = bricks[k] { found.append((c, brick)) }
                else if inside.contains(k) { table[c] = -2 }
              }
            }
            slabs[i] = found
          }
        }
      }

      var reading: [SculptBrick] = []
      for slab in slabs
      {
        for (c, brick) in slab
        {
          table[c] = Int32(count + reading.count)
          reading.append(brick)
        }
      }

      let readers = reading

      let writers = keys.map { bricks[$0] }
      guard !writers.contains(where: { $0 == nil }) else { return false }

      let slots = count + readers.count
      guard let tableBuffer = buffer(1, cells * 4),
            let distIn = buffer(2, slots * voxels * 4),
            let colorIn = buffer(3, count * voxels * 4),
            let maskIn = buffer(4, count * voxels),
            let distOut = buffer(5, count * voxels * 4),
            let colorOut = buffer(6, count * voxels * 4),
            let maskOut = buffer(7, count * voxels),
            let keyBuffer = buffer(8, count * 16),
            let moved = buffer(9, count * 4),
            let distReb = buffer(10, count * voxels * 4),
            let rebanded = buffer(11, count * 4)
      else { return false }

      table.withUnsafeBytes { tableBuffer.contents().copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
      let keyPointer = keyBuffer.contents().bindMemory(to: SIMD4<Int32>.self, capacity: count)
      for (n, k) in keys.enumerated() { keyPointer[n] = SIMD4(k, 0) }
      memset(moved.contents(), 0, count * 4)
      memset(rebanded.contents(), 0, count * 4)

      let distances = distIn.contents().bindMemory(to: Float.self, capacity: slots * voxels)
      let colors = colorIn.contents().bindMemory(to: SIMD4<UInt8>.self, capacity: count * voxels)
      let masks = maskIn.contents().bindMemory(to: UInt8.self, capacity: count * voxels)
      DispatchQueue.concurrentPerform(iterations: slots)
      { s in
        if s < count
        {
          let brick = writers[s]!
          brick.distance.withUnsafeBufferPointer { (distances + s * voxels).update(from: $0.baseAddress!, count: voxels) }
          brick.color.withUnsafeBufferPointer { (colors + s * voxels).update(from: $0.baseAddress!, count: voxels) }
          brick.mask.withUnsafeBufferPointer { (masks + s * voxels).update(from: $0.baseAddress!, count: voxels) }
        }
        else
        {
          readers[s - count].distance.withUnsafeBufferPointer
          {
            (distances + s * voxels).update(from: $0.baseAddress!, count: voxels)
          }
        }
      }

      let r = dab.radius
      var params = Params(center: SIMD4(dab.center, r),
                          normal: SIMD4(dab.normal, dab.strength),
                          delta: SIMD4(dab.delta, dab.strength * r * 0.055),
                          previous: SIMD4(dab.previous, dab.paints),
                          plane: SIMD4(plane, (r + band) * (r + band)),
                          paint: SIMD4<Float>(dab.color),
                          lo: SIMD4(lo, Int32(count)),
                          extent: SIMD4(extent, brushCode),
                          misc: SIMD4(band, voxel, band * 0.99, 0),
                          flags: SIMD4(Self.code(dab.falloff), dab.ignoresMask ? 1 : 0, 0, 0))

      guard let commands = queue.makeCommandBuffer(), let encoder = commands.makeComputeCommandEncoder() else { return false }
      let groups = MTLSize(width: count * voxels / Self.group, height: 1, depth: 1)
      let threads = MTLSize(width: Self.group, height: 1, depth: 1)

      encoder.setComputePipelineState(brushPipeline)
      encoder.setBytes(&params, length: MemoryLayout<Params>.stride, index: 0)
      for (i, b) in [tableBuffer, distIn, colorIn, maskIn, distOut, colorOut, maskOut, keyBuffer, moved].enumerated()
      {
        encoder.setBuffer(b, offset: 0, index: i + 1)
      }
      encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)

      if rebands
      {
        // the repair reads what the brush wrote, a serial encoder runs it once the brush is done
        encoder.setComputePipelineState(rebandPipeline)
        encoder.setBuffer(distReb, offset: 0, index: 10)
        encoder.setBuffer(rebanded, offset: 0, index: 11)
        encoder.dispatchThreadgroups(groups, threadsPerThreadgroup: threads)
      }

      encoder.endEncoding()
      commands.commit()
      commands.waitUntilCompleted()
      guard commands.status == .completed else { return false }

      // the bricks that changed take their new voxels back, each on its own core
      let edits = moved.contents().bindMemory(to: UInt32.self, capacity: count)
      let repairs = rebanded.contents().bindMemory(to: UInt32.self, capacity: count)
      let finalDistances = (rebands ? distReb : distOut).contents().bindMemory(to: Float.self, capacity: count * voxels)
      let newColors = colorOut.contents().bindMemory(to: SIMD4<UInt8>.self, capacity: count * voxels)
      let newMasks = maskOut.contents().bindMemory(to: UInt8.self, capacity: count * voxels)
      DispatchQueue.concurrentPerform(iterations: count)
      { n in
        let edited = edits[n] != 0, repaired = repairs[n] != 0
        guard edited || repaired else { return }

        let brick = writers[n]!
        brick.distance.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: finalDistances + n * voxels, count: voxels) }
        guard edited else { return }
        brick.color.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: newColors + n * voxels, count: voxels) }
        brick.mask.withUnsafeMutableBufferPointer { $0.baseAddress!.update(from: newMasks + n * voxels, count: voxels) }
      }

      // the books the processor keeps, in the same order, the brush's changes and then the repair's
      for (n, k) in keys.enumerated() where edits[n] != 0
      {
        volume.noteChange(k, UInt8(edits[n] & UInt32(SculptVolume.allFaces)))
        volume.unsettle(k)
      }

      let steps: [SIMD3<Int32>] = [SIMD3(-1, 0, 0), SIMD3(1, 0, 0), SIMD3(0, -1, 0), SIMD3(0, 1, 0), SIMD3(0, 0, -1), SIMD3(0, 0, 1)]
      for (n, k) in keys.enumerated() where repairs[n] != 0
      {
        volume.noteChange(k, UInt8(repairs[n] & UInt32(SculptVolume.allFaces)))
        writers[n]!.settled = 0
        for step in steps { volume.bricks[k &+ step]?.settled = 0 }
      }

      return true
    }
  }
}

extension Kraken.SculptCompute
{
  /// the brush kernels and band repair, each the processor's own arithmetic voxel for voxel
  static let source = """
  #include <metal_stdlib>
  using namespace metal;

  struct Params
  {
    float4 center;
    float4 normal;
    float4 delta;
    float4 previous;
    float4 plane;
    float4 paint;
    int4 lo;
    int4 extent;
    float4 misc;
    int4 flags;
  };

  // whole bricks, floor division that holds for negative grid points
  static inline int3 brickOf(int3 g)
  {
    return int3(floor(float3(g) / 8.0f));
  }

  static inline int slotOf(constant Params& P, device const int* table, int3 k)
  {
    int3 o = k - P.lo.xyz;
    if (any(o < 0) || any(o >= P.extent.xyz)) return -1;
    return table[o.x + P.extent.x * (o.y + P.extent.y * o.z)];
  }

  static inline int indexOf(int3 l)
  {
    return l.x | (l.y << 3) | (l.z << 6);
  }

  // the distance at a grid point as the dab found it
  static inline float found(constant Params& P, device const int* table, device const float* dist, int3 g)
  {
    int3 k = brickOf(g);
    int t = slotOf(P, table, k);
    if (t < 0) return t == -2 ? -P.misc.x : P.misc.x;
    return dist[t * 512 + indexOf(g - k * 8)];
  }

  static inline float blended(constant Params& P, device const int* table, device const float* dist, float3 p)
  {
    float3 q = p / P.misc.y;
    float3 f = floor(q);
    float3 t = q - f;
    int3 g = int3(f);

    float c000 = found(P, table, dist, g);
    float c100 = found(P, table, dist, g + int3(1, 0, 0));
    float c010 = found(P, table, dist, g + int3(0, 1, 0));
    float c110 = found(P, table, dist, g + int3(1, 1, 0));
    float c001 = found(P, table, dist, g + int3(0, 0, 1));
    float c101 = found(P, table, dist, g + int3(1, 0, 1));
    float c011 = found(P, table, dist, g + int3(0, 1, 1));
    float c111 = found(P, table, dist, g + int3(1, 1, 1));

    float x00 = c000 + (c100 - c000) * t.x;
    float x10 = c010 + (c110 - c010) * t.x;
    float x01 = c001 + (c101 - c001) * t.x;
    float x11 = c011 + (c111 - c011) * t.x;
    float y0 = x00 + (x10 - x00) * t.y;
    float y1 = x01 + (x11 - x01) * t.y;
    return y0 + (y1 - y0) * t.z;
  }

  static inline float falloff(int kind, float t)
  {
    if (!(t < 1.0f)) return 0.0f;
    float x = max(t, 0.0f);
    switch (kind)
    {
      case 0: return 1.0f - x * x * (3.0f - 2.0f * x);
      case 1: return sqrt(1.0f - x * x);
      case 2: return (1.0f - x) * (1.0f - x);
      case 3: return 1.0f - sqrt(x);
      case 4: return 1.0f - x;
      default: return 1.0f;
    }
  }

  static inline uint facesOf(int3 l)
  {
    uint out = 0;
    if (l.x < 2) out |= 1;
    if (l.x >= 6) out |= 2;
    if (l.y < 2) out |= 4;
    if (l.y >= 6) out |= 8;
    if (l.z < 2) out |= 16;
    if (l.z >= 6) out |= 32;
    return out;
  }

  static inline float smin(float a, float b, float k)
  {
    float h = max(k - abs(a - b), 0.0f) / k;
    return min(a, b) - h * h * k * 0.25f;
  }

  static inline uchar4 blendColor(uchar4 color, float w, float4 paint)
  {
    w = min(max(w, 0.0f), 1.0f);
    return uchar4(round(float4(color) * (1.0f - w) + paint * w));
  }

  // one voxel of one dab, the processor's kernel brush for brush
  static inline void brushVoxel(constant Params& P, device const int* table, device const float* dist, int3 g,
                                thread float& d, thread uchar4& color, thread uchar& mask)
  {
    float band = P.misc.x, voxel = P.misc.y;
    float3 p = float3(g) * voxel;
    float3 c = P.center.xyz, n = P.normal.xyz;
    float r = P.center.w, strength = P.normal.w, amount = P.delta.w, paints = P.previous.w;
    int brush = P.extent.w;

    float3 local = p - c;
    bool near = brush == 9 || length_squared(local) < P.plane.w;
    if (!near) return;

    float freely = P.flags.y != 0 ? 1.0f : 1.0f - float(mask) / 255.0f;
    float f = falloff(P.flags.x, length(local) / r) * freely;

    switch (brush)
    {
      case 0:
      {
        if (!(f > 0)) return;
        d = blended(P, table, dist, p - n * amount * f);
        if (paints > 0 && abs(d) < band) color = blendColor(color, f * paints, P.paint);
        return;
      }

      case 3:
      {
        if (!(f > 0) || !(abs(d) < band * 0.99f)) return;
        d -= amount * f;
        if (paints > 0 && abs(d) < band) color = blendColor(color, f * paints, P.paint);
        return;
      }

      case 1:
      {
        float h = dot(p - P.plane.xyz, n);
        float3 tangent = local - n * dot(local, n);
        float side = length(tangent) / r;
        float w = falloff(P.flags.x, side) * freely * max(1.0f - abs(h) / r, 0.0f);
        if (!(w > 0) || !(abs(d) < band * 0.99f)) return;
        float plane = h - abs(amount) * 1.6f * (amount < 0 ? -1.0f : 1.0f);
        float target = amount >= 0 ? min(d, plane) : max(d, plane);
        d += (target - d) * min(w * 0.6f, 1.0f);
        if (paints > 0 && abs(d) < band) color = blendColor(color, w * paints, P.paint);
        return;
      }

      case 2:
      {
        float s = length(local) - r * 0.55f;
        float w = min(abs(strength), 1.0f) * freely;
        if (!(w > 0)) return;
        float round_ = min(r * 0.35f, band * 0.9f);
        float target = strength >= 0 ? smin(d, s, round_) : -smin(-d, -s, round_);
        float next = strength >= 0 ? target : max(d, -s);
        d += (next - d) * w;
        if (paints > 0 && s < voxel * 1.5f) color = blendColor(color, w * paints, P.paint);
        return;
      }

      case 4:
      {
        if (!(f > 0)) return;
        float sum = found(P, table, dist, g + int3(1, 0, 0)) + found(P, table, dist, g - int3(1, 0, 0))
          + found(P, table, dist, g + int3(0, 1, 0)) + found(P, table, dist, g - int3(0, 1, 0))
          + found(P, table, dist, g + int3(0, 0, 1)) + found(P, table, dist, g - int3(0, 0, 1));
        d += (sum / 6.0f - d) * min(f * abs(strength), 1.0f);
        return;
      }

      case 5:
      {
        if (!(f > 0) || !(abs(d) < band * 0.99f)) return;
        float sharp = falloff(2, length(local) / r) * freely;
        float3 away = -local;
        float3 pull = (away - n * dot(away, n)) * f * 0.3f * min(abs(strength), 1.0f);
        d = blended(P, table, dist, p - pull) + amount * 0.8f * sharp;
        return;
      }

      case 6:
      {
        if (!(f > 0)) return;
        float3 away = -local;
        float3 pull = (away - n * dot(away, n)) * f * 0.35f * strength;
        d = blended(P, table, dist, p - pull);
        return;
      }

      case 7:
      case 8:
      {
        float plane = dot(p - P.plane.xyz, n);
        if (!(f > 0) || !(abs(plane) < r) || !(abs(d) < band * 0.99f || (d < 0 && plane > 0))) return;
        float target = brush == 8 ? (strength >= 0 ? max(d, plane) : min(d, plane)) : plane;
        float move = (target - d) * min(f * abs(strength) * 0.5f, 1.0f);
        d += min(max(move, -band * 0.5f), band * 0.5f);
        return;
      }

      case 9:
      {
        float3 a = P.previous.xyz, ba = c - a;
        float t = min(max(dot(p - a, ba) / max(length_squared(ba), 1e-12f), 0.0f), 1.0f);
        float s = length(p - a - ba * t) - r;
        if (!(s < band)) return;
        if (strength >= 0)
        {
          d = smin(d, s, min(r * 0.3f, band * 0.9f));
          if (s < voxel * 2) color = blendColor(color, min(1.0f - s / (voxel * 2), 1.0f) * max(paints, 0.0f), P.paint);
        }
        else
        {
          d = max(d, -s);
        }
        return;
      }

      case 10:
      {
        if (!(f > 0) || !(abs(d) < band)) return;
        color = blendColor(color, f * abs(strength), P.paint);
        return;
      }

      case 11:
      {
        if (!(abs(d) < band)) return;
        float w = falloff(P.flags.x, length(local) / r) * strength * 255.0f;
        mask = uchar(min(max(float(mask) + w, 0.0f), 255.0f));
        return;
      }

      default:
        return;
    }
  }

  kernel void sculptBrush(constant Params& P [[buffer(0)]],
                          device const int* table [[buffer(1)]],
                          device const float* distIn [[buffer(2)]],
                          device const uchar4* colorIn [[buffer(3)]],
                          device const uchar* maskIn [[buffer(4)]],
                          device float* distOut [[buffer(5)]],
                          device uchar4* colorOut [[buffer(6)]],
                          device uchar* maskOut [[buffer(7)]],
                          device const int4* keys [[buffer(8)]],
                          device atomic_uint* moved [[buffer(9)]],
                          uint id [[thread_position_in_grid]])
  {
    uint b = id / 512, i = id % 512;
    int3 l = int3(i & 7, (i >> 3) & 7, i >> 6);
    int3 g = keys[b].xyz * 8 + l;
    float band = P.misc.x;

    float d0 = distIn[b * 512 + i];
    uchar4 c0 = colorIn[b * 512 + i];
    uchar m0 = maskIn[b * 512 + i];
    float d = d0;
    uchar4 color = c0;
    uchar mask = m0;
    brushVoxel(P, table, distIn, g, d, color, mask);

    float out = max(min(d, band), -band);
    bool changed = out != d0 || any(color != c0) || mask != m0;
    distOut[b * 512 + i] = out;
    colorOut[b * 512 + i] = color;
    maskOut[b * 512 + i] = mask;

    uint faces = simd_or(changed ? (facesOf(l) | 0x80u) : 0u);
    if (simd_is_first() && faces != 0) atomic_fetch_or_explicit(&moved[b], faces, memory_order_relaxed);
  }

  // the distance at a grid point once the brush is done, the written bricks come first in the pack
  static inline float written(constant Params& P, device const int* table, device const float* distIn,
                              device const float* distOut, int3 g)
  {
    int3 k = brickOf(g);
    int t = slotOf(P, table, k);
    if (t < 0) return t == -2 ? -P.misc.x : P.misc.x;
    int i = indexOf(g - k * 8);
    return t < P.lo.w ? distOut[t * 512 + i] : distIn[t * 512 + i];
  }

  // a clamped grid point next to a moved surface takes back its distance, one voxel past its nearest neighbor
  kernel void sculptReband(constant Params& P [[buffer(0)]],
                           device const int* table [[buffer(1)]],
                           device const float* distIn [[buffer(2)]],
                           device const float* distOut [[buffer(5)]],
                           device const int4* keys [[buffer(8)]],
                           device float* distReb [[buffer(10)]],
                           device atomic_uint* rebanded [[buffer(11)]],
                           uint id [[thread_position_in_grid]])
  {
    uint b = id / 512, i = id % 512;
    int3 l = int3(i & 7, (i >> 3) & 7, i >> 6);
    int3 g = keys[b].xyz * 8 + l;
    float voxel = P.misc.y, limit = P.misc.z;

    float d = distOut[b * 512 + i];
    float out = d;
    uint faces = 0;
    if (abs(d) >= limit)
    {
      float nearest = min(min(min(abs(written(P, table, distIn, distOut, g - int3(1, 0, 0))),
                                  abs(written(P, table, distIn, distOut, g + int3(1, 0, 0)))),
                              min(abs(written(P, table, distIn, distOut, g - int3(0, 1, 0))),
                                  abs(written(P, table, distIn, distOut, g + int3(0, 1, 0))))),
                          min(abs(written(P, table, distIn, distOut, g - int3(0, 0, 1))),
                              abs(written(P, table, distIn, distOut, g + int3(0, 0, 1)))));
      float reached = nearest + voxel;
      if (reached < abs(d))
      {
        out = d < 0 ? -reached : reached;
        faces = facesOf(l) | 0x80u;
      }
    }

    distReb[b * 512 + i] = out;
    faces = simd_or(faces);
    if (simd_is_first() && faces != 0) atomic_fetch_or_explicit(&rebanded[b], faces, memory_order_relaxed);
  }
  """
}
