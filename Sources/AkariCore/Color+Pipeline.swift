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

import Foundation
import LabGL

public extension Akari
{
  enum Color
  {
    /// Scene exposure and display mapping applied before/at the view transform.
    public struct Pipeline: Sendable
    {
      /// The display view transform.
      public var viewTransform: Akari.Color.ViewTransform = .agx
      {
        didSet
        {
          // prevent redundant state changes.
          guard viewTransform != oldValue else { return }

          // set the active tonemap on change.
          gl.tonemap(viewTransform.uniform)
        }
      }

      /// Exposure in stops (EV). 0 is neutral, +1 doubles scene luminance.
      public var exposure: Float = 0

      /// Post-transform gamma trim (rarely needed, 1.0 = untouched).
      public var gamma: Float = 1

      /// Viewport clear / background color.
      public var background: (Float, Float, Float, Float) = (0.82, 0.40, 0.12, 1)

      public init()
      {}

      public init(viewTransform: Akari.Color.ViewTransform,
                  exposure: Float,
                  gamma: Float,
                  background: (Float, Float, Float, Float))
      {
        self.viewTransform = viewTransform
        self.exposure = exposure
        self.gamma = gamma
        self.background = background
      }
    }
  }
}
