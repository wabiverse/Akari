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

extension Kraken.SceneEdit
{
  /// how a primvar's values spread over a mesh, coarsest first
  enum JoinSpread: Int, Comparable, Hashable
  {
    case constant, uniform, vertex, faceVarying

    init?(_ token: Tf.Token)
    {
      switch token.string
      {
        case "constant": self = .constant
        case "uniform": self = .uniform
        case "vertex", "varying": self = .vertex
        case "faceVarying": self = .faceVarying
        default: return nil
      }
    }

    var token: Tf.Token
    {
      switch self
      {
        case .constant: Tf.Token("constant")
        case .uniform: Tf.Token("uniform")
        case .vertex: Tf.Token("vertex")
        case .faceVarying: Tf.Token("faceVarying")
      }
    }

    static func < (a: JoinSpread, b: JoinSpread) -> Bool
    {
      a.rawValue < b.rawValue
    }
  }

  /// a primvar's flattened values, `width` floats for each element
  struct JoinPrimvar
  {
    var values: [Float]
    var width: Int
    var spread: JoinSpread
  }

  /// one mesh going into a join, read into the joined mesh's space
  struct JoinPiece
  {
    var points: [SIMD3<Float>] = []
    var counts: [Int32] = []
    var indices: [Int32] = []
    /// the corner each joined corner came from, which differs where a mirrored face had its winding turned
    var corners: [Int] = []
    var normals: JoinPrimvar?
    var primvars: [String: JoinPrimvar] = [:]
    var types: [String: Pixar.SdfValueTypeName] = [:]
    var creases: [Int32] = []
    var creaseSharpness: [Float] = []
    var cornerIndices: [Int32] = []
    var cornerSharpness: [Float] = []
    var holes: [Int32] = []
    var sharp: [Int32] = []
    /// the material each face renders with, empty where none is bound
    var materials: [String] = []
  }

  struct JoinResult
  {
    var target = ""
    var joined = 0
    var removed: [String] = []
    var failed = false
  }

  /// whether the scene draws this mesh in a render, so proxies, guides and hidden meshes stay out of a join
  nonisolated static func joinable(_ prim: UsdPrim, _ t: Pixar.UsdTimeCode) -> Bool
  {
    guard prim.isA(.mesh), !invisible(prim, t) else { return false }

    let purpose = Pixar.UsdGeomImageable(prim).ComputePurpose().string
    return purpose != "proxy" && purpose != "guide"
  }

  /// the children a join walks, through instances too
  nonisolated static func joinChildren(_ prim: UsdPrim) -> [UsdPrim]
  {
    var range = prim.GetFilteredChildren(Pixar.UsdTraverseInstanceProxies())
    var out: [UsdPrim] = []
    while let child = range.next() { out.append(child) }
    return out
  }

  /// every mesh under the paths the scene draws, with instances kept whole since their insides can't be picked apart
  nonisolated static func hierarchy(_ stage: UsdStage, _ paths: [String], _ time: Double) -> [String]
  {
    let t = Pixar.UsdTimeCode(time)
    var out: [String] = []
    var seen = Set<String>()

    for path in paths
    {
      guard let root = prim(stage, path) else { continue }

      for p in IteratorSequence(Pixar.UsdPrimRange(root))
      {
        guard p.isInstance || joinable(p, t) else { continue }

        let found = p.GetPath().string
        if seen.insert(found).inserted { out.append(found) }
      }
    }

    return out
  }

  /// the material a prim renders with, empty when none is bound
  nonisolated static func materialPath(_ prim: UsdPrim) -> String
  {
    let material = Pixar.UsdShadeMaterialBindingAPI(prim).ComputeBoundMaterial(.allPurpose, nil, true)
    return material.GetPrim().isValid ? material.GetPrim().GetPath().string : ""
  }

  nonisolated static func ints(_ attribute: Usd.Attribute, _ t: Pixar.UsdTimeCode) -> [Int32]
  {
    var array = Pixar.VtIntArray()
    guard attribute.Get(&array, t) else { return [] }

    let data: UnsafePointer<Int32>? = Overlay.cdata(array)
    return Array(UnsafeBufferPointer(start: data, count: array.size()))
  }

