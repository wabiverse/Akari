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
import LabGL
import simd

public extension Akari
{
  /// The core Akari render engine. Owns the resolved frame graph and
  /// executes it each frame. Created once by the app, retained by the
  /// `HdAkariRenderDelegate`, and driven by `HdAkariRenderPass` every
  /// frame.
  final class RenderEngine
  {
    /// Live configuration, safe to set from any thread. The frame
    /// graph rebuilds at the start of the next `renderFrame`.
    public var settings: RenderSettings
    {
      get { settingsLock.withLock { _settings } }
      set
      {
        settingsLock.withLock
        {
          _settings = newValue
          settingsPendingRebuild = true
        }
      }
    }

    /// What the viewport outlines, safe to set from any thread.
    public var selection: Akari.Selection?
    {
      get { settingsLock.withLock { _selection } }
      set { settingsLock.withLock { _selection = newValue } }
    }

    /// The viewport overlay toggle for the selection outline, safe
    /// to set from any thread. Never drawn into a final render.
    public var showsSelectionOutline: Bool
    {
      get { settingsLock.withLock { _showsSelectionOutline } }
      set { settingsLock.withLock { _showsSelectionOutline = newValue } }
    }

    /// The sample a final render is accumulating, safe to set from any thread.
    /// While set, frames render as final with every sample on its own jitter,
    /// at the render sample count, at a fixed resolution, with no viewport
    /// overlays.
    public var finalRenderSample: Int?
    {
      get { settingsLock.withLock { _finalRenderSample } }
      set { settingsLock.withLock { _finalRenderSample = newValue } }
    }

    /// The size the viewport last drew at, read on the frame queue.
    public private(set) var viewportSize = (width: 0, height: 0)

    private let settingsLock = NSLock()
    private var _settings: RenderSettings
    private var _finalRenderSample: Int?
    private var _selection: Akari.Selection?
    private var _showsSelectionOutline = true
    private var settingsPendingRebuild = false
    private var pipeline: RenderPipeline
    private var graph: [any Akari.GPU.RenderPassNode]
    /// The features `graph` was built for, the settings' own or the stage's say over volumetrics.
    private var graphFeatures: RenderFeatures
    private var gpu: Akari.GPU.HydraContext?
    public let labfx = Akari.LabFXEngine()
    private var frameIndex: UInt64 = 0
    /// Viewport frames rendered so far.
    public private(set) var viewportFrames = 0
    private var lastStatsRevision: UInt64 = 0
    private var lastCamera: (view: [Float], projection: [Float])?
    private let viewportCameraLock = NSLock()
    private var _viewportCamera: (view: simd_float4x4, projection: simd_float4x4)?

    /// The viewport's last frame world -> view and view -> clip, safe to read from any thread.
    public var viewportCamera: (view: simd_float4x4, projection: simd_float4x4)?
    {
      viewportCameraLock.withLock { _viewportCamera }
    }

    public init(settings: RenderSettings = RenderSettings())
    {
      _settings = settings
      pipeline = RenderPipeline(settings: settings)
      graph = RenderEngine.buildGraph(for: settings)
      graphFeatures = settings.features
    }

    /// The passes the latest settings run, in order.
    public var activePasses: [RenderPassID]
    {
      RenderPipeline(settings: settings).activePasses
    }

    /// Rebuilds the graph if the settings changed, returning the snapshot this frame runs with.
    private func applyPendingSettings() -> RenderSettings
    {
      let (stored, pending) = settingsLock.withLock
      {
        defer { settingsPendingRebuild = false }
        return (_settings, settingsPendingRebuild)
      }

      var settings = stored
      // the stage's `/World/RenderSettings` turns the fog on or off over the settings.
      if let stage = labfx.usdVolume, stage.hasEnabled
      {
        if stage.enabled { settings.features.insert(.volumetrics) } else { settings.features.remove(.volumetrics) }
      }

      if pending || settings.features != graphFeatures
      {
        pipeline.settings = settings
        graph = RenderEngine.buildGraph(for: settings)
        graphFeatures = settings.features
      }

      return settings
    }

    /// Per frame entry point. Called by the Hydra render pass.
    public func renderFrame(hgi: Pixar.HgiMetal,
                            renderParam: Pixar.HdAkariRenderParam,
                            color: Pixar.HdAkariRenderBuffer?,
                            depth: Pixar.HdAkariRenderBuffer?,
                            primId: Pixar.HdAkariRenderBuffer?,
                            instanceId: Pixar.HdAkariRenderBuffer?,
                            view: [Float],
                            projection: [Float],
                            width: Int,
                            height: Int,
                            isFinalRender: Bool = false)
    {
      // Hydra's frame queue doesn't drain an autorelease pool between frames, so drain one per frame here
      // instead of letting Metal and MetalFX objects pile up until the queue goes idle.
      autoreleasepool
      {
        drawFrame(hgi: hgi, renderParam: renderParam, color: color, depth: depth, primId: primId,
                  instanceId: instanceId, view: view, projection: projection, width: width, height: height,
                  isFinalRender: isFinalRender)
      }
    }

