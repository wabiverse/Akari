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
import HydraKit
import LabFX
import LabGL
import simd

extension Akari.LabFXEngine
{
  /// Turns the temporal resolve on for this frame.
  public func setTemporal(camera: Akari.Camera, samples: Int, moving: Bool)
  {
    let viewProjection = camera.projection * camera.view
    let limit = max(samples, 1)
    let previous = temporal.prevViewProjection
    let restart = previous == nil || temporal.restart
    let now = ProcessInfo.processInfo.systemUptime
    let elapsed = max(now - temporal.lastFrame, 1e-3)
    temporal.lastFrame = now
    let moved = min(10, limit, max(2, Int(Self.movingHistorySeconds / elapsed)))
    temporal.samples = restart ? 1
      : moving && motionBlur.subframes == 0 ? moved
      : min(temporal.samples + 1, limit)

    setMatrix(.prevViewProj, previous ?? viewProjection)
    setMatrix(.currViewProj, viewProjection)
    setVector(.taa, SIMD4(1, restart ? 1 : 0, 1 / Float(temporal.samples), motionBlur.subframes > 0 ? 1 : 0))
    setVector(.taaJitter, SIMD4(taaJitter.x, taaJitter.y, 0, 0))
    temporal.reset = restart
    temporal.restart = false
    temporal.prevViewProjection = viewProjection
    temporal.thisFrame = true
  }

  /// Starts every temporal accumulation over on the next frame,
  /// so a final render frame never blends in the one before it.
  public func resetHistory()
  {
    temporal.prevViewProjection = nil
    volumetrics.previousViewProjection = nil
    ssgi.needsReset = true
    ssr.needsReset = true
  }

  /// Starts the temporal accumulation over on the next frame, keeping this frame's
  /// camera and geometry as the previous ones so the next frame still has motion.
  public func restartAccumulation()
  {
    temporal.restart = true
    ssgi.needsReset = true
    ssr.needsReset = true
  }

  /// Turns on screen space GI for this frame.
  public func setScreenSpaceGI(maxRoughness: Float = 0.5)
  {
    let diagonal = sceneBounds.map { $0.max - $0.min } ?? SIMD3(repeating: 1)
    let radius = max((diagonal * diagonal).sum().squareRoot() * 0.15, 1e-3)
    setVector(.ssgi, SIMD4(radius, radius * 0.2, 1, ssgi.needsReset || !ssgi.passesActive ? 1 : 0))

    let size = SIMD2<Float>(Float(sizes.half.width * 2), Float(sizes.half.height * 2))
    setVector(.ssgiSize, SIMD4(size.x, size.y, 1 / size.x, 1 / size.y))
    setVector(.horizonScan, SIMD4(maxRoughness, 1, 0, 0))
    ssgi.needsReset = false
    ssgi.thisFrame = true
  }

  /// Turns on screen space reflections for this frame.
  public func setScreenSpaceReflections(maxRoughness: Float = 0.5)
  {
    let diagonal = sceneBounds.map { $0.max - $0.min } ?? SIMD3(repeating: 1)
    let distance = max((diagonal * diagonal).sum().squareRoot(), 1e-3)
    setVector(.ssr, SIMD4(maxRoughness, distance, 1, ssr.needsReset || !ssr.passesActive ? 1 : 0))
    ssr.needsReset = false
    ssr.thisFrame = true
  }
}
