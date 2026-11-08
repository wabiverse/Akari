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

extension Akari
{
  /// Uniforms the compute and depth kernels declare, `index` naming one of a numbered family.
  enum ComputeUniform: String, CaseIterable
  {
    case alphaTest = "u_alphaTest"
    case boxCount = "u_boxCount"
    case budget = "u_budget"
    case cameraWorld = "u_cameraWorld"
    case casterCount = "u_casterCount"
    case count
    case d
    case dgrid
    case directionalRefOffset = "u_directionalRefOffset"
    case dirty = "u_dirty"
    case dst = "u_dst"
    case eyeToFitEye = "u_eyeToFitEye"
    case eyeToLightRotation = "u_eyeToLightRotation"
    case grid
    case gridMax = "u_gridMax"
    case gridMin = "u_gridMin"
    case gridSize = "u_gridSize"
    case invProj = "u_invProj"
    case invView = "u_invView"
    case l
    case layer
    case lightColor = "u_lightColor"
    case lightCount = "u_lightCount"
    case lightLodBias = "u_lightLodBias"
    case lightPos = "u_lightPos"
    case lightPosRadius = "u_lightPosRadius"
    case lightX = "u_lightX"
    case lightY = "u_lightY"
    case lightZ = "u_lightZ"
    case lodRange = "u_lodRange"
    case maxViewPerTilemap = "u_max_view_per_tilemap"
    case mode = "u_mode"
    case noise
    case origin
    case params = "u_params"
    case screen = "u_screen"
    case sim
    case sky = "u_sky"
    case slotCount = "u_slotCount"
    case src = "u_src"
    case step
    case sun = "u_sun"
    case sunColor = "u_sunColor"
    case sunMap = "u_sunMap"
    case sunMatrix = "u_sunMatrix"
    case value = "u_value"
    case vgrid
    case viewBase = "u_viewBase"
    case viewProj = "u_viewProj"
    case volume = "u_volume"
    case wind

    func name(_ index: Int? = nil) -> String
    {
      index.map { rawValue + String($0) } ?? rawValue
    }
  }
}

extension gl
{
  static func setShaderUniform(_ shader: GLuint, _ uniform: Akari.ComputeUniform, _ value: some UniformValue)
  {
    withUnsafeBytes(of: value)
    {
      setShaderUniform(shader, name: uniform.name(), type: type(of: value).glType, data: $0.baseAddress)
    }
  }
}
