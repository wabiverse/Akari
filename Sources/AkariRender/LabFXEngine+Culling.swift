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
import LabFX
import LabGL

extension Akari.LabFXEngine
{
  /// The static capture's draws the camera sees, culled and encoded on the GPU
  /// in two passes (last frame's survivors first, then whatever the Hi-Z of those
  /// doesn't hide.
  struct CameraCull
  {
    var kernel: GLuint = 0
    var lateKernel: GLuint = 0
    var hzbFirstKernel: GLuint = 0
    var hzbReduceKernel: GLuint = 0
    var bounds: GLuint = 0
    var visibility: GLuint = 0
    var lateVisibility: GLuint = 0
    var lastVisible: GLuint = 0
    var capacity = 0
    var count = 0
    var generation: UInt64 = .max
    /// Last frame's survivors are stale, the early pass takes every draw in the frustum.
    var reset = true
    var encoded = false
    /// Farthest view distance per texel, each level half the last, packed one after another.
    var hzb: GLuint = 0
    var hzbCapacity = 0
    var levels: [SIMD4<Int32>] = []
    var levelBuffer: GLuint = 0
    var levelSize = SIMD2<Int>(0, 0)
    var viewProjection = Akari.Matrix4.identity
    var perspective = false
  }

  /// Camera culled replay slots, the shadows take the ones above.
  static let cameraCullSlot: Int32 = 0
  static let cameraLateCullSlot: Int32 = 1

  static let frustumGLSL = """
    bool inFrustum(vec3 lo, vec3 hi, mat4 viewProj)
    {
      int out0 = 0, out1 = 0, out2 = 0, out3 = 0, out4 = 0, out5 = 0;
      for (int c = 0; c < 8; ++c)
      {
        vec4 p = viewProj * vec4((c & 1) != 0 ? hi.x : lo.x, (c & 2) != 0 ? hi.y : lo.y,
                                 (c & 4) != 0 ? hi.z : lo.z, 1.0);
        out0 += p.x < -p.w ? 1 : 0;
        out1 += p.x > p.w ? 1 : 0;
        out2 += p.y < -p.w ? 1 : 0;
        out3 += p.y > p.w ? 1 : 0;
        out4 += p.z < -p.w ? 1 : 0;
        out5 += p.z > p.w ? 1 : 0;
      }
      return out0 < 8 && out1 < 8 && out2 < 8 && out3 < 8 && out4 < 8 && out5 < 8;
    }
    """

  static let frustumMSL = frustumGLSL
    .replacingOccurrences(of: "vec3", with: "float3")
    .replacingOccurrences(of: "vec4", with: "float4")
    .replacingOccurrences(of: "mat4", with: "float4x4")

  static let cameraCullGLSL = """
    #version 430
    layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
    layout(std430, binding = 0) buffer Bounds { float bounds[]; };
    layout(std430, binding = 1) buffer Visibility { uint visibility[]; };
    layout(std430, binding = 2) buffer LastVisible { uint last_visible[]; };
    uniform mat4 u_viewProj;
    uniform ivec4 u_params;
    \(frustumGLSL)
    void main()
    {
      int draw = int(gl_GlobalInvocationID.x);
      if (draw >= u_params.x) return;
      vec3 lo = vec3(bounds[draw * 6 + 0], bounds[draw * 6 + 1], bounds[draw * 6 + 2]);
      vec3 hi = vec3(bounds[draw * 6 + 3], bounds[draw * 6 + 4], bounds[draw * 6 + 5]);
      bool seen = u_params.y != 0 || last_visible[draw] != 0u;
      visibility[draw] = seen && inFrustum(lo, hi, u_viewProj) ? 1u : 0u;
    }
    """