  nonisolated static func floatValues(_ attribute: Usd.Attribute, _ t: Pixar.UsdTimeCode) -> [Float]
  {
    floats(attribute, width: 1, t) ?? []
  }

  /// how many floats each element of a primvar type holds, for the float types a join can carry
  nonisolated static func width(_ typeName: String) -> Int?
  {
    guard typeName.hasSuffix("[]") else { return nil }

    switch typeName.dropLast(2)
    {
      case "float": return 1
      case "float2", "texCoord2f": return 2
      case "float3", "color3f", "normal3f", "point3f", "vector3f", "texCoord3f": return 3
      case "float4", "color4f": return 4
      default: return nil
    }
  }

  /// an attribute's float array values, `width` floats for each element
  nonisolated static func floats(_ attribute: Usd.Attribute, width: Int, _ t: Pixar.UsdTimeCode) -> [Float]?
  {
    func flat<S>(_ data: UnsafePointer<S>?, _ count: Int) -> [Float]
    {
      guard let data else { return [] }
      return Array(UnsafeBufferPointer(start: UnsafeRawPointer(data).assumingMemoryBound(to: Float.self), count: count * width))
    }

    switch width
    {
      case 1:
        var array = Pixar.VtFloatArray()
        guard attribute.Get(&array, t) else { return nil }
        let data: UnsafePointer<Float>? = Overlay.cdata(array)
        return flat(data, array.size())
      case 2:
        var array = Pixar.VtVec2fArray()
        guard attribute.Get(&array, t) else { return nil }
        let data: UnsafePointer<Pixar.GfVec2f>? = Overlay.cdata(array)
        return flat(data, array.size())
      case 3:
        var array = Pixar.VtVec3fArray()
        guard attribute.Get(&array, t) else { return nil }
        let data: UnsafePointer<Pixar.GfVec3f>? = Overlay.cdata(array)
        return flat(data, array.size())
      case 4:
        var array = Pixar.VtVec4fArray()
        guard attribute.Get(&array, t) else { return nil }
        let data: UnsafePointer<Pixar.GfVec4f>? = Overlay.cdata(array)
        return flat(data, array.size())
      default:
        return nil
    }
  }

  @discardableResult
  nonisolated static func setFloats(_ attribute: Usd.Attribute, _ values: [Float], width: Int) -> Bool
  {
    let time = Pixar.UsdTimeCode.Default()
    let at = stride(from: 0, to: values.count - width + 1, by: width)

    switch width
    {
      case 1:
        return attribute.Set(floatArray(values), time)
      case 2:
        let vectors = at.map { Pixar.GfVec2f(values[$0], values[$0 + 1]) }
        let array: Pixar.VtVec2fArray = vectors.withUnsafeBufferPointer { Overlay.vtArray($0.baseAddress, $0.count) }
        return attribute.Set(array, time)
      case 3:
        let vectors = at.map { Pixar.GfVec3f(values[$0], values[$0 + 1], values[$0 + 2]) }
        let array: Pixar.VtVec3fArray = vectors.withUnsafeBufferPointer { Overlay.vtArray($0.baseAddress, $0.count) }
        return attribute.Set(array, time)
      case 4:
        let vectors = at.map { Pixar.GfVec4f(values[$0], values[$0 + 1], values[$0 + 2], values[$0 + 3]) }
        let array: Pixar.VtVec4fArray = vectors.withUnsafeBufferPointer { Overlay.vtArray($0.baseAddress, $0.count) }
        return attribute.Set(array, time)
      default:
        return false
    }
  }

  /// a primvar's values with its indices undone, nil when they don't fit the mesh
  nonisolated static func channel(_ prim: UsdPrim, _ name: String, width: Int, spread: JoinSpread, elements: Int,
                                  _ t: Pixar.UsdTimeCode) -> JoinPrimvar?
  {
    guard let attribute = prim.attribute(named: Tf.Token("primvars:" + name)),
          var values = floats(attribute, width: width, t)
    else { return nil }

    if let lookup = prim.attribute(named: Tf.Token("primvars:\(name):indices"))
    {
      let indices = ints(lookup, t)
      if !indices.isEmpty
      {
        let count = values.count / width
        var flat: [Float] = []
        flat.reserveCapacity(indices.count * width)
        for i in indices.map(Int.init)
        {
          guard i >= 0, i < count else { return nil }
          flat += values[i * width ..< (i + 1) * width]
        }

        values = flat
      }
    }

    guard values.count == elements * width else { return nil }
    return JoinPrimvar(values: values, width: width, spread: spread)
  }

