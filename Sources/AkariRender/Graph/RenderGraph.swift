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

import AkariCore
import simd

public extension Akari
{
  /// the deferred graph declared in swift, written out as labfx text for the labfx runtime.
  enum RenderGraph {}
}

// MARK: Buffers

extension Akari.RenderGraph
{
  /// a texture format labfx allocates.
  enum Format: String, Sendable
  {
    case f32x1, f32x2, f32x3, f32x4
    case f16x1, f16x2, f16x3, f16x4
    case u8x1, u8x2, u8x3, u8x4
    case s8x1, s8x2, s8x3, s8x4
    case i32x1
  }

  /// how many frames a buffer keeps.
  enum Latency: Sendable
  {
    case triple
    case ring(Int)
  }

  /// how labfx allocates a buffer, where nil leaves the line out.
  struct BufferOptions: Sendable
  {
    /// the buffer level `has depth`.
    var depth: Bool?
    var latency: Latency?
    /// the texture list's `has mips`.
    var mips: Bool?
    /// the texture list's own `has depth`.
    var textureDepth: Bool?
    /// a fixed size instead of a scale of the root size.
    var size: SIMD2<Int>?
    var cube: Bool?
    var mipLevels: Int?

    init(depth: Bool? = false, latency: Latency? = nil, mips: Bool? = nil, textureDepth: Bool? = nil,
         size: SIMD2<Int>? = nil, cube: Bool? = nil, mipLevels: Int? = nil)
    {
      self.depth = depth
      self.latency = latency
      self.mips = mips
      self.textureDepth = textureDepth
      self.size = size
      self.cube = cube
      self.mipLevels = mipLevels
    }
  }

  /// a buffer whose cases are its textures in attachment order, so every reference to one is checked by the compiler.
  protocol RenderBuffer: RawRepresentable<String>, CaseIterable, Hashable, Sendable
  {
    /// the buffer's name in the graph.
    static var name: String { get }
    static var options: BufferOptions { get }
    /// this texture's format.
    var format: Format { get }
    /// this texture's size as a fraction of the root size, nil for fixed size buffers.
    var scale: Double? { get }
  }

  /// one texture of one buffer, with the names labfx binds it by.
  struct TextureRef: Hashable, Sendable
  {
    let buffer: String
    let texture: String

    /// the sampler a shader reads this texture through.
    var sampler: String { "u_\(texture)_texture" }
    /// the output a shader writes this texture through.
    var output: String { "o_\(texture)_texture" }
  }
}

extension Akari.RenderGraph.RenderBuffer
{
  static var options: Akari.RenderGraph.BufferOptions { .init() }
  var format: Akari.RenderGraph.Format { .f16x4 }
  var scale: Double? { 1.0 }

  var ref: Akari.RenderGraph.TextureRef { .init(buffer: Self.name, texture: rawValue) }
}

// MARK: Shader interface

extension Akari.RenderGraph
{
  /// a swift value type with the glsl type name a shader interface declares it as.
  protocol ShaderType: Sendable
  {
    static var labfxType: String { get }
  }

  /// a scalar simd vectors of shader types are built from.
  protocol ShaderScalar: SIMDScalar, ShaderType, Hashable, Codable
  {
    static var vectorPrefix: String { get }
  }

  /// values labfx fills in on its own.
  enum Auto: String, Sendable
  {
    case resolution = "auto-resolution"
    case viewMatrix = "auto-view-matrix"
    case skyMatrix = "auto-sky-matrix"
    case tonemapFramebuffer = "auto-tonemap-framebuffer"
    case tonemapDisplay = "auto-tonemap-display"
    case mipFraction = "auto-mip-fraction"
  }

  /// vertex attribute semantics.
  enum Semantic: String, Sendable
  {
    case position, color, normal, texcoord, pad
  }

  /// sampler types, spelled the way the graph spells them.
  enum SamplerType: String, Sendable
  {
    case sampler2D = "sampler2d"
    case sampler3D
    case samplerCube
    case sampler2DArray = "sampler2DArray"
    case isampler2D = "isampler2D"
    case usampler2D = "usampler2D"
    case usampler2DArray = "usampler2DArray"
  }

