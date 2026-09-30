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
import HdAkari
import LabFX
import LabGL
import OpenUSDKit

public extension Akari
{
  /// Drives the LabGL / LabFX graph. Owned by `RenderEngine`, reached
  /// by passes through `FrameContext`.
  final class LabFXEngine
  {
    public typealias LabGLWindowHandle = OpaquePointer
    public typealias LabGLCaptureBuffer = OpaquePointer
    public typealias LabFXGraph = UnsafeMutablePointer<lab.fx.Graph>

    private var windowHandle: LabGLWindowHandle?
    /// Parsed `.labfx` tree.
    private var graph: LabFXGraph?
    /// Buffer the scene geometry is recorded into.
    var captureBuffer: LabGLCaptureBuffer?
    /// The LabFX runtime driving the graph.
    var runtime = lab.fx.Runtime()
    var lastWidth = 0
    var lastHeight = 0

    /// Cached scene revision, skips capture when geometry is unchanged.
    var lastGeometryRevision: UInt64 = 0

    private let materialAtlas = Akari.MaterialAtlas()
    private let recorder = Akari.Geom.Recorder()
    let shadowAtlas = Akari.ShadowAtlas()
    private let fireflies = Fireflies()
    private let probeBake = ProbeBakeOverlay()
    var boundShadowAtlas: GLuint = 0

    /// World bounds of the last recorded geometry.
    var sceneBounds: (min: SIMD3<Float>, max: SIMD3<Float>)?
    /// Per caster world AABBs for the shadow tilemap's own GPU tagging.
    var casterBounds: [Float] = []
    /// Per caster, a hash of its world positions, matching `casterBounds`.
    var casterKeys: [UInt64] = []
    /// Set once the atlas has tiles the deferred pass can sample.
    var shadowsReady = false
    private var temporal = Temporal()
    private var ssgi = ScreenSpaceGI()
    private var ssr = ScreenSpaceReflections()
    var volumetrics = Volumetrics()
    /// Froxel depth reduction + column integration.
    let froxelVolume = Akari.FroxelVolume()

    var syncedPointLights: [Akari.Lux.PointLight] = []

    /// Volume + sphere light probes baked from the scene capture.
    let lightProbes = Akari.LightProbes()
    var probeOverrides: [Akari.LightProbes.Override] = []
    var probeOverrideRevision: UInt64 = .max
    /// Probe identity without the transform, keys the probe layout bake.
    var probeStructuralRevision: UInt64 = 0
    /// The material, color and emissive atlases the probe capture samples.
    var probeMaterials: (material: GLuint, color: GLuint, emissive: GLuint) = (0, 0, 0)

    /// This is `true` when the opened usd stage's upAxis is "Z".
    var stageIsZUp = false

    /// Call once, right after opening the usd stage.
    public func setStageUpAxis(isZUp: Bool)
    {
      stageIsZUp = isZUp
    }

    /// Compute sun direction based on the opened usd stages's upAxis.
    func worldSpaceSunDirection(_ light: LightSettings) -> SIMD3<Float>
    {
      let sky = light.sunDirection
      return stageIsZUp ? SIMD3(sky.x, -sky.z, sky.y) : sky
    }

    /// The last GL_TONEMAP_* operator applied to the tonemap pass.
    private var lastTonemap = GLenum(0)

    /// IBL is expensive, this sets a flag to bake it once.
    private var iblNeedsBake = true
    /// The last sunHeight value to determine if IBL needs rebaking.
    private var lastSunHeight: Float = 0
    {
      didSet
      {
        // prevent redundant state changes.
        guard oldValue != lastSunHeight else { return }

        // when sunHeight changes the sky cubemap changes,
        // so the prefiltered IBL maps must be regenerated.
        setPasses(Self.iblPassNames, active: true)
        iblNeedsBake = true
      }
    }

