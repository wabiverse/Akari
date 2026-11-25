import Foundation

/// what shift a adds
public enum Kind: String, CaseIterable, Sendable
{
  case plane, cube, circle, uvSphere = "uvsphere", icoSphere = "icosphere", cylinder, cone, torus, grid
  case pointLight = "point", sunLight = "sun", spotLight = "spot", areaLight = "area", cylinderLight = "tube"
  case camera, empty
}

/// add options in meters
public struct AddOptions: Sendable
{
  public var radius: Double?
  public var depth: Double?
  public var size: Double?
  public var vertices: Int?
  public var rings: Int?
  public var subdivisions: Int?
  public var cuts: Int?
  public var majorRadius: Double?
  public var minorRadius: Double?
  public var majorSegments: Int?
  public var minorSegments: Int?

  public init(radius: Double? = nil, depth: Double? = nil, size: Double? = nil, vertices: Int? = nil, rings: Int? = nil,
              subdivisions: Int? = nil, cuts: Int? = nil, majorRadius: Double? = nil, minorRadius: Double? = nil,
              majorSegments: Int? = nil, minorSegments: Int? = nil)
  {
    self.radius = radius
    self.depth = depth
    self.size = size
    self.vertices = vertices
    self.rings = rings
    self.subdivisions = subdivisions
    self.cuts = cuts
    self.majorRadius = majorRadius
    self.minorRadius = minorRadius
    self.majorSegments = majorSegments
    self.minorSegments = minorSegments
  }

  var json: [String: Any]
  {
    var o: [String: Any] = [:]
    let pairs: [(String, Any?)] = [("radius", radius), ("depth", depth), ("size", size), ("vertices", vertices),
                                   ("rings", rings), ("subdivisions", subdivisions), ("cuts", cuts),
                                   ("majorRadius", majorRadius), ("minorRadius", minorRadius),
                                   ("majorSegments", majorSegments), ("minorSegments", minorSegments)]
    for (key, value) in pairs { if let value { o[key] = value } }
    return o
  }
}

/// numpad views
public enum View: String, Sendable
{
  case front, back, top, bottom, right, left, all, selected, camera
}

public enum Shading: String, Sendable
{
  case wireframe, solid, material, rendered
}

/// render features the view turns on and off
public enum Feature: String, CaseIterable, Sendable
{
  case imageBasedLighting = "ibl", lightProbes = "probes", shadows, reflections = "ssr", globalIllumination = "ssgi"
  case temporalAA = "taa", bloom, depthOfField = "dof", volumes, rayTracing = "raytracing"
  case dynamicResolution = "dynamic", motionBlur = "motionblur"
}

/// the fps counter
public struct Stats: Sendable
{
  public var fps: Double
  public var milliseconds: Double
}

/// the open scene
public var scene: Scene
{
  Scene.current
}

public final class Scene
{
  public static let current = Scene()

  private init() {}

  /// file new
  @discardableResult
  public static func new(up: Axis = .z, keepStarter: Bool = false) -> Scene
  {
    Connection.shared.call("new", ["upAxis": up.rawValue.uppercased(), "keep": keepStarter])
    return current
  }

  /// file open
  @discardableResult
  public static func open(_ path: String) -> Scene
  {
    Connection.shared.call("open", ["path": resolve(path)])
    return current
  }

  static func resolve(_ path: String) -> String
  {
    let expanded = (path as NSString).expandingTildeInPath
    if expanded.hasPrefix("/") { return expanded }
    return URL(fileURLWithPath: Kraken.scriptPath).deletingLastPathComponent().appendingPathComponent(expanded).path
  }

  /// file save
  public func save(to path: String? = nil)
  {
    Connection.shared.call("save", path.map { ["path": Scene.resolve($0)] } ?? [:])
  }

  private var info: [String: Any]
  {
    Connection.shared.call("stage") as? [String: Any] ?? [:]
  }

  /// the file or nil
  public var file: String?
  {
    let path = info["path"] as? String ?? ""
    return path.isEmpty ? nil : path
  }