  static let cameraCullMSL = """
    #include <metal_stdlib>
    using namespace metal;
    struct U { float4x4 viewProj; int4 params; };
    \(frustumMSL)
    kernel void compute_main(constant U& u [[buffer(0)]],
                             device const float* bounds [[buffer(1)]],
                             device uint* visibility [[buffer(2)]],
                             device const uint* last_visible [[buffer(3)]],
                             uint gid [[thread_position_in_grid]])
    {
      int draw = int(gid);
      if (draw >= u.params.x) return;
      float3 lo = float3(bounds[draw * 6 + 0], bounds[draw * 6 + 1], bounds[draw * 6 + 2]);
      float3 hi = float3(bounds[draw * 6 + 3], bounds[draw * 6 + 4], bounds[draw * 6 + 5]);
      bool seen = u.params.y != 0 || last_visible[draw] != 0u;
      visibility[draw] = seen && inFrustum(lo, hi, u.viewProj) ? 1u : 0u;
    }
    """

  static let hzbFirstGLSL = """
    #version 430
    layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
    layout(std430, binding = 0) buffer Hzb { float hzb[]; };
    layout(binding = 1) uniform sampler2D u_position;
    uniform ivec4 u_params;
    void main()
    {
      ivec2 p = ivec2(gl_GlobalInvocationID.xy);
      if (p.x >= u_params.z || p.y >= u_params.w) return;
      ivec2 screen = u_params.xy;
      float m = 0.0;
      for (int i = 0; i < 4; ++i) {
        ivec2 s = min(p * 2 + ivec2(i & 1, i >> 1), screen - 1);
        vec3 q = texelFetch(u_position, s, 0).xyz;
        m = max(m, q == vec3(0.0) ? 1e30 : -q.z);
      }
      hzb[p.y * u_params.z + p.x] = m;
    }
    """

  static let hzbFirstMSL = """
    #include <metal_stdlib>
    using namespace metal;
    struct U { int4 params; };
    kernel void compute_main(constant U& u [[buffer(0)]],
                             device float* hzb [[buffer(1)]],
                             texture2d<float> posTex [[texture(1)]],
                             sampler posSampler [[sampler(0)]],
                             uint2 gid [[thread_position_in_grid]])
    {
      int2 p = int2(gid);
      if (p.x >= u.params.z || p.y >= u.params.w) return;
      int2 screen = u.params.xy;
      float m = 0.0;
      for (int i = 0; i < 4; ++i) {
        int2 s = min(p * 2 + int2(i & 1, i >> 1), screen - 1);
        float3 q = posTex.read(uint2(s)).xyz;
        m = max(m, all(q == float3(0.0)) ? 1e30 : -q.z);
      }
      hzb[p.y * u.params.z + p.x] = m;
    }
    """

  static let hzbReduceGLSL = """
    #version 430
    layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
    layout(std430, binding = 0) buffer Hzb { float hzb[]; };
    uniform ivec4 u_src;
    uniform ivec4 u_dst;
    void main()
    {
      ivec2 p = ivec2(gl_GlobalInvocationID.xy);
      if (p.x >= u_dst.y || p.y >= u_dst.z) return;
      float m = 0.0;
      for (int i = 0; i < 4; ++i) {
        ivec2 s = min(p * 2 + ivec2(i & 1, i >> 1), u_src.yz - 1);
        m = max(m, hzb[u_src.x + s.y * u_src.y + s.x]);
      }
      hzb[u_dst.x + p.y * u_dst.y + p.x] = m;
    }
    """

  static let hzbReduceMSL = """
    #include <metal_stdlib>
    using namespace metal;
    struct U { int4 src; int4 dst; };
    kernel void compute_main(constant U& u [[buffer(0)]],
                             device float* hzb [[buffer(1)]],
                             uint2 gid [[thread_position_in_grid]])
    {
      int2 p = int2(gid);
      if (p.x >= u.dst.y || p.y >= u.dst.z) return;
      float m = 0.0;
      for (int i = 0; i < 4; ++i) {
        int2 s = min(p * 2 + int2(i & 1, i >> 1), u.src.yz - 1);
        m = max(m, hzb[u.src.x + s.y * u.src.y + s.x]);
      }
      hzb[u.dst.x + p.y * u.dst.y + p.x] = m;
    }
    """

