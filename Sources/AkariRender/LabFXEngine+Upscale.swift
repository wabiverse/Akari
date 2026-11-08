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
import LabFX
import LabGL

extension Akari.LabFXEngine
{
  /// How the scene reaches the target's size, and what the MetalFX callback reads.
  struct Upscale
  {
    var mode = UpscaleMode.taa
    /// The textures the upscale callback reads, looked up before the graph runs.
    var textures = UpscaleTextures()
    var registered = false
    /// MetalFX turned an upscale down, the TAA pass takes over.
    var failed = false
    /// MetalFX's temporal scaler waits out a heavy frame or memory pressure on the TAA pass until then.
    var neuralHeldUntil = Date.distantPast
    /// The capture rebuilds `prepareUpscale` last saw.
    var rebuilds = 0
    /// MetalFX didn't run last frame, its history is from before the TAA pass took over.
    var stale = true
  }

  /// What brings this frame's scene up to the target.
  enum UpscaleMode
  {
    /// The `taa` pass, which also downsamples a supersampled frame.
    case taa
    case temporal
    case spatial
    /// MetalFX temporal up to `supersampleScale`, then the `downsample` pass.
    case supersample
  }

  struct UpscaleTextures
  {
    var color: GLuint = 0
    var depth: GLuint = 0
    var velocity: GLuint = 0
    var output: GLuint = 0
  }

  /// Picks this frame's upscaler and turns its pass on.
  func configureUpscale(settings: RenderSettings, width: Int, height: Int)
  {
    if !upscaling.registered
    {
      runtime.setPassCallback(.metalfxUpscale, callback: akariUpscaleCallback,
                              userdata: Unmanaged.passUnretained(self).toOpaque())
      upscaling.registered = true
    }

    // metalfx can't build its scaler for a frame as small as hydra's 1x1 populate pass.
    let tiny = min(width, height) < 64
    upscaling.mode = if settings.upscaler != .metalFX || renderScale > 1 || tiny || upscaling.failed || motionBlur.subframes > 0
      || labgl.upscaleSupported() == 0 || (settings.features.contains(.temporalAA) && !neuralUpscaleSafe)
    {
      .taa
    }
    else if settings.features.contains(.temporalAA)
    {
      supersampleScale > 1 ? .supersample : .temporal
    }
    else
    {
      renderScale < 1 ? .spatial : .taa
    }

    setUpscalePasses()
  }

  private func setUpscalePasses()
  {
    runtime.setPassActive(.taa, active: upscaling.mode == .taa)
    runtime.setPassActive(.upscale, active: upscaling.mode == .temporal || upscaling.mode == .spatial)
    runtime.setPassActive(.upscaleSupersample, active: upscaling.mode == .supersample)
    runtime.setPassActive(.downsample, active: upscaling.mode == .supersample)
    runtime.setPassActive(.upscaleSanitize, active: upscaling.mode != .taa)
  }

  /// Whether MetalFX's temporal scaler may run this frame.
  var neuralUpscaleSafe: Bool
  {
    var pressure: Int32 = 0
    var size = MemoryLayout<Int32>.size
    let pressured = sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &size, nil, 0) == 0 && pressure > 1
    if pressured || labgl.lastFrameGPUTime() > 0.25
    {
      upscaling.neuralHeldUntil = Date(timeIntervalSinceNow: 2)
    }
    // judged once the scene's geometry has settled, a load still syncing would let it in and keep it.
    return Date() >= upscaling.neuralHeldUntil
      && (upscaling.mode != .taa || geometry.record.triangles > 0 && Date().timeIntervalSince(geometry.record.rebuiltAt) > 5
        && Self.footprint() + (2 << 30) < Self.memoryBudget)
  }

  /// What the scene may take of the machine's memory.
  static var memoryBudget: UInt64
  {
    UInt64(Double(ProcessInfo.processInfo.physicalMemory) * 0.65)
  }

  /// The process's physical footprint, what the system counts against it.
  static func footprint() -> UInt64
  {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info)
    {
      $0.withMemoryRebound(to: integer_t.self, capacity: Int(count))
      {
        task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
      }
    }

    return result == KERN_SUCCESS ? info.phys_footprint : 0
  }

  /// The callback runs inside `runtime.render()`, so it can't look the textures up itself.
  func prepareUpscale()
  {
    // rebuilding the captures makes the heaviest frame there is.
    if geometry.record.rebuilds != upscaling.rebuilds
    {
      upscaling.rebuilds = geometry.record.rebuilds
      upscaling.neuralHeldUntil = Date(timeIntervalSinceNow: 2)
      if upscaling.mode == .temporal || upscaling.mode == .supersample
      {
        upscaling.mode = .taa
        setUpscalePasses()
      }
    }

    guard upscaling.mode != .taa else { upscaling.stale = true; return }
    upscaling.textures = UpscaleTextures(color: runtime.texture(.upscaleInput, named: .upscaleColor),
                                      depth: runtime.bufferDepth(.gbuffer),
                                      velocity: runtime.texture(.upscaleInput, named: .upscaleVelocity),
                                      output: upscaling.mode == .supersample
                                        ? runtime.writeTexture(.supersample, named: .supersample)
                                        : runtime.writeTexture(.taa, named: .final))
  }

  fileprivate func upscale()
  {
    let color = upscaling.textures.color
    let output = upscaling.textures.output
    switch upscaling.mode
    {
      case .temporal, .supersample:
        // labgl's targets keep gl's bottom up rows, so MetalFX's pixels run up like the uv.
        upscaling.failed = labgl.upscaleTemporal(color: color,
                                              depth: upscaling.textures.depth,
                                              motion: upscaling.textures.velocity,
                                              output: output,
                                              jitterX: taaJitter.x,
                                              jitterY: taaJitter.y,
                                              motionScaleX: Float(sizes.render.width),
                                              motionScaleY: Float(sizes.render.height),
                                              reversedDepth: 1,
                                              reset: temporalReset || upscaling.stale ? 1 : 0) == 0
        upscaling.stale = false
      case .spatial:
        upscaling.failed = labgl.upscaleSpatial(color: color, output: output) == 0
      case .taa:
        break
    }
  }
}

/// `Runtime.setPassCallback` takes a plain C function pointer.
private func akariUpscaleCallback(_ userdata: UnsafeMutableRawPointer?, _: Int32, _: Int32)
{
  guard let userdata else { return }
  Unmanaged<Akari.LabFXEngine>.fromOpaque(userdata).takeUnretainedValue().upscale()
}