  public var up: Axis
  {
    get { (info["upAxis"] as? String) == "Y" ? .y : .z }
    set { Connection.shared.call("stage", ["upAxis": newValue.rawValue.uppercased()]) }
  }

  /// what references get
  public var defaultPrim: Prim?
  {
    get { (info["defaultPrim"] as? String).flatMap { $0.isEmpty ? nil : self[$0] } }
    set { Connection.shared.call("stage", ["defaultPrim": newValue?.path ?? "/"]) }
  }

  /// the file doc
  public var documentation: String = ""
  {
    didSet { Connection.shared.call("stage", ["doc": documentation]) }
  }

  /// the view follows what gets built
  public var follow: Bool = false
  {
    didSet { Connection.shared.call("follow", ["on": follow]) }
  }

  /// the 3d cursor
  public var cursor: Vec3
  {
    get { (["v": Connection.shared.call("cursor")] as [String: Any]).vector("v") }
    set { Connection.shared.call("cursor", ["location": json(newValue)]) }
  }

  /// the prim at a path
  public subscript(_ path: String) -> Prim?
  {
    guard let info = (try? Kraken.call("get", ["path": path])) as? [String: Any] else { return nil }
    return Prim.make(path: path, type: info["type"] as? String ?? "")
  }

  /// every prim
  public var prims: [Prim]
  {
    (Connection.shared.call("prims") as? [[String: Any]] ?? []).map
    {
      Prim.make(path: $0["path"] as? String ?? "", type: $0["type"] as? String ?? "")
    }
  }

  public var materials: [Material]
  {
    (Connection.shared.call("materials") as? [String] ?? []).map { Material(path: $0, type: "Material") }
  }

  /// a material by name
  public func material(named name: String) -> Material?
  {
    materials.first { $0.name == name }
  }

  /// shift a
  @discardableResult
  public func add(_ kind: Kind, _ name: String? = nil, in parent: Prim? = nil, at location: Vec3? = nil,
                  _ options: AddOptions = AddOptions()) -> Prim
  {
    var args: [String: Any] = ["kind": kind.rawValue, "options": options.json]
    if let name { args["name"] = name }
    if let parent { args["parent"] = parent.path }
    if let location { args["location"] = json(location) }
    let made = Connection.shared.call("add", args) as? [String: Any] ?? [:]
    return Prim.make(path: made["path"] as? String ?? "", type: made["type"] as? String ?? "")
  }

  /// a cylinder between two heights
  @discardableResult
  public func cylinder(_ name: String, radius: Double, z: ClosedRange<Double>, center: (x: Double, y: Double) = (0, 0),
                       vertices: Int = 32, in parent: Prim? = nil) -> Mesh
  {
    add(.cylinder, name, in: parent, at: Vec3(center.x, center.y, z.middle),
        AddOptions(radius: radius, depth: z.span, vertices: vertices)) as! Mesh
  }

  /// a new material
  @discardableResult
  public func material(_ name: String, in scope: Prim? = nil) -> Material
  {
    var args: [String: Any] = ["name": name]
    if let scope { args["scope"] = scope.path }
    return Material(path: Connection.shared.call("material.new", args) as? String ?? "", type: "Material")
  }

  /// x
  public func remove(_ prims: Prim...)
  {
    Connection.shared.call("remove", ["paths": prims.map(\.path)])
  }

  /// selects prims
  public func select(_ prims: Prim...)
  {
    Connection.shared.call("select", ["paths": prims.map(\.path)])
  }

  public func view(_ view: View)
  {
    Connection.shared.call("view", ["view": view.rawValue])
  }

  /// where the view camera is and where it looks
  public struct ViewCamera
  {
    public var eye: Vec3
    public var forward: Vec3
    public var focus: Vec3
  }