    private struct Temporal
    {
      /// Unjittered view projection the last temporal resolve ran with.
      var prevViewProjection: Matrix4?
      var thisFrame = false
      /// Frames of history behind the current pixel.
      var samples = 0
    }

    private struct ScreenSpaceGI
    {
      var thisFrame = false
      var passesActive = true
      var needsReset = true
    }

    private struct ScreenSpaceReflections
    {
      var thisFrame = false
      var passesActive = true
      var needsReset = true
    }

    private static let iblPassNames = [
      "sky",
      "prefilter",
      "irradiance",
      "dfg"
    ]

    private static let ssgiPassNames = [
      "ssgi prep",
      "ssgi pyramid",
      "ssgi",
      "ssgi temporal",
      "ssgi history"
    ]

    private static let ssrPassNames = [
      "ssr",
      "ssr temporal",
      "ssr history"
    ]

    private static let gbufferPassNames = [
      "clear gbuffer",
      "geometry"
    ]

    init()
    {}

    deinit
    {
      teardown()
    }

    /// Starts a new frame through LabGL. Ensures the engine and the deferred
    /// graph exist, resizes to the target, and opens the frame.
    ///
    /// - Parameters:
    ///   - width: AOV width dimension in pixels.
    ///   - height: AOV height dimension in pixels.
    ///   - hgi: the `HgiMetal` whose command queue LabGL submits on.
    public func beginFrame(width: Int, height: Int, hgi: Pixar.HgiMetal)
    {
      guard width > 0, height > 0 else { return }
      ensureEngine(width: width, height: height, hgi: hgi)
      guard let windowHandle else { return }

      if width != lastWidth || height != lastHeight
      {
        labgl.resize(windowHandle, width: Int32(width), height: Int32(height))
        runtime.resize(rootWidth: Int32(width), rootHeight: Int32(height))
        // buffer rebuild wipes the baked IBL textures,
        // so rerun the IBL passes on the next frame to
        // rebake, then disable them again.
        iblNeedsBake = true
        temporal.prevViewProjection = nil
        volumetrics.previousViewProjection = nil
        ssgi.needsReset = true
        ssr.needsReset = true
        lastWidth = width
        lastHeight = height
      }

      if iblNeedsBake { setPasses(Self.iblPassNames, active: true) }

      if !temporal.thisFrame { temporal.prevViewProjection = nil }
      temporal.thisFrame = false
      setVector("u_taa", SIMD4(0, 1, 1, 0))

      ssgi.thisFrame = false
      setVector("u_ssgi", SIMD4(0, 0, 0, 0))
      setVector("u_horizonScan", SIMD4(0, 0, 0, 0))

      ssr.thisFrame = false
      setVector("u_ssr", SIMD4(0, 0, 0, 0))

      setVector("u_probeGridMin", SIMD4(0, 0, 0, 0))
      setVector("u_probeGridMax", SIMD4(0, 0, 0, 0))

      volumetrics.thisFrame = false
      volumetrics.froxels = nil

      gl.clearDepth(0)
      labgl.beginFrame(windowHandle)
    }

