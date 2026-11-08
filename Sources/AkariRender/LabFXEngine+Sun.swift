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
  /// Call once, right after opening the usd stage.
  public func setStageUpAxis(isZUp: Bool)
  {
    stageIsZUp = isZUp
  }


  /// Call once, right after opening the usd stage.
  public func setStageMetersPerUnit(_ metersPerUnit: Double)
  {
    stageMetersPerUnit = metersPerUnit > 0 ? Float(metersPerUnit) : 1
  }

  /// Compute sun direction based on the opened usd stages's upAxis.
  func worldSpaceSunDirection(_ light: LightSettings) -> SIMD3<Float>
  {
    guard let swung = swungSun(light)
    else
    {
      if let authored = authoredSunDirection { return Akari.Math.normalize(authored) }
      let sky = light.sunDirection
      return stageIsZUp ? SIMD3(sky.x, -sky.z, sky.y) : sky
    }

    let t = Akari.Math.smoothstep(-0.3, 0.05, light.sunHeight)
    return Akari.Math.normalize(swung.moon + (swung.sun - swung.moon) * t)
  }

  /// The stage's own sun, its distant light's or its dome's.
  var authoredSunDirection: SIMD3<Float>?
  {
    environment.distantSun?.direction ?? dome?.sunDirection
  }

  private var stageUp: SIMD3<Float>
  {
    stageIsZUp ? SIMD3(0, 0, 1) : SIMD3(0, 1, 0)
  }

  /// The stage sun's bearing at Sun Height's elevation, and the moon rising opposite it.
  func swungSun(_ light: LightSettings) -> (sun: SIMD3<Float>, moon: SIMD3<Float>)?
  {
    guard light.overridesStageSun, let authored = authoredSunDirection else { return nil }
    let up = stageUp
    let level = authored - up * simd_dot(authored, up)
    let bearing = simd_length(level) > 1e-4 ? simd_normalize(level) : (stageIsZUp ? SIMD3(0, -1, 0) : SIMD3(0, 0, 1))
    let elevation = Akari.Math.radians(Akari.Math.saturate(abs(light.sunHeight) + 0.01) * 75)
    return (bearing * cos(elevation) + up * sin(elevation), -bearing * cos(elevation) + up * sin(elevation))
  }

  /// Sun Height where the stage's own sun stands, unless the HUD's sliders replace it.
  func effectiveSunHeight(_ light: LightSettings) -> Float
  {
    guard !light.overridesStageSun, let authored = authoredSunDirection else { return light.sunHeight }
    let elevation = asin(min(max(simd_dot(Akari.Math.normalize(authored), stageUp), -1), 1)) * 180 / .pi
    return min(max(elevation / 75 - 0.01, 0.01), 1)
  }

  /// The sun disk's angular diameter, the stage's distant light's or its dome's, unless the HUD's sliders replace it.
  func effectiveSunAngle(_ light: LightSettings) -> Float
  {
    guard !light.overridesStageSun else { return light.sunAngle }
    if let distantSun = environment.distantSun { return distantSun.angle }
    if let sun = dome?.sun, sun.angle > 0 { return sun.angle }
    return light.sunAngle
  }

  /// Where the stage's sun comes from, a rect light far outside the scene or the dome's file.
  enum StageSun: Equatable
  {
    case none
    case rect(LightKey)
    case dome(String)
  }

  /// Starts the HUD's sun sliders where the stage authored its sun, the first frame each stage sun shows.
  func adoptAuthoredSun()
  {
    guard let authored = authoredSunDirection else { return }
    let sun: StageSun = environment.rectSunKey.map { .rect($0) } ?? dome.map { .dome($0.file) } ?? .none
    guard sun != environment.authoredSun else { return }
    environment.authoredSun = sun
    let elevation = asin(min(max(simd_dot(authored, stageUp), -1), 1)) * 180 / .pi
    onAuthoredSun?(min(max(elevation / 75 - 0.01, 0.01), 1), environment.distantSun?.angle ?? Float(4 * Double.pi / 180))
  }
}
