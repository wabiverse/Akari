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

public extension Akari
{
  final class FroxelVolume
  {
    /// Per froxel column, the farthest view depth it shows.
    public private(set) var depthTexture: GLuint = 0
    private var depthSize = SIMD2<Int>(0, 0)
    private var depthShader: GLuint = 0
    private var integrateShader: GLuint = 0
    private var built = false
    private var failed = false

    public init()
    {}

    deinit
    {
      release()
    }

    /// Compiles the kernels once.
    public func prepare() -> Bool
    {
      if built { return true }
      if failed { return false }

      depthShader = gl.defineComputeShader(name: "akari-froxel-depth",
                                           glsl: Self.depthGLSL,
                                           msl: Self.depthMSL)
      integrateShader = gl.defineComputeShader(name: "akari-froxel-integrate",
                                               glsl: Self.integrateGLSL,
                                               msl: Self.integrateMSL)
      guard depthShader != 0, integrateShader != 0
      else
      {
        print("[akari/volume] froxel compute kernels failed to compile, volumetrics disabled")
        release()
        failed = true
        return false
      }
      gl.setComputeShaderThreadgroupSize(depthShader, x: 16, y: 16, z: 1)
      gl.setComputeShaderThreadgroupSize(integrateShader, x: 8, y: 8, z: 1)
      built = true
      return true
    }

    /// Reduces the G-buffer to `depthTexture`, one threadgroup per froxel column.
    public func reduceDepth(gbufferPosition: GLuint,
                            gridWidth: Int,
                            gridHeight: Int,
                            screenWidth: Int,
                            screenHeight: Int) -> Bool
    {
      guard
        prepare(),
        gbufferPosition != 0,
        gridWidth > 0,
        gridHeight > 0,
        ensureDepthTexture(width: gridWidth, height: gridHeight)
      else { return false }

      var params = SIMD4<Float>(Float(gridWidth), Float(gridHeight), Float(screenWidth), Float(screenHeight))
      gl.setComputeShaderUniform(depthShader, name: "u_params", type: GL_FLOAT_VEC4, data: &params)
      gl.setComputeShaderImage(depthShader, index: 0, texture: depthTexture,
                               format: GL_RGBA32F, level: 0)
      gl.setComputeShaderSampler(depthShader, index: 1, texture: gbufferPosition, samplerIndex: 0)
      gl.dispatchCompute(depthShader,
                         groupsX: GLuint(gridWidth),
                         groupsY: GLuint(gridHeight),
                         groupsZ: 1)
      return true
    }

    /// Composites each column's slabs front to back into the integrated atlas the deferred
    /// resolve samples.
    public func integrate(scatter: GLuint, integrated: GLuint, gridWidth: Int, gridHeight: Int)
    {
      guard
        built,
        scatter != 0,
        integrated != 0,
        gridWidth > 0,
        gridHeight > 0
      else { return }

      var params = SIMD4<Float>(Float(gridWidth), Float(gridHeight), 0, 0)
      gl.setComputeShaderUniform(integrateShader, name: "u_params", type: GL_FLOAT_VEC4, data: &params)
      gl.setComputeShaderImage(integrateShader, index: 0, texture: integrated,
                               format: GLenum(GL_RGBA16F), level: 0)
      gl.setComputeShaderSampler(integrateShader, index: 1, texture: scatter, samplerIndex: 0)
      gl.dispatchCompute(integrateShader,
                         groupsX: GLuint((gridWidth + 7) / 8),
                         groupsY: GLuint((gridHeight + 7) / 8),
                         groupsZ: 1)
    }

    public func release()
    {
      if depthTexture != 0
      {
        var tex = depthTexture
        gl.deleteTextures(count: 1, textures: &tex)
        depthTexture = 0
      }
      depthSize = .zero
      for shader in [depthShader, integrateShader] where shader != 0
      {
        gl.deleteComputeShader(shader)
      }
      depthShader = 0
      integrateShader = 0
      built = false
    }

