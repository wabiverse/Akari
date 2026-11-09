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

extension Kraken
{
  /// The shader inputs Akari reads or writes (PxrSurface, UsdPreviewSurface, and the texture reader).
  enum ShaderInput: String, CaseIterable
  {
    case diffuseColor, diffuseGain, specularFaceColor, specularEdgeColor, specularRoughness, specularIor, presence
    case glowColor, glowGain, clearcoatFaceColor, clearcoatEdgeColor, clearcoatRoughness, bumpNormal
    case metallic, roughness, ior, opacity, opacityThreshold, emissiveColor, clearcoat, specularColor, normal
    case occlusion, displacement, useSpecularWorkflow
    case file, filename

    /// The input's name on its shader.
    var token: Tf.Token
    {
      Tf.Token(rawValue)
    }

    /// The input's attribute, its name in the `inputs:` namespace.
    var attribute: Tf.Token
    {
      Tf.Token(Tf.Token.inputs.string + rawValue)
    }

    /// Human readable label for each PxrSurface property.
    var label: String
    {
      switch self
      {
        case .diffuseColor: "Base Color"
        case .diffuseGain: "Diffuse Gain"
        case .specularFaceColor: "Specular Face"
        case .specularEdgeColor: "Specular Edge"
        case .specularIor, .ior: "IOR"
        case .glowColor, .emissiveColor: "Emission Color"
        case .glowGain: "Emission Strength"
        case .clearcoatFaceColor: "Coat Face"
        case .clearcoatEdgeColor: "Coat Edge"
        case .clearcoatRoughness: "Coat Roughness"
        case .bumpNormal, .normal: "Normal"
        case .specularRoughness, .roughness: "Roughness"
        case .opacity: "Alpha"
        case .opacityThreshold: "Alpha Clip"
        case .clearcoat: "Coat Weight"
        case .specularColor: "Specular Tint"
        case .useSpecularWorkflow: "Specular Workflow"
        default: rawValue.prefix(1).uppercased() + String(rawValue.dropFirst())
      }
    }
  }
}