  /// Whether a box is behind the Hi-Z, its nearest distance past the farthest
  /// one under the up to 2x2 texels of the level its screen rect fits.
  static let occludedBody = """
      float nearest = 1e30;
      VEC2 lo2 = VEC2(1e30), hi2 = VEC2(-1e30);
      bool crossesNear = false;
      for (int c = 0; c < 8; ++c)
      {
        VEC4 p = VIEWPROJ * VEC4((c & 1) != 0 ? hi.x : lo.x, (c & 2) != 0 ? hi.y : lo.y,
                                 (c & 4) != 0 ? hi.z : lo.z, 1.0);
        if (p.w <= 1e-4) { crossesNear = true; break; }
        nearest = min(nearest, p.w);
        lo2 = min(lo2, p.xy / p.w);
        hi2 = max(hi2, p.xy / p.w);
      }
      bool occluded = false;
      if (!crossesNear && PARAMS.z != 0)
      {
        VEC2 screen = SCREEN.xy;
        VEC2 a = (clamp(lo2, VEC2(-1.0), VEC2(1.0)) * 0.5 + 0.5) * screen;
        VEC2 b = (clamp(hi2, VEC2(-1.0), VEC2(1.0)) * 0.5 + 0.5) * screen;
        float extent = max(max(b.x - a.x, b.y - a.y), 1.0);
        int level = clamp(int(ceil(log2(extent))) - 1, 0, PARAMS.y - 1);
        float texel = float(2 << level);
        IVEC4 info = LEVELS[level];
        IVEC2 t0 = clamp(IVEC2(floor(a / texel)), IVEC2(0), info.yz - 1);
        IVEC2 t1 = clamp(IVEC2(floor(b / texel)), IVEC2(0), info.yz - 1);
        float farthest = 0.0;
        for (int y = t0.y; y <= t1.y; ++y)
          for (int x = t0.x; x <= t1.x; ++x)
            farthest = max(farthest, hzb[info.x + y * info.y + x]);
        occluded = nearest > farthest;
      }
    """

  static let lateCullGLSL = """
    #version 430
    layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
    layout(std430, binding = 0) buffer Bounds { float bounds[]; };
    layout(std430, binding = 1) buffer Visibility { uint visibility[]; };
    layout(std430, binding = 2) buffer LastVisible { uint last_visible[]; };
    layout(std430, binding = 3) buffer LateVisibility { uint late_visibility[]; };
    layout(std430, binding = 4) buffer Hzb { float hzb[]; };
    layout(std430, binding = 5) buffer Levels { ivec4 levels[]; };
    uniform mat4 u_viewProj;
    uniform ivec4 u_params;
    uniform vec4 u_screen;
    #define VEC2 vec2
    #define VEC4 vec4
    #define IVEC2 ivec2
    #define IVEC4 ivec4
    #define VIEWPROJ u_viewProj
    #define PARAMS u_params
    #define SCREEN u_screen
    #define LEVELS levels
    \(frustumGLSL)
    void main()
    {
      int draw = int(gl_GlobalInvocationID.x);
      if (draw >= u_params.x) return;
      vec3 lo = vec3(bounds[draw * 6 + 0], bounds[draw * 6 + 1], bounds[draw * 6 + 2]);
      vec3 hi = vec3(bounds[draw * 6 + 3], bounds[draw * 6 + 4], bounds[draw * 6 + 5]);
      bool visible = inFrustum(lo, hi, u_viewProj);
      if (visible)
      {
        \(occludedBody)
        visible = !occluded;
      }
      last_visible[draw] = visible ? 1u : 0u;
      late_visibility[draw] = visible && visibility[draw] == 0u ? 1u : 0u;
    }
    """

