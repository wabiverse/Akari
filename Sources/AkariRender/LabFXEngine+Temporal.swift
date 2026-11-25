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
  /// turns the temporal resolve on for this frame
  public func setTemporal(camera: Akari.Camera, samples: Int, moving: Bool)
  {
    let viewProjection = camera.projection * camera.view
    let limit = max(samples, 1)
    let previous = temporal.prevViewProjection

    // a cut starts every history over, since reprojecting the shot before it ghosts that shot over this one until it fades
    let cut = temporal.prevView.map { cameraCut(from: $0, to: camera.view) } ?? false
    if cut
    {
      ssgi.needsReset = true
      ssr.needsReset = true
    }

    let restart = previous == nil || temporal.restart || cut

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
    temporal.prevView = camera.view
    temporal.thisFrame = true
  }

  /// whether the camera jumped between two frames rather than moved, a tenth of the scene or 15 degrees in one frame
  private func cameraCut(from before: Akari.Matrix4, to now: Akari.Matrix4) -> Bool
  {
    let a = before.inverse(), b = now.inverse()
    let eyeA = a.transform(.zero), eyeB = b.transform(.zero)
    let aheadA = simd_normalize(a.transform(SIMD3(0, 0, -1)) - eyeA)
    let aheadB = simd_normalize(b.transform(SIMD3(0, 0, -1)) - eyeB)
    let extent = sceneBounds.map { simd_length($0.max - $0.min) } ?? 1
    return simd_distance(eyeA, eyeB) > extent * 0.1 || simd_dot(aheadA, aheadB) < cos(Float.pi / 12)
  }

  /// starts every temporal accumulation over next frame so a final render frame never blends the one before
  public func resetHistory()
  {
    temporal.prevViewProjection = nil
    temporal.prevView = nil
    volumetrics.previousViewProjection = nil
    ssgi.needsReset = true
    ssr.needsReset = true
  }

  /// restarts temporal accumulation next frame but keeps this frame's camera and geometry as previous for motion
  public func restartAccumulation()
  {
    temporal.restart = true
    ssgi.needsReset = true
    ssr.needsReset = true
  }

  /// turns on screen space gi for this frame
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

  /// turns on screen space reflections for this frame
  public func setScreenSpaceReflections(maxRoughness: Float = 0.5)
  {
    let diagonal = sceneBounds.map { $0.max - $0.min } ?? SIMD3(repeating: 1)
    let distance = max((diagonal * diagonal).sum().squareRoot(), 1e-3)
    setVector(.ssr, SIMD4(maxRoughness, distance, 1, ssr.needsReset || !ssr.passesActive ? 1 : 0))

    ssr.needsReset = false
    ssr.thisFrame = true
  }
}
