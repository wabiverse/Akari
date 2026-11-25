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
  /// casts rays against what the scene draws, meshes by triangle and other gprims by bounds, reading each mesh only once a ray reaches it
  final class SceneRaycast: @unchecked Sendable
  {
    struct Hit: Sendable
    {
      var point: SIMD3<Double>
      var normal: SIMD3<Double>
      /// the gprim hit, empty for the ground plane
      var path: String
      /// the world bounds of what was hit
      var lo: SIMD3<Double>
      var hi: SIMD3<Double>
    }

    private struct Target
    {
      var path: String
      var lo: SIMD3<Double>
      var hi: SIMD3<Double>
      var mesh: Bool
    }

    private var targets: [Target] = []
    private var triangles: [String: [SIMD3<Double>]] = [:]
    private let time: Pixar.UsdTimeCode
    let up: SIMD3<Double>

    init(_ stage: UsdStage, time: Double)
    {
      self.time = Pixar.UsdTimeCode(time)
      up = UsdGeom.getUpAxis(for: stage) == .z ? SIMD3(0, 0, 1) : SIMD3(0, 1, 0)
      var boxes = SceneEdit.bboxCache(self.time)
      func visit(_ prim: UsdPrim)
      {
        for child in OutlinerScan.children(prim)
        {
          if child.isA(.imageable), Pixar.UsdGeomImageable(child).ComputeVisibility(self.time) == .invisible { continue }
          if child.isA(.gprim)
          {
            let range = boxes.ComputeWorldBound(child).ComputeAlignedRange()
            guard !range.IsEmpty() else { continue }
            #if compiler(>=6.4) && canImport(Usd)
              let lo = SceneEdit.numbers(range.GetMinConsuming()), hi = SceneEdit.numbers(range.GetMaxConsuming())
            #else
              let lo = SceneEdit.numbers(range.GetMin()), hi = SceneEdit.numbers(range.GetMax())
            #endif
            targets.append(Target(path: child.GetPath().string, lo: SIMD3(lo[0], lo[1], lo[2]), hi: SIMD3(hi[0], hi[1], hi[2]),
                                  mesh: child.isA(.mesh)))
            continue
          }

          visit(child)
        }
      }

      visit(stage.GetPseudoRoot())
    }

    /// the nearest surface along the ray, skipping what's under `excluding`, else the ground plane in front of it
    func cast(_ stage: UsdStage, _ origin: SIMD3<Double>, _ direction: SIMD3<Double>, excluding: String? = nil,
              ground: Bool = true) -> Hit?
    {
      let inverse = SIMD3(1 / direction.x, 1 / direction.y, 1 / direction.z)
      var candidates: [(t: Double, index: Int)] = []
      for (i, target) in targets.enumerated()
      {
        if let excluding, SceneEdit.within(target.path, excluding) { continue }
        let a = (target.lo - origin) * inverse, b = (target.hi - origin) * inverse
        let near = simd_min(a, b).max(), far = simd_max(a, b).min()
        if far >= max(near, 0) { candidates.append((max(near, 0), i)) }
      }

      candidates.sort { $0.t < $1.t }
      var best: Hit?
      var bestT = Double.infinity
      for candidate in candidates where candidate.t < bestT
      {
        let target = targets[candidate.index]
        if target.mesh
        {
          let soup = triangles[target.path] ?? load(stage, target.path)
          var i = 0
          while i + 2 < soup.count
          {
            if let t = Self.intersect(origin, direction, soup[i], soup[i + 1], soup[i + 2]), t < bestT
            {
              bestT = t
              var n = simd_normalize(simd_cross(soup[i + 1] - soup[i], soup[i + 2] - soup[i]))
              if simd_dot(n, direction) > 0 { n = -n }
              best = Hit(point: origin + direction * t, normal: n, path: target.path, lo: target.lo, hi: target.hi)
            }

            i += 3
          }
        }
        else
        {
          // other gprims are hit on their bounds, the face the ray enters through giving the normal
          let a = (target.lo - origin) * inverse, b = (target.hi - origin) * inverse
          let lows = simd_min(a, b)
          let t = lows.max()
          guard t > 0, t < bestT else { continue }
          let axis = lows.x == t ? 0 : lows.y == t ? 1 : 2
          var n = SIMD3<Double>.zero
          n[axis] = direction[axis] > 0 ? -1 : 1
          bestT = t
          best = Hit(point: origin + direction * t, normal: n, path: target.path, lo: target.lo, hi: target.hi)
        }
      }

      if best == nil, ground, let t = Self.plane(origin, direction, up)
      {
        let p = origin + direction * t
        best = Hit(point: p, normal: up, path: "", lo: p, hi: p)
      }

      return best
    }

    /// the mesh's world space triangles, fanned from each face's first corner
    private func load(_ stage: UsdStage, _ path: String) -> [SIMD3<Double>]
    {
      var soup: [SIMD3<Double>] = []
      defer { triangles[path] = soup }
      let prim = stage.GetPrimAtPath(Sdf.Path(path))
      guard prim.isValid else { return soup }
      let mesh = Pixar.UsdGeomMesh(prim)
      var points = Pixar.VtVec3fArray(), counts = Pixar.VtIntArray(), indices = Pixar.VtIntArray()
      guard mesh.GetPointsAttr().Get(&points, time), mesh.GetFaceVertexCountsAttr().Get(&counts, time),
            mesh.GetFaceVertexIndicesAttr().Get(&indices, time),
            let xyz: UnsafePointer<Pixar.GfVec3f> = Overlay.cdata(points),
            let faceCounts: UnsafePointer<Int32> = Overlay.cdata(counts),
            let faceIndices: UnsafePointer<Int32> = Overlay.cdata(indices)
      else { return soup }

      var cache = Pixar.UsdGeomXformCache(time)
      let world = Layout.matrix(SceneEdit.rows(cache.GetLocalToWorldTransform(prim)))
      let raw = UnsafeRawPointer(xyz).assumingMemoryBound(to: Float.self)
      let pointCount = points.size()
      let placed = (0 ..< pointCount).map
      { i -> SIMD3<Double> in
        let p = world * SIMD4(Double(raw[i * 3]), Double(raw[i * 3 + 1]), Double(raw[i * 3 + 2]), 1)
        return SIMD3(p.x, p.y, p.z)
      }

      var offset = 0
      let indexCount = indices.size()
      soup.reserveCapacity(indexCount * 3)
      for f in 0 ..< counts.size()
      {
        let count = Int(faceCounts[f])
        defer { offset += count }
        guard count >= 3, offset + count <= indexCount else { continue }
        let first = Int(faceIndices[offset])
        for k in 1 ..< count - 1
        {
          let b = Int(faceIndices[offset + k]), c = Int(faceIndices[offset + k + 1])
          guard first < pointCount, b < pointCount, c < pointCount else { continue }
          soup += [placed[first], placed[b], placed[c]]
        }
      }

      return soup
    }

    /// where a ray meets a triangle, its distance along the ray
    static func intersect(_ o: SIMD3<Double>, _ d: SIMD3<Double>, _ a: SIMD3<Double>, _ b: SIMD3<Double>,
                          _ c: SIMD3<Double>) -> Double?
    {
      let e1 = b - a, e2 = c - a
      let p = simd_cross(d, e2)
      let det = simd_dot(e1, p)
      guard abs(det) > 1e-14 else { return nil }
      let inv = 1 / det
      let s = o - a
      let u = simd_dot(s, p) * inv
      guard u >= 0, u <= 1 else { return nil }
      let q = simd_cross(s, e1)
      let v = simd_dot(d, q) * inv
      guard v >= 0, u + v <= 1 else { return nil }
      let t = simd_dot(e2, q) * inv
      return t > 1e-9 ? t : nil
    }

    /// where a ray meets the plane through the origin facing `normal`, in front of it
    static func plane(_ o: SIMD3<Double>, _ d: SIMD3<Double>, _ normal: SIMD3<Double>) -> Double?
    {
      let denominator = simd_dot(d, normal)
      guard abs(denominator) > 1e-9 else { return nil }
      let t = -simd_dot(o, normal) / denominator
      return t > 0 ? t : nil
    }
  }

  /// where a dropped asset goes: how it turns to stand, hang or lie on the surface under the pointer.
  enum AssetPlace
  {
    static func rotation(x angle: Double) -> simd_double4x4
    {
      let c = cos(angle), s = sin(angle)
      return simd_double4x4(columns: (SIMD4(1, 0, 0, 0), SIMD4(0, c, s, 0), SIMD4(0, -s, c, 0), SIMD4(0, 0, 0, 1)))
    }

    static func translation(_ t: SIMD3<Double>) -> simd_double4x4
    {
      var m = matrix_identity_double4x4
      m.columns.3 = SIMD4(t, 1)
      return m
    }

    /// a rotation taking the columns of `from` onto the columns of `to`, both orthonormal frames
    static func turn(from: simd_double3x3, to: simd_double3x3) -> simd_double4x4
    {
      let r = to * from.transpose
      return simd_double4x4(columns: (SIMD4(r.columns.0, 0), SIMD4(r.columns.1, 0), SIMD4(r.columns.2, 0), SIMD4(0, 0, 0, 1)))
    }

    /// the scene's own side, up and front, the way an asset authored for it faces
    static func frame(zUp: Bool) -> simd_double3x3
    {
      zUp ? simd_double3x3(columns: (SIMD3(1, 0, 0), SIMD3(0, 0, 1), SIMD3(0, -1, 0)))
        : simd_double3x3(columns: (SIMD3(1, 0, 0), SIMD3(0, 1, 0), SIMD3(0, 0, 1)))
    }

    /// the asset turned upright for the scene and scaled to its units, about the asset's own origin
    static func conform(_ asset: LibraryAsset, zUp: Bool, metersPerUnit: Double) -> simd_double4x4
    {
      let s = asset.metersPerUnit / max(metersPerUnit, 1e-12)
      var scale = matrix_identity_double4x4
      scale.columns.0.x = s
      scale.columns.1.y = s
      scale.columns.2.z = s
      let upright = asset.isZUp == zUp ? matrix_identity_double4x4 : rotation(x: zUp ? .pi / 2 : -.pi / 2)
      return scale * upright
    }

    /// the asset's bounds once conformed, in the scene's axes
    static func bounds(_ asset: LibraryAsset, _ conformed: simd_double4x4) -> (lo: SIMD3<Double>, hi: SIMD3<Double>)
    {
      var lo = SIMD3(repeating: Double.infinity), hi = -lo
      let a = asset.lo, b = asset.hi
      for i in 0 ..< 8
      {
        let corner = SIMD3(i & 1 == 0 ? a.x : b.x, i & 2 == 0 ? a.y : b.y, i & 4 == 0 ? a.z : b.z)
        let p = conformed * SIMD4(corner, 1)
        lo = simd_min(lo, SIMD3(p.x, p.y, p.z))
        hi = simd_max(hi, SIMD3(p.x, p.y, p.z))
      }

      return (lo, hi)
    }

    /// a unit direction in the ground plane, `toward` flattened, else `fallback`
    static func flat(_ toward: SIMD3<Double>, up: SIMD3<Double>, fallback: SIMD3<Double>) -> SIMD3<Double>
    {
      let d = toward - up * simd_dot(toward, up)
      return simd_length(d) > 1e-6 ? simd_normalize(d) : fallback
    }

    /// turns `front` about `up` to the nearest eighth of a turn
    static func snapped(_ front: SIMD3<Double>, up: SIMD3<Double>, base: SIMD3<Double>) -> SIMD3<Double>
    {
      let side = simd_cross(up, base)
      let angle = atan2(simd_dot(front, side), simd_dot(front, base))
      let step = Double.pi / 4
      let a = (angle / step).rounded() * step
      return base * cos(a) + side * sin(a)
    }

    /// the world transform for `asset` dropped on `hit`, seen from `eye`, `below` finding the floor under a point
    static func matrix(_ asset: LibraryAsset, hit: SceneRaycast.Hit, eye: SIMD3<Double>, zUp: Bool, metersPerUnit: Double,
                       below: (SIMD3<Double>) -> SceneRaycast.Hit?) -> simd_double4x4
    {
      let conformed = conform(asset, zUp: zUp, metersPerUnit: metersPerUnit)
      let box = bounds(asset, conformed)
      let canonical = frame(zUp: zUp)
      let up = canonical.columns.1, front = canonical.columns.2
      let mid = (box.lo + box.hi) / 2

      // the bottom center, the side the scene's up comes out of turned under
      let base = mid - up * simd_dot(mid - box.lo, up)
      let n = simd_normalize(hit.normal)
      let facing = flat(eye - hit.point, up: up, fallback: front)

      switch asset.placement
      {
        case .wall:
          // its back on the surface, its front out along the normal and its up as close to the scene's as the wall lets it
          let back = mid - front * simd_dot(mid - box.lo, front) * (simd_dot(front, box.hi - box.lo) >= 0 ? 1 : -1)
          var upward = up - n * simd_dot(up, n)
          upward = simd_length(upward) > 1e-3 ? simd_normalize(upward) : facing
          let side = simd_cross(upward, n)
          let turn = turn(from: canonical, to: simd_double3x3(columns: (side, upward, n)))
          return translation(hit.point) * turn * translation(-back) * conformed
        case .surface:
          let ahead = flat(facing, up: n, fallback: simd_cross(SIMD3(1, 0, 0), n))
          let side = simd_cross(n, ahead)
          let turn = turn(from: canonical, to: simd_double3x3(columns: (side, n, ahead)))
          return translation(hit.point) * turn * translation(-base) * conformed
        case .floor:
          var point = hit.point
          var ahead = snapped(facing, up: up, base: front)
          if simd_dot(n, up) < 0.6, !hit.path.isEmpty
          {
            // dropped on a wall it backs onto the wall facing out, standing on the floor below
            ahead = flat(n, up: up, fallback: facing)
            let depth = simd_dot(box.hi - box.lo, SIMD3(abs(front.x), abs(front.y), abs(front.z)))
            point = hit.point + ahead * depth * 0.52
            if let floor = below(point + up * simd_dot(box.hi - box.lo, up) * 0.01) { point = floor.point }
          }

          let side = simd_cross(up, ahead)
          let turn = turn(from: canonical, to: simd_double3x3(columns: (side, up, ahead)))
          return translation(point) * turn * translation(-base) * conformed
      }
    }
  }
}