  /// one entry of a uniform, varying or attribute list.
  struct Declaration: Hashable, Sendable
  {
    let name: String
    let type: String
    /// the `<-` tag, an auto value or an attribute semantic.
    let tag: String?
  }

  /// anything a shader can list in its interface.
  protocol InterfaceItem
  {
    var declaration: Declaration { get }
  }

  /// a uniform swift sets by value, typed so the shader declaration and the setter agree.
  struct Uniform<Value: ShaderType>: InterfaceItem, Hashable, Sendable
  {
    let name: String
    let auto: Auto?

    init(_ name: String, auto: Auto? = nil)
    {
      self.name = name
      self.auto = auto
    }

    var declaration: Declaration { .init(name: name, type: Value.labfxType, tag: auto?.rawValue) }
  }

  /// a sampler, named after the pass input it reads unless given a name of its own.
  struct Sampler: InterfaceItem, Hashable, Sendable
  {
    let name: String
    let type: SamplerType

    init(_ texture: some RenderBuffer, _ type: SamplerType = .sampler2D)
    {
      self.init(texture.ref, type)
    }

    init(_ texture: TextureRef, _ type: SamplerType = .sampler2D)
    {
      name = texture.sampler
      self.type = type
    }

    init(_ name: String, _ type: SamplerType = .sampler2D)
    {
      self.name = name
      self.type = type
    }

    var declaration: Declaration { .init(name: name, type: type.rawValue, tag: nil) }
  }

  /// a value the vertex stage hands the fragment stage as `var.<name>`.
  struct Varying<Value: ShaderType>: InterfaceItem, Sendable
  {
    let name: String

    init(_ name: String)
    {
      self.name = name
    }

    var declaration: Declaration { .init(name: name, type: Value.labfxType, tag: nil) }
  }

  /// a vertex input.
  struct Attribute<Value: ShaderType>: InterfaceItem, Sendable
  {
    let name: String
    let semantic: Semantic

    init(_ name: String, _ semantic: Semantic)
    {
      self.name = name
      self.semantic = semantic
    }

    var declaration: Declaration { .init(name: name, type: Value.labfxType, tag: semantic.rawValue) }
  }

  @resultBuilder
  enum InterfaceBuilder
  {
    static func buildExpression(_ item: some InterfaceItem) -> [Declaration] { [item.declaration] }
    static func buildExpression(_ items: [Declaration]) -> [Declaration] { items }
    static func buildBlock(_ parts: [Declaration]...) -> [Declaration] { parts.flatMap(\.self) }
    static func buildOptional(_ part: [Declaration]?) -> [Declaration] { part ?? [] }
    static func buildEither(first: [Declaration]) -> [Declaration] { first }
    static func buildEither(second: [Declaration]) -> [Declaration] { second }
    static func buildArray(_ parts: [[Declaration]]) -> [Declaration] { parts.flatMap(\.self) }
  }
}

extension Float: Akari.RenderGraph.ShaderScalar
{
  static var labfxType: String { "float" }
  static var vectorPrefix: String { "" }
}

extension Int32: Akari.RenderGraph.ShaderScalar
{
  static var labfxType: String { "int" }
  static var vectorPrefix: String { "i" }
}

extension UInt32: Akari.RenderGraph.ShaderScalar
{
  static var labfxType: String { "uint" }
  static var vectorPrefix: String { "u" }
}

extension SIMD2: Akari.RenderGraph.ShaderType where Scalar: Akari.RenderGraph.ShaderScalar
{
  static var labfxType: String { "\(Scalar.vectorPrefix)vec2" }
}

extension SIMD3: Akari.RenderGraph.ShaderType where Scalar: Akari.RenderGraph.ShaderScalar
{
  static var labfxType: String { "\(Scalar.vectorPrefix)vec3" }
}

extension SIMD4: Akari.RenderGraph.ShaderType where Scalar: Akari.RenderGraph.ShaderScalar
{
  static var labfxType: String { "\(Scalar.vectorPrefix)vec4" }
}

extension Akari.Matrix4: Akari.RenderGraph.ShaderType
{
  static var labfxType: String { "mat4" }
}

// MARK: Shader stages

