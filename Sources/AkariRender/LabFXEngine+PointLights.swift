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
import LabGL

extension Akari.LabFXEngine
{
  /// A light's Hydra path key.
  typealias LightKey = UInt64

  /// The point lights shading the view, and how their shadow maps are handed out.
  struct PointLights
  {
    /// The lights that shade, `shadowed` are the front of them.
    var lit: [Akari.Lux.PointLight] = []
    var shadowed: [Akari.Lux.PointLight] = []
    /// Each shadowed light, by the slot its shadow maps stay in.
    var slots: [LightKey] = []
    /// The shadowed lights kept at full resolution, swapped only for one lighting the view far more.
    var mains: Set<LightKey> = []
    /// The sync each main light took its place, its hold on it fading from then.
    var mainSince: [LightKey: UInt64] = [:]
    var syncs: UInt64 = 0
    /// Each shadowed light's visible, shadowed light on screen, smoothed over frames.
    var importance: [LightKey: Float] = [:]
    var positions: [LightKey: SIMD3<Float>] = [:]
    /// Lights seen moving, the ones that follow a character.
    var following: Set<LightKey> = []
    /// The lights packed for the deferred pass.
    var texture: GLuint = 0
    var onScreen = OnScreen()
  }

  /// The GPU pass measuring each shadowed light on screen, read back a few frames late.
  struct OnScreen
  {
    var kernel = Akari.ComputeKernel()
    var readback: GLuint = 0
    var boxes: [GLuint] = []
    var cursor = 0
  }
}