  /// aims the view camera
  @discardableResult
  public func camera(focus: Vec3? = nil, distance: Double? = nil, pitch: Double? = nil, yaw: Double? = nil) -> ViewCamera
  {
    var args: [String: Any] = [:]
    if let focus { args["focus"] = json(focus) }
    if let distance { args["distance"] = distance }
    if let pitch { args["pitch"] = pitch }
    if let yaw { args["yaw"] = yaw }
    let placed = Connection.shared.call("camera", args) as? [String: Any] ?? [:]
    return ViewCamera(eye: placed.vector("eye"), forward: placed.vector("forward"), focus: placed.vector("focus"))
  }

  /// the view sun from 1 at noon down to minus 1 at night
  public func sun(height: Double)
  {
    Connection.shared.call("sun", ["height": height])
  }

  /// shows or hides the sky behind the scene
  public func sky(_ on: Bool)
  {
    Connection.shared.call("sky", ["on": on])
  }

  /// turns a view render feature on or off
  public func feature(_ feature: Feature, _ on: Bool = true)
  {
    Connection.shared.call("feature", ["name": feature.rawValue, "on": on])
  }

  /// viewport fps and frame time
  public var stats: Stats
  {
    let stats = Connection.shared.call("stats") as? [String: Any] ?? [:]
    return Stats(fps: stats["fps"] as? Double ?? 0, milliseconds: stats["ms"] as? Double ?? 0)
  }

  /// builds things only the viewport shows that never get saved
  public func session(_ body: () -> Void)
  {
    Connection.shared.call("session", ["on": true])
    body()
    Connection.shared.call("session", ["on": false])
  }

  /// view depth of field on a prim or a distance
  public func depthOfField(focus prim: Prim? = nil, distance: Double? = nil, fStop: Double = 2.8, maxSize: Double? = nil)
  {
    var args: [String: Any] = ["on": true, "fStop": fStop, "focus": prim?.path ?? ""]
    if let distance { args["distance"] = distance }
    if let maxSize { args["maxSize"] = maxSize }
    Connection.shared.call("dof", args)
  }

  /// turns view depth of field off
  public func depthOfFieldOff()
  {
    Connection.shared.call("dof", ["on": false])
  }

  public var shading: Shading = .solid
  {
    didSet { Connection.shared.call("shading", ["mode": shading.rawValue]) }
  }
}

/// an attribute value
public enum Value: Sendable, ExpressibleByFloatLiteral, ExpressibleByIntegerLiteral, ExpressibleByBooleanLiteral,
  ExpressibleByArrayLiteral, ExpressibleByStringLiteral, CustomStringConvertible
{
  case number(Double)
  case numbers([Double])
  case flag(Bool)
  case token(String)

  public init(floatLiteral value: Double) { self = .number(value) }
  public init(integerLiteral value: Int) { self = .number(Double(value)) }
  public init(booleanLiteral value: Bool) { self = .flag(value) }
  public init(arrayLiteral elements: Double...) { self = .numbers(elements) }
  public init(stringLiteral value: String) { self = .token(value) }
  public static func vector(_ v: Vec3) -> Value { .numbers([v.x, v.y, v.z]) }

  public var number: Double?
  {
    switch self
    {
      case let .number(n): n
      case let .numbers(a): a.first
      case let .flag(b): b ? 1 : 0
      case .token: nil
    }
  }

  public var vector: Vec3?
  {
    if case let .numbers(a) = self, a.count == 3 { return Vec3(a[0], a[1], a[2]) }
    return nil
  }

  public var description: String
  {
    switch self
    {
      case let .number(n): "\(n)"
      case let .numbers(a): "\(a)"
      case let .flag(b): "\(b)"
      case let .token(t): t
    }
  }

  var json: Any
  {
    switch self
    {
      case let .number(n): n
      case let .numbers(a): a
      case let .flag(b): b
      case let .token(t): t
    }
  }
}

/// a prim found by path
public class Prim: Hashable, CustomStringConvertible
{
  public internal(set) var path: String
  public let type: String

  required init(path: String, type: String)
  {
    self.path = path
    self.type = type
  }