  static let lateCullMSL = """
    #include <metal_stdlib>
    using namespace metal;
    struct U { float4x4 viewProj; int4 params; float4 screen; };
    #define VEC2 float2
    #define VEC4 float4
    #define IVEC2 int2
    #define IVEC4 int4
    #define VIEWPROJ u.viewProj
    #define PARAMS u.params
    #define SCREEN u.screen
    #define LEVELS levels
    \(frustumMSL)
    kernel void compute_main(constant U& u [[buffer(0)]],
                             device const float* bounds [[buffer(1)]],
                             device const uint* visibility [[buffer(2)]],
                             device uint* last_visible [[buffer(3)]],
                             device uint* late_visibility [[buffer(4)]],
                             device const float* hzb [[buffer(5)]],
                             device const int4* levels [[buffer(6)]],
                             uint gid [[thread_position_in_grid]])
    {
      int draw = int(gid);
      if (draw >= u.params.x) return;
      float3 lo = float3(bounds[draw * 6 + 0], bounds[draw * 6 + 1], bounds[draw * 6 + 2]);
      float3 hi = float3(bounds[draw * 6 + 3], bounds[draw * 6 + 4], bounds[draw * 6 + 5]);
      bool visible = inFrustum(lo, hi, u.viewProj);
      if (visible)
      {
        \(occludedBody)
        visible = !occluded;
      }
      last_visible[draw] = visible ? 1u : 0u;
      late_visibility[draw] = visible && visibility[draw] == 0u ? 1u : 0u;
    }
    """

  /// Culls the static capture's draws to `viewProjection` and last frame's survivors, and encodes
  /// them for the G-buffer's early replay, which falls back to every draw when this can't.
  func cullStaticGeometry(projection: Akari.Matrix4, view: Akari.Matrix4)
  {
    let viewProjection = projection * view
    geometry.cameraCull.viewProjection = viewProjection
    geometry.cameraCull.perspective = projection[2, 3] < -0.5
    geometry.cameraCull.encoded = encodeCameraCull(viewProjection)
    runtime.setMeshCaptureCulledSlot("mesh", slot: geometry.cameraCull.encoded ? Self.cameraCullSlot : -1)
  }

  private func compile(_ kernel: inout GLuint, _ name: String, _ glsl: String, _ msl: String,
                       x: GLuint, y: GLuint) -> Bool
  {
    if kernel == 0
    {
      kernel = gl.precompileComputeShader(name: name, glsl: glsl, msl: msl)
      if kernel != 0 { gl.setComputeShaderThreadgroupSize(kernel, x: x, y: y, z: 1) }
    }
    return kernel != 0 && gl.waitComputeShader(kernel) != 0
  }

