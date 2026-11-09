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

extension Kraken.SceneEdit
{
  /// An animated attribute, as listed in the dope sheet.
  struct Channel: Hashable, Sendable
  {
    var path: String
    var name: String
    var times: [Double]

    var id: String
    {
      path + "." + name
    }
  }

  // MARK: Curves

  nonisolated static func keyTimes(_ attribute: Usd.Attribute) -> [Double]
  {
    Array(Pixar.HdAkariTimeSamples(attribute))
  }

  nonisolated static func value(_ attribute: Usd.Attribute, _ time: Double) -> Pixar.VtValue?
  {
    var value = Pixar.VtValue()
    guard attribute.Get(&value, Pixar.UsdTimeCode(time)), !value.IsEmpty() else { return nil }
    return value
  }

  /// Writes `value` at `time`, or as the default value when `time` is nil.
  @discardableResult
  nonisolated static func write(_ attribute: Usd.Attribute, _ value: Pixar.VtValue, at time: Double?) -> Bool
  {
    Pixar.HdAkariSetValue(attribute, value, time ?? .nan)
  }

  /// Whether the edit target's layer has its own keys for the attribute.
  nonisolated static func localCurve(_ attribute: Usd.Attribute, _ stage: UsdStage) -> Bool
  {
    let target = stage.editTarget
    #if compiler(>=6.4)
      let layer = target.GetLayerConsuming()
    #else
      let layer = target.GetLayer()
    #endif
    return layer.pointee.GetNumTimeSamplesForPath(target.MapToSpecPath(attribute.GetPath())) > 0
  }

  /// Copies a curve from a weaker layer into the edit target before its first edit.
  /// Keys in a stronger layer replace the whole curve below, so editing one key would otherwise drop the rest.
  nonisolated static func localize(_ attribute: Usd.Attribute, _ stage: UsdStage)
  {
    guard attribute.GetNumTimeSamples() > 0, !localCurve(attribute, stage) else { return }
    let keys = keyTimes(attribute).compactMap { t in value(attribute, t).map { (t, $0) } }
    for (t, v) in keys { write(attribute, v, at: t) }
  }

  /// The animated attributes of the prims at `paths` and their materials, without duplicates.
  nonisolated static func channels(_ stage: UsdStage, _ paths: [String]) -> [Channel]
  {
    var seen = Set<String>()
    var out: [Channel] = []
    func add(_ p: UsdPrim)
    {
      for attribute in p.GetAttributes() where attribute.GetNumTimeSamples() > 0
      {
        let channel = Channel(path: p.GetPath().string, name: attribute.name.string, times: keyTimes(attribute))
        if seen.insert(channel.id).inserted { out.append(channel) }
      }
    }

    for path in paths
    {
      guard let prim = prim(stage, path) else { continue }
      add(prim)
      if let material = boundMaterial(prim)
      {
        let root = material.GetPrim()
        for p in IteratorSequence(Pixar.UsdPrimRange(root)) where p.GetPath() != root.GetPath() { add(p) }
      }
    }

    return out
  }

  // MARK: Keys

  /// Keys `name` at `time` with its current value.
  @discardableResult
  nonisolated static func insertKey(_ stage: UsdStage, _ path: String, _ name: String, _ time: Double) -> Bool
  {
    let keyed = Kraken.Authoring.edit(stage, path)
    { prim, stage in
      guard let attribute = prim.attribute(named: Tf.Token(name)), let v = value(attribute, time) else { return false }
      localize(attribute, stage)
      return write(attribute, v, at: time)
    }
    // The value may come from an unkeyed edit held in the session layer, which the key replaces.
    clearSessionValue(stage, path, name)
    return keyed
  }

  /// Deletes the key at `time`. Deleting the last key keeps its value as the default,
  /// so a weaker layer's curve doesn't show through.
  @discardableResult
  nonisolated static func deleteKey(_ stage: UsdStage, _ path: String, _ name: String, _ time: Double) -> Bool
  {
    Kraken.Authoring.edit(stage, path)
    { prim, stage in
      guard let attribute = prim.attribute(named: Tf.Token(name)) else { return false }
      localize(attribute, stage)
      let v = value(attribute, time)
      guard attribute.ClearAtTime(Pixar.UsdTimeCode(time)) else { return false }
      if !localCurve(attribute, stage), let v { write(attribute, v, at: nil) }
      return true
    }
  }

