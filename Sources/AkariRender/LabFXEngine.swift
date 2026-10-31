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
import HydraKit
import LabFX
import LabGL
import simd

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
    /// The scene geometry's static and dynamic captures.
    var geometry = SceneGeometry()
    /// The LabFX runtime driving the graph.
    var runtime = lab.fx.Runtime()
    var lastWidth = 0
    var lastHeight = 0
    /// Every pass up to the resolve renders at this fraction of the target, TAA upsamples the rest.
    public internal(set) var renderScale: Float = 1
    /// What the scene buffers were last staged at.
    private var stagedRenderScale: Float = 1
    /// MetalFX upscales to this fraction of the target before the `downsample` pass, 1 when it's off.
    public internal(set) var supersampleScale: Float = 1
    private var stagedSupersampleScale: Float = 1
    var supersampleWidth = 1
    var supersampleHeight = 1
    var dynamicResolution = DynamicResolution()
    var upscaleMode = UpscaleMode.taa
    /// The textures the upscale callback reads, looked up before the graph runs.
    var upscaleTextures = UpscaleTextures()
    var upscaleRegistered = false
    /// MetalFX turned an upscale down, the TAA pass takes over.
    var upscaleFailed = false
    /// The scene's sheet of water, shaded as a plane, and the meshes it came from.
    var water: WaterPlane?
    var waterKeys: Set<UInt64> = []
    /// MetalFX's temporal scaler waits out a heavy frame or memory pressure on the TAA pass until then.
    var neuralUpscaleHeldUntil = Date.distantPast
    /// The geometry records `prepareUpscale` last saw.
    var upscaleRecords = 0
    /// The temporal history starts over this frame.
    var temporalReset: Bool
    {
      temporal.reset
    }

    /// The G-buffer's size, `renderScale` of the target's.
    var renderWidth = 0
    var renderHeight = 0
    /// The half res effect buffers size, half of the smaller of the G-buffer and target.
    var halfWidth = 1
    var halfHeight = 1
    /// This frame's projection jitter, in G-buffer pixels.
    public var taaJitter = SIMD2<Float>(repeating: 0)

    // Buffers at the G-buffer's size, and at half of it.

    private static let renderBuffers = ["gbuffer", "color", "transparentAccum", "transparentResolved", "upscaleInput"]
    private static let halfRenderBuffers = ["ssgiPrep", "ssgiPyramid", "ssgi", "ssgiAccum", "ssgiHistory", "pointShadowRaw", "pointShadowBlur", "pointShadow", "fogSimHalf",
                                            "volumeScatter", "volumeIntegrated", "ssr", "ssrAccum", "ssrHistory"]

    /// Pins the scene buffers to `renderScale` of `width` by `height`, for the next build or resize.
    private func stageRenderSize(width: Int, height: Int)
    {
      stagedRenderScale = renderScale
      stagedSupersampleScale = supersampleScale
      renderWidth = max(Int(Float(width) * renderScale), 1)
      renderHeight = max(Int(Float(height) * renderScale), 1)
      for name in Self.renderBuffers
      {
        runtime.stageBufferSize(name, width: Int32(renderWidth), height: Int32(renderHeight))
      }
      halfWidth = max(min(renderWidth, width) / 2, 1)
      halfHeight = max(min(renderHeight, height) / 2, 1)
      for name in Self.halfRenderBuffers
      {
        runtime.stageBufferSize(name, width: Int32(halfWidth), height: Int32(halfHeight))
      }
      stageMotionBlurSize(width: width, height: height)
      supersampleWidth = supersampleScale > 1 ? Int(Float(width) * supersampleScale) : 1
      supersampleHeight = supersampleScale > 1 ? Int(Float(height) * supersampleScale) : 1
      runtime.stageBufferSize("supersample", width: Int32(supersampleWidth), height: Int32(supersampleHeight))
    }

    /// Cached scene revision, skips capture when geometry is unchanged.
    var lastGeometryRevision: UInt64 = 0

    private let materialAtlas = Akari.MaterialAtlas()
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
    public let fogSim = Akari.FogSim()
    var atmosphere = Atmosphere()
    var motionBlur = MotionBlur()
    var post = Post()
    var volumes = Volumes()
    var styles = Styles()
    var transparency = Transparency()
    var outline = Outline()
    /// Froxel depth reduction + column integration.
    let froxelVolume = Akari.FroxelVolume()

    var syncedPointLights: [Akari.Lux.PointLight] = []
    /// Each shadowed light's path, by the slot its shadow maps stay in.
    var shadowSlots: [String] = []
    /// The shadowed lights kept at full resolution, swapped only for one lighting the view far more.
    var mainShadowKeys: Set<String> = []
    /// Each shadowed light's visible, shadowed light on screen, smoothed over frames.
    var lightImportance: [String: Float] = [:]
    var importanceKernel: GLuint = 0
    var importanceReadback: GLuint = 0
    var importanceBoxes: [GLuint] = []
    var importanceBoxCursor = 0
    /// The frame each main light took its place, its hold on it fading from then.
    var mainSince: [String: UInt64] = [:]
    var lightSyncs: UInt64 = 0
    var lightPositions: [String: SIMD3<Float>] = [:]
    /// Lights seen moving, the ones that follow a character.
    var followLights: Set<String> = []
    static let mainShadowLights = 4
    /// The lights that shade, `syncedPointLights` are the shadowed front of them.
    var litPointLights: [Akari.Lux.PointLight] = []
    var pointLightTexture: GLuint = 0
    static let maxPointLights = 64

    /// Volume + sphere light probes baked from the scene capture.
    let lightProbes = Akari.LightProbes()
    let ptex = Akari.PtexStream()
    var probeOverrides: [Akari.LightProbes.Override] = []
    var probeOverrideRevision: UInt64 = .max
    /// Probe identity without the transform, keys the probe layout bake.
    var probeStructuralRevision: UInt64 = 0
    /// The material, color and emissive atlases the probe capture samples.
    var probeMaterials: (material: GLuint, color: GLuint, emissive: GLuint, constants: GLuint) = (0, 0, 0, 0)

    /// This is `true` when the opened usd stage's upAxis is "Z".
    var stageIsZUp = false

    /// Call once, right after opening the usd stage.
    public func setStageUpAxis(isZUp: Bool)
    {
      stageIsZUp = isZUp
    }

    /// The opened usd stage's metersPerUnit.
    public internal(set) var stageMetersPerUnit: Float = 1

    /// Call once, right after opening the usd stage.
    public func setStageMetersPerUnit(_ metersPerUnit: Double)
    {
      stageMetersPerUnit = metersPerUnit > 0 ? Float(metersPerUnit) : 1
    }

    /// Compute sun direction based on the opened usd stages's upAxis.
    func worldSpaceSunDirection(_ light: LightSettings) -> SIMD3<Float>
    {
      if let distant = distantSun { return distant.direction }
      if let sun = dome?.sunDirection { return sun }
      let sky = light.sunDirection
      return stageIsZUp ? SIMD3(sky.x, -sky.z, sky.y) : sky
    }

    /// AgX look LUTs, uploaded the first time each is used.
    var agxLooks: [Akari.Color.Look: GLuint] = [:]

    /// The last GL_TONEMAP_* operator applied to the tonemap pass.
    private var lastTonemap = GLenum(0)

    /// IBL is expensive, this sets a flag to bake it once.
    var iblNeedsBake = true
    /// The DFG table only depends on the BRDF, it bakes again only after the buffers are rebuilt.
    var dfgNeedsBake = true
    /// The viewport reads big files (a volume's density) off the render thread instead of waiting on them.
    public var loadsInBackground = false
    /// The viewport is playing, so a probe bake goes a little each frame instead of all at once.
    public var isPlaying = false
    /// The stage's dome light, in place of the procedural sky.
    var dome: Dome?
    /// The stage's brightest distant light, shading as the sun in place of the dome's or the sky's.
    var distantSun: (direction: SIMD3<Float>, irradiance: SIMD3<Float>, angle: Float)?
    /// The rect light shading as `distantSun`, out of the local lights.
    var rectSunKey: String?
    var domeRevision: UInt64 = .max
    /// What the image based lighting was last baked from, the dome's file, frame and banded color.
    var domeBakeKey: (file: String, values: [Float]) = ("\u{0}", [])
    /// Set by `reloadTextures()` from the main actor, taken by the next sync.
    var forceDomeReload: Bool
    {
      get { reloadState.pointee.force }
      set { reloadState.pointee.force = newValue }
    }

    /// Bumped when the environment changes, the light probes relight from it.
    var environmentRevision: UInt64 = 0
    /// Set by `reloadTextures()` until the next sync rereads them.
    public internal(set) var reloadPending: Bool
    {
      get { reloadState.pointee.pending }
      set { reloadState.pointee.pending = newValue }
    }

    /// How far a reload has come, 0 to 1, written as the dome decodes.
    public var reloadProgress: Float
    {
      get { reloadState.pointee.progress }
      set { reloadState.pointee.progress = newValue }
    }

    /// Heap storage the image loader writes into while the main actor reads it.
    let reloadState: UnsafeMutablePointer<(pending: Bool, force: Bool, progress: Float)> =
    {
      let state = UnsafeMutablePointer<(pending: Bool, force: Bool, progress: Float)>.allocate(capacity: 1)
      state.initialize(to: (false, false, 0))
      return state
    }()

    /// The last sunHeight value to determine if IBL needs rebaking.
    private var lastSunHeight: Float = 0
    {
      didSet
      {
        // prevent redundant state changes.
        guard oldValue != lastSunHeight else { return }

        // when sunHeight changes the sky cubemap changes,
        // so the prefiltered IBL maps must be regenerated.
        setIBLPasses(active: true)
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
      /// This frame starts the history over.
      var reset = true
      /// The next frame starts the accumulation over, keeping the last camera for motion.
      var restart = false
      var lastFrame = 0.0
    }

    /// Seconds of history a moving view keeps, so a slow frame doesn't trail further behind.
    static let movingHistorySeconds = 0.15

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
      "geometry",
      "geometry instanced",
      "geometry dynamic"
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
        stageRenderSize(width: width, height: height)
        runtime.resize(rootWidth: Int32(width), rootHeight: Int32(height))
        // buffer rebuild wipes the baked IBL textures,
        // so rerun the IBL passes on the next frame to
        // rebake, then disable them again.
        iblNeedsBake = true
        dfgNeedsBake = true
        volumes.bakedShadow = []
        temporal.prevViewProjection = nil
        volumetrics.previousViewProjection = nil
        ssgi.needsReset = true
        ssr.needsReset = true
        lastWidth = width
        lastHeight = height
      }
      else if renderScale != stagedRenderScale || supersampleScale != stagedSupersampleScale
      {
        // only the scene buffers change size, the baked IBL and the rest stay.
        stageRenderSize(width: width, height: height)
        for name in Self.renderBuffers + Self.halfRenderBuffers + ["supersample"]
        {
          runtime.rebuildBuffer(name)
        }
        temporal.prevViewProjection = nil
        volumetrics.previousViewProjection = nil
        ssgi.needsReset = true
        ssr.needsReset = true
      }

      if iblNeedsBake { setIBLPasses(active: true) }

      if !temporal.thisFrame { temporal.prevViewProjection = nil }
      temporal.thisFrame = false
      setVector("u_taa", SIMD4(0, 1, 1, 0))
      setVector("u_renderScale", SIMD4(Float(renderWidth) / Float(width),
                                       Float(renderHeight) / Float(height),
                                       0, 0))
      setVector("u_supersampleScale", SIMD4(Float(supersampleWidth) / Float(width),
                                            Float(supersampleHeight) / Float(height),
                                            0, 0))
      setVector("u_halfScale", SIMD4(Float(renderWidth) / Float(halfWidth),
                                     Float(renderHeight) / Float(halfHeight),
                                     0, 0))

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

    /// Rerecords the synced meshes that changed into the captures, the
    /// selected ones into the outline's, and sets the per frame view
    /// matrix (LabGL's geometry stage).
    ///
    /// - Parameters:
    ///   - renderParam: opaque `HdAkariRenderParam`.
    ///   - view: 16 row-major floats, world->view.
    ///   - projection: 16 row-major floats, view->clip.
    ///   - unjitteredProjection: `projection` without the TAA jitter.
    ///   - selection: what to outline, if anything.
    public func recordGeometry(renderParam: Pixar.HdAkariRenderParam,
                               view: Matrix4,
                               projection: Matrix4,
                               unjitteredProjection: Matrix4,
                               selection: Akari.Selection?,
                               planetCloudMarchSteps: Int)
    {
      guard
        geometry.staticCapture != nil,
        let scene = renderParam.GetScene()
      else { return }

      updateOutline(selection, projection: unjitteredProjection, sceneProjection: projection)

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
        let constantsTex = materialAtlas.uploadConstants(atlas)
        setSampler("u_materialConstants", constantsTex)
        probeMaterials = (materialTex, colorTex, emissiveTex, constantsTex)
      }

      syncDome(scene)
      syncDistant(scene)

      setMatrix("u_eyeToWorld", view.inverse())
      let eye = view.inverse().transform(.zero)
      syncAtmosphere(scene, eye: eye, cloudMarchSteps: planetCloudMarchSteps)
      syncVolumes(scene)
      let snapshot = scene.LightSnapshot().filter { $0.id.string != rectSunKey }
      let domeSun = dome.flatMap { dome in dome.sun.map { ($0.irradiance * dome.color).max() } }
      let sunFloor = (distantSun?.irradiance.max() ?? domeSun ?? 0) * 0.05
      let keys = snapshot.map(\.id.string)
      var lights = snapshot.map
      { light in
        let mat = Pixar.GfMatrix4f(light.transform)
        let (position, xAxis, yAxis): (SIMD3<Float>, SIMD3<Float>, SIMD3<Float>) = if let mPtr = mat.GetArray()
        {
          (SIMD3(mPtr[12], mPtr[13], mPtr[14]), SIMD3(mPtr[0], mPtr[1], mPtr[2]), SIMD3(mPtr[4], mPtr[5], mPtr[6]))
        }
        else
        {
          (.zero, .zero, .zero)
        }
        var point = Akari.Lux.PointLight(position: position,
                                         color: SIMD3(light.colorR, light.colorG, light.colorB),
                                         intensity: light.intensity * exp2(light.exposure),
                                         radius: light.radius,
                                         diffuse: light.diffuse,
                                         specular: light.specular,
                                         halfAxis: xAxis * light.length * 0.5,
                                         tubeRadius: light.tubeRadius)
        point.halfWidth = xAxis * light.width * 0.5
        point.halfHeight = yAxis * light.height * 0.5
        point.cameraVisible = light.cameraVisible
        point.probes = light.probes && light.tubeRadius <= 0
        // under a sun a lamp's shadow fades out where it gives 1/20th of the sun's light.
        point.shadowFloor = max(1e-3, sunFloor)
        return point
      }
      // the ones that light the view the most, by their irradiance at the camera
      // or at the animated geometry, whichever they light more.
      let subject = geometry.dynamicBatch.bounds.map { ($0.min + $0.max) * 0.5 }
      func irradiance(_ light: Akari.Lux.PointLight, at point: SIMD3<Float>) -> Float
      {
        let d = light.position - point
        let r2 = light.radius * light.radius
        return light.intensity * light.color.max() * r2 / max((d * d).sum(), r2)
      }
      func weight(_ light: Akari.Lux.PointLight) -> Float
      {
        max(irradiance(light, at: eye), subject.map { irradiance(light, at: $0) } ?? 0)
      }
      // practicals (LEDs and the like) sit in their own fixture, so only lights
      // reaching past a meter cast shadows, and those take the first slots.
      // a light keeps its slot while it stays shadowed, so reranking never hands its maps to another.
      // a light that has moved and reaches an animated mesh follows a character, so it's a hero too.
      for (i, key) in keys.enumerated()
      {
        if let last = lightPositions[key], ((last - lights[i].position) * (last - lights[i].position)).sum() > 1e-8
        {
          followLights.insert(key)
          lights[i].moved = ((lights[i].position - last) * (lights[i].position - last)).sum().squareRoot()
        }
        lightPositions[key] = lights[i].position
      }
      let animated = geometry.dynamicBatch.bounds
      let heroes = Set(snapshot.filter(\.hero).map(\.id.string)).union(zip(keys, lights).compactMap
      { key, light in
        guard followLights.contains(key), let animated else { return nil }
        let gap = light.position - pointwiseMin(pointwiseMax(light.position, animated.min), animated.max)
        return (gap * gap).sum() < light.reach * light.reach ? key : nil
      })
      let sorted = lights.indices.sorted
      {
        heroes.contains(keys[$0]) != heroes.contains(keys[$1]) ? heroes.contains(keys[$0]) : weight(lights[$0]) > weight(lights[$1])
      }
      let minShadowReach = 1 / stageMetersPerUnit
      let wanted = Set(sorted.filter { lights[$0].reach >= minShadowReach }
        .prefix(Akari.ShadowAtlas.maxPunctualLights).map { keys[$0] })
      var slots = shadowSlots
      var slot = 0
      while slot < slots.count
      {
        if wanted.contains(slots[slot]) { slot += 1 } else { slots[slot] = slots[slots.count - 1]; slots.removeLast() }
      }
      slots += sorted.map { keys[$0] }.filter { wanted.contains($0) && !slots.contains($0) }
      shadowSlots = slots
      let index = Dictionary(keys.indices.map { (keys[$0], $0) }, uniquingKeysWith: { first, _ in first })
      var weights: [String: Float] = [:]
      for key in slots
      {
        if let i = index[key] { weights[key] = lightImportance[key] ?? weight(lights[i]) * Float(Self.importanceSamples) }
      }
      lightSyncs &+= 1
      // heroes win outright, the rest by score, a light already main holding on
      // with a bonus that starts high and settles, so assignments never flicker.
      for key in Array(mainSince.keys) where !mainShadowKeys.contains(key) || weights[key] == nil
      {
        mainSince[key] = nil
      }
      func held(_ key: String) -> Float
      {
        guard let since = mainSince[key] else { return 1 }
        return 2 + 2 * exp(-Float(lightSyncs &- since) / 120)
      }
      let ranked = slots.sorted
      {
        heroes.contains($0) != heroes.contains($1)
          ? heroes.contains($0)
          : weights[$0, default: 0] * held($0) > weights[$1, default: 0] * held($1)
      }
      let mains = Set(ranked.prefix(Self.mainShadowLights))
      for key in mains where mainSince[key] == nil
      {
        mainSince[key] = lightSyncs
      }
      mainShadowKeys = mains
      shadowAtlas.mainSlots = Set(slots.indices.filter { mains.contains(slots[$0]) })
      syncedPointLights = slots.compactMap { index[$0].map { lights[$0] } }
      litPointLights = Array((syncedPointLights + sorted.filter { !wanted.contains(keys[$0]) }.map { lights[$0] })
        .prefix(Self.maxPointLights))

      geometry.restyled = syncStyles(scene) || geometry.restyled
      geometry.deformer.eye = eye
      geometry.deformer.zUp = stageIsZUp
      let drained = scene.DrainMeshChanges()
      var changed: [Akari.Geom.Recorder.RawMesh] = []
      var removed = Array(drained.removed)
      changed.reserveCapacity(drained.updated.size())

      for mesh in drained.updated
      {
        let key = Pixar.HdAkariPathKey(mesh.id)
        let mat = Pixar.GfMatrix4f(mesh.transform)
        guard
          !mesh.points.empty(),
          !mesh.triangleIndices.empty(),
          let mPtr = mat.GetArray()
        else
        {
          removed.append(key)
          continue
        }

        let worldMatrix = Array(UnsafeBufferPointer(start: mPtr, count: 16))
        let normalMatrix = Matrix.normalMatrix3x3(mPtr)
        let flipWinding = Matrix.determinant3x3(mPtr) < 0

        var raw = Akari.Geom.Recorder.RawMesh(id: mesh.id.string,
                                              key: key,
                                              primId: mesh.primId,
                                              dataRevision: mesh.dataRevision,
                                              topologyRevision: mesh.topologyRevision,
                                              flipWinding: flipWinding,
                                              points: mesh.points,
                                              tris: mesh.triangleIndices,
                                              uvs: mesh.uvs,
                                              worldMatrix: worldMatrix,
                                              normalMatrix: normalMatrix,
                                              contentKey: mesh.contentKey)
        raw.transparent = mesh.transparent
        raw.emitter = mesh.emitter
        raw.opacity = mesh.opacity
        raw.smooth = mesh.smooth
        raw.color = SIMD3(mesh.displayColor[0], mesh.displayColor[1], mesh.displayColor[2])
        raw.roughness = mesh.roughness
        raw.triangleFaces = mesh.triangleFaces
        raw.faceRes = mesh.faceRes
        raw.ptexMap = Int32(mesh.ptexMap)
        let instanceCount = Int(mesh.instances.size())
        if instanceCount > 0
        {
          // every mesh under one prototype shares its set, copied once.
          raw.instancesKey = mesh.instancesKey
          if let shared = geometry.instanceSets[mesh.instancesKey], shared.count == instanceCount * 16
          {
            raw.instances = shared
          }
          else
          {
            raw.instances = [Float](repeating: 0, count: instanceCount * 16)
            raw.instances.withUnsafeMutableBufferPointer
            { buffer in
              Pixar.HdAkariCopyInstances(mesh, buffer.baseAddress!)
            }
            geometry.instanceSets[mesh.instancesKey] = raw.instances
          }
          if let live = Akari.LiveInstances.prototype(of: raw.id), live.slot.count == instanceCount { raw.livePrototype = live.path }
        }
        let joints = Int(Pixar.HdAkariSkinJointCount(mesh))
        if joints > 0
        {
          raw.skinInfluencesPerPoint = Int(mesh.skinInfluencesPerPoint)
          raw.skinInfluences = mesh.skinInfluences
          raw.skinRevision = mesh.skinRevision
          raw.skinPalette = [Float](repeating: 0, count: joints * 12)
          raw.skinBounds = [Float](repeating: 0, count: 6)
          raw.skinPalette.withUnsafeMutableBufferPointer
          { palette in
            raw.skinBounds.withUnsafeMutableBufferPointer { Pixar.HdAkariCopySkin(mesh, palette.baseAddress!, $0.baseAddress!) }
          }
        }
        changed.append(raw)
      }
      lastGeometryRevision = scene.Revision()

      // the viewport chooses its geometry again where the camera settles,past
      // the margin it was chosen for or 1/30th of the scene from before.
      let forward = simd_normalize(view.inverse().transform(SIMD3(0, 0, -1)) - eye)
      if eye != geometry.lastEye || forward != geometry.lastForward
      {
        geometry.lastEye = eye
        geometry.lastForward = forward
        geometry.eyeMoved = Date()
      }
      if loadsInBackground, let recorded = geometry.camera, let bounds = sceneBounds,
         simd_distance(eye, recorded.eye) > simd_length(bounds.max - bounds.min) * 0.03
         || simd_dot(forward, recorded.forward) < cos(RecordCamera.margin),
         Date().timeIntervalSince(geometry.eyeMoved) > 0.5
      {
        geometry.reframe = true
      }
      // a record during a load's peak held less than the scene can have once it settles.
      if loadsInBackground, geometry.records > 0, Date().timeIntervalSince(geometry.recordedAt) > 5,
         triangleBudgetGrew()
      {
        geometry.reframe = true
      }

      if !changed.isEmpty || !removed.isEmpty || geometry.records == 0 || geometry.restyled || geometry.reframe
      {
        geometry.camera = RecordCamera(view: view, projection: unjitteredProjection, height: renderHeight,
                                       frustum: !loadsInBackground)
        recordCaptures(changed: changed, removed: removed)
      }
      else
      {
        geometry.deformer.settle()
      }
      // the shadow maps cache static pages, so the flags meshes just brought have to be up before they're drawn.
      if geometry.emitters != styles.emitters || geometry.transparent != styles.transparent || geometry.opacity != styles.opacity
      {
        geometry.restyled = syncStyles(scene) || geometry.restyled
      }
      recordOutline(changed: changed, removed: removed)
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
        if name == "geometry", encodeLateCull()
        {
          runtime.setMeshCaptureCulledSlot("mesh-static", slot: Self.cameraLateCullSlot)
          runtime.renderPass(name)
        }
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
                            view: Matrix4,
                            light: LightSettings,
                            shadowsEnabled: Bool)
    {
      setFloat("u_iblEnabled", iblEnabled ? 1 : 0)
      setMatrix("u_proj", projection)
      setMatrix("u_invProj", projection.inverse())

      setFloat("sunHeight", light.sunHeight)
      lastSunHeight = light.sunHeight // handles IBL rebaking, if changed.

      let sun = worldSpaceSunDirection(light)
      setVector("u_sunDirection", SIMD4(sun.x, sun.y, sun.z, distantSun.map { $0.angle * 0.5 } ?? light.sunAngle * 0.5))
      setVector("u_sunOverride", distantSun.map { SIMD4($0.irradiance, 1) } ?? .zero)
      applyAtmosphere(sun: sun)
      applyVolumes(sun: sun)
      applyTransparency(projection: projection, view: view)

      setFloat("u_shadowEnabled", shadowsEnabled && shadowsReady ? 1 : 0)
      setFloat("u_zUp", stageIsZUp ? 1 : 0)
      applyDome()

      setFloat("u_punctualShadowEnabled", shadowsEnabled && shadowsReady ? 1 : 0)
      setFloat("u_pointLightCount", Float(litPointLights.count))
      setFloat("u_shadowedPointLightCount", Float(syncedPointLights.count))
      for slot in 0 ..< 4
      {
        let p = slot < litPointLights.count ? litPointLights[slot] : nil
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
      uploadPointLights()
    }

    /// Every lit point light, six texels a light, for the lighting pass.
    private func uploadPointLights()
    {
      if pointLightTexture == 0
      {
        gl.genTextures(count: 1, textures: &pointLightTexture)
        gl.bindTexture(target: GL_TEXTURE_2D, texture: pointLightTexture)
        gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_MIN_FILTER, param: GLint(GL_NEAREST))
        gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_MAG_FILTER, param: GLint(GL_NEAREST))
        gl.texImage2D(target: GL_TEXTURE_2D, level: 0, internalFormat: GL_RGBA32F,
                      width: 6, height: GLsizei(Self.maxPointLights), border: 0,
                      format: GL_RGBA, type: GL_FLOAT, pixels: nil)
      }
      guard pointLightTexture != 0 else { return }

      let texels: [Float] = litPointLights.enumerated().flatMap
      { i, light in
        let shadowed = i < syncedPointLights.count
        // a tube's half axis and radius, or a rect's half width and -1, then a rect's half height.
        let shape = light.halfWidth != .zero ? SIMD4(light.halfWidth, -1) : SIMD4(light.halfAxis, light.tubeRadius)
        return [light.position.x, light.position.y, light.position.z, light.intensity,
                light.color.x, light.color.y, light.color.z, light.radius,
                light.diffuse, light.specular,
                shadowed ? shadowAtlas.lodBias(slot: i) : 0,
                shadowed && shadowAtlas.mainSlots.contains(i) ? 1 : 0,
                shape.x, shape.y, shape.z, shape.w,
                light.halfHeight.x, light.halfHeight.y, light.halfHeight.z, light.moved,
                light.cameraVisible ? 1 : 0, 0, 0, 0]
      }
      if !texels.isEmpty
      {
        gl.bindTexture(target: GL_TEXTURE_2D, texture: pointLightTexture)
        gl.texSubImage2D(target: GL_TEXTURE_2D, level: 0, xOffset: 0, yOffset: 0,
                         width: 6, height: GLsizei(litPointLights.count),
                         format: GL_RGBA, type: GL_FLOAT, pixels: texels)
      }
      setSampler("u_pointLightData", pointLightTexture)
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
      let restart = previous == nil || temporal.restart
      let now = ProcessInfo.processInfo.systemUptime
      let elapsed = max(now - temporal.lastFrame, 1e-3)
      temporal.lastFrame = now
      let moved = min(10, limit, max(2, Int(Self.movingHistorySeconds / elapsed)))
      temporal.samples = restart ? 1
        : moving && motionBlur.subframes == 0 ? moved
        : min(temporal.samples + 1, limit)

      setMatrix("u_prevViewProj", previous ?? viewProjection)
      setMatrix("u_currViewProj", viewProjection)
      setVector("u_taa", SIMD4(1, restart ? 1 : 0, 1 / Float(temporal.samples), motionBlur.subframes > 0 ? 1 : 0))
      setVector("u_taaJitter", SIMD4(taaJitter.x, taaJitter.y, 0, 0))
      temporal.reset = restart
      temporal.restart = false
      temporal.prevViewProjection = viewProjection
      temporal.thisFrame = true
    }

    /// Starts every temporal accumulation over on the next frame,
    /// so a final render frame never blends in the one before it.
    public func resetHistory()
    {
      temporal.prevViewProjection = nil
      volumetrics.previousViewProjection = nil
      ssgi.needsReset = true
      ssr.needsReset = true
    }

    /// Starts the temporal accumulation over on the next frame, keeping this frame's
    /// camera and geometry as the previous ones so the next frame still has motion.
    public func restartAccumulation()
    {
      temporal.restart = true
      ssgi.needsReset = true
      ssr.needsReset = true
    }

    /// Turns on screen space GI for this frame.
    public func setScreenSpaceGI(maxRoughness: Float = 0.5)
    {
      let diagonal = sceneBounds.map { $0.max - $0.min } ?? SIMD3(repeating: 1)
      let radius = max((diagonal * diagonal).sum().squareRoot() * 0.15, 1e-3)
      setVector("u_ssgi", SIMD4(radius, radius * 0.2, 1, ssgi.needsReset || !ssgi.passesActive ? 1 : 0))

      let size = SIMD2<Float>(Float(halfWidth * 2), Float(halfHeight * 2))
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
    ///   - look: the AgX look, its baked LUT.
    ///   - frameIndex: per frame counter to seed the dither.
    public func setTonemap(exposure: Float,
                           gamma: Float,
                           viewTransform: Akari.Color.ViewTransform,
                           look: Akari.Color.Look,
                           frameIndex: UInt64)
    {
      setFloat("exposure", exposure)
      setFloat("gamma", gamma)
      setInt("frameIndex", Int32(frameIndex & 0xFFFF))
      bindAgXLook(viewTransform == .agx ? look : nil)

      if viewTransform.uniform != lastTonemap
      {
        lastTonemap = viewTransform.uniform

        runtime.setPassTonemap("tonemap", tonemap: viewTransform.uniform)
      }
    }

    /// Executes the deferred graph, outlines the selection, presents, and wraps the
    /// final color, prim id and depth textures into the AOV render buffers Hydra
    /// presents and picks with (LabGL's present stage).
    ///
    /// - Parameters:
    ///   - target: the AOV render buffers Hydra bound.
    ///   - projection: the unjittered camera projection, for the depth AOV.
    ///   - hgi: the `HgiMetal` shared with Hydra.
    public func present(target: Akari.GPU.HydraTarget,
                        projection: Matrix4,
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
      runtime.setPassActive("ssgi prep", active: ssgi.thisFrame || ssr.thisFrame)

      syncVolumetrics()
      syncMotionBlur()
      syncPost()
      setVector("u_aovProjection", SIMD4(projection[2, 2], projection[3, 2], 0, 0))

      prepareUpscale()
      syncPtex()
      if iblNeedsBake { setIBLPasses(active: true) }
      runtime.render()
      finishAtmosphereFrame()

      // bake the IBL once.
      if iblNeedsBake
      {
        setIBLPasses(active: false)
        dfgNeedsBake = false
        iblNeedsBake = false
      }
      labgl.present(windowHandle)

      // hand the graph's final color and id/depth
      // textures to the AOVs through Hgi.
      let outputs = [
        (target.color, outlinedTexture),
        (target.primId, runtime.texture("aov", named: "aovPrimId")),
        (target.instanceId, runtime.texture("aov", named: "aovInstanceId")),
        (target.depth, runtime.texture("aov", named: "aovDepth"))
      ]
      for case let (renderBuffer?, texture) in outputs where texture != 0
      {
        let native = lglGetTextureNativeHandle(texture)
        if native != 0
        {
          Pixar.AkariRenderBufferSetExternalTexture(renderBuffer, hgi, native)
        }
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
        let graphSource = (try? String(contentsOf: url, encoding: .utf8)).map(Self.expandIncludes)
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

      stageRenderSize(width: width, height: height)
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

      // capture buffers the geometry passes replay each frame.
      guard createCaptures(), createOutlineCapture()
      else
      {
        print("[akari/labgl] labgl_captureCreate failed")
        return
      }

      lastWidth = width
      lastHeight = height
    }

    /// Splices each `//@include <resource>` line's bundled file in its place, at its indent.
    private static func expandIncludes(_ source: String) -> String
    {
      source.split(separator: "\n", omittingEmptySubsequences: false).map
      { line in
        let trimmed = line.drop { $0 == " " }
        guard trimmed.hasPrefix("//@include ") else { return String(line) }
        let name = trimmed.dropFirst("//@include ".count).trimmingCharacters(in: .whitespaces)
        let file = name as NSString
        guard
          let url = Bundle.akari.url(forResource: file.deletingPathExtension, withExtension: file.pathExtension),
          let text = (try? String(contentsOf: url, encoding: .utf8)).map(expandIncludes)
        else { return String(line) }
        let indent = String(line.prefix(line.count - trimmed.count))
        return text.split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? "" : indent + $0 }.joined(separator: "\n")
      }.joined(separator: "\n")
    }

    private func teardown()
    {
      fireflies.release()
      probeBake.release()
      shadowAtlas.release()
      froxelVolume.release()
      lightProbes.release()
      releaseOutline()

      gl.shaderCacheFlush()

      runtime.destroy()
      destroyCaptures()
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
