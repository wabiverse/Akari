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
import simd

extension Akari.LightProbes
{
  /// Rasterizes `views` (probe * 6 + face) into the capture atlas,
  /// a run of amplified faces per replay of the scene capture.
  func drawCapture(_ captures: [OpaquePointer], views range: Range<Int>,
                   materials: (material: GLuint, color: GLuint, emissive: GLuint))
  {
    let projection = Akari.Matrix4.reversedDepth(.perspective(left: -near, right: near,
                                                              bottom: -near, top: near,
                                                              near: near, far: near * 1e6))
    beginPass(captureTarget, size: SIMD2(Self.atlasWidth, Self.atlasHeight), sunPass: false, materials: materials)

    var start = range.lowerBound
    while start < range.upperBound
    {
      let run = start ..< min(start + Akari.ShadowAtlas.maxAmplificationViews, range.upperBound)
      var transforms: [Float] = []
      var rects: [Int32] = []
      for view in run
      {
        let face = Self.faces[view % 6]
        let eye = probePosition(view / 6)
        let viewMatrix = Akari.Matrix4.lookAt(eye: eye, target: eye + face.forward, up: face.up)
        (projection * viewMatrix).withUnsafeFloats { transforms.append(contentsOf: $0) }
        let rect = faceRect(view)
        rects += [rect.x, rect.y, rect.z, rect.w]
      }
      setAmplification(transforms: transforms, viewports: rects, count: run.count)
      for capture in captures
      {
        labgl.capturePlaybackIndirectDraws(capture)
      }
      gl.disableVertexAmplification()
      start = run.upperBound
    }

    endPass()
  }

  /// An orthographic sun depth map over the whole scene.
  func drawSunMap(_ captures: [OpaquePointer],
                  sceneBounds: (min: SIMD3<Float>, max: SIMD3<Float>),
                  direction: SIMD3<Float>,
                  materials: (material: GLuint, color: GLuint, emissive: GLuint))
  {
    let center = (sceneBounds.min + sceneBounds.max) * 0.5
    let extent = sceneBounds.max - sceneBounds.min
    let radius = max((extent * extent).sum().squareRoot() * 0.5, 1e-3)
    let dir = Akari.Matrix.normalize(direction)
    let up: SIMD3<Float> = abs(dir.y) > 0.99 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
    let view = Akari.Matrix4.lookAt(eye: center + dir * (radius * 2), target: center, up: up)
    let projection = Akari.Matrix4.reversedDepth(.ortho(left: -radius, right: radius,
                                                        bottom: -radius, top: radius,
                                                        near: radius, far: radius * 3))
    sunMatrix = projection * view
    sunTexelWorld = 2 * radius / Float(Self.sunResolution)
    sunDepthPerWorld = 1 / (2 * radius)

    clear(sunMap, width: Self.sunResolution, height: Self.sunResolution, format: GLenum(GL_R32F))
    beginPass(sunTarget, size: SIMD2(Self.sunResolution, Self.sunResolution), sunPass: true, materials: materials)
    var transform: [Float] = []
    sunMatrix.withUnsafeFloats { transform.append(contentsOf: $0) }
    setAmplification(transforms: transform,
                     viewports: [0, 0, Int32(Self.sunResolution), Int32(Self.sunResolution)],
                     count: 1)
    for capture in captures
    {
      labgl.capturePlaybackIndirectDraws(capture)
    }
    gl.disableVertexAmplification()
    endPass()
  }

  /// One bounce: projects the volume probes to SH (reading last bounce's
  /// SH for their indirect), then rebuilds and filters the sphere probes.
  func relight(_ lighting: Lighting, environment: GLuint)
  {
    let next = 1 - shIndex

    let project = kernels.project
    setUniforms(project, lighting, param: 0)
    gl.setComputeShaderImage(project, index: 0, texture: sh[next], format: GLenum(GL_RGBA16F), level: 0)
    gl.setComputeShaderImage(project, index: 1, texture: sphereInfo, format: GL_RGBA32F, level: 0)
    bindScene(project, environment: environment, sh: sh[shIndex])
    gl.dispatchCompute(project, groupsX: GLuint(layout.probeCount), groupsY: 1, groupsZ: 1)
    shIndex = next

    guard !layout.spheres.isEmpty else { return }

    let base = kernels.sphereBase
    let baseGroups = GLuint((Self.octResolution + 2 + 15) / 16)
    setUniforms(base, lighting, param: 0)
    gl.setComputeShaderImage(base, index: 0, texture: sphereAtlas, format: GLenum(GL_RGBA16F), level: 0)
    gl.setComputeShaderSampler(base, index: 1, texture: sphereInfo, samplerIndex: 0)
    bindScene(base, environment: environment, sh: sh[shIndex])
    gl.dispatchCompute(base, groupsX: baseGroups, groupsY: baseGroups, groupsZ: GLuint(layout.spheres.count))

    let filter = kernels.sphereFilter
    for level in 1 ..< Self.octLevels
    {
      let groups = GLuint(((Self.octResolution >> level) + 2 + 15) / 16)
      setUniforms(filter, lighting, param: Float(level))
      gl.setComputeShaderImage(filter, index: 0, texture: sphereAtlas, format: GLenum(GL_RGBA16F), level: 0)
      gl.dispatchCompute(filter, groupsX: groups, groupsY: groups, groupsZ: GLuint(layout.spheres.count))
    }
  }

