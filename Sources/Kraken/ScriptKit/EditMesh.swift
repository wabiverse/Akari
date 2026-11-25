import Foundation

/// a mesh in edit mode in world space
public final class EditMesh
{
  public struct Face: Hashable, Sendable
  {
    public let index: Int
    public let verts: [Int]
    public let center: Vec3
    public let normal: Vec3

    /// side faces of a z cylinder
    public var isSide: Bool { normal.z.magnitude < 0.2 }
    public var isTop: Bool { normal.z > 0.8 }
    public var isBottom: Bool { normal.z < -0.8 }
  }

  public enum Element: String, Sendable
  {
    case verts, edges, faces
  }

  public enum SelectMode: String, Sendable
  {
    case vertex, edge, face
  }

  public enum MergeTarget: Sendable
  {
    case center, cursor, distance(Double)
  }

  public let path: String
  public private(set) var points: [Vec3] = []
  public private(set) var faces: [Face] = []
  public private(set) var edges: [(Int, Int)] = []
  public private(set) var selectedFaces: [Face] = []
  public private(set) var selectedVerts: Set<Int> = []

  init(_ snapshot: [String: Any])
  {
    path = snapshot["path"] as? String ?? ""
    read(snapshot)
  }

  private func read(_ snapshot: [String: Any])
  {
    func vec(_ any: Any?) -> Vec3
    {
      let a = (any as? [Any])?.compactMap { ($0 as? Double) ?? ($0 as? Int).map(Double.init) } ?? []
      return a.count == 3 ? Vec3(a[0], a[1], a[2]) : .zero
    }

    points = (snapshot["points"] as? [Any] ?? []).map(vec)
    faces = (snapshot["faces"] as? [[String: Any]] ?? []).enumerated().map
    { i, f in
      Face(index: i, verts: f["verts"] as? [Int] ?? [], center: vec(f["center"]), normal: vec(f["normal"]))
    }

    edges = (snapshot["edges"] as? [[Int]] ?? []).map { ($0[0], $0[1]) }
    let chosen = snapshot["selectedFaces"] as? [Int] ?? []
    selectedFaces = chosen.filter { $0 < faces.count }.map { faces[$0] }
    selectedVerts = Set(snapshot["selectedVerts"] as? [Int] ?? [])
  }

  @discardableResult
  private func op(_ name: String, _ args: [String: Any] = [:]) -> Self
  {
    var args = args
    args["op"] = name
    read(Connection.shared.call("mesh.op", args) as? [String: Any] ?? [:])
    return self
  }

  /// middle of the selection
  public var selectionCenter: Vec3
  {
    selectedVerts.isEmpty ? .zero : selectedVerts.reduce(Vec3.zero) { $0 + points[$1] } / Double(selectedVerts.count)
  }

  /// 1 2 3
  public var selectMode: SelectMode = .vertex
  {
    didSet { op("mode", ["mode": selectMode.rawValue]) }
  }

  /// selects faces
  @discardableResult
  public func select(_ faces: some Sequence<Face>, extend: Bool = false) -> Self
  {
    read(Connection.shared.call("mesh.select", ["faces": faces.map(\.index), "extend": extend]) as? [String: Any] ?? [:])
    return self
  }

  /// selects faces that pass
  @discardableResult
  public func select(extend: Bool = false, where test: (Face) -> Bool) -> Self
  {
    select(faces.filter(test), extend: extend)
  }

  /// selects verts that pass
  @discardableResult
  public func selectVerts(extend: Bool = false, where test: (Int, Vec3) -> Bool) -> Self
  {
    let chosen = points.indices.filter { test($0, points[$0]) }
    read(Connection.shared.call("mesh.select", ["verts": chosen, "extend": extend]) as? [String: Any] ?? [:])
    return self
  }

  /// a
  @discardableResult
  public func selectAll() -> Self
  {
    read(Connection.shared.call("mesh.select", ["all": true]) as? [String: Any] ?? [:])
    return self
  }