// MARK: authoring

extension Kraken.SceneEdit
{
  /// `file` as an asset path from the layer `from`, relative when they share a folder above them
  nonisolated static func assetPath(_ file: String, from layer: SdfLayerHandle) -> String
  {
    guard !layer.pointee.IsAnonymous() else { return file }
    let home = URL(fileURLWithPath: Kraken.Authoring.identifier(layer)).deletingLastPathComponent().standardizedFileURL.pathComponents
    let target = URL(fileURLWithPath: file).standardizedFileURL.pathComponents
    var shared = 0
    while shared < home.count, shared < target.count, home[shared] == target[shared] { shared += 1 }

    // only the root in common, an absolute path reads better
    guard shared > 1 else { return file }
    let ups = home.count - shared
    let rest = target[shared...].joined(separator: "/")
    return ups == 0 ? "./" + rest : String(repeating: "../", count: ups) + rest
  }

  /// a new prim in the department layer referencing `asset`, placed at `world`, giving its path
  nonisolated static func placeAsset(_ stage: UsdStage, _ asset: Kraken.LibraryAsset, world: simd_double4x4) -> String
  {
    let home = stage.GetDefaultPrim()
    let nested = home.isValid && home.isA(.xformable) && !home.isInstance && !home.IsInstanceProxy()
    let parent: Pixar.SdfPath = nested ? home.GetPath() : Sdf.Path.absoluteRootPath()
    let path = uniqueChild(stage, parent, asset.primName)

    return Kraken.Authoring.inDepartment(stage, for: path)
    { () -> String in
      // typeless, so the asset's own root type comes through the reference
      let prim = stage.DefinePrim(path, Tf.Token())
      var references = prim.getReferences()
      let file = assetPath(asset.file, from: Kraken.Authoring.department(stage))
      if asset.prim.isEmpty { references.addReference(assetPath: file) }
      else { references.addReference(assetPath: file, primPath: Sdf.Path(asset.prim)) }
      if asset.instanceable { _ = prim.SetInstanceable(true) }
      adoptLegacyBindings(stage, under: prim)
      guard prim.isA(.xformable) else { return path.string }

      var local = world
      if nested
      {
        var cache = Pixar.UsdGeomXformCache(Pixar.UsdTimeCode.Default())
        local = Kraken.Layout.matrix(rows(cache.GetLocalToWorldTransform(home))).inverse * world
      }

      // the placement replaces whatever transform the asset's root carries
      let xformable = Pixar.UsdGeomXformable(prim)
      _ = xformable.ClearXformOpOrder()
      _ = xformable.addXformOp(type: .transform, precision: .double).Set(matrix(Kraken.Layout.array(local)), Pixar.UsdTimeCode.Default())
      return path.string
    }
  }

