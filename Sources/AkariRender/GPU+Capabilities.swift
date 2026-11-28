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

#if canImport(Metal)
  import Metal
#endif
#if canImport(MetalFX)
  import MetalFX
#endif

public extension Akari.GPU
{
  /// what the gpu and machine running akari can do, read once so every feature takes the best path this device has
  struct Capabilities: Sendable, CustomStringConvertible
  {
    /// the block compression material textures upload with, best first
    public enum TextureCompression: String, Sendable
    {
      /// macs and apple9 gpus onward, a17 pro and m1 up
      case bc7
      /// every apple gpu, the only block format iphones before the a17 pro have
      case astc
      /// uncompressed rgba8
      case none
    }

    /// the gpu's name, with the emulated profile when one stands in for it
    public var name: String
    public var textureCompression: TextureCompression
    /// metalfx temporal and spatial scalers
    public var temporalUpscaling: Bool
    /// linear filtering of 32 bit float textures, apple9 gpus and macs only
    public var float32Filtering: Bool
    /// the machine's physical memory in bytes
    public var memory: UInt64
    /// the most views one draw amplifies to, the shadow maps render a page per view
    public var maxAmplificationViews: Int

    /// how much of the machine's memory the scene may take
    public var memoryBudget: UInt64
    {
      UInt64(Double(memory) * 0.65)
    }

    /// shadow pages of 256 squared texels the virtual shadow maps keep in each of their two pools, half a gb a pool at 2048
    public var shadowPages: Int
    {
      // ios reports a little under the marketed size, so an 8 gb phone reads as about 7.5
      memory >= 7 << 30 ? 2048 : memory >= 5 << 30 ? 1024 : 512
    }

    /// the largest side a material texture atlas grows to, each of its rgba8 layers a quarter gb at 8192
    public var atlasSide: Int
    {
      memory >= 12 << 30 ? 16384 : memory >= 6 << 30 ? 8192 : 4096
    }

    /// the largest render scale the scene buffers allocate at, a 4 gb phone cannot hold dozens of them at its native size
    public var renderScaleCeiling: Float
    {
      memory >= 5 << 30 ? .infinity : 0.67
    }

    /// what the metalfx temporal scaler holds on top of the scene, it builds a neural engine model per size
    public static let temporalUpscalingReserve: UInt64 = 2 << 30

    /// whether the temporal scaler can ever fit beside a scene on this machine, it never does on a 4 gb phone
    public var temporalUpscalingFits: Bool
    {
      temporalUpscaling && memoryBudget > Self.temporalUpscalingReserve + (1 << 30)
    }

    public var description: String
    {
      "\(name), \(textureCompression.rawValue) textures, metalfx \(temporalUpscalingFits ? "on" : temporalUpscaling ? "out of memory" : "unsupported"), \(shadowPages) shadow pages, \(memory >> 30) gb"
    }

    public init(name: String, textureCompression: TextureCompression, temporalUpscaling: Bool,
                float32Filtering: Bool, memory: UInt64, maxAmplificationViews: Int)
    {
      self.name = name
      self.textureCompression = textureCompression
      self.temporalUpscaling = temporalUpscaling
      self.float32Filtering = float32Filtering
      self.memory = memory
      self.maxAmplificationViews = maxAmplificationViews
    }

    /// this device, or the profile `AKARI_DEVICE` names so a mac can run another device's paths, `AKARI_TEXTURE_COMPRESSION` picks the block format
    public static let current: Capabilities =
    {
      let environment = ProcessInfo.processInfo.environment
      var capabilities = environment["AKARI_DEVICE"].flatMap { emulated[$0.lowercased()] } ?? detect()
      if let format = environment["AKARI_TEXTURE_COMPRESSION"].flatMap({ TextureCompression(rawValue: $0.lowercased()) })
      {
        capabilities.textureCompression = format
      }

      return capabilities
    }()

    /// devices a mac can stand in for, named by `AKARI_DEVICE`
    public static let emulated: [String: Capabilities] = [
      "iphone13": Capabilities(name: "Apple A15 GPU (emulated)", textureCompression: .astc, temporalUpscaling: true,
                               float32Filtering: false, memory: 4 << 30, maxAmplificationViews: 2),
    ]

    private static func detect() -> Capabilities
    {
      let memory = ProcessInfo.processInfo.physicalMemory
      #if canImport(Metal)
        if let device = MTLCreateSystemDefaultDevice()
        {
          var upscaling = false
          #if canImport(MetalFX)
            upscaling = MTLFXTemporalScalerDescriptor.supportsDevice(device) && MTLFXSpatialScalerDescriptor.supportsDevice(device)
          #endif
          let views = [8, 4, 2].first { device.supportsVertexAmplificationCount($0) } ?? 2
          return Capabilities(name: device.name,
                              textureCompression: device.supportsBCTextureCompression ? .bc7 : device.supportsFamily(.apple2) ? .astc : .none,
                              temporalUpscaling: upscaling,
                              float32Filtering: device.supports32BitFloatFiltering,
                              memory: memory, maxAmplificationViews: views)
        }
      #endif
      return Capabilities(name: "OpenGL", textureCompression: .none, temporalUpscaling: false, float32Filtering: true, memory: memory,
                          maxAmplificationViews: 2)
    }
  }
}
