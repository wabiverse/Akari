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

public extension Akari.Color
{
  /// the view transform applied in the tonemap pass.
  enum ViewTransform: String, Sendable, CaseIterable
  {
    /// akari's default transform
    case agx

    /// the older filmic transform, narkowicz's aces fit
    case filmic

    /// aces 1.x rrt+odt.
    case aces

    /// khronos pbr neutral, for material accuracy over a cinematic look
    case khronosPBRNeutral

    /// a fitted aces 1 rrt variant
    case acesGuy

    /// aces fitted curve by stephen hill.
    case acesHill

    /// aldridge's filmic tone curve.
    case aldridge

    /// hard clamp to [0, 1].
    case clamping

    /// the day photographic operator
    case day

    /// drago's logarithmic mapping.
    case drago

    /// durand and dorsey's contrast preserving operator.
    case durandDorsey

    /// exponential exposure curve.
    case exponential

    /// pure exponentiation curve.
    case exponentiation

    /// ferwerda's tone mapping.
    case ferwerda

    /// pure gamma curve.
    case gamma

    /// hable's filmic curve from uncharted 2
    case hable

    /// hable's updated linear gamma fit
    case hableUpdated

    /// hejl and burgess dawson's filmic fit.
    case hejlBurgessDawson

    /// logarithmic exposure curve.
    case logarithmic

    /// lottes' filmic curve.
    case lottes

    /// reinhard division by max component.
    case maxdivision

    /// reinhard division by mean value.
    case meanvalue

    /// classic reinhard operator.
    case reinhard

    /// reinhard extended with a white point curve, devlin's version
    case reinhardDevlin

    /// reinhard extended, brightness-aware variant.
    case reinhardExtended

    /// schlick's rational approximation.
    case schlick

    /// tumblin and rushmeier's operator.
    case tumblinRushmeier

    /// uchimura's tone curve.
    case uchimura

    /// ward's scale-preserving operator.
    case ward

    /// srgb with no tone curve, the same as storm's default
    case sRGB
  }
}

public extension Akari.Color.ViewTransform
{
  /// the tonemap switch value for use in shaders.
  var uniform: GLenum
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

extension Akari.Color.ViewTransform: CustomStringConvertible
{
  /// the label pickers and the hud show
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

public extension Akari.Color.ViewTransform
{
  /// from a view transform name, as a stage's color management carries it.
  init?(transformName: String)
  {
    switch transformName
    {
      case "AgX": self = .agx
      case "Standard": self = .clamping
      case "Filmic": self = .filmic
      case "Khronos PBR Neutral": self = .khronosPBRNeutral
      default: return nil
    }
  }
}
