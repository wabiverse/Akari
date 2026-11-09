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

    var windowHandle: LabGLWindowHandle?
    /// Parsed `.labfx` tree.
    private var graph: LabFXGraph?
    /// The scene geometry's static and dynamic captures.
    var geometry = SceneGeometry()
    /// The LabFX runtime driving the graph.
    var runtime = lab.fx.Runtime()
    var sizes = FrameSizes()

    /// Every pass up to the resolve renders at this fraction of the target, TAA upsamples the rest.
    public internal(set) var renderScale: Float = 1
    /// MetalFX upscales to this fraction of the target before the `downsample` pass, 1 when it's off.
    public internal(set) var supersampleScale: Float = 1
    var dynamicResolution = DynamicResolution()
    /// The scene's sheet of water, shaded as a plane, and the meshes it came from.
    var water: WaterPlane?
    var waterKeys: Set<UInt64> = []
    /// The temporal history starts over this frame.
    var temporalReset: Bool
    {
      temporal.reset
    }

    /// This frame's projection jitter, in G-buffer pixels.
    public var taaJitter = SIMD2<Float>(repeating: 0)

    // Buffers at the G-buffer's size, and at half of it.

    private static let renderBuffers: [Buffer] = [.gbuffer, .color, .transparentAccum, .transparentResolved, .upscaleInput,
                                                  .sunShadowRaw, .sunShadowAccum, .sunShadowHistory]
    private static let halfRenderBuffers: [Buffer] = [.ssgiPrep, .ssgiPyramid, .ssgi, .ssgiAccum, .ssgiHistory, .pointShadowRaw, .pointShadowBlur, .pointShadow, .fogSimHalf,
                                            .volumeScatter, .volumeIntegrated, .ssr, .ssrAccum, .ssrHistory]

    /// Pins the scene buffers to `renderScale` of `width` by `height`, for the next build or resize.
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

      sizes.half.width = max(min(sizes.render.width, width) / 2, 1)
      sizes.half.height = max(min(sizes.render.height, height) / 2, 1)
      for buffer in Self.halfRenderBuffers
      {
        runtime.stageBufferSize(buffer, width: Int32(sizes.half.width), height: Int32(sizes.half.height))
      }

      stageMotionBlurSize(width: width, height: height)
      sizes.supersample.width = supersampleScale > 1 ? Int(Float(width) * supersampleScale) : 1
      sizes.supersample.height = supersampleScale > 1 ? Int(Float(height) * supersampleScale) : 1
      runtime.stageBufferSize(.supersample, width: Int32(sizes.supersample.width), height: Int32(sizes.supersample.height))
    }

    /// Cached scene revision, skips capture when geometry is unchanged.
    var lastGeometryRevision: UInt64 = 0

    let materialAtlas = Akari.MaterialAtlas()
    let shadowAtlas = Akari.ShadowAtlas()
    let fireflies = Fireflies()
    let probeBake = ProbeBakeOverlay()

    /// World bounds of the last recorded geometry.
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
    /// Froxel depth reduction + column integration.
    let froxelVolume = Akari.FroxelVolume()

    static let mainShadowLights = 4
    static let maxPointLights = 64

    var pointLights = PointLights()

    var upscaling = Upscale()

    var environment = Environment()

    var probes = Probes()

    var shadows = Shadows()

    /// Volume + sphere light probes baked from the scene capture.
    let lightProbes = Akari.LightProbes()
    let ptex = Akari.PtexStream()

    /// This is `true` when the opened usd stage's upAxis is "Z".
    var stageIsZUp = false
    /// The opened usd stage's metersPerUnit.
    public internal(set) var stageMetersPerUnit: Float = 1

    /// AgX look LUTs, uploaded the first time each is used.
    var agxLooks: [Akari.Color.Look: GLuint] = [:]

    /// The last GL_TONEMAP_* operator applied to the tonemap pass.
    var lastTonemap = GLenum(0)

    /// The viewport reads big files (a volume's density) off the render thread instead of waiting on them.
    public var loadsInBackground = false
    /// The viewport is playing, so a probe bake goes a little each frame instead of all at once.
    public var isPlaying = false
    /// The stage's dome light, in place of the procedural sky.
    var dome: Dome?
    /// Called with Sun Height and Sun Angle putting the sun where the stage authored it, once per stage sun.
    public var onAuthoredSun: ((Float, Float) -> Void)?
    /// Set by `reloadTextures()` from the main actor, taken by the next sync.
    var forceDomeReload: Bool
    {
      get { reloadState.pointee.force }
      set { reloadState.pointee.force = newValue }
    }

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
    var lastSunHeight: Float = 0
    {
      didSet
      {
        // prevent redundant state changes.
        guard oldValue != lastSunHeight else { return }

        // when sunHeight changes the sky cubemap changes,
        // so the prefiltered IBL maps must be regenerated.
        setIBLPasses(active: true)
        environment.iblNeedsBake = true
      }
    }

    struct Temporal
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
      .ssr,
      .ssrTemporal,
      .ssrHistory
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

    /// Starts a new frame through LabGL. Ensures the engine and the deferred
    /// graph exist, resizes to the target, and opens the frame.
    public func beginFrame(width: Int, height: Int, hgi: Pixar.HgiMetal)
    {
      guard width > 0, height > 0 else { return }
      ensureEngine(width: width, height: height, hgi: hgi)
      guard let windowHandle else { return }

      if width != sizes.target.width || height != sizes.target.height
      {
        labgl.resize(windowHandle, width: Int32(width), height: Int32(height))
        stageRenderSize(width: width, height: height)
        runtime.resize(rootWidth: Int32(width), rootHeight: Int32(height))
        // buffer rebuild wipes the baked IBL textures,
        // so rerun the IBL passes on the next frame to
        // rebake, then disable them again.
        environment.iblNeedsBake = true
        environment.dfgNeedsBake = true
        volumes.bakedShadow = []
        temporal.prevViewProjection = nil
        volumetrics.previousViewProjection = nil
        ssgi.needsReset = true
        ssr.needsReset = true
        sizes.target.width = width
        sizes.target.height = height
      }
      else if renderScale != sizes.stagedRenderScale || supersampleScale != sizes.stagedSupersampleScale
      {
        // only the scene buffers change size, the baked IBL and the rest stay.
        stageRenderSize(width: width, height: height)
        for buffer in Self.renderBuffers + Self.halfRenderBuffers + [.supersample]
        {
          runtime.rebuildBuffer(buffer)
        }

        temporal.prevViewProjection = nil
        volumetrics.previousViewProjection = nil
        ssgi.needsReset = true
        ssr.needsReset = true
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

    /// Draws to this engine's LabGL targets from here on, a process can hold another engine's too.
    public func makeCurrent()
    {
      if let windowHandle { labgl.makeCurrent(windowHandle) }
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
      setFloat(.roughnessScale, 1.0)

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

      sizes.target.width = width
      sizes.target.height = height
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