  /// how many elements a primvar spread this way holds on a piece
  nonisolated static func elements(_ spread: JoinSpread, points: Int, faces: Int, corners: Int) -> Int
  {
    switch spread
    {
      case .constant: 1
      case .uniform: faces
      case .vertex: points
      case .faceVarying: corners
    }
  }

  /// each vertex's normal averaged over the faces around it, for meshes that come with none
  nonisolated static func vertexNormals(_ points: [SIMD3<Float>], _ counts: [Int32], _ indices: [Int32]) -> [Float]
  {
    var sums = [SIMD3<Float>](repeating: .zero, count: points.count)
    var offset = 0

    for count in counts.map(Int.init)
    {
      let face = indices[offset ..< offset + count].map(Int.init)
      let n = Kraken.PrimitiveShape.newell(points, face)
      for v in face { sums[v] += n }
      offset += count
    }

    return sums.flatMap
    { s -> [Float] in
      let n = simd_length(s) > 0 ? simd_normalize(s) : SIMD3<Float>(0, 0, 1)
      return [n.x, n.y, n.z]
    }
  }

  /// reads a mesh into the space of `world`, nil when its faces point past its points
  nonisolated static func piece(_ prim: UsdPrim, into world: simd_double4x4, identity: Bool, leftHanded: Bool,
                                _ t: Pixar.UsdTimeCode, _ cache: inout Pixar.UsdGeomXformCache) -> JoinPiece?
  {
    let mesh = Pixar.UsdGeomMesh(prim)
    var pointArray = Pixar.VtVec3fArray()
    _ = mesh.GetPointsAttr().Get(&pointArray, t)
    let pointData: UnsafePointer<Pixar.GfVec3f>? = Overlay.cdata(pointArray)
    let raw = pointData.map
    {
      Array(UnsafeBufferPointer(start: UnsafeRawPointer($0).assumingMemoryBound(to: Float.self), count: pointArray.size() * 3))
    } ?? []

    let counts = ints(mesh.GetFaceVertexCountsAttr(), t)
    let indices = ints(mesh.GetFaceVertexIndicesAttr(), t)
    let pointCount = raw.count / 3
    guard counts.allSatisfy({ $0 >= 0 }), counts.reduce(0, { $0 + Int($1) }) == indices.count,
          indices.allSatisfy({ $0 >= 0 && Int($0) < pointCount })
    else { return nil }

    let relative = identity ? matrix_identity_double4x4
      : world.inverse * Kraken.Layout.matrix(rows(cache.GetLocalToWorldTransform(prim)))
    let linear = simd_double3x3(columns: (SIMD3(relative.columns.0.x, relative.columns.0.y, relative.columns.0.z),
                                          SIMD3(relative.columns.1.x, relative.columns.1.y, relative.columns.1.z),
                                          SIMD3(relative.columns.2.x, relative.columns.2.y, relative.columns.2.z)))
    let normalMatrix = linear.determinant == 0 ? linear : linear.inverse.transpose

    var piece = JoinPiece()
    piece.points = stride(from: 0, to: raw.count - 2, by: 3).map
    { i -> SIMD3<Float> in
      let p = relative * SIMD4(Double(raw[i]), Double(raw[i + 1]), Double(raw[i + 2]), 1)
      return SIMD3(Float(p.x), Float(p.y), Float(p.z))
    }

    // a mirroring transform or the other handedness turns faces inside out, so their winding is turned back
    var orientation = Tf.Token()
    _ = mesh.GetOrientationAttr().Get(&orientation, t)
    let mirrored = (orientation.string == "leftHanded") != leftHanded
    let flip = mirrored != (linear.determinant < 0)

    piece.counts = counts
    piece.corners.reserveCapacity(indices.count)
    var offset = 0
    for count in counts.map(Int.init)
    {
      if flip && count > 2
      {
        piece.corners.append(offset)
        for i in stride(from: count - 1, through: 1, by: -1) { piece.corners.append(offset + i) }
      }
      else
      {
        piece.corners += Array(offset ..< offset + count)
      }

      offset += count
    }

    piece.indices = piece.corners.map { indices[$0] }

    let faces = counts.count, corners = indices.count
    func size(_ spread: JoinSpread) -> Int { elements(spread, points: pointCount, faces: faces, corners: corners) }

    // normals come from the primvar when it has values, which outranks the plain attribute
    let primvars = Pixar.UsdGeomPrimvarsAPI(prim)
    let normalPrimvar = primvars.GetPrimvar(.normals)
    var normals: JoinPrimvar?
    if normalPrimvar.HasValue(), let spread = JoinSpread(normalPrimvar.GetInterpolation())
    {
      normals = channel(prim, "normals", width: 3, spread: spread, elements: size(spread), t)
    }
    else if let spread = JoinSpread(mesh.GetNormalsInterpolation()), let values = floats(mesh.GetNormalsAttr(), width: 3, t),
            values.count == size(spread) * 3
    {
      normals = JoinPrimvar(values: values, width: 3, spread: spread)
    }

    if var n = normals
    {
      for i in stride(from: 0, to: n.values.count - 2, by: 3)
      {
        let v = normalMatrix * SIMD3(Double(n.values[i]), Double(n.values[i + 1]), Double(n.values[i + 2]))
        let unit = simd_length(v) > 0 ? simd_normalize(v) : v
        n.values[i] = Float(unit.x)
        n.values[i + 1] = Float(unit.y)
        n.values[i + 2] = Float(unit.z)
      }

      piece.normals = n
    }

    for primvar in primvars.GetPrimvarsWithValues()
    {
      let name = primvar.GetPrimvarName().string
      guard name != "normals", primvar.GetElementSize() == 1, let spread = JoinSpread(primvar.GetInterpolation()) else { continue }

      let typeName = primvar.__GetTypeNameUnsafe()
      guard let width = width(typeName.GetAsToken().string),
            let values = channel(prim, name, width: width, spread: spread, elements: size(spread), t)
      else { continue }

      piece.primvars[name] = values
      piece.types[name] = typeName
    }

    (piece.creases, piece.creaseSharpness) = creases(mesh, t)
    piece.cornerIndices = ints(mesh.GetCornerIndicesAttr(), t)
    piece.cornerSharpness = floatValues(mesh.GetCornerSharpnessesAttr(), t)
    if piece.cornerIndices.count != piece.cornerSharpness.count
    {
      piece.cornerIndices = []
      piece.cornerSharpness = []
    }

    piece.holes = ints(mesh.GetHoleIndicesAttr(), t)
    if let attribute = prim.attribute(named: sharpEdgesName)
    {
      let pairs = ints(attribute, t)
      piece.sharp = Array(pairs.prefix(pairs.count - pairs.count % 2))
    }

    // per face materials from the mesh binding, overridden by each face set bound in the material family
    let base = materialPath(prim)
    piece.materials = [String](repeating: base, count: faces)
    
    var materialApi = UsdShade.MaterialBindingAPI(prim)
    for subset in materialApi.GetMaterialBindSubsets()
    {
      let material = materialPath(subset.GetPrim())
      for f in ints(subset.GetIndicesAttr(), t).map(Int.init) where f >= 0 && f < faces { piece.materials[f] = material }
    }

    return piece
  }

