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
  /// drives the labgl and labfx graph, owned by `RenderEngine` and reached by passes through `FrameContext`
  final class LabFXEngine
  {
    public typealias LabGLWindowHandle = OpaquePointer
    public typealias LabGLCaptureBuffer = OpaquePointer
    public typealias LabFXGraph = UnsafeMutablePointer<lab.fx.Graph>

    var windowHandle: LabGLWindowHandle?
    /// the parsed labfx tree of the deferred graph.
    private var graph: LabFXGraph?
    /// the scene geometry's static and dynamic captures.
    var geometry = SceneGeometry()
    /// the labfx runtime driving the graph.
    var runtime = lab.fx.Runtime()
    var sizes = FrameSizes()

    /// every pass up to the resolve renders at this fraction of the target, taa upsamples the rest.
    public internal(set) var renderScale: Float = 1
    /// metalfx upscales to this fraction of the target before the downsample pass, 1 when it's off
    public internal(set) var supersampleScale: Float = 1
    var dynamicResolution = DynamicResolution()
    /// the scene's sheet of water, shaded as a plane, and the meshes it came from.
    var water: WaterPlane?
    var waterKeys: Set<UInt64> = []
    /// the temporal history starts over this frame.
    var temporalReset: Bool
    {
      temporal.reset
    }

    /// this frame's projection jitter, in g-buffer pixels.
    public var taaJitter = SIMD2<Float>(repeating: 0)

    // buffers at the g-buffer's size, and at half of it.

    // the back layer sits beside the gbuffer and the reflection trace that reads it runs at the gbuffer's size
    private static let renderBuffers: [Buffer] = [.gbuffer, .backGbuffer, .color, .transparentAccum, .transparentResolved, .upscaleInput,
                                                  .sunShadowRaw, .sunShadowAccum, .sunShadowHistory,
                                                  .sunShadowBlur, .sunShadowSoft,
                                                  .glassFront, .glassBack, .glassBehindFront, .glassBehindBack,
                                                  .transparentBehind, .transparentBehindResolved]

    // the caustics are splatted over the frame and read back through a wide disc, so finer than half size is lost in the blur anyway
    private static let halfRenderBuffers: [Buffer] = [.glassSunCaustic, .glassLocalCaustic, .glassCausticAccum, .glassCausticHistory,
                                            .ssgiPrep, .ssgiPyramid, .ssgi, .ssgiAccum, .ssgiHistory, .pointShadowRaw, .pointShadowBlur, .pointShadow, .fogSimHalf,
                                            .volumeScatter, .volumeIntegrated, .ssr, .ssrResolve, .ssrAccum, .ssrHistory]

    /// pins the scene buffers to `renderScale` of `width` by `height`, for the next build or resize.
    private func stageRenderSize(width: Int, height: Int)
    {
      sizes.stagedRenderScale = renderScale
      sizes.stagedSupersampleScale = supersampleScale
      sizes.render.width = max(Int(Float(width) * renderScale), 1)
      sizes.render.height = max(Int(Float(height) * renderScale), 1)
      for buffer in Self.renderBuffers
      {
        runtime.stageBufferSize(buffer, width: Int32(sizes.render.width), height: Int32(sizes.render.height))
      }

      // half the target at most but never coarser than the gbuffer, coarser left the reflection and gi traces too coarse to find hits
      sizes.half.width = max(min(sizes.render.width, width / 2), 1)
      sizes.half.height = max(min(sizes.render.height, height / 2), 1)
      for buffer in Self.halfRenderBuffers
      {
        runtime.stageBufferSize(buffer, width: Int32(sizes.half.width), height: Int32(sizes.half.height))
      }

      // the fog simulation reads its half buffer at exactly every other gbuffer pixel
      runtime.stageBufferSize(.fogSimHalf, width: Int32(max(sizes.render.width / 2, 1)), height: Int32(max(sizes.render.height / 2, 1)))

      stageMotionBlurSize(width: width, height: height)
      sizes.supersample.width = supersampleScale > 1 ? Int(Float(width) * supersampleScale) : 1
      sizes.supersample.height = supersampleScale > 1 ? Int(Float(height) * supersampleScale) : 1
      runtime.stageBufferSize(.supersample, width: Int32(sizes.supersample.width), height: Int32(sizes.supersample.height))
    }

    /// cached scene revision, skips capture when geometry is unchanged.
    var lastGeometryRevision: UInt64 = 0
    /// the scene these caches were filled from, a replaced stage brings a new scene so everything keyed to the old one has to go
    var lastSceneId: UInt64 = 0

    let materialAtlas = Akari.MaterialAtlas()
    let shadowAtlas = Akari.ShadowAtlas()
    let probeBake = ProbeBakeOverlay()

    /// world bounds of the last recorded geometry.
    var sceneBounds: (min: SIMD3<Float>, max: SIMD3<Float>)?
    var temporal = Temporal()
    var ssgi = ScreenSpaceGI()
    var ssr = ScreenSpaceReflections()
    var volumetrics = Volumetrics()
    public let fogSim = Akari.FogSim()
    var atmosphere = Atmosphere()
    var motionBlur = MotionBlur()
    var post = Post()
    var volumes = Volumes()
    var styles = Styles()
    var transparency = Transparency()
    var outline = Outline()
    /// froxel depth reduction and column integration
    let froxelVolume = Akari.FroxelVolume()
    let glassMaps = GlassMaps()
    let glassCaustics = GlassCaustics()

    static let mainShadowLights = 4
    static let maxPointLights = 64

    var pointLights = PointLights()

    var upscaling = Upscale()

    var environment = Environment()

    var probes = Probes()

    var shadows = Shadows()

    /// volume and sphere light probes baked from the scene capture
    let lightProbes = Akari.LightProbes()
    let ptex = Akari.PtexStream()

    /// true when the opened stage is z up
    var stageIsZUp = false
    /// the opened usd stage's metersPerUnit.
    public internal(set) var stageMetersPerUnit: Float = 1

    /// agx look tables, uploaded the first time each is used
    var agxLooks: [Akari.Color.Look: GLuint] = [:]

    /// the last tonemap operator given to the tonemap pass
    var lastTonemap = GLenum(0)

    /// the viewport reads big files like a volume's density off the render thread instead of waiting
    public var loadsInBackground = false
    /// the viewport is playing, so a probe bake goes a little each frame instead of all at once.
    public var isPlaying = false
    /// a prim is being transformed, so the light probes hold their last bake until the edit ends.
    public var isEditing = false
    /// the stage's dome light, in place of the procedural sky.
    var dome: Dome?
    /// called with sun height and sun angle putting the sun where the stage authored it, once per stage sun.
    public var onAuthoredSun: ((Float, Float) -> Void)?
    /// set by `reloadTextures()` from the main actor, taken by the next sync.
    var forceDomeReload: Bool
    {
      get { reloadState.pointee.force }
      set { reloadState.pointee.force = newValue }
    }

    /// set by `reloadTextures()` until the next sync rereads them.
    public internal(set) var reloadPending: Bool
    {
      get { reloadState.pointee.pending }
      set { reloadState.pointee.pending = newValue }
    }

    /// how far a reload has come, 0 to 1, written as the dome decodes.
    public var reloadProgress: Float
    {
      get { reloadState.pointee.progress }
      set { reloadState.pointee.progress = newValue }
    }

    /// heap storage the image loader writes into while the main actor reads it.
    let reloadState: UnsafeMutablePointer<(pending: Bool, force: Bool, progress: Float)> =
    {
      let state = UnsafeMutablePointer<(pending: Bool, force: Bool, progress: Float)>.allocate(capacity: 1)
      state.initialize(to: (false, false, 0))
      return state
    }()

    /// the last sunHeight value to determine if ibl needs rebaking.
    var lastSunHeight: Float = 0
    {
      didSet
      {
        // prevent redundant state changes.
        guard oldValue != lastSunHeight else { return }

        // a new sun height changes the sky cubemap, so the prefiltered ibl maps are made again
        setIBLPasses(active: true)
        environment.iblNeedsBake = true
      }
    }

    struct Temporal
    {
      /// unjittered view projection the last temporal resolve ran with.
      var prevViewProjection: Matrix4?
      var thisFrame = false
      /// frames of history behind the current pixel.
      var samples = 0
      /// this frame starts the history over.
      var reset = true
      /// the next frame starts the accumulation over, keeping the last camera for motion.
      var restart = false
      /// the unjittered view the last temporal resolve ran with, to tell a cut in an animation from a move
      var prevView: Matrix4?
      var lastFrame = 0.0
    }

    /// seconds of history a moving view keeps, so a slow frame doesn't trail further behind.
    static let movingHistorySeconds = 0.15

    struct ScreenSpaceGI
    {
      var thisFrame = false
      var passesActive = true
      var needsReset = true
    }

    struct ScreenSpaceReflections
    {
      var thisFrame = false
      var passesActive = true
      var needsReset = true
    }

    static let ssgiPassNames: [Pass] = [
      .ssgiPrep,
      .ssgiPyramid,
      .ssgi,
      .ssgiTemporal,
      .ssgiHistory
    ]

    static let ssrPassNames: [Pass] = [
      .hiz,
      .ssr,
      .ssrResolve,
      .ssrTemporal,
      .ssrHistory
    ]

    /// the faces turned away from the eye that screen space reflections trace behind, drawn right after the gbuffer
    static let backLayerPassNames: [Pass] = [
      .geometryBack,
      .geometryInstancedBack,
      .geometryDynamicBack
    ]

    static let gbufferPassNames: [Pass] = [
      .clearGbuffer,
      .geometry,
      .geometryInstanced,
      .geometryDynamic
    ]

    init()
    {}

    deinit
    {
      teardown()
    }

    /// recompiles a graph shader's passes whenever a signed edit of its source reloads, swapping it into the parsed graph
    private func watchGraphShaders()
    {
      guard Akari.ShaderSource.isWatching, let graph else { return }
      for index in 0 ..< graph.pointee.shaders.size()
      {
        let name = String(graph.pointee.shaders[index].name)
        for stage in [Akari.RenderGraph.Stage.Kind.vertex, .fragment]
        {
          Akari.ShaderSource.watch("\(name).\(stage.rawValue)")
          { [weak self] source in
            guard let self, let graph = self.graph else { return .gone }
            if stage == .vertex { graph.pointee.shaders[index].vsh_msl = std.string(source) }
            else { graph.pointee.shaders[index].fsh_msl = std.string(source) }

            // overriding a pass's shader with its own and back drops its compiled program, which the next render rebuilds.
            for pass in 0 ..< graph.pointee.passes.size() where String(graph.pointee.passes[pass].shader) == name
            {
              let passName = String(graph.pointee.passes[pass].name)
              self.runtime.setPassShader(passName, name)
              self.runtime.setPassShader(passName, nil)
            }
            return .swapped
          }
        }
      }
    }

    public func beginFrame(width: Int, height: Int, hgi: Pixar.HgiMetal)
    {
      guard width > 0, height > 0 else { return }
      ensureEngine(width: width, height: height, hgi: hgi)
      guard let windowHandle else { return }

      // the deformed draws replay unculled until this frame's camera culls them
      geometry.dynamicCulled = false
      Akari.ShaderSource.poll()

      if width != sizes.target.width || height != sizes.target.height
      {
        labgl.resize(windowHandle, width: Int32(width), height: Int32(height))
        stageRenderSize(width: width, height: height)
        runtime.resize(rootWidth: Int32(width), rootHeight: Int32(height))

        // a buffer rebuild wipes the baked ibl, so the ibl passes run again next frame to rebake
        environment.iblNeedsBake = true
        environment.dfgNeedsBake = true
        volumes.bakedShadow = []
        temporal.prevViewProjection = nil
        volumetrics.previousViewProjection = nil
        ssgi.needsReset = true
        ssr.needsReset = true
        forgetGlassViews()
        sizes.target.width = width
        sizes.target.height = height
      }
      else if renderScale != sizes.stagedRenderScale || supersampleScale != sizes.stagedSupersampleScale
      {
        // only the scene buffers change size, the baked ibl and the rest stay.
        stageRenderSize(width: width, height: height)
        for buffer in Self.renderBuffers + Self.halfRenderBuffers + [.supersample]
        {
          runtime.rebuildBuffer(buffer)
        }

        temporal.prevViewProjection = nil
        volumetrics.previousViewProjection = nil
        ssgi.needsReset = true
        ssr.needsReset = true
        forgetGlassViews()
      }

      if environment.iblNeedsBake { setIBLPasses(active: true) }

      if !temporal.thisFrame { temporal.prevViewProjection = nil }
      temporal.thisFrame = false
      setVector(.taa, SIMD4(0, 1, 1, 0))
      setVector(.renderScale, SIMD4(Float(sizes.render.width) / Float(width),
                                       Float(sizes.render.height) / Float(height),
                                       0, 0))
      setVector(.supersampleScale, SIMD4(Float(sizes.supersample.width) / Float(width),
                                            Float(sizes.supersample.height) / Float(height),
                                            0, 0))
      setVector(.halfScale, SIMD4(Float(sizes.render.width) / Float(sizes.half.width),
                                     Float(sizes.render.height) / Float(sizes.half.height),
                                     0, 0))

      ssgi.thisFrame = false
      setVector(.ssgi, SIMD4(0, 0, 0, 0))
      setVector(.horizonScan, SIMD4(0, 0, 0, 0))

      ssr.thisFrame = false
      setVector(.ssr, SIMD4(0, 0, 0, 0))

      setVector(.probeGridMin, SIMD4(0, 0, 0, 0))
      setVector(.probeGridMax, SIMD4(0, 0, 0, 0))

      volumetrics.thisFrame = false
      volumetrics.froxels = nil

      gl.clearDepth(0)
      labgl.beginFrame(windowHandle)
    }

    /// draws to this engine's labgl targets from here on, a process can hold another engine's too.
    public func makeCurrent()
    {
      if let windowHandle { labgl.makeCurrent(windowHandle) }
    }

    private func ensureEngine(width: Int, height: Int, hgi: Pixar.HgiMetal)
    {
      guard windowHandle == nil else { return }

      // headless attach, on hydra's queue so the aov handoff stays ordered.
      let queue = Unmanaged.passUnretained(hgi.GetQueue() as AnyObject).toOpaque()
      guard let handle = labgl.attachOffscreen(width: Int32(width), height: Int32(height), commandQueue: queue)
      else
      {
        print("[akari/labgl] labgl_attachOffscreen failed")
        return
      }

      windowHandle = handle

      // build the deferred graph once from its swift declaration.
      let graphSource = Akari.RenderGraph.deferred.labfx
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

      watchGraphShaders()

      // roughness reached at the prefilter's last mip.
      setFloat(.roughnessScale, 1.0)

      probeBake.attach(to: &runtime)

      attachVolumetrics()
      attachGlassMaps()
      attachGlassCaustics()

      // compiles in the background, each pass waits only on what it uses.
      lightProbes.precompileShaders()
      froxelVolume.precompileShaders()
      shadowAtlas.precompileShaders()
      glassMaps.precompileShaders()
      glassCaustics.precompileShaders()

      // capture buffers the geometry passes replay each frame.
      guard createCaptures(), createOutlineCapture()
      else
      {
        print("[akari/labgl] labgl_captureCreate failed")
        return
      }

      sizes.target.width = width
      sizes.target.height = height
    }

    private func teardown()
    {
      probeBake.release()
      shadowAtlas.release()
      froxelVolume.release()
      glassMaps.release()
      glassCaustics.release()
      if transparency.glassLights != 0 { gl.deleteTextures(count: 1, textures: &transparency.glassLights) }
      transparency.glassLights = 0
      transparency.glassPassesActive = [:]
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
