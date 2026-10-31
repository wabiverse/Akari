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
import HdAkari
import LabGL

public extension Akari.LabFXEngine
{
  /// Fits the shadow views to this frame, then tags
  /// the pages its G-buffer and froxels sample.
  ///
  /// - Parameters:
  ///   - camera: the view the G-buffer was just rendered from.
  ///   - settings: the frame's render settings.
  func markShadowPageUsage(camera: Akari.Camera, settings: RenderSettings)
  {
    guard settings.features.contains(.shadowMaps) else { return }
    measureLightImportance(camera: camera)

    let posTex = runtime.texture("gbuffer", named: "position")
    guard
      posTex != 0,
      let sceneBounds
    else { return }

    shadowAtlas.markPageUsage(gbufferPosition: posTex,
                              camera: camera,
                              screenWidth: renderWidth,
                              screenHeight: renderHeight,
                              footprintHeight: max(renderHeight, lastHeight),
                              lightDirection: worldSpaceSunDirection(settings.light),
                              sceneBounds: sceneBounds,
                              settings: settings.light.shadow,
                              lights: syncedPointLights,
                              punctualFarDistance: Self.punctualFarDistance(sceneBounds),
                              sceneRevision: lastGeometryRevision,
                              casterBounds: casterBounds,
                              casterKeys: casterKeys,
                              staticGeneration: geometry.staticShadow.map { labgl.captureGeneration($0) } ?? 0,
                              volume: volumetrics.froxels)
  }

  /// Redraws whichever tiles `markShadowPageUsage` found
  /// stale, then binds them for the deferred resolve.
  ///
  /// - Parameters:
  ///   - renderParam: hydra render param.
  ///   - camera: the view the cascades were fitted to.
  ///   - settings: the frame's render settings.
  ///   - frameIndex: per frame counter, drives atlas eviction.
  func renderShadows(renderParam: Pixar.HdAkariRenderParam,
                     camera: Akari.Camera,
                     settings: RenderSettings,
                     frameIndex _: UInt64)
  {
    shadowsReady = false
    var staticCaptures: [OpaquePointer] = []
    if !geometry.staticBatch.isEmpty, let capture = geometry.staticShadow
    {
      staticCaptures.append(capture)
    }
    if !geometry.instancedBatch.isEmpty, let capture = geometry.staticInstancedCapture
    {
      staticCaptures.append(capture)
    }
    // the deformed capture's draws move without a rerecord, so their bounds come along.
    var dynamicCaptures: [OpaquePointer] = []
    var dynamicDrawBounds: [[Float]?] = []
    if !geometry.dynamicBatch.isEmpty, let capture = geometry.deformer.shadowCapture ?? geometry.dynamicCapture
    {
      dynamicCaptures.append(capture)
      dynamicDrawBounds.append(geometry.dynamicBatch.casterBounds)
    }

    guard
      !staticCaptures.isEmpty || !dynamicCaptures.isEmpty,
      sceneBounds != nil,
      renderParam.GetScene() != nil
    else { return }

    let shadow = settings.light.shadow
    shadowAtlas.materialAtlas = probeMaterials.material
    shadowAtlas.materialConstants = probeMaterials.constants
    let views = shadowAtlas.render(staticCaptures: staticCaptures,
                                   dynamicCaptures: dynamicCaptures,
                                   dynamicDrawBounds: dynamicDrawBounds,
                                   casterBounds: casterBounds)
    bindShadowViews(views, settings: shadow)
    shadowsReady = true

    // the atlas draws left the light's matrices on the stack,
    // so put the camera back before the captured replay.
    gl.matrixMode(GL_PROJECTION)
    gl.loadMatrix(Akari.Matrix4.reversedDepth(camera.projection).m)
    gl.matrixMode(GL_MODELVIEW)
    gl.loadMatrix(camera.view.m)
  }

