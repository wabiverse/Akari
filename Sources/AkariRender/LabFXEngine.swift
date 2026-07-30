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

    /// IBL is expensive, this sets a flag to bake it once.
    private var iblNeedsBake = true
    private static let kIblPassNames = [
      "env gen",
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
    public func recordGeometry(renderParam: UnsafeMutableRawPointer?,
                               view: Matrix4,
                               projection: Matrix4)
    {
      // rerecord the synced meshes into the capture buffer.
      if let renderParam, let captureBuffer
      {
        AkariSceneRecordCapture(renderParam, UnsafeMutableRawPointer(captureBuffer), view.m, projection.m)
      }

      // set the per frame view matrix.
      runtime.setViewMatrix(view.m)
    }

    /// Sets the deferred lighting stage state: the split sum IBL toggle and
    /// the inverse projection the resolve shader reconstructs world space
    /// positions with.
    ///
    /// - Parameters:
    ///   - iblEnabled: gates the split sum IBL lobes.
    ///   - projection: 16 row-major floats, view->clip.
    public func setLighting(iblEnabled: Bool, projection: Matrix4)
    {
      var iblOn: Float = iblEnabled ? 1 : 0
      runtime.setUniform("u_iblEnabled", UInt32(GL_FLOAT), &iblOn)

      let invProj = Self.mat4Inverse(projection.m)
      invProj.withUnsafeBufferPointer
      { buf in
        runtime.setUniform("u_invProj", UInt32(GL_FLOAT_MAT4), buf.baseAddress)
      }
    }

    /// Sets the tonemap stage state: exposure, gamma,
    /// view transform, and the dithering frame seed.
    ///
    /// - Parameters:
    ///   - exposure: exposure setting the tonemap pass reads.
    ///   - gamma: gamma setting the tonemap pass reads.
    ///   - viewTransform: (e.g. AgX) setting the tonemap pass reads.
    ///   - frameIndex: per frame counter to seed the dither.
    public func setTonemap(exposure: Float,
                           gamma: Float,
                           viewTransform: Int32,
                           frameIndex: UInt64)
    {
      var expV = exposure
      runtime.setUniform("exposure", UInt32(GL_FLOAT), &expV)

      var gammaV = gamma
      runtime.setUniform("gamma", UInt32(GL_FLOAT), &gammaV)

      var vtV = Float(viewTransform)
      runtime.setUniform("viewTransform", UInt32(GL_FLOAT), &vtV)

      var fIdx = Int32(frameIndex & 0xFFFF)
      runtime.setUniform("frameIndex", UInt32(GL_INT), &fIdx)
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

      // pin the IBL generation targets to fixed 2:1 / square resolutions so
      // the shaders texel<->direction mapping is the standard equirect that
      // is independent of the window size.
      runtime.setBufferSize("env", 512, 256)
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

      buffer: env
        has depth: no
        textures:
          [ env, f16x4, scale: 0.25 ]

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

      pass: env gen
        draw: quad
        depth test: never
        write depth: no
        use shader: env-gen
        outputs: env [ env ]

      pass: prefilter 0
        draw: quad
        depth test: never
        write depth: no
        use shader: prefilter-lvl0
        inputs: [env.env]
        outputs: pref0 [ pref0 ]

      pass: prefilter 1
        draw: quad
        depth test: never
        write depth: no
        use shader: prefilter-lvl1
        inputs: [env.env]
        outputs: pref1 [ pref1 ]

      pass: prefilter 2
        draw: quad
        depth test: never
        write depth: no
        use shader: prefilter-lvl2
        inputs: [env.env]
        outputs: pref2 [ pref2 ]

      pass: prefilter 3
        draw: quad
        depth test: never
        write depth: no
        use shader: prefilter-lvl3
        inputs: [env.env]
        outputs: pref3 [ pref3 ]

      pass: prefilter 4
        draw: quad
        depth test: never
        write depth: no
        use shader: prefilter-lvl4
        inputs: [env.env]
        outputs: pref4 [ pref4 ]

      pass: prefilter 5
        draw: quad
        depth test: never
        write depth: no
        use shader: prefilter-lvl5
        inputs: [env.env]
        outputs: pref5 [ pref5 ]

      pass: irradiance gen
        draw: quad
        depth test: never
        write depth: no
        use shader: irradiance-gen
        inputs: [env.env]
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
                 env.env, pref0.pref0, pref1.pref1,
                 pref2.pref2, pref3.pref3, pref4.pref4,
                 pref5.pref5, irradiance.irradiance, dfg.dfg]
        outputs: color [ final ]

      pass: tonemap
        draw: quad
        depth test: never
        write depth: no
        use shader: tonemap
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

      shader: env-gen
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

          struct AkariSkyPerezParameters {
            float horizonDarkening;
            float horizonScattering;
            float solarIntensity;
            float solarWidth;
            float backscattering;
          };
          
          // Preetham 1999 analytic sky (https://dl.acm.org/doi/pdf/10.1145/311535.311545)
          float AkariSkyPerez(AkariSkyPerezParameters params, float theta, float gamma)
          {
            float cosTheta = cos(theta);
            float cosGamma = cos(gamma);

            float horizonGradient = 1.0 + params.horizonDarkening * exp(params.horizonScattering / max(cosTheta, 1e-5));
            float solarScattering = 1.0 + params.solarIntensity * exp(params.solarWidth * gamma) + params.backscattering * cosGamma * cosGamma;
            
            return horizonGradient * solarScattering;
          }
          
          vec3 AkariSkyColor(vec3 dir)
          {
            const vec3 sunDir = normalize(vec3(0.4, 0.8, 0.5));
            const float T = 2.2;
            const float T2 = T * T;

            float theta = 1.57079632679 - atan(dir.y, length(dir.xz));
            float phi = atan(dir.x, dir.z);

            float suntheta = acos(clamp(sunDir.y, -1.0, 1.0));
            float sunphi = atan(sunDir.x, sunDir.z);

            float cospsi = sin(theta) * sin(suntheta) * cos(phi - sunphi) +
                           cos(theta) * cos(suntheta);
            float gamma = acos(clamp(cospsi, -1.0, 1.0));

            float ts = suntheta;
            float ts2 = ts * ts;
            float ts3 = ts2 * ts;
            float chi = (4.0 / 9.0 - T / 120.0) * (PI - 2.0 * ts);
            
            // 2012 Kol analytical sky simulation (https://timothykol.com/pub/sky.pdf)
            // section (3.2) the Preetham model, functions of turbidity and solar elevation
            // for absolute zenith values.
            vec3 radiance;
            radiance.x = ((4.0453 * T - 4.9710) * tan(chi) - 0.2155 * T + 2.4192) * 0.06;
            radiance.y = (0.00166 * ts3 - 0.00375 * ts2 + 0.00209 * ts) * T2 +
                         (-0.02903 * ts3 + 0.06377 * ts2 - 0.03202 * ts + 0.00394) * T +
                         (0.11693 * ts3 - 0.21196 * ts2 + 0.06052 * ts + 0.25886);
            radiance.z = (0.00275 * ts3 - 0.00610 * ts2 + 0.00317 * ts) * T2 +
                         (-0.04214 * ts3 + 0.08970 * ts2 - 0.04153 * ts + 0.00516) * T +
                         (0.15346 * ts3 - 0.26756 * ts2 + 0.06670 * ts + 0.26688);

            // 2012 Kol analytical sky simulation (https://timothykol.com/pub/sky.pdf)
            // section (3.2) the Preetham model, functions of turbidity resulted from
            // the fitting process (for the chromaticity values x and y, part of the
            // CIE xyY color space).

            AkariSkyPerezParameters cfgY = { 
              0.1787 * T - 1.4630,  // horizonDarkening
              -0.3554 * T + 0.4275, // horizonScattering
              -0.0227 * T + 5.3251, // solarIntensity
              0.1206 * T - 2.5771,  // solarWidth
              -0.0670 * T + 0.3703  // backscattering
            };

            AkariSkyPerezParameters cfgx = {
              -0.0193 * T - 0.2592, // horizonDarkening
              -0.0665 * T + 0.0008, // horizonScattering
              -0.0004 * T + 0.2125, // solarIntensity
              -0.0641 * T - 0.8989, // solarWidth
              -0.0033 * T + 0.0452  // backscattering
            };

            AkariSkyPerezParameters cfgy = {
              -0.0167 * T - 0.2608, // horizonDarkening
              -0.0950 * T + 0.0092, // horizonScattering
              -0.0079 * T + 0.2102, // solarIntensity
              -0.0441 * T - 1.6537, // solarWidth
              -0.0109 * T + 0.0529  // backscattering
            };

            radiance.x /= AkariSkyPerez(cfgY, 0.0, ts);
            radiance.y /= AkariSkyPerez(cfgx, 0.0, ts);
            radiance.z /= AkariSkyPerez(cfgy, 0.0, ts);

            theta = min(theta, 1.57079632679 - 0.001);

            float Y = radiance.x * AkariSkyPerez(cfgY, theta, gamma);
            float x = radiance.y * AkariSkyPerez(cfgx, theta, gamma);
            float y = radiance.z * AkariSkyPerez(cfgy, theta, gamma);

            float X = (y != 0.0) ? (x / y) * Y : 0.0;
            float Z = (y != 0.0 && Y != 0.0) ? ((1.0 - x - y) / y) * Y : 0.0;
            
            // IEC 61966-2-1:1999 / Lindbloom conversion from CIE XYZ to sRGB
            // (http://www.brucelindbloom.com/index.html?Eqn_RGB_XYZ_Matrix.html)
            mat3 color = mat3(
              vec3(3.2404542, -0.9692660, 0.0556434),
              vec3(-1.5371385, 1.8760108, -0.2040259),
              vec3(-0.4985314, 0.0415560, 1.0572252)
            ) * vec3(X, Y, Z);
                                    
            return max(color, vec3(0.0));
          }

          void main()
          {
            vec2 uv = var.texCoord;
            float theta = uv.y * PI;
            float phi = (uv.x - 0.5) * 2.0 * PI;
            vec3 dir = vec3(sin(theta) * sin(phi), cos(theta), sin(theta) * cos(phi));
            o_env_texture = vec4(AkariSkyColor(dir), 1.0);
          }
          ```

          source msl:
          ```msl
          constexpr constant float PI = 3.1415926536;

          struct AkariSkyPerezParameters {
            float horizonDarkening;
            float horizonScattering;
            float solarIntensity;
            float solarWidth;
            float backscattering;
          };
          
          // Preetham 1999 analytic sky (https://dl.acm.org/doi/pdf/10.1145/311535.311545)
          float AkariSkyPerez(AkariSkyPerezParameters params, float theta, float gamma)
          {
            float cosTheta = cos(theta);
            float cosGamma = cos(gamma);
            
            float horizonGradient = 1.0 + params.horizonDarkening * exp(params.horizonScattering / max(cosTheta, 1e-5));
            float solarScattering = 1.0 + params.solarIntensity * exp(params.solarWidth * gamma) + params.backscattering * cosGamma * cosGamma;
            
            return horizonGradient * solarScattering;
          }

          float3 AkariSkyColor(float3 dir)
          {
            const float3 sunDir = normalize(float3(0.4, 0.8, 0.5));
            const float T = 2.2;
            const float T2 = T * T;

            float theta = 1.57079632679 - atan2(dir.y, length(float2(dir.x, dir.z)));
            float phi = atan2(dir.x, dir.z);

            float suntheta = acos(clamp(sunDir.y, -1.0, 1.0));
            float sunphi = atan2(sunDir.x, sunDir.z);

            float cospsi = sin(theta) * sin(suntheta) * cos(phi - sunphi) +
                           cos(theta) * cos(suntheta);
            float gamma = acos(clamp(cospsi, -1.0, 1.0));

            float ts = suntheta;
            float ts2 = ts * ts;
            float ts3 = ts2 * ts;
            float chi = (4.0 / 9.0 - T / 120.0) * (PI - 2.0 * ts);

            // 2012 Kol analytical sky simulation (https://timothykol.com/pub/sky.pdf)
            // section (3.2) the Preetham model, functions of turbidity and solar elevation
            // for absolute zenith values.
            float3 radiance;
            radiance.x = ((4.0453 * T - 4.9710) * tan(chi) - 0.2155 * T + 2.4192) * 0.06;
            radiance.y = (0.00166 * ts3 - 0.00375 * ts2 + 0.00209 * ts) * T2 +
                         (-0.02903 * ts3 + 0.06377 * ts2 - 0.03202 * ts + 0.00394) * T +
                         (0.11693 * ts3 - 0.21196 * ts2 + 0.06052 * ts + 0.25886);
            radiance.z = (0.00275 * ts3 - 0.00610 * ts2 + 0.00317 * ts) * T2 +
                         (-0.04214 * ts3 + 0.08970 * ts2 - 0.04153 * ts + 0.00516) * T +
                         (0.15346 * ts3 - 0.26756 * ts2 + 0.06670 * ts + 0.26688);

            // 2012 Kol analytical sky simulation (https://timothykol.com/pub/sky.pdf)
            // section (3.2) the Preetham model, functions of turbidity resulted from
            // the fitting process (for the chromaticity values x and y, part of the
            // CIE xyY color space).

            AkariSkyPerezParameters cfgY = { 
              0.1787 * T - 1.4630,  // horizonDarkening
              -0.3554 * T + 0.4275, // horizonScattering
              -0.0227 * T + 5.3251, // solarIntensity
              0.1206 * T - 2.5771,  // solarWidth
              -0.0670 * T + 0.3703  // backscattering
            };

            AkariSkyPerezParameters cfgx = {
              -0.0193 * T - 0.2592, // horizonDarkening
              -0.0665 * T + 0.0008, // horizonScattering
              -0.0004 * T + 0.2125, // solarIntensity
              -0.0641 * T - 0.8989, // solarWidth
              -0.0033 * T + 0.0452  // backscattering
            };

            AkariSkyPerezParameters cfgy = {
              -0.0167 * T - 0.2608, // horizonDarkening
              -0.0950 * T + 0.0092, // horizonScattering
              -0.0079 * T + 0.2102, // solarIntensity
              -0.0441 * T - 1.6537, // solarWidth
              -0.0109 * T + 0.0529  // backscattering
            };

            radiance.x /= AkariSkyPerez(cfgY, 0.0, ts);
            radiance.y /= AkariSkyPerez(cfgx, 0.0, ts);
            radiance.z /= AkariSkyPerez(cfgy, 0.0, ts);

            theta = min(theta, 1.57079632679 - 0.001);

            float Y = radiance.x * AkariSkyPerez(cfgY, theta, gamma);
            float x = radiance.y * AkariSkyPerez(cfgx, theta, gamma);
            float y = radiance.z * AkariSkyPerez(cfgy, theta, gamma);

            float X = (y != 0.0) ? (x / y) * Y : 0.0;
            float Z = (y != 0.0 && Y != 0.0) ? ((1.0 - x - y) / y) * Y : 0.0;

            // IEC 61966-2-1:1999 / Lindbloom conversion from CIE XYZ to sRGB
            // (http://www.brucelindbloom.com/index.html?Eqn_RGB_XYZ_Matrix.html)
            float3 color = float3x3(
              float3(3.2404542, -0.9692660, 0.0556434),
              float3(-1.5371385, 1.8760108, -0.2040259),
              float3(-0.4985314, 0.0415560, 1.0572252)
            ) * float3(X, Y, Z);
                                    
            return max(color, float3(0.0));
          }

          //@main
          {
            float2 uv = var.texCoord;
            float theta = uv.y * PI;
            float phi = (uv.x - 0.5) * 2.0 * PI;
            float3 dir = float3(sin(theta) * sin(phi), cos(theta), sin(theta) * cos(phi));
            o_env_texture = float4(AkariSkyColor(dir), 1.0);
          }
          ```

      shader: prefilter-lvl0
        uniforms: [ u_env_texture: sampler2d ]
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
                vec3 value = texture(u_env_texture, dirToUV(L)).rgb;
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
                float3 value = texture(u_env_texture, dirToUV(L)).rgb;
                color += value * dotNL;
                totalWeight += dotNL;
              }
            }
            o_pref0_texture = float4(color / max(totalWeight, 1e-4), 1.0);
          }
          ```

      shader: prefilter-lvl1
        uniforms: [ u_env_texture: sampler2d ]
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
                vec3 value = texture(u_env_texture, dirToUV(L)).rgb;
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
                float3 value = texture(u_env_texture, dirToUV(L)).rgb;
                color += value * dotNL;
                totalWeight += dotNL;
              }
            }
            o_pref1_texture = float4(color / max(totalWeight, 1e-4), 1.0);
          }
          ```

      shader: prefilter-lvl2
        uniforms: [ u_env_texture: sampler2d ]
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
                vec3 value = texture(u_env_texture, dirToUV(L)).rgb;
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
                float3 value = texture(u_env_texture, dirToUV(L)).rgb;
                color += value * dotNL;
                totalWeight += dotNL;
              }
            }
            o_pref2_texture = float4(color / max(totalWeight, 1e-4), 1.0);
          }
          ```

      shader: prefilter-lvl3
        uniforms: [ u_env_texture: sampler2d ]
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
                vec3 value = texture(u_env_texture, dirToUV(L)).rgb;
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
                float3 value = texture(u_env_texture, dirToUV(L)).rgb;
                color += value * dotNL;
                totalWeight += dotNL;
              }
            }
            o_pref3_texture = float4(color / max(totalWeight, 1e-4), 1.0);
          }
          ```

      shader: prefilter-lvl4
        uniforms: [ u_env_texture: sampler2d ]
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
                vec3 value = texture(u_env_texture, dirToUV(L)).rgb;
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
                float3 value = texture(u_env_texture, dirToUV(L)).rgb;
                color += value * dotNL;
                totalWeight += dotNL;
              }
            }
            o_pref4_texture = float4(color / max(totalWeight, 1e-4), 1.0);
          }
          ```

      shader: prefilter-lvl5
        uniforms: [ u_env_texture: sampler2d ]
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
                vec3 value = texture(u_env_texture, dirToUV(L)).rgb;
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
                float3 value = texture(u_env_texture, dirToUV(L)).rgb;
                color += value * dotNL;
                totalWeight += dotNL;
              }
            }
            o_pref5_texture = float4(color / max(totalWeight, 1e-4), 1.0);
          }
          ```

      shader: irradiance-gen
        uniforms: [ u_env_texture: sampler2d ]
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
                color += texture(u_env_texture, dirToUV(sampleVector)).rgb *
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
                color += texture(u_env_texture, dirToUV(sampleVector)).rgb *
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
                    u_env_texture: sampler2d,
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
                    u_invProj: mat4 ]
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

          vec2 dirToUV(vec3 dir)
          {
            float horiz2 = dir.x * dir.x + dir.z * dir.z;
            float u = (horiz2 > 1e-12)
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
                vec3 sky = texture(u_env_texture, dirToUV(worldDir)).rgb;
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

            vec3 color = vec3(0.0);
            vec3 L = normalize(vec3(0.4, 0.8, 0.5));
            float NoL = max(dot(N, L), 0.0);
            if (NoL > 0.0) {
              vec3 H = normalize(V + L);
              float NoH = max(dot(N, H), 0.0);
              float LoH = max(dot(L, H), 0.0);
              float D = D_GGX(roughness, NoH);
              float Vis = V_SmithGGXCorrelatedFast(roughness, NoV, NoL);
              vec3 F = F_Schlick(f0, LoH);
              vec3 Fr = D * Vis * F;
              vec3 Fd = diffuseColor / PI;
              color += (Fd + Fr) * NoL * vec3(1.0, 0.97, 0.92) * 5.0;
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
            float fracLod = lod - l0;
            vec2 ruv = dirToUV(r);
            vec3 pr0;
            if (l0 < 0.5) pr0 = texture(u_pref0_texture, ruv).rgb;
            else if (l0 < 1.5) pr0 = texture(u_pref1_texture, ruv).rgb;
            else if (l0 < 2.5) pr0 = texture(u_pref2_texture, ruv).rgb;
            else if (l0 < 3.5) pr0 = texture(u_pref3_texture, ruv).rgb;
            else if (l0 < 4.5) pr0 = texture(u_pref4_texture, ruv).rgb;
            else pr0 = texture(u_pref5_texture, ruv).rgb;
            vec3 pr1;
            if (l0 < 0.5) pr1 = texture(u_pref1_texture, ruv).rgb;
            else if (l0 < 1.5) pr1 = texture(u_pref2_texture, ruv).rgb;
            else if (l0 < 2.5) pr1 = texture(u_pref3_texture, ruv).rgb;
            else if (l0 < 3.5) pr1 = texture(u_pref4_texture, ruv).rgb;
            else pr1 = texture(u_pref5_texture, ruv).rgb;
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

          float2 dirToUV(float3 dir)
          {
            float horiz2 = dir.x * dir.x + dir.z * dir.z;
            float u = (horiz2 > 1e-12)
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
                float3 sky = texture(u_env_texture, dirToUV(worldDir)).rgb;
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

              float3 color = float3(0.0);

              float3 L = normalize(float3(0.4, 0.8, 0.5));
              float NoL = max(dot(N, L), 0.0);
              if (NoL > 0.0) {
                float3 H = normalize(V + L);
                float NoH = max(dot(N, H), 0.0);
                float LoH = max(dot(L, H), 0.0);
                float D = D_GGX(roughness, NoH);
                float Vis = V_SmithGGXCorrelatedFast(roughness, NoV, NoL);
                float3 F = F_Schlick(f0, LoH);
                float3 Fr = D * Vis * F;
                float3 Fd = diffuseColor / PI;
                color += (Fd + Fr) * NoL * float3(1.0, 0.97, 0.92) * 5.0;
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
              float fracLod = lod - l0;
              float2 ruv = dirToUV(r);
              float3 pr0;
              if (l0 < 0.5) pr0 = texture(u_pref0_texture, ruv).rgb;
              else if (l0 < 1.5) pr0 = texture(u_pref1_texture, ruv).rgb;
              else if (l0 < 2.5) pr0 = texture(u_pref2_texture, ruv).rgb;
              else if (l0 < 3.5) pr0 = texture(u_pref3_texture, ruv).rgb;
              else if (l0 < 4.5) pr0 = texture(u_pref4_texture, ruv).rgb;
              else pr0 = texture(u_pref5_texture, ruv).rgb;
              float3 pr1;
              if (l0 < 0.5) pr1 = texture(u_pref1_texture, ruv).rgb;
              else if (l0 < 1.5) pr1 = texture(u_pref2_texture, ruv).rgb;
              else if (l0 < 2.5) pr1 = texture(u_pref3_texture, ruv).rgb;
              else if (l0 < 3.5) pr1 = texture(u_pref4_texture, ruv).rgb;
              else pr1 = texture(u_pref5_texture, ruv).rgb;
              float3 prefilteredRadiance = mix(pr0, pr1, fracLod);
              float3 Fr = E * prefilteredRadiance * energyCompensation;

              float3 irradiance = texture(u_irradiance_texture, dirToUV(N)).rgb;
              float3 Fd = diffuseColor * irradiance * (1.0 - E);

              color += (Fd + Fr) * u_iblEnabled;

              o_final_texture = float4(color, 1.0);
            }
          }
          ```

      shader: tonemap
        uniforms: [ u_final_texture: sampler2d,
                    exposure: float,
                    gamma: float,
                    viewTransform: float,
                    frameIndex: int,
                    u_resolution: vec2 <- auto-resolution,
                    u_framebuffer_to_rec2020: mat3 <- auto-tonemap-framebuffer,
                    u_rec2020_to_display: mat3 <- auto-tonemap-display ]
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

          const mat3 AgXInset = mat3(
            0.856627153315983, 0.137318972929847, 0.11189821299995,
            0.0951212405381588, 0.761241990602591, 0.0767994186031903,
            0.0482516061458583, 0.101439036467562, 0.811302368396859);

          const mat3 AgXOutset = mat3(
            1.12710058, -0.14132976, -0.14132976,
            -0.11060664,  1.1578237, -0.11060664,
            -0.01649394, -0.01649394,  1.25193641);

          const float AgxMinEv = -12.47393;
          const float AgxMaxEv = 4.026069;

          vec3 agxContrastApprox(vec3 x)
          {
            vec3 x2 = x * x;
            vec3 x4 = x2 * x2;
            vec3 x6 = x4 * x2;
            return -17.86 * x6 * x
                 + 78.01 * x6
                 - 126.7 * x4 * x
                 + 92.06 * x4
                 - 28.72 * x2 * x
                 + 4.361 * x2
                 - 0.1718 * x
                 + 0.002857;
          }

          vec3 agx(vec3 v)
          {
            v = max(v, vec3(0.0));
            v = AgXInset * v;
            v = max(v, vec3(1E-10));
            v = log2(v);
            v = (v - AgxMinEv) / (AgxMaxEv - AgxMinEv);
            v = clamp(v, 0.0, 1.0);
            v = agxContrastApprox(v);
            v = AgXOutset * v;
            v = pow(max(v, vec3(0.0)), vec3(2.2));
            return v;
          }

          const mat3 Rec2020_to_AP0 = mat3(
            0.66868028, 0.04490008, 0.0,
            0.15181768, 0.86216027, 0.02782752,
            0.17716327, 0.10190731, 1.0515471);

          const mat3 AP0_to_AP1 = mat3(
            1.4514393161, -0.0765537734, 0.0083161484,
            -0.2365107469, 1.1762296998, -0.0060324498,
            -0.2149285693, -0.0996759264, 0.9977163014);

          const mat3 AP1_to_Rec2020 = mat3(
            1.0417988, -0.00168309, -0.00521046,
            -0.01074163, 1.00035025, -0.02264483,
            -0.00696194, -0.00140818, 0.95244411);

          const mat3 AP1_to_XYZ = mat3(
            0.6624541811, 0.2722287168, -0.0055746495,
            0.1340042065, 0.6740817658, 0.0040607335,
            0.1561876870, 0.0536895174, 1.0103391003);

          const mat3 XYZ_to_AP1 = mat3(
            1.6410233797, -0.6636628587, 0.0117218943,
            -0.3248032942, 1.6153315917, -0.0082844420,
            -0.2364246952, 0.0167563477, 0.9883948585);

          const vec3 LUMINANCE_AP1 = vec3(0.272229, 0.674082, 0.0536895);

          float rgb2Saturation(vec3 rgb)
          {
            float mi = min(rgb.r, min(rgb.g, rgb.b));
            float ma = max(rgb.r, max(rgb.g, rgb.b));
            return (max(ma, 1e-5) - max(mi, 1e-5)) / max(ma, 1e-2);
          }

          float rgb2YC(vec3 rgb)
          {
            float chroma = sqrt(rgb.b * (rgb.b - rgb.g) +
                                rgb.g * (rgb.g - rgb.r) +
                                rgb.r * (rgb.r - rgb.b));
            return (rgb.b + rgb.g + rgb.r + 1.75 * chroma) / 3.0;
          }

          float sigmoidShaper(float x)
          {
            float t = max(1.0 - abs(x / 2.0), 0.0);
            return (1.0 + sign(x) * (1.0 - t * t)) / 2.0;
          }

          float glowFwd(float ycIn, float glowGainIn, float glowMid)
          {
            if (ycIn <= 2.0 / 3.0 * glowMid) {
              return glowGainIn;
            }
            if (ycIn >= 2.0 * glowMid) {
              return 0.0;
            }
            return glowGainIn * (glowMid / ycIn - 0.5);
          }

          float rgb2Hue(vec3 rgb)
          {
            if (rgb.x == rgb.y && rgb.y == rgb.z) {
              return 0.0;
            }
            float hue = 57.2957795 * atan(sqrt(3.0) * (rgb.y - rgb.z),
                                          2.0 * rgb.x - rgb.y - rgb.z);
            return (hue < 0.0) ? hue + 360.0 : hue;
          }

          float centerHue(float hue, float centerH)
          {
            float h = hue - centerH;
            if (h < -180.0) {
              h += 360.0;
            } else if (h > 180.0) {
              h -= 360.0;
            }
            return h;
          }

          vec3 darkSurroundToDimSurround(vec3 linearCV)
          {
            const float DIM_SURROUND_GAMMA = 0.9811;
            vec3 xyz = AP1_to_XYZ * linearCV;

            // xyY chromaticities, guarded against pure black (0/0).
            float sum = max(xyz.x + xyz.y + xyz.z, 1e-5);
            float x = xyz.x / sum;
            float y = xyz.y / sum;

            float Y = pow(clamp(xyz.y, 0.0, 65504.0), DIM_SURROUND_GAMMA);
            float a = Y / max(y, 1e-5);

            return XYZ_to_AP1 * vec3(x * a, Y, (1.0 - x - y) * a);
          }

          vec3 aces(vec3 color)
          {
            const float RRT_GLOW_GAIN = 0.05;
            const float RRT_GLOW_MID = 0.08;
            const float RRT_RED_SCALE = 0.82;
            const float RRT_RED_PIVOT = 0.03;
            const float RRT_RED_HUE = 0.0;
            const float RRT_RED_WIDTH = 135.0;
            const float RRT_SAT_FACTOR = 0.96;
            const float ODT_SAT_FACTOR = 0.93;

            vec3 ap0 = Rec2020_to_AP0 * color;

            float saturation = rgb2Saturation(ap0);
            float ycIn = rgb2YC(ap0);
            float s = sigmoidShaper((saturation - 0.4) / 0.2);
            ap0 *= 1.0 + glowFwd(ycIn, RRT_GLOW_GAIN * s, RRT_GLOW_MID);

            float hueWeight = smoothstep(0.0, 1.0,
              1.0 - abs(2.0 * centerHue(rgb2Hue(ap0), RRT_RED_HUE) / RRT_RED_WIDTH));
            hueWeight *= hueWeight;
            ap0.r += hueWeight * saturation * (RRT_RED_PIVOT - ap0.r) *
                     (1.0 - RRT_RED_SCALE);

            vec3 ap1 = clamp(AP0_to_AP1 * ap0, vec3(0.0), vec3(65504.0));
            ap1 = mix(vec3(dot(ap1, LUMINANCE_AP1)), ap1, RRT_SAT_FACTOR);

            const float a = 2.785085;
            const float b = 0.107772;
            const float c = 2.936045;
            const float d = 0.887122;
            const float e = 0.806889;
            vec3 rgbPost = (ap1 * (a * ap1 + b)) / (ap1 * (c * ap1 + d) + e);

            vec3 linearCV = darkSurroundToDimSurround(rgbPost);
            linearCV = mix(vec3(dot(linearCV, LUMINANCE_AP1)), linearCV, ODT_SAT_FACTOR);
            return AP1_to_Rec2020 * linearCV;
          }

          vec3 filmic(vec3 x)
          {
            return (x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14);
          }

          vec3 pbrNeutral(vec3 color)
          {
            const float startCompression = 0.8 - 0.04;
            const float desaturation = 0.15;
            float x = min(color.r, min(color.g, color.b));
            float offset = x < 0.08 ? x - 6.25 * x * x : 0.04;
            color -= offset;

            float peak = max(color.r, max(color.g, color.b));
            if (peak < startCompression) {
              return color;
            }

            const float d = 1.0 - startCompression;
            float newPeak = 1.0 - d * d / (peak + d - startCompression);
            color *= newPeak / peak;

            float g = 1.0 - 1.0 / (desaturation * (peak - newPeak) + 1.0);
            return mix(color, vec3(newPeak), g);
          }

          vec3 srgbEncode(vec3 c)
          {
            vec3 lo = c * 12.92;
            vec3 hi = 1.055 * pow(max(c, vec3(0.0)), vec3(1.0 / 2.4)) - 0.055;
            return vec3(c.r <= 0.0031308 ? lo.r : hi.r,
                        c.g <= 0.0031308 ? lo.g : hi.g,
                        c.b <= 0.0031308 ? lo.b : hi.b);
          }

          float ditherNoise(vec2 fragCoord, int frameIndex)
          {
            vec3 p3 = fract(vec3(fragCoord.x, fragCoord.y, float(frameIndex)) * 0.1031);
            p3 += dot(p3, p3.yzx + 33.33);
            return fract((p3.x + p3.y) * p3.z);
          }

          void main()
          {
            vec4 hdr = texture(u_final_texture, var.texCoord);

            vec3 c = hdr.rgb * pow(2.0, exposure);

            c = u_framebuffer_to_rec2020 * c;

            int vt = int(viewTransform);
            if (vt == 0) {
              // AgX (default).
              c = agx(c);
              c = u_rec2020_to_display * c;
            } else if (vt == 1) {
              // Filmic.
              c = filmic(c);
              c = u_rec2020_to_display * c;
              c = srgbEncode(c);
            } else if (vt == 2) {
              // ACES.
              c = aces(c);
              c = u_rec2020_to_display * c;
              c = srgbEncode(c);
            } else if (vt == 3) {
              // Khronos PBR Neutral.
              c = pbrNeutral(c);
              c = u_rec2020_to_display * c;
              c = srgbEncode(c);
            } else {
              // Standard.
              c = clamp(c, 0.0, 1.0);
              c = u_rec2020_to_display * c;
              c = srgbEncode(c);
            }

            // post transform gamma trim (default 1.0 = untouched).
            c = pow(max(c, vec3(0.0)), vec3(1.0 / gamma));

            // dither before the 8-bit AOV write to hide banding.
            c += (ditherNoise(var.texCoord * u_resolution, frameIndex) - 0.5) / 255.0;

            o_tonemap_texture = vec4(c, hdr.a);
          }
          ```

          source msl:
          ```msl

          float3 agxContrastApprox(float3 x)
          {
            float3 x2 = x * x;
            float3 x4 = x2 * x2;
            float3 x6 = x4 * x2;
            return -17.86 * x6 * x
                 + 78.01 * x6
                 - 126.7 * x4 * x
                 + 92.06 * x4
                 - 28.72 * x2 * x
                 + 4.361 * x2
                 - 0.1718 * x
                 + 0.002857;
          }

          float3 agx(float3 v)
          {
            const float3x3 AgXInset = float3x3(
              float3(0.856627153315983, 0.137318972929847, 0.11189821299995),
              float3(0.0951212405381588, 0.761241990602591, 0.0767994186031903),
              float3(0.0482516061458583, 0.101439036467562, 0.811302368396859)
            );
            const float3x3 AgXOutset = float3x3(
              float3(1.12710058, -0.14132976, -0.14132976),
              float3(-0.11060664, 1.1578237, -0.11060664),
              float3(-0.01649394, -0.01649394, 1.25193641)
            );
            const float AgxMinEv = -12.47393;
            const float AgxMaxEv = 4.026069;

            v = max(v, float3(0.0));
            v = AgXInset * v;
            v = max(v, float3(1E-10));
            v = log2(v);
            v = (v - AgxMinEv) / (AgxMaxEv - AgxMinEv);
            v = clamp(v, 0.0, 1.0);
            v = agxContrastApprox(v);
            v = AgXOutset * v;
            v = pow(max(v, float3(0.0)), float3(2.2));
            return v;
          }

          float rgb2Saturation(float3 rgb)
          {
            float mi = min(rgb.r, min(rgb.g, rgb.b));
            float ma = max(rgb.r, max(rgb.g, rgb.b));
            return (max(ma, 1e-5) - max(mi, 1e-5)) / max(ma, 1e-2);
          }

          float rgb2YC(float3 rgb)
          {
            float chroma = sqrt(rgb.b * (rgb.b - rgb.g) +
                                rgb.g * (rgb.g - rgb.r) +
                                rgb.r * (rgb.r - rgb.b));
            return (rgb.b + rgb.g + rgb.r + 1.75 * chroma) / 3.0;
          }

          float sigmoidShaper(float x)
          {
            float t = max(1.0 - abs(x / 2.0), 0.0);
            return (1.0 + sign(x) * (1.0 - t * t)) / 2.0;
          }

          float glowFwd(float ycIn, float glowGainIn, float glowMid)
          {
            if (ycIn <= 2.0 / 3.0 * glowMid) {
              return glowGainIn;
            }
            if (ycIn >= 2.0 * glowMid) {
              return 0.0;
            }
            return glowGainIn * (glowMid / ycIn - 0.5);
          }

          float rgb2Hue(float3 rgb)
          {
            if (rgb.x == rgb.y && rgb.y == rgb.z) {
              return 0.0;
            }
            float hue = 57.2957795 * atan2(sqrt(3.0) * (rgb.y - rgb.z),
                                           2.0 * rgb.x - rgb.y - rgb.z);
            return (hue < 0.0) ? hue + 360.0 : hue;
          }

          float centerHue(float hue, float centerH)
          {
            float h = hue - centerH;
            if (h < -180.0) {
              h += 360.0;
            } else if (h > 180.0) {
              h -= 360.0;
            }
            return h;
          }

          float3 darkSurroundToDimSurround(float3 linearCV)
          {
            const float DIM_SURROUND_GAMMA = 0.9811;
            const float3x3 AP1_to_XYZ = float3x3(
              float3(0.6624541811, 0.2722287168, -0.0055746495),
              float3(0.1340042065, 0.6740817658, 0.0040607335),
              float3(0.1561876870, 0.0536895174, 1.0103391003)
            );
            const float3x3 XYZ_to_AP1 = float3x3(
              float3(1.6410233797, -0.6636628587, 0.0117218943),
              float3(-0.3248032942, 1.6153315917, -0.0082844420),
              float3(-0.2364246952, 0.0167563477, 0.9883948585)
            );

            float3 xyz = AP1_to_XYZ * linearCV;

            // xyY chromaticities, guarded against pure black (0/0).
            float sum = max(xyz.x + xyz.y + xyz.z, 1e-5);
            float x = xyz.x / sum;
            float y = xyz.y / sum;

            float Y = pow(clamp(xyz.y, 0.0, 65504.0), DIM_SURROUND_GAMMA);
            float a = Y / max(y, 1e-5);

            return XYZ_to_AP1 * float3(x * a, Y, (1.0 - x - y) * a);
          }

          float3 aces(float3 color)
          {
            const float3x3 Rec2020_to_AP0 = float3x3(
              float3(0.66868028, 0.04490008, 0.0),
              float3(0.15181768, 0.86216027, 0.02782752),
              float3(0.17716327, 0.10190731, 1.0515471)
            );
            const float3x3 AP0_to_AP1 = float3x3(
              float3(1.4514393161, -0.0765537734, 0.0083161484),
              float3(-0.2365107469, 1.1762296998, -0.0060324498),
              float3(-0.2149285693, -0.0996759264, 0.9977163014)
            );
            const float3x3 AP1_to_Rec2020 = float3x3(
              float3(1.0417988, -0.00168309, -0.00521046),
              float3(-0.01074163, 1.00035025, -0.02264483),
              float3(-0.00696194, -0.00140818, 0.95244411)
            );
            const float3 LUMINANCE_AP1 = float3(0.272229, 0.674082, 0.0536895);
            const float RRT_GLOW_GAIN = 0.05;
            const float RRT_GLOW_MID = 0.08;
            const float RRT_RED_SCALE = 0.82;
            const float RRT_RED_PIVOT = 0.03;
            const float RRT_RED_HUE = 0.0;
            const float RRT_RED_WIDTH = 135.0;
            const float RRT_SAT_FACTOR = 0.96;
            const float ODT_SAT_FACTOR = 0.93;

            float3 ap0 = Rec2020_to_AP0 * color;

            float saturation = rgb2Saturation(ap0);
            float ycIn = rgb2YC(ap0);
            float s = sigmoidShaper((saturation - 0.4) / 0.2);
            ap0 *= 1.0 + glowFwd(ycIn, RRT_GLOW_GAIN * s, RRT_GLOW_MID);

            float hueWeight = smoothstep(0.0, 1.0,
              1.0 - abs(2.0 * centerHue(rgb2Hue(ap0), RRT_RED_HUE) / RRT_RED_WIDTH));
            hueWeight *= hueWeight;
            ap0.r += hueWeight * saturation * (RRT_RED_PIVOT - ap0.r) *
                     (1.0 - RRT_RED_SCALE);

            float3 ap1 = clamp(AP0_to_AP1 * ap0, float3(0.0), float3(65504.0));
            ap1 = mix(float3(dot(ap1, LUMINANCE_AP1)), ap1, RRT_SAT_FACTOR);

            const float a = 2.785085;
            const float b = 0.107772;
            const float c = 2.936045;
            const float d = 0.887122;
            const float e = 0.806889;
            float3 rgbPost = (ap1 * (a * ap1 + b)) / (ap1 * (c * ap1 + d) + e);

            float3 linearCV = darkSurroundToDimSurround(rgbPost);
            linearCV = mix(float3(dot(linearCV, LUMINANCE_AP1)), linearCV, ODT_SAT_FACTOR);
            return AP1_to_Rec2020 * linearCV;
          }

          float3 filmic(float3 x)
          {
            return (x * (2.51 * x + 0.03)) / (x * (2.43 * x + 0.59) + 0.14);
          }

          float3 pbrNeutral(float3 color)
          {
            const float startCompression = 0.8 - 0.04;
            const float desaturation = 0.15;
            float x = min(color.r, min(color.g, color.b));
            float offset = x < 0.08 ? x - 6.25 * x * x : 0.04;
            color -= offset;

            float peak = max(color.r, max(color.g, color.b));
            if (peak < startCompression) {
              return color;
            }

            const float d = 1.0 - startCompression;
            float newPeak = 1.0 - d * d / (peak + d - startCompression);
            color *= newPeak / peak;

            float g = 1.0 - 1.0 / (desaturation * (peak - newPeak) + 1.0);
            return mix(color, float3(newPeak), g);
          }

          float3 srgbEncode(float3 c)
          {
            float3 lo = c * 12.92;
            float3 hi = 1.055 * pow(max(c, float3(0.0)), float3(1.0 / 2.4)) - 0.055;
            return float3(c.r <= 0.0031308 ? lo.r : hi.r,
                          c.g <= 0.0031308 ? lo.g : hi.g,
                          c.b <= 0.0031308 ? lo.b : hi.b);
          }

          float ditherNoise(float2 fragCoord, int frameIndex)
          {
            float3 p3 = fract(float3(fragCoord.x, fragCoord.y, float(frameIndex)) * 0.1031);
            p3 += dot(p3, p3.yzx + 33.33);
            return fract((p3.x + p3.y) * p3.z);
          }

          //@main
          {
            float4 hdr = texture(u_final_texture, var.texCoord);

            float3 c = hdr.rgb * pow(2.0, exposure);

            c = u_framebuffer_to_rec2020 * c;

            int vt = int(viewTransform + 0.5);
            if (vt == 0) {
              // AgX (default)
              c = agx(c);
              c = u_rec2020_to_display * c;
            } else if (vt == 1) {
              // Filmic.
              c = filmic(c);
              c = u_rec2020_to_display * c;
              c = srgbEncode(c);
            } else if (vt == 2) {
              // ACES.
              c = aces(c);
              c = u_rec2020_to_display * c;
              c = srgbEncode(c);
            } else if (vt == 3) {
              // Khronos PBR Neutral.
              c = pbrNeutral(c);
              c = u_rec2020_to_display * c;
              c = srgbEncode(c);
            } else {
              // Standard.
              c = clamp(c, 0.0, 1.0);
              c = u_rec2020_to_display * c;
              c = srgbEncode(c);
            }

            // post transform gamma trim (default 1.0 = untouched).
            c = pow(max(c, float3(0.0)), float3(1.0));

            // dither before the 8-bit AOV write to hide banding.
            c += (ditherNoise(var.texCoord * u_resolution, frameIndex) - 0.5) / 255.0;

            o_tonemap_texture = float4(c, hdr.a);
          }
          ```
      """
  }
}
