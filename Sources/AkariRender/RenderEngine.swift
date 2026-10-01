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
import OpenUSDKit

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

    private let settingsLock = NSLock()
    private var _settings: RenderSettings
    private var _selection: Akari.Selection?
    private var _showsSelectionOutline = true
    private var settingsPendingRebuild = false
    private var pipeline: RenderPipeline
    private var graph: [any Akari.GPU.RenderPassNode]
    private var gpu: Akari.GPU.HydraContext?
    public let labfx = Akari.LabFXEngine()
    private var frameIndex: UInt64 = 0
    private var lastStatsRevision: UInt64 = 0
    private var lastCamera: (view: [Float], projection: [Float])?

    public init(settings: RenderSettings = RenderSettings())
    {
      _settings = settings
      pipeline = RenderPipeline(settings: settings)
      graph = RenderEngine.buildGraph(for: settings)
    }

    /// The passes the latest settings run, in order.
    public var activePasses: [RenderPassID]
    {
      RenderPipeline(settings: settings).activePasses
    }

    /// Rebuilds the graph if the settings changed, returning the snapshot this frame runs with.
    private func applyPendingSettings() -> RenderSettings
    {
      let (settings, pending) = settingsLock.withLock
      {
        defer { settingsPendingRebuild = false }
        return (_settings, settingsPendingRebuild)
      }

      if pending
      {
        pipeline.settings = settings
        graph = RenderEngine.buildGraph(for: settings)
      }

      return settings
    }

    /// Per frame entry point. Called by the Hydra render pass.
    ///
    /// - Parameters:
    ///   - hgi: the `HgiMetal` shared with Hydra.
    ///   - color: the color AOV's render buffer, if bound.
    ///   - depth: the depth AOV's render buffer, if bound.
    ///   - primId: the primId AOV's render buffer, if bound.
    ///   - instanceId: the instanceId AOV's render buffer, if bound.
    ///   - view: 16 row-major floats, world->view.
    ///   - projection: 16 row-major floats, view->clip.
    ///   - width: target width dimension in pixels.
    ///   - height: target height dimension in pixels.
    ///   - isFinalRender: if rendering for output (still).
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
      let settings = applyPendingSettings()

      if gpu?.wraps(hgi) != true
      {
        gpu = Akari.GPU.HydraContext(hgi: hgi, backend: settings.backend)
      }

      guard
        let gpu,
        width > 0,
        height > 0
      else { return }

      logSceneStats(renderParam)

      // detect camera motion so the TAA resolve can skip accumulation
      // while the view changes to prevent ghosting.
      let cameraMoved = lastCamera.map
      {
        !matrixNear($0.view, view) || !matrixNear($0.projection, projection)
      } ?? true

      lastCamera = (view: view, projection: projection)

      let unjitteredCamera = Akari.Camera(view: Matrix4(view), projection: Matrix4(projection))
      var camera = unjitteredCamera
      if settings.features.contains(.temporalAA)
      {
        let index = frameIndex % UInt64(min(max(settings.samples, 1), 16)) + 1
        let jitter = SIMD2(Self.halton(index, 2), Self.halton(index, 3)) - 0.5
        camera.projection = Matrix4.translation(SIMD3(2 * jitter.x / Float(width),
                                                      2 * jitter.y / Float(height), 0)) * camera.projection
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
