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
import AkariRender
import Foundation
import HydraKit
import LatticeCore
import LatticeUSD

#if canImport(Metal)
  import LatticeMetal
  import Metal

  extension InstanceXform: @retroactive LatticeGPUComponent {}
  extension LatticeBulbMotion: LatticeGPUComponent {}
#endif

/// Per instance inputs of the mandelbulb motion field, 12 packed floats.
public struct LatticeBulbMotion: LatticeComponent, Equatable, Sendable
{
  public var dirX: Float, dirY: Float, dirZ: Float
  public var radius: Float, angle: Float, height: Float
  public var arrive: Float, spinRate: Float
  public var axisX: Float, axisY: Float, axisZ: Float
  public var size: Float
}

/// Runs a motion field over a Lattice store on the GPU, writing each frame's
/// instances into the store and straight into the buffers Akari draws a point
/// instancer's prototypes from. Hydra syncs the instancer once and is never
/// told it moved.
public final class LatticeBulbDriver: Hydra.FrameDelegate
{
  /// Retained for the process, hydra holds its frame delegate weakly.
  nonisolated(unsafe) static var shared: LatticeBulbDriver?

  public var inner: (any Hydra.FrameDelegate)?
  public var time: () -> Double = { 0 }

  private struct Prototype
  {
    var path: String
    var offset: Int
    var count: Int
    var version = 0
    #if canImport(Metal)
      var matrices: (any MTLBuffer)?
    #endif
  }

  private let store = LatticeStore()
  private var prototypes: [Prototype] = []

  #if canImport(Metal)
    private var device: (any MTLDevice)?
    private var queue: (any MTLCommandQueue)?
    private var pipeline: (any MTLComputePipelineState)?
    private var xforms: MetalBackedColumn<InstanceXform>?
    private var motions: MetalBackedColumn<LatticeBulbMotion>?
  #endif

  /// Claims the prototypes, so it has to run before the hydra engine is made.
  public init?(motionFile: String)
  {
    guard let data = FileManager.default.contents(atPath: motionFile),
          data.count % MemoryLayout<LatticeBulbMotion>.stride == 0,
          let ranges = (try? JSONSerialization.jsonObject(with: Data(contentsOf: URL(filePath: (motionFile as NSString).deletingPathExtension + ".json")))) as? [[String: Any]]
    else
    {
      print("[lattice] unreadable motion \(motionFile)")
      return nil
    }
    prototypes = ranges.compactMap
    {
      guard let path = $0["path"] as? String, let offset = $0["offset"] as? Int, let count = $0["count"] as? Int else { return nil }
      return Prototype(path: path, offset: offset, count: count)
    }
    let rows: [LatticeBulbMotion] = data.withUnsafeBytes { Array($0.bindMemory(to: LatticeBulbMotion.self)) }

    #if canImport(Metal)
      guard let device = MTLCreateSystemDefaultDevice() else { return nil }
      self.device = device
      store.register(InstanceXform.self) { MetalBackedColumn<InstanceXform>(device: device, initialCapacity: rows.count) }
      store.register(LatticeBulbMotion.self) { MetalBackedColumn<LatticeBulbMotion>(device: device, initialCapacity: rows.count) }
      for row in rows
      {
        let entity = store.spawn()
        store.set(row, on: entity)
        store.set(InstanceXform(tx: 0, ty: 0, tz: 0, sx: row.size, sy: row.size, sz: row.size, rx: 0, ry: 0, rz: 0, rw: 1), on: entity)
      }
      store.query(InstanceXform.self, LatticeBulbMotion.self).forEachColumnPair
      { x, m in
        xforms = x as? MetalBackedColumn<InstanceXform>
        motions = m as? MetalBackedColumn<LatticeBulbMotion>
      }
      do
      {
        let options = MTLCompileOptions()
        options.mathMode = .fast
        let library = try device.makeLibrary(source: latticeBulbShader, options: options)
        pipeline = try library.makeFunction(name: "kBulbField").map { try device.makeComputePipelineState(function: $0) }
        queue = device.makeCommandQueue()
      }
      catch
      {
        print("[lattice] bulb kernel failed: \(error)")
        return nil
      }
    #endif

    for prototype in prototypes
    {
      Akari.LiveInstances.register(prototype: prototype.path, count: prototype.count)
    }
    print("[lattice] \(rows.count) instances over \(prototypes.count) prototypes, gpu-direct")
    Self.shared = self
  }