  /// Deletes every key, keeping the value at `time` as the default.
  @discardableResult
  nonisolated static func clearKeys(_ stage: UsdStage, _ path: String, _ name: String, _ time: Double) -> Bool
  {
    Kraken.Authoring.edit(stage, path)
    { prim, _ in
      guard let attribute = prim.attribute(named: Tf.Token(name)), let v = value(attribute, time) else { return false }
      _ = attribute.Clear()
      return write(attribute, v, at: nil)
    }
  }

  /// Moves the keys at `times` to `pivot + (t - pivot) * scale + delta`, rounded to whole frames.
  /// Leaves the originals in place when `duplicate` is set.
  @discardableResult
  nonisolated static func retimeKeys(_ stage: UsdStage, _ path: String, _ name: String, _ times: [Double],
                                     delta: Double, scale: Double = 1, pivot: Double = 0, duplicate: Bool = false) -> Bool
  {
    Kraken.Authoring.edit(stage, path)
    { prim, stage in
      guard let attribute = prim.attribute(named: Tf.Token(name)), !times.isEmpty else { return false }
      localize(attribute, stage)
      let moved = times.compactMap { t in value(attribute, t).map { (t, $0) } }
      if !duplicate { for (t, _) in moved { _ = attribute.ClearAtTime(Pixar.UsdTimeCode(t)) } }
      return moved.reduce(true) { $0 && write(attribute, $1.1, at: (pivot + ($1.0 - pivot) * scale + delta).rounded()) }
    }
  }

  nonisolated static func keyValue(_ stage: UsdStage, _ path: String, _ name: String, _ time: Double) -> Pixar.VtValue?
  {
    prim(stage, path)?.attribute(named: Tf.Token(name)).flatMap { value($0, time) }
  }

  @discardableResult
  nonisolated static func setKey(_ stage: UsdStage, _ path: String, _ name: String, _ time: Double, _ v: Pixar.VtValue) -> Bool
  {
    Kraken.Authoring.edit(stage, path)
    { prim, stage in
      guard let attribute = prim.attribute(named: Tf.Token(name)) else { return false }
      localize(attribute, stage)
      return write(attribute, v, at: time)
    }
  }

  /// Holds an unkeyed edit to an animated attribute as a session layer default, which wins over the
  /// curves below it, until it's keyed or the frame changes.
  @discardableResult
  nonisolated static func setSessionValue(_ stage: UsdStage, _ path: String, _ name: Tf.Token, _ values: [Double]) -> Bool
  {
    guard let prim = prim(stage, path), let attribute = prim.attribute(named: name), attribute.isValid else { return false }
    var wrote = false
    Kraken.Authoring.inSession(stage) { wrote = assign(attribute, values, Pixar.UsdTimeCode.Default()) }
    return wrote
  }

  nonisolated static func clearSessionValue(_ stage: UsdStage, _ path: String, _ name: String)
  {
    guard let attribute = prim(stage, path)?.attribute(named: Tf.Token(name)) else { return }
    Kraken.Authoring.inSession(stage) { _ = attribute.ClearDefault() }
  }

  // MARK: Transforms

  private static let heldLock = NSLock()
  /// Animated prims with an unkeyed move held in the session layer.
  nonisolated(unsafe) private static var held = Set<String>()

  nonisolated static func holdsTransform(_ path: String) -> Bool
  {
    heldLock.withLock { held.contains(path) }
  }

  private nonisolated static func ops(_ prim: UsdPrim) -> (ops: [Pixar.UsdGeomXformOp], resets: Bool)
  {
    var resets = false
    let list = Pixar.UsdGeomXformable(prim).GetOrderedXformOps(&resets)
    return ((0 ..< list.size()).map { list[$0] }, resets)
  }

  nonisolated static func transformAnimated(_ prim: UsdPrim) -> Bool
  {
    ops(prim).ops.contains { $0.GetNumTimeSamples() > 0 }
  }