  /// a prim's bounds in its own space, min then max, nil when it draws nothing
  nonisolated static func localBounds(_ stage: UsdStage, _ path: String, _ time: Double) -> [Double]?
  {
    guard let prim = prim(stage, path) else { return nil }
    var cache = bboxCache(Pixar.UsdTimeCode(time))
    let range = cache.ComputeUntransformedBound(prim).ComputeAlignedRange()
    guard !range.IsEmpty() else { return nil }
    #if compiler(>=6.4) && canImport(Usd)
      return numbers(range.GetMinConsuming()) + numbers(range.GetMaxConsuming())
    #else
      return numbers(range.GetMin()) + numbers(range.GetMax())
    #endif
  }

  /// moves a placed asset to `world`
  nonisolated static func movePlaced(_ stage: UsdStage, _ path: String, world: simd_double4x4, _ time: Double)
  {
    guard let placed = transform(stage, path, time) else { return }
    setTransform(stage, path, Kraken.Layout.array(Kraken.Layout.matrix(placed.parent).inverse * world))
  }

  /// letters and digits only, lowercased, so `Painted Teal` matches `PaintedTeal`
  nonisolated static func lookKey(_ name: String) -> String
  {
    String(name.lowercased().filter { $0.isLetter || $0.isNumber })
  }

