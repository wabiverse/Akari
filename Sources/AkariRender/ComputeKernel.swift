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
import LabGL

extension Akari
{
  /// A compute kernel, zero when it isn't built or failed to compile.
  struct ComputeKernel: Equatable
  {
    var id: GLuint = 0

    var isBuilt: Bool
    {
      id != 0
    }

    /// Starts compiling in the background.
    init(label: String, glsl: String = "", msl: String, threadgroup: SIMD3<Int>)
    {
      id = gl.precompileComputeShader(name: label, glsl: glsl, msl: msl)
      if id != 0
      {
        gl.setComputeShaderThreadgroupSize(id, x: GLuint(threadgroup.x), y: GLuint(threadgroup.y), z: GLuint(threadgroup.z))
      }
    }

    init()
    {}

    /// Waits for the compile, false and released if it failed.
    mutating func wait() -> Bool
    {
      if id != 0, gl.waitComputeShader(id) != 0 { return true }
      release()

      return false
    }

    mutating func release()
    {
      if id != 0 { gl.deleteComputeShader(id) }
      id = 0
    }

    func set(_ uniform: ComputeUniform, index: Int? = nil, _ value: some UniformValue)
    {
      withUnsafeBytes(of: value)
      {
        gl.setComputeShaderUniform(id, name: uniform.name(index), type: type(of: value).glType, data: $0.baseAddress)
      }
    }

    /// Binds `buffers` in order from binding `first`.
    func bind(_ buffers: GLuint..., at first: Int = 0)
    {
      bind(buffers, at: first)
    }

    func bind(_ buffers: [GLuint], at first: Int = 0)
    {
      for (offset, buffer) in buffers.enumerated()
      {
        gl.setComputeShaderBuffer(id, binding: GLuint(first + offset), buffer: buffer)
      }
    }

    func sample(_ texture: GLuint, at index: Int, sampler: Int = 0)
    {
      gl.setComputeShaderSampler(id, index: GLuint(index), texture: texture, samplerIndex: GLuint(sampler))
    }

    func image(_ texture: GLuint, at index: Int, format: GLenum, level: Int = 0)
    {
      gl.setComputeShaderImage(id, index: GLuint(index), texture: texture, format: format, level: GLuint(level))
    }

    func layeredImage(_ texture: GLuint, at index: Int, format: GLenum, level: Int = 0)
    {
      gl.setComputeShaderImage(id, index: GLuint(index), texture: texture, format: format, layered: GLboolean(1),
                               level: GLuint(level))
    }

    func readback(_ readback: GLuint, at index: Int)
    {
      gl.setComputeShaderReadback(id, bindingIndex: GLuint(index), readback: readback)
    }

    func dispatch(_ x: Int, _ y: Int = 1, _ z: Int = 1)
    {
      gl.dispatchCompute(id, groupsX: GLuint(x), groupsY: GLuint(y), groupsZ: GLuint(z))
    }

    func dispatch(indirect args: GLuint, offset: Int = 0)
    {
      gl.dispatchComputeIndirect(id, argsBuffer: args, offsetBytes: GLsizei(offset))
    }
  }

  /// A set of kernels named by an enum, each case declaring its own source and threadgroup.
  protocol ComputeKernelName: CaseIterable, Hashable
  {
    /// Prefixes every kernel's label, ex. `shadow` for `akari-shadow-begin-frame`.
    static var label: String { get }
    var glsl: String { get }
    var msl: String { get }
    var threadgroup: SIMD3<Int> { get }
  }

  struct ComputeKernels<Name: ComputeKernelName>
  {
    private var kernels: [Name: ComputeKernel] = [:]

    /// True until `precompile`, a kernel that failed stays in the set unbuilt.
    var isEmpty: Bool
    {
      kernels.isEmpty
    }

    var allBuilt: Bool
    {
      !kernels.isEmpty && kernels.values.allSatisfy(\.isBuilt)
    }

    subscript(name: Name) -> ComputeKernel
    {
      kernels[name] ?? ComputeKernel()
    }

    /// Starts every kernel compiling in the background.
    static func precompile() -> Self
    {
      var set = Self()
      for name in Name.allCases
      {
        set.kernels[name] = ComputeKernel(label: "akari-\(Name.label)-\(name.kebabName)",
                                          glsl: name.glsl,
                                          msl: name.msl,
                                          threadgroup: name.threadgroup)
      }

      return set
    }

    /// Waits for every kernel and releases the ones that failed, which it returns.
    mutating func wait() -> [Name]
    {
      var failed: [Name] = []
      for name in Name.allCases where kernels[name]?.wait() != true
      {
        failed.append(name)
      }

      return failed
    }

    mutating func release()
    {
      for name in kernels.keys
      {
        kernels[name]?.release()
      }

      kernels = [:]
    }
  }

  /// Buffers named by an enum, each case declaring its own usage and size.
  protocol GPUBufferName: CaseIterable, Hashable
  {
    var usage: GLuint { get }
    var bytes: Int { get }
  }

  struct GPUBuffers<Name: GPUBufferName>
  {
    private var buffers: [Name: GLuint] = [:]

    subscript(name: Name) -> GLuint
    {
      buffers[name] ?? 0
    }

    /// Every buffer, nil if any failed to allocate.
    static func make() -> Self?
    {
      var set = Self()
      for name in Name.allCases
      {
        let buffer = gl.createBuffer(usage: name.usage, sizeBytes: GLsizei(name.bytes))
        set.buffers[name] = buffer
        guard buffer != 0 else { set.release(); return nil }
      }

      return set
    }

    mutating func release()
    {
      for buffer in buffers.values where buffer != 0
      {
        gl.deleteBuffer(buffer)
      }

      buffers = [:]
    }
  }
}

extension Akari.ComputeKernelName
{
  var glsl: String
  {
    ""
  }

  /// The case name as a label, ex. `beginFrame` as `begin-frame`.
  var kebabName: String
  {
    String(describing: self).reduce(into: "")
    { name, c in
      if c.isUppercase { name += "-" }
      name += c.lowercased()
    }
  }
}

/// A value a uniform takes, with the GL type it uploads as.
protocol UniformValue
{
  static var glType: GLenum { get }
}

protocol UniformScalar: SIMDScalar, UniformValue, Hashable, Codable
{
  static var vec3Type: GLenum { get }
  static var vec4Type: GLenum { get }
}

extension Int32: UniformScalar
{
  static var glType: GLenum { GL_INT }
  static var vec3Type: GLenum { GLenum(GL_INT_VEC3) }
  static var vec4Type: GLenum { GL_INT_VEC4 }
}

extension Float: UniformScalar
{
  static var glType: GLenum { GL_FLOAT }
  static var vec3Type: GLenum { GLenum(GL_FLOAT_VEC3) }
  static var vec4Type: GLenum { GL_FLOAT_VEC4 }
}

extension SIMD3: UniformValue where Scalar: UniformScalar
{
  static var glType: GLenum { Scalar.vec3Type }
}

extension SIMD4: UniformValue where Scalar: UniformScalar
{
  static var glType: GLenum { Scalar.vec4Type }
}

extension Akari.Matrix4: UniformValue
{
  static var glType: GLenum { GL_FLOAT_MAT4 }
}
