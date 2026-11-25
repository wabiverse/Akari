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
import Foundation
import LabFX
import LabGL

// MARK: Writing LabFX

extension Akari.RenderGraph.Graph
{
  /// the graph as labfx text, header, buffers, passes and then shaders.
  var labfx: String
  {
    var sections = ["--- labfx version 1.0", "name: \(name)\nversion: \(version)"]
    sections += buffers.map(Akari.RenderGraph.LabFXWriter.buffer)
    sections += passes.map(Akari.RenderGraph.LabFXWriter.pass)
    sections += shaders.map(Akari.RenderGraph.LabFXWriter.shader)
    return sections.joined(separator: "\n\n") + "\n"
  }
}

extension Akari.RenderGraph
{
  /// turns each kind of node into its labfx section.
  enum LabFXWriter
  {
    static func yesNo(_ value: Bool) -> String { value ? "yes" : "no" }

    static func buffer(_ buffer: BufferSpec) -> String
    {
      let options = buffer.options
      var lines = ["buffer: \(buffer.name)"]
      if let depth = options.depth { lines.append("  has depth: \(yesNo(depth))") }
      switch options.latency
      {
        case .triple: lines.append("  latency: triple")
        case let .ring(count): lines.append("  latency: ring \(count)")
        case nil: break
      }
      lines.append("  textures:")
      if let mips = options.mips { lines.append("    has mips: \(yesNo(mips))") }
      if let depth = options.textureDepth { lines.append("    has depth: \(yesNo(depth))") }
      if let size = options.size { lines.append("    size: [\(size.x) \(size.y)]") }
      if let cube = options.cube { lines.append("    cube: \(yesNo(cube))") }
      if let levels = options.mipLevels { lines.append("    mip levels: \(levels)") }
      let entries = buffer.textures.map
      { texture in
        [texture.name, texture.format.rawValue] + (texture.scale.map { ["scale: \($0)"] } ?? [])
      }.map { $0.joined(separator: ", ") }
      lines.append(list(entries, open: "    [ ", continuation: "      ", separator: ""))
      return lines.joined(separator: "\n")
    }

    static func pass(_ pass: PassSpec) -> String
    {
      var lines = ["pass: \(pass.name)"]
      if let draw = pass.draw { lines.append("  draw: \(draw.rawValue)") }
      if let callback = pass.callback { lines.append("  callback: \(callback)") }
      if let clear = pass.clearDepth { lines.append("  clear depth: \(yesNo(clear))") }
      if let clear = pass.clearOutputs { lines.append("  clear outputs: \(yesNo(clear))") }
      if let test = pass.depthTest { lines.append("  depth test: \(test.rawValue)") }
      if let write = pass.writeDepth { lines.append("  write depth: \(yesNo(write))") }
      if let blend = pass.blend { lines.append("  blend: \(blend.rawValue)") }
      if let shader = pass.shader { lines.append("  use shader: \(shader.name)") }
      if let groups = pass.dispatch { lines.append("  dispatch: [ \(groups.x), \(groups.y), \(groups.z) ]") }
      if let threads = pass.threadgroup { lines.append("  threadgroup: [ \(threads.x), \(threads.y), \(threads.z) ]") }
      if pass.everyMip { lines.append("  mip: all") }
      if !pass.inputs.isEmpty
      {
        lines.append("  inputs: [\(pass.inputs.map { "\($0.buffer).\($0.texture)" }.joined(separator: ", "))]")
      }
      switch pass.outputs
      {
        case .visible: lines.append("  outputs: visible")
        case let .buffer(buffer, textures): lines.append("  outputs: \(buffer) [ \(textures.joined(separator: ", ")) ]")
        case nil: break
      }
      return lines.joined(separator: "\n")
    }

    static func shader(_ program: any ShaderProgram) -> String
    {
      var lines = ["shader: \(program.name)"]
      let uniforms = program.uniforms
      if !uniforms.isEmpty
      {
        lines.append(list(uniforms.map(declaration), open: "  uniforms: [ ", continuation: "              "))
      }
      let varyings = program.varyings
      if !varyings.isEmpty
      {
        lines.append(list(varyings.map(declaration), open: "  varying:  [ ", continuation: "              "))
      }
      for stage in program.stages
      {
        lines.append("")
        lines.append("  \(stage.kind.rawValue):")
        if !stage.attributes.isEmpty
        {
          lines.append("    attributes:")
          lines.append(list(stage.attributes.map(declaration), open: "    [ ", continuation: "      "))
          lines.append("")
        }
        lines.append(source(stage.glsl, tag: "source:", fence: "glsl"))
        lines.append("")
        lines.append(source(Akari.ShaderSource.msl("\(program.name).\(stage.kind.rawValue)", stage.msl), tag: "source msl:", fence: "msl"))
      }
      return lines.joined(separator: "\n")
    }

    static func declaration(_ declaration: Declaration) -> String
    {
      "\(declaration.name): \(declaration.type)" + (declaration.tag.map { " <- \($0)" } ?? "")
    }

    /// a bracketed list with one entry per line, the way the graph lays them out.
    static func list(_ entries: [String], open: String, continuation: String, separator: String = ",") -> String
    {
      entries.enumerated().map
      { index, entry in
        (index == 0 ? open : continuation) + entry + (index == entries.count - 1 ? " ]" : separator)
      }.joined(separator: "\n")
    }