  /// the material for `asset` in the scene, a prim in the looks scope referencing it, made when not there yet
  nonisolated static func referenceMaterial(_ stage: UsdStage, _ asset: Kraken.LibraryAsset) -> String
  {
    let home = stage.GetDefaultPrim()
    let owner: Pixar.SdfPath = home.isValid && !home.isInstance ? home.GetPath() : Sdf.Path.absoluteRootPath()
    let scope = owner.AppendChild(Tf.Token("Looks"))
    let file = assetPath(asset.file, from: Kraken.Authoring.department(stage))
    let existing = scope.AppendChild(Tf.Token(String(asset.primName.map { $0.isLetter || $0.isNumber || $0 == "_" ? $0 : "_" })))
    let found = stage.GetPrimAtPath(existing)
    if found.isValid, found.isA(.material), found.HasAuthoredReferences() { return existing.string }

    return Kraken.Authoring.inDepartment(stage, for: scope)
    { () -> String in
      if !stage.GetPrimAtPath(scope).isValid { _ = stage.DefinePrim(scope, .scope) }
      let path = uniqueChild(stage, scope, asset.primName)
      var references = stage.DefinePrim(path, .material).getReferences()
      references.addReference(assetPath: file, primPath: Sdf.Path(asset.prim))
      return path.string
    }
  }

