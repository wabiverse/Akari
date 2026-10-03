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
  /// The static capture's draws the camera sees, culled and encoded on the GPU.
  struct CameraCull
  {
    var kernel: GLuint = 0
    var bounds: GLuint = 0
    var visibility: GLuint = 0
    var capacity = 0
    var count = 0
    var generation: UInt64 = .max
  }

  /// Camera culled replay slot, the shadows take the ones above.
  static let cameraCullSlot: Int32 = 0

  static let cameraCullGLSL = """
    #version 430
    layout(local_size_x = 64, local_size_y = 1, local_size_z = 1) in;
    layout(std430, binding = 0) buffer Bounds { float bounds[]; };
    layout(std430, binding = 1) buffer Visibility { uint visibility[]; };
    uniform mat4 u_viewProj;
    uniform ivec4 u_params;
    void main()
    {
      int draw = int(gl_GlobalInvocationID.x);
      if (draw >= u_params.x) return;
      vec3 lo = vec3(bounds[draw * 6 + 0], bounds[draw * 6 + 1], bounds[draw * 6 + 2]);
      vec3 hi = vec3(bounds[draw * 6 + 3], bounds[draw * 6 + 4], bounds[draw * 6 + 5]);
      int out0 = 0, out1 = 0, out2 = 0, out3 = 0, out4 = 0, out5 = 0;
      for (int c = 0; c < 8; ++c)
      {
        vec4 p = u_viewProj * vec4((c & 1) != 0 ? hi.x : lo.x, (c & 2) != 0 ? hi.y : lo.y,
                                   (c & 4) != 0 ? hi.z : lo.z, 1.0);
        out0 += p.x < -p.w ? 1 : 0;
        out1 += p.x > p.w ? 1 : 0;
        out2 += p.y < -p.w ? 1 : 0;
        out3 += p.y > p.w ? 1 : 0;
        out4 += p.z < -p.w ? 1 : 0;
        out5 += p.z > p.w ? 1 : 0;
      }
      visibility[draw] = out0 < 8 && out1 < 8 && out2 < 8 && out3 < 8 && out4 < 8 && out5 < 8 ? 1u : 0u;
    }
    """

  static let cameraCullMSL = """
    #include <metal_stdlib>
    using namespace metal;
    struct U { float4x4 viewProj; int4 params; };
    kernel void compute_main(constant U& u [[buffer(0)]],
                             device const float* bounds [[buffer(1)]],
                             device uint* visibility [[buffer(2)]],
                             uint gid [[thread_position_in_grid]])
    {
      int draw = int(gid);
      if (draw >= u.params.x) return;
      float3 lo = float3(bounds[draw * 6 + 0], bounds[draw * 6 + 1], bounds[draw * 6 + 2]);
      float3 hi = float3(bounds[draw * 6 + 3], bounds[draw * 6 + 4], bounds[draw * 6 + 5]);
      int out0 = 0, out1 = 0, out2 = 0, out3 = 0, out4 = 0, out5 = 0;
      for (int c = 0; c < 8; ++c)
      {
        float4 p = u.viewProj * float4((c & 1) != 0 ? hi.x : lo.x, (c & 2) != 0 ? hi.y : lo.y,
                                       (c & 4) != 0 ? hi.z : lo.z, 1.0);
        out0 += p.x < -p.w ? 1 : 0;
        out1 += p.x > p.w ? 1 : 0;
        out2 += p.y < -p.w ? 1 : 0;
        out3 += p.y > p.w ? 1 : 0;
        out4 += p.z < -p.w ? 1 : 0;
        out5 += p.z > p.w ? 1 : 0;
      }
      visibility[draw] = out0 < 8 && out1 < 8 && out2 < 8 && out3 < 8 && out4 < 8 && out5 < 8 ? 1u : 0u;
    }
    """

  /// Culls the static capture's draws to `viewProjection` and encodes the survivors
  /// for the G-buffer's replay, which falls back to every draw when this can't.
  func cullStaticGeometry(viewProjection: Akari.Matrix4)
  {
    runtime.setMeshCaptureCulledSlot("mesh", slot: encodeCameraCull(viewProjection) ? Self.cameraCullSlot : -1)
  }

  private func encodeCameraCull(_ viewProjection: Akari.Matrix4) -> Bool
  {
    guard
      !geometry.staticBatch.isEmpty,
      let capture = geometry.staticCapture
    else { return false }

    var cull = geometry.cameraCull
    defer { geometry.cameraCull = cull }

    if cull.kernel == 0
    {
      cull.kernel = gl.precompileComputeShader(name: "akari-camera-cull", glsl: Self.cameraCullGLSL,
                                               msl: Self.cameraCullMSL)
    }
    guard
      cull.kernel != 0,
      gl.waitComputeShader(cull.kernel) != 0
    else { return false }

    let generation = labgl.captureGeneration(capture)
    if generation != cull.generation
    {
      cull.generation = generation
      cull.count = 0
      var bounds: UnsafePointer<Float>? = nil
      let count = Int(labgl.captureIndirectDrawBounds(capture, bounds: &bounds))
      guard
        count > 0,
        let bounds
      else { return false }

      if count > cull.capacity
      {
        for buffer in [cull.bounds, cull.visibility] where buffer != 0
        {
          gl.deleteBuffer(buffer)
        }
        cull.bounds = gl.createBuffer(usage: LGL_BUFFER_COMPUTE_READ | LGL_BUFFER_MAP_WRITE,
                                      sizeBytes: GLsizei(count * 6 * MemoryLayout<Float>.size))
        cull.visibility = gl.createBuffer(usage: LGL_BUFFER_COMPUTE_READ | LGL_BUFFER_COMPUTE_WRITE,
                                          sizeBytes: GLsizei(count * MemoryLayout<UInt32>.size))
        cull.capacity = count
      }
      guard
        cull.bounds != 0,
        cull.visibility != 0,
        let p = gl.mapBuffer(cull.bounds)
      else { return false }
      p.copyMemory(from: bounds, byteCount: count * 6 * MemoryLayout<Float>.size)
      gl.unmapBuffer(cull.bounds)
      cull.count = count
    }
    guard cull.count > 0 else { return false }

    let kernel = cull.kernel
    gl.setComputeShaderThreadgroupSize(kernel, x: 64, y: 1, z: 1)
    viewProjection.withUnsafeFloats
    { buf in
      gl.setComputeShaderUniform(kernel, name: "u_viewProj", type: GL_FLOAT_MAT4, data: buf.baseAddress)
    }
    var params = SIMD4<Int32>(Int32(cull.count), 0, 0, 0)
    gl.setComputeShaderUniform(kernel, name: "u_params", type: GL_INT_VEC4, data: &params)
    gl.setComputeShaderBuffer(kernel, binding: 0, buffer: cull.bounds)
    gl.setComputeShaderBuffer(kernel, binding: 1, buffer: cull.visibility)
    gl.dispatchCompute(kernel, groupsX: GLuint((cull.count + 63) / 64), groupsY: 1, groupsZ: 1)

    return labgl.captureEncodeCulled(capture, visibility: cull.visibility, offset: 0,
                                     slot: UInt32(Self.cameraCullSlot), instanceStride: 0) != 0
  }
}
