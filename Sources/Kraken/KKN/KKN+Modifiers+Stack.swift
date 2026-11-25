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

extension Kraken.Modifiers
{
  /// the stack the mesh at path carries, bottom to top, empty when it carries none
  nonisolated static func read(_ stage: UsdStage, _ path: String) -> [Entry]
  {
    guard let prim = Kraken.SceneEdit.prim(stage, path), prim.isA(.mesh) else { return [] }

    return names(prim).compactMap { entry(prim, $0) }
  }

  /// the names in the prims stack attribute, in order
  nonisolated static func names(_ prim: UsdPrim) -> [String]
  {
    var tokens = Pixar.VtTokenArray()
    guard let attribute = prim.attribute(named: order), attribute.Get(&tokens, Pixar.UsdTimeCode.Default()) else
    {
      return []
    }

    var out: [String] = []
    out.reserveCapacity(tokens.size())
    for i in 0 ..< tokens.size() { out.append(tokens[i].string) }
    return out
  }

  /// reads one modifier off the prim, nil when its type attribute names none akari knows
  nonisolated private static func entry(_ prim: UsdPrim, _ name: String) -> Entry?
  {
    var type = Tf.Token()
    guard let kindAttribute = prim.attribute(named: attribute(name, "type")),
          kindAttribute.Get(&type, Pixar.UsdTimeCode.Default()),
          let kind = Kind(rawValue: type.string) else { return nil }

    var out = Entry(name: name, kind: kind)
    out.viewport = boolean(prim, attribute(name, "viewport")) ?? true
    out.render = boolean(prim, attribute(name, "render")) ?? true

    for parameter in kind.parameters
    {
      out.values[parameter.key] = numbers(prim, attribute(name, parameter), parameter)
    }

    return out
  }

  nonisolated private static func boolean(_ prim: UsdPrim, _ name: Tf.Token) -> Bool?
  {
    var value = false
    guard let attribute = prim.attribute(named: name), attribute.Get(&value, Pixar.UsdTimeCode.Default()) else
    {
      return nil
    }

    return value
  }

  /// one parameters numbers, falling back to its defaults where the prim authors nothing
  nonisolated static func numbers(_ prim: UsdPrim, _ name: Tf.Token, _ parameter: Parameter) -> [Double]
  {
    guard let attribute = prim.attribute(named: name) else { return parameter.defaults }

    let time = Pixar.UsdTimeCode.Default()
    switch parameter.type
    {
      case .bool:
        var value = false
        return attribute.Get(&value, time) ? [value ? 1 : 0] : parameter.defaults
      case .int:
        var value = Int32(0)
        return attribute.Get(&value, time) ? [Double(value)] : parameter.defaults
      case .float:
        var value = Float(0)
        return attribute.Get(&value, time) ? [Double(value)] : parameter.defaults
      case .float3:
        var value = Pixar.GfVec3f(0, 0, 0)
        return attribute.Get(&value, time) ? [Double(value[0]), Double(value[1]), Double(value[2])] : parameter.defaults
      case .token:
        var value = Tf.Token()
        guard attribute.Get(&value, time) else { return parameter.defaults }

        return [Double(schemes.firstIndex { $0.token == value } ?? 0)]
      default:
        return parameter.defaults
    }
  }

  // MARK: writing

  /// writes the stacks order to the prim, leaving the modifiers own attributes alone
  @discardableResult
  nonisolated static func setOrder(_ stage: UsdStage, _ path: String, _ names: [String]) -> Bool
  {
    Kraken.Authoring.edit(stage, path)
    { prim, _ in
      guard let attribute = prim.attribute(named: order)
        ?? prim.createAttribute(name: order, typeName: Sdf.getValueType(for: .tokenArray), custom: true,
                                variability: .uniform) else { return false }

      let tokens = names.map { Tf.Token($0) }
      let array: Pixar.VtTokenArray = tokens.withUnsafeBufferPointer
      {
        Overlay.vtArray($0.baseAddress, $0.count)
      }

      return attribute.Set(array, Pixar.UsdTimeCode.Default())
    }
  }

  /// adds a modifier of kind on top of the prims stack and returns the name it took
  @discardableResult
  nonisolated static func add(_ stage: UsdStage, _ path: String, _ kind: Kind) -> String?
  {
    guard let prim = Kraken.SceneEdit.prim(stage, path), prim.isA(.mesh) else { return nil }

    let taken = names(prim)
    let name = unique(kind, among: taken)

    let wrote = Kraken.Authoring.edit(stage, path)
    { prim, _ in
      guard let type = prim.createAttribute(name: attribute(name, "type"), typeName: Sdf.getValueType(for: .token),
                                            custom: true, variability: .uniform) else { return false }
      _ = type.Set(Tf.Token(kind.rawValue), Pixar.UsdTimeCode.Default())

      for key in ["viewport", "render"]
      {
        guard let flag = prim.createAttribute(name: attribute(name, key), typeName: Sdf.getValueType(for: .bool),
                                              custom: true, variability: .uniform) else { continue }
        _ = flag.set(true)
      }

      // the parameters are written out so the stack reads the same in a text layer as it does here
      for parameter in kind.parameters where !parameter.absolute
      {
        write(prim, attribute(name, parameter), parameter, parameter.defaults)
      }

      return true
    }

    guard wrote else { return nil }

    // subdivision is the meshs own scheme and levels, so adding one authors those instead of a namespace
    if kind.isRefinement
    {
      Kraken.Authoring.edit(stage, path)
      { prim, _ in
        for parameter in kind.parameters where parameter.absolute
        {
          write(prim, Tf.Token(parameter.key), parameter, parameter.defaults)
        }

        return true
      }
    }

    setOrder(stage, path, taken + [name])
    return name
  }