  /// removes the bindings a drop authored at and below `path` from the department layer so variants can switch the look again
  nonisolated static func clearBindings(_ stage: UsdStage, under path: String)
  {
    guard let root = prim(stage, path), !root.IsInstanceProxy() else { return }
    let name = Tf.Token("material:binding")
    var prims = [root]
    while let prim = prims.popLast()
    {
      if prim.GetRelationship(name).IsValid()
      {
        var bound = prim
        Kraken.Authoring.inDepartment(stage, for: prim.GetPath()) { _ = bound.RemoveProperty(name) }
      }

      // what's inside an instance belongs to its prototype, the instance itself is the only place a drop binds
      if !prim.isInstance { prims += Kraken.OutlinerScan.children(prim).filter { !$0.IsInstanceProxy() } }
    }
  }

  /// puts a dropped material on what it hit, the matching shading variant if there is one, else the material bound over the prim or its instance
  nonisolated static func applyMaterial(_ stage: UsdStage, _ asset: Kraken.LibraryAsset, to hitPath: String) -> String
  {
    let object = object(for: hitPath, stage)
    let keys: Set<String> = [lookKey(asset.primName), lookKey(asset.name)]
    for set in variantSets(stage, object) where Kraken.AssetScan.shadingSet(set.name)
    {
      if let variant = set.variants.first(where: { keys.contains(lookKey($0)) })
      {
        clearBindings(stage, under: object)
        selectVariant(stage, object, set: set.name, variant: variant)
        return "\(object.split(separator: "/").last ?? "") \(set.name) set to \(variant)"
      }
    }

    let materialPath = referenceMaterial(stage, asset)
    let material = Pixar.UsdShadeMaterial(stage.GetPrimAtPath(Sdf.Path(materialPath)))

    // a part of an instance can't take its own binding, so the instance a drop customizes stops being one and the part takes it
    let instance = hit(for: hitPath, stage)
    if instance != hitPath, let root = prim(stage, instance)
    {
      setInstanceable(stage, instance, false)

      // a binding an earlier drop put over the whole instance would still win over the part's own
      var bound = root
      Kraken.Authoring.inDepartment(stage, for: root.GetPath()) { _ = bound.RemoveProperty(Tf.Token("material:binding")) }
    }
    let target = prim(stage, hitPath).map { $0.IsInstanceProxy() ? instance : hitPath } ?? instance
    let bound = Kraken.Authoring.edit(stage, target)
    { prim, _ in
      guard !prim.IsInstanceProxy() else { return false }
      return UsdShade.MaterialBindingAPI.apply(prim).bind(material)
    }

    let name = target.split(separator: "/").last ?? ""
    return bound ? "\(asset.name) bound to \(name)" : "Couldn't bind \(asset.name) to \(name)"
  }
}

