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
import LabFX
import LabGL

extension Akari.LabFXEngine
{
  /// Fireflies overlay with LabFX `callback:` passes + `latency:` ring buffers.
  final class Fireflies
  {
    private var graph: LabFXGraph?
    /// LabFX runtime instance this overlay lives on.
    private let runtime: UnsafeMutablePointer<lab.fx.Runtime>
    private var shader: GLuint = 0
    private let simulation = Akari.FireflySimulation()
    /// Read by `draw`.
    private var enabled = false

    init()
    {
      runtime = .allocate(capacity: 1)
      runtime.initialize(to: lab.fx.Runtime())
    }

    deinit
    {
      runtime.deinitialize(count: 1)
      runtime.deallocate()
    }

    /// Hooks the overlay's draw into the deferred graph's `draw-fireflies` pass.
    func attach(to deferred: inout lab.fx.Runtime)
    {
      shader = gl.precompileShader(name: "akari-firefly",
                                   vertexGLSL: Self.vertexGLSL, fragmentGLSL: Self.fragmentGLSL,
                                   vertexMSL: Self.msl, fragmentMSL: nil)
      deferred.setPassCallback("draw-fireflies", callback: akariFireflyDrawCallback,
                               userdata: Unmanaged.passUnretained(self).toOpaque())
    }

    func update(enabled: Bool)
    {
      self.enabled = enabled
      guard enabled else { simulation.stop(); return }
      guard ensureRing() else { return }
      runtime.pointee.render()
    }

    func release()
    {
      simulation.stop()
      runtime.pointee.destroy()
      if let graph
      {
        lab.fx.free(graph)
        self.graph = nil
      }
      if shader != 0
      {
        gl.deleteShader(shader)
        shader = 0
      }
    }

    private func ensureRing() -> Bool
    {
      if graph != nil { return true }

      guard
        let url = Bundle.akari.url(forResource: "Fireflies", withExtension: "labfx"),
        let source = try? String(contentsOf: url, encoding: .utf8)
      else
      {
        print("[akari/fireflies] Fireflies.labfx missing from bundle")
        return false
      }
      guard let parsed = lab.fx.parse(source, length: source.utf8.count)
      else
      {
        print("[akari/fireflies] labfx parse failed")
        return false
      }
      guard runtime.pointee.build(parsed, rootWidth: 1, rootHeight: 1)
      else
      {
        print("[akari/fireflies] runtime build failed")
        return false
      }
      graph = parsed

      runtime.pointee.setPassCallback("simulate", callback: akariFireflySimulateCallback,
                                      userdata: Unmanaged.passUnretained(self).toOpaque())
      simulation.start()
      return true
    }

    fileprivate func simulate()
    {
      guard simulation.refreshIfNeeded() else { return }
      let tex = runtime.pointee.writeTexture("fireflies", named: "state")
      guard tex != 0 else { return }

      var pixels = [Float](repeating: 0, count: Akari.FireflySimulation.count * 4)
      for (i, p) in simulation.current.enumerated()
      {
        pixels[i * 4 + 0] = p.x
        pixels[i * 4 + 1] = p.y
        pixels[i * 4 + 2] = p.z
        pixels[i * 4 + 3] = p.w
      }

      gl.bindTexture(target: GL_TEXTURE_2D, texture: tex)
      pixels.withUnsafeBufferPointer
      { buf in
        gl.texImage2D(target: GL_TEXTURE_2D,
                      level: 0,
                      internalFormat: GL_RGBA32F,
                      width: GLsizei(Akari.FireflySimulation.count),
                      height: 1,
                      border: 0,
                      format: GL_RGBA,
                      type: GL_FLOAT,
                      pixels: buf.baseAddress)
      }
    }

    fileprivate func draw()
    {
      guard enabled, shader != 0 else { return }
      gl.useShader(shader)
      gl.begin(mode: GL_TRIANGLES)
      let s: Float = 0.02
      for p in simulation.current
      {
        gl.vertex(x: p.x - s, y: p.y - s, z: Float(0))
        gl.vertex(x: p.x + s, y: p.y - s, z: Float(0))
        gl.vertex(x: p.x - s, y: p.y + s, z: Float(0))
        gl.vertex(x: p.x - s, y: p.y + s, z: Float(0))
        gl.vertex(x: p.x + s, y: p.y - s, z: Float(0))
        gl.vertex(x: p.x + s, y: p.y + s, z: Float(0))
      }
      gl.end()
      gl.useShader(0)
    }

    private static let vertexGLSL = """
      #version 330 core
      layout(location = 0) in vec4 a_position;
      void main()
      {
        gl_Position = a_position;
      }
      """

    private static let fragmentGLSL = """
      #version 330 core
      layout(location = 0) out vec4 o_color;
      void main()
      {
        o_color = vec4(1.0, 0.85, 0.3, 1.0);
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
      };

      vertex VertOut vert_main(VertIn in [[stage_in]])
      {
        VertOut out;
        out.position = in.a_position;
        return out;
      }

      fragment float4 frag_main(VertOut in [[stage_in]])
      {
        return float4(1.0, 0.85, 0.3, 1.0);
      }
      """
  }
}

/// `Runtime.setPassCallback` takes a plain C function pointer.
private func akariFireflySimulateCallback(_ userdata: UnsafeMutableRawPointer?, _: Int32, _: Int32)
{
  guard let userdata else { return }
  Unmanaged<Akari.LabFXEngine.Fireflies>.fromOpaque(userdata).takeUnretainedValue().simulate()
}

private func akariFireflyDrawCallback(_ userdata: UnsafeMutableRawPointer?, _: Int32, _: Int32)
{
  guard let userdata else { return }
  Unmanaged<Akari.LabFXEngine.Fireflies>.fromOpaque(userdata).takeUnretainedValue().draw()
}
