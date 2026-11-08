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
  struct MotionBlur
  {
    var thisFrame = false
    var passesActive = true
    var samplePassesActive = true
    var tiles = SIMD2<Int>(1, 1)
    /// The camera's `shutter:open` and `shutter:close`, in frames.
    var shutter = SIMD2<Float>(0, 0)
    /// A final render splits the shutter into this many samples, each blurred over its own slice.
    var subframes = 0
    /// The USD camera's shutter while looking through one, in place of the Hydra camera's.
    var cameraOverride: SIMD2<Float>?
    /// The scene's frames a second, which the shutter is a fraction of.
    var frameRate = 24.0
    var lastFrame = 0.0
  }

  static let motionBlurPasses: [Pass] = [.motionTiles8, .motionTiles, .motionNeighbors, .motionBlur, .motionBlurApply]
  /// While a final render integrates the shutter, each sample is blurred over its own slice before the samples average.
  static let motionBlurSamplePasses: [Pass] = [.motionTilesPre8, .motionTilesPre, .motionNeighborsPre, .motionBlurPre, .motionBlurPreApply]

  /// The widest blur in output pixels, also the size of a tile of the motion search.
  static let motionBlurRadius = 96

  /// The camera's shutter, read each frame from the Hydra camera.
  public var cameraShutter: SIMD2<Float>
  {
    get { motionBlur.shutter }
    set { motionBlur.shutter = newValue }
  }

  /// The shutter of the USD camera a render or the viewport looks through, nil for a free camera.
  public var usdCameraShutter: SIMD2<Float>?
  {
    get { motionBlur.cameraOverride }
    set { motionBlur.cameraOverride = newValue }
  }

  /// The stage's frames a second, which a shutter's open and close count in.
  public var sceneFrameRate: Double
  {
    get { motionBlur.frameRate }
    set { motionBlur.frameRate = newValue }
  }

  /// While a final render integrates the shutter over `count` samples, 0 when it doesnt.
  public var motionBlurSubframes: Int
  {
    get { motionBlur.subframes }
    set { motionBlur.subframes = newValue }
  }

  func stageMotionBlurSize(width: Int, height: Int)
  {
    motionBlur.tiles = SIMD2((width + Self.motionBlurRadius - 1) / Self.motionBlurRadius,
                             (height + Self.motionBlurRadius - 1) / Self.motionBlurRadius)
    for buffer in [.motionTiles, .motionNeighbors] as [Buffer]
    {
      runtime.stageBufferSize(buffer, width: Int32(motionBlur.tiles.x), height: Int32(motionBlur.tiles.y))
    }

    runtime.stageBufferSize(.motionTiles8, width: Int32((width + 7) / 8), height: Int32((height + 7) / 8))
    runtime.stageBufferSize(.dofTiles8, width: Int32((width + 7) / 8), height: Int32((height + 7) / 8))
    for buffer in [.dofTiles, .dofNeighbors] as [Buffer]
    {
      runtime.stageBufferSize(buffer, width: Int32((width + 47) / 48), height: Int32((height + 47) / 48))
    }
  }

  /// Turns motion blur on for this frame, over the camera's shutter interval.
  public func setMotionBlur()
  {
    let shutter = motionBlur.cameraOverride ?? motionBlur.shutter
    let interval = shutter.y - shutter.x
    guard interval > 0 else { return }
    let now = ProcessInfo.processInfo.systemUptime
    let elapsed = now - motionBlur.lastFrame
    motionBlur.lastFrame = now
    // a viewport frame slower than the scene's moves further than one frame does, the shutter stays a scene frame's.
    let frames = elapsed > 0 && elapsed < 1 ? max(elapsed * motionBlur.frameRate, 1) : 1
    // each sample reaches a little past its slice, so neighbors overlap rather than leave seams.
    let scale = motionBlur.subframes > 0 ? 1.35 : interval / Float(frames)
    setVector(.motionBlur, SIMD4(scale, Float(Self.motionBlurRadius), Float(motionBlur.tiles.x), Float(motionBlur.tiles.y)))
    setVector(.motionSize, SIMD4(Float(sizes.target.width), Float(sizes.target.height), 1 / Float(max(sizes.target.width, 1)), 1 / Float(max(sizes.target.height, 1))))
    motionBlur.thisFrame = true
  }

  func syncMotionBlur()
  {
    let perSample = motionBlur.thisFrame && motionBlur.subframes > 0
    let afterward = motionBlur.thisFrame && !perSample
    if afterward != motionBlur.passesActive
    {
      setPasses(Self.motionBlurPasses, active: afterward)
      motionBlur.passesActive = afterward
    }

    if perSample != motionBlur.samplePassesActive
    {
      setPasses(Self.motionBlurSamplePasses, active: perSample)
      motionBlur.samplePassesActive = perSample
    }

    motionBlur.thisFrame = false
  }
}
