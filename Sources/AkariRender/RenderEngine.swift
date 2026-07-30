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

public extension Akari
{
  /// The core Akari render engine. Owns the resolved frame graph and
  /// executes it each frame. Created once by the app, retained by the
  /// `HdAkariRenderDelegate`, and driven by `HdAkariRenderPass` every
  /// frame.
  final class RenderEngine
  {
    /// Live configuration, reassigning rebuilds the frame graph.
    public var settings: RenderSettings
    {
      didSet { rebuild() }
    }

    private var pipeline: RenderPipeline
    private var graph: [any RenderPassNode]
    private var gpu: GpuContext?
    private var frameIndex: UInt64 = 0
    private var lastLoggedMeshCount: Int = -2
    private var lastCamera: (view: [Float], projection: [Float])?

    public init(settings: RenderSettings = RenderSettings())
    {
      self.settings = settings
      pipeline = RenderPipeline(settings: settings)
      graph = RenderEngine.buildGraph(for: settings)
    }

    /// The passes that will run this frame, in order.
    public var activePasses: [RenderPassID]
    {
      pipeline.activePasses
    }

    private func rebuild()
    {
      pipeline.settings = settings
      graph = RenderEngine.buildGraph(for: settings)
    }

    /// Per frame entry point. Called by the Hydra render pass.
    ///
    /// - Parameters:
    ///   - hgi: opaque `Hgi` shared with Hydra.
    ///   - color: opaque `HgiTexture` for the color AOV (may be null).
    ///   - depth: opaque `HgiTexture` for the depth AOV (may be null).
    ///   - view: 16 row-major floats, world->view.
    ///   - projection: 16 row-major floats, view->clip.
    ///   - width: target width dimension in pixels.
    ///   - height: target height dimension in pixels.
    ///   - isFinalRender: if rendering for output (still).
    public func renderFrame(hgi: UnsafeMutableRawPointer?,
                            renderParam: UnsafeMutableRawPointer?,
                            color: UnsafeMutableRawPointer?,
                            depth: UnsafeMutableRawPointer?,
                            view: [Float],
                            projection: [Float],
                            width: Int,
                            height: Int,
                            isFinalRender: Bool = false)
    {
      if gpu == nil || gpu?.hgi != hgi
      {
        gpu = GpuContext(hgi: hgi, backend: settings.backend)
      }
      guard let gpu, width > 0, height > 0 else { return }

      logSceneStats(renderParam)

      // detect camera motion so the TAA resolve can skip accumulation
      // while the view changes to prevent ghosting.
      var cameraMoved = lastCamera == nil
      if let last = lastCamera
      {
        cameraMoved = cameraMoved || !matrixNear(last.view, view)
          || !matrixNear(last.projection, projection)
      }
      lastCamera = (view: view, projection: projection)

      let camera = Camera(view: Matrix4(view), projection: Matrix4(projection))
      let target = FrameTarget(color: color, depth: depth, width: width, height: height)
      let ctx = FrameContext(gpu: gpu,
                             camera: camera,
                             target: target,
                             settings: settings,
                             frameIndex: frameIndex,
                             cameraMoved: cameraMoved,
                             isFinalRender: isFinalRender,
                             renderParam: renderParam)

      var state = FrameState(target: target)
      for node in graph
      {
        node.execute(&state, ctx)
      }

      frameIndex &+= 1
    }

    /// Returns `true` when two camera matrices are identical within a small epsilon.
    private func matrixNear(_ a: [Float], _ b: [Float]) -> Bool
    {
      guard a.count == b.count else { return false }
      for i in 0 ..< a.count where abs(a[i] - b[i]) > 1e-6
      {
        return false
      }
      return true
    }

    /// Debug output that geometry sync is feeding the engine.
    private func logSceneStats(_ renderParam: UnsafeMutableRawPointer?)
    {
      let meshes = Int(AkariSceneMeshCount(renderParam))
      guard meshes != lastLoggedMeshCount else { return }
      lastLoggedMeshCount = meshes
      let tris = Int(AkariSceneTriangleCount(renderParam))
      print("[akari] scene: \(meshes) mesh(es), \(tris) triangle(s)")
    }

    /// Map the resolved pass order onto concrete graph nodes.
    private static func buildGraph(for settings: RenderSettings) -> [any RenderPassNode]
    {
      RenderPipeline(settings: settings).activePasses.compactMap(node(for:))
    }

    private static func node(for id: RenderPassID) -> (any RenderPassNode)?
    {
      switch id
      {
        case .depthPrepass: DepthPrepass()
        case .shadow: ShadowPass()
        case .geometry: GeometryPass()
        case .ambientOcclusion: AmbientOcclusionPass()
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
