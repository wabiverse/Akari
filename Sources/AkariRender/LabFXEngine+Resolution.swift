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
import LabGL

extension Akari.LabFXEngine
{
  /// A buffer size in pixels.
  struct PixelSize: Equatable
  {
    var width: Int
    var height: Int
  }

  /// The sizes a frame renders at, from the target down.
  struct FrameSizes
  {
    var target = PixelSize(width: 0, height: 0)
    /// The G-buffer's size, `renderScale` of the target's.
    var render = PixelSize(width: 0, height: 0)
    /// The half res effect buffers size, half of the smaller of the G-buffer and target.
    var half = PixelSize(width: 1, height: 1)
    var supersample = PixelSize(width: 1, height: 1)
    /// What the scene buffers were last staged at.
    var stagedRenderScale: Float = 1
    var stagedSupersampleScale: Float = 1
  }

  /// Steps the render scale down if the GPU cant keep up with the fps,
  /// and back up, into supersampling as far as it's allowed, once the
  /// next step up fits it again.
  struct DynamicResolution
  {
    /// Largest first, from `ceiling` down to `floor`.
    static func scales(upTo ceiling: Float, downTo floor: Float) -> [Float]
    {
      (RenderSettings.supersamplingSteps.filter { $0 > 1 && $0 <= ceiling }.reversed() + [1, 0.85, 0.75, 0.67, 0.6, 0.5, 0.42, 0.34])
        .filter { $0 >= floor - 1e-3 }
    }

    var scales: [Float] = []
    var step = 0

    /// Smoothed GPU seconds a frame.
    var gpuTime: Double = 0
    var overBudget: Double = 0
    var underBudget: Double = 0
    var sinceChange: Double = 0
    var lastUpdate: Double?
    /// The GPU time measured at each scale, and when.
    var measured: [Float: (gpuTime: Double, at: Double)] = [:]
    /// How much finer or coarser than the record's fitted detail the instances pick their levels at,
    /// following the frames shown toward the frame budget.
    var geometryScale: Float = 1
    /// The scale it heads for, `geometryScale` taking it in eighth octave steps so a settled frame culls the same.
    var geometryTarget: Float = 1
    /// Smoothed seconds between the frames shown.
    var frameTime: Double = 0
  }

  /// Picks this frame's render scale, the supersampling ceiling while `.dynamicResolution` is off.
  /// With MetalFX temporal on, supersampling upscales to the ceiling from at most the target instead.
  func updateRenderScale(settings: RenderSettings)
  {
    var res = dynamicResolution
    defer { dynamicResolution = res }

    let now = ProcessInfo.processInfo.systemUptime
    let dt = res.lastUpdate.map { min(now - $0, 0.25) } ?? 0
    res.lastUpdate = now

    let sample = labgl.lastFrameGPUTime()
    if sample > 0
    {
      res.gpuTime = res.gpuTime == 0 ? sample : res.gpuTime + (sample - res.gpuTime) * 0.1
    }

    // the instances' detail follows the frames the viewport shows, everything a frame costs counted:
    // coarser while they come late, finer only while they come well early, held in between so a
    // settled view stays as it is.
    let frameBudget = 1 / Double(max(settings.targetFrameRate, 1))
    if dt > 0, dt < 0.25
    {
      res.frameTime = res.frameTime == 0 ? dt : res.frameTime + (dt - res.frameTime) * 0.1
    }

    if res.frameTime > 0
    {
      let frame = Float(min(dt, 0.033))
      // a display synced frame never comes early, so on time with the GPU well under budget is room too,
      // or the slow frames of a launch would hold the detail down until something reframes it.
      let room = res.frameTime < frameBudget * 0.8
        || (res.frameTime < frameBudget * 1.1 && res.gpuTime > 0 && res.gpuTime < frameBudget * 0.6)
      let clampedStepFactor: Float = res.frameTime > frameBudget * 1.1
        ? max(Float(frameBudget / res.frameTime), 1 - 3 * frame)
        : room ? 1 + 0.5 * frame : 1
      res.geometryTarget = res.geometryTarget * clampedStepFactor

      let minFloor: Float = 0.15
      let maxHeadroom: Float = 2.0
      res.geometryTarget = min(max(res.geometryTarget, minFloor), maxHeadroom / max(geometry.instanceLOD.detail, 1e-4))

      let octave = log2(res.geometryTarget / res.geometryScale)
      if abs(octave) > 0.125
      {
        res.geometryScale = exp2((log2(res.geometryTarget) * 8).rounded() / 8)
      }
    }

    let step = RenderSettings.supersamplingStep(settings.supersampling)
    let chained = step > 1 &&
      settings.upscaler == .metalFX &&
      settings.features.contains(.temporalAA) &&
      !upscaling.failed && labgl.upscaleSupported() != 0

    supersampleScale = chained ? step : 1
    let ceiling = chained ? 1 : step
    guard settings.features.contains(.dynamicResolution)
    else
    {
      res = DynamicResolution(gpuTime: res.gpuTime, lastUpdate: now, geometryScale: res.geometryScale,
                              geometryTarget: res.geometryTarget, frameTime: res.frameTime)
      res.measured = [:]
      renderScale = ceiling
      return
    }

    // MetalFX upscales by up to 3x and everything else by up to 2x. This follows the chosen upscaler only,
    // since following MetalFX's short pauses would keep resizing the targets and rebuilding its scaler.
    let temporal = settings.upscaler == .metalFX && settings.features.contains(.temporalAA) &&
      !upscaling.failed && labgl.upscaleSupported() != 0
    let scales = DynamicResolution.scales(upTo: ceiling, downTo: temporal ? supersampleScale / 3 : max(supersampleScale / 3, 0.5))
    if scales != res.scales
    {
      res.step = scales.indices.min { abs(scales[$0] - renderScale) < abs(scales[$1] - renderScale) } ?? 0
      res.scales = scales
    }

    res.sinceChange += dt

    let budget = 1 / Double(max(settings.targetFrameRate, 1))
    if res.sinceChange > 0.5
    {
      res.measured[scales[res.step]] = (res.gpuTime, now)
    }

    // Shadows, probes and MetalFX's output pass cost the same at any scale,
    // so only half the frame is assumed to follow the pixel count.
    func predicted(_ step: Int) -> Double
    {
      if let known = res.measured[scales[step]], now - known.at < 10 { return known.gpuTime }
      let ratio = Double(scales[step] / scales[res.step])
      return res.gpuTime * (0.5 + 0.5 * ratio * ratio)
    }

    res.overBudget = res.gpuTime > budget * 0.95 ? res.overBudget + dt : 0
    res.underBudget = res.step > 0 && predicted(res.step - 1) < budget * 0.8 ? res.underBudget + dt : 0

    var next = res.step
    if res.overBudget > 0.25, res.sinceChange > 0.5, res.step < scales.count - 1
    {
      next = (res.step + 1 ..< scales.count).first { predicted($0) < budget * 0.85 } ?? scales.count - 1
    }
    else if res.underBudget > 1.5, res.sinceChange > 2
    {
      next = res.step - 1
    }

    if next != res.step
    {
      if next > res.step { res.gpuTime = predicted(next) }
      res.step = next
      res.overBudget = 0
      res.underBudget = 0
      res.sinceChange = 0
    }

    renderScale = scales[res.step]
  }
}
