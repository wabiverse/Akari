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

/// The view transform applied in the tonemap pass.
/// Every tonemap LabGL ships (`GL_TONEMAP_*`) is
/// exposed so it can be selected from the UI and
/// driven through the tonemap pass.
public enum ViewTransform: String, Sendable, CaseIterable
{
  /// Akari's modern default (same as Blender's EEVEE).
  case agx

  /// The older filmic transform (ACES fitted curve by Narkowicz).
  case filmic

  /// ACES 1.x RRT+ODT.
  case aces

  /// Khronos PBR Neutral (for material accuracy over a cinematic look).
  case khronosPBRNeutral

  /// ACES 1.x RRT variant fitted by John Hable's colleague (Guy).
  case acesGuy

  /// ACES fitted curve by Stephen Hill.
  case acesHill

  /// Aldridge's filmic tone curve.
  case aldridge

  /// Hard clamp to [0, 1].
  case clamping

  /// "Day" photographic operator.
  case day

  /// Drago's logarithmic mapping.
  case drago

  /// Durand–Dorsey contrast-preserving operator.
  case durandDorsey

  /// Exponential exposure curve.
  case exponential

  /// Pure exponentiation curve.
  case exponentiation

  /// Ferwerda's tone mapping.
  case ferwerda

  /// Pure gamma curve.
  case gamma

  /// Hable's filmic curve (Uncharted 2).
  case hable

  /// Hable's updated (linear-gamma) fit.
  case hableUpdated

  /// Hejl–Burgess–Dawson filmic fit.
  case hejlBurgessDawson

  /// Logarithmic exposure curve.
  case logarithmic

  /// Lottes' filmic curve.
  case lottes

  /// Reinhard division by max component.
  case maxdivision

  /// Reinhard division by mean value.
  case meanvalue

  /// Classic Reinhard operator.
  case reinhard

  /// Reinhard extended with a white-point curve (Devlin).
  case reinhardDevlin

  /// Reinhard extended, brightness-aware variant.
  case reinhardExtended

  /// Schlick's rational approximation.
  case schlick

  /// Tumblin–Rushmeier operator.
  case tumblinRushmeier

  /// Uchimura's tone curve.
  case uchimura

  /// Ward's scale-preserving operator.
  case ward

  /// sRGB with no tone curve (same as Storm's default).
  case sRGB
}

public extension ViewTransform
{
  /// The tonemap switch value for use in shaders.
  var uniform: Int32
  {
    switch self
    {
      case .agx: GL_TONEMAP_AGX
      case .filmic: GL_TONEMAP_ACES_NARKOWICZ
      case .aces: GL_TONEMAP_ACES
      case .khronosPBRNeutral: GL_TONEMAP_KHRONOS_NEUTRAL
      case .acesGuy: GL_TONEMAP_ACES_GUY
      case .acesHill: GL_TONEMAP_ACES_HILL
      case .aldridge: GL_TONEMAP_ALDRIDGE
      case .clamping: GL_TONEMAP_CLAMPING
      case .day: GL_TONEMAP_DAY
      case .drago: GL_TONEMAP_DRAGO
      case .durandDorsey: GL_TONEMAP_DURAND_DORSEY
      case .exponential: GL_TONEMAP_EXPONENTIAL
      case .exponentiation: GL_TONEMAP_EXPONENTIATION
      case .ferwerda: GL_TONEMAP_FERWERDA
      case .gamma: GL_TONEMAP_GAMMA
      case .hable: GL_TONEMAP_HABLE
      case .hableUpdated: GL_TONEMAP_HABLE_UPDATED
      case .hejlBurgessDawson: GL_TONEMAP_HEJL_BURGESS_DAWSON
      case .logarithmic: GL_TONEMAP_LOGARITHMIC
      case .lottes: GL_TONEMAP_LOTTES
      case .maxdivision: GL_TONEMAP_MAXDIVISION
      case .meanvalue: GL_TONEMAP_MEANVALUE
      case .reinhard: GL_TONEMAP_REINHARD
      case .reinhardDevlin: GL_TONEMAP_REINHARD_DEVLIN
      case .reinhardExtended: GL_TONEMAP_REINHARD_EXTENDED
      case .schlick: GL_TONEMAP_SCHLICK
      case .tumblinRushmeier: GL_TONEMAP_TUMBLIN_RUSHMEIER
      case .uchimura: GL_TONEMAP_UCHIMURA
      case .ward: GL_TONEMAP_WARD
      case .sRGB: GL_TONEMAP_SRGB
    }
  }
}

extension ViewTransform: CustomStringConvertible
{
  /// Display label for UI (pickers, HUD).
  public var description: String
  {
    switch self
    {
      case .agx: "AgX"
      case .filmic: "Filmic"
      case .aces: "ACES"
      case .khronosPBRNeutral: "PBR Neutral"
      case .sRGB: "Standard (sRGB)"
      case .acesGuy: "ACES Guy"
      case .acesHill: "ACES Hill"
      case .aldridge: "Aldridge"
      case .clamping: "Clamping"
      case .day: "Day"
      case .drago: "Drago"
      case .durandDorsey: "Durand–Dorsey"
      case .exponential: "Exponential"
      case .exponentiation: "Exponentiation"
      case .ferwerda: "Ferwerda"
      case .gamma: "Gamma"
      case .hable: "Hable"
      case .hableUpdated: "Hable Updated"
      case .hejlBurgessDawson: "Hejl–Burgess–Dawson"
      case .logarithmic: "Logarithmic"
      case .lottes: "Lottes"
      case .maxdivision: "Max Division"
      case .meanvalue: "Mean Value"
      case .reinhard: "Reinhard"
      case .reinhardDevlin: "Reinhard Devlin"
      case .reinhardExtended: "Reinhard Extended"
      case .schlick: "Schlick"
      case .tumblinRushmeier: "Tumblin–Rushmeier"
      case .uchimura: "Uchimura"
      case .ward: "Ward"
    }
  }
}

/// Scene exposure and display mapping applied before/at the view transform.
public struct ColorPipeline: Sendable
{
  /// The display view transform.
  public var viewTransform: ViewTransform = .agx
  {
    didSet
    {
      // prevent redundant state changes.
      guard viewTransform != oldValue else { return }
        
      // set the active tonemap on change.
      gl.tonemap(GLenum(viewTransform.uniform))
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

  public init(viewTransform: ViewTransform,
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