    /// Rerecords the synced meshes into the capture buffer and sets
    /// the per frame view matrix (LabGL's geometry stage).
    ///
    /// - Parameters:
    ///   - renderParam: opaque `HdAkariRenderParam`.
    ///   - view: 16 row-major floats, world->view.
    ///   - projection: 16 row-major floats, view->clip.
    public func recordGeometry(renderParam: Pixar.HdAkariRenderParam,
                               view: Matrix4,
                               projection: Matrix4)
    {
      guard
        let captureBuffer,
        let scene = renderParam.GetScene()
      else { return }

      gl.matrixMode(GL_PROJECTION)
      gl.loadMatrix(Matrix4.reversedDepth(projection).m)
      gl.matrixMode(GL_MODELVIEW)
      gl.loadMatrix(view.m)

      runtime.setViewMatrix(view.m)

      // the shared roughness/metallic/opacity texture atlas.
      if let atlas = renderParam.GetTextureAtlas()
      {
        let (materialTex, colorTex, normalTex, emissiveTex) = materialAtlas.uploadIfNeeded(atlas)
        setSampler("u_material_atlas", materialTex)
        setSampler("u_color_atlas", colorTex)
        setSampler("u_normal_atlas", normalTex)
        setSampler("u_emissive_atlas", emissiveTex)
        probeMaterials = (materialTex, colorTex, emissiveTex)
      }

      let lights = scene.LightSnapshot().prefix(4)

      syncedPointLights = lights.map
      { light in
        let mat = Pixar.GfMatrix4f(light.transform)
        let position: SIMD3<Float> = if let mPtr = mat.GetArray()
        {
          SIMD3(mPtr[12], mPtr[13], mPtr[14])
        }
        else
        {
          .zero
        }
        return Akari.Lux.PointLight(position: position,
                                    color: SIMD3(light.colorR, light.colorG, light.colorB),
                                    intensity: light.intensity * exp2(light.exposure),
                                    radius: light.radius)
      }

      // only capture when geometry has changed.
      let rev = scene.Revision()
      guard rev != lastGeometryRevision else { return }
      lastGeometryRevision = rev

      let meshes = scene.Snapshot()

      var triangleEstimate = 0
      var rawMeshes: [Akari.Geom.Recorder.RawMesh] = []
      rawMeshes.reserveCapacity(meshes.count)

      for mesh in meshes
      {
        if mesh.points.empty() || mesh.triangleIndices.empty() { continue }

        triangleEstimate += mesh.triangleIndices.size()

        let mat = Pixar.GfMatrix4f(mesh.transform)
        guard let mPtr = mat.GetArray() else { continue }

        let worldMatrix = Array(UnsafeBufferPointer(start: mPtr, count: 16))
        let normalMatrix = Matrix.normalMatrix3x3(mPtr)
        let flipWinding = Matrix.determinant3x3(mPtr) < 0

        rawMeshes.append(Akari.Geom.Recorder.RawMesh(id: mesh.id.string,
                                                     dataRevision: mesh.dataRevision,
                                                     flipWinding: flipWinding,
                                                     points: mesh.points,
                                                     tris: mesh.triangleIndices,
                                                     uvs: mesh.uvs,
                                                     worldMatrix: worldMatrix,
                                                     normalMatrix: normalMatrix))
      }

      rawMeshes.sort { Self.mortonKey($0.worldMatrix) < Self.mortonKey($1.worldMatrix) }

      let items = recorder.record(rawMeshes)

      gl.bindTexture(target: GL_TEXTURE_2D, texture: 0)
      labgl.captureClear(captureBuffer)
      labgl.captureStart(captureBuffer)

      gl.enable(GL_DEPTH_TEST)
      gl.depthFunc(GLenum(GL_GREATER))

      gl.enable(GL_CULL_FACE)
      gl.cullFace(GL_BACK)
      gl.frontFace(GL_CCW)

      let batch = Akari.Geom.Batch(estimatedTriangles: triangleEstimate)
      for item in items
      {
        item.worldMatrix.withUnsafeBufferPointer
        { buf in
          batch.append(localVerts: item.verts, localIndices: item.indices,
                       worldMatrix: buf.baseAddress!, normalMatrix: item.normalMatrix)
        }
      }
      batch.draw()
      labgl.captureStop()

      sceneBounds = batch.worldBounds
      casterBounds = batch.casterBounds
      casterKeys = batch.casterKeys
    }

    /// Rasterizes the G-buffer now instead of waiting
    /// for `present()`'s final `runtime.render()`.
    public func renderGbufferEarly()
    {
      guard windowHandle != nil else { return }

      ensureShadowBindings()

      for name in Self.gbufferPassNames
      {
        runtime.renderPass(name)
        runtime.setPassActive(name, active: false)
      }
    }