  /// A power of two, so animated bounds don't move the cube far planes and restale them.
  private static func punctualFarDistance(_ bounds: (min: SIMD3<Float>, max: SIMD3<Float>)) -> Float
  {
    let diagonal = bounds.max - bounds.min
    return exp2(ceil(log2(max((diagonal * diagonal).sum().squareRoot(), 1))))
  }

  internal func ensureShadowBindings()
  {
    guard
      shadowAtlas.prepare(),
      shadowAtlas.atlas != boundShadowAtlas
    else { return }

    boundShadowAtlas = shadowAtlas.atlas
    setSampler("u_shadow_atlas", shadowAtlas.atlas)
    setSampler("u_shadow_data", shadowAtlas.data)
    setSampler("u_shadow_pagetable", shadowAtlas.pageTable)
  }

  private func bindShadowViews(_ views: [Akari.ShadowAtlas.View], settings: ShadowSettings)
  {
    ensureShadowBindings()
    setSampler("u_shadow_data", shadowAtlas.data)

    setFloat("u_shadowLevelCount", Float(views.count))
    setVector("u_shadowBias", SIMD4(settings.depthBias, settings.normalBias, 0, 0))

    let sun = shadowAtlas.sun
    setMatrix("u_eyeToLightRotation", sun.eyeToLightRotation)
    setVector("u_directionalRefOffset", SIMD4(sun.refOffset.x, sun.refOffset.y, sun.refOffset.z, 0))
    setVector("u_shadowLodRange", SIMD4(Float(sun.lodMin),
                                        Float(sun.lodMax),
                                        sun.isClipmap ? 1 : 0,
                                        sun.lodBias))
  }

  static let importanceGrid = (width: 64, height: 36)
  static let importanceMaxBoxes = 64
  static var importanceSamples: Int
  {
    importanceGrid.width * importanceGrid.height
  }

  /// Sums each shadowed lights shadowed irradiance over a grid of last frames
  /// gbuffer, so lights blocked where they stand never count as main, and the
  /// animated meshes in view, the characters whose shadows move every frame,
  /// count the most.
  func measureLightImportance(camera: Akari.Camera)
  {
    if importanceKernel == 0
    {
      importanceKernel = gl.precompileComputeShader(name: "akari-light-importance",
                                                    glsl: Self.importanceGLSL, msl: Self.importanceMSL)
      if importanceKernel != 0 { gl.setComputeShaderThreadgroupSize(importanceKernel, x: 256, y: 1, z: 1) }
      importanceReadback = gl.createComputeReadback(sizeBytes: GLsizei(16 * MemoryLayout<Float>.size), ringSize: 3)
    }
    guard
      importanceKernel != 0,
      importanceReadback != 0,
      gl.waitComputeShader(importanceKernel) != 0,
      pointLightTexture != 0
    else { return }

    var size: GLsizei = 0
    if let raw = gl.computeReadbackLatest(importanceReadback, size: &size), size == GLsizei(16 * MemoryLayout<Float>.size)
    {
      let sums = raw.assumingMemoryBound(to: Float.self)
      for (slot, key) in shadowSlots.enumerated() where slot < 16
      {
        let value = sums[slot]
        guard value.isFinite else { continue }
        lightImportance[key] = lightImportance[key].map { $0 * 0.92 + value * 0.08 } ?? value
      }
    }

    let textures = [
      runtime.texture("gbuffer", named: "position"),
      runtime.texture("gbuffer", named: "normal"),
      pointLightTexture
    ] + (0 ..< 4).map { runtime.texture("pointShadow", named: "pointShadow\($0)") }
    guard textures.allSatisfy({ $0 != 0 }) else { return }
    let kernel = importanceKernel
    camera.view.inverse().withUnsafeFloats
    { buf in
      gl.setComputeShaderUniform(kernel, name: "u_invView", type: GL_FLOAT_MAT4, data: buf.baseAddress)
    }
    if importanceBoxes.isEmpty
    {
      importanceBoxes = (0 ..< 3).map
      { _ in
        gl.createBuffer(usage: LGL_BUFFER_COMPUTE_READ | LGL_BUFFER_MAP_WRITE,
                        sizeBytes: GLsizei(Self.importanceMaxBoxes * 8 * MemoryLayout<Float>.size))
      }
    }
    importanceBoxCursor = (importanceBoxCursor + 1) % importanceBoxes.count
    let boxes = importanceBoxes[importanceBoxCursor]
    let bounds = geometry.dynamicBatch.casterBounds
    let boxCount = min(bounds.count / 6, Self.importanceMaxBoxes)
    if boxes != 0, let p = gl.mapBuffer(boxes)
    {
      let out = p.assumingMemoryBound(to: Float.self)
      for b in 0 ..< boxCount
      {
        for c in 0 ..< 3
        {
          out[b * 8 + c] = bounds[b * 6 + c]
          out[b * 8 + 4 + c] = bounds[b * 6 + 3 + c]
        }
      }
      gl.unmapBuffer(boxes)
    }
    var params = SIMD4<Float>(Float(min(syncedPointLights.count, 16)),
                              Float(Self.importanceGrid.width), Float(Self.importanceGrid.height), Float(boxCount))
    gl.setComputeShaderUniform(kernel, name: "u_params", type: GL_FLOAT_VEC4, data: &params)
    for (i, texture) in textures.enumerated()
    {
      gl.setComputeShaderSampler(kernel, index: GLuint(i), texture: texture, samplerIndex: GLuint(i))
    }
    gl.setComputeShaderBuffer(kernel, binding: 0, buffer: gl.computeReadbackCurrentBuffer(importanceReadback))
    gl.setComputeShaderBuffer(kernel, binding: 1, buffer: boxes)
    gl.setComputeShaderReadback(kernel, bindingIndex: 0, readback: importanceReadback)
    gl.dispatchCompute(kernel, groupsX: 1, groupsY: 1, groupsZ: 1)
  }