  static func make(path: String, type: String) -> Prim
  {
    switch type
    {
      case "Mesh": Mesh(path: path, type: type)
      case "Material": Material(path: path, type: type)
      case _ where type.hasSuffix("Light"): Light(path: path, type: type)
      default: Prim(path: path, type: type)
    }
  }

  public static func == (a: Prim, b: Prim) -> Bool { a.path == b.path }
  public func hash(into hasher: inout Hasher) { hasher.combine(path) }
  public var description: String { "\(type) \(path)" }

  private var info: [String: Any]
  {
    Connection.shared.call("get", ["path": path]) as? [String: Any] ?? [:]
  }

  /// renames and fixes what points at it
  public var name: String
  {
    get { String(path.split(separator: "/").last ?? "") }
    set { path = Connection.shared.call("rename", ["path": path, "name": newValue]) as? String ?? path }
  }

  /// ctrl p keeping it in place
  public var parent: Prim?
  {
    get
    {
      let up = (path as NSString).deletingLastPathComponent
      return up == "/" ? nil : scene[up]
    }
    set
    {
      let moved = Connection.shared.call("parent", ["paths": [path], "parent": newValue?.path ?? "/"]) as? [String]
      path = moved?.first ?? path
    }
  }

  public var children: [Prim]
  {
    (info["children"] as? [String] ?? []).compactMap { scene[$0] }
  }

  /// meters
  public var location: Vec3
  {
    get { info.vector("location") }
    set { transform(location: newValue) }
  }

  /// degrees
  public var rotation: Vec3
  {
    get { info.vector("rotation") }
    set { transform(rotation: newValue) }
  }

  public var scale: Vec3
  {
    get { info.vector("scale") }
    set { transform(scale: newValue) }
  }

  /// sets transform parts at once
  @discardableResult
  public func transform(location: Vec3? = nil, rotation: Vec3? = nil, scale: Vec3? = nil) -> Self
  {
    var args: [String: Any] = ["path": path]
    if let location { args["location"] = json(location) }
    if let rotation { args["rotation"] = json(rotation) }
    if let scale { args["scale"] = json(scale) }
    Connection.shared.call("transform", args)
    return self
  }

  /// the bound material
  public var material: Material?
  {
    get
    {
      let path = info["material"] as? String ?? ""
      return path.isEmpty ? nil : Material(path: path, type: "Material")
    }
    set
    {
      guard let newValue else { return }
      Connection.shared.call("material.bind", ["path": path, "material": newValue.path])
    }
  }

  /// an attribute by name
  public subscript(_ attribute: String) -> Value
  {
    get
    {
      let numbers = Connection.shared.call("attr.get", ["path": path, "name": attribute]) as? [Double] ?? []
      return numbers.count == 1 ? .number(numbers[0]) : .numbers(numbers)
    }
    set
    {
      if case let .token(t) = newValue
      {
        Connection.shared.call("token.set", ["path": path, "name": attribute, "value": t])
      }
      else
      {
        Connection.shared.call("attr.set", ["path": path, "name": attribute, "value": newValue.json])
      }
    }
  }

  /// sets an attribute
  @discardableResult
  public func set(_ attribute: String, _ value: Value) -> Self
  {
    self[attribute] = value
    return self
  }

  public func select()
  {
    Connection.shared.call("select", ["paths": [path]])
  }

  public func remove()
  {
    Connection.shared.call("remove", ["paths": [path]])
  }

  /// a variant set
  public func variantSet(_ name: String) -> VariantSet
  {
    VariantSet(prim: self, name: name)
  }

  public var variantSets: [VariantSet]
  {
    (Connection.shared.call("variants", ["path": path]) as? [[String: Any]] ?? []).map
    {
      VariantSet(prim: self, name: $0["name"] as? String ?? "")
    }
  }
}

/// a variant set and its variants
public struct VariantSet
{
  public let prim: Prim
  public let name: String

  private var info: [String: Any]
  {
    (Connection.shared.call("variants", ["path": prim.path]) as? [[String: Any]] ?? []).first { $0["name"] as? String == name } ?? [:]
  }

  public var variants: [String]
  {
    info["variants"] as? [String] ?? []
  }

