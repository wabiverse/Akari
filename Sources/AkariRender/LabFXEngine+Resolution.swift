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
  /// Steps the render scale down if the GPU cant keep up with the fps,
  /// and back up, into supersampling as far as it's allowed, once the
  /// next step up fits it again.
  struct DynamicResolution
  {
    /// Largest first, from `ceiling` down to `floor`, at most half the target.
    static func scales(upTo ceiling: Float, downTo floor: Float) -> [Float]
    {
      (RenderSettings.supersamplingSteps.filter { $0 > 1 && $0 <= ceiling }.reversed() + [1, 0.85, 0.75, 0.67, 0.6, 0.5])
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

    let step = RenderSettings.supersamplingStep(settings.supersampling)
    let chained = step > 1 &&
      settings.upscaler == .metalFX &&
      settings.features.contains(.temporalAA) &&
      !upscaleFailed && labgl.upscaleSupported() != 0

    supersampleScale = chained ? step : 1
    let ceiling = chained ? 1 : step
    guard settings.features.contains(.dynamicResolution) else
    {
      res = DynamicResolution(lastUpdate: now)
      renderScale = ceiling
      return
    }

    // metalfx upscales by 3x at most.
    let scales = DynamicResolution.scales(upTo: ceiling, downTo: max(supersampleScale / 3, 0.5))
    if scales != res.scales
    {
      res.step = scales.indices.min { abs(scales[$0] - renderScale) < abs(scales[$1] - renderScale) } ?? 0
      res.scales = scales
    }

    let sample = labgl.lastFrameGPUTime()
    if sample > 0
    {
      res.gpuTime = res.gpuTime == 0 ? sample : res.gpuTime + (sample - res.gpuTime) * 0.1
    }
    res.sinceChange += dt

    let budget = 1 / Double(max(settings.targetFrameRate, 1))
    func predicted(_ step: Int) -> Double
    {
      let ratio = Double(scales[step] / scales[res.step])
      return res.gpuTime * ratio * ratio
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
      // the smoothed time was measured at the old scale.
      res.gpuTime = predicted(next)
      res.step = next
      res.overBudget = 0
      res.underBudget = 0
      res.sinceChange = 0
    }
    renderScale = scales[res.step]
  }
}
