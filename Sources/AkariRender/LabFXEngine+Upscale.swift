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
    if !upscaleRegistered
    {
      runtime.setPassCallback("metalfx-upscale", callback: akariUpscaleCallback,
                              userdata: Unmanaged.passUnretained(self).toOpaque())
      upscaleRegistered = true
    }

    // metalfx can't build its scaler for a frame as small as hydra's 1x1 populate pass.
    let tiny = min(width, height) < 64
    upscaleMode = if settings.upscaler != .metalFX || renderScale > 1 || tiny || upscaleFailed || motionBlur.subframes > 0
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
    runtime.setPassActive("taa", active: upscaleMode == .taa)
    runtime.setPassActive("upscale", active: upscaleMode == .temporal || upscaleMode == .spatial)
    runtime.setPassActive("upscale supersample", active: upscaleMode == .supersample)
    runtime.setPassActive("downsample", active: upscaleMode == .supersample)
    runtime.setPassActive("upscale sanitize", active: upscaleMode != .taa)
  }

  /// Whether MetalFX's temporal scaler may run this frame.
  var neuralUpscaleSafe: Bool
  {
    var pressure: Int32 = 0
    var size = MemoryLayout<Int32>.size
    let pressured = sysctlbyname("kern.memorystatus_vm_pressure_level", &pressure, &size, nil, 0) == 0 && pressure > 1
    if pressured || labgl.lastFrameGPUTime() > 0.25
    {
      neuralUpscaleHeldUntil = Date(timeIntervalSinceNow: 2)
    }
    // judged once the scene's geometry has settled, a load still syncing would let it in and keep it.
    return Date() >= neuralUpscaleHeldUntil
      && (upscaleMode != .taa || geometry.recordedTriangles > 0 && Date().timeIntervalSince(geometry.recordedAt) > 5
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
    // rerecording the scene makes the heaviest frame there is.
    if geometry.records != upscaleRecords
    {
      upscaleRecords = geometry.records
      neuralUpscaleHeldUntil = Date(timeIntervalSinceNow: 2)
      if upscaleMode == .temporal || upscaleMode == .supersample
      {
        upscaleMode = .taa
        setUpscalePasses()
      }
    }
    guard upscaleMode != .taa else { return }
    upscaleTextures = UpscaleTextures(color: runtime.texture("upscaleInput", named: "upscaleColor"),
                                      depth: runtime.bufferDepth("gbuffer"),
                                      velocity: runtime.texture("upscaleInput", named: "upscaleVelocity"),
                                      output: upscaleMode == .supersample
                                        ? runtime.writeTexture("supersample", named: "supersample")
                                        : runtime.writeTexture("taa", named: "final"))
  }

  fileprivate func upscale()
  {
    let color = upscaleTextures.color
    let output = upscaleTextures.output
    switch upscaleMode
    {
      case .temporal, .supersample:
        // the velocity runs up in uv, MetalFX wants pixels running down.
        upscaleFailed = labgl.upscaleTemporal(color: color,
                                              depth: upscaleTextures.depth,
                                              motion: upscaleTextures.velocity,
                                              output: output,
                                              jitterX: taaJitter.x,
                                              jitterY: -taaJitter.y,
                                              motionScaleX: Float(renderWidth),
                                              motionScaleY: -Float(renderHeight),
                                              reversedDepth: 1,
                                              reset: temporalReset ? 1 : 0) == 0
      case .spatial:
        upscaleFailed = labgl.upscaleSpatial(color: color, output: output) == 0
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