  func clear(_ texture: GLuint, width: Int, height: Int, format: GLenum = GLenum(GL_RGBA16F))
  {
    let kernel = kernels.clear
    var value = SIMD4<Float>(repeating: 0)
    gl.setComputeShaderUniform(kernel, name: "u_value", type: GL_FLOAT_VEC4, data: &value)
    gl.setComputeShaderImage(kernel, index: 0, texture: texture, format: format, level: 0)
    gl.dispatchCompute(kernel,
                       groupsX: GLuint((width + 15) / 16),
                       groupsY: GLuint((height + 15) / 16),
                       groupsZ: 1)
  }

  private func bindScene(_ kernel: GLuint, environment: GLuint, sh: GLuint)
  {
    gl.setComputeShaderSampler(kernel, index: 2, texture: captureTextures[0], samplerIndex: 0)
    gl.setComputeShaderSampler(kernel, index: 3, texture: captureTextures[1], samplerIndex: 0)
    gl.setComputeShaderSampler(kernel, index: 4, texture: captureTextures[2], samplerIndex: 0)
    gl.setComputeShaderSampler(kernel, index: 5, texture: environment, samplerIndex: 0)
    gl.setComputeShaderSampler(kernel, index: 6, texture: sunMap, samplerIndex: 0)
    gl.setComputeShaderSampler(kernel, index: 7, texture: sh, samplerIndex: 0)
  }

  /// Every relight kernel shares `U` fields set in declaration order.
  private func setUniforms(_ kernel: GLuint, _ lighting: Lighting, param: Float)
  {
    func vector(_ name: String, _ value: SIMD4<Float>)
    {
      var value = value
      gl.setComputeShaderUniform(kernel, name: name, type: GL_FLOAT_VEC4, data: &value)
    }

    sunMatrix.withUnsafeFloats
    { buf in
      gl.setComputeShaderUniform(kernel, name: "u_sunMatrix", type: GL_FLOAT_MAT4, data: buf.baseAddress)
    }
    vector("u_sun", SIMD4(lighting.sunDirection, lighting.sunHeight))
    vector("u_sky", SIMD4(lighting.zUp ? 1 : 0, lighting.iblEnabled ? 1 : 0, near, 0))
    vector("u_sunMap", SIMD4(Float(Self.sunResolution), sunTexelWorld, sunDepthPerWorld, 0))
    vector("u_gridMin", SIMD4(layout.gridMin, Float(layout.volumeCount)))
    vector("u_gridMax", SIMD4(layout.gridMax, Float(layout.spheres.count)))
    vector("u_gridSize", SIMD4(SIMD3<Float>(layout.dims), layout.normalBias))
    let lightCount = min(lighting.lights.count / 2, 4)
    for i in 0 ..< 4
    {
      vector("u_lightPos\(i)", i < lightCount ? lighting.lights[i * 2] : .zero)
    }
    for i in 0 ..< 4
    {
      vector("u_lightColor\(i)", i < lightCount ? lighting.lights[i * 2 + 1] : .zero)
    }
    vector("u_params", SIMD4(Float(lightCount), param, 0, 0))
  }

  private func setAmplification(transforms: [Float], viewports: [Int32], count: Int)
  {
    transforms.withUnsafeBufferPointer
    { buf in
      gl.instanceTransformsData(handle: amplification.views,
                                size: GLsizei(buf.count * MemoryLayout<Float>.size),
                                transforms: buf.baseAddress, cullRadius: 0, usage: GL_STATIC_DRAW)
    }
    viewports.withUnsafeBufferPointer
    { buf in
      gl.instanceViewportsData(handle: amplification.viewports,
                               size: GLsizei(buf.count * MemoryLayout<Int32>.size),
                               viewports: buf.baseAddress, usage: GL_STATIC_DRAW)
    }
    gl.setVertexAmplification(viewsHandle: amplification.views,
                              viewportsHandle: amplification.viewports,
                              count: GLsizei(count))
  }

  private func beginPass(_ target: GLuint, size: SIMD2<Int>, sunPass: Bool,
                         materials: (material: GLuint, color: GLuint, emissive: GLuint))
  {
    gl.bindRenderTarget(target)
    gl.disable(GLenum(GL_BLEND))
    gl.disable(GL_CULL_FACE)
    gl.enable(GL_DEPTH_TEST)
    gl.depthFunc(GLenum(GL_GREATER))
    gl.depthMask(GLboolean(1))
    gl.enable(GLenum(GL_SCISSOR_TEST))
    gl.viewport(x: 0, y: 0, width: GLsizei(size.x), height: GLsizei(size.y))
    gl.scissor(x: 0, y: 0, width: GLsizei(size.x), height: GLsizei(size.y))

    gl.useShader(captureShader)
    var mode = SIMD4<Float>(sunPass ? 1 : 0, 0, 0, 0)
    gl.setShaderUniform(captureShader, name: "u_mode", type: GL_FLOAT_VEC4, data: &mode)
    gl.setShaderImageArgument(captureShader, bufferIndex: 0, texture: materials.material)
    gl.setShaderImageArgument(captureShader, bufferIndex: 1, texture: materials.color)
    gl.setShaderImageArgument(captureShader, bufferIndex: 4, texture: materials.emissive)
  }

  private func endPass()
  {
    gl.useShader(0)
    gl.disable(GLenum(GL_SCISSOR_TEST))
    gl.enable(GL_CULL_FACE)
    gl.bindRenderTarget(gl.rootRenderTarget())
  }
}
