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
import HdAkari
import LabGL

extension Akari.LabFXEngine
{
  /// Bloom with the lens's streaks and ghosts, and depth of field, over the resolved HDR color.
  struct Post
  {
    var lens: Pixar.HdAkariCameraLens?
    var viewportLens = Pixar.HdAkariCameraLens()
    var focusObjectDistance: Double?
    var bloomThisFrame = false
    var lensThisFrame = false
    var dofThisFrame = false
    var bloomActive = true
    var lensActive = true
    var dofActive = true
  }

  static let bloomPasses = (0 ..< 6).map { "bloom down \($0)" } + (0 ..< 5).map { "bloom up \($0)" } + ["bloom composite"]
  static let lensPasses = ["lens streak", "lens streak wide", "lens streak long", "lens ghosts"]
  static let dofPasses = ["depth of field depth", "depth of field tiles 8", "depth of field tiles", "depth of field neighbors", "depth of field downsample", "depth of field half", "depth of field", "depth of field apply"]

  /// The lens of the USD camera a render or the viewport looks through, nil for a free camera.
  public var usdCameraLens: Pixar.HdAkariCameraLens?
  {
    get { post.lens }
    set { post.lens = newValue }
  }

  /// The free view's focal length and aperture, its depth of field focusing as `settings` say.
  public var viewportLens: Pixar.HdAkariCameraLens
  {
    get { post.viewportLens }
    set { post.viewportLens = newValue }
  }

  /// The view's distance to its focus object this frame, in scene units, nil without one.
  public var focusObjectDistance: Double?
  {
    get { post.focusObjectDistance }
    set { post.focusObjectDistance = newValue }
  }

  /// Turns bloom on for this frame, the camera's `akari:bloom`, `akari:streak` and `akari:flare` as `settings` scale them.
  public func setBloom(_ settings: BloomSettings)
  {
    let lens = post.lens ?? Pixar.HdAkariCameraLens()
    let strength = Float(lens.bloom) * settings.strength
    let streaks = Float(lens.streak) + settings.streaks
    let ghosts = Float(lens.flare) + settings.ghosts
    setVector("u_bloom", SIMD4(strength, streaks, ghosts, 0))
    setVector("u_bloomFilter", SIMD4(settings.threshold, settings.smoothness, settings.maximum > 0 ? settings.maximum : 60000, 0))
    setVector("u_bloomTint", SIMD4(settings.tint, settings.saturation))
    post.bloomThisFrame = strength > 0 || streaks > 0 || ghosts > 0
    post.lensThisFrame = streaks > 0 || ghosts > 0
  }

  /// Turns depth of field on for this frame when the lens has an `fStop` and a `focusDistance`,
  /// the USD camera's unless `settings` override it, the free view's from `settings`. Unless
  /// `exact`, the half resolution gather takes a quarter of the taps.
  public func setDepthOfField(width: Int, exact: Bool, settings: DepthOfFieldSettings)
  {
    var lens = post.lens ?? post.viewportLens
    if settings.overridesCamera || post.lens == nil
    {
      lens.fStop = Double(settings.fStop)
      lens.focusDistance = post.focusObjectDistance ?? Double(settings.focusDistance) / Double(stageMetersPerUnit)
    }
    guard lens.fStop > 0, lens.focusDistance > 0, lens.horizontalAperture > 0 else { return }
    let f = lens.focalLength
    let focus = lens.focusDistance * Double(stageMetersPerUnit) * 1000
    guard focus > f else { return }
    let coc = f * f / (lens.fStop * (focus - f)) / lens.horizontalAperture * Double(width)
    let maxRadius = min(Double(settings.maxSize) * Double(width) / 1920, 48)
    setVector("u_dof", SIMD4(Float(coc), Float(lens.focusDistance), Float(max(maxRadius, 4)), geometry.transparent.isEmpty ? 0 : 1))
    setVector("u_dofSampling", SIMD4(exact ? 0.375 : 1.5, 0, 0, 0))
    post.dofThisFrame = true
  }

  func syncPost()
  {
    if post.bloomThisFrame != post.bloomActive
    {
      setPasses(Self.bloomPasses, active: post.bloomThisFrame)
      post.bloomActive = post.bloomThisFrame
    }
    if post.lensThisFrame != post.lensActive
    {
      setPasses(Self.lensPasses, active: post.lensThisFrame)
      post.lensActive = post.lensThisFrame
    }
    if post.dofThisFrame != post.dofActive
    {
      setPasses(Self.dofPasses, active: post.dofThisFrame)
      post.dofActive = post.dofThisFrame
    }
    post.bloomThisFrame = false
    post.lensThisFrame = false
    post.dofThisFrame = false
  }
}