  private func encodeCameraCull(_ viewProjection: Akari.Matrix4) -> Bool
  {
    guard
      !geometry.staticBatch.isEmpty,
      let capture = geometry.staticCapture
    else { return false }

    var cull = geometry.cameraCull
    defer { geometry.cameraCull = cull }

    guard compile(&cull.kernel, "akari-camera-cull", Self.cameraCullGLSL, Self.cameraCullMSL, x: 64, y: 1)
    else { return false }

    let generation = labgl.captureGeneration(capture)
    if generation != cull.generation
    {
      cull.generation = generation
      cull.count = 0
      cull.reset = true
      var bounds: UnsafePointer<Float>? = nil
      let count = Int(labgl.captureIndirectDrawBounds(capture, bounds: &bounds))
      guard
        count > 0,
        let bounds
      else { return false }

      if count > cull.capacity
      {
        for buffer in [cull.bounds, cull.visibility, cull.lateVisibility, cull.lastVisible] where buffer != 0
        {
          gl.deleteBuffer(buffer)
        }
        let flags = LGL_BUFFER_COMPUTE_READ | LGL_BUFFER_COMPUTE_WRITE
        let size = GLsizei(count * MemoryLayout<UInt32>.size)
        cull.bounds = gl.createBuffer(usage: LGL_BUFFER_COMPUTE_READ | LGL_BUFFER_MAP_WRITE,
                                      sizeBytes: GLsizei(count * 6 * MemoryLayout<Float>.size))
        cull.visibility = gl.createBuffer(usage: flags, sizeBytes: size)
        cull.lateVisibility = gl.createBuffer(usage: flags, sizeBytes: size)
        cull.lastVisible = gl.createBuffer(usage: flags, sizeBytes: size)
        cull.capacity = count
      }
      guard
        cull.bounds != 0,
        cull.visibility != 0,
        cull.lateVisibility != 0,
        cull.lastVisible != 0,
        let p = gl.mapBuffer(cull.bounds)
      else { return false }
      p.copyMemory(from: bounds, byteCount: count * 6 * MemoryLayout<Float>.size)
      gl.unmapBuffer(cull.bounds)
      cull.count = count
    }
    guard cull.count > 0 else { return false }

    let kernel = cull.kernel
    viewProjection.withUnsafeFloats
    { buf in
      gl.setComputeShaderUniform(kernel, name: "u_viewProj", type: GL_FLOAT_MAT4, data: buf.baseAddress)
    }
    var params = SIMD4<Int32>(Int32(cull.count), cull.reset ? 1 : 0, 0, 0)
    gl.setComputeShaderUniform(kernel, name: "u_params", type: GL_INT_VEC4, data: &params)
    gl.setComputeShaderBuffer(kernel, binding: 0, buffer: cull.bounds)
    gl.setComputeShaderBuffer(kernel, binding: 1, buffer: cull.visibility)
    gl.setComputeShaderBuffer(kernel, binding: 2, buffer: cull.lastVisible)
    gl.dispatchCompute(kernel,
                       groupsX: GLuint((cull.count + 63) / 64),
                       groupsY: 1,
                       groupsZ: 1)

    return labgl.captureEncodeCulled(capture, visibility: cull.visibility, offset: 0,
                                     slot: UInt32(Self.cameraCullSlot), instanceStride: 0) != 0
  }

  /// After the early replay: builds the Hi-Z of what it drew, tests every draw in
  /// the frustum against it and encodes those the early replay missed for the late
  /// one.
  func encodeLateCull() -> Bool
  {
    guard
      geometry.cameraCull.encoded,
      let capture = geometry.staticCapture
    else { return false }

    var cull = geometry.cameraCull
    defer { geometry.cameraCull = cull }

    guard
      compile(&cull.lateKernel, "akari-camera-cull-late", Self.lateCullGLSL, Self.lateCullMSL, x: 64, y: 1),
      compile(&cull.hzbFirstKernel, "akari-hzb-first", Self.hzbFirstGLSL, Self.hzbFirstMSL, x: 8, y: 8),
      compile(&cull.hzbReduceKernel, "akari-hzb-reduce", Self.hzbReduceGLSL, Self.hzbReduceMSL, x: 8, y: 8),
      ensureHzb(&cull)
    else { return false }

    let position = runtime.texture("gbuffer", named: "position")
    guard position != 0 else { return false }

    let first = cull.levels[0]
    var firstParams = SIMD4<Int32>(Int32(renderWidth), Int32(renderHeight), first.y, first.z)
    gl.setComputeShaderUniform(cull.hzbFirstKernel, name: "u_params", type: GL_INT_VEC4, data: &firstParams)
    gl.setComputeShaderBuffer(cull.hzbFirstKernel, binding: 0, buffer: cull.hzb)
    gl.setComputeShaderSampler(cull.hzbFirstKernel, index: 1, texture: position, samplerIndex: 0)
    gl.dispatchCompute(cull.hzbFirstKernel,
                       groupsX: GLuint((first.y + 7) / 8),
                       groupsY: GLuint((first.z + 7) / 8),
                       groupsZ: 1)

    for (src, dst) in zip(cull.levels, cull.levels.dropFirst())
    {
      var s = src
      var d = dst
      gl.setComputeShaderUniform(cull.hzbReduceKernel, name: "u_src", type: GL_INT_VEC4, data: &s)
      gl.setComputeShaderUniform(cull.hzbReduceKernel, name: "u_dst", type: GL_INT_VEC4, data: &d)
      gl.setComputeShaderBuffer(cull.hzbReduceKernel, binding: 0, buffer: cull.hzb)
      gl.dispatchCompute(cull.hzbReduceKernel,
                         groupsX: GLuint((dst.y + 7) / 8),
                         groupsY: GLuint((dst.z + 7) / 8),
                         groupsZ: 1)
    }

    let kernel = cull.lateKernel
    cull.viewProjection.withUnsafeFloats
    { buf in
      gl.setComputeShaderUniform(kernel, name: "u_viewProj", type: GL_FLOAT_MAT4, data: buf.baseAddress)
    }
    var params = SIMD4<Int32>(Int32(cull.count), Int32(cull.levels.count), cull.perspective ? 1 : 0, 0)
    gl.setComputeShaderUniform(kernel, name: "u_params", type: GL_INT_VEC4, data: &params)

    var screen = SIMD4<Float>(Float(renderWidth), Float(renderHeight), 0, 0)
    gl.setComputeShaderUniform(kernel, name: "u_screen", type: GL_FLOAT_VEC4, data: &screen)
    gl.setComputeShaderBuffer(kernel, binding: 0, buffer: cull.bounds)
    gl.setComputeShaderBuffer(kernel, binding: 1, buffer: cull.visibility)
    gl.setComputeShaderBuffer(kernel, binding: 2, buffer: cull.lastVisible)
    gl.setComputeShaderBuffer(kernel, binding: 3, buffer: cull.lateVisibility)
    gl.setComputeShaderBuffer(kernel, binding: 4, buffer: cull.hzb)
    gl.setComputeShaderBuffer(kernel, binding: 5, buffer: cull.levelBuffer)
    gl.dispatchCompute(kernel,
                       groupsX: GLuint((cull.count + 63) / 64),
                       groupsY: 1,
                       groupsZ: 1)
    cull.reset = false

    return labgl.captureEncodeCulled(capture, visibility: cull.lateVisibility, offset: 0,
                                     slot: UInt32(Self.cameraLateCullSlot), instanceStride: 0) != 0
  }

