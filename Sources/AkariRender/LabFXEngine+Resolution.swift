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
  /// a buffer size in pixels
  struct PixelSize: Equatable
  {
    var width: Int
    var height: Int
  }

  /// the sizes a frame renders at, from the target down
  struct FrameSizes
  {
    var target = PixelSize(width: 0, height: 0)

    /// the gbuffer size, the target size times `renderScale`
    var render = PixelSize(width: 0, height: 0)

    /// the half res effect buffer size, half of the smaller of the gbuffer and target
    var half = PixelSize(width: 1, height: 1)
    var supersample = PixelSize(width: 1, height: 1)

    /// the scales the scene buffers were last staged at
    var stagedRenderScale: Float = 1
    var stagedSupersampleScale: Float = 1
  }

  /// steps the render scale down when the gpu can't keep up and back up, into supersampling as allowed, once the next step fits
  struct DynamicResolution
  {
    /// the scales from `ceiling` down to `floor`, largest first
    static func scales(upTo ceiling: Float, downTo floor: Float) -> [Float]
    {
      (RenderSettings.supersamplingSteps.filter { $0 > 1 && $0 <= ceiling }.reversed() + [1, 0.85, 0.75, 0.67, 0.6, 0.5, 0.42, 0.34])
        .filter { $0 >= floor - 1e-3 }
    }

    var scales: [Float] = []
    var step = 0

    /// seconds a frame is meant to take, the glass also fits its caustics to this
    var budget: Double = 1.0 / 60.0

    /// smoothed gpu seconds per frame
    var gpuTime: Double = 0
    var overBudget: Double = 0
    var underBudget: Double = 0
    var sinceChange: Double = 0
    var lastUpdate: Double?

    /// the gpu time measured at each scale and when it was measured
    var measured: [Float: (gpuTime: Double, at: Double)] = [:]

    /// when each scale was last given up for running over budget, so it isn't tried again right away
    var leftForLoad: [Float: Double] = [:]

    /// how much finer or coarser than recorded the instances pick their levels, following shown frames toward the budget
    var geometryScale: Float = 1

    /// the scale `geometryScale` heads for in eighth octave steps so a settled frame culls the same
    var geometryTarget: Float = 1

    /// smoothed seconds between shown frames
    var frameTime: Double = 0
  }

  /// picks this frame's render scale, the supersampling ceiling while dynamic resolution is off with metalfx temporal on
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

    // instance detail follows shown frames, coarser while they come late, finer only while well early, held in between
    let frameBudget = 1 / Double(max(settings.targetFrameRate, 1))
    res.budget = frameBudget

    if dt > 0, dt < 0.25
    {
      res.frameTime = res.frameTime == 0 ? dt : res.frameTime + (dt - res.frameTime) * 0.1
    }

    if res.frameTime > 0
    {
      let frame = Float(min(dt, 0.033))

      // a display synced frame is never early, so on time with the gpu well under budget counts as room too
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

    // metalfx upscales up to 3x and the rest up to 2x, following only the chosen upscaler so pauses don't rebuild its scaler
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

    // shadows, probes and the metalfx output cost the same at any scale, so only half the frame follows the pixel count
    func predicted(_ step: Int) -> Double
    {
      if let known = res.measured[scales[step]], now - known.at < 30 { return known.gpuTime }
      let ratio = Double(scales[step] / scales[res.step])
      return res.gpuTime * (0.5 + 0.5 * ratio * ratio)
    }

    // every change rebuilds buffers and restarts the temporal effects, so the scale only moves after sustained misses with a wide band and a cooldown
    res.overBudget = res.gpuTime > budget * 0.98 ? res.overBudget + dt : 0
    let finer = res.step - 1
    let finerFits = finer >= 0 && predicted(finer) < budget * 0.75
      && !(res.leftForLoad[scales[finer]].map { now - $0 < 15 } ?? false)
    res.underBudget = finerFits ? res.underBudget + dt : 0

    var next = res.step
    if res.overBudget > 1, res.sinceChange > 1, res.step < scales.count - 1
    {
      next = (res.step + 1 ..< scales.count).first { predicted($0) < budget * 0.85 } ?? scales.count - 1
      res.leftForLoad[scales[res.step]] = now
    }
    else if res.underBudget > 3, res.sinceChange > 4
    {
      next = finer
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