extension Akari.RenderGraph
{
  /// one stage of a shader, with a glsl body and an msl body.
  struct Stage: Sendable
  {
    enum Kind: String, Sendable
    {
      case vertex = "vsh"
      case fragment = "fsh"
      case compute = "csh"
    }

    let kind: Kind
    let attributes: [Declaration]
    let glsl: String
    let msl: String

    init(_ kind: Kind, glsl: String, msl: String, @InterfaceBuilder attributes: () -> [Declaration] = { [] })
    {
      self.kind = kind
      self.attributes = attributes()
      self.glsl = glsl
      self.msl = msl
    }
  }

  @resultBuilder
  enum StageBuilder
  {
    static func buildBlock(_ stages: Stage...) -> [Stage] { stages }
  }

  /// a shader the graph declares as a value naming its interface and stages, so one type can describe a family of shaders
  protocol ShaderProgram
  {
    /// the shader's name in the graph.
    var name: String { get }
    @InterfaceBuilder var uniforms: [Declaration] { get }
    @InterfaceBuilder var varyings: [Declaration] { get }
    @StageBuilder var stages: [Stage] { get }
  }

  /// a shader drawn over a full screen quad, with the shared vertex stage and its own fragment body.
  protocol FullscreenShader: ShaderProgram
  {
    var fragmentGLSL: String { get }
    var fragmentMSL: String { get }
  }

  /// shaders labfx ships itself.
  enum BuiltinShader: String, Sendable
  {
    case agx, aces, reinhard
  }
}

extension Akari.RenderGraph.ShaderProgram
{
  var varyings: [Akari.RenderGraph.Declaration] { [] }
}

extension Akari.RenderGraph.FullscreenShader
{
  var varyings: [Akari.RenderGraph.Declaration]
  {
    [Akari.RenderGraph.Varying<SIMD2<Float>>("texCoord").declaration]
  }

  var stages: [Akari.RenderGraph.Stage]
  {
    [.fullscreenQuad, .init(.fragment, glsl: fragmentGLSL, msl: fragmentMSL)]
  }
}

// MARK: Passes

extension Akari.RenderGraph
{
  enum DrawMode: String, Sendable
  {
    case none = "no"
    case quad
    case opaqueGeometry = "opaque geometry"
    case blit
    case compute
  }

  enum DepthFunc: String, Sendable
  {
    case never, less, lequal, equal, greater, gequal, always
  }

  enum BlendMode: String, Sendable
  {
    case alpha, additive, multiply
  }

  /// the shader a pass runs.
  enum ShaderRef
  {
    case program(any ShaderProgram)
    case builtin(BuiltinShader)

    var name: String
    {
      switch self
      {
        case let .program(program): program.name
        case let .builtin(builtin): builtin.rawValue
      }
    }
  }

  /// where a pass writes.
  enum Outputs: Sendable
  {
    case visible
    case buffer(String, [String])
  }

  /// everything one pass says, in the order labfx reads it.
  struct PassSpec
  {
    var name: String
    var draw: DrawMode?
    var callback: String?
    var clearDepth: Bool?
    var clearOutputs: Bool?
    var depthTest: DepthFunc?
    var writeDepth: Bool?
    var blend: BlendMode?
    var shader: ShaderRef?
    var dispatch: SIMD3<Int>?
    var threadgroup: SIMD3<Int>?
    var everyMip = false
    var inputs: [TextureRef] = []
    var outputs: Outputs?
  }

  /// one line of a pass declaration.
  protocol PassAttribute
  {
    func apply(to pass: inout PassSpec)
  }

  @resultBuilder
  enum PassBuilder
  {
    static func buildExpression(_ attribute: some PassAttribute) -> [any PassAttribute] { [attribute] }
    static func buildBlock(_ parts: [any PassAttribute]...) -> [any PassAttribute] { parts.flatMap(\.self) }
    static func buildOptional(_ part: [any PassAttribute]?) -> [any PassAttribute] { part ?? [] }
    static func buildEither(first: [any PassAttribute]) -> [any PassAttribute] { first }
    static func buildEither(second: [any PassAttribute]) -> [any PassAttribute] { second }
  }

