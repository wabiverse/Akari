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

public extension Akari
{
  /// Volume (irradiance grid) and sphere (reflection) light probes. The scene
  /// capture is rasterized once into amplified cube faces, then relit on the
  /// GPU whenever the sun or lights change.
  final class LightProbes
  {
    /// A probe authored in USD, as a world space box.
    public struct Override: Sendable
    {
      public var min: SIMD3<Float>
      public var max: SIMD3<Float>
      public var isSphere: Bool
      /// Volume probe counts per axis, zero picks them from the settings.
      public var resolution: SIMD3<Int32>

      public init(min: SIMD3<Float>, max: SIMD3<Float>, isSphere: Bool, resolution: SIMD3<Int32> = .zero)
      {
        self.min = min
        self.max = max
        self.isSphere = isSphere
        self.resolution = resolution
      }
    }

    /// What the relight shades the captured surfaces with.
    public struct Lighting: Equatable
    {
      public var sunDirection: SIMD3<Float>
      public var sunHeight: Float
      public var zUp: Bool
      public var iblEnabled: Bool
      /// Per point light, position + intensity then color + radius.
      public var lights: [SIMD4<Float>]
    }

    struct Layout: Equatable
    {
      var gridMin = SIMD3<Float>(repeating: 0)
      var gridMax = SIMD3<Float>(repeating: 0)
      var dims = SIMD3<Int32>(repeating: 0)
      /// Center + radius, largest first so smaller ones blend over them.
      var spheres: [SIMD4<Float>] = []

      var volumeCount: Int { Int(dims.x) * Int(dims.y) * Int(dims.z) }
      var probeCount: Int { volumeCount + spheres.count }

      var cell: SIMD3<Float>
      {
        (gridMax - gridMin) / SIMD3<Float>(simd_max(dims &- 1, SIMD3(repeating: 1)))
      }

      /// How far along the normal a shading point steps before picking its probes.
      var normalBias: Float { cell.min() * 0.25 }
    }

    struct LayoutKey: Equatable
    {
      var overrideRevision: UInt64
      var resolution: Int
      var upAxis: Int
    }

    struct Kernels
    {
      var clear: GLuint = 0
      var project: GLuint = 0
      var sphereBase: GLuint = 0
      var sphereFilter: GLuint = 0

      var all: [GLuint] { [clear, project, sphereBase, sphereFilter] }
    }

    static let atlasWidth = 2048
    static let volumeFace = 16
    static let sphereFace = 128
    static let maxVolumeProbes = 1024
    static let maxSphereProbes = 16
    static let volumeRegionHeight = maxVolumeProbes * 6 / (atlasWidth / volumeFace) * volumeFace
    static let atlasHeight = volumeRegionHeight + maxSphereProbes * 6 / (atlasWidth / sphereFace) * sphereFace
    static let octResolution = 128
    static let octLevels = 5
    static let octTile = SIMD2<Int>(196, 130)
    static let octTilesPerRow = 4
    static let sunResolution = 2048
    static let shProbesPerRow = 256

    /// Volume probe L1 spherical harmonics, four texels per probe.
    public var volumeSH: GLuint { sh[shIndex] }
    /// Octahedral sphere probe radiance, one tile of roughness levels per probe.
    public private(set) var sphereAtlas: GLuint = 0
    /// Per sphere probe, center + radius then validity.
    public private(set) var sphereInfo: GLuint = 0
    /// Set once every probe has been captured and lit.
    public private(set) var isReady = false
    /// Cube faces the current layout needs captured, zero before the first layout.
    public var captureTotal: Int { layoutKey == nil ? 0 : layout.probeCount * 6 }

    var layout = Layout()
    var layoutKey: LayoutKey?

    var kernels = Kernels()
    var captureShader: GLuint = 0
    var captureTarget: GLuint = 0
    var captureDepth: GLuint = 0
    /// Albedo + facing, normal + depth, emission + metallic.
    var captureTextures: [GLuint] = []
    var sunTarget: GLuint = 0
    var sunDepth: GLuint = 0
    var sunMap: GLuint = 0
    var sunMatrix = Akari.Matrix4.identity
    var sunTexelWorld: Float = 0
    var sunDepthPerWorld: Float = 0
    var sh: [GLuint] = [0, 0]
    var shIndex = 0
    var amplification = Akari.ShadowAtlas.Amplification()
    var near: Float = 1e-3

