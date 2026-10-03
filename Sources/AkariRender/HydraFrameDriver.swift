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
import CNanocolor
import Foundation
import HydraKit
import OpenUSDKit

public extension Akari
{
  protocol HydraFrameDriver: Hydra.FrameDelegate
  {
    func snapshot() -> Akari.RenderStats
  }

  final class FrameDriver: HydraFrameDriver
  {
    /// the active usd stage.
    public let stage: UsdStage

    /// weak: the app owns the hydra render engine.
    public weak var engine: Hydra.RenderEngine?
    public weak var akari: Akari.RenderEngine?

    /// Start of the current one second average, and the frames pulled in it.
    private var windowStart: CFAbsoluteTime = 0
    private var windowFrames = 0

    private let statsLock = NSLock()
    private var stats = Akari.RenderStats()

    /// Hydra's selection the outline labels were last built for.
    private var selectionKey: SelectionKey?
    private var selectionLabels: (labels: [Int32], all: Bool)?

    private struct SelectionKey: Equatable
    {
      var primId: Int32
      var groupVersion: Int?
      var modelsVersion: Int?
    }

    public init(stage: UsdStage, hydra: Hydra.RenderEngine, akari: Akari.RenderEngine)
    {
      self.stage = stage
      engine = hydra
      self.akari = akari

      engine?.frameDelegate = self
      // akari outlines the selection in its own graph.
      engine?.drawsSelectionOutline = false
    }

    public func snapshot() -> Akari.RenderStats
    {
      statsLock.lock()
      defer { statsLock.unlock() }
      return stats
    }

    public func hydraWillPull(deltaTime: Double)
    {
      let pullStart = CFAbsoluteTimeGetCurrent()
      if windowStart == 0 { windowStart = pullStart }
      else { windowFrames += 1 }

      let elapsed = pullStart - windowStart
      if elapsed >= 1, windowFrames > 0
      {
        statsLock.lock()
        stats.frameMilliseconds = elapsed * 1000.0 / Double(windowFrames)
        statsLock.unlock()
        windowStart = pullStart
        windowFrames = 0
      }

      advanceTime(by: deltaTime)
      syncSelection()
    }

    public func hydraDidPull()
    {}

    /// Hands Hydra's selection to Akari's outline,
    /// rebuilding the labels only when it changed.
    private func syncSelection()
    {
      guard let engine, let akari else { return }

      let key = SelectionKey(primId: engine.selectedPrimId,
                             groupVersion: engine.selectionUsesGroup ? engine.selectionGroupVersion : nil,
                             modelsVersion: engine.selectionSelectAll ? engine.selectionModelLUTVersion : nil)
      if key != selectionKey
      {
        selectionKey = key
        if engine.selectionSelectAll
        {
          // model ids are hashes, renumber them so each stays exact as a float.
          var numbers: [Int32: Int32] = [:]
          let labels = engine.selectionModelLUT.map
          { model in
            if let number = numbers[model] { return number }
            let number = Int32(numbers.count + 1)
            numbers[model] = number
            return number
          }
          selectionLabels = (labels, true)
        }
        else if engine.selectionUsesGroup
        {
          selectionLabels = (engine.selectionGroup, false)
        }
        else if engine.selectedPrimId >= 0
        {
          var labels = [Int32](repeating: 0, count: Int(engine.selectedPrimId) + 1)
          labels[Int(engine.selectedPrimId)] = 1
          selectionLabels = (labels, false)
        }
        else
        {
          selectionLabels = nil
        }
      }

      // display sRGB in, akari composites before hydra's color correction.
      let c = engine.selectionOutlineColor
      let rgb = nc_ref_TransformColor(nc_ref_GetNamedColorSpace("lin_rec709_scene"),
                                      nc_ref_GetNamedColorSpace("srgb_rec709_scene"),
                                      nc_ref_RGB(r: c[0], g: c[1], b: c[2]))
      let color = SIMD4(rgb.r, rgb.g, rgb.b, c[3])
      akari.selection = selectionLabels.map
      {
        Akari.Selection(labels: $0.labels, all: $0.all, color: color, width: engine.selectionOutlineWidth)
      }
    }

    /// Loops the stage's animation, held while the light probes bake.
    private func advanceTime(by deltaTime: Double)
    {
      guard
        stage.HasAuthoredTimeCodeRange(),
        let engine,
        let akari
      else { return }

      if akari.settings.features.contains(.lightProbes), !akari.labfx.lightProbes.isReady { return }

      let start = stage.getStartTimeCode()
      let end = stage.GetEndTimeCode()
      let range = end - start
      guard range > 0 else { return }

      let step = min(max(deltaTime, 1.0 / 240.0), 1.0 / 20.0) * stage.GetTimeCodesPerSecond()
      var next = engine.currentTimeCode + step
      if next > end
      {
        next = start + (next - start).truncatingRemainder(dividingBy: range)
      }
      engine.currentTimeCode = next
    }
  }
}