  /// Lays the Hi-Z levels out for the render size, from half of it down to one texel.
  private func ensureHzb(_ cull: inout CameraCull) -> Bool
  {
    let size = SIMD2(max(renderWidth, 1), max(renderHeight, 1))
    if size == cull.levelSize, cull.hzb != 0, cull.levelBuffer != 0 { return true }

    var levels: [SIMD4<Int32>] = []
    var offset = 0
    var w = (size.x + 1) / 2
    var h = (size.y + 1) / 2
    while true
    {
      levels.append(SIMD4(Int32(offset), Int32(w), Int32(h), 0))
      offset += w * h
      if w == 1, h == 1 { break }
      w = (w + 1) / 2
      h = (h + 1) / 2
    }

    if offset > cull.hzbCapacity
    {
      if cull.hzb != 0 { gl.deleteBuffer(cull.hzb) }
      cull.hzb = gl.createBuffer(usage: LGL_BUFFER_COMPUTE_READ | LGL_BUFFER_COMPUTE_WRITE,
                                 sizeBytes: GLsizei(offset * MemoryLayout<Float>.size))
      cull.hzbCapacity = cull.hzb != 0 ? offset : 0
    }
    if cull.levelBuffer == 0
    {
      cull.levelBuffer = gl.createBuffer(usage: LGL_BUFFER_COMPUTE_READ | LGL_BUFFER_MAP_WRITE,
                                         sizeBytes: GLsizei(32 * MemoryLayout<SIMD4<Int32>>.size))
    }
    guard
      cull.hzb != 0,
      cull.levelBuffer != 0,
      levels.count <= 32,
      let p = gl.mapBuffer(cull.levelBuffer)
    else { return false }

    levels.withUnsafeBytes { p.copyMemory(from: $0.baseAddress!, byteCount: $0.count) }
    gl.unmapBuffer(cull.levelBuffer)

    cull.levels = levels
    cull.levelSize = size
    // the survivors were tested at the old size.
    cull.reset = true
    return true
  }
}