    private var resourcesReady = false
    private var failed = false
    /// Cube faces captured so far out of `captureTotal`.
    public private(set) var captured = 0
    /// Relight dispatches left before the current bake settles.
    public private(set) var relightFrames = 0
    private var sunKey: SIMD3<Float>?
    private var lastLighting: Lighting?

    public init()
    {}

    deinit
    {
      release()
    }

    /// Advances the bake by one frame and relights when the lights changed.
    ///
    /// - Returns: whether the probes can be sampled this frame.
    func update(captures: [OpaquePointer],
                sceneBounds: (min: SIMD3<Float>, max: SIMD3<Float>),
                overrides: [Override],
                overrideRevision: UInt64,
                upAxis: Int,
                materials: (material: GLuint, color: GLuint, emissive: GLuint),
                environment: GLuint,
                lighting: Lighting,
                settings: LightProbeSettings) -> Bool
    {
      guard
        materials.material != 0,
        materials.color != 0,
        materials.emissive != 0,
        environment != 0,
        ensureResources()
      else { return false }

      let key = LayoutKey(overrideRevision: overrideRevision,
                          resolution: settings.volumeResolution,
                          upAxis: upAxis)
      if key != layoutKey
      {
        layoutKey = key
        let next = Self.place(bounds: sceneBounds,
                              overrides: overrides,
                              resolution: settings.volumeResolution,
                              upAxis: upAxis)
        if next != layout
        {
          layout = next
          isReady = false
          uploadSphereInfo()
          for tex in sh { clear(tex, width: Self.shProbesPerRow * 4, height: Self.maxVolumeProbes / Self.shProbesPerRow) }
          clear(sphereAtlas, width: Self.octTile.x * Self.octTilesPerRow,
                height: Self.octTile.y * Self.maxSphereProbes / Self.octTilesPerRow)
        }
        let extent = sceneBounds.max - sceneBounds.min
        near = max((extent * extent).sum().squareRoot() * 1e-4, 1e-4)
        for tex in captureTextures { clear(tex, width: Self.atlasWidth, height: Self.atlasHeight) }
        captured = 0
        sunKey = nil
      }

      let total = layout.probeCount * 6
      if captured < total
      {
        let count = min(total - captured, max(settings.captureViewsPerFrame, 1))
        drawCapture(captures, views: captured ..< captured + count, materials: materials)
        captured += count
        guard captured == total else { return isReady }
      }

      if sunKey != lighting.sunDirection
      {
        drawSunMap(captures, sceneBounds: sceneBounds, direction: lighting.sunDirection, materials: materials)
        sunKey = lighting.sunDirection
        lastLighting = nil
      }
      if lighting != lastLighting
      {
        lastLighting = lighting
        relightFrames = max(settings.bounces, 0) + 1
      }
      if relightFrames > 0
      {
        relight(lighting, environment: environment)
        relightFrames -= 1
        isReady = true
      }

      return isReady
    }

    /// Where `view` (probe * 6 + face) lands in the capture atlas.
    func faceRect(_ view: Int) -> SIMD4<Int32>
    {
      let probe = view / 6
      if probe < layout.volumeCount
      {
        let perRow = Self.atlasWidth / Self.volumeFace
        return SIMD4(Int32((view % perRow) * Self.volumeFace), Int32((view / perRow) * Self.volumeFace),
                     Int32(Self.volumeFace), Int32(Self.volumeFace))
      }
      let tile = view - layout.volumeCount * 6
      let perRow = Self.atlasWidth / Self.sphereFace
      return SIMD4(Int32((tile % perRow) * Self.sphereFace),
                   Int32(Self.volumeRegionHeight + (tile / perRow) * Self.sphereFace),
                   Int32(Self.sphereFace), Int32(Self.sphereFace))
    }

    func probePosition(_ probe: Int) -> SIMD3<Float>
    {
      guard probe < layout.volumeCount else
      {
        let s = layout.spheres[probe - layout.volumeCount]
        return SIMD3(s.x, s.y, s.z)
      }

      let dx = Int(layout.dims.x)
      let dy = Int(layout.dims.y)

      let c = SIMD3<Float>(
        Float(probe % dx),
        Float((probe / dx) % dy),
        Float(probe / (dx * dy))
      )
      return layout.gridMin + c * layout.cell
    }