  /// the spread every piece's values can be written at without losing any of them
  nonisolated static func spread(of channels: [JoinPrimvar]) -> JoinSpread
  {
    let spreads = Set(channels.map(\.spread))
    if spreads.contains(.uniform) && spreads.contains(.vertex) { return .faceVarying }

    let top = spreads.max() ?? .constant
    if top == .constant, channels.contains(where: { $0.values != channels[0].values }) { return .uniform }
    return top
  }

  /// a piece's values spread out to a finer spread, in the joined corner order
  nonisolated static func expand(_ c: JoinPrimvar, to spread: JoinSpread, _ piece: JoinPiece) -> [Float]
  {
    let faces = piece.counts.count, points = piece.points.count, corners = piece.indices.count
    var slots: [Int]

    switch (spread, c.spread)
    {
      case (.constant, _):
        slots = [0]
      case (.uniform, .constant):
        slots = [Int](repeating: 0, count: faces)
      case (.uniform, _):
        slots = Array(0 ..< faces)
      case (.vertex, .constant):
        slots = [Int](repeating: 0, count: points)
      case (.vertex, _):
        slots = Array(0 ..< points)
      case (.faceVarying, .constant):
        slots = [Int](repeating: 0, count: corners)
      case (.faceVarying, .uniform):
        slots = []
        slots.reserveCapacity(corners)
        for (f, count) in piece.counts.enumerated() { slots += [Int](repeating: f, count: Int(count)) }
      case (.faceVarying, .vertex):
        slots = piece.indices.map(Int.init)
      case (.faceVarying, .faceVarying):
        slots = piece.corners
    }

    var out: [Float] = []
    out.reserveCapacity(slots.count * c.width)
    for s in slots { out += c.values[s * c.width ..< (s + 1) * c.width] }
    return out
  }