    /// Only reallocates when the froxel grid itself changes size.
    private func ensureDepthTexture(width: Int, height: Int) -> Bool
    {
      if depthTexture != 0, depthSize == SIMD2(width, height) { return true }
      if depthTexture != 0
      {
        var tex = depthTexture
        gl.deleteTextures(count: 1, textures: &tex)
        depthTexture = 0
      }

      var tex: GLuint = 0
      gl.genTextures(count: 1, textures: &tex)
      guard tex != 0 else { return false }

      gl.bindTexture(target: GL_TEXTURE_2D, texture: tex)
      gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_MIN_FILTER, param: GLint(GL_NEAREST))
      gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_MAG_FILTER, param: GLint(GL_NEAREST))
      gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_WRAP_S, param: GLint(GL_CLAMP_TO_EDGE))
      gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_WRAP_T, param: GLint(GL_CLAMP_TO_EDGE))
      gl.texImage2D(target: GL_TEXTURE_2D,
                    level: 0,
                    internalFormat: GL_RGBA32F,
                    width: GLsizei(width),
                    height: GLsizei(height),
                    border: 0,
                    format: GL_RGBA,
                    type: GL_FLOAT,
                    pixels: nil)
      gl.bindTexture(target: GL_TEXTURE_2D, texture: 0)

      depthTexture = tex
      depthSize = SIMD2(width, height)
      return true
    }

    /// Farthest view depth under each froxel column.
    private static let depthCommon = """
      ivec2 regionStart(ivec2 froxel, ivec2 grid, ivec2 screen)
      {
        ivec2 viaResolve = froxel * 16 - 8;
        ivec2 viaScatter = ivec2(floor(vec2(froxel) * vec2(screen) / vec2(grid)));
        return max(min(viaResolve, viaScatter), ivec2(0));
      }
      ivec2 regionEnd(ivec2 froxel, ivec2 grid, ivec2 screen)
      {
        ivec2 viaResolve = froxel * 16 + 24;
        ivec2 viaScatter = ivec2(ceil(vec2(froxel + 1) * vec2(screen) / vec2(grid)));
        ivec2 end = max(viaResolve, viaScatter);
        end = ivec2(froxel.x == grid.x - 1 ? screen.x : end.x, froxel.y == grid.y - 1 ? screen.y : end.y);
        return min(end, screen);
      }
      """

    private static let depthGLSL = """
      #version 430
      layout(local_size_x = 16, local_size_y = 16, local_size_z = 1) in;
      layout(rgba32f, binding = 0) uniform writeonly image2D o_depth;
      layout(binding = 1) uniform sampler2D u_position;
      uniform vec4 u_params;
      shared float farthest[256];
      \(depthCommon)
      void main()
      {
        ivec2 grid = ivec2(u_params.xy);
        ivec2 screen = ivec2(u_params.zw);
        ivec2 froxel = ivec2(gl_WorkGroupID.xy);
        ivec2 lo = regionStart(froxel, grid, screen);
        ivec2 hi = regionEnd(froxel, grid, screen);
        ivec2 local = ivec2(gl_LocalInvocationID.xy);
        float m = 0.0;
        for (int y = lo.y + local.y; y < hi.y; y += 16)
          for (int x = lo.x + local.x; x < hi.x; x += 16) {
            vec3 p = texelFetch(u_position, ivec2(x, y), 0).xyz;
            m = max(m, p == vec3(0.0) ? 1e30 : -p.z);
          }
        uint li = gl_LocalInvocationIndex;
        farthest[li] = m;
        barrier();
        for (uint stride = 128u; stride > 0u; stride >>= 1) {
          if (li < stride) farthest[li] = max(farthest[li], farthest[li + stride]);
          barrier();
        }
        if (li == 0u) imageStore(o_depth, froxel, vec4(farthest[0], 0.0, 0.0, 0.0));
      }
      """

    private static let depthMSL = """
      #include <metal_stdlib>
      using namespace metal;
      #define vec2 float2
      #define ivec2 int2
      \(depthCommon)
      struct U { float4 params; };
      kernel void compute_main(constant U& u [[buffer(0)]],
                               texture2d<float, access::write> o_depth [[texture(0)]],
                               texture2d<float> posTex [[texture(1)]],
                               sampler posSampler [[sampler(0)]],
                               uint2 group [[threadgroup_position_in_grid]],
                               uint2 local_u [[thread_position_in_threadgroup]],
                               uint li [[thread_index_in_threadgroup]])
      {
        threadgroup float farthest[256];
        int2 grid = int2(u.params.xy);
        int2 screen = int2(u.params.zw);
        int2 froxel = int2(group);
        int2 lo = regionStart(froxel, grid, screen);
        int2 hi = regionEnd(froxel, grid, screen);
        int2 local = int2(local_u);
        float m = 0.0;
        for (int y = lo.y + local.y; y < hi.y; y += 16)
          for (int x = lo.x + local.x; x < hi.x; x += 16) {
            float3 p = posTex.read(uint2(x, y)).xyz;
            m = max(m, all(p == float3(0)) ? 1e30 : -p.z);
          }
        farthest[li] = m;
        threadgroup_barrier(mem_flags::mem_threadgroup);
        for (uint stride = 128u; stride > 0u; stride >>= 1) {
          if (li < stride) farthest[li] = max(farthest[li], farthest[li + stride]);
          threadgroup_barrier(mem_flags::mem_threadgroup);
        }
        if (li == 0u) o_depth.write(float4(farthest[0], 0.0, 0.0, 0.0), uint2(froxel));
      }
      """

    /// One thread per froxel column.
    private static let integrateGLSL = """
      #version 430
      layout(local_size_x = 8, local_size_y = 8, local_size_z = 1) in;
      layout(rgba16f, binding = 0) uniform writeonly image2D o_integrated;
      layout(binding = 1) uniform sampler2D u_scatter;
      uniform vec4 u_params;
      void main()
      {
        ivec2 grid = ivec2(u_params.xy);
        ivec2 froxel = ivec2(gl_GlobalInvocationID.xy);
        if (froxel.x >= grid.x || froxel.y >= grid.y) return;
        vec3 scattered = vec3(0.0);
        float transmittance = 1.0;
        for (int k = 0; k < 64; ++k) {
          ivec2 texel = ivec2(k % 8, k / 8) * grid + froxel;
          vec4 slab = texelFetch(u_scatter, texel, 0);
          scattered += transmittance * slab.rgb;
          transmittance *= slab.a;
          imageStore(o_integrated, texel, vec4(scattered, transmittance));
        }
      }
      """

    private static let integrateMSL = """
      #include <metal_stdlib>
      using namespace metal;
      struct U { float4 params; };
      kernel void compute_main(constant U& u [[buffer(0)]],
                               texture2d<float, access::write> o_integrated [[texture(0)]],
                               texture2d<float> scatterTex [[texture(1)]],
                               sampler scatterSampler [[sampler(0)]],
                               uint2 gid [[thread_position_in_grid]])
      {
        int2 grid = int2(u.params.xy);
        int2 froxel = int2(gid);
        if (froxel.x >= grid.x || froxel.y >= grid.y) return;
        float3 scattered = float3(0.0);
        float transmittance = 1.0;
        for (int k = 0; k < 64; ++k) {
          uint2 texel = uint2(int2(k % 8, k / 8) * grid + froxel);
          float4 slab = scatterTex.read(texel);
          scattered += transmittance * slab.rgb;
          transmittance *= slab.a;
          o_integrated.write(float4(scattered, transmittance), texel);
        }
      }
      """
  }
}