    /// Forward and up of each cube face, matching the kernels' `faceBasis`.
    static let faces: [(forward: SIMD3<Float>, up: SIMD3<Float>)] = [
      (SIMD3(1, 0, 0), SIMD3(0, 1, 0)),
      (SIMD3(-1, 0, 0), SIMD3(0, 1, 0)),
      (SIMD3(0, 1, 0), SIMD3(0, 0, -1)),
      (SIMD3(0, -1, 0), SIMD3(0, 0, 1)),
      (SIMD3(0, 0, 1), SIMD3(0, 1, 0)),
      (SIMD3(0, 0, -1), SIMD3(0, 1, 0))
    ]

    /// Auto places the volume grid over the scene and a few
    /// sphere probes across it, authored probes replace either.
    static func place(bounds: (min: SIMD3<Float>, max: SIMD3<Float>),
                      overrides: [Override],
                      resolution: Int,
                      upAxis: Int) -> Layout
    {
      var layout = Layout()

      let volumes = overrides.filter { !$0.isSphere }
      var lo = bounds.min
      var hi = bounds.max
      var requested = SIMD3<Int32>(repeating: 0)
      if let first = volumes.first
      {
        lo = volumes.reduce(first.min) { simd_min($0, $1.min) }
        hi = volumes.reduce(first.max) { simd_max($0, $1.max) }
        requested = first.resolution
      }
      else
      {
        let pad = (hi - lo) * 0.02 + 1e-3
        lo -= pad
        hi += pad
      }
      let extent = simd_max(hi - lo, SIMD3(repeating: 1e-3))

      var dims: [Int]
      if requested.x > 0, requested.y > 0, requested.z > 0
      {
        dims = [Int(requested.x), Int(requested.y), Int(requested.z)].map { min(max($0, 2), 32) }
      }
      else
      {
        var spacing = extent.max() / Float(max(resolution - 1, 1))
        repeat
        {
          dims = (0 ..< 3).map { min(max(Int((extent[$0] / spacing).rounded(.up)) + 1, 2), 32) }
          spacing *= 1.1
        }
        while dims.reduce(1, *) > maxVolumeProbes
      }
      while dims.reduce(1, *) > maxVolumeProbes, let k = dims.indices.max(by: { dims[$0] < dims[$1] })
      {
        dims[k] -= 1
      }
      layout.gridMin = lo
      layout.gridMax = hi
      layout.dims = SIMD3(Int32(dims[0]), Int32(dims[1]), Int32(dims[2]))

      var spheres = overrides.filter(\.isSphere).map
      { probe -> SIMD4<Float> in
        let center = (probe.min + probe.max) * 0.5
        return SIMD4(center, ((probe.max - probe.min) * 0.5).max())
      }
      if spheres.isEmpty
      {
        let size = simd_max(bounds.max - bounds.min, SIMD3(repeating: 1e-3))
        let axes = [0, 1, 2].filter { $0 != upAxis }
        let longest = max(size[axes[0]], size[axes[1]])
        let counts = axes.map { size[$0] > longest * 0.5 ? 2 : 1 }
        var cell = size
        cell[axes[0]] /= Float(counts[0])
        cell[axes[1]] /= Float(counts[1])
        let radius = (cell * cell).sum().squareRoot() * 0.6
        for i in 0 ..< counts[0]
        {
          for j in 0 ..< counts[1]
          {
            var center = bounds.min
            center[axes[0]] += (Float(i) + 0.5) * cell[axes[0]]
            center[axes[1]] += (Float(j) + 0.5) * cell[axes[1]]
            center[upAxis] += 0.35 * size[upAxis]
            spheres.append(SIMD4(center, radius))
          }
        }
      }
      layout.spheres = Array(spheres.sorted { $0.w > $1.w }.prefix(maxSphereProbes))

      return layout
    }