// MARK: the drop session

extension Kraken
{
  /// one asset dragged into the viewport, a model follows the surface and a material shows what it lands on, the drop is one undo step
  @MainActor
  final class AssetDrop
  {
    /// what the frame queue keeps between a drag's casts
    private final class Shared: @unchecked Sendable
    {
      var raycast: SceneRaycast?
      var path: String?
      var start = 0
      /// the asset's bounds measured once placed, for an asset that didn't author its extents
      var bounds: [Double]?
    }

    var asset: LibraryAsset?
    /// what the drop is about to do, shown by the pointer
    var caption = ""
    var point = CGPoint.zero
    var hit: SceneRaycast.Hit?
    var placed: simd_double4x4?
    var finished = false
    /// the pointer was let go, waiting on the asset when a dropped file is still being read
    private(set) var released = false

    private let layout: Layout
    private let shared = Shared()
    private let writer = Layout.Writer()
    private var began = false
    weak var view: LayoutView?

    init(layout: Layout, asset: LibraryAsset?)
    {
      self.layout = layout
      self.asset = asset
      caption = asset.map(\.name) ?? "Reading…"
    }

    /// starts once the asset is known, a step for undo and the scene snapshot for the casts
    func begin()
    {
      guard let asset, !began, !finished else { return }
      began = true
      if layout.mode == .edit { layout.exitEdit() }
      if asset.kind == .model { layout.checkpoint() }
      let time = layout.hydra.currentTimeCode
      let shared = shared
      layout.onStage
      { stage in
        shared.start = Int(Pixar.HdAkariJournalPosition())
        shared.raycast = SceneRaycast(stage, time: time)
      }

      if let view { move(to: point, in: view) }
    }

    /// follows the pointer, at `point` in the viewport's top down coordinates
    func move(to point: CGPoint, in view: LayoutView)
    {
      self.point = point
      self.view = view
      guard began, let asset, let camera = view.camera else { return }
      let ray = camera.ray(point)
      let eye = camera.eye
      let zUp = layout.isZUp, units = layout.metersPerUnit, time = layout.hydra.currentTimeCode
      let shared = shared
      writer.submit(layout.hydra)
      { stage in
        guard let raycast = shared.raycast else { return }
        let hit = raycast.cast(stage, ray.origin, ray.direction, excluding: shared.path)
        var world: simd_double4x4?
        var created: String?
        var sized = asset
        if sized.bounds.count != 6, let measured = shared.bounds { sized.bounds = measured }
        if let hit, asset.kind == .model
        {
          if shared.path == nil, sized.bounds.count != 6
          {
            // a kit asset keeps its geometry in a payload, so its size is known once it's in the scene
            let path = SceneEdit.placeAsset(stage, asset, world: AssetPlace.translation(hit.point))
            shared.path = path
            created = path
            let measured = SceneEdit.localBounds(stage, path, time) ?? [-0.5, 0, -0.5, 0.5, 1, 0.5]
            shared.bounds = measured
            sized.bounds = measured
          }

          let m = AssetPlace.matrix(sized, hit: hit, eye: eye, zUp: zUp, metersPerUnit: units)
          { p in raycast.cast(stage, p, -raycast.up, excluding: shared.path, ground: true) }
          world = m
          if let path = shared.path { SceneEdit.movePlaced(stage, path, world: m, time) }
          else
          {
            let path = SceneEdit.placeAsset(stage, asset, world: m)
            shared.path = path
            created = path
          }
        }

        nonisolated(unsafe) let placed = world
        let bounds = sized.bounds
        DispatchQueue.main.async
        { [weak self] in
          guard let self, !self.finished else { return }
          self.hit = hit
          self.placed = placed
          if bounds.count == 6 { self.asset?.bounds = bounds }
          if created != nil { self.layout.primsChanged() }
          self.caption = self.describe(hit)
          self.view?.invalidate()
        }
      }
    }