  nonisolated static func merge(_ channels: [JoinPrimvar], _ pieces: [JoinPiece]) -> JoinPrimvar
  {
    let spread = spread(of: channels)
    let width = channels[0].width
    guard spread != .constant else { return JoinPrimvar(values: channels[0].values, width: width, spread: .constant) }

    var values: [Float] = []
    for (c, piece) in zip(channels, pieces) { values += expand(c, to: spread, piece) }
    return JoinPrimvar(values: values, width: width, spread: spread)
  }

  /// what a mesh without a primvar shows for it, so filling the gap leaves it looking the same
  nonisolated static func fallback(_ name: String, width: Int) -> [Float]
  {
    switch name
    {
      case "displayOpacity": [Float](repeating: 1, count: width)
      case "displayColor": [Float](repeating: 0.5, count: width)
      default: [Float](repeating: 0, count: width)
    }
  }

  /// merges the selected meshes into the active one in its space, keeping every primvar value and each face's material
  nonisolated static func join(_ stage: UsdStage, _ paths: [String], active: String?, _ time: Double) -> JoinResult
  {
    let t = Pixar.UsdTimeCode(time)
    let roots = paths
      .filter { p in !paths.contains { $0 != p && within(p, $0) } }
      .compactMap { prim(stage, $0) }

    var meshes: [UsdPrim] = []
    var seen = Set<String>()
    for root in roots
    {
      for p in IteratorSequence(Pixar.UsdPrimRange(root, Pixar.UsdTraverseInstanceProxies())) where joinable(p, t)
      {
        if seen.insert(p.GetPath().string).inserted { meshes.append(p) }
      }
    }

    // the mesh everything joins into, which has to be one the department layer can edit on its own
    let owned = meshes.filter { !$0.IsInstanceProxy() }
    let activePath = active ?? ""
    guard let target = owned.first(where: { $0.GetPath().string == activePath })
      ?? owned.first(where: { within($0.GetPath().string, activePath) }) ?? owned.first
    else { return JoinResult(failed: true) }

    let targetPath = target.GetPath().string
    let sourcePaths = seen

    // a prim goes with the join when everything under it is joined, looks and lights keep their prim
    var memo: [String: Bool] = [:]
    func prunable(_ prim: UsdPrim) -> Bool
    {
      let path = prim.GetPath().string
      if let known = memo[path] { return known }

      var result = false
      if within(targetPath, path) { result = false }
      else if sourcePaths.contains(path) { result = true }
      else if ["Xform", "Scope", ""].contains(prim.typeName.string)
      {
        let children = joinChildren(prim)
        result = !children.isEmpty && children.allSatisfy(prunable)
      }

      memo[path] = result
      return result
    }

    var removals: [UsdPrim] = []
    func collect(_ prim: UsdPrim)
    {
      if prunable(prim) { removals.append(prim) }
      else { for child in joinChildren(prim) { collect(child) } }
    }

    for root in roots { collect(root) }

    // part of an instance can't be taken out of it without breaking the instance, so those meshes stay
    let removable = removals.filter { !$0.IsInstanceProxy() }.map { $0.GetPath().string }
    let sources = [target] + meshes.filter
    { m in
      let path = m.GetPath().string
      return path != targetPath && removable.contains { within(path, $0) }
    }

    guard sources.count > 1 else { return JoinResult(target: targetPath, failed: true) }

    var cache = Pixar.UsdGeomXformCache(t)
    let world = Kraken.Layout.matrix(rows(cache.GetLocalToWorldTransform(target)))
    var orientation = Tf.Token()
    _ = Pixar.UsdGeomMesh(target).GetOrientationAttr().Get(&orientation, t)
    let leftHanded = orientation.string == "leftHanded"

    var pieces: [JoinPiece] = []
    for source in sources
    {
      guard let piece = piece(source, into: world, identity: source.GetPath().string == targetPath, leftHanded: leftHanded, t, &cache)
      else { return JoinResult(target: targetPath, failed: true) }

      pieces.append(piece)
    }

    var points: [SIMD3<Float>] = [], counts: [Int32] = [], indices: [Int32] = []
    var creaseIndices: [Int32] = [], creaseSharpness: [Float] = []
    var cornerIndices: [Int32] = [], cornerSharpness: [Float] = []
    var holes: [Int32] = [], sharp: [Int32] = [], materials: [String] = []

    for piece in pieces
    {
      let v = Int32(points.count), f = Int32(counts.count)
      points += piece.points
      counts += piece.counts
      indices += piece.indices.map { $0 + v }
      creaseIndices += piece.creases.map { $0 + v }
      creaseSharpness += piece.creaseSharpness
      cornerIndices += piece.cornerIndices.map { $0 + v }
      cornerSharpness += piece.cornerSharpness
      holes += piece.holes.map { $0 + f }
      sharp += piece.sharp.map { $0 + v }
      materials += piece.materials
    }

    // a piece with no normals of its own gets the smooth ones it would shade with anyway
    var normals: JoinPrimvar?
    if pieces.contains(where: { $0.normals != nil })
    {
      normals = merge(pieces.map
      {
        $0.normals ?? JoinPrimvar(values: vertexNormals($0.points, $0.counts, $0.indices), width: 3, spread: .vertex)
      }, pieces)
    }

    var names: [String] = []
    for piece in pieces
    {
      for name in piece.primvars.keys.sorted() where !names.contains(name) { names.append(name) }
    }

    var merged: [(name: String, type: Pixar.SdfValueTypeName, channel: JoinPrimvar)] = []
    for name in names
    {
      let present = pieces.compactMap { $0.primvars[name] }
      guard let type = pieces.lazy.compactMap({ $0.types[name] }).first,
            let width = present.first?.width, present.allSatisfy({ $0.width == width })
      else { continue }

      let filled = pieces.map { $0.primvars[name] ?? JoinPrimvar(values: fallback(name, width: width), width: width, spread: .constant) }
      merged.append((name, type, merge(filled, pieces)))
    }

    let targetFaces = pieces[0].counts.count
    let wrote = Kraken.Authoring.edit(stage, targetPath)
    { prim, _ in
      var mesh = Pixar.UsdGeomMesh(prim)
      let time = Pixar.UsdTimeCode.Default()
      let p = vec3fArray(points)

      _ = mesh.GetPointsAttr().Set(p, time)
      _ = mesh.GetFaceVertexCountsAttr().Set(intArray(counts), time)
      _ = mesh.GetFaceVertexIndicesAttr().Set(intArray(indices), time)

      var extent = Pixar.VtVec3fArray()
      if Pixar.UsdGeomPointBased.ComputeExtent(p, &extent) { _ = mesh.GetExtentAttr().Set(extent, time) }

      // every primvar is written flat, so old indices and whatever didn't carry over are blocked
      let primvars = Pixar.UsdGeomPrimvarsAPI(prim)
      let kept = Set(merged.map(\.name))
      for primvar in primvars.GetPrimvars()
      {
        let name = primvar.GetPrimvarName().string
        if let lookup = prim.attribute(named: Tf.Token("primvars:\(name):indices")), lookup.HasAuthoredValue() { lookup.Block() }
        if name == "normals" || !kept.contains(name), let attribute = prim.attribute(named: Tf.Token("primvars:" + name)),
           attribute.HasAuthoredValue()
        {
          attribute.Block()
        }
      }

      for (name, type, channel) in merged
      {
        _ = primvars.CreatePrimvar(Tf.Token(name), type, channel.spread.token, -1)
        if let attribute = prim.attribute(named: Tf.Token("primvars:" + name))
        {
          setFloats(attribute, channel.values, width: channel.width)
        }
      }

      if let normals
      {
        setFloats(mesh.GetNormalsAttr(), normals.values, width: 3)
        _ = mesh.SetNormalsInterpolation(normals.spread.token)
      }
      else if mesh.GetNormalsAttr().HasAuthoredValue()
      {
        mesh.GetNormalsAttr().Block()
      }

      if !creaseSharpness.isEmpty || mesh.GetCreaseIndicesAttr().HasAuthoredValue()
      {
        _ = mesh.GetCreaseIndicesAttr().Set(intArray(creaseIndices), time)
        _ = mesh.GetCreaseLengthsAttr().Set(intArray([Int32](repeating: 2, count: creaseSharpness.count)), time)
        _ = mesh.GetCreaseSharpnessesAttr().Set(floatArray(creaseSharpness), time)
      }

      if !cornerSharpness.isEmpty || mesh.GetCornerIndicesAttr().HasAuthoredValue()
      {
        _ = mesh.GetCornerIndicesAttr().Set(intArray(cornerIndices), time)
        _ = mesh.GetCornerSharpnessesAttr().Set(floatArray(cornerSharpness), time)
      }

      if !holes.isEmpty || mesh.GetHoleIndicesAttr().HasAuthoredValue()
      {
        _ = mesh.GetHoleIndicesAttr().Set(intArray(holes), time)
      }

      if let edges = prim.attribute(named: sharpEdgesName) ?? (sharp.isEmpty ? nil : prim.createAttribute(name: sharpEdgesName, typeName: .intArray))
      {
        _ = edges.Set(intArray(sharp), time)
      }

      bindFaces(stage, prim, materials, from: targetFaces, t)
      return true
    }

    guard wrote else { return JoinResult(target: targetPath, failed: true) }

    // joined prims the department made alone are deleted, ones from other layers or references are deactivated instead
    for path in removable { remove(stage, path) }

    return JoinResult(target: targetPath, joined: sources.count, removed: removable)
  }

