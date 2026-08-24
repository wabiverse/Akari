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
  /// Renders the LabGL / LabFX graph and is driven off the main thread.
  final class LabFXEngine
  {
    public nonisolated(unsafe) static let shared = LabFXEngine()

    /// Opaque `labgl_WindowHandle`.
    private var windowHandle: OpaquePointer?
    /// Parsed `.labfx` tree.
    private var graph: UnsafeMutablePointer<lab.fx.labfx>?
    /// Opaque `LabGLCaptureBuffer` the scene geometry is recorded into.
    private var captureBuffer: OpaquePointer?
    /// The LabFX runtime driving the graph.
    private var runtime = lab.fx.Runtime()
    private var lastWidth = 0
    private var lastHeight = 0
    
    /// Cached scene revision, skips capture when geometry is unchanged.
    private var lastGeometryRevision: UInt64 = 0

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
    private static let kIblPassNames = [
      "sky cook",
      "prefilter 0",
      "prefilter 1",
      "prefilter 2",
      "prefilter 3",
      "prefilter 4",
      "prefilter 5",
      "irradiance gen",
      "dfg gen"
    ]

    private init()
    {}

    /// Inverse transpose of the 3x3 upper-left of a row-major 4x4,
    /// returned as a column-major 3x3 (9 floats). Used to bake per
    /// mesh model normals into world space during geometry recording.
    static func normalMatrix3x3(_ m: UnsafePointer<Float>) -> [Float]
    {
      // extract 3x3 into column-major.
      let a0 = m[0];  let a1 = m[4];  let a2 = m[8]   // column 0
      let a3 = m[1];  let a4 = m[5];  let a5 = m[9]   // column 1
      let a6 = m[2];  let a7 = m[6];  let a8 = m[10]  // column 2

      let det = Double(a0*(a4*a8-a5*a7) - a3*(a1*a8-a2*a7) + a6*(a1*a5-a2*a4))
      guard abs(det) > 1e-8 else { return [1,0,0, 0,1,0, 0,0,1] }
      let inv = 1.0 / det

      // inverse transpose, column-major layout.
      return [
        Float(inv * Double( a4*a8 - a5*a7)),
        Float(inv * Double( a6*a5 - a3*a8)),
        Float(inv * Double( a3*a7 - a6*a4)),
        Float(inv * Double( a2*a7 - a8*a1)),
        Float(inv * Double( a0*a8 - a2*a6)),
        Float(inv * Double( a6*a1 - a0*a7)),
        Float(inv * Double( a1*a5 - a4*a2)),
        Float(inv * Double( a3*a2 - a0*a5)),
        Float(inv * Double( a0*a4 - a1*a3))
      ]
    }

    /// Inverse of a row-major 4x4 (16 floats) via Gauss-Jordan.
    static func mat4Inverse(_ m: [Float]) -> [Float]
    {
      guard m.count == 16 else { return Array(repeating: 0, count: 16) }
      var a = m
      var inv: [Float] = [1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1]
      for col in 0 ..< 4
      {
        var pivot = col
        var best = abs(a[col * 4 + col])
        for r in (col + 1) ..< 4 where abs(a[r * 4 + col]) > best
        {
          best = abs(a[r * 4 + col]); pivot = r
        }
        if best < 1e-9 { return Array(repeating: 0, count: 16) }
        if pivot != col
        {
          for k in 0 ..< 4
          {
            a.swapAt(col * 4 + k, pivot * 4 + k)
            inv.swapAt(col * 4 + k, pivot * 4 + k)
          }
        }
        let d = a[col * 4 + col]
        for k in 0 ..< 4
        {
          a[col * 4 + k] /= d; inv[col * 4 + k] /= d
        }
        for r in 0 ..< 4 where r != col
        {
          let f = a[r * 4 + col]
          if f == 0 { continue }
          for k in 0 ..< 4
          {
            a[r * 4 + k] -= f * a[col * 4 + k]; inv[r * 4 + k] -= f * inv[col * 4 + k]
          }
        }
      }
      return inv
    }

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
      if ProcessInfo.processInfo.environment["AKARI_DUMP_IRRADIANCE"] != nil
      {
        print("[akari/ibl] beginFrame w=\(width) h=\(height) bake=\(iblNeedsBake)")
        fflush(stdout)
      }
      ensureEngine(width: width, height: height)
      guard let windowHandle else { return }

      if width != lastWidth || height != lastHeight
      {
        labgl_resize(windowHandle, Int32(width), Int32(height))
        runtime.resize(Int32(width), Int32(height))
        // buffer rebuild wipes the baked IBL textures,
        // so rerun the IBL passes on the next frame to
        // rebake, then disable them again.
        iblNeedsBake = true
        lastWidth = width
        lastHeight = height
      }

      if iblNeedsBake { setIblPasses(active: true) }

      labgl_beginFrame(windowHandle)
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

      LABGLDISPATCH_glMatrixMode(GLenum(GL_PROJECTION))
      LABGLDISPATCH_glLoadMatrixf(projection.m)
      LABGLDISPATCH_glMatrixMode(GLenum(GL_MODELVIEW))
      LABGLDISPATCH_glLoadMatrixf(view.m)

      runtime.setViewMatrix(view.m)

      // only capture when geometry has changed.
      let rev = scene.Revision()
      guard rev != lastGeometryRevision else { return }
      lastGeometryRevision = rev

      let meshes = scene.Snapshot()

      labgl_captureClear(captureBuffer)
      labgl_captureStart(captureBuffer)

      LABGLDISPATCH_glEnable(GLenum(GL_DEPTH_TEST))
      LABGLDISPATCH_glDepthFunc(GLenum(GL_LESS))

      var mergedVerts: [Float] = []
      var mergedIndices: [Int32] = []
      var verts: [Float] = []
      var indices: [Int32] = []

      for mesh in meshes
      {
        if mesh.points.empty() || mesh.triangleIndices.empty() { continue }

        verts.removeAll(keepingCapacity: true)
        indices.removeAll(keepingCapacity: true)
        Akari.Geom.buildMesh(points: mesh.points,
                             tris: mesh.triangleIndices,
                             verts: &verts, indices: &indices)
        if verts.isEmpty || indices.isEmpty { continue }

        let vertCount = verts.count / 6
        let baseVertex = Int32(mergedVerts.count / 14)

        guard let m = Pixar.GfMatrix4f(mesh.transform).GetArray() else { continue }
        let normMtx = Self.normalMatrix3x3(m)

        let r = mesh.displayColor[0]
        let g = mesh.displayColor[1]
        let b = mesh.displayColor[2]

        for v in 0 ..< vertCount
        {
          let s = v * 6
          let px = verts[s];   let py = verts[s+1]; let pz = verts[s+2]
          let nx = verts[s+3]; let ny = verts[s+4]; let nz = verts[s+5]

          // bake model transform into world-space position.
          let wx = m[0]*px + m[4]*py + m[8]*pz  + m[12]
          let wy = m[1]*px + m[5]*py + m[9]*pz  + m[13]
          let wz = m[2]*px + m[6]*py + m[10]*pz + m[14]

          // bake inverse transpose model into world-space normal.
          let rnx = normMtx[0]*nx + normMtx[3]*ny + normMtx[6]*nz
          let rny = normMtx[1]*nx + normMtx[4]*ny + normMtx[7]*nz
          let rnz = normMtx[2]*nx + normMtx[5]*ny + normMtx[8]*nz

          mergedVerts.append(contentsOf: [wx, wy, wz, 1.0,
                                          r,  g,  b,  1.0,
                                          0, 0,
                                          rnx, rny, rnz,
                                          0])
        }

        for idx in indices { mergedIndices.append(idx + baseVertex) }
      }

      if !mergedVerts.isEmpty && !mergedIndices.isEmpty
      {
        let vbSize = GLsizei(mergedVerts.count * MemoryLayout<Float>.size)
        let ibSize = GLsizei(mergedIndices.count * MemoryLayout<Int32>.size)
        let vb = LABGLDISPATCH_lglCreateBuffer(GLuint(LGL_BUFFER_VERTEX | LGL_BUFFER_MAP_WRITE), vbSize)
        let ib = LABGLDISPATCH_lglCreateBuffer(GLuint(LGL_BUFFER_INDEX | LGL_BUFFER_MAP_WRITE), ibSize)

        if let vPtr = LABGLDISPATCH_lglMapBuffer(vb)
        {
          memcpy(vPtr, mergedVerts, Int(vbSize))
          LABGLDISPATCH_lglUnmapBuffer(vb)
        }
        if let iPtr = LABGLDISPATCH_lglMapBuffer(ib)
        {
          memcpy(iPtr, mergedIndices, Int(ibSize))
          LABGLDISPATCH_lglUnmapBuffer(ib)
        }

        LABGLDISPATCH_glBindBuffer(GLenum(GL_ARRAY_BUFFER), vb)
        LABGLDISPATCH_glBindBuffer(GLenum(GL_ELEMENT_ARRAY_BUFFER), ib)
        LABGLDISPATCH_glEnableClientState(GLenum(GL_VERTEX_ARRAY))
        LABGLDISPATCH_glEnableClientState(GLenum(GL_COLOR_ARRAY))
        LABGLDISPATCH_glEnableClientState(GLenum(GL_TEXTURE_COORD_ARRAY))
        LABGLDISPATCH_glEnableClientState(GLenum(GL_NORMAL_ARRAY))
        LABGLDISPATCH_glVertexPointer(4, GLenum(GL_FLOAT), GLsizei(56),
                                      UnsafeRawPointer(bitPattern: 0))
        LABGLDISPATCH_glColorPointer(4, GLenum(GL_FLOAT), GLsizei(56),
                                     UnsafeRawPointer(bitPattern: 16))
        LABGLDISPATCH_glTexCoordPointer(2, GLenum(GL_FLOAT), GLsizei(56),
                                        UnsafeRawPointer(bitPattern: 32))
        LABGLDISPATCH_glNormalPointer(GLenum(GL_FLOAT), GLsizei(56),
                                      UnsafeRawPointer(bitPattern: 40))

        // single draw call for ALL geometry.
        LABGLDISPATCH_glDrawElements(GLenum(GL_TRIANGLES),
                                     Int32(mergedIndices.count),
                                     GLenum(GL_UNSIGNED_INT),
                                     UnsafeRawPointer(bitPattern: 0))

        LABGLDISPATCH_glDisableClientState(GLenum(GL_NORMAL_ARRAY))
        LABGLDISPATCH_glDisableClientState(GLenum(GL_TEXTURE_COORD_ARRAY))
        LABGLDISPATCH_glDisableClientState(GLenum(GL_COLOR_ARRAY))
        LABGLDISPATCH_glDisableClientState(GLenum(GL_VERTEX_ARRAY))
        LABGLDISPATCH_lglDeleteBuffer(vb)
        LABGLDISPATCH_lglDeleteBuffer(ib)
      }

      labgl_captureStop()
    }

    /// Sets the deferred lighting stage state: the split sum IBL toggle,
    /// the inverse projection, and the Hosek-Wilkie sky parameters.
    ///
    /// - Parameters:
    ///   - iblEnabled: gates the split sum IBL lobes.
    ///   - projection: 16 row-major floats, view->clip.
     ///  - sunHeight: height of the sun [-1, 1] for day/night.
    public func setLighting(iblEnabled: Bool, projection: Matrix4, sunHeight: Float)
    {
      var iblOn: Float = iblEnabled ? 1 : 0
      runtime.setUniform("u_iblEnabled", UInt32(GL_FLOAT), &iblOn)

      let invProj = Self.mat4Inverse(projection.m)
      invProj.withUnsafeBufferPointer
      { buf in
        runtime.setUniform("u_invProj", UInt32(GL_FLOAT_MAT4), buf.baseAddress)
      }

      var sunHeightV = sunHeight
      runtime.setUniform("sunHeight", GLenum(GL_FLOAT), &sunHeightV)
      lastSunHeight = sunHeight // handles IBL rebaking, if changed.
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
      var expV = exposure
      runtime.setUniform("exposure", GLenum(GL_FLOAT), &expV)

      var gammaV = gamma
      runtime.setUniform("gamma", GLenum(GL_FLOAT), &gammaV)

      var fIdx = Int32(frameIndex & 0xFFFF)
      runtime.setUniform("frameIndex", GLenum(GL_INT), &fIdx)

      if GLenum(viewTransform.uniform) != lastTonemap
      {
        lastTonemap = GLenum(viewTransform.uniform)
        
        runtime.setPassTonemap("tonemap", GLenum(viewTransform.uniform))
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
      labgl_present(windowHandle)

      // export the tonemapped color buffer's native texture
      // and hand it to the color AOV through Hgi.
      guard let color, let hgi else { return }
      let finalTex = runtime.bufferTexture("tonemap", "tonemap")
      guard finalTex != 0 else { return }
      let native = lglGetTextureNativeHandle(finalTex)
      if native != 0
      {
        AkariRenderBufferSetExternalTexture(color, hgi, native)
      }
    }

    private func ensureEngine(width: Int, height: Int)
    {
      guard windowHandle == nil else { return }

      // headless attach.
      guard let handle = labgl_attachOffscreen(Int32(width), Int32(height))
      else
      {
        print("[akari/labgl] labgl_attachOffscreen failed")
        return
      }
      windowHandle = handle

      // parse + build the deferred graph once.
      guard let parsed = lab.fx.parse_labfx(Self.kDeferredGraph, Self.kDeferredGraph.utf8.count)
      else
      {
        print("[akari/labgl] labfx parse failed")
        return
      }
      graph = parsed
      
      // set hosek wilkie sky compute buffer.
      let data = HosekWilkieSkyData.flattenedFloats()
      data.withUnsafeBufferPointer
      { buf in
        runtime.setComputeBuffer("hosekData",
                                 buf.baseAddress,
                                 buf.count * MemoryLayout<Float>.stride)
      }
      
      // set other shader buffer sizes.
      for level in 0 ..< 6
      {
        runtime.setBufferSize("pref\(level)", 128, 64)
      }
      runtime.setBufferSize("irradiance", 32, 16)
      runtime.setBufferSize("dfg", 128, 128)

      guard runtime.build(parsed, Int32(width), Int32(height))
      else
      {
        print("[akari/labgl] labfx runtime build failed")
        return
      }

      // capture buffer the geometry pass replays each frame.
      guard let cap = labgl_captureCreate()
      else
      {
        print("[akari/labgl] labgl_captureCreate failed")
        return
      }
      runtime.setMeshCapture("mesh", cap)
      captureBuffer = cap

      lastWidth = width
      lastHeight = height
    }

    private func teardown()
    {
      runtime.destroy()
      if let captureBuffer
      {
        labgl_captureDestroy(captureBuffer)
        self.captureBuffer = nil
      }
      if let graph
      {
        lab.fx.free_labfx(graph)
        self.graph = nil
      }
      if let windowHandle
      {
        labgl_destroyWindow(windowHandle)
        self.windowHandle = nil
      }
    }

    /// Toggles the IBL generation passes on/off.
    private func setIblPasses(active: Bool)
    {
      guard let graph else { return }
      for i in 0 ..< graph.pointee.passes.count
      {
        let name = graph.pointee.passes[i].name
        if Self.kIblPassNames.contains(String(name))
        {
          graph.pointee.passes[i].active = active
        }
      }
    }

    /// LabGL reads its own `.labfx` format.
    private static let kDeferredGraph = """
      --- labfx version 1.0

      name: Akari LabGL
      version: 1.0

      buffer: gbuffer
        has depth: yes
        textures:
          [ diffuse, f16x4, scale: 1.0
            position, f16x4, scale: 1.0
            normal, f16x4, scale: 1.0 ]

      buffer: envCube
        textures:
          has mips: yes
          has depth: no
          size: [256 256]
          cube: yes
          [ envCube, f16x4, scale: 1.0 ]

      buffer: pref0
        has depth: no
        textures:
          [ pref0, f16x4, scale: 0.25 ]

      buffer: pref1
        has depth: no
        textures:
          [ pref1, f16x4, scale: 0.25 ]

      buffer: pref2
        has depth: no
        textures:
          [ pref2, f16x4, scale: 0.25 ]

      buffer: pref3
        has depth: no
        textures:
          [ pref3, f16x4, scale: 0.25 ]

      buffer: pref4
        has depth: no
        textures:
          [ pref4, f16x4, scale: 0.25 ]

      buffer: pref5
        has depth: no
        textures:
          [ pref5, f16x4, scale: 0.25 ]

      buffer: irradiance
        has depth: no
        textures:
          [ irradiance, f16x4, scale: 0.125 ]

      buffer: dfg
        has depth: no
        textures:
          [ dfg, f16x4, scale: 0.25 ]

      buffer: color
        has depth: no
        textures:
          [ final, f16x4, scale: 1.0 ]

      buffer: tonemap
        has depth: no
        textures:
          [ tonemap, f16x4, scale: 1.0 ]

      pass: clear gbuffer
        draw: no
        clear depth: yes
        clear outputs: yes
        outputs: gbuffer [diffuse, position, normal]

      pass: sky cook
        draw: compute
        use shader: hosek-wilkie
        dispatch: [ 64, 64, 6 ]
        threadgroup: [ 16, 16, 1 ]
        inputs: [hosekData.data]
        outputs: envCube [ envCube ]

      pass: prefilter 0
        draw: quad
        depth test: never
        write depth: no
        use shader: prefilter-lvl0
        inputs: [envCube.envCube]
        outputs: pref0 [ pref0 ]

      pass: prefilter 1
        draw: quad
        depth test: never
        write depth: no
        use shader: prefilter-lvl1
        inputs: [envCube.envCube]
        outputs: pref1 [ pref1 ]

      pass: prefilter 2
        draw: quad
        depth test: never
        write depth: no
        use shader: prefilter-lvl2
        inputs: [envCube.envCube]
        outputs: pref2 [ pref2 ]

      pass: prefilter 3
        draw: quad
        depth test: never
        write depth: no
        use shader: prefilter-lvl3
        inputs: [envCube.envCube]
        outputs: pref3 [ pref3 ]

      pass: prefilter 4
        draw: quad
        depth test: never
        write depth: no
        use shader: prefilter-lvl4
        inputs: [envCube.envCube]
        outputs: pref4 [ pref4 ]

      pass: prefilter 5
        draw: quad
        depth test: never
        write depth: no
        use shader: prefilter-lvl5
        inputs: [envCube.envCube]
        outputs: pref5 [ pref5 ]

      pass: irradiance gen
        draw: quad
        depth test: never
        write depth: no
        use shader: irradiance-gen
        inputs: [envCube.envCube]
        outputs: irradiance [ irradiance ]

      pass: dfg gen
        draw: quad
        depth test: never
        write depth: no
        use shader: dfg-gen
        outputs: dfg [ dfg ]

      pass: geometry
        draw: opaque geometry
        clear depth: no
        depth test: less
        write depth: yes
        use shader: mesh
        outputs: gbuffer [diffuse, position, normal]

      pass: resolve
        draw: quad
        depth test: never
        write depth: no
        use shader: deferred-shade
        inputs: [gbuffer.diffuse, gbuffer.position, gbuffer.normal,
                 envCube.envCube, pref0.pref0, pref1.pref1,
                 pref2.pref2, pref3.pref3, pref4.pref4,
                 pref5.pref5, irradiance.irradiance, dfg.dfg]
        outputs: color [ final ]

      pass: tonemap
        draw: quad
        depth test: never
        write depth: no
        use shader: agx
        inputs: [color.final]
        outputs: tonemap [ tonemap ]

      pass: blit
        draw: blit
        inputs: [tonemap.tonemap]
        outputs: visible

      shader: mesh
        uniforms: []
        varying:  [ color: vec4, posEye: vec3, normalEye: vec3 ]

        vsh:
          attributes:
          [ a_position: vec3 <- position,
            a_color: vec4 <- color,
            a_normal: vec3 <- normal ]

          source:
          ```glsl
          void main()
          {
            var.color = a_color;
            vec4 ep = u_modelview * vec4(a_position, 1.0);
            var.posEye = ep.xyz;
            var.normalEye = normalize(u_normalMatrix * a_normal);
            gl_Position = u_modelviewProjection * vec4(a_position, 1.0);
          }
          ```

          source msl:
          ```msl
          var.color = a_color;
          float4 ep = u_modelview * float4(a_position, 1.0);
          var.posEye = ep.xyz;
          var.normalEye = normalize(u_normalMatrix * a_normal);
          gl_Position = u_modelviewProjection * float4(a_position, 1.0);
          ```

        fsh:
          source:
          ```glsl
          void main()
          {
            o_diffuse_texture = var.color;
            o_position_texture = vec4(var.posEye, 1.0);
            o_normal_texture = vec4(var.normalEye, 1.0);
          }
          ```

          source msl:
          ```msl
          o_diffuse_texture = var.color;
          o_position_texture = float4(var.posEye, 1.0);
          o_normal_texture = float4(var.normalEye, 1.0);
          ```

      shader: hosek-wilkie
        uniforms: [ sunHeight: float ]
        csh:
          source:
          ```glsl
          layout(std430, binding=0) readonly buffer HosekData {
            float values[3600];
          } hosekData;

          const float PI = 3.14159265358979323846;
          const float SKY_SCALE = 0.02;

          vec3 cubeFaceDir(vec2 uv, int face)
          {
            float u = uv.x * 2.0 - 1.0;
            float v = uv.y * 2.0 - 1.0;
            if (face == 0) return normalize(vec3( 1.0, -v, -u));
            if (face == 1) return normalize(vec3(-1.0, -v,  u));
            if (face == 2) return normalize(vec3( u,  1.0, -v));
            if (face == 3) return normalize(vec3( u, -1.0,  v));
            if (face == 4) return normalize(vec3( u, -v,  1.0));
            return normalize(vec3(-u, -v, -1.0));
          }

          float hosekWilkieSkyRadiance(mat3 config, float cosTheta, float gamma)
          {
            cosTheta = max(cosTheta, 0.0);
            float expM = exp(config[1][1] * gamma);
            float rayM = cos(gamma) * cos(gamma);
            float mieM = (1.0 + rayM) / pow(1.0 + config[2][2] * config[2][2]
                         - 2.0 * config[2][2] * cos(gamma), 1.5);
            float zenith = sqrt(cosTheta);
            return (1.0 + config[0][0] * exp(config[0][1] / (cosTheta + 0.01)))
                 * (config[0][2] + config[1][0] * expM
                    + config[1][2] * rayM + config[2][0] * mieM
                    + config[2][1] * zenith);
          }

          void main()
          {
            ivec3 gid = ivec3(gl_GlobalInvocationID);
            ivec2 texel = gid.xy;
            int face = gid.z;
            ivec2 size = imageSize(out_envCube);
            if (texel.x >= size.x || texel.y >= size.y || face >= 6) return;

            float u = (float(texel.x) + 0.5) / float(size.x);
            float v = (float(texel.y) + 0.5) / float(size.y);
            vec3 dir = cubeFaceDir(vec2(u, v), face);

            // Map sunHeight [0=horizon, 1=zenith] to a proper elevation angle.
            // At 0 the sun sits on the horizon, at 1 it is directly overhead.
            float sunElevAngle = clamp(sunHeight, 0.0, 1.0) * 75.0 * PI / 180.0;
            vec3 sunDir = normalize(vec3(0.4 * cos(sunElevAngle),
                                         sin(sunElevAngle),
                                         -0.5 * cos(sunElevAngle)));

            // --- HORIZON SMOOTHING PREPARATION ---
            float skyCosTheta = max(dir.y, 0.001);
            vec3 horizonDir = normalize(vec3(dir.x, 0.0, dir.z));
            float horizonCosTheta = 0.0;

            float cospsiSky = dot(dir, sunDir);
            float gammaSky = acos(clamp(cospsiSky, -1.0, 1.0));

            float cospsiHorizon = dot(horizonDir, sunDir);
            float gammaHorizon = acos(clamp(cospsiHorizon, -1.0, 1.0));
            // -------------------------------------

            // Hosek-Wilkie cooking
            float se = pow(clamp(sunHeight, 0.0, 1.0), 1.0 / 3.0);
            float remE = 1.0 - se;
            float e0 = remE*remE*remE*remE*remE;
            float e1 = 5.0*remE*remE*remE*remE*se;
            float e2 = 10.0*remE*remE*remE*se*se;
            float e3 = 10.0*remE*remE*se*se*se;
            float e4 = 5.0*remE*se*se*se*se;
            float e5 = se*se*se*se*se;

            float r = 0.0, g = 0.0, b = 0.0;
            float r_hor = 0.0, g_hor = 0.0, b_hor = 0.0;

            for (int ch = 0; ch < 3; ch++) {
              int chOff = ch * 1080;
              int radOff = 3240 + ch * 120;
              vec3 c0 = vec3(0.0), c1 = vec3(0.0), c2 = vec3(0.0);

              for (int i = 0; i < 3; i++) {
                int b = chOff + 54 + i;
                float lo = e0*hosekData.values[b] + e1*hosekData.values[b+9]
                         + e2*hosekData.values[b+18] + e3*hosekData.values[b+27]
                         + e4*hosekData.values[b+36] + e5*hosekData.values[b+45];
                int b2 = chOff + 108 + i;
                float hi = e0*hosekData.values[b2] + e1*hosekData.values[b2+9]
                         + e2*hosekData.values[b2+18] + e3*hosekData.values[b2+27]
                         + e4*hosekData.values[b2+36] + e5*hosekData.values[b2+45];
                c0[i] = 0.8 * lo + 0.2 * hi;
              }
              for (int i = 0; i < 3; i++) {
                int b = chOff + 54 + (i+3);
                float lo = e0*hosekData.values[b] + e1*hosekData.values[b+9]
                         + e2*hosekData.values[b+18] + e3*hosekData.values[b+27]
                         + e4*hosekData.values[b+36] + e5*hosekData.values[b+45];
                int b2 = chOff + 108 + (i+3);
                float hi = e0*hosekData.values[b2] + e1*hosekData.values[b2+9]
                         + e2*hosekData.values[b2+18] + e3*hosekData.values[b2+27]
                         + e4*hosekData.values[b2+36] + e5*hosekData.values[b2+45];
                c1[i] = 0.8 * lo + 0.2 * hi;
              }
              for (int i = 0; i < 3; i++) {
                int b = chOff + 54 + (i+6);
                float lo = e0*hosekData.values[b] + e1*hosekData.values[b+9]
                         + e2*hosekData.values[b+18] + e3*hosekData.values[b+27]
                         + e4*hosekData.values[b+36] + e5*hosekData.values[b+45];
                int b2 = chOff + 108 + (i+6);
                float hi = e0*hosekData.values[b2] + e1*hosekData.values[b2+9]
                         + e2*hosekData.values[b2+18] + e3*hosekData.values[b2+27]
                         + e4*hosekData.values[b2+36] + e5*hosekData.values[b2+45];
                c2[i] = 0.8 * lo + 0.2 * hi;
              }

              mat3 cfg = mat3(c0, c1, c2);

              int rb = radOff + 6;
              float radLo = e0*hosekData.values[rb] + e1*hosekData.values[rb+1]
                          + e2*hosekData.values[rb+2] + e3*hosekData.values[rb+3]
                          + e4*hosekData.values[rb+4] + e5*hosekData.values[rb+5];
              rb = radOff + 12;
              float radHi = e0*hosekData.values[rb] + e1*hosekData.values[rb+1]
                          + e2*hosekData.values[rb+2] + e3*hosekData.values[rb+3]
                          + e4*hosekData.values[rb+4] + e5*hosekData.values[rb+5];
              float rad = 0.8 * radLo + 0.2 * radHi;

              float sky = hosekWilkieSkyRadiance(cfg, skyCosTheta, gammaSky) * rad;

              if (ch == 0) r = sky;
              else if (ch == 1) g = sky;
              else b = sky;

              float hor = hosekWilkieSkyRadiance(cfg, horizonCosTheta, gammaHorizon) * rad;
              if (ch == 0) r_hor = hor;
              else if (ch == 1) g_hor = hor;
              else b_hor = hor;
            }

            // --- GAUSSIAN BLEND EXECUTION ---
            vec3 skyColor = vec3(r, g, b);
            vec3 horizonColor = vec3(r_hor, g_hor, b_hor);
            float sigma = 0.12;
            float gaussianFactor = exp(-(dir.y * dir.y) / (2.0 * sigma * sigma));
            vec3 blendedColor = mix(skyColor, horizonColor, gaussianFactor * 0.5);
            // ---------------------------------

            // Night fade: smoothly darken below horizon.
            float nightFade = smoothstep(-0.3, 0.05, sunHeight);

            imageStore(out_envCube, ivec3(texel, face),
                       vec4(max(blendedColor * SKY_SCALE * nightFade, vec3(0.0)), 1.0));
          }
          ```

          source msl:
          ```msl
          constexpr constant float PI = 3.14159265358979323846;
          constexpr constant float SKY_SCALE = 0.02;

          float3 cubeFaceDir(float2 uv, int face)
          {
            float u = uv.x * 2.0 - 1.0;
            float v = uv.y * 2.0 - 1.0;
            if (face == 0) return normalize(float3( 1.0, -v, -u));
            if (face == 1) return normalize(float3(-1.0, -v,  u));
            if (face == 2) return normalize(float3( u,  1.0,  v));
            if (face == 3) return normalize(float3( u, -1.0, -v));
            if (face == 4) return normalize(float3( u, -v,  1.0));
            return normalize(float3(-u, -v, -1.0));
          }

          float hosekWilkieSkyRadiance(float3x3 config, float cosTheta, float gamma)
          {
            cosTheta = max(cosTheta, 0.0);
            float expM = exp(config[1][1] * gamma);
            float rayM = cos(gamma) * cos(gamma);
            float mieM = (1.0 + rayM) / pow(1.0 + config[2][2] * config[2][2]
                         - 2.0 * config[2][2] * cos(gamma), 1.5);
            float zenith = sqrt(cosTheta);
            return (1.0 + config[0][0] * exp(config[0][1] / (cosTheta + 0.01)))
                 * (config[0][2] + config[1][0] * expM
                    + config[1][2] * rayM + config[2][0] * mieM
                    + config[2][1] * zenith);
          }

          //@main
          {
            uint2 texel = gid.xy;
            uint face = gid.z;
            uint2 size = uint2(out_envCube.get_width(), out_envCube.get_height());
            if (texel.x >= size.x || texel.y >= size.y || face >= 6) return;

            float u = (float(texel.x) + 0.5) / float(size.x);
            float v = (float(texel.y) + 0.5) / float(size.y);
            float3 dir = cubeFaceDir(float2(u, v), int(face));

            float sunElevAngle = clamp(sunHeight, 0.0, 1.0) * 75.0 * PI / 180.0;
            float3 sunDir = normalize(float3(0.4 * cos(sunElevAngle),
                                             sin(sunElevAngle),
                                             -0.5 * cos(sunElevAngle)));

            // --- HORIZON SMOOTHING PREPARATION ---
            float skyCosTheta = max(dir.y, 0.001);
            float3 horizonDir = normalize(float3(dir.x, 0.0, dir.z));
            float horizonCosTheta = 0.0;

            float cospsiSky = dot(dir, sunDir);
            float gammaSky = acos(clamp(cospsiSky, -1.0, 1.0));

            float cospsiHorizon = dot(horizonDir, sunDir);
            float gammaHorizon = acos(clamp(cospsiHorizon, -1.0, 1.0));
            // -------------------------------------

            float se = pow(clamp(sunHeight, 0.0, 1.0), 1.0 / 3.0);
            float remE = 1.0 - se;
            float e0 = remE*remE*remE*remE*remE;
            float e1 = 5.0*remE*remE*remE*remE*se;
            float e2 = 10.0*remE*remE*remE*se*se;
            float e3 = 10.0*remE*remE*se*se*se;
            float e4 = 5.0*remE*se*se*se*se;
            float e5 = se*se*se*se*se;

            float r = 0.0, g = 0.0, b = 0.0;
            float r_hor = 0.0, g_hor = 0.0, b_hor = 0.0;

            for (int ch = 0; ch < 3; ch++) {
              int chOff = ch * 1080;
              int radOff = 3240 + ch * 120;
              float3 c0 = float3(0.0), c1 = float3(0.0), c2 = float3(0.0);

              for (int i = 0; i < 3; i++) {
                int b = chOff + 54 + i;
                float lo = e0*data[b] + e1*data[b+9] + e2*data[b+18]
                         + e3*data[b+27] + e4*data[b+36] + e5*data[b+45];
                int b2 = chOff + 108 + i;
                float hi = e0*data[b2] + e1*data[b2+9] + e2*data[b2+18]
                         + e3*data[b2+27] + e4*data[b2+36] + e5*data[b2+45];
                c0[i] = 0.8 * lo + 0.2 * hi;
              }
              for (int i = 0; i < 3; i++) {
                int b = chOff + 54 + (i+3);
                float lo = e0*data[b] + e1*data[b+9] + e2*data[b+18]
                         + e3*data[b+27] + e4*data[b+36] + e5*data[b+45];
                int b2 = chOff + 108 + (i+3);
                float hi = e0*data[b2] + e1*data[b2+9] + e2*data[b2+18]
                         + e3*data[b2+27] + e4*data[b2+36] + e5*data[b2+45];
                c1[i] = 0.8 * lo + 0.2 * hi;
              }
              for (int i = 0; i < 3; i++) {
                int b = chOff + 54 + (i+6);
                float lo = e0*data[b] + e1*data[b+9] + e2*data[b+18]
                         + e3*data[b+27] + e4*data[b+36] + e5*data[b+45];
                int b2 = chOff + 108 + (i+6);
                float hi = e0*data[b2] + e1*data[b2+9] + e2*data[b2+18]
                         + e3*data[b2+27] + e4*data[b2+36] + e5*data[b2+45];
                c2[i] = 0.8 * lo + 0.2 * hi;
              }

              float3x3 cfg = float3x3(c0, c1, c2);

              int rb = radOff + 6;
              float radLo = e0*data[rb] + e1*data[rb+1] + e2*data[rb+2]
                          + e3*data[rb+3] + e4*data[rb+4] + e5*data[rb+5];
              rb = radOff + 12;
              float radHi = e0*data[rb] + e1*data[rb+1] + e2*data[rb+2]
                          + e3*data[rb+3] + e4*data[rb+4] + e5*data[rb+5];
              float rad = 0.8 * radLo + 0.2 * radHi;

              float sky = hosekWilkieSkyRadiance(cfg, skyCosTheta, gammaSky) * rad;

              if (ch == 0) r = sky;
              else if (ch == 1) g = sky;
              else b = sky;

              float hor = hosekWilkieSkyRadiance(cfg, horizonCosTheta, gammaHorizon) * rad;
              if (ch == 0) r_hor = hor;
              else if (ch == 1) g_hor = hor;
              else b_hor = hor;
            }

            // --- GAUSSIAN BLEND EXECUTION ---
            float3 skyColor = float3(r, g, b);
            float3 horizonColor = float3(r_hor, g_hor, b_hor);
            float sigma = 0.12;
            float gaussianFactor = exp(-(dir.y * dir.y) / (2.0 * sigma * sigma));
            float3 blendedColor = mix(skyColor, horizonColor, gaussianFactor * 0.5);
            // ---------------------------------

            float nightFade = smoothstep(-0.3, 0.05, sunHeight);

            out_envCube.write(half4(half3(max(blendedColor * SKY_SCALE * nightFade, float3(0.0))), 1.0h),
                              ushort2(texel), ushort(face));
          }
          ```

      shader: prefilter-lvl0
        uniforms: [ u_envCube_texture: samplerCube ]
        varying:  [ texCoord: vec2 ]

        vsh:
          attributes:
          [ a_position: vec3 <- position,
            a_uv: vec2 <- texcoord ]

          source:
          ```glsl
          void main()
          {
            var.texCoord = a_uv;
            gl_Position = vec4(a_position, 1.0);
          }
          ```

          source msl:
          ```msl
          var.texCoord = a_uv;
          gl_Position = float4(a_position, 1.0);
          ```

        fsh:
          source:
          ```glsl
          const float PI = 3.1415926536;
          const float kRoughness = 0.0;

          float AkariRadicalInverse(uint a)
          {
            return float(bitfieldReverse(a)) * 2.3283064365386963e-10;
          }

          vec2 AkariHammersley2d(uint a, uint N)
          {
            return vec2(float(a) / float(N), AkariRadicalInverse(a));
          }

          vec3 AkariImportanceSampleGGX(vec2 Xi, float roughness, vec3 normal)
          {
            float alpha = roughness * roughness;
            float phi = 2.0 * PI * Xi.x;
            float cosTheta = min(
                1.0, sqrt((1.0 - Xi.y) / (1.0 + (alpha * alpha - 1.0) * Xi.y)));
            float sinTheta = sqrt(1.0 - cosTheta * cosTheta);
            vec3 H = vec3(sinTheta * cos(phi), sinTheta * sin(phi), cosTheta);
            vec3 up = abs(normal.z) < 0.999 ? vec3(0.0, 0.0, 1.0)
                                            : vec3(1.0, 0.0, 0.0);
            vec3 tangentX = normalize(cross(up, normal));
            vec3 tangentY = normalize(cross(normal, tangentX));
            return normalize(tangentX * H.x + tangentY * H.y + normal * H.z);
          }

          vec2 dirToUV(vec3 dir)
          {
            float horiz2 = dir.x * dir.x + dir.z * dir.z;
            float u = (horiz2 > 1e-12)
                ? atan(dir.x, dir.z) * (0.5 / PI) + 0.5
                : 0.5;
            float v = acos(clamp(dir.y, -1.0, 1.0)) / PI;
            return vec2(u, v);
          }

          void main()
          {
            vec2 uv = var.texCoord;
            float theta = uv.y * PI;
            float phi = (uv.x - 0.5) * 2.0 * PI;
            vec3 R = vec3(sin(theta) * sin(phi), cos(theta), sin(theta) * cos(phi));

            vec3 color = vec3(0.0);
            float totalWeight = 0.0;
            const uint numSamples = 1024u;
            for (uint i = 0u; i < numSamples; i++) {
              vec2 Xi = AkariHammersley2d(i, numSamples);
              vec3 H = AkariImportanceSampleGGX(Xi, kRoughness, R);
              vec3 L = 2.0 * dot(R, H) * H - R;
              float dotNL = clamp(dot(R, L), 0.0, 1.0);
              if (dotNL > 0.0) {
                vec3 value = texture(u_envCube_texture, L).rgb;
                color += value * dotNL;
                totalWeight += dotNL;
              }
            }
            o_pref0_texture = vec4(color / max(totalWeight, 1e-4), 1.0);
          }
          ```

          source msl:
          ```msl
          constexpr constant float PI = 3.1415926536;
          constexpr constant float kRoughness = 0.0;

          float AkariRadicalInverse(uint a)
          {
            return float(reverse_bits(a)) * 2.3283064365386963e-10;
          }

          float2 AkariHammersley2d(uint a, uint N)
          {
            return float2(float(a) / float(N), AkariRadicalInverse(a));
          }

          float3 AkariImportanceSampleGGX(float2 Xi, float roughness, float3 normal)
          {
            float alpha = roughness * roughness;
            float phi = 2.0 * PI * Xi.x;
            float cosTheta = min(1.0, sqrt((1.0 - Xi.y) / (1.0 + (alpha * alpha - 1.0) * Xi.y)));
            float sinTheta = sqrt(1.0 - cosTheta * cosTheta);
            float3 H = float3(sinTheta * cos(phi), sinTheta * sin(phi), cosTheta);
            float3 up = abs(normal.z) < 0.999 ? float3(0.0, 0.0, 1.0)
                                              : float3(1.0, 0.0, 0.0);
            float3 tangentX = normalize(cross(up, normal));
            float3 tangentY = normalize(cross(normal, tangentX));
            return normalize(tangentX * H.x + tangentY * H.y + normal * H.z);
          }

          float2 dirToUV(float3 dir)
          {
            float horiz2 = dir.x * dir.x + dir.z * dir.z;
            float u = (horiz2 > 1e-12)
                ? atan2(dir.x, dir.z) * (0.5 / PI) + 0.5
                : 0.5;
            float v = acos(clamp(dir.y, -1.0, 1.0)) / PI;
            return float2(u, v);
          }

          //@main
          {
            float2 uv = var.texCoord;
            float theta = uv.y * PI;
            float phi = (uv.x - 0.5) * 2.0 * PI;
            float3 R = float3(sin(theta) * sin(phi), cos(theta), sin(theta) * cos(phi));

            float3 color = float3(0.0);
            float totalWeight = 0.0;
            const uint numSamples = 1024u;
            for (uint i = 0u; i < numSamples; i++) {
              float2 Xi = AkariHammersley2d(i, numSamples);
              float3 H = AkariImportanceSampleGGX(Xi, kRoughness, R);
              float3 L = 2.0 * dot(R, H) * H - R;
              float dotNL = clamp(dot(R, L), 0.0, 1.0);
              if (dotNL > 0.0) {
                float3 value = texture(u_envCube_texture, L).rgb;
                color += value * dotNL;
                totalWeight += dotNL;
              }
            }
            o_pref0_texture = float4(color / max(totalWeight, 1e-4), 1.0);
          }
          ```

      shader: prefilter-lvl1
        uniforms: [ u_envCube_texture: samplerCube ]
        varying:  [ texCoord: vec2 ]

        vsh:
          attributes:
          [ a_position: vec3 <- position,
            a_uv: vec2 <- texcoord ]

          source:
          ```glsl
          void main()
          {
            var.texCoord = a_uv;
            gl_Position = vec4(a_position, 1.0);
          }
          ```

          source msl:
          ```msl
          var.texCoord = a_uv;
          gl_Position = float4(a_position, 1.0);
          ```

        fsh:
          source:
          ```glsl
          const float PI = 3.1415926536;
          const float kRoughness = 0.2;

          float AkariRadicalInverse(uint a)
          {
            return float(bitfieldReverse(a)) * 2.3283064365386963e-10;
          }

          vec2 AkariHammersley2d(uint a, uint N)
          {
            return vec2(float(a) / float(N), AkariRadicalInverse(a));
          }

          vec3 AkariImportanceSampleGGX(vec2 Xi, float roughness, vec3 normal)
          {
            float alpha = roughness * roughness;
            float phi = 2.0 * PI * Xi.x;
            float cosTheta = min(
                1.0, sqrt((1.0 - Xi.y) / (1.0 + (alpha * alpha - 1.0) * Xi.y)));
            float sinTheta = sqrt(1.0 - cosTheta * cosTheta);
            vec3 H = vec3(sinTheta * cos(phi), sinTheta * sin(phi), cosTheta);
            vec3 up = abs(normal.z) < 0.999 ? vec3(0.0, 0.0, 1.0)
                                            : vec3(1.0, 0.0, 0.0);
            vec3 tangentX = normalize(cross(up, normal));
            vec3 tangentY = normalize(cross(normal, tangentX));
            return normalize(tangentX * H.x + tangentY * H.y + normal * H.z);
          }

          vec2 dirToUV(vec3 dir)
          {
            float horiz2 = dir.x * dir.x + dir.z * dir.z;
            float u = (horiz2 > 1e-12)
                ? atan(dir.x, dir.z) * (0.5 / PI) + 0.5
                : 0.5;
            float v = acos(clamp(dir.y, -1.0, 1.0)) / PI;
            return vec2(u, v);
          }

          void main()
          {
            vec2 uv = var.texCoord;
            float theta = uv.y * PI;
            float phi = (uv.x - 0.5) * 2.0 * PI;
            vec3 R = vec3(sin(theta) * sin(phi), cos(theta), sin(theta) * cos(phi));

            vec3 color = vec3(0.0);
            float totalWeight = 0.0;
            const uint numSamples = 1024u;
            for (uint i = 0u; i < numSamples; i++) {
              vec2 Xi = AkariHammersley2d(i, numSamples);
              vec3 H = AkariImportanceSampleGGX(Xi, kRoughness, R);
              vec3 L = 2.0 * dot(R, H) * H - R;
              float dotNL = clamp(dot(R, L), 0.0, 1.0);
              if (dotNL > 0.0) {
                vec3 value = texture(u_envCube_texture, L).rgb;
                color += value * dotNL;
                totalWeight += dotNL;
              }
            }
            o_pref1_texture = vec4(color / max(totalWeight, 1e-4), 1.0);
          }
          ```

          source msl:
          ```msl
          constexpr constant float PI = 3.1415926536;
          constexpr constant float kRoughness = 0.2;

          float AkariRadicalInverse(uint a)
          {
            return float(reverse_bits(a)) * 2.3283064365386963e-10;
          }

          float2 AkariHammersley2d(uint a, uint N)
          {
            return float2(float(a) / float(N), AkariRadicalInverse(a));
          }

          float3 AkariImportanceSampleGGX(float2 Xi, float roughness, float3 normal)
          {
            float alpha = roughness * roughness;
            float phi = 2.0 * PI * Xi.x;
            float cosTheta = min(
                1.0, sqrt((1.0 - Xi.y) / (1.0 + (alpha * alpha - 1.0) * Xi.y)));
            float sinTheta = sqrt(1.0 - cosTheta * cosTheta);
            float3 H = float3(sinTheta * cos(phi), sinTheta * sin(phi), cosTheta);
            float3 up = abs(normal.z) < 0.999 ? float3(0.0, 0.0, 1.0)
                                              : float3(1.0, 0.0, 0.0);
            float3 tangentX = normalize(cross(up, normal));
            float3 tangentY = normalize(cross(normal, tangentX));
            return normalize(tangentX * H.x + tangentY * H.y + normal * H.z);
          }

          float2 dirToUV(float3 dir)
          {
            float horiz2 = dir.x * dir.x + dir.z * dir.z;
            float u = (horiz2 > 1e-12)
                ? atan2(dir.x, dir.z) * (0.5 / PI) + 0.5
                : 0.5;
            float v = acos(clamp(dir.y, -1.0, 1.0)) / PI;
            return float2(u, v);
          }

          //@main
          {
            float2 uv = var.texCoord;
            float theta = uv.y * PI;
            float phi = (uv.x - 0.5) * 2.0 * PI;
            float3 R = float3(sin(theta) * sin(phi), cos(theta), sin(theta) * cos(phi));

            float3 color = float3(0.0);
            float totalWeight = 0.0;
            const uint numSamples = 1024u;
            for (uint i = 0u; i < numSamples; i++) {
              float2 Xi = AkariHammersley2d(i, numSamples);
              float3 H = AkariImportanceSampleGGX(Xi, kRoughness, R);
              float3 L = 2.0 * dot(R, H) * H - R;
              float dotNL = clamp(dot(R, L), 0.0, 1.0);
              if (dotNL > 0.0) {
                float3 value = texture(u_envCube_texture, L).rgb;
                color += value * dotNL;
                totalWeight += dotNL;
              }
            }
            o_pref1_texture = float4(color / max(totalWeight, 1e-4), 1.0);
          }
          ```

      shader: prefilter-lvl2
        uniforms: [ u_envCube_texture: samplerCube ]
        varying:  [ texCoord: vec2 ]

        vsh:
          attributes:
          [ a_position: vec3 <- position,
            a_uv: vec2 <- texcoord ]

          source:
          ```glsl
          void main()
          {
            var.texCoord = a_uv;
            gl_Position = vec4(a_position, 1.0);
          }
          ```

          source msl:
          ```msl
          var.texCoord = a_uv;
          gl_Position = float4(a_position, 1.0);
          ```

        fsh:
          source:
          ```glsl
          const float PI = 3.1415926536;
          const float kRoughness = 0.4;

          float AkariRadicalInverse(uint a)
          {
            return float(bitfieldReverse(a)) * 2.3283064365386963e-10;
          }

          vec2 AkariHammersley2d(uint a, uint N)
          {
            return vec2(float(a) / float(N), AkariRadicalInverse(a));
          }

          vec3 AkariImportanceSampleGGX(vec2 Xi, float roughness, vec3 normal)
          {
            float alpha = roughness * roughness;
            float phi = 2.0 * PI * Xi.x;
            float cosTheta = min(
                1.0, sqrt((1.0 - Xi.y) / (1.0 + (alpha * alpha - 1.0) * Xi.y)));
            float sinTheta = sqrt(1.0 - cosTheta * cosTheta);
            vec3 H = vec3(sinTheta * cos(phi), sinTheta * sin(phi), cosTheta);
            vec3 up = abs(normal.z) < 0.999 ? vec3(0.0, 0.0, 1.0)
                                            : vec3(1.0, 0.0, 0.0);
            vec3 tangentX = normalize(cross(up, normal));
            vec3 tangentY = normalize(cross(normal, tangentX));
            return normalize(tangentX * H.x + tangentY * H.y + normal * H.z);
          }

          vec2 dirToUV(vec3 dir)
          {
            float horiz2 = dir.x * dir.x + dir.z * dir.z;
            float u = (horiz2 > 1e-12)
                ? atan(dir.x, dir.z) * (0.5 / PI) + 0.5
                : 0.5;
            float v = acos(clamp(dir.y, -1.0, 1.0)) / PI;
            return vec2(u, v);
          }

          void main()
          {
            vec2 uv = var.texCoord;
            float theta = uv.y * PI;
            float phi = (uv.x - 0.5) * 2.0 * PI;
            vec3 R = vec3(sin(theta) * sin(phi), cos(theta), sin(theta) * cos(phi));

            vec3 color = vec3(0.0);
            float totalWeight = 0.0;
            const uint numSamples = 1024u;
            for (uint i = 0u; i < numSamples; i++) {
              vec2 Xi = AkariHammersley2d(i, numSamples);
              vec3 H = AkariImportanceSampleGGX(Xi, kRoughness, R);
              vec3 L = 2.0 * dot(R, H) * H - R;
              float dotNL = clamp(dot(R, L), 0.0, 1.0);
              if (dotNL > 0.0) {
                vec3 value = texture(u_envCube_texture, L).rgb;
                color += value * dotNL;
                totalWeight += dotNL;
              }
            }
            o_pref2_texture = vec4(color / max(totalWeight, 1e-4), 1.0);
          }
          ```

          source msl:
          ```msl
          constexpr constant float PI = 3.1415926536;
          constexpr constant float kRoughness = 0.4;

          float AkariRadicalInverse(uint a)
          {
            return float(reverse_bits(a)) * 2.3283064365386963e-10;
          }

          float2 AkariHammersley2d(uint a, uint N)
          {
            return float2(float(a) / float(N), AkariRadicalInverse(a));
          }

          float3 AkariImportanceSampleGGX(float2 Xi, float roughness, float3 normal)
          {
            float alpha = roughness * roughness;
            float phi = 2.0 * PI * Xi.x;
            float cosTheta = min(
                1.0, sqrt((1.0 - Xi.y) / (1.0 + (alpha * alpha - 1.0) * Xi.y)));
            float sinTheta = sqrt(1.0 - cosTheta * cosTheta);
            float3 H = float3(sinTheta * cos(phi), sinTheta * sin(phi), cosTheta);
            float3 up = abs(normal.z) < 0.999 ? float3(0.0, 0.0, 1.0)
                                              : float3(1.0, 0.0, 0.0);
            float3 tangentX = normalize(cross(up, normal));
            float3 tangentY = normalize(cross(normal, tangentX));
            return normalize(tangentX * H.x + tangentY * H.y + normal * H.z);
          }

          float2 dirToUV(float3 dir)
          {
            float horiz2 = dir.x * dir.x + dir.z * dir.z;
            float u = (horiz2 > 1e-12)
                ? atan2(dir.x, dir.z) * (0.5 / PI) + 0.5
                : 0.5;
            float v = acos(clamp(dir.y, -1.0, 1.0)) / PI;
            return float2(u, v);
          }

          //@main
          {
            float2 uv = var.texCoord;
            float theta = uv.y * PI;
            float phi = (uv.x - 0.5) * 2.0 * PI;
            float3 R = float3(sin(theta) * sin(phi), cos(theta), sin(theta) * cos(phi));

            float3 color = float3(0.0);
            float totalWeight = 0.0;
            const uint numSamples = 1024u;
            for (uint i = 0u; i < numSamples; i++) {
              float2 Xi = AkariHammersley2d(i, numSamples);
              float3 H = AkariImportanceSampleGGX(Xi, kRoughness, R);
              float3 L = 2.0 * dot(R, H) * H - R;
              float dotNL = clamp(dot(R, L), 0.0, 1.0);
              if (dotNL > 0.0) {
                float3 value = texture(u_envCube_texture, L).rgb;
                color += value * dotNL;
                totalWeight += dotNL;
              }
            }
            o_pref2_texture = float4(color / max(totalWeight, 1e-4), 1.0);
          }
          ```

      shader: prefilter-lvl3
        uniforms: [ u_envCube_texture: samplerCube ]
        varying:  [ texCoord: vec2 ]

        vsh:
          attributes:
          [ a_position: vec3 <- position,
            a_uv: vec2 <- texcoord ]

          source:
          ```glsl
          void main()
          {
            var.texCoord = a_uv;
            gl_Position = vec4(a_position, 1.0);
          }
          ```

          source msl:
          ```msl
          var.texCoord = a_uv;
          gl_Position = float4(a_position, 1.0);
          ```

        fsh:
          source:
          ```glsl
          const float PI = 3.1415926536;
          const float kRoughness = 0.6;

          float AkariRadicalInverse(uint a)
          {
            return float(bitfieldReverse(a)) * 2.3283064365386963e-10;
          }

          vec2 AkariHammersley2d(uint a, uint N)
          {
            return vec2(float(a) / float(N), AkariRadicalInverse(a));
          }

          vec3 AkariImportanceSampleGGX(vec2 Xi, float roughness, vec3 normal)
          {
            float alpha = roughness * roughness;
            float phi = 2.0 * PI * Xi.x;
            float cosTheta = min(
                1.0, sqrt((1.0 - Xi.y) / (1.0 + (alpha * alpha - 1.0) * Xi.y)));
            float sinTheta = sqrt(1.0 - cosTheta * cosTheta);
            vec3 H = vec3(sinTheta * cos(phi), sinTheta * sin(phi), cosTheta);
            vec3 up = abs(normal.z) < 0.999 ? vec3(0.0, 0.0, 1.0)
                                            : vec3(1.0, 0.0, 0.0);
            vec3 tangentX = normalize(cross(up, normal));
            vec3 tangentY = normalize(cross(normal, tangentX));
            return normalize(tangentX * H.x + tangentY * H.y + normal * H.z);
          }

          vec2 dirToUV(vec3 dir)
          {
            float horiz2 = dir.x * dir.x + dir.z * dir.z;
            float u = (horiz2 > 1e-12)
                ? atan(dir.x, dir.z) * (0.5 / PI) + 0.5
                : 0.5;
            float v = acos(clamp(dir.y, -1.0, 1.0)) / PI;
            return vec2(u, v);
          }

          void main()
          {
            vec2 uv = var.texCoord;
            float theta = uv.y * PI;
            float phi = (uv.x - 0.5) * 2.0 * PI;
            vec3 R = vec3(sin(theta) * sin(phi), cos(theta), sin(theta) * cos(phi));

            vec3 color = vec3(0.0);
            float totalWeight = 0.0;
            const uint numSamples = 1024u;
            for (uint i = 0u; i < numSamples; i++) {
              vec2 Xi = AkariHammersley2d(i, numSamples);
              vec3 H = AkariImportanceSampleGGX(Xi, kRoughness, R);
              vec3 L = 2.0 * dot(R, H) * H - R;
              float dotNL = clamp(dot(R, L), 0.0, 1.0);
              if (dotNL > 0.0) {
                vec3 value = texture(u_envCube_texture, L).rgb;
                color += value * dotNL;
                totalWeight += dotNL;
              }
            }
            o_pref3_texture = vec4(color / max(totalWeight, 1e-4), 1.0);
          }
          ```

          source msl:
          ```msl
          constexpr constant float PI = 3.1415926536;
          constexpr constant float kRoughness = 0.6;

          float AkariRadicalInverse(uint a)
          {
            return float(reverse_bits(a)) * 2.3283064365386963e-10;
          }

          float2 AkariHammersley2d(uint a, uint N)
          {
            return float2(float(a) / float(N), AkariRadicalInverse(a));
          }

          float3 AkariImportanceSampleGGX(float2 Xi, float roughness, float3 normal)
          {
            float alpha = roughness * roughness;
            float phi = 2.0 * PI * Xi.x;
            float cosTheta = min(
                1.0, sqrt((1.0 - Xi.y) / (1.0 + (alpha * alpha - 1.0) * Xi.y)));
            float sinTheta = sqrt(1.0 - cosTheta * cosTheta);
            float3 H = float3(sinTheta * cos(phi), sinTheta * sin(phi), cosTheta);
            float3 up = abs(normal.z) < 0.999 ? float3(0.0, 0.0, 1.0)
                                              : float3(1.0, 0.0, 0.0);
            float3 tangentX = normalize(cross(up, normal));
            float3 tangentY = normalize(cross(normal, tangentX));
            return normalize(tangentX * H.x + tangentY * H.y + normal * H.z);
          }

          float2 dirToUV(float3 dir)
          {
            float horiz2 = dir.x * dir.x + dir.z * dir.z;
            float u = (horiz2 > 1e-12)
                ? atan2(dir.x, dir.z) * (0.5 / PI) + 0.5
                : 0.5;
            float v = acos(clamp(dir.y, -1.0, 1.0)) / PI;
            return float2(u, v);
          }

          //@main
          {
            float2 uv = var.texCoord;
            float theta = uv.y * PI;
            float phi = (uv.x - 0.5) * 2.0 * PI;
            float3 R = float3(sin(theta) * sin(phi), cos(theta), sin(theta) * cos(phi));

            float3 color = float3(0.0);
            float totalWeight = 0.0;
            const uint numSamples = 1024u;
            for (uint i = 0u; i < numSamples; i++) {
              float2 Xi = AkariHammersley2d(i, numSamples);
              float3 H = AkariImportanceSampleGGX(Xi, kRoughness, R);
              float3 L = 2.0 * dot(R, H) * H - R;
              float dotNL = clamp(dot(R, L), 0.0, 1.0);
              if (dotNL > 0.0) {
                float3 value = texture(u_envCube_texture, L).rgb;
                color += value * dotNL;
                totalWeight += dotNL;
              }
            }
            o_pref3_texture = float4(color / max(totalWeight, 1e-4), 1.0);
          }
          ```

      shader: prefilter-lvl4
        uniforms: [ u_envCube_texture: samplerCube ]
        varying:  [ texCoord: vec2 ]

        vsh:
          attributes:
          [ a_position: vec3 <- position,
            a_uv: vec2 <- texcoord ]

          source:
          ```glsl
          void main()
          {
            var.texCoord = a_uv;
            gl_Position = vec4(a_position, 1.0);
          }
          ```

          source msl:
          ```msl
          var.texCoord = a_uv;
          gl_Position = float4(a_position, 1.0);
          ```

        fsh:
          source:
          ```glsl
          const float PI = 3.1415926536;
          const float kRoughness = 0.8;

          float AkariRadicalInverse(uint a)
          {
            return float(bitfieldReverse(a)) * 2.3283064365386963e-10;
          }

          vec2 AkariHammersley2d(uint a, uint N)
          {
            return vec2(float(a) / float(N), AkariRadicalInverse(a));
          }

          vec3 AkariImportanceSampleGGX(vec2 Xi, float roughness, vec3 normal)
          {
            float alpha = roughness * roughness;
            float phi = 2.0 * PI * Xi.x;
            float cosTheta = min(
                1.0, sqrt((1.0 - Xi.y) / (1.0 + (alpha * alpha - 1.0) * Xi.y)));
            float sinTheta = sqrt(1.0 - cosTheta * cosTheta);
            vec3 H = vec3(sinTheta * cos(phi), sinTheta * sin(phi), cosTheta);
            vec3 up = abs(normal.z) < 0.999 ? vec3(0.0, 0.0, 1.0)
                                            : vec3(1.0, 0.0, 0.0);
            vec3 tangentX = normalize(cross(up, normal));
            vec3 tangentY = normalize(cross(normal, tangentX));
            return normalize(tangentX * H.x + tangentY * H.y + normal * H.z);
          }

          vec2 dirToUV(vec3 dir)
          {
            float horiz2 = dir.x * dir.x + dir.z * dir.z;
            float u = (horiz2 > 1e-12)
                ? atan(dir.x, dir.z) * (0.5 / PI) + 0.5
                : 0.5;
            float v = acos(clamp(dir.y, -1.0, 1.0)) / PI;
            return vec2(u, v);
          }

          void main()
          {
            vec2 uv = var.texCoord;
            float theta = uv.y * PI;
            float phi = (uv.x - 0.5) * 2.0 * PI;
            vec3 R = vec3(sin(theta) * sin(phi), cos(theta), sin(theta) * cos(phi));

            vec3 color = vec3(0.0);
            float totalWeight = 0.0;
            const uint numSamples = 1024u;
            for (uint i = 0u; i < numSamples; i++) {
              vec2 Xi = AkariHammersley2d(i, numSamples);
              vec3 H = AkariImportanceSampleGGX(Xi, kRoughness, R);
              vec3 L = 2.0 * dot(R, H) * H - R;
              float dotNL = clamp(dot(R, L), 0.0, 1.0);
              if (dotNL > 0.0) {
                vec3 value = texture(u_envCube_texture, L).rgb;
                color += value * dotNL;
                totalWeight += dotNL;
              }
            }
            o_pref4_texture = vec4(color / max(totalWeight, 1e-4), 1.0);
          }
          ```

          source msl:
          ```msl
          constexpr constant float PI = 3.1415926536;
          constexpr constant float kRoughness = 0.8;

          float AkariRadicalInverse(uint a)
          {
            return float(reverse_bits(a)) * 2.3283064365386963e-10;
          }

          float2 AkariHammersley2d(uint a, uint N)
          {
            return float2(float(a) / float(N), AkariRadicalInverse(a));
          }

          float3 AkariImportanceSampleGGX(float2 Xi, float roughness, float3 normal)
          {
            float alpha = roughness * roughness;
            float phi = 2.0 * PI * Xi.x;
            float cosTheta = min(
                1.0, sqrt((1.0 - Xi.y) / (1.0 + (alpha * alpha - 1.0) * Xi.y)));
            float sinTheta = sqrt(1.0 - cosTheta * cosTheta);
            float3 H = float3(sinTheta * cos(phi), sinTheta * sin(phi), cosTheta);
            float3 up = abs(normal.z) < 0.999 ? float3(0.0, 0.0, 1.0)
                                              : float3(1.0, 0.0, 0.0);
            float3 tangentX = normalize(cross(up, normal));
            float3 tangentY = normalize(cross(normal, tangentX));
            return normalize(tangentX * H.x + tangentY * H.y + normal * H.z);
          }

          float2 dirToUV(float3 dir)
          {
            // Guard the pole singularity: atan2(x, z) is undefined/NaN exactly at
            // x == z == 0, and extremely sensitive to floating-point noise near
            // it. See the GLSL variant for the full explanation.
            float horiz2 = dir.x * dir.x + dir.z * dir.z;
            float u = (horiz2 > 1e-12)
                ? atan2(dir.x, dir.z) * (0.5 / PI) + 0.5
                : 0.5;
            float v = acos(clamp(dir.y, -1.0, 1.0)) / PI;
            return float2(u, v);
          }

          //@main
          {
            float2 uv = var.texCoord;
            float theta = uv.y * PI;
            float phi = (uv.x - 0.5) * 2.0 * PI;
            float3 R = float3(sin(theta) * sin(phi), cos(theta), sin(theta) * cos(phi));

            float3 color = float3(0.0);
            float totalWeight = 0.0;
            const uint numSamples = 1024u;
            for (uint i = 0u; i < numSamples; i++) {
              float2 Xi = AkariHammersley2d(i, numSamples);
              float3 H = AkariImportanceSampleGGX(Xi, kRoughness, R);
              float3 L = 2.0 * dot(R, H) * H - R;
              float dotNL = clamp(dot(R, L), 0.0, 1.0);
              if (dotNL > 0.0) {
                float3 value = texture(u_envCube_texture, L).rgb;
                color += value * dotNL;
                totalWeight += dotNL;
              }
            }
            o_pref4_texture = float4(color / max(totalWeight, 1e-4), 1.0);
          }
          ```

      shader: prefilter-lvl5
        uniforms: [ u_envCube_texture: samplerCube ]
        varying:  [ texCoord: vec2 ]

        vsh:
          attributes:
          [ a_position: vec3 <- position,
            a_uv: vec2 <- texcoord ]

          source:
          ```glsl
          void main()
          {
            var.texCoord = a_uv;
            gl_Position = vec4(a_position, 1.0);
          }
          ```

          source msl:
          ```msl
          var.texCoord = a_uv;
          gl_Position = float4(a_position, 1.0);
          ```

        fsh:
          source:
          ```glsl
          const float PI = 3.1415926536;
          const float kRoughness = 1.0;

          float AkariRadicalInverse(uint a)
          {
            return float(bitfieldReverse(a)) * 2.3283064365386963e-10;
          }

          vec2 AkariHammersley2d(uint a, uint N)
          {
            return vec2(float(a) / float(N), AkariRadicalInverse(a));
          }

          vec3 AkariImportanceSampleGGX(vec2 Xi, float roughness, vec3 normal)
          {
            float alpha = roughness * roughness;
            float phi = 2.0 * PI * Xi.x;
            float cosTheta = min(
                1.0, sqrt((1.0 - Xi.y) / (1.0 + (alpha * alpha - 1.0) * Xi.y)));
            float sinTheta = sqrt(1.0 - cosTheta * cosTheta);
            vec3 H = vec3(sinTheta * cos(phi), sinTheta * sin(phi), cosTheta);
            vec3 up = abs(normal.z) < 0.999 ? vec3(0.0, 0.0, 1.0)
                                            : vec3(1.0, 0.0, 0.0);
            vec3 tangentX = normalize(cross(up, normal));
            vec3 tangentY = normalize(cross(normal, tangentX));
            return normalize(tangentX * H.x + tangentY * H.y + normal * H.z);
          }

          vec2 dirToUV(vec3 dir)
          {
            float horiz2 = dir.x * dir.x + dir.z * dir.z;
            float u = (horiz2 > 1e-12)
                ? atan(dir.x, dir.z) * (0.5 / PI) + 0.5
                : 0.5;
            float v = acos(clamp(dir.y, -1.0, 1.0)) / PI;
            return vec2(u, v);
          }

          void main()
          {
            vec2 uv = var.texCoord;
            float theta = uv.y * PI;
            float phi = (uv.x - 0.5) * 2.0 * PI;
            vec3 R = vec3(sin(theta) * sin(phi), cos(theta), sin(theta) * cos(phi));

            vec3 color = vec3(0.0);
            float totalWeight = 0.0;
            const uint numSamples = 1024u;
            for (uint i = 0u; i < numSamples; i++) {
              vec2 Xi = AkariHammersley2d(i, numSamples);
              vec3 H = AkariImportanceSampleGGX(Xi, kRoughness, R);
              vec3 L = 2.0 * dot(R, H) * H - R;
              float dotNL = clamp(dot(R, L), 0.0, 1.0);
              if (dotNL > 0.0) {
                vec3 value = texture(u_envCube_texture, L).rgb;
                color += value * dotNL;
                totalWeight += dotNL;
              }
            }
            o_pref5_texture = vec4(color / max(totalWeight, 1e-4), 1.0);
          }
          ```

          source msl:
          ```msl
          constexpr constant float PI = 3.1415926536;
          constexpr constant float kRoughness = 1.0;

          float AkariRadicalInverse(uint a)
          {
            return float(reverse_bits(a)) * 2.3283064365386963e-10;
          }

          float2 AkariHammersley2d(uint a, uint N)
          {
            return float2(float(a) / float(N), AkariRadicalInverse(a));
          }

          float3 AkariImportanceSampleGGX(float2 Xi, float roughness, float3 normal)
          {
            float alpha = roughness * roughness;
            float phi = 2.0 * PI * Xi.x;
            float cosTheta = min(
                1.0, sqrt((1.0 - Xi.y) / (1.0 + (alpha * alpha - 1.0) * Xi.y)));
            float sinTheta = sqrt(1.0 - cosTheta * cosTheta);
            float3 H = float3(sinTheta * cos(phi), sinTheta * sin(phi), cosTheta);
            float3 up = abs(normal.z) < 0.999 ? float3(0.0, 0.0, 1.0)
                                              : float3(1.0, 0.0, 0.0);
            float3 tangentX = normalize(cross(up, normal));
            float3 tangentY = normalize(cross(normal, tangentX));
            return normalize(tangentX * H.x + tangentY * H.y + normal * H.z);
          }

          float2 dirToUV(float3 dir)
          {
            float horiz2 = dir.x * dir.x + dir.z * dir.z;
            float u = (horiz2 > 1e-12)
                ? atan2(dir.x, dir.z) * (0.5 / PI) + 0.5
                : 0.5;
            float v = acos(clamp(dir.y, -1.0, 1.0)) / PI;
            return float2(u, v);
          }

          //@main
          {
            float2 uv = var.texCoord;
            float theta = uv.y * PI;
            float phi = (uv.x - 0.5) * 2.0 * PI;
            float3 R = float3(sin(theta) * sin(phi), cos(theta), sin(theta) * cos(phi));

            float3 color = float3(0.0);
            float totalWeight = 0.0;
            const uint numSamples = 1024u;
            for (uint i = 0u; i < numSamples; i++) {
              float2 Xi = AkariHammersley2d(i, numSamples);
              float3 H = AkariImportanceSampleGGX(Xi, kRoughness, R);
              float3 L = 2.0 * dot(R, H) * H - R;
              float dotNL = clamp(dot(R, L), 0.0, 1.0);
              if (dotNL > 0.0) {
                float3 value = texture(u_envCube_texture, L).rgb;
                color += value * dotNL;
                totalWeight += dotNL;
              }
            }
            o_pref5_texture = float4(color / max(totalWeight, 1e-4), 1.0);
          }
          ```

      shader: irradiance-gen
        uniforms: [ u_envCube_texture: samplerCube ]
        varying:  [ texCoord: vec2 ]

        vsh:
          attributes:
          [ a_position: vec3 <- position,
            a_uv: vec2 <- texcoord ]

          source:
          ```glsl
          void main()
          {
            var.texCoord = a_uv;
            gl_Position = vec4(a_position, 1.0);
          }
          ```

          source msl:
          ```msl
          var.texCoord = a_uv;
          gl_Position = float4(a_position, 1.0);
          ```

        fsh:
          source:
          ```glsl
          const float PI = 3.1415926536;
          const float AkariDeltaPhi = (2.0 * PI) / 180.0;
          const float AkariDeltaTheta = (0.5 * PI) / 64.0;

          vec2 dirToUV(vec3 dir)
          {
            float horiz2 = dir.x * dir.x + dir.z * dir.z;
            float u = (horiz2 > 1e-12)
                ? atan(dir.x, dir.z) * (0.5 / PI) + 0.5
                : 0.5;
            float v = acos(clamp(dir.y, -1.0, 1.0)) / PI;
            return vec2(u, v);
          }

          void main()
          {
            vec2 uv = var.texCoord;
            float theta = uv.y * PI;
            float phi = (uv.x - 0.5) * 2.0 * PI;
            vec3 N = vec3(sin(theta) * sin(phi), cos(theta), sin(theta) * cos(phi));

            vec3 up = abs(N.y) < 0.999 ? vec3(0.0, 1.0, 0.0) : vec3(0.0, 0.0, 1.0);
            vec3 right = normalize(cross(up, N));
            up = cross(N, right);

            const float TWO_PI = PI * 2.0;
            const float HALF_PI = PI * 0.5;

            vec3 color = vec3(0.0);
            uint sampleCount = 0u;
            for (float p = 0.0; p < TWO_PI; p += AkariDeltaPhi) {
              for (float t = 0.0; t < HALF_PI; t += AkariDeltaTheta) {
                vec3 tempVec = cos(p) * right + sin(p) * up;
                vec3 sampleVector = cos(t) * N + sin(t) * tempVec;
                color += texture(u_envCube_texture, sampleVector).rgb *
                         cos(t) * sin(t);
                sampleCount++;
              }
            }
            o_irradiance_texture = vec4(PI * color / float(sampleCount), 1.0);
          }
          ```

          source msl:
          ```msl
          constexpr constant float PI = 3.1415926536;
          constexpr constant float AkariDeltaPhi = (2.0 * PI) / 180.0;
          constexpr constant float AkariDeltaTheta = (0.5 * PI) / 64.0;

          float2 dirToUV(float3 dir)
          {
            float horiz2 = dir.x * dir.x + dir.z * dir.z;
            float u = (horiz2 > 1e-12)
                ? atan2(dir.x, dir.z) * (0.5 / PI) + 0.5
                : 0.5;
            float v = acos(clamp(dir.y, -1.0, 1.0)) / PI;
            return float2(u, v);
          }

          //@main
          {
            float2 uv = var.texCoord;
            float theta = uv.y * PI;
            float phi = (uv.x - 0.5) * 2.0 * PI;
            float3 N = float3(sin(theta) * sin(phi), cos(theta), sin(theta) * cos(phi));

            float3 up = abs(N.y) < 0.999 ? float3(0.0, 1.0, 0.0) : float3(0.0, 0.0, 1.0);
            float3 right = normalize(cross(up, N));
            up = cross(N, right);

            const float TWO_PI = PI * 2.0;
            const float HALF_PI = PI * 0.5;

            float3 color = float3(0.0);
            uint sampleCount = 0u;
            for (float p = 0.0; p < TWO_PI; p += AkariDeltaPhi) {
              for (float t = 0.0; t < HALF_PI; t += AkariDeltaTheta) {
                float3 tempVec = cos(p) * right + sin(p) * up;
                float3 sampleVector = cos(t) * N + sin(t) * tempVec;
                color += texture(u_envCube_texture, sampleVector).rgb *
                         cos(t) * sin(t);
                sampleCount++;
              }
            }
            o_irradiance_texture = float4(PI * color / float(sampleCount), 1.0);
          }
          ```

      shader: dfg-gen
        uniforms: []
        varying:  [ texCoord: vec2 ]

        vsh:
          attributes:
          [ a_position: vec3 <- position,
            a_uv: vec2 <- texcoord ]

          source:
          ```glsl
          void main()
          {
            var.texCoord = a_uv;
            gl_Position = vec4(a_position, 1.0);
          }
          ```

          source msl:
          ```msl
          var.texCoord = a_uv;
          gl_Position = float4(a_position, 1.0);
          ```

        fsh:
          source:
          ```glsl
          const float PI = 3.1415926536;

          float AkariRadicalInverse(uint a)
          {
            return float(bitfieldReverse(a)) * 2.3283064365386963e-10;
          }

          vec2 AkariHammersley2d(uint a, uint N)
          {
            return vec2(float(a) / float(N), AkariRadicalInverse(a));
          }

          vec3 AkariImportanceSampleGGX(vec2 Xi, float roughness, vec3 normal)
          {
            float alpha = roughness * roughness;
            float phi = 2.0 * PI * Xi.x;
            float cosTheta = min(
                1.0, sqrt((1.0 - Xi.y) / (1.0 + (alpha * alpha - 1.0) * Xi.y)));
            float sinTheta = sqrt(1.0 - cosTheta * cosTheta);
            vec3 H = vec3(sinTheta * cos(phi), sinTheta * sin(phi), cosTheta);
            vec3 up = abs(normal.z) < 0.999 ? vec3(0.0, 0.0, 1.0)
                                            : vec3(1.0, 0.0, 0.0);
            vec3 tangentX = normalize(cross(up, normal));
            vec3 tangentY = normalize(cross(normal, tangentX));
            return normalize(tangentX * H.x + tangentY * H.y + normal * H.z);
          }

          float AkariGeometrySchlicksmithGGX(float dotNL, float dotNV, float roughness)
          {
            float k = (roughness * roughness) / 2.0;
            float GL = dotNL / (dotNL * (1.0 - k) + k);
            float GV = dotNV / (dotNV * (1.0 - k) + k);
            return GL * GV;
          }

          vec2 AkariComputeBRDF(float NoV, float roughness)
          {
            NoV = max(NoV, 0.001);

            const vec3 N = vec3(0.0, 0.0, 1.0);
            vec3 V = vec3(sqrt(1.0 - NoV * NoV), 0.0, NoV);

            vec2 LUT = vec2(0.0);
            const uint NUM_SAMPLES = 1024u;
            for (uint i = 0u; i < NUM_SAMPLES; i++) {
              vec2 Xi = AkariHammersley2d(i, NUM_SAMPLES);
              vec3 H = AkariImportanceSampleGGX(Xi, roughness, N);
              vec3 L = 2.0 * dot(V, H) * H - V;

              float dotNL = max(dot(N, L), 0.0);
              float dotNV = max(dot(N, V), 0.0);
              float dotVH = max(dot(V, H), 0.0);
              float dotNH = max(dot(H, N), 0.0);

              if (dotNL > 0.0) {
                float G = AkariGeometrySchlicksmithGGX(dotNL, dotNV, roughness);
                float G_Vis = (G * dotVH) / (dotNH * dotNV);
                float Fc = pow(1.0 - dotVH, 5.0);
                LUT += vec2((1.0 - Fc) * G_Vis, Fc * G_Vis);
              }
            }
            return LUT / float(NUM_SAMPLES);
          }

          void main()
          {
            vec2 texCoords = var.texCoord;
            vec2 lut = AkariComputeBRDF(texCoords.x, texCoords.y);
            o_dfg_texture = vec4(lut, 0.0, 1.0);
          }
          ```

          source msl:
          ```msl
          constexpr constant float PI = 3.1415926536;

          float AkariRadicalInverse(uint a)
          {
            return float(reverse_bits(a)) * 2.3283064365386963e-10;
          }

          float2 AkariHammersley2d(uint a, uint N)
          {
            return float2(float(a) / float(N), AkariRadicalInverse(a));
          }

          float3 AkariImportanceSampleGGX(float2 Xi, float roughness, float3 normal)
          {
            float alpha = roughness * roughness;
            float phi = 2.0 * PI * Xi.x;
            float cosTheta = min(
                1.0, sqrt((1.0 - Xi.y) / (1.0 + (alpha * alpha - 1.0) * Xi.y)));
            float sinTheta = sqrt(1.0 - cosTheta * cosTheta);
            float3 H = float3(sinTheta * cos(phi), sinTheta * sin(phi), cosTheta);
            float3 up = abs(normal.z) < 0.999 ? float3(0.0, 0.0, 1.0)
                                              : float3(1.0, 0.0, 0.0);
            float3 tangentX = normalize(cross(up, normal));
            float3 tangentY = normalize(cross(normal, tangentX));
            return normalize(tangentX * H.x + tangentY * H.y + normal * H.z);
          }

          float AkariGeometrySchlicksmithGGX(float dotNL, float dotNV, float roughness)
          {
            float k = (roughness * roughness) / 2.0;
            float GL = dotNL / (dotNL * (1.0 - k) + k);
            float GV = dotNV / (dotNV * (1.0 - k) + k);
            return GL * GV;
          }

          float2 AkariComputeBRDF(float NoV, float roughness)
          {
            NoV = max(NoV, 0.001);

            const float3 N = float3(0.0, 0.0, 1.0);
            float3 V = float3(sqrt(1.0 - NoV * NoV), 0.0, NoV);

            float2 LUT = float2(0.0);
            const uint NUM_SAMPLES = 1024u;
            for (uint i = 0u; i < NUM_SAMPLES; i++) {
              float2 Xi = AkariHammersley2d(i, NUM_SAMPLES);
              float3 H = AkariImportanceSampleGGX(Xi, roughness, N);
              float3 L = 2.0 * dot(V, H) * H - V;

              float dotNL = max(dot(N, L), 0.0);
              float dotNV = max(dot(N, V), 0.0);
              float dotVH = max(dot(V, H), 0.0);
              float dotNH = max(dot(H, N), 0.0);

              if (dotNL > 0.0) {
                float G = AkariGeometrySchlicksmithGGX(dotNL, dotNV, roughness);
                float G_Vis = (G * dotVH) / (dotNH * dotNV);
                float Fc = pow(1.0 - dotVH, 5.0);
                LUT += float2((1.0 - Fc) * G_Vis, Fc * G_Vis);
              }
            }
            return LUT / float(NUM_SAMPLES);
          }

          //@main
          {
            float2 texCoords = var.texCoord;
            float2 lut = AkariComputeBRDF(texCoords.x, texCoords.y);
            o_dfg_texture = float4(lut, 0.0, 1.0);
          }
          ```

      shader: deferred-shade
        uniforms: [ u_normal_texture: sampler2d,
                    u_position_texture: sampler2d,
                    u_diffuse_texture: sampler2d,
                    u_envCube_texture: samplerCube,
                    u_pref0_texture: sampler2d,
                    u_pref1_texture: sampler2d,
                    u_pref2_texture: sampler2d,
                    u_pref3_texture: sampler2d,
                    u_pref4_texture: sampler2d,
                    u_pref5_texture: sampler2d,
                    u_irradiance_texture: sampler2d,
                    u_dfg_texture: sampler2d,
                    u_view: mat4 <- auto-view-matrix,
                    u_iblEnabled: float,
                    u_invProj: mat4,
                    sunHeight: float ]
        varying:  [ texCoord: vec2 ]

        vsh:
          attributes:
          [ a_position: vec3 <- position,
            a_uv: vec2 <- texcoord ]

          source:
          ```glsl
          void main()
          {
            var.texCoord = a_uv;
            gl_Position = vec4(a_position, 1.0);
          }
          ```

          source msl:
          ```msl
          var.texCoord = a_uv;
          gl_Position = float4(a_position, 1.0);
          ```

        fsh:
          source:
          ```glsl
          const float PI = 3.14159265358979;
          const float LIGHT_INTENSITY = 3.0;
          const float MOON_INTENSITY = 0.12;

          vec2 dirToUV(vec3 dir)
          {
            float horiz2 = dir.x * dir.x + dir.z * dir.z;
            float u = (horiz2 > 1e-6)
                ? atan(dir.x, dir.z) * (0.5 / PI) + 0.5
                : 0.5;
            float v = acos(clamp(dir.y, -1.0, 1.0)) / PI;
            return vec2(u, v);
          }

          vec3 F_Schlick(vec3 f0, float VoH)
          {
            float f = pow(1.0 - VoH, 5.0);
            return f + f0 * (1.0 - f);
          }

          float D_GGX(float roughness, float NoH)
          {
            float a = NoH * roughness;
            float k = min(roughness / (1.0 - NoH * NoH + a * a), 453.5);
            return k * k * (1.0 / PI);
          }

          float V_SmithGGXCorrelatedFast(float roughness, float NoV, float NoL)
          {
            return 0.5 / mix(2.0 * NoL * NoV, NoL + NoV, roughness);
          }

          void main()
          {
            vec4 normalSample = texture(u_normal_texture, var.texCoord);
            vec3 normalEye = normalSample.xyz;
            vec3 posEye = texture(u_position_texture, var.texCoord).xyz;
            vec3 diffuse = texture(u_diffuse_texture, var.texCoord).xyz;

            mat3 invView = mat3(inverse(u_view));

            if (normalSample.a < 0.5) {
              if (u_iblEnabled > 0.5) {
                vec4 e = u_invProj * vec4(var.texCoord * 2.0 - 1.0, 1.0, 1.0);
                vec3 worldDir = normalize(invView * (e.xyz / e.w));
                vec3 sky = texture(u_envCube_texture, worldDir).rgb;
                o_final_texture = vec4(sky, 1.0);
              } else {
                o_final_texture = vec4(diffuse, 1.0);
              }
              return;
            }

            vec3 N = normalize(invView * normalEye);
            vec3 V = normalize(invView * (-posEye));
            float NoV = max(dot(N, V), 1e-4);

            // (todo): get the proper roughness from the material.
            float perceptualRoughness = 0.5;
            float roughness = perceptualRoughness * perceptualRoughness;
            vec3 baseColor = diffuse;
            vec3 f0 = mix(vec3(0.04), baseColor, 0.0);
            vec3 diffuseColor = baseColor * (1.0 - 0.0);

            float celestialAngle = clamp(abs(sunHeight) + 0.01, 0.0, 1.0) * 75.0 * PI / 180.0;
            vec3 sunL = normalize(vec3(0.4 * cos(celestialAngle),
                                        sin(celestialAngle),
                                        -0.5 * cos(celestialAngle)));
            vec3 moonL = vec3(-sunL.x, sunL.y, -sunL.z);

            float nightFade = smoothstep(-0.3, 0.05, sunHeight);
            vec3 L = normalize(mix(moonL, sunL, nightFade));

            vec3 color = vec3(0.0);
            float NoL = max(dot(N, L), 1e-4);
            if (NoL > 0.0) {
              vec3 H = normalize(V + L);
              float NoH = max(dot(N, H), 0.0);
              float LoH = max(dot(L, H), 0.0);
              float D = D_GGX(roughness, NoH);

              float Vis = V_SmithGGXCorrelatedFast(roughness, NoV, NoL);
              vec3 F = F_Schlick(f0, LoH);

              vec3 kD = vec3(1.0) - F;
              vec3 Fr = D * Vis * F * NoL;
              vec3 Fd = (kD * diffuseColor / PI) * NoL;

              float terminatorSmooth = pow(smoothstep(-0.40, 0.40, NoL), 3.0);

              vec3 dayColor = mix(texture(u_envCube_texture, L).rgb, vec3(1.0), clamp(sunHeight, 0.0, 1.0));
              vec3 nightColor = mix(texture(u_envCube_texture, L).rgb, vec3(0.95, 0.95, 1.00), clamp(-sunHeight, 0.0, 1.0));
              vec3 dynamicSky = mix(nightColor * MOON_INTENSITY, dayColor * LIGHT_INTENSITY, nightFade);

              color += (Fd + Fr) * terminatorSmooth * dynamicSky;
            }

            vec3 dfg = texture(u_dfg_texture, vec2(NoV, perceptualRoughness)).rgb;
            vec3 E = mix(dfg.yyy, dfg.xxx, f0);
            vec3 energyCompensation =
                1.0 + f0 * (1.0 / max(mix(vec3(1.0), dfg.yyy, f0), 1e-4) - 1.0);

            vec3 r = reflect(-V, N);
            r = mix(r, N, roughness * roughness);

            float lod = 5.0 * perceptualRoughness * (2.0 - perceptualRoughness);
            lod = clamp(lod, 0.0, 5.0);
            float l0 = floor(lod);
            float l1 = min(l0 + 1.0, 5.0);
            float fracLod = lod - l0;

            vec2 ruv = dirToUV(r);

            sampler2D prefTextures[6] = sampler2D[6](
              u_pref0_texture, u_pref1_texture, u_pref2_texture,
              u_pref3_texture, u_pref4_texture, u_pref5_texture
            );

            vec3 pr0 = texture(prefTextures[int(l0)], ruv).rgb;
            vec3 pr1 = texture(prefTextures[int(l1)], ruv).rgb;

            vec3 prefilteredRadiance = mix(pr0, pr1, fracLod);
            vec3 Fr = E * prefilteredRadiance * energyCompensation;

            vec3 irradiance = texture(u_irradiance_texture, dirToUV(N)).rgb;
            vec3 Fd = diffuseColor * irradiance * (1.0 - E);

            color += (Fd + Fr) * u_iblEnabled;

            o_final_texture = vec4(color, 1.0);
          }
          ```

          source msl:
          ```msl
          constexpr constant float PI = 3.14159265358979;
          constexpr constant float LIGHT_INTENSITY = 3.0;
          constexpr constant float MOON_INTENSITY = 0.12;

          float2 dirToUV(float3 dir)
          {
            float horiz2 = dir.x * dir.x + dir.z * dir.z;
            float u = (horiz2 > 1e-6)
                ? atan2(dir.x, dir.z) * (0.5 / PI) + 0.5
                : 0.5;
            float v = acos(clamp(dir.y, -1.0, 1.0)) / PI;
            return float2(u, v);
          }

          float3 F_Schlick(float3 f0, float VoH)
          {
            float f = pow(1.0 - VoH, 5.0);
            return f + f0 * (1.0 - f);
          }

          float D_GGX(float roughness, float NoH)
          {
            float a = NoH * roughness;
            float k = min(roughness / (1.0 - NoH * NoH + a * a), 453.5);
            return k * k * (1.0 / PI);
          }

          float V_SmithGGXCorrelatedFast(float roughness, float NoV, float NoL)
          {
            return 0.5 / mix(2.0 * NoL * NoV, NoL + NoV, roughness);
          }

          //@main
          {
            float4 normalSample = texture(u_normal_texture, var.texCoord);
            float3 normalEye = normalSample.xyz;
            float3 posEye = texture(u_position_texture, var.texCoord).xyz;
            float3 diffuse = texture(u_diffuse_texture, var.texCoord).xyz;

            float3x3 invView = float3x3(
              float3(u_view[0][0], u_view[1][0], u_view[2][0]),
              float3(u_view[0][1], u_view[1][1], u_view[2][1]),
              float3(u_view[0][2], u_view[1][2], u_view[2][2])
            );

            if (normalSample.a < 0.5) {
              if (u_iblEnabled > 0.5) {
                float4 e = u_invProj * float4(var.texCoord * 2.0 - 1.0, 1.0, 1.0);
                float3 worldDir = normalize(invView * (e.xyz / e.w));
                float3 sky = texture(u_envCube_texture, worldDir).rgb;
                o_final_texture = float4(sky, 1.0);
              } else {
                o_final_texture = float4(diffuse, 1.0);
              }
            } else {
              float3 N = normalize(invView * normalEye);
              float3 V = normalize(invView * (-posEye));
              float NoV = max(dot(N, V), 1e-4);

              float perceptualRoughness = 0.5;
              float roughness = perceptualRoughness * perceptualRoughness;
              float3 baseColor = diffuse;
              float3 f0 = mix(float3(0.04), baseColor, 0.0);
              float3 diffuseColor = baseColor * (1.0 - 0.0);

              float celestialAngle = saturate(abs(sunHeight) + 0.01) * 75.0 * PI / 180.0;
              float3 sunL = normalize(float3(0.4 * cos(celestialAngle),
                                             sin(celestialAngle),
                                             -0.5 * cos(celestialAngle)));
              float3 moonL = float3(-sunL.x, sunL.y, -sunL.z);

              float nightFade = smoothstep(-0.3, 0.05, sunHeight);
              float3 L = normalize(mix(moonL, sunL, nightFade));

              float3 color = float3(0.0);
              float NoL = max(dot(N, L), 1e-4);
              if (NoL > 0.0) {
                float3 H = normalize(V + L);
                float NoH = max(dot(N, H), 0.0);
                float LoH = max(dot(L, H), 0.0);
                float D = D_GGX(roughness, NoH);

                float Vis = V_SmithGGXCorrelatedFast(roughness, NoV, NoL);
                float3 F = F_Schlick(f0, LoH);

                float3 kD = float3(1.0) - F;
                float3 Fr = D * Vis * F * NoL;
                float3 Fd = (kD * diffuseColor / PI) * NoL;

                float terminatorSmooth = pow(smoothstep(-0.40, 0.40, NoL), 3.0);

                float3 dayColor = mix(texture(u_envCube_texture, L).rgb, float3(1.0), saturate(sunHeight));
                float3 nightColor = mix(texture(u_envCube_texture, L).rgb, float3(0.95, 0.95, 1.00), saturate(-sunHeight));
                float3 dynamicSky = mix(nightColor * MOON_INTENSITY, dayColor * LIGHT_INTENSITY, nightFade);
      
                color += (Fd + Fr) * terminatorSmooth * dynamicSky;
              }

              float3 dfg = texture(u_dfg_texture, float2(NoV, perceptualRoughness)).rgb;
              float3 E = mix(dfg.yyy, dfg.xxx, f0);
              float3 energyCompensation =
                  1.0 + f0 * (1.0 / max(mix(float3(1.0), dfg.yyy, f0), 1e-4) - 1.0);

              float3 r = reflect(-V, N);
              r = mix(r, N, roughness * roughness);

              float lod = 5.0 * perceptualRoughness * (2.0 - perceptualRoughness);
              lod = clamp(lod, 0.0, 5.0);
              float l0 = floor(lod);
              float l1 = min(l0 + 1.0, 5.0);
              float fracLod = lod - l0;

              float2 ruv = dirToUV(r);
      
              array<texture2d<float>, 6> prefTextures = {
                u_pref0_texture, u_pref1_texture, u_pref2_texture, 
                u_pref3_texture, u_pref4_texture, u_pref5_texture
              };
      
              float3 pr0 = prefTextures[int(l0)].sample(u_pref0_texture_smp, ruv).rgb;
              float3 pr1 = prefTextures[int(l1)].sample(u_pref0_texture_smp, ruv).rgb;

              float3 prefilteredRadiance = mix(pr0, pr1, fracLod);
              float3 Fr = E * prefilteredRadiance * energyCompensation;

              float3 irradiance = texture(u_irradiance_texture, dirToUV(N)).rgb;
              float3 Fd = diffuseColor * irradiance * (1.0 - E);

              color += (Fd + Fr) * u_iblEnabled;

              o_final_texture = float4(color, 1.0);
            }
          }
          ```
      """
  }
}