    /// Sets the deferred lighting stage state: the split sum IBL toggle,
    /// the inverse projection, and the Hosek-Wilkie sky parameters.
    ///
    /// - Parameters:
    ///   - iblEnabled: gates the split sum IBL lobes.
    ///   - projection: 16 row-major floats, view->clip.
    ///   - light: sun height and shadow configuration.
    ///   - shadowsEnabled: gates the cascade lookup.
    public func setLighting(iblEnabled: Bool,
                            projection: Matrix4,
                            light: LightSettings,
                            shadowsEnabled: Bool)
    {
      setFloat("u_iblEnabled", iblEnabled ? 1 : 0)
      setMatrix("u_proj", projection)
      setMatrix("u_invProj", projection.inverse())

      setFloat("sunHeight", light.sunHeight)
      lastSunHeight = light.sunHeight // handles IBL rebaking, if changed.

      let sun = worldSpaceSunDirection(light)
      setVector("u_sunDirection", SIMD4(sun.x, sun.y, sun.z, light.sunAngle * 0.5))

      setFloat("u_shadowEnabled", shadowsEnabled && shadowsReady ? 1 : 0)
      setFloat("u_zUp", stageIsZUp ? 1 : 0)

      setFloat("u_punctualShadowEnabled", shadowsEnabled && shadowsReady ? 1 : 0)
      setFloat("u_pointLightCount", Float(syncedPointLights.count))
      for slot in 0 ..< 4
      {
        let p = slot < syncedPointLights.count ? syncedPointLights[slot] : nil
        setVector("u_pointLightPosIntensity\(slot)",
                  SIMD4(p?.position.x ?? 0,
                        p?.position.y ?? 0,
                        p?.position.z ?? 0,
                        p?.intensity ?? 0))
        setVector("u_pointLightColorRadius\(slot)",
                  SIMD4(p?.color.x ?? 0,
                        p?.color.y ?? 0,
                        p?.color.z ?? 0,
                        p?.radius ?? 1))
      }
    }

    /// Turns the temporal resolve on for this frame.
    ///
    /// - Parameters:
    ///   - camera: this frame's unjittered camera.
    ///   - samples: the viewport sample count.
    ///   - moving: whether the camera moved since last frame.
    public func setTemporal(camera: Akari.Camera, samples: Int, moving: Bool)
    {
      let viewProjection = camera.projection * camera.view
      let limit = max(samples, 1)
      let previous = temporal.prevViewProjection
      temporal.samples = previous == nil ? 1
        : moving ? min(10, limit)
        : min(temporal.samples + 1, limit)

      setMatrix("u_prevViewProj", previous ?? viewProjection)
      setMatrix("u_currViewProj", viewProjection)
      setVector("u_taa", SIMD4(1, previous == nil ? 1 : 0, 1 / Float(temporal.samples), 0))
      temporal.prevViewProjection = viewProjection
      temporal.thisFrame = true
    }

    /// Turns on screen space GI for this frame.
    public func setScreenSpaceGI(maxRoughness: Float = 0.5)
    {
      let diagonal = sceneBounds.map { $0.max - $0.min } ?? SIMD3(repeating: 1)
      let radius = max((diagonal * diagonal).sum().squareRoot() * 0.15, 1e-3)
      setVector("u_ssgi", SIMD4(radius, radius * 0.2, 1, ssgi.needsReset || !ssgi.passesActive ? 1 : 0))

      let size = SIMD2<Float>(Float(max(lastWidth, 1)), Float(max(lastHeight, 1)))
      setVector("u_ssgiSize", SIMD4(size.x, size.y, 1 / size.x, 1 / size.y))
      setVector("u_horizonScan", SIMD4(maxRoughness, 1, 0, 0))
      ssgi.needsReset = false
      ssgi.thisFrame = true
    }