  static let importanceBody = """
      int count = int(PARAMS.x);
      int gw = int(PARAMS.y), gh = int(PARAMS.z);
      float sums[16];
      for (int i = 0; i < 16; ++i) sums[i] = 0.0;
      for (int k = int(TID); k < gw * gh; k += 256)
      {
        IVEC2 p = IVEC2((VEC2(float(k % gw), float(k / gw)) + 0.5) / VEC2(float(gw), float(gh)) * VEC2(FULL_SIZE));
        VEC4 n = FETCH(NORMAL, p);
        if (n.w < 0.5) continue;
        VEC3 wp = (INV_VIEW * VEC4(FETCH(POSITION, p).xyz, 1.0)).xyz;
        VEC3 N = normalize((INV_VIEW * VEC4(n.xyz, 0.0)).xyz);
        IVEC2 hp = min(IVEC2(VEC2(p) * VEC2(HALF_SIZE) / VEC2(FULL_SIZE)), HALF_SIZE - 1);
        float focus = 1.0;
        for (int b = 0; b < int(PARAMS.w); ++b)
        {
          if (all(wp >= BOXES[b * 2].xyz) && all(wp <= BOXES[b * 2 + 1].xyz)) { focus = 16.0; break; }
        }
        VEC4 s0 = FETCH(SHADOW0, hp), s1 = FETCH(SHADOW1, hp), s2 = FETCH(SHADOW2, hp), s3 = FETCH(SHADOW3, hp);
        for (int i = 0; i < count; ++i)
        {
          VEC4 pi = FETCH(LIGHTS, IVEC2(0, i));
          VEC4 cr = FETCH(LIGHTS, IVEC2(1, i));
          VEC3 tl = pi.xyz - wp;
          float dd = max(dot(tl, tl), cr.w * cr.w);
          VEC4 s = i < 4 ? s0 : i < 8 ? s1 : i < 12 ? s2 : s3;
          sums[i] += pi.w * max(cr.x, max(cr.y, cr.z)) * cr.w * cr.w / dd
                   * max(dot(N, tl * inversesqrt(dd)), 0.0) * s[i & 3] * focus;
        }
      }
      for (int i = 0; i < 16; ++i) partial[int(TID) * 16 + i] = sums[i];
      BARRIER;
      if (TID < 16u)
      {
        float total = 0.0;
        for (int j = 0; j < 256; ++j) total += partial[j * 16 + int(TID)];
        out_buf[TID] = total;
      }
    """

