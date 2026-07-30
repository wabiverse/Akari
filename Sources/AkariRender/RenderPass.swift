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

/// One stage of the frame, the ordering here is the frame graph
/// itself. Each pass reads the targets earlier passes produced
/// and writes its own.
public enum RenderPassID: String, CaseIterable, Sendable
{
  /// Depth only prepass.
  case depthPrepass
  /// Shadow map(s), sun cascades + punctual/area maps.
  case shadow
  /// Opaque geometry, G-buffer (deferred) or forward+ shaded opaque.
  case geometry
  /// Ground truth ambient occlusion (GTAO).
  case ambientOcclusion
  /// Direct + image based lighting (PBR, analytic & area lights, IBL).
  case lighting
  /// Screen space global illumination (indirect diffuse bounce).
  case screenSpaceGI
  /// Screen space (and opt-in hardware RT) reflections.
  case reflections
  /// Sorted forward transparency.
  case transparency
  /// Froxel volumetrics composite.
  case volumetrics
  /// Temporal resolve / anti aliasing (also stabilizes the SS effects).
  case temporalResolve
  /// Bloom.
  case bloom
  /// Depth of field.
  case depthOfField
  /// Exposure + view transform (AgX, etc.).
  case tonemap
  /// Blit / handoff to the viewport (or an AOV for Hydra).
  case present
}