    public func release()
    {
      for target in [captureTarget, sunTarget] where target != 0
      {
        gl.deleteRenderTarget(target)
      }
      for var tex in captureTextures + sh + [captureDepth, sunMap, sunDepth, sphereAtlas, sphereInfo] where tex != 0
      {
        gl.deleteTextures(count: 1, textures: &tex)
      }
      for kernel in kernels.all where kernel != 0
      {
        gl.deleteComputeShader(kernel)
      }
      if captureShader != 0 { gl.deleteShader(captureShader) }
      if amplification.views != 0
      {
        var handle = amplification.views
        gl.deleteInstanceTransforms(count: 1, handles: &handle)
      }
      if amplification.viewports != 0
      {
        var handle = amplification.viewports
        gl.deleteInstanceViewports(count: 1, handles: &handle)
      }

      captureTarget = 0; captureDepth = 0; captureTextures = []
      sunTarget = 0; sunDepth = 0; sunMap = 0
      sh = [0, 0]; shIndex = 0
      sphereAtlas = 0; sphereInfo = 0
      kernels = Kernels()
      captureShader = 0
      amplification = Akari.ShadowAtlas.Amplification()
      resourcesReady = false
      isReady = false
      layout = Layout()
      layoutKey = nil
      captured = 0
      relightFrames = 0
      sunKey = nil
      lastLighting = nil
    }

    /// Starts the capture and relight shaders compiling in the background.
    func precompileShaders()
    {
      guard captureShader == 0, !failed else { return }

      kernels.clear = gl.precompileComputeShader(name: "akari-probe-clear", glsl: "", msl: Self.clearMSL)
      kernels.project = gl.precompileComputeShader(name: "akari-probe-project", glsl: "", msl: Self.projectMSL)
      kernels.sphereBase = gl.precompileComputeShader(name: "akari-probe-sphere-base", glsl: "", msl: Self.sphereBaseMSL)
      kernels.sphereFilter = gl.precompileComputeShader(name: "akari-probe-sphere-filter", glsl: "", msl: Self.sphereFilterMSL)
      captureShader = gl.precompileShader(name: "akari-probe-capture",
                                          vertexGLSL: "",
                                          fragmentGLSL: "",
                                          vertexMSL: Self.captureMSL,
                                          fragmentMSL: nil)
      gl.setComputeShaderThreadgroupSize(kernels.clear, x: 16, y: 16, z: 1)
      gl.setComputeShaderThreadgroupSize(kernels.project, x: 256, y: 1, z: 1)
      gl.setComputeShaderThreadgroupSize(kernels.sphereBase, x: 16, y: 16, z: 1)
      gl.setComputeShaderThreadgroupSize(kernels.sphereFilter, x: 16, y: 16, z: 1)
    }

    private func ensureResources() -> Bool
    {
      if resourcesReady { return true }
      if failed { return false }

      precompileShaders()
      guard
        kernels.all.allSatisfy({ $0 != 0 && gl.waitComputeShader($0) != 0 }),
        gl.waitShader(captureShader) != 0
      else { return fail("probe shaders failed to compile") }

      amplification.views = gl.genInstanceTransforms(count: GLsizei(Akari.ShadowAtlas.maxAmplificationViews))
      amplification.viewports = gl.genInstanceViewports(count: GLsizei(Akari.ShadowAtlas.maxAmplificationViews))
      guard
        amplification.views != 0,
        amplification.viewports != 0
      else { return fail("amplification handle allocation failed") }

      captureTextures = (0 ..< 3).map
      { _ in
        makeTexture(width: Self.atlasWidth, height: Self.atlasHeight, internalFormat: GLint(GL_RGBA16F))
      }
      captureDepth = gl.createMemorylessDepthTexture(width: GLsizei(Self.atlasWidth),
                                                     height: GLsizei(Self.atlasHeight),
                                                     layers: 1,
                                                     internalFormat: GLenum(GL_DEPTH_COMPONENT32F))
      sunMap = makeTexture(width: Self.sunResolution, height: Self.sunResolution, internalFormat: GLint(GL_R32F))
      sunDepth = gl.createMemorylessDepthTexture(width: GLsizei(Self.sunResolution),
                                                 height: GLsizei(Self.sunResolution),
                                                 layers: 1,
                                                 internalFormat: GLenum(GL_DEPTH_COMPONENT32F))
      sh = (0 ..< 2).map
      { _ in
        makeTexture(width: Self.shProbesPerRow * 4,
                    height: Self.maxVolumeProbes / Self.shProbesPerRow,
                    internalFormat: GLint(GL_RGBA16F))
      }
      sphereAtlas = makeTexture(width: Self.octTile.x * Self.octTilesPerRow,
                                height: Self.octTile.y * Self.maxSphereProbes / Self.octTilesPerRow,
                                internalFormat: GLint(GL_RGBA16F))
      sphereInfo = makeTexture(width: Self.maxSphereProbes, height: 2, internalFormat: GL_RGBA32F)
      guard
        !captureTextures.contains(0), !sh.contains(0),
        captureDepth != 0, sunMap != 0, sunDepth != 0,
        sphereAtlas != 0, sphereInfo != 0
      else { return fail("probe texture allocation failed") }

      var rt: GLuint = 0
      gl.genRenderTarget(hasDepth: GLboolean(1), target: &rt)
      guard rt != 0 else { return fail("glGenRenderTarget failed") }
      for (slot, tex) in captureTextures.enumerated()
      {
        gl.renderTargetTexture(target: rt, attachment: GLenum(GL_COLOR_ATTACHMENT0) + GLenum(slot), texture: tex)
      }
      gl.renderTargetTexture(target: rt, attachment: GLenum(GL_DEPTH_ATTACHMENT), texture: captureDepth)
      captureTarget = rt

      rt = 0
      gl.genRenderTarget(hasDepth: GLboolean(1), target: &rt)
      guard rt != 0 else { return fail("glGenRenderTarget failed") }
      gl.renderTargetTexture(target: rt, attachment: GLenum(GL_COLOR_ATTACHMENT0), texture: sunMap)
      gl.renderTargetTexture(target: rt, attachment: GLenum(GL_DEPTH_ATTACHMENT), texture: sunDepth)
      sunTarget = rt

      precompileCaptureVariants()
      resourcesReady = true
      return true
    }