    /// Turns on screen space reflections for this frame.
    public func setScreenSpaceReflections(maxRoughness: Float = 0.5)
    {
      let diagonal = sceneBounds.map { $0.max - $0.min } ?? SIMD3(repeating: 1)
      let distance = max((diagonal * diagonal).sum().squareRoot(), 1e-3)
      setVector("u_ssr", SIMD4(maxRoughness, distance, 1, ssr.needsReset || !ssr.passesActive ? 1 : 0))
      ssr.needsReset = false
      ssr.thisFrame = true
    }

    /// Sets the tonemap stage state: exposure, gamma,
    /// view transform, and the dithering frame seed.
    ///
    /// - Parameters:
    ///   - exposure: exposure setting the tonemap pass reads.
    ///   - gamma: gamma setting the tonemap pass reads.
    ///   - viewTransform: (e.g. AgX) selects the LabGL tonemap operator.
    ///   - frameIndex: per frame counter to seed the dither.
    public func setTonemap(exposure: Float,
                           gamma: Float,
                           viewTransform: Akari.Color.ViewTransform,
                           frameIndex: UInt64)
    {
      setFloat("exposure", exposure)
      setFloat("gamma", gamma)
      setInt("frameIndex", Int32(frameIndex & 0xFFFF))

      if viewTransform.uniform != lastTonemap
      {
        lastTonemap = viewTransform.uniform

        runtime.setPassTonemap("tonemap", tonemap: viewTransform.uniform)
      }
    }

    /// Executes the deferred graph, presents, and wraps the final color texture into
    /// the color AOV render buffer Hydra presents (LabGL's present stage).
    ///
    /// - Parameters:
    ///   - color: the color AOV's render buffer, if bound.
    ///   - hgi: the `HgiMetal` shared with Hydra.
    public func present(color: Pixar.HdAkariRenderBuffer?,
                        hgi: Pixar.HgiMetal,
                        fireflies enableFireflies: Bool = false,
                        lightProbes showLightProbes: Bool = false)
    {
      guard let windowHandle else { return }

      fireflies.update(enabled: enableFireflies)
      probeBake.update(enabled: showLightProbes, probes: lightProbes)

      ensureShadowBindings()

      if ssgi.thisFrame != ssgi.passesActive
      {
        setPasses(Self.ssgiPassNames, active: ssgi.thisFrame)
        ssgi.passesActive = ssgi.thisFrame
      }

      if ssr.thisFrame != ssr.passesActive
      {
        setPasses(Self.ssrPassNames, active: ssr.thisFrame)
        ssr.passesActive = ssr.thisFrame
      }

      syncVolumetrics()

      runtime.render()

      // bake the IBL once.
      if iblNeedsBake
      {
        setPasses(Self.iblPassNames, active: false)
        iblNeedsBake = false
      }
      labgl.present(windowHandle)

      // export the tonemapped color buffer's native texture
      // and hand it to the color AOV through Hgi.
      guard let color else { return }
      let finalTex = runtime.texture("tonemap", named: "tonemap")
      guard finalTex != 0 else { return }
      let native = lglGetTextureNativeHandle(finalTex)
      if native != 0
      {
        Pixar.AkariRenderBufferSetExternalTexture(color, hgi, native)
      }
    }

    /// `runtime.setUniform` takes a pointer, so each of
    /// these binds an addressable value for the caller.
    func setFloat(_ name: String, _ value: Float)
    {
      var value = value
      runtime.setUniform(name, type: GL_FLOAT, data: &value)
    }

    func setInt(_ name: String, _ value: Int32)
    {
      var value = value
      runtime.setUniform(name, type: GL_INT, data: &value)
    }

    /// Skips texture names LabGL hasn't uploaded yet.
    func setSampler(_ name: String, _ texture: GLuint)
    {
      guard texture != 0 else { return }
      var texture = texture
      runtime.setUniform(name, type: GL_SAMPLER_2D, data: &texture)
    }

    func setVector(_ name: String, _ value: SIMD4<Float>)
    {
      var value = value
      runtime.setUniform(name, type: GL_FLOAT_VEC4, data: &value)
    }

