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
    private var captureBuffer: LabGLCaptureBuffer?
    /// The LabFX runtime driving the graph.
    private var runtime = lab.fx.Runtime()
    private var lastWidth = 0
    private var lastHeight = 0

    /// Cached scene revision, skips capture when geometry is unchanged.
    private var lastGeometryRevision: UInt64 = 0

    private let materialAtlas = Akari.MaterialAtlas()
    private let recorder = Akari.Geom.Recorder()

    /// This is `true` when the opened usd stage's upAxis is "Z".
    private var stageIsZUp = false

    /// Call once, right after opening the usd stage.
    public func setStageUpAxis(isZUp: Bool)
    {
      stageIsZUp = isZUp
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
        setIblPasses(active: true)
        iblNeedsBake = true
      }
    }

    private static let iblPassNames = [
      "sky",
      "prefilter",
      "irradiance",
      "dfg"
    ]

    init()
    {}

    deinit { teardown() }

    /// Starts a new frame through LabGL. Ensures the engine and the deferred
    /// graph exist, resizes to the target, and opens the frame.
    ///
    /// - Parameters:
    ///   - width: AOV width dimension in pixels.
    ///   - height: AOV height dimension in pixels.
    public func beginFrame(width: Int, height: Int)
    {
      guard width > 0, height > 0 else { return }
      ensureEngine(width: width, height: height)
      guard let windowHandle else { return }

      if width != lastWidth || height != lastHeight
      {
        labgl.resize(windowHandle, width: Int32(width), height: Int32(height))
        runtime.resize(rootWidth: Int32(width), rootHeight: Int32(height))
        // buffer rebuild wipes the baked IBL textures,
        // so rerun the IBL passes on the next frame to
        // rebake, then disable them again.
        iblNeedsBake = true
        lastWidth = width
        lastHeight = height
      }

      if iblNeedsBake { setIblPasses(active: true) }

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
      gl.loadMatrix(projection.m)
      gl.matrixMode(GL_MODELVIEW)
      gl.loadMatrix(view.m)

      runtime.setViewMatrix(view.m)

      // the shared roughness/metallic/opacity texture atlas.
      if let atlas = renderParam.GetTextureAtlas()
      {
        let (materialTex, colorTex) = materialAtlas.uploadIfNeeded(atlas)
        setSampler("u_material_atlas", materialTex)
        setSampler("u_color_atlas", colorTex)
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

        triangleEstimate += mesh.triangleIndices.size() / 3

        let mat = Pixar.GfMatrix4f(mesh.transform)
        guard let mPtr = mat.GetArray() else { continue }
        let worldMatrix = Array(UnsafeBufferPointer(start: mPtr, count: 16))
        let normalMatrix = Akari.normalMatrix3x3(mPtr)
        let flipWinding = Akari.determinant3x3(mPtr) < 0

        rawMeshes.append(Akari.Geom.Recorder.RawMesh(id: mesh.id.string, dataRevision: mesh.dataRevision,
                                                     flipWinding: flipWinding, points: mesh.points,
                                                     tris: mesh.triangleIndices, uvs: mesh.uvs,
                                                     worldMatrix: worldMatrix, normalMatrix: normalMatrix))
      }

      let items = recorder.record(rawMeshes)

      labgl.captureClear(captureBuffer)
      labgl.captureStart(captureBuffer)

      gl.enable(GL_DEPTH_TEST)
      gl.depthFunc(GL_LESS)

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
    }

    /// Sets the deferred lighting stage state: the split sum IBL toggle,
    /// the inverse projection, and the Hosek-Wilkie sky parameters.
    ///
    /// - Parameters:
    ///   - iblEnabled: gates the split sum IBL lobes.
    ///   - projection: 16 row-major floats, view->clip.
    ///   - sunHeight: height of the sun [-1, 1] for day/night.
    public func setLighting(iblEnabled: Bool, projection: Matrix4, sunHeight: Float)
    {
      setFloat("u_iblEnabled", iblEnabled ? 1 : 0)
      setMatrix("u_invProj", projection.inverse())

      setFloat("sunHeight", sunHeight)
      lastSunHeight = sunHeight // handles IBL rebaking, if changed.

      setFloat("u_zUp", stageIsZUp ? 1 : 0)
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
                           viewTransform: ViewTransform,
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
    ///   - color: opaque `HdAkariRenderBuffer` for the color AOV.
    ///   - hgi: opaque `Hgi` shared with Hydra.
    public func present(color: UnsafeMutableRawPointer?, hgi: UnsafeMutableRawPointer?)
    {
      guard let windowHandle else { return }

      runtime.render()

      // bake the IBL once.
      if iblNeedsBake
      {
        setIblPasses(active: false)
        iblNeedsBake = false
      }
      labgl.present(windowHandle)

      // export the tonemapped color buffer's native texture
      // and hand it to the color AOV through Hgi.
      guard let color, let hgi else { return }
      let finalTex = runtime.texture("tonemap", named: "tonemap")
      guard finalTex != 0 else { return }
      let native = lglGetTextureNativeHandle(finalTex)
      if native != 0
      {
        AkariRenderBufferSetExternalTexture(color, hgi, native)
      }
    }

    /// `runtime.setUniform` takes a pointer, so each of
    /// these binds an addressable value for the caller.
    private func setFloat(_ name: String, _ value: Float)
    {
      var value = value
      runtime.setUniform(name, type: GL_FLOAT, data: &value)
    }

    private func setInt(_ name: String, _ value: Int32)
    {
      var value = value
      runtime.setUniform(name, type: GL_INT, data: &value)
    }

    /// Skips texture names LabGL hasn't uploaded yet.
    private func setSampler(_ name: String, _ texture: GLuint)
    {
      guard texture != 0 else { return }
      var texture = texture
      runtime.setUniform(name, type: GL_SAMPLER_2D, data: &texture)
    }

    private func setMatrix(_ name: String, _ matrix: Matrix4)
    {
      matrix.m.withUnsafeBufferPointer
      { buf in
        runtime.setUniform(name, type: GL_FLOAT_MAT4, data: buf.baseAddress)
      }
    }

    private func ensureEngine(width: Int, height: Int)
    {
      guard windowHandle == nil else { return }

      // headless attach.
      guard let handle = labgl.attachOffscreen(width: Int32(width), height: Int32(height))
      else
      {
        print("[akari/labgl] labgl_attachOffscreen failed")
        return
      }
      windowHandle = handle

      // parse + build the deferred graph once.
      guard
        let url = Bundle.module.url(forResource: "DeferredGraph", withExtension: "labfx"),
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

    /// Toggles the IBL generation passes on/off.
    private func setIblPasses(active: Bool)
    {
      for name in Self.iblPassNames
      {
        runtime.setPassActive(name, active: active)
      }
    }
  }
}