  public var selection: String?
  {
    get { (info["selection"] as? String).flatMap { $0.isEmpty ? nil : $0 } }
    nonmutating set
    {
      guard let newValue else { return }
      Connection.shared.call("variant.select", ["path": prim.path, "set": name, "variant": newValue])
    }
  }

  /// adds variants
  @discardableResult
  public func add(_ variants: String...) -> VariantSet
  {
    for variant in variants { Connection.shared.call("variant.add", ["path": prim.path, "set": name, "variant": variant]) }
    return self
  }

  /// edits inside a variant
  public func edit(_ variant: String, _ body: () -> Void)
  {
    if !variants.contains(variant) { add(variant) }
    Connection.shared.call("variant.edit", ["path": prim.path, "set": name, "variant": variant])
    body()
    Connection.shared.call("variant.done")
  }
}

/// how a mesh subdivides as it renders, the usd subdivision schemes
public enum Subdivision: String, Sendable
{
  case none, catmullClark, loop, bilinear
}

public final class Mesh: Prim
{
  /// subdivides the mesh as it renders, catmull clark unless told otherwise
  @discardableResult
  public func subdivision(_ scheme: Subdivision = .catmullClark) -> Self
  {
    set("subdivisionScheme", .token(scheme.rawValue))
  }

  /// tab in run body tab out
  @discardableResult
  public func edit(_ body: (EditMesh) -> Void) -> Self
  {
    let mesh = EditMesh(Connection.shared.call("edit", ["path": path]) as? [String: Any] ?? [:])
    body(mesh)
    Connection.shared.call("object")
    return self
  }
}

/// a light
public final class Light: Prim
{
  private func input(_ name: String) -> Double { self["inputs:" + name].number ?? 0 }

  public var intensity: Double
  {
    get { input("intensity") }
    set { self["inputs:intensity"] = .number(newValue) }
  }

  public var exposure: Double
  {
    get { input("exposure") }
    set { self["inputs:exposure"] = .number(newValue) }
  }

  public var color: Vec3
  {
    get { self["inputs:color"].vector ?? Vec3(1, 1, 1) }
    set { self["inputs:color"] = .vector(newValue) }
  }

  /// sphere disk and cylinder lights
  public var radius: Double
  {
    get { input("radius") }
    set { self["inputs:radius"] = .number(newValue) }
  }

  /// cylinder light length
  public var length: Double
  {
    get { input("length") }
    set { self["inputs:length"] = .number(newValue) }
  }

  /// rect light size
  public var width: Double
  {
    get { input("width") }
    set { self["inputs:width"] = .number(newValue) }
  }

  public var height: Double
  {
    get { input("height") }
    set { self["inputs:height"] = .number(newValue) }
  }
}

/// a material
public final class Material: Prim
{
  /// sets a shader input
  @discardableResult
  public func input(_ name: String, _ value: Value) -> Self
  {
    Connection.shared.call("material.set", ["material": path, "input": name, "value": value.json])
    return self
  }

  /// metal
  @discardableResult
  public func metal(_ color: Vec3, roughness: Double) -> Self
  {
    input("diffuseGain", 0).input("specularFaceColor", .vector(color)).input("specularEdgeColor", [1, 1, 1])
      .input("specularRoughness", .number(roughness))
  }

  /// paint or plastic
  @discardableResult
  public func dielectric(_ color: Vec3, roughness: Double) -> Self
  {
    input("diffuseGain", 1).input("diffuseColor", .vector(color)).input("specularFaceColor", [0.04, 0.04, 0.04])
      .input("specularEdgeColor", [1, 1, 1]).input("specularRoughness", .number(roughness))
  }

  /// glow
  @discardableResult
  public func emission(_ color: Vec3, strength: Double) -> Self
  {
    input("glowColor", .vector(color)).input("glowGain", .number(strength))
  }

  /// 1 solid 0 gone
  @discardableResult
  public func opacity(_ presence: Double) -> Self
  {
    input("presence", .number(presence))
  }
}
