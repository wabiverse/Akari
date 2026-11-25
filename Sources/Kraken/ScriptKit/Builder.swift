import Foundation

/// a prim to build with its children and what to do once made
public struct Node
{
  let make: (Prim?) -> Prim?
  var children: [Node] = []
  var after: [(Prim) -> Void] = []
  /// what runs once every other step is done, whatever order they were added in
  var last: [(Prim) -> Void] = []

  init(make: @escaping (Prim?) -> Prim?, children: [Node] = [])
  {
    self.make = make
    self.children = children
  }

  /// builds this and its children
  @discardableResult
  func build(in parent: Prim?) -> Prim?
  {
    let prim = make(parent)
    for child in children { child.build(in: prim ?? parent) }
    if let prim { for body in after + last { body(prim) } }
    return prim
  }

  /// runs body once built
  public func then(_ body: @escaping (Prim) -> Void) -> Node
  {
    var next = self
    next.after.append(body)
    return next
  }

  /// binds a material by name
  public func material(_ name: String) -> Node
  {
    then
    { prim in
      guard let material = scene.material(named: name) else { Connection.die("no material named \(name)") }
      prim.material = material
    }
  }

  /// edits the mesh once built
  public func edit(_ body: @escaping (EditMesh) -> Void) -> Node
  {
    then
    { prim in
      guard let mesh = prim as? Mesh else { Connection.die("\(prim.path) isn't a mesh to edit") }
      mesh.edit(body)
    }
  }

  /// subdivides the mesh as it renders, catmull clark by default, holding edges sharper than `angle` degrees hard
  public func subdivision(_ scheme: Subdivision = .catmullClark, creasing angle: Double? = nil) -> Node
  {
    var next = then
    { prim in
      guard let mesh = prim as? Mesh else { Connection.die("\(prim.path) isn't a mesh to subdivide") }
      mesh.subdivision(scheme)
    }

    if let angle
    {
      next.last.append
      { prim in
        (prim as? Mesh)?.edit
        { mesh in
          mesh.selectSharp(angle: angle)
          if !mesh.selectedVerts.isEmpty { mesh.crease(1) }
          mesh.deselectAll()
        }
      }
    }

    return next
  }

  public func transform(location: Vec3? = nil, rotation: Vec3? = nil, scale: Vec3? = nil) -> Node
  {
    then { $0.transform(location: location, rotation: rotation, scale: scale) }
  }

  public func set(_ attribute: String, _ value: Value) -> Node
  {
    then { $0[attribute] = value }
  }
}

/// how a material looks
public struct Look
{
  let apply: (Material) -> Void

  public init(_ apply: @escaping (Material) -> Void)
  {
    self.apply = apply
  }

  public static func metal(_ color: Vec3, roughness: Double) -> Look
  {
    Look { $0.metal(color, roughness: roughness) }
  }

  public static func dielectric(_ color: Vec3, roughness: Double) -> Look
  {
    Look { $0.dielectric(color, roughness: roughness) }
  }

  /// glows color times strength
  public static func emissive(_ color: Vec3, strength: Double, opacity: Double = 1) -> Look
  {
    Look { $0.dielectric(.zero, roughness: 1).emission(color, strength: strength).opacity(opacity) }
  }
}

@resultBuilder
public enum SceneBuilder
{
  public static func buildExpression(_ node: Node) -> [Node] { [node] }
  public static func buildExpression(_ nodes: [Node]) -> [Node] { nodes }
  public static func buildBlock(_ parts: [Node]...) -> [Node] { parts.flatMap { $0 } }
  public static func buildOptional(_ part: [Node]?) -> [Node] { part ?? [] }
  public static func buildEither(first: [Node]) -> [Node] { first }
  public static func buildEither(second: [Node]) -> [Node] { second }
  public static func buildArray(_ parts: [[Node]]) -> [Node] { parts.flatMap { $0 } }
}

public extension Scene
{
  /// builds the nodes in order
  @discardableResult
  func build(in parent: Prim? = nil, @SceneBuilder _ content: () -> [Node]) -> [Prim]
  {
    content().compactMap { $0.build(in: parent) }
  }
}

/// a group
public func Xform(_ name: String, @SceneBuilder _ children: () -> [Node] = { [] }) -> Node
{
  Node(make: { scene.add(.empty, name, in: $0) }, children: children())
}

/// a group with no transform
public func Scope(_ name: String, @SceneBuilder _ children: () -> [Node] = { [] }) -> Node
{
  // an empty turned into a scope
  Node(make: { parent in
    let prim = scene.add(.empty, name, in: parent)
    Connection.shared.call("retype", ["path": prim.path, "type": "Scope"])
    return scene[prim.path]
  }, children: children())
}

