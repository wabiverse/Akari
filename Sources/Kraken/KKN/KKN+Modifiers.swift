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
  /// a mesh's modifier stack as akari attributes, saved with the shot while its result lives in the session layer over the cage
  enum Modifiers
  {
    /// the modifiers a mesh can carry, in the order the add menu lists them
    enum Kind: String, CaseIterable, Sendable
    {
      case subdivision, mirror, array, solidify, weld, smooth, triangulate

      var title: String
      {
        switch self
        {
          case .subdivision: "Subdivision"
          case .mirror: "Mirror"
          case .array: "Array"
          case .solidify: "Solidify"
          case .weld: "Weld"
          case .smooth: "Smooth"
          case .triangulate: "Triangulate"
        }
      }

      /// what the panel says the modifier does, under its parameters
      var note: String
      {
        switch self
        {
          case .subdivision: "refines the whole stack last, on the gpu"
          case .mirror: "mirrors the mesh across the objects own axes"
          case .array: "repeats the mesh along an offset"
          case .solidify: "gives the surface a thickness"
          case .weld: "merges points closer together than the distance"
          case .smooth: "relaxes each point toward its neighbours"
          case .triangulate: "cuts every face into triangles"
        }
      }

      /// subdivision belongs to the renderer, so the stack leaves it alone and evaluates everything before it
      var isRefinement: Bool
      {
        self == .subdivision
      }

      var parameters: [Parameter]
      {
        switch self
        {
          case .subdivision:
            [Parameter(key: "subdivisionScheme", label: "Scheme", type: .token, absolute: true,
                       control: .choice(Modifiers.schemes.map(\.label))),
             Parameter(key: "akari:subdivision:viewportLevel", label: "Levels Viewport", type: .int, absolute: true,
                       control: .whole(0 ... 6), fallback: 1),
             Parameter(key: "akari:subdivision:renderLevel", label: "Render", type: .int, absolute: true,
                       control: .whole(0 ... 6), fallback: 2)]
          case .mirror:
            [Parameter(key: "axisX", label: "Axis X", type: .bool, control: .toggle, fallback: 1),
             Parameter(key: "axisY", label: "Y", type: .bool, control: .toggle),
             Parameter(key: "axisZ", label: "Z", type: .bool, control: .toggle),
             Parameter(key: "merge", label: "Merge", type: .bool, control: .toggle, fallback: 1),
             Parameter(key: "mergeThreshold", label: "Distance", type: .float, control: .distance(0 ... 1),
                       fallback: 0.001)]
          case .array:
            [Parameter(key: "count", label: "Count", type: .int, control: .whole(1 ... 256), fallback: 2),
             Parameter(key: "relativeOffset", label: "Relative Offset", type: .float3, control: .vector(-8 ... 8),
                       fallbacks: [1, 0, 0]),
             Parameter(key: "constantOffset", label: "Constant Offset", type: .float3, control: .vector(-100 ... 100)),
             Parameter(key: "merge", label: "Merge", type: .bool, control: .toggle, fallback: 1),
             Parameter(key: "mergeThreshold", label: "Distance", type: .float, control: .distance(0 ... 1),
                       fallback: 0.001)]
          case .solidify:
            [Parameter(key: "thickness", label: "Thickness", type: .float, control: .distance(-10 ... 10),
                       fallback: 0.01),
             Parameter(key: "offset", label: "Offset", type: .float, control: .factor(-1 ... 1), fallback: -1),
             Parameter(key: "rim", label: "Fill Rim", type: .bool, control: .toggle, fallback: 1)]
          case .weld:
            [Parameter(key: "mergeThreshold", label: "Distance", type: .float, control: .distance(0 ... 1),
                       fallback: 0.001)]
          case .smooth:
            [Parameter(key: "factor", label: "Factor", type: .float, control: .factor(0 ... 1), fallback: 0.5),
             Parameter(key: "iterations", label: "Repeat", type: .int, control: .whole(1 ... 64), fallback: 1)]
          case .triangulate:
            [Parameter(key: "quads", label: "Split Quads", type: .bool, control: .toggle, fallback: 1),
             Parameter(key: "minimumVertices", label: "Minimum Vertices", type: .int, control: .whole(4 ... 16),
                       fallback: 4)]
        }
      }
    }

    /// one parameter of a modifier, which is one usd attribute and one row of the panel
    struct Parameter
    {
      /// the attribute name under the modifiers namespace, or the whole name when absolute
      var key: String
      var label: String
      var type: Sdf.ValueTypeNameType
      /// subdivisions parameters are the meshs own attributes rather than a namespace of the stack
      var absolute = false
      var control: Control
      var fallback: Double = 0
      /// a vectors per component fallbacks, when they differ
      var fallbacks: [Double]?

      enum Control
      {
        case whole(ClosedRange<Double>)
        case factor(ClosedRange<Double>)
        case distance(ClosedRange<Double>)
        case vector(ClosedRange<Double>)
        case toggle
        case choice([String])
      }

      var components: Int
      {
        if case .vector = control { 3 } else { 1 }
      }

      var defaults: [Double]
      {
        fallbacks ?? [Double](repeating: fallback, count: components)
      }
    }

    /// one modifier on a prim, named by the slug its attributes live under
    struct Entry: Equatable, Identifiable
    {
      var name: String
      var kind: Kind
      var viewport = true
      var render = true
      /// every parameters numbers, by key
      var values: [String: [Double]] = [:]

      var id: String { name }

      func number(_ key: String, _ fallback: Double, _ i: Int = 0) -> Double
      {
        let v = values[key] ?? []
        return i < v.count ? v[i] : fallback
      }

      func flag(_ key: String, _ fallback: Bool = false) -> Bool
      {
        number(key, fallback ? 1 : 0) != 0
      }

      func vector(_ key: String, _ fallback: SIMD3<Float> = .zero) -> SIMD3<Float>
      {
        let v = values[key] ?? []
        guard v.count >= 3 else { return fallback }
        return SIMD3(Float(v[0]), Float(v[1]), Float(v[2]))
      }

      /// whether the stack evaluates this entry for the viewport or for a final render
      func shows(render: Bool) -> Bool
      {
        render ? self.render : viewport
      }
    }

    /// the subdivision schemes a mesh can carry, as the panel names them
    static let schemes: [(label: String, token: Tf.Token)] =
      [("Catmull Clark", Tf.Token("catmullClark")), ("Loop", Tf.Token("loop")), ("Bilinear", Tf.Token("bilinear"))]

    /// the stacks order, a token array of the entry names from bottom to top
    static let order = Tf.Token("akari:modifiers")

    /// set in the session layer while an applied modifier waits for the scene to be saved
    static let pending = Tf.Token("akari:modifiers:applied")

    static let namespace = "akari:modifier:"

    /// the attribute that parameter of the modifier named name is
    static func attribute(_ name: String, _ parameter: Parameter) -> Tf.Token
    {
      parameter.absolute ? Tf.Token(parameter.key) : attribute(name, parameter.key)
    }

    static func attribute(_ name: String, _ key: String) -> Tf.Token
    {
      Tf.Token("\(namespace)\(name):\(key)")
    }

    /// a slug for a new kind on a prim that already carries taken
    static func unique(_ kind: Kind, among taken: [String]) -> String
    {
      let base = kind.title.replacingOccurrences(of: " ", with: "")
      guard taken.contains(base) else { return base }

      var i = 2
      while taken.contains("\(base)\(i)") { i += 1 }
      return "\(base)\(i)"
    }
  }
}