  /// alt a
  @discardableResult
  public func deselectAll() -> Self
  {
    read(Connection.shared.call("mesh.select", [:]) as? [String: Any] ?? [:])
    return self
  }

  /// ctrl i
  @discardableResult
  public func invertSelection() -> Self { op("invert") }

  /// ctrl l
  @discardableResult
  public func selectLinked() -> Self { op("linked") }

  /// keeps every other face
  @discardableResult
  public func checkerDeselect() -> Self { op("checker") }

  /// e along the normal or left in place
  @discardableResult
  public func extrude(_ distance: Double? = nil) -> Self
  {
    op("extrude", distance.map { ["distance": $0] } ?? [:])
  }

  /// i
  @discardableResult
  public func inset(_ amount: Double) -> Self { op("inset", ["amount": amount]) }

  /// ctrl r through a point
  @discardableResult
  public func loopCut(through point: Vec3) -> Self
  {
    op("loopcut", ["through": json(point)])
  }

  /// ctrl r on the nearest edge
  @discardableResult
  public func loopCut(near point: Vec3, at t: Double = 0.5) -> Self
  {
    op("loopcut", ["near": json(point), "at": t])
  }

  @discardableResult
  public func subdivide() -> Self { op("subdivide") }

  /// shift e, how hard subdivision holds the selected edges, 0 smooth to 1 a hard edge
  @discardableResult
  public func crease(_ value: Double = 1) -> Self { op("crease", ["value": value]) }

  /// splits the shading normals along the selected edges
  @discardableResult
  public func markSharp() -> Self { op("sharp", ["on": true]) }

  @discardableResult
  public func clearSharp() -> Self { op("sharp", ["on": false]) }

  /// selects the edges whose two faces meet at more than `angle` degrees
  @discardableResult
  public func selectSharp(angle: Double = 30) -> Self { op("selectsharp", ["angle": angle]) }

  /// f
  @discardableResult
  public func fill() -> Self { op("fill") }

  /// shift d
  @discardableResult
  public func duplicate() -> Self { op("duplicate") }

  /// x
  @discardableResult
  public func delete(_ what: Element = .faces) -> Self { op("delete", ["what": what.rawValue]) }

  /// m
  @discardableResult
  public func merge(at target: MergeTarget = .center) -> Self
  {
    switch target
    {
      case .center: op("merge", ["at": "center"])
      case .cursor: op("merge", ["at": "cursor"])
      case let .distance(d): op("merge", ["at": "distance", "distance": d])
    }
  }

  /// g in meters
  @discardableResult
  public func move(_ offset: Vec3) -> Self { op("move", ["by": json(offset)]) }

  /// s about a pivot
  @discardableResult
  public func resize(_ factors: Vec3, about pivot: Vec3? = nil) -> Self
  {
    var args: [String: Any] = ["by": json(factors)]
    if let pivot { args["pivot"] = json(pivot) }
    return op("resize", args)
  }

  @discardableResult
  public func resize(_ factor: Double, about pivot: Vec3? = nil) -> Self
  {
    resize(Vec3(repeating: factor), about: pivot)
  }

  /// r about a pivot
  @discardableResult
  public func rotate(_ degrees: Double, around axis: Axis, about pivot: Vec3? = nil) -> Self
  {
    var args: [String: Any] = ["degrees": degrees, "axis": json(axis.vector)]
    if let pivot { args["pivot"] = json(pivot) }
    return op("rotate", args)
  }

  /// moves each selected vert to where body says
  @discardableResult
  public func reshape(_ body: (Int, Vec3) -> Vec3) -> Self
  {
    let verts = selectedVerts.sorted()
    return op("set", ["verts": verts, "points": verts.map { json(body($0, points[$0])) }])
  }

  /// adds a primitive into this mesh
  @discardableResult
  public func add(_ kind: Kind) -> Self { op("add", ["kind": kind.rawValue]) }
}
