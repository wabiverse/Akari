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

/// Resolves a set of ``RenderSettings`` into the
/// ordered list of passes that actually run this
/// frame, the assembled frame graph.
public struct RenderPipeline: Sendable
{
  public var settings: RenderSettings

  public init(settings: RenderSettings)
  {
    self.settings = settings
  }

  /// The passes that run for the current settings, in execution order.
  public var activePasses: [RenderPassID]
  {
    let f = settings.features

    var passes: [RenderPassID] = [.depthPrepass]

    if f.contains(.shadowMaps) { passes.append(.shadow) }

    passes.append(.geometry)

    if f.contains(.ambientOcclusion) { passes.append(.ambientOcclusion) }

    passes.append(.lighting)

    if f.contains(.screenSpaceGI) { passes.append(.screenSpaceGI) }
    // reflections run when either screen space or hardware RT is on.
    if f.contains(.screenSpaceReflections) || f.contains(.hardwareRayTracing)
    {
      passes.append(.reflections)
    }

    passes.append(.transparency)

    if f.contains(.volumetrics) { passes.append(.volumetrics) }
    if f.contains(.temporalAA) { passes.append(.temporalResolve) }
    if f.contains(.bloom) { passes.append(.bloom) }
    if f.contains(.depthOfField) { passes.append(.depthOfField) }

    // the color pipeline.
    passes.append(.tonemap)
    passes.append(.present)

    return passes
  }
}
