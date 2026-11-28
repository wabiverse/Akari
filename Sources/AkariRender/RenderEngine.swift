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
  /// the akari render engine, it owns the frame graph and runs it each frame for the render delegate and render pass
  final class RenderEngine
  {
    /// live settings, safe from any thread, the graph rebuilds at the start of the next frame
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

    /// what the viewport outlines, safe to set from any thread
    public var selection: Akari.Selection?
    {
      get { settingsLock.withLock { _selection } }
      set { settingsLock.withLock { _selection = newValue } }
    }

    /// the viewport's selection outline toggle, safe from any thread and never drawn into a final render
    /// how far a light probe bake has come, in probes
    public struct ProbeBake: Sendable, Equatable
    {
      public var done: Int
      public var total: Int

      public var fraction: Double
      {
        total > 0 ? Double(done) / Double(total) : 0
      }
    }

    /// the viewport's light probe bake while one runs, nil once the probes in view are ready
    public var probeBake: ProbeBake?
    {
      settingsLock.withLock { _probeBake }
    }

    /// the scene's prim id revision as of the last frame, prim id lookups start over when it moves
    public var primIdRevision: UInt64
    {
      settingsLock.withLock { _primIdRevision }
    }

    public var showsSelectionOutline: Bool
    {
      get { settingsLock.withLock { _showsSelectionOutline } }
      set { settingsLock.withLock { _showsSelectionOutline = newValue } }
    }

    /// the sample a final render is on, safe from any thread, frames then render final with no overlays and their own jitter
    public var finalRenderSample: Int?
    {
      get { settingsLock.withLock { _finalRenderSample } }
      set { settingsLock.withLock { _finalRenderSample = newValue } }
    }

    /// the size the viewport last drew at, read on the frame queue
    public private(set) var viewportSize = (width: 0, height: 0)

    private let settingsLock = NSLock()
    private var _settings: RenderSettings
    private var _finalRenderSample: Int?
    private var _selection: Akari.Selection?
    private var _showsSelectionOutline = true
    private var _primIdRevision: UInt64 = 0
    private var _probeBake: ProbeBake?
    private var settingsPendingRebuild = false
    private var pipeline: RenderPipeline
    private var graph: [any Akari.GPU.RenderPassNode]
    /// the features `graph` was built for, including any stage override of volumetrics
    private var graphFeatures: RenderFeatures
    private var gpu: Akari.GPU.HydraContext?
    public let labfx = Akari.LabFXEngine()
    private var frameIndex: UInt64 = 0
    /// viewport frames rendered so far
    public private(set) var viewportFrames = 0
    private var lastStatsRevision: UInt64 = 0
    private var lastCamera: (view: [Float], projection: [Float])?
    private let viewportCameraLock = NSLock()
    private var _viewportCamera: (view: simd_float4x4, projection: simd_float4x4)?

    /// the last viewport frame's world to view and view to clip matrices, safe to read from any thread
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

    /// the passes the latest settings run, in order
    public var activePasses: [RenderPassID]
    {
      RenderPipeline(settings: settings).activePasses
    }

    /// rebuilds the graph if the settings changed and returns the snapshot this frame runs with
    private func applyPendingSettings() -> RenderSettings
    {
      let (stored, pending) = settingsLock.withLock
      {
        defer { settingsPendingRebuild = false }
        return (_settings, settingsPendingRebuild)
      }

      var settings = stored

      // the stage's `/World/RenderSettings` can turn the fog on or off over the settings
      if let stage = labfx.usdVolume, stage.hasEnabled
      {
        if stage.enabled
        {
          settings.features.insert(.volumetrics)
        }
        else
        {
          settings.features.remove(.volumetrics)
        }
      }

      if pending || settings.features != graphFeatures
      {
        pipeline.settings = settings
        graph = RenderEngine.buildGraph(for: settings)
        graphFeatures = settings.features
      }

      return settings
    }

    /// per frame entry point called by the hydra render pass
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
      // the hydra frame queue never drains an autorelease pool, so one drains here before metal objects pile up
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
      if let scene = renderParam.GetScene()
      {
        let revision = scene.PrimIdRevision()
        settingsLock.withLock { _primIdRevision = revision }
      }

      var settings = applyPendingSettings()
      let finalSample = finalRenderSample
      let isFinalRender = isFinalRender || finalSample != nil

      // the viewport accumulates over the render sample count too, not only a final render
      settings.samples = max(settings.renderSamples, 1)
      if finalSample != nil { settings.features.remove(.dynamicResolution) }
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

      // taa skips accumulation while the camera moves to avoid ghosting
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
        // the jitter walks the whole sample sequence instead of wrapping early
        let index = finalSample.map { UInt64($0 % settings.samples) + 1 }
          ?? frameIndex % UInt64(max(settings.samples, 1)) + 1
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
      if !isFinalRender
      {
        viewportFrames += 1

        // six cube faces make a probe
        let probes = labfx.lightProbes
        let baking = settings.features.contains(.lightProbes) && probes.inView && probes.captureTotal > 0
          && (probes.captured < probes.captureTotal || !probes.isReady)
        let bake = baking ? ProbeBake(done: probes.captured / 6, total: probes.captureTotal / 6) : nil
        settingsLock.withLock { _probeBake = bake }
      }
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

    /// whether two camera matrices match within a small epsilon
    private func matrixNear(_ a: [Float], _ b: [Float]) -> Bool
    {
      a.count == b.count && zip(a, b).allSatisfy { abs($0 - $1) <= 1e-6 }
    }

    /// logs scene totals so it is clear geometry sync is feeding the engine
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

    /// maps the resolved pass order onto concrete graph nodes
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