  /// a full screen quad that neither tests nor writes depth, the way nearly every post pass draws.
  struct Quad: PassAttribute
  {
    func apply(to pass: inout PassSpec)
    {
      pass.draw = .quad
      pass.depthTest = .never
      pass.writeDepth = false
    }
  }

  struct Draw: PassAttribute
  {
    let mode: DrawMode
    init(_ mode: DrawMode) { self.mode = mode }
    func apply(to pass: inout PassSpec) { pass.draw = mode }
  }

  /// a pass swift draws itself through a registered callback.
  struct Callback: PassAttribute
  {
    let name: String
    init(_ callback: Akari.LabFXEngine.Callback) { name = callback.rawValue }
    init(_ name: String) { self.name = name }
    func apply(to pass: inout PassSpec) { pass.callback = name }
  }

  struct ClearDepth: PassAttribute
  {
    let clear: Bool
    init(_ clear: Bool = true) { self.clear = clear }
    func apply(to pass: inout PassSpec) { pass.clearDepth = clear }
  }

  struct ClearOutputs: PassAttribute
  {
    let clear: Bool
    init(_ clear: Bool = true) { self.clear = clear }
    func apply(to pass: inout PassSpec) { pass.clearOutputs = clear }
  }

  struct DepthTest: PassAttribute
  {
    let test: DepthFunc
    init(_ test: DepthFunc) { self.test = test }
    func apply(to pass: inout PassSpec) { pass.depthTest = test }
  }

  struct WriteDepth: PassAttribute
  {
    let write: Bool
    init(_ write: Bool = true) { self.write = write }
    func apply(to pass: inout PassSpec) { pass.writeDepth = write }
  }

  struct Blend: PassAttribute
  {
    let mode: BlendMode
    init(_ mode: BlendMode) { self.mode = mode }
    func apply(to pass: inout PassSpec) { pass.blend = mode }
  }

  /// the shader a pass runs, which also puts the shader's declaration in the graph.
  struct Shader: PassAttribute
  {
    let ref: ShaderRef
    init(_ program: some ShaderProgram) { ref = .program(program) }
    init(_ builtin: BuiltinShader) { ref = .builtin(builtin) }
    func apply(to pass: inout PassSpec) { pass.shader = ref }
  }

  struct Dispatch: PassAttribute
  {
    let groups: SIMD3<Int>
    let threads: SIMD3<Int>
    init(_ groups: SIMD3<Int>, threadgroup: SIMD3<Int>)
    {
      self.groups = groups
      threads = threadgroup
    }

    func apply(to pass: inout PassSpec)
    {
      pass.draw = .compute
      pass.dispatch = groups
      pass.threadgroup = threads
    }
  }

  /// runs a compute pass once per mip of its output
  struct EveryMip: PassAttribute
  {
    func apply(to pass: inout PassSpec)
    {
      pass.everyMip = true
    }
  }

  /// textures a pass samples, bound to the shader's `u_<texture>_texture` samplers.
  struct Inputs: PassAttribute
  {
    let textures: [TextureRef]
    init(_ textures: any RenderBuffer...) { self.textures = textures.map { $0.ref } }
    init(_ textures: TextureRef...) { self.textures = textures }
    init(_ textures: [TextureRef]) { self.textures = textures }
    func apply(to pass: inout PassSpec) { pass.inputs += textures }
  }

  /// textures a pass writes, all of one buffer, which the generic parameter makes the compiler check.
  struct Output: PassAttribute, Sendable
  {
    let outputs: Outputs

    init<B: RenderBuffer>(_ first: B, _ rest: B...)
    {
      outputs = .buffer(B.name, ([first] + rest).map(\.rawValue))
    }

    /// every texture of the buffer.
    init<B: RenderBuffer>(_ buffer: B.Type)
    {
      outputs = .buffer(B.name, B.allCases.map(\.rawValue))
    }

    /// one texture picked by value, such as a level of a chain of buffers.
    init(_ texture: TextureRef)
    {
      outputs = .buffer(texture.buffer, [texture.texture])
    }