    private func describe(_ hit: SceneRaycast.Hit?) -> String
    {
      guard let asset else { return "Reading…" }
      guard let hit else { return asset.name }
      let on = hit.path.isEmpty ? "Ground" : String(hit.path.split(separator: "/").last ?? "")
      if asset.kind == .material { return hit.path.isEmpty ? "\(asset.name), drop on an object" : "\(asset.name) on \(on)" }
      return "\(asset.name) on \(on)"
    }

    /// the pointer let go over the viewport, the drop lands now or once its asset is read
    func release()
    {
      released = true
      if began { drop() }
    }

    /// lands the asset where it is now
    func drop()
    {
      guard let asset, began, !finished else
      {
        cancel()
        return
      }

      finished = true
      let layout = layout
      let shared = shared
      switch asset.kind
      {
        case .model:
          layout.onStage
          { _ in
            let path = shared.path
            DispatchQueue.main.async
            {
              guard let path else
              {
                layout.status = "Nothing under the pointer to place \(asset.name) on"
                return
              }

              layout.primsChanged()
              layout.select([path])
              layout.status = "Placed \(asset.name)"
            }
          }
        case .material:
          guard let target = hit?.path, !target.isEmpty else
          {
            layout.status = "Drop \(asset.name) on an object"
            return
          }

          layout.checkpoint()
          layout.onStage
          { stage in
            let result = SceneEdit.applyMaterial(stage, asset, to: target)
            DispatchQueue.main.async
            {
              layout.status = result
              layout.primsChanged()
              layout.inspector.reload()
            }
          }
      }

      view?.invalidate()
    }

    /// takes back everything the drag did, the drag left the viewport or was let go of nowhere
    func cancel()
    {
      // a drop that already landed stays, the next drag cancels whatever drop came before it
      guard !finished else { return }
      let wasBegun = began && asset?.kind == .model
      finished = true
      view?.invalidate()
      guard wasBegun else { return }
      let layout = layout
      let shared = shared
      layout.onStage
      { _ in
        let created = shared.path != nil
        if created { Pixar.HdAkariJournalSeek(shared.start) }
        let start = String(shared.start)
        DispatchQueue.main.async
        {
          if layout.undoStack.last?.text == start { layout.undoStack.removeLast() }
          if created { layout.primsChanged() }
        }
      }
    }
  }
}

extension Kraken.Layout
{
  /// places a library asset under the middle of the viewport, or puts a material on the active object, for a tap or double click
  func use(_ asset: Kraken.LibraryAsset)
  {
    guard let view = viewport else { return }
    if asset.kind == .material
    {
      guard let target = active else
      {
        status = "Select an object to put \(asset.name) on"
        return
      }

      checkpoint()
      onStage
      { [self] stage in
        let result = Kraken.SceneEdit.applyMaterial(stage, asset, to: target)
        DispatchQueue.main.async
        {
          self.status = result
          self.primsChanged()
          self.inspector.reload()
        }
      }

      return
    }

    let drop = Kraken.AssetDrop(layout: self, asset: asset)
    drop.view = view
    drop.point = CGPoint(x: view.bounds.midX, y: view.bounds.midY)
    drop.begin()
    drop.drop()
  }
}