    static func source(_ text: String, tag: String, fence: String) -> String
    {
      let body = text.split(separator: "\n", omittingEmptySubsequences: false)
        .map { $0.isEmpty ? "" : "    " + $0 }
        .joined(separator: "\n")
      return "    \(tag)\n    ```\(fence)\n\(body)\n    ```"
    }
  }
}

// MARK: Checking

extension Akari.RenderGraph.Graph
{
  /// mistakes the labfx parser would accept but render wrong, such as an input no sampler reads.
  var diagnostics: [String]
  {
    var problems: [String] = []
    var names = Set<String>()
    for pass in passes
    {
      if !names.insert(pass.name).inserted { problems.append("pass '\(pass.name)' is declared twice") }

      var textures = Set<String>()
      for input in pass.inputs where !textures.insert(input.texture).inserted
      {
        problems.append("pass '\(pass.name)' reads two textures named '\(input.texture)', which bind to one sampler")
      }

      if pass.draw == .quad, pass.shader == nil { problems.append("pass '\(pass.name)' draws a quad without a shader") }
      if pass.outputs == nil, pass.draw != nil { problems.append("pass '\(pass.name)' has no outputs") }

      guard case let .program(program) = pass.shader else { continue }
      let samplers = Set(program.uniforms.map(\.name))
      for input in pass.inputs where !samplers.contains(input.sampler)
      {
        problems.append("pass '\(pass.name)' reads \(input.buffer).\(input.texture) but shader '\(program.name)' declares no \(input.sampler)")
      }
      let read = Set(pass.inputs.map(\.sampler))
      for sampler in samplers where sampler.hasSuffix("_texture") && !read.contains(sampler)
      {
        problems.append("shader '\(program.name)' declares \(sampler) but pass '\(pass.name)' has no input for it")
      }
    }
    return problems
  }
}

extension Akari.RenderGraph
{
  /// how one emitted section compares with the same section of a reference graph.
  enum SectionMatch
  {
    case same
    case missing
    case differs(line: Int, reference: String, emitted: String)
  }

  /// splits labfx text into its top level sections, keyed by header line.
  static func sections(of text: String) -> [(header: String, body: [String])]
  {
    var sections: [(header: String, body: [String])] = []
    for line in text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
    {
      if ["buffer: ", "pass: ", "shader: ", "texture: "].contains(where: { line.hasPrefix($0) })
      {
        sections.append((line, [line]))
      }
      else if !sections.isEmpty
      {
        sections[sections.count - 1].body.append(line)
      }
    }
    return sections.map
    { section in
      var body = section.body
      while let last = body.last, last.trimmingCharacters(in: .whitespaces).isEmpty || last.hasPrefix("-") { body.removeLast() }
      return (section.header, body)
    }
  }

  /// compares every section of the emitted text with the reference section of the same header.
  static func compare(emitted: String, reference: String) -> [(header: String, match: SectionMatch)]
  {
    let references = Dictionary(sections(of: reference).map { ($0.header, $0.body) }) { first, _ in first }
    return sections(of: emitted).map
    { section in
      guard let expected = references[section.header] else { return (section.header, .missing) }
      for index in 0 ..< max(expected.count, section.body.count)
      {
        let lhs = index < expected.count ? expected[index] : "<end>"
        let rhs = index < section.body.count ? section.body[index] : "<end>"
        if lhs != rhs { return (section.header, .differs(line: index + 1, reference: lhs, emitted: rhs)) }
      }
      return (section.header, .same)
    }
  }

  /// handles `--emit-labfx [file]` and `--check-labfx <graph.labfx>`, returning an exit code, or nil when neither is given.
  public static func runCommandLine(_ arguments: [String]) -> Int32?
  {
    let graph = deferred
    if let index = arguments.firstIndex(of: "--emit-labfx")
    {
      let text = graph.labfx
      if index + 1 < arguments.count, !arguments[index + 1].hasPrefix("-")
      {
        do { try text.write(toFile: arguments[index + 1], atomically: true, encoding: .utf8) }
        catch
        {
          print("[akari/graph] could not write \(arguments[index + 1]): \(error)")
          return 1
        }
      }
      else
      {
        print(text, terminator: "")
      }
      return 0
    }

    guard let index = arguments.firstIndex(of: "--check-labfx") else { return nil }
    guard index + 1 < arguments.count, let reference = try? String(contentsOfFile: arguments[index + 1], encoding: .utf8)
    else
    {
      print("[akari/graph] --check-labfx needs a readable .labfx file")
      return 1
    }

    var failed = false
    for (header, match) in compare(emitted: graph.labfx, reference: reference)
    {
      switch match
      {
        case .same: print("same     \(header)")
        case .missing:
          failed = true
          print("missing  \(header)")
        case let .differs(line, expected, emitted):
          failed = true
          print("differs  \(header) at line \(line)\n  reference: \(expected)\n  emitted:   \(emitted)")
      }
    }
    for problem in graph.diagnostics
    {
      failed = true
      print("warning  \(problem)")
    }
    return failed ? 1 : 0
  }
}

// MARK: Setting uniforms

extension lab.fx.Runtime
{
  /// sets a graph uniform, with the value's swift type checked against the type the shader declares.
  mutating func setUniform<Value: Akari.RenderGraph.ShaderType & UniformValue>(_ uniform: Akari.RenderGraph.Uniform<Value>, _ value: Value)
  {
    withUnsafeBytes(of: value)
    {
      setUniform(uniform.name, type: Value.glType, data: $0.baseAddress)
    }
  }
}