  static let importanceGLSL = """
    #version 430
    layout(local_size_x = 256, local_size_y = 1, local_size_z = 1) in;
    layout(std430, binding = 0) buffer Out { float out_buf[]; };
    layout(binding = 0) uniform sampler2D u_position;
    layout(binding = 1) uniform sampler2D u_normal;
    layout(binding = 2) uniform sampler2D u_lights;
    layout(binding = 3) uniform sampler2D u_shadow0;
    layout(binding = 4) uniform sampler2D u_shadow1;
    layout(binding = 5) uniform sampler2D u_shadow2;
    layout(binding = 6) uniform sampler2D u_shadow3;
    uniform mat4 u_invView;
    uniform vec4 u_params;
    layout(std430, binding = 1) buffer Boxes { vec4 boxes[]; };
    shared float partial[256 * 16];
    #define BOXES boxes
    #define PARAMS u_params
    #define INV_VIEW u_invView
    #define VEC2 vec2
    #define VEC3 vec3
    #define VEC4 vec4
    #define IVEC2 ivec2
    #define FETCH(t, p) texelFetch(t, p, 0)
    #define POSITION u_position
    #define NORMAL u_normal
    #define LIGHTS u_lights
    #define SHADOW0 u_shadow0
    #define SHADOW1 u_shadow1
    #define SHADOW2 u_shadow2
    #define SHADOW3 u_shadow3
    #define BARRIER barrier()
    void main()
    {
      uint TID = gl_LocalInvocationIndex;
      ivec2 FULL_SIZE = textureSize(u_position, 0);
      ivec2 HALF_SIZE = textureSize(u_shadow0, 0);
      \(importanceBody)
    }
    """

  static let importanceMSL = """
    #include <metal_stdlib>
    using namespace metal;
    struct U { float4x4 invView; float4 params; };
    #define BOXES boxes
    #define PARAMS u.params
    #define INV_VIEW u.invView
    #define VEC2 float2
    #define VEC3 float3
    #define VEC4 float4
    #define IVEC2 int2
    #define FETCH(t, p) t.read(uint2(p))
    #define POSITION positionTex
    #define NORMAL normalTex
    #define LIGHTS lightTex
    #define SHADOW0 shadow0
    #define SHADOW1 shadow1
    #define SHADOW2 shadow2
    #define SHADOW3 shadow3
    #define BARRIER threadgroup_barrier(mem_flags::mem_threadgroup)
    #define inversesqrt rsqrt
    kernel void compute_main(constant U& u [[buffer(0)]],
                             device float* out_buf [[buffer(1)]],
                             device const float4* boxes [[buffer(2)]],
                             texture2d<float> positionTex [[texture(0)]],
                             texture2d<float> normalTex [[texture(1)]],
                             texture2d<float> lightTex [[texture(2)]],
                             texture2d<float> shadow0 [[texture(3)]],
                             texture2d<float> shadow1 [[texture(4)]],
                             texture2d<float> shadow2 [[texture(5)]],
                             texture2d<float> shadow3 [[texture(6)]],
                             uint TID [[thread_index_in_threadgroup]])
    {
      threadgroup float partial[256 * 16];
      int2 FULL_SIZE = int2(positionTex.get_width(), positionTex.get_height());
      int2 HALF_SIZE = int2(shadow0.get_width(), shadow0.get_height());
      \(importanceBody)
    }
    """
}
