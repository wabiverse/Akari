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
import LabGL

extension Akari.LabFXEngine
{
  /// draws the glass into each glass light's tile of the shared atlases in one replay amplified into a view per light
  final class GlassMaps
  {
    enum Map: String, CaseIterable
    {
      case near, far, transmit
    }

    private var shaders: [Map: GLuint] = [:]
    private var views: GLuint = 0
    private var viewports: GLuint = 0

    /// each light's direction or position per view, one buffer per frame so a frame in flight keeps its own
    private var lightBuffers: [GLuint] = []
    private var ring = 0
    private var failed = false

    func precompileShaders()
    {
      guard shaders.isEmpty, !failed else { return }
      for map in Map.allCases
      {
        shaders[map] = Akari.ShaderSource.shader("akari-glass-\(map.rawValue)", msl: Self.msl(map), owner: self)
        { owner, fresh in
          defer { owner.shaders[map] = fresh }
          return owner.shaders[map] ?? 0
        }
      }
    }

    /// waits for the shaders the first time, returns false for good if they failed
    private func prepare() -> Bool
    {
      if failed { return false }

      precompileShaders()
      if views != 0 { return true }
      guard shaders.values.allSatisfy({ gl.waitShader($0) != 0 })
      else
      {
        print("[akari/glass] glass map shaders failed to compile, glass casts no tinted light")
        failed = true
        return false
      }

      views = gl.genInstanceTransforms(count: GLsizei(Akari.ShadowAtlas.maxAmplificationViews))
      viewports = gl.genInstanceViewports(count: GLsizei(Akari.ShadowAtlas.maxAmplificationViews))
      lightBuffers = (0 ..< 3).map
      { _ in
        gl.createBuffer(usage: LGL_BUFFER_VERTEX | LGL_BUFFER_MAP_WRITE,
                        sizeBytes: GLsizei(Akari.RenderGraph.GlassAtlas.tiles * MemoryLayout<SIMD4<Float>>.stride))
      }

      guard views != 0, viewports != 0, !lightBuffers.contains(0)
      else
      {
        print("[akari/glass] glass map buffers failed to allocate, glass casts no tinted light")
        failed = true
        return false
      }

      return true
    }

    /// writes this frame's lights in the order `draw` replays them
    func upload(_ frames: [GlassFrame])
    {
      guard !frames.isEmpty, prepare() else { return }

      ring = (ring + 1) % lightBuffers.count
      guard let lights = gl.mapBuffer(lightBuffers[ring])?.assumingMemoryBound(to: SIMD4<Float>.self) else { return }

      for (index, frame) in frames.enumerated() { lights[index] = frame.light }
      gl.unmapBuffer(lightBuffers[ring])
    }

    /// replays `capture` once per run of lights into the current pass's glass atlas
    func draw(_ map: Map, frames: [GlassFrame], capture: LabGLCaptureBuffer,
              materials: (material: GLuint, color: GLuint, constants: GLuint), styles: GLuint, ior: Float)
    {
      guard
        !frames.isEmpty, prepare(), let shader = shaders[map],
        materials.material != 0, materials.color != 0, materials.constants != 0, styles != 0
      else { return }

      gl.useShader(shader)

      // the far map needs back faces and the replay skips the capture state that keeps culling off
      gl.disable(GL_CULL_FACE)

      // labgl lays uniforms out in the order they are first set, which has to match `U`
      gl.setShaderUniform(shader, .viewBase, Int32(0))
      gl.setShaderUniform(shader, .ior, ior)
      gl.setShaderImageArgument(shader, bufferIndex: 5, texture: materials.material)
      gl.setShaderImageArgument(shader, bufferIndex: 6, texture: materials.color)
      gl.setShaderImageArgument(shader, bufferIndex: 7, texture: materials.constants)
      gl.setShaderImageArgument(shader, bufferIndex: 8, texture: styles)
      gl.setShaderVertexBuffer(shader, index: 7, buffer: lightBuffers[ring])

      let tile = Int32(Akari.RenderGraph.GlassAtlas.tile)
      for start in stride(from: 0, to: frames.count, by: Akari.ShadowAtlas.maxAmplificationViews)
      {
        let run = frames[start ..< min(start + Akari.ShadowAtlas.maxAmplificationViews, frames.count)]
        var transforms: [Float] = []
        var rects: [Int32] = []
        for frame in run
        {
          frame.matrix.withUnsafeFloats { transforms.append(contentsOf: $0) }
          let origin = Akari.RenderGraph.GlassAtlas.origin(frame.tile)
          rects += [Int32(origin.x), Int32(origin.y), tile, tile]
        }

        transforms.withUnsafeBufferPointer
        {
          gl.instanceTransformsData(handle: views, size: GLsizei($0.count * MemoryLayout<Float>.size),
                                    transforms: $0.baseAddress, cullRadius: 0, usage: GL_STATIC_DRAW)
        }

        rects.withUnsafeBufferPointer
        {
          gl.instanceViewportsData(handle: viewports, size: GLsizei($0.count * MemoryLayout<Int32>.size),
                                   viewports: $0.baseAddress, usage: GL_STATIC_DRAW)
        }

        gl.setShaderUniform(shader, .viewBase, Int32(start))
        gl.setVertexAmplification(viewsHandle: views, viewportsHandle: viewports, count: GLsizei(run.count))

        // only the glass draws are encoded with the deform, or every draw when that could not encode
        labgl.capturePlaybackCulled(capture, slot: Akari.LabFXEngine.glassDrawSlot)
        gl.disableVertexAmplification()
      }

      gl.useShader(0)
    }