  /// binds the joined faces from `start` on to their old materials through face sets, skipping ones matching the mesh's own
  nonisolated static func bindFaces(_ stage: UsdStage, _ prim: UsdPrim, _ materials: [String], from start: Int,
                                    _ t: Pixar.UsdTimeCode)
  {
    var binding = Pixar.UsdShadeMaterialBindingAPI(prim)
    let subsets = Array(binding.GetMaterialBindSubsets())
    let base = materialPath(prim)

    var groups: [String: [Int32]] = [:]
    var order: [String] = []
    for f in start ..< materials.count
    {
      let material = materials[f]
      guard !material.isEmpty, !(subsets.isEmpty && material == base) else { continue }

      if groups[material] == nil { order.append(material) }
      groups[material, default: []].append(Int32(f))
    }

    for material in order
    {
      guard let faces = groups[material] else { continue }

      if let subset = subsets.first(where: { materialPath($0.GetPrim()) == material })
      {
        let indices = subset.GetIndicesAttr()
        _ = indices.Set(intArray(ints(indices, t) + faces), Pixar.UsdTimeCode.Default())
        continue
      }

      let name = uniqueChild(stage, prim.GetPath(), String(material.split(separator: "/").last ?? "Material"))
      let subset = binding.CreateMaterialBindSubset(Tf.Token(String(name.string.split(separator: "/").last ?? "")),
                                                    intArray(faces), Tf.Token("face"))
      _ = UsdShade.MaterialBindingAPI.apply(subset.GetPrim()).bind(Pixar.UsdShadeMaterial(stage.GetPrimAtPath(Sdf.Path(material))))
    }
  }
}