    func setMatrix(_ name: String, _ matrix: Matrix4)
    {
      matrix.withUnsafeFloats
      { buf in
        runtime.setUniform(name, type: GL_FLOAT_MAT4, data: buf.baseAddress)
      }
    }

    /// Toggles a set of graph passes on/off.
    func setPasses(_ names: [String], active: Bool)
    {
      for name in names
      {
        runtime.setPassActive(name, active: active)
      }
    }

    /// Morton code of a mesh's world position, quantized against a fixed grid (in meters).
    private static func mortonKey(_ worldMatrix: [Float]) -> UInt64
    {
      func part(_ v: Float) -> UInt64
      {
        var x = UInt64(UInt32(bitPattern: Int32(max(-1_048_576, min(1_048_575, (v * 8).rounded())) + 1_048_576)) & 0x1FFFFF)
        x = (x | (x << 32)) & 0x1F_0000_0000_FFFF
        x = (x | (x << 16)) & 0x1F_0000_FF00_00FF
        x = (x | (x << 8)) & 0x100F_00F0_0F00_F00F
        x = (x | (x << 4)) & 0x10C3_0C30_C30C_30C3
        x = (x | (x << 2)) & 0x1249_2492_4924_9249
        return x
      }
      return part(worldMatrix[12]) | (part(worldMatrix[13]) << 1) | (part(worldMatrix[14]) << 2)
    }

    private func ensureEngine(width: Int, height: Int, hgi: Pixar.HgiMetal)
    {
      guard windowHandle == nil else { return }

      // headless attach, on hydra's queue so the AOV handoff stays ordered.
      let queue = Unmanaged.passUnretained(hgi.GetQueue() as AnyObject).toOpaque()
      guard let handle = labgl.attachOffscreen(width: Int32(width), height: Int32(height), commandQueue: queue)
      else
      {
        print("[akari/labgl] labgl_attachOffscreen failed")
        return
      }
      windowHandle = handle

      // parse + build the deferred graph once.
      guard
        let url = Bundle.akari.url(forResource: "DeferredGraph", withExtension: "labfx"),
        let graphSource = try? String(contentsOf: url, encoding: .utf8)
      else
      {
        print("[akari/labgl] DeferredGraph.labfx missing from bundle")
        return
      }
      guard let parsed = lab.fx.parse(graphSource, length: graphSource.utf8.count)
      else
      {
        print("[akari/labgl] labfx parse failed")
        return
      }
      graph = parsed

      guard runtime.build(parsed, rootWidth: Int32(width), rootHeight: Int32(height))
      else
      {
        print("[akari/labgl] labfx runtime build failed")
        return
      }

      // roughness reached at the prefilter's last mip.
      setFloat("roughnessScale", 1.0)

      fireflies.attach(to: &runtime)
      probeBake.attach(to: &runtime)

      attachVolumetrics()

      // compiles in the background, each pass waits only on what it uses.
      lightProbes.precompileShaders()
      froxelVolume.precompileShaders()
      shadowAtlas.precompileShaders()

      // capture buffer the geometry pass replays each frame.
      guard let cap = labgl.captureCreate()
      else
      {
        print("[akari/labgl] labgl_captureCreate failed")
        return
      }
      runtime.setMeshCapture("mesh", buffer: cap)
      captureBuffer = cap

      lastWidth = width
      lastHeight = height
    }

    private func teardown()
    {
      fireflies.release()
      probeBake.release()
      shadowAtlas.release()
      froxelVolume.release()
      lightProbes.release()

      gl.shaderCacheFlush()

      runtime.destroy()
      if let captureBuffer
      {
        labgl.captureDestroy(captureBuffer)
        self.captureBuffer = nil
      }
      if let graph
      {
        lab.fx.free(graph)
        self.graph = nil
      }
      if let windowHandle
      {
        labgl.destroyWindow(windowHandle)
        self.windowHandle = nil
      }
    }
  }
}