  /// takes a modifier off the stack along with everything it authored
  nonisolated static func remove(_ stage: UsdStage, _ path: String, _ name: String)
  {
    guard let prim = Kraken.SceneEdit.prim(stage, path) else { return }

    let kept = names(prim).filter { $0 != name }
    let kind = read(stage, path).first { $0.name == name }?.kind

    Kraken.Authoring.edit(stage, path)
    { prim, _ in
      var owner = prim
      for key in ["type", "viewport", "render"] + (kind?.parameters.filter { !$0.absolute }.map(\.key) ?? [])
      {
        _ = owner.RemoveProperty(attribute(name, key))
      }

      // a mesh with no scheme of its own resolves to catmull clark, so dropping subdivision says plainly it is a polygon mesh again
      if kind?.isRefinement == true
      {
        for level in ["akari:subdivision:viewportLevel", "akari:subdivision:renderLevel"]
        {
          _ = owner.RemoveProperty(Tf.Token(level))
        }

        var mesh = Pixar.UsdGeomMesh(prim)
        _ = mesh.CreateSubdivisionSchemeAttr(Pixar.VtValue(Tf.Token("none")), false)
      }

      return true
    }

    setOrder(stage, path, kept)
  }

  /// moves a modifier one place up or down the stack
  nonisolated static func move(_ stage: UsdStage, _ path: String, _ name: String, up: Bool)
  {
    guard let prim = Kraken.SceneEdit.prim(stage, path) else { return }

    var list = names(prim)
    guard let at = list.firstIndex(of: name) else { return }

    let to = up ? at + 1 : at - 1
    guard list.indices.contains(to) else { return }

    list.swapAt(at, to)
    setOrder(stage, path, list)
  }

  /// writes one of a modifiers parameters
  nonisolated static func set(_ stage: UsdStage, _ path: String, _ name: String, _ parameter: Parameter,
                              _ values: [Double])
  {
    Kraken.Authoring.edit(stage, path)
    { prim, _ in
      write(prim, attribute(name, parameter), parameter, values)
      return true
    }
  }

  /// sets a subdivision modifiers levels, leaving out the one that is nil
  nonisolated static func setLevels(_ stage: UsdStage, _ path: String, _ name: String, viewport: Int?, render: Int?)
  {
    let parameters = Kind.subdivision.parameters
    guard let viewportLevel = parameters.first(where: { $0.key.hasSuffix("viewportLevel") }),
          let renderLevel = parameters.first(where: { $0.key.hasSuffix("renderLevel") }) else { return }

    if let viewport { set(stage, path, name, viewportLevel, [Double(viewport)]) }
    if let render { set(stage, path, name, renderLevel, [Double(render)]) }
  }

  /// turns a modifier on or off for the viewport or for a final render
  nonisolated static func show(_ stage: UsdStage, _ path: String, _ name: String, render: Bool, on: Bool)
  {
    Kraken.Authoring.edit(stage, path)
    { prim, _ in
      let key = render ? "render" : "viewport"
      guard let attribute = prim.attribute(named: attribute(name, key))
        ?? prim.createAttribute(name: attribute(name, key), typeName: Sdf.getValueType(for: .bool), custom: true,
                                variability: .uniform) else { return false }

      return attribute.set(on)
    }
  }

  /// writes values into the attribute named name on prim, creating it in the current edit target
  @discardableResult
  nonisolated static func write(_ prim: UsdPrim, _ name: Tf.Token, _ parameter: Parameter,
                                _ values: [Double]) -> Bool
  {
    guard let attribute = prim.attribute(named: name)
      ?? prim.createAttribute(name: name, typeName: Sdf.getValueType(for: parameter.type), custom: !parameter.absolute,
                              variability: .uniform) else { return false }

    let x = values.first ?? parameter.fallback
    switch parameter.type
    {
      case .bool: return attribute.set(x != 0)
      case .int: return attribute.set(Int32(x.rounded()))
      case .float: return attribute.set(Float(x))
      case .float3:
        let v = values.count >= 3 ? values : parameter.defaults
        return attribute.set(Pixar.GfVec3f(Float(v[0]), Float(v[1]), Float(v[2])))
      case .token:
        let i = Int(x.rounded())
        guard schemes.indices.contains(i) else { return false }
        return attribute.Set(schemes[i].token, Pixar.UsdTimeCode.Default())
      default: return false
    }
  }
}