  public func hydraWillPull(deltaTime: Double)
  {
    #if canImport(Metal)
      if let device, let queue, let pipeline, let xforms, let motions, let commands = queue.makeCommandBuffer()
      {
        var t = Float(time())
        for i in prototypes.indices
        {
          // akari allocates the buffer when it records, and again if it records anew.
          guard let slot = Akari.LiveInstances.slot(prototypes[i].path), let base = slot.base else { continue }
          if slot.version != prototypes[i].version
          {
            prototypes[i].matrices = device.makeBuffer(bytesNoCopy: base, length: slot.count * 64,
                                                       options: .storageModeShared, deallocator: nil)
            prototypes[i].version = slot.version
          }
          guard let matrices = prototypes[i].matrices, let encoder = commands.makeComputeCommandEncoder() else { continue }
          var offset = UInt32(prototypes[i].offset)
          var count = UInt32(prototypes[i].count)
          encoder.setComputePipelineState(pipeline)
          encoder.setBuffer(xforms.metalBuffer, offset: 0, index: 0)
          encoder.setBuffer(motions.metalBuffer, offset: 0, index: 1)
          encoder.setBytes(&t, length: MemoryLayout<Float>.stride, index: 2)
          encoder.setBytes(&count, length: MemoryLayout<UInt32>.stride, index: 3)
          encoder.setBuffer(matrices, offset: 0, index: 4)
          encoder.setBytes(&offset, length: MemoryLayout<UInt32>.stride, index: 5)
          let width = min(pipeline.maxTotalThreadsPerThreadgroup, 256)
          encoder.dispatchThreadgroups(MTLSize(width: (prototypes[i].count + width - 1) / width, height: 1, depth: 1),
                                       threadsPerThreadgroup: MTLSize(width: width, height: 1, depth: 1))
          encoder.endEncoding()
        }
        commands.commit()
        commands.waitUntilCompleted()
        xforms.markWholeColumnChanged(tick: store.currentTick)
      }
    #endif
    store.advanceChangeTick()
    inner?.hydraWillPull(deltaTime: deltaTime)
  }

  public func hydraDidPull()
  {
    inner?.hydraDidPull()
  }
}

extension AppUtils
{
  /// `--lattice-motion <file>`, its prototype ranges beside it as json.
  static func latticeMotionFile() -> String?
  {
    let arguments = CommandLine.arguments
    guard let i = arguments.firstIndex(of: "--lattice-motion"), i + 1 < arguments.count else { return nil }
    return arguments[i + 1]
  }
}

let latticeBulbShader = """
  #include <metal_stdlib>
  using namespace metal;

  struct InstanceXform { float tx, ty, tz, sx, sy, sz, rx, ry, rz, rw; };
  struct BulbMotion
  {
    float dirX, dirY, dirZ, radius, angle, height, arrive, spinRate, axisX, axisY, axisZ, size;
  };

  static inline float bulbDistance(float3 c, float power)
  {
    float3 z = c;
    float dr = 1.0f;
    float r = 0.0f;
    for (int i = 0; i < 12; ++i)
    {
      r = length(z);
      if (r > 2.0f) { break; }
      const float theta = acos(clamp(z.z / max(r, 1e-6f), -1.0f, 1.0f)) * power;
      const float phi = atan2(z.y, z.x) * power;
      dr = pow(r, power - 1.0f) * power * dr + 1.0f;
      z = pow(r, power) * float3(sin(theta) * cos(phi), sin(theta) * sin(phi), cos(theta)) + c;
    }
    return 0.5f * log(max(r, 1e-6f)) * r / max(dr, 1e-6f);
  }

  // instances are row major, row vector matrices, as hydra composes them.
  kernel void kBulbField(device InstanceXform *xforms [[buffer(0)]],
                         const device BulbMotion *motions [[buffer(1)]],
                         constant float &t [[buffer(2)]],
                         constant uint &count [[buffer(3)]],
                         device float4 *matrices [[buffer(4)]],
                         constant uint &offset [[buffer(5)]],
                         uint local [[thread_position_in_grid]])
  {
    if (local >= count) { return; }
    const uint id = offset + local;
    const BulbMotion m = motions[id];
    const float3 dir = float3(m.dirX, m.dirY, m.dirZ);
    const float power = t > 3.4f ? 8.0f + 2.5f * sin((t - 3.4f) * 0.9f) : 8.0f;

    float s = 1.6f;
    for (int i = 0; i < 40; ++i)
    {
      s = max(s - max(bulbDistance(dir * s, power), 0.0015f), 0.05f);
    }
    float3 target = dir * s;
    const float a = 0.12f * t;
    target = float3(target.x * cos(a) - target.y * sin(a), target.x * sin(a) + target.y * cos(a), target.z);

    const float turn = m.angle + 1.4f / sqrt(m.radius) * t;
    const float3 disk = float3(m.radius * cos(turn), m.radius * sin(turn), m.height + 0.15f * sin(turn * 2.0f + m.radius));
    const float u = smoothstep(0.0f, 1.0f, (t - m.arrive) / 1.1f);
    const float3 p = mix(disk, target, u) + float3(0, 0, sin(u * M_PI_F) * 0.9f * m.radius / 6.0f + 1.25f);

    const float h = m.spinRate * t * (1.0f - u) * 0.5f;
    const float k = m.size * (0.55f + 0.45f * u);
    const float4 q = float4(float3(m.axisX, m.axisY, m.axisZ) * sin(h), cos(h));
    xforms[id] = InstanceXform{ p.x, p.y, p.z, k, k, k, q.x, q.y, q.z, q.w };

    const float x = q.x, y = q.y, z = q.z, w = q.w;
    matrices[local * 4 + 0] = k * float4(1 - 2 * (y * y + z * z), 2 * (x * y + z * w), 2 * (x * z - y * w), 0);
    matrices[local * 4 + 1] = k * float4(2 * (x * y - z * w), 1 - 2 * (x * x + z * z), 2 * (y * z + x * w), 0);
    matrices[local * 4 + 2] = k * float4(2 * (x * z + y * w), 2 * (y * z - x * w), 1 - 2 * (x * x + y * y), 0);
    matrices[local * 4 + 3] = float4(p, 1);
  }
  """