    func release()
    {
      for shader in shaders.values where shader != 0 { gl.deleteShader(shader) }
      shaders = [:]

      if views != 0 { gl.deleteInstanceTransforms(count: 1, handles: &views) }
      if viewports != 0 { gl.deleteInstanceViewports(count: 1, handles: &viewports) }
      for buffer in lightBuffers where buffer != 0 { gl.deleteBuffer(buffer) }

      views = 0
      viewports = 0
      lightBuffers = []
    }

    // MARK: shaders

    /// the vertex stage every entry labgl picks from shares, and the map's own fragment stage
    private static func msl(_ map: Map) -> String
    {
      #"""
      #include <metal_stdlib>
      using namespace metal;

      struct VertIn
      {
        float4 a_position [[attribute(0)]];
        float4 a_color    [[attribute(1)]];
        float2 a_texcoord [[attribute(2)]];
        float3 a_normal   [[attribute(3)]];
      };

      struct U
      {
        int u_viewBase;
        float u_ior;
      };

      struct VertOut
      {
        float4 position [[position]];
        float3 posWorld [[user(glass_pos)]];
        float3 normalWorld [[user(glass_normal)]];
        float2 uv [[user(glass_uv)]];
        float primId [[user(glass_prim)]];
        float4 vcolor [[user(glass_vcolor)]];
        float4 light [[user(glass_light)]];
      };

      struct Image
      {
        texture2d<float> image [[id(0)]];
      };

      static VertOut glassVertex(VertIn in, float4x4 model, float4x4 toMap, float4 light)
      {
        VertOut out;
        float4 world = model * float4(in.a_position.xyz, 1.0);
        out.posWorld = world.xyz;
        out.normalWorld = (model * float4(in.a_normal, 0.0)).xyz;
        out.uv = in.a_texcoord;
        out.primId = in.a_color.r;
        float packed = in.a_texcoord.x < 0.0 ? in.a_texcoord.y - 1.0 : -1.0;
        out.vcolor = packed >= 0.0 ? float4(floor(packed / 65536.0), fmod(floor(packed / 256.0), 256.0), fmod(packed, 256.0), 255.0) / 255.0
                                   : float4(0.0);
        out.light = light;
        out.position = toMap * world;
        \#(map == .far ? "// flipping reversed depth keeps the farthest glass\n  out.position.z = out.position.w - out.position.z;" : "")
        return out;
      }

      vertex VertOut vert_main(VertIn in [[stage_in]],
                               constant float4x4* viewsXf [[buffer(1)]],
                               constant U& u [[buffer(2)]],
                               const device float4* lights [[buffer(7)]])
      {
        return glassVertex(in, float4x4(1.0), viewsXf[0], lights[u.u_viewBase]);
      }

      vertex VertOut vert_indirect_main(VertIn in [[stage_in]],
                                        constant float4x4* viewsXf [[buffer(1)]],
                                        constant U& u [[buffer(2)]],
                                        constant float4x4& model [[buffer(4)]],
                                        const device float4* lights [[buffer(7)]])
      {
        return glassVertex(in, model, viewsXf[0], lights[u.u_viewBase]);
      }

      vertex VertOut vert_amplified_main(VertIn in [[stage_in]],
                                         constant float4x4* viewsXf [[buffer(1)]],
                                         constant U& u [[buffer(2)]],
                                         const device float4* lights [[buffer(7)]],
                                         ushort ampId [[amplification_id]])
      {
        return glassVertex(in, float4x4(1.0), viewsXf[ampId], lights[u.u_viewBase + int(ampId)]);
      }

      vertex VertOut vert_amplified_indirect_main(VertIn in [[stage_in]],
                                                  constant float4x4* viewsXf [[buffer(1)]],
                                                  constant U& u [[buffer(2)]],
                                                  constant float4x4& model [[buffer(4)]],
                                                  const device float4* lights [[buffer(7)]],
                                                  ushort ampId [[amplification_id]])
      {
        return glassVertex(in, model, viewsXf[ampId], lights[u.u_viewBase + int(ampId)]);
      }

      \#(Akari.RenderGraph.ShaderLibrary.glassSurfaceMSL)

      \#(fragmentMSL(map))
      """#
    }

    private static func fragmentMSL(_ map: Map) -> String
    {
      let output: String
      let body: String
      switch map
      {
        case .near:
          output = "struct Out { float4 surface [[color(0)]]; float4 normal [[color(1)]]; };"
          body = "return { float4(in.posWorld, glassDistance(in)), float4(normalize(in.normalWorld), 1.0) };"
        case .far:
          output = "struct Out { float distance [[color(0)]]; float4 normal [[color(1)]]; };"
          body = "return { glassDistance(in), float4(normalize(in.normalWorld), 1.0) };"
        case .transmit:
          output = "struct Out { float4 transmit [[color(0)]]; };"
          body = #"""
            float alpha = surface.a;

            // what each surface's tint and opacity let through, the trace removes what reflects at the angles its rays cross
            float3 transmit = (1.0 - alpha) * mix(float3(1.0), surface.rgb, 1.0 - alpha);
            return { float4(-log(max(transmit, float3(1e-4))), 1.0) };
            """#
      }

      return #"""
        \#(output)

        // distance from the light, or along the light direction for the sun
        static float glassDistance(VertOut in)
        {
          return in.light.w > 0.5 ? length(in.posWorld - in.light.xyz) : -dot(in.posWorld, in.light.xyz);
        }

        fragment Out frag_main(VertOut in [[stage_in]],
                               constant U& u [[buffer(2)]],
                               constant Image& materials [[buffer(5)]],
                               constant Image& colors [[buffer(6)]],
                               constant Image& constants [[buffer(7)]],
                               constant Image& styles [[buffer(8)]])
        {
          // only prims marked transparent in texel 4 of the style texture are glass, a glowing shell counts as light
          int id = int(in.primId + 0.5);
          int perRow = int(styles.image.get_width()) / 8;
          if (id < 0 || perRow <= 0 || id / perRow >= int(styles.image.get_height())) discard_fragment();
          float4 flags = styles.image.read(uint2((id % perRow) * 8 + 4, id / perRow));
          if (flags.y < 0.5 || flags.z > 0.5) discard_fragment();

          constexpr sampler linear(filter::linear, address::clamp_to_edge);
          float4 surface = glassSurface(in.uv, in.vcolor, materials.image, linear, colors.image, linear, constants.image);
          if (surface.a < 0.0) discard_fragment();
          \#(body)
        }
        """#
    }
  }

  /// the dynamic capture's culled slot for its glass draws, placed after the shadow atlas slots
  static let glassDrawSlot = UInt32(Akari.ShadowAtlas.cullSlotBase + Akari.ShadowAtlas.maxRuns + 1)

  /// draws one of the glass maps for every light that has glass maps this frame
  fileprivate func drawGlass(_ map: GlassMaps.Map)
  {
    guard
      geometry.deformer.hasGlass, !geometry.dynamicBatch.isEmpty, let capture = geometry.dynamicCapture
    else { return }

    let materials = probes.materials
    glassMaps.draw(map, frames: transparency.glass, capture: capture,
                   materials: (materials.material, materials.color, materials.constants), styles: styles.texture,
                   ior: Self.transparencyIOR)
  }

  func attachGlassMaps()
  {
    let userdata = Unmanaged.passUnretained(self).toOpaque()
    runtime.setPassCallback(.drawGlassNear, callback: akariDrawGlassNear, userdata: userdata)
    runtime.setPassCallback(.drawGlassFar, callback: akariDrawGlassFar, userdata: userdata)
    runtime.setPassCallback(.drawGlassTransmit, callback: akariDrawGlassTransmit, userdata: userdata)
  }
}

/// `Runtime.setPassCallback` takes plain c function pointers, one per map
private func engine(_ userdata: UnsafeMutableRawPointer?) -> Akari.LabFXEngine?
{
  userdata.map { Unmanaged<Akari.LabFXEngine>.fromOpaque($0).takeUnretainedValue() }
}

private func akariDrawGlassNear(_ userdata: UnsafeMutableRawPointer?, _: Int32, _: Int32)
{
  engine(userdata)?.drawGlass(.near)
}

private func akariDrawGlassFar(_ userdata: UnsafeMutableRawPointer?, _: Int32, _: Int32)
{
  engine(userdata)?.drawGlass(.far)
}

private func akariDrawGlassTransmit(_ userdata: UnsafeMutableRawPointer?, _: Int32, _: Int32)
{
  engine(userdata)?.drawGlass(.transmit)
}