  /// The prim's transform as a single matrix op, replacing any op stack.
  private nonisolated static func matrixOp(_ prim: UsdPrim) -> Pixar.UsdGeomXformOp
  {
    let (list, resets) = ops(prim)
    if list.count == 1, list[0].GetOpType() == .transform { return list[0] }
    let xformable = Pixar.UsdGeomXformable(prim)
    _ = xformable.ClearXformOpOrder()
    let op = xformable.addXformOp(type: .transform, precision: .double)
    if resets { _ = xformable.SetResetXformStack(true) }
    return op
  }

  /// Holds a move of an animated prim in the session layer until it's keyed or the frame changes.
  /// Returns nil when the prim's transform isn't animated.
  nonisolated static func overrideTransform(_ stage: UsdStage, _ path: String, _ local: [Double]) -> Bool?
  {
    guard let prim = prim(stage, path), holdsTransform(path) || transformAnimated(prim) else { return nil }
    var wrote = false
    Kraken.Authoring.inSession(stage) { wrote = matrixOp(prim).Set(matrix(local), Pixar.UsdTimeCode.Default()) }
    _ = heldLock.withLock { held.insert(path) }
    return wrote
  }

  /// Keys the prim's current local transform, including any held move, at `time`.
  /// An animated op stack is first baked into a single matrix op so the existing motion is kept.
  @discardableResult
  nonisolated static func keyTransform(_ stage: UsdStage, _ path: String, _ time: Double) -> Bool
  {
    guard let now = transform(stage, path, time)?.local else { return false }
    releaseTransform(stage, path)
    return Kraken.Authoring.edit(stage, path)
    { prim, stage in
      guard prim.isA(.xformable) else { return false }
      let (list, _) = ops(prim)
      var baked: [(Double, Pixar.GfMatrix4d)] = []
      if !(list.count == 1 && list[0].GetOpType() == .transform)
      {
        let frames = Set(list.flatMap { op in prim.attribute(named: op.GetOpName()).map(keyTimes) ?? [] }).sorted()
        baked = frames.compactMap { t in transform(stage, path, t).map { (t, matrix($0.local)) } }
      }

      let op = matrixOp(prim)
      for (t, m) in baked { _ = op.Set(m, Pixar.UsdTimeCode(t)) }
      if let attribute = prim.attribute(named: op.GetOpName()) { localize(attribute, stage) }
      return op.Set(matrix(now), Pixar.UsdTimeCode(time))
    }
  }

  @discardableResult
  nonisolated static func deleteTransformKey(_ stage: UsdStage, _ path: String, _ time: Double) -> Bool
  {
    releaseTransform(stage, path)
    guard let prim = prim(stage, path) else { return false }
    let names = ops(prim).ops.filter { $0.GetNumTimeSamples() > 0 }.map { $0.GetOpName().string }
    return names.reduce(false) { deleteKey(stage, path, $1, time) || $0 }
  }

  /// Deletes every transform key, leaving the prim where it is at `time`.
  @discardableResult
  nonisolated static func clearTransformKeys(_ stage: UsdStage, _ path: String, _ time: Double) -> Bool
  {
    guard let now = transform(stage, path, time)?.local else { return false }
    releaseTransform(stage, path)
    return Kraken.Authoring.edit(stage, path)
    { prim, _ in
      let op = matrixOp(prim)
      if let attribute = prim.attribute(named: op.GetOpName()) { _ = attribute.Clear() }
      return op.Set(matrix(now), Pixar.UsdTimeCode.Default())
    }
  }

  /// Drops a held move so the prim follows its animation again.
  nonisolated static func releaseTransform(_ stage: UsdStage, _ path: String)
  {
    guard heldLock.withLock({ held.remove(path) }) != nil, let prim = prim(stage, path) else { return }
    Kraken.Authoring.inSession(stage)
    {
      _ = Pixar.UsdGeomXformable(prim).GetXformOpOrderAttr().Clear()
      _ = prim.attribute(named: Tf.Token("xformOp:transform"))?.ClearDefault()
    }
  }

  /// Drops every held move and returns the affected paths.
  @discardableResult
  nonisolated static func releaseTransforms(_ stage: UsdStage) -> [String]
  {
    let paths = heldLock.withLock { Array(held) }
    for path in paths { releaseTransform(stage, path) }
    return paths
  }
}
