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
 *    copyright  notice,  this  list  of  conditions  and  the  following
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
 * MERCHANTABILITY   AND   FITNESS FOR A PARTICULAR PURPOSE ARE
 * DISCLAIMED.   IN  NO  EVENT SHALL THE COPYRIGHT HOLDER OR
 * CONTRIBUTORS  BE  LIABLE  FOR  ANY  DIRECT, INDIRECT, INCIDENTAL,
 * SPECIAL,  EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
 * LIMITED  TO,  PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF
 * USE,  DATA,  OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED
 * AND  ON  ANY  THEORY  OF  LIABILITY,  WHETHER  IN CONTRACT, STRICT
 * LIABILITY,  OR  TORT (INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN
 * ANY  WAY  OUT  OF  THE  USE  OF  THIS SOFTWARE, EVEN IF ADVISED OF
 * THE  POSSIBILITY OF SUCH DAMAGE.
 *
 *                               Copyright (C) 2026 Wabi Foundation.
 *                                              All rights reserved.
 * -----------------------------------------------------------------
 *  . x x x . o o o . x x x . : : : .    o  x  o    . : : : .
 * ----------------------------------------------------------------- */

import AkariCore
import Foundation
import LabFX
import LabGL

extension Akari.LabFXEngine
{
  /// Light probe bake progress bar, drawn from a `callback:` pass.
  final class ProbeBakeOverlay
  {
    private var shader: GLuint = 0
    /// Written by `update` on the render thread, read by `draw`.
    private var enabled = false
    private weak var probes: Akari.LightProbes?

    /// Hooks the overlay's draw into the deferred graph's `draw-probe-bake` pass.
    func attach(to deferred: inout lab.fx.Runtime)
    {
      shader = gl.precompileShader(name: "akari-probe-bake",
                                   vertexGLSL: Self.vertexGLSL,
                                   fragmentGLSL: Self.fragmentGLSL,
                                   vertexMSL: Self.msl,
                                   fragmentMSL: nil)
      deferred.setPassCallback("draw-probe-bake",
                               callback: akariProbeBakeDrawCallback,
                               userdata: Unmanaged.passUnretained(self).toOpaque())
    }

    /// Tracks the feature flag and the probe state the bar reads.
    func update(enabled: Bool, probes: Akari.LightProbes?)
    {
      self.enabled = enabled
      self.probes = enabled ? probes : nil
    }

    func release()
    {
      if shader != 0
      {
        gl.deleteShader(shader)
        shader = 0
      }
      probes = nil
      enabled = false
    }

    fileprivate func draw(width: Int32, height: Int32)
    {
      guard enabled, shader != 0, let probes else { return }
      let total = probes.captureTotal
      guard total > 0, probes.captured < total || !probes.isReady else { return }
      
      let progress = min(max(Float(probes.captured) / Float(total), 0), 1)
      
      let x0: Float = 0.63
      let x1: Float = 0.95
      let y0: Float = -0.93
      let y1: Float = -0.894

      let borderX = Float(3) / Float(width)
      let borderY = Float(3) / Float(height)

      gl.useShader(shader)

      gl.color(red: Float(1), green: Float(1), blue: Float(1), alpha: Float(0.10))
      roundedOutline(x0, y0, x1, y1, radius: 0.004, outX: borderX, outY: borderY)

      gl.color(red: Float(0), green: Float(0), blue: Float(0), alpha: Float(0.55))
      roundedQuad(x0, y0, x1, y1, radius: 0.004)

      if progress > 0
      {
        gl.color(red: Float(0), green: Float(0.478), blue: Float(1), alpha: Float(0.85))
        let fillX = x0 + (x1 - x0) * progress
        roundedQuad(x0, y0, fillX, y1, radius: 0.004)
        text("Baking light probes: \(probes.captured / 6)/\(total / 6) · \(Int((progress * 100).rounded()))%",
             x: x0, y: y0, width: width, height: height)
      }

      gl.color(red: Float(1), green: Float(1), blue: Float(1), alpha: Float(1))
      gl.useShader(0)
    }

    private static let fontPath: String? = {
      let path = Bundle.fonts.url(forResource: "CascadiaMono", withExtension: "ttf")?.path
      if path == nil { print("[akari/fonts] CascadiaMono.ttf missing from the LabGL bundle") }
      return path
    }()

    /// Draws text flat on screen.
    private func text(_ text: String, x: Float, y: Float, width: Int32, height: Int32)
    {
      guard width > 0, height > 0, let fontPath = Self.fontPath else { return }

      let px = (x + Float(1)) / Float(2) * Float(width) + Float(8)
      let py = (Float(1) - y) / Float(2) * Float(height) - Float(10)

      gl.matrixMode(GL_PROJECTION)
      gl.loadIdentity()
      gl.ortho(left: 0, right: Double(width), bottom: Double(height), top: 0, near: -1, far: 1)
      gl.matrixMode(GL_MODELVIEW)
      gl.loadIdentity()

      gl.disable(GL_CULL_FACE)

      gl.font(path: fontPath, pointSize: 12)
      gl.begin(mode: GL_FONT)
      gl.color(red: Float(1), green: Float(1), blue: Float(1), alpha: Float(1))
      gl.text(x: px, y: py, z: Float(0), text)
      gl.end()

      gl.enable(GL_CULL_FACE)
    }
    
    /// Two triangles in clip space.
    private func quad(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float)
    {
      gl.begin(mode: GL_TRIANGLES)
      gl.vertex(x: x0, y: y0, z: Float(0))
      gl.vertex(x: x1, y: y0, z: Float(0))
      gl.vertex(x: x1, y: y1, z: Float(0))
      gl.vertex(x: x0, y: y0, z: Float(0))
      gl.vertex(x: x1, y: y1, z: Float(0))
      gl.vertex(x: x0, y: y1, z: Float(0))
      gl.end()
    }

    private static let cornerArcs: [[(Float, Float)]] = {
      let arcSteps = 6

      return [
        -Float.pi / 2, 0,
         Float.pi / 2,
         Float.pi
      ].map
      { start in
        (0...arcSteps).map
        { i in
          let a = start + Float(i) * (Float.pi / 2) / Float(arcSteps)
          return (cos(a), sin(a))
        }
      }
    }()

    private func roundedQuad(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float, radius: Float)
    {
      let r = min(radius, (y1 - y0) * 0.5, (x1 - x0) * 0.5)
      guard r > 0 else
      {
        quad(x0, y0, x1, y1)
        return
      }

      let centers: [(Float, Float)] = [
        (x1 - r, y0 + r),
        (x1 - r, y1 - r),
        (x0 + r, y1 - r),
        (x0 + r, y0 + r),
      ]

      gl.begin(mode: GLenum(GL_TRIANGLE_FAN))
      gl.vertex(x: (x0 + x1) * 0.5, y: (y0 + y1) * 0.5, z: Float(0))
      for (center, arc) in zip(centers, Self.cornerArcs)
      {
        for (u, v) in arc
        {
          gl.vertex(x: center.0 + r * u, y: center.1 + r * v, z: Float(0))
        }
      }
      gl.vertex(x: x1 - r, y: y0, z: Float(0))
      gl.end()
    }

    private func roundedOutline(_ x0: Float, _ y0: Float, _ x1: Float, _ y1: Float,
                                radius: Float, outX: Float, outY: Float)
    {
      let r = min(radius, (y1 - y0) * 0.5, (x1 - x0) * 0.5)
      guard r > 0 else { return }

      let centers: [(Float, Float)] = [
        (x1 - r, y0 + r), (x1 - r, y1 - r), (x0 + r, y1 - r), (x0 + r, y0 + r),
      ]

      gl.begin(mode: GLenum(GL_TRIANGLE_STRIP))
      for (center, arc) in zip(centers, Self.cornerArcs)
      {
        for (u, v) in arc
        {
          gl.vertex(x: center.0 + r * u, y: center.1 + r * v, z: Float(0))
          gl.vertex(x: center.0 + (r + outX) * u, y: center.1 + (r + outY) * v, z: Float(0))
        }
      }
      let (u0, v0) = Self.cornerArcs[0][0]
      gl.vertex(x: centers[0].0 + r * u0, y: centers[0].1 + r * v0, z: Float(0))
      gl.vertex(x: centers[0].0 + (r + outX) * u0, y: centers[0].1 + (r + outY) * v0, z: Float(0))
      gl.end()
    }

    private static let vertexGLSL = """
      #version 330 core
      layout(location = 0) in vec4 a_position;
      layout(location = 1) in vec4 a_color;
      layout(location = 2) in vec2 a_texcoord;
      layout(location = 3) in vec3 a_normal;
      out vec4 v_color;
      void main()
      {
        v_color = a_color;
        gl_Position = a_position;
      }
      """

    private static let fragmentGLSL = """
      #version 330 core
      layout(location = 0) in vec4 v_color;
      layout(location = 0) out vec4 o_color;
      void main()
      {
        o_color = v_color;
      }
      """

    private static let msl = """
      #include <metal_stdlib>
      using namespace metal;

      struct VertIn
      {
        float4 a_position [[attribute(0)]];
        float4 a_color    [[attribute(1)]];
        float2 a_texcoord [[attribute(2)]];
        float3 a_normal   [[attribute(3)]];
      };

      struct VertOut
      {
        float4 position [[position]];
        float4 color    [[user(locn0)]];
      };

      vertex VertOut vert_main(VertIn in [[stage_in]])
      {
        VertOut out;
        out.position = in.a_position;
        out.color = in.a_color;
        return out;
      }

      fragment float4 frag_main(VertOut in [[stage_in]])
      {
        return in.color;
      }
      """
  }
}

/// `Runtime.setPassCallback` takes a plain C function pointer.
private func akariProbeBakeDrawCallback(_ userdata: UnsafeMutableRawPointer?, _ width: Int32, _ height: Int32)
{
  guard let userdata else { return }
  Unmanaged<Akari.LabFXEngine.ProbeBakeOverlay>.fromOpaque(userdata)
    .takeUnretainedValue().draw(width: width, height: height)
}