    /// textures picked by value, which have to share a buffer.
    init(_ first: TextureRef, _ rest: TextureRef...)
    {
      precondition(rest.allSatisfy { $0.buffer == first.buffer }, "a pass writes the textures of one buffer")
      outputs = .buffer(first.buffer, [first.texture] + rest.map(\.texture))
    }

    private init(_ outputs: Outputs) { self.outputs = outputs }

    /// the host's own framebuffer.
    static let visible = Output(.visible)

    func apply(to pass: inout PassSpec) { pass.outputs = outputs }
  }
}

// MARK: Graph

extension Akari.RenderGraph
{
  /// one top level entry of the graph.
  enum Node
  {
    case buffer(BufferSpec)
    case pass(PassSpec)
    case shader(any ShaderProgram)
  }

  /// a buffer's declaration, taken from its RenderBuffer type.
  struct BufferSpec
  {
    let name: String
    let options: BufferOptions
    let textures: [(name: String, format: Format, scale: Double?)]

    init<B: RenderBuffer>(_: B.Type)
    {
      name = B.name
      options = B.options
      textures = B.allCases.map { ($0.rawValue, $0.format, $0.scale) }
    }
  }

  /// anything that can sit in a graph body.
  protocol GraphContent
  {
    var nodes: [Node] { get }
  }

  @resultBuilder
  enum GraphBuilder
  {
    static func buildExpression(_ content: some GraphContent) -> [Node] { content.nodes }
    static func buildBlock(_ parts: [Node]...) -> [Node] { parts.flatMap(\.self) }
    static func buildOptional(_ part: [Node]?) -> [Node] { part ?? [] }
    static func buildEither(first: [Node]) -> [Node] { first }
    static func buildEither(second: [Node]) -> [Node] { second }
    static func buildArray(_ parts: [[Node]]) -> [Node] { parts.flatMap(\.self) }
  }

  /// buffer declarations, in the order they should appear.
  struct Buffers: GraphContent
  {
    let nodes: [Node]
    init<each B: RenderBuffer>(_ buffer: repeat (each B).Type)
    {
      var nodes: [Node] = []
      for b in repeat each buffer { nodes.append(.buffer(BufferSpec(b))) }
      self.nodes = nodes
    }
  }

  /// shaders no pass names, such as the ones geometry captures replay through.
  struct Shaders: GraphContent
  {
    let nodes: [Node]
    init(_ programs: any ShaderProgram...) { nodes = programs.map(Node.shader) }
  }

  /// a pass, named by the engine's own pass enum so swift and the graph can't drift apart.
  struct Pass: GraphContent
  {
    let spec: PassSpec

    init(_ id: Akari.LabFXEngine.Pass, @PassBuilder _ attributes: () -> [any PassAttribute])
    {
      self.init(id.rawValue, attributes)
    }

    init(_ name: String, @PassBuilder _ attributes: () -> [any PassAttribute])
    {
      var spec = PassSpec(name: name)
      for attribute in attributes() { attribute.apply(to: &spec) }
      self.spec = spec
    }

    var nodes: [Node] { [.pass(spec)] }
  }

  /// a whole graph, buffers, passes and shaders.
  struct Graph
  {
    let name: String
    let version: String
    let nodes: [Node]

    init(_ name: String, version: String, @GraphBuilder _ body: () -> [Node])
    {
      self.name = name
      self.version = version
      nodes = body()
    }

    var passes: [PassSpec]
    {
      var passes: [PassSpec] = []
      for case let .pass(pass) in nodes { passes.append(pass) }
      return passes
    }

    var buffers: [BufferSpec]
    {
      var buffers: [BufferSpec] = []
      for case let .buffer(buffer) in nodes { buffers.append(buffer) }
      return buffers
    }

    /// every shader the graph declares or a pass names, first use first, each once.
    var shaders: [any ShaderProgram]
    {
      var seen = Set<String>()
      var programs: [any ShaderProgram] = []
      for node in nodes
      {
        var program: (any ShaderProgram)?
        switch node
        {
          case let .shader(declared): program = declared
          case let .pass(pass): if case let .program(named) = pass.shader { program = named }
          case .buffer: break
        }
        if let program, seen.insert(program.name).inserted { programs.append(program) }
      }
      return programs
    }
  }
}
