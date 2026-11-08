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

import CxxStdlib
import Foundation
import HdAkari
import HydraKit
import simd

extension AkariDemo
{
  /// The layout workspace's scene edits, each aimed where ``Authoring`` routes it.
  enum SceneEdit
  {
    /// What a widget draws, the camera or light its prim is.
    enum WidgetKind
    {
      case camera
      case distantLight
      case sphereLight
      case spotLight
      case rectLight
      case diskLight
      case domeLight
      case cylinderLight
      case other

      /// Lights the viewport shows aim and size handles for.
      var hasLightHandles: Bool
      {
        switch self
        {
          case .distantLight, .sphereLight, .spotLight, .rectLight, .diskLight: true
          default: false
        }
      }

      /// Widgets drawn without their transform's scale.
      var ignoresScale: Bool
      {
        switch self
        {
          case .camera, .distantLight, .sphereLight, .spotLight: true
          default: false
        }
      }
    }

    struct Object
    {
      var path = ""
      var kind = WidgetKind.other
      var world: [Double] = []
      var center: [Double] = []
      var size = 0.0
      var size2 = 0.0
      var angle = 0.0
      var focalLength = 0.0
      var horizontalAperture = 0.0
      var verticalAperture = 0.0
    }

    struct Mesh
    {
      var valid = false
      var points: [Float] = []
      var counts: [Int32] = []
      var indices: [Int32] = []
    }

    struct Attribute
    {
      var name = Tf.Token()
      var isColor = false
      var value = ""
      var components = 0
      var values: [Double] = [0, 0, 0]
      var texture = ""
      /// Its shader definition's label and page, a nested page after a colon.
      var label = ""
      var page = ""
      var options: [Option] = []
      var checkbox = false
    }

    struct Option: Equatable, CustomStringConvertible
    {
      var label: String
      var value: Double

      var description: String { label }
    }

    struct Prim
    {
      var valid = false
      var typeName = Tf.Token()
      var kind = ""
      var camera = false
      var light = false
      var purpose = Tf.Token.default_
      var projection = Tf.Token.perspective
      var active = true
      var instanceable = false
      var visible = true
      var geometry = false
      var attributes: [Attribute] = []
      var material = ""
      var shader = ""
      var inputs: [Attribute] = []
      var route = ""
      var materialRoute = ""
    }
  }
}