    private func drawFrame(hgi: Pixar.HgiMetal,
                           renderParam: Pixar.HdAkariRenderParam,
                           color: Pixar.HdAkariRenderBuffer?,
                           depth: Pixar.HdAkariRenderBuffer?,
                           primId: Pixar.HdAkariRenderBuffer?,
                           instanceId: Pixar.HdAkariRenderBuffer?,
                           view: [Float],
                           projection: [Float],
                           width: Int,
                           height: Int,
                           isFinalRender: Bool)
    {
      labfx.makeCurrent()
      var settings = applyPendingSettings()
      let finalSample = finalRenderSample
      let isFinalRender = isFinalRender || finalSample != nil
      if finalSample != nil
      {
        settings.features.remove(.dynamicResolution)
        settings.samples = max(settings.renderSamples, 1)
      }

      if isFinalRender { settings.shading = .rendered }
      settings.features.formIntersection(settings.shading.features)

      if gpu?.wraps(hgi) != true
      {
        gpu = Akari.GPU.HydraContext(hgi: hgi, backend: settings.backend)
      }

      guard
        let gpu,
        width > 0,
        height > 0
      else { return }

      if !isFinalRender, width > 1, height > 1 { viewportSize = (width, height) }
      labfx.loadsInBackground = !isFinalRender
      logSceneStats(renderParam)

      // detect camera motion so the TAA resolve can skip accumulation
      // while the view changes to prevent ghosting.
      let cameraMoved = lastCamera.map
      {
        !matrixNear($0.view, view) || !matrixNear($0.projection, projection)
      } ?? true

      lastCamera = (view: view, projection: projection)
      if !isFinalRender
      {
        viewportCameraLock.withLock { _viewportCamera = (Matrix4(view).simd, Matrix4(projection).simd) }
      }

      let unjitteredCamera = Akari.Camera(view: Matrix4(view), projection: Matrix4(projection),
                                          metersPerUnit: labfx.stageMetersPerUnit)
      var camera = unjitteredCamera
      labfx.cameraShutter = SIMD2(Float(renderParam.GetShutterOpen()), Float(renderParam.GetShutterClose()))
      labfx.updateRenderScale(settings: settings)
      labfx.configureUpscale(settings: settings, width: width, height: height)
      labfx.taaJitter = .zero
      if settings.features.contains(.temporalAA)
      {
        let index = finalSample.map { UInt64($0 % settings.samples) + 1 }
          ?? frameIndex % UInt64(min(max(settings.samples, 1), 16)) + 1
        let jitter = SIMD2(Self.halton(index, 2), Self.halton(index, 3)) - 0.5
        let renderWidth = Float(max(Int(Float(width) * labfx.renderScale), 1))
        let renderHeight = Float(max(Int(Float(height) * labfx.renderScale), 1))
        camera.projection = Matrix4.translation(SIMD3(2 * jitter.x / renderWidth,
                                                      2 * jitter.y / renderHeight, 0)) * camera.projection
        labfx.taaJitter = jitter
      }

      let target = Akari.GPU.HydraTarget(color: color,
                                         depth: depth,
                                         primId: primId,
                                         instanceId: instanceId,
                                         width: width,
                                         height: height)

      let ctx = Akari.GPU.FrameContext(gpu: gpu,
                                       labfx: labfx,
                                       camera: camera,
                                       unjitteredCamera: unjitteredCamera,
                                       target: target,
                                       settings: settings,
                                       frameIndex: frameIndex,
                                       cameraMoved: cameraMoved,
                                       isFinalRender: isFinalRender,
                                       selection: isFinalRender || !showsSelectionOutline ? nil : selection,
                                       renderParam: renderParam)

      var state = Akari.GPU.FrameState(target: target)
      for node in graph
      {
        node.execute(&state, ctx)
      }

      frameIndex &+= 1
      if !isFinalRender { viewportFrames += 1 }
    }

    private static func halton(_ index: UInt64, _ base: UInt64) -> Float
    {
      var result: Float = 0
      var fraction: Float = 1
      var i = index
      while i > 0
      {
        fraction /= Float(base)
        result += fraction * Float(i % base)
        i /= base
      }

      return result
    }

    /// Returns `true` when two camera matrices are identical within a small epsilon.
    private func matrixNear(_ a: [Float], _ b: [Float]) -> Bool
    {
      a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= 1e-6 }
    }

    /// Debug output that geometry sync is feeding the engine.
    private func logSceneStats(_ renderParam: Pixar.HdAkariRenderParam)
    {
      guard let scene = renderParam.GetScene() else { return }

      let rev = scene.Revision()
      guard rev != lastStatsRevision else { return }
      lastStatsRevision = rev

      let meshes = scene.MeshCount()
      let tris = scene.TriangleCount()
      print("[akari] scene: \(meshes) mesh(es), \(tris) triangle(s)")
    }

    /// Map the resolved pass order onto concrete graph nodes.
    private static func buildGraph(for settings: RenderSettings) -> [any Akari.GPU.RenderPassNode]
    {
      RenderPipeline(settings: settings).activePasses.compactMap(node(for:))
    }

    private static func node(for id: RenderPassID) -> (any Akari.GPU.RenderPassNode)?
    {
      switch id
      {
        case .depthPrepass: DepthPrepass()
        case .shadow: ShadowPass()
        case .lightProbes: LightProbePass()
        case .geometry: GeometryPass()
        case .lighting: LightingPass()
        case .screenSpaceGI: ScreenSpaceGIPass()
        case .reflections: ReflectionsPass()
        case .transparency: TransparencyPass()
        case .volumetrics: VolumetricsPass()
        case .temporalResolve: TemporalResolvePass()
        case .bloom: BloomPass()
        case .depthOfField: DepthOfFieldPass()
        case .tonemap: TonemapPass()
        case .present: PresentPass()
      }
    }
  }
}