    /// Every amplified run the capture and sun passes replay, direct and indirect.
    private func precompileCaptureVariants()
    {
      let runs = [(captureTarget, Akari.ShadowAtlas.maxAmplificationViews), (sunTarget, 1)]
      for (target, maxCount) in runs
      {
        for count in 1 ... maxCount
        {
          for flags in [0, LGL_SHADER_VARIANT_INDIRECT]
          {
            gl.precompileShaderVariant(captureShader,
                                       renderTarget: target,
                                       blend: GLboolean(0),
                                       blendSource: 0,
                                       blendDestination: 0,
                                       amplification: GLsizei(count),
                                       flags: GLbitfield(flags))
          }
        }
      }
    }

    /// Row 0 of the sphere info, row 1 is the validity `project` writes.
    private func uploadSphereInfo()
    {
      var texels = [Float](repeating: 0, count: Self.maxSphereProbes * 2 * 4)
      for (i, sphere) in layout.spheres.enumerated()
      {
        texels[i * 4 + 0] = sphere.x
        texels[i * 4 + 1] = sphere.y
        texels[i * 4 + 2] = sphere.z
        texels[i * 4 + 3] = sphere.w
      }
      gl.bindTexture(target: GL_TEXTURE_2D, texture: sphereInfo)
      texels.withUnsafeBytes
      { buf in
        gl.texImage2D(target: GL_TEXTURE_2D,
                      level: 0,
                      internalFormat: GL_RGBA32F,
                      width: GLsizei(Self.maxSphereProbes),
                      height: 2,
                      border: 0,
                      format: GL_RGBA,
                      type: GL_FLOAT,
                      pixels: buf.baseAddress)
      }
      gl.bindTexture(target: GL_TEXTURE_2D, texture: 0)
    }

    private func makeTexture(width: Int, height: Int, internalFormat: GLint) -> GLuint
    {
      var tex: GLuint = 0
      gl.genTextures(count: 1, textures: &tex)
      guard tex != 0 else { return 0 }

      gl.bindTexture(target: GL_TEXTURE_2D, texture: tex)
      gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_MIN_FILTER, param: GLint(GL_LINEAR))
      gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_MAG_FILTER, param: GLint(GL_LINEAR))
      gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_WRAP_S, param: GLint(GL_CLAMP_TO_EDGE))
      gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_WRAP_T, param: GLint(GL_CLAMP_TO_EDGE))
      gl.texImage2D(target: GL_TEXTURE_2D,
                    level: 0,
                    internalFormat: internalFormat,
                    width: GLsizei(width),
                    height: GLsizei(height),
                    border: 0,
                    format: GL_RGBA,
                    type: GL_FLOAT,
                    pixels: nil)
      gl.bindTexture(target: GL_TEXTURE_2D, texture: 0)

      return tex
    }

    private func fail(_ message: String) -> Bool
    {
      print("[akari/probes] \(message), light probes disabled")
      release()
      failed = true
      return false
    }
  }
}