/// any shift+a primitive
public func Primitive(_ kind: Kind, _ name: String, at location: Vec3? = nil, _ options: AddOptions = AddOptions()) -> Node
{
  Node(make: { scene.add(kind, name, in: $0, at: location, options) })
}

/// a cylinder between two heights
public func Cylinder(_ name: String, radius: Double, z: ClosedRange<Double>, center: (x: Double, y: Double) = (0, 0),
                     vertices: Int = 32) -> Node
{
  Primitive(.cylinder, name, at: Vec3(center.x, center.y, z.middle), AddOptions(radius: radius, depth: z.span, vertices: vertices))
}

/// a cone between two heights
public func Cone(_ name: String, radius: Double, z: ClosedRange<Double>, center: (x: Double, y: Double) = (0, 0),
                 vertices: Int = 32) -> Node
{
  Primitive(.cone, name, at: Vec3(center.x, center.y, z.middle), AddOptions(radius: radius, depth: z.span, vertices: vertices))
}

public func Cube(_ name: String, size: Double, at location: Vec3 = .zero) -> Node
{
  Primitive(.cube, name, at: location, AddOptions(size: size))
}

public func Sphere(_ name: String, radius: Double, at location: Vec3 = .zero, segments: Int = 32, rings: Int = 16) -> Node
{
  Primitive(.uvSphere, name, at: location, AddOptions(radius: radius, vertices: segments, rings: rings))
}

public func Plane(_ name: String, size: Double, at location: Vec3 = .zero) -> Node
{
  Primitive(.plane, name, at: location, AddOptions(size: size))
}

/// a torus with a tube this thick
public func Torus(_ name: String, radius: Double, thickness: Double, at location: Vec3 = .zero,
                  segments: Int = 48, sides: Int = 12) -> Node
{
  Primitive(.torus, name, at: location, AddOptions(majorRadius: radius, minorRadius: thickness / 2,
                                                   majorSegments: segments, minorSegments: sides))
}

private func lamp(_ kind: Kind, _ name: String, _ location: Vec3?, _ inputs: [(String, Value?)]) -> Node
{
  Node(make: { parent in
    let light = scene.add(kind, name, in: parent, at: location)
    for (input, value) in inputs { if let value { light["inputs:" + input] = value } }
    return light
  })
}

/// a tube of light along x
public func CylinderLight(_ name: String, at location: Vec3? = nil, radius: Double? = nil, length: Double? = nil,
                          intensity: Double? = nil, color: Vec3? = nil) -> Node
{
  lamp(.cylinderLight, name, location, [("radius", radius.map(Value.number)), ("length", length.map(Value.number)),
                                        ("intensity", intensity.map(Value.number)), ("color", color.map(Value.vector))])
}

public func PointLight(_ name: String, at location: Vec3? = nil, radius: Double? = nil, intensity: Double? = nil,
                       color: Vec3? = nil) -> Node
{
  lamp(.pointLight, name, location, [("radius", radius.map(Value.number)), ("intensity", intensity.map(Value.number)),
                                     ("color", color.map(Value.vector))])
}

public func SunLight(_ name: String, intensity: Double? = nil, color: Vec3? = nil) -> Node
{
  lamp(.sunLight, name, nil, [("intensity", intensity.map(Value.number)), ("color", color.map(Value.vector))])
}

public func AreaLight(_ name: String, at location: Vec3? = nil, width: Double? = nil, height: Double? = nil,
                      intensity: Double? = nil, color: Vec3? = nil) -> Node
{
  lamp(.areaLight, name, location, [("width", width.map(Value.number)), ("height", height.map(Value.number)),
                                    ("intensity", intensity.map(Value.number)), ("color", color.map(Value.vector))])
}

/// a material from a look
public func Surface(_ name: String, _ look: Look) -> Node
{
  Node(make: { parent in
    let material = scene.material(name, in: parent)
    look.apply(material)
    return material
  })
}

/// builds inside an existing child
public func Within(_ name: String, @SceneBuilder _ children: () -> [Node]) -> Node
{
  Node(make: { parent in
    let path = (parent?.path ?? "") + "/" + name
    guard let prim = scene[path] else { Connection.die("\(path) isn't on the stage to build within") }
    return prim
  }, children: children())
}

/// builds inside a variant
public func Variant(_ set: String, _ variant: String, @SceneBuilder _ children: () -> [Node]) -> Node
{
  let content = children()
  return Node(make: { parent in
    guard let parent else { Connection.die("a Variant needs a prim to be built under") }
    parent.variantSet(set).edit(variant) { for child in content { child.build(in: parent) } }
    return nil
  })
}

/// picks a variant
public func SelectVariant(_ set: String, _ variant: String) -> Node
{
  Node(make: { parent in
    parent?.variantSet(set).selection = variant
    return nil
  })
}
