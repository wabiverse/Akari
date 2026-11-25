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
  /// caustics traced forward from each glass light, rays through its glass map land on the gbuffer and spread their light over the triangles between them
  final class GlassCaustics
  {
    /// rays per side of the grid over each light's glass map, which every glass object shares
    static let grid = 256
    /// bytes per traced ray, see the trace's `Bundle`.
    static let bundleBytes = 80
    /// vertices per grid cell, one quad around both its triangles and their sweep
    static let cellVertices = 6

    fileprivate enum Kernel: Akari.ComputeKernelName
    {
      case trace

      static let label = "glass"
      var glsl: String { "" }
      var msl: String { GlassCaustics.traceMSL }
      var threadgroup: SIMD3<Int> { SIMD3(64, 1, 1) }
    }

    private var kernels = Akari.ComputeKernels<Kernel>()
    private var meshShader: GLuint = 0
    /// `cellVertices` per grid cell, each carrying its cell's index and its corner.
    private var cells: GLuint = 0
    /// each glass light's rays, by its tile.
    private var bundles: [Int: GLuint] = [:]
    private var traced: Set<Int> = []
    private var failed = false
    private var frame: UInt32 = 0

    static var bundleCount: Int { grid * grid }

    func precompileShaders()
    {
      guard kernels.isEmpty, !failed else { return }
      kernels = .precompile()
      meshShader = Akari.ShaderSource.shader("akari-glass-mesh", msl: Self.meshMSL, owner: self)
      { owner, fresh in
        defer { owner.meshShader = fresh }
        return owner.meshShader
      }
    }

    /// waits for the kernel the first time, false for good if it failed.
    private func prepare() -> Bool
    {
      if failed { return false }
      precompileShaders()
      if !kernels.allBuilt
      {
        guard kernels.wait().isEmpty, meshShader != 0
        else
        {
          print("[akari/glass] caustic kernels failed to compile, glass casts no caustics")
          failed = true
          return false
        }
      }

      return true
    }

    /// a fresh offset for the grid every frame, which the caustic blend averages
    func advance()
    {
      traced = []
      frame &+= 1
    }

    /// traces a glass light's rays into its ray buffer.
    func trace(_ glass: GlassFrame, camera: (view: Akari.Matrix4, projection: Akari.Matrix4), textures: GlassTextures,
               screen: SIMD2<Float>, ior: Float)
    {
      let (near, far, transmit, gbuffer) = (textures.near, textures.far, textures.transmit, textures.gbuffer)
      guard
        prepare(),
        near.surface != 0, near.normal != 0, far.surface != 0, far.normal != 0, transmit != 0,
        gbuffer.position != 0, gbuffer.normal != 0
      else { return }

      if bundles[glass.tile] == nil
      {
        bundles[glass.tile] = gl.createBuffer(usage: LGL_BUFFER_COMPUTE_READ | LGL_BUFFER_COMPUTE_WRITE,
                                              sizeBytes: GLsizei(Self.bundleCount * Self.bundleBytes))
      }

      guard let buffer = bundles[glass.tile], buffer != 0 else { return }
      let origin = SIMD2<Float>(Akari.RenderGraph.GlassAtlas.origin(glass.tile))
      let tile = Float(Akari.RenderGraph.GlassAtlas.tile)
      let kernel = kernels[.trace]

      // labgl lays uniforms out in the order they're first set, the order of `U`
      kernel.set(.glassMatrix, glass.matrix)
      kernel.set(.view, camera.view)
      kernel.set(.proj, camera.projection)
      kernel.set(.glassLight, glass.light)
      kernel.set(.params, SIMD4<Float>(Float(Self.grid), ior, Float(frame % 4096), glass.size))
      kernel.set(.march, SIMD4<Float>(glass.reach, 48, screen.x, screen.y))
      kernel.set(.tile, SIMD4<Float>(origin.x, origin.y, tile, tile))
      kernel.set(.glassShapeX, glass.shape.x)
      kernel.set(.glassShapeY, glass.shape.y)
      kernel.bind(buffer)
      for (index, texture) in [near.surface, near.normal, far.surface, far.normal, transmit, gbuffer.position, gbuffer.normal].enumerated()
      {
        kernel.sample(texture, at: index)
      }

      kernel.dispatch((Self.bundleCount + 63) / 64)
      traced.insert(glass.tile)
    }

    /// draws a glass light's traced grid as triangles into the caustic texture the current pass adds to.
    func splat(_ glass: GlassFrame, camera: (view: Akari.Matrix4, projection: Akari.Matrix4),
               gbuffer: (position: GLuint, normal: GLuint), size: SIMD2<Float>)
    {
      // whatever rays this light has, traced this frame or standing by from the frame that last needed to.
      guard let buffer = bundles[glass.tile], ensureCells() else { return }
      gl.useShader(meshShader)
      gl.setShaderUniform(meshShader, .view, camera.view)
      gl.setShaderUniform(meshShader, .proj, camera.projection)
      gl.setShaderUniform(meshShader, .glassLight, glass.light)

      // a triangle stretched much past the glass's size spans a gap between surfaces rather than lying on one.
      gl.setShaderUniform(meshShader, .params, SIMD4<Float>(size.x, size.y, glass.reach * 0.15, Float(Self.grid)))
      gl.setShaderUniform(meshShader, .strength, glass.strength)
      gl.setShaderVertexBuffer(meshShader, index: 5, buffer: buffer)
      gl.setShaderImageArgument(meshShader, bufferIndex: 5, texture: gbuffer.position)
      gl.setShaderImageArgument(meshShader, bufferIndex: 6, texture: gbuffer.normal)

      let stride = GLsizei(Akari.Geom.Batch.vertexStride)
      let floatBytes = MemoryLayout<Float>.stride
      gl.bindBuffer(target: GL_ARRAY_BUFFER, buffer: cells)
      gl.enableClientState(GL_VERTEX_ARRAY)
      gl.enableClientState(GL_COLOR_ARRAY)
      gl.enableClientState(GL_TEXTURE_COORD_ARRAY)
      gl.enableClientState(GL_NORMAL_ARRAY)
      gl.vertexPointer(size: 4, type: GL_FLOAT, stride: stride, pointer: .init(bitPattern: 0))
      gl.colorPointer(size: 4, type: GL_FLOAT, stride: stride, pointer: .init(bitPattern: 4 * floatBytes))
      gl.texCoordPointer(size: 2, type: GL_FLOAT, stride: stride, pointer: .init(bitPattern: 8 * floatBytes))
      gl.normalPointer(type: GL_FLOAT, stride: stride, pointer: .init(bitPattern: 10 * floatBytes))
      gl.drawArrays(mode: GL_TRIANGLES, first: 0, count: GLsizei(Self.bundleCount * Self.cellVertices))
      gl.disableClientState(GL_NORMAL_ARRAY)
      gl.disableClientState(GL_TEXTURE_COORD_ARRAY)
      gl.disableClientState(GL_COLOR_ARRAY)
      gl.disableClientState(GL_VERTEX_ARRAY)
      gl.bindBuffer(target: GL_ARRAY_BUFFER, buffer: 0)
      gl.useShader(0)
    }

    private func ensureCells() -> Bool
    {
      if cells != 0 { return true }
      let floatsPerVertex = Akari.Geom.Batch.vertexStride / MemoryLayout<Float>.stride
      let vertexCount = Self.bundleCount * Self.cellVertices
      cells = gl.createBuffer(usage: LGL_BUFFER_VERTEX | LGL_BUFFER_MAP_WRITE,
                              sizeBytes: GLsizei(vertexCount * Akari.Geom.Batch.vertexStride))
      guard cells != 0, let p = gl.mapBuffer(cells)?.assumingMemoryBound(to: Float.self) else { return false }
      p.update(repeating: 0, count: vertexCount * floatsPerVertex)
      for vertex in 0 ..< vertexCount
      {
        p[vertex * floatsPerVertex] = Float(vertex / Self.cellVertices)
        p[vertex * floatsPerVertex + 1] = Float(vertex % Self.cellVertices)
      }

      gl.unmapBuffer(cells)
      return true
    }

    /// drops the rays traced through the scene that was shown before
    func forgetRays()
    {
      for buffer in bundles.values where buffer != 0 { gl.deleteBuffer(buffer) }
      bundles = [:]
      traced = []
    }

    func release()
    {
      kernels.release()
      if meshShader != 0 { gl.deleteShader(meshShader) }
      meshShader = 0
      for buffer in Array(bundles.values) + [cells] where buffer != 0 { gl.deleteBuffer(buffer) }
      bundles = [:]
      cells = 0
      traced = []
    }

    // MARK: Shaders

    /// one thread per grid corner, traced from the light's center and edges, writing where it lands, the light it carries and how it moves
    fileprivate static let traceMSL = #"""
      #include <metal_stdlib>
      using namespace metal;

      struct U
      {
        float4x4 glassMatrix;
        float4x4 view;
        float4x4 proj;
        float4 light;
        float4 params;
        float4 march;
        float4 tile;
        float4 shapeX;
        float4 shapeY;
      };

      struct Bundle
      {
        float4 hit;
        float4 power;
        float4 normal;
        float4 acrossX;
        float4 acrossY;
      };

      struct Maps
      {
        texture2d<float> farMap;
        texture2d<float> farNormal;
        texture2d<float> positions;
        texture2d<float> normals;
      };

      // distance from the light, along it for the sun.
      static float lightDistance(float3 p, float4 light)
      {
        return light.w > 0.5 ? length(p - light.xyz) : -dot(p, normalize(light.xyz));
      }

      // the texel of the light's tile, at origin and size texels wide, that p falls in.
      static uint2 mapTexel(float3 p, float4x4 m, uint2 origin, uint2 size, thread bool &inside)
      {
        float4 c = m * float4(p, 1.0);
        float2 uv = c.xy / max(c.w, 1e-6) * 0.5 + 0.5;
        inside = c.w > 1e-6 && all(uv >= 0.0) && all(uv < 1.0);
        return origin + min(uint2(max(uv, 0.0) * float2(size)), size - 1);
      }

      // two axes across axis.
      static void across(float3 axis, thread float3 &x, thread float3 &y)
      {
        float3 helper = abs(axis.y) < 0.99 ? float3(0.0, 1.0, 0.0) : float3(1.0, 0.0, 0.0);
        x = normalize(cross(helper, axis));
        y = cross(axis, x);
      }

      // how much light a surface lets through at an angle whose cosine is c, the rest reflecting away.
      static float transmitted(float c, float ior)
      {
        float f0 = (ior - 1.0) / (ior + 1.0);
        f0 *= f0;
        return 1.0 - (f0 + (1.0 - f0) * pow(1.0 - saturate(c), 5.0));
      }

      // refracts a ray in through the glass and out its far side, false when it reflects back, kept is the share of light the surfaces let through
      static bool through(constant U& u, Maps maps, float3 entry, float3 N0, float thickness, float3 incident,
                          uint2 origin, uint2 mapSize, thread float3 &start, thread float3 &direction, thread float &kept)
      {
        float ior = u.params.y;
        if (dot(N0, incident) > 0.0) N0 = -N0;
        float3 inside = refract(incident, N0, 1.0 / ior);
        start = entry;
        direction = incident;
        kept = transmitted(-dot(incident, N0), ior);
        if (dot(inside, inside) > 1e-6 && thickness > 0.0) {
          // steps along the refracted ray until it passes the far surface, then halves in on the crossing
          float along = max(dot(inside, incident), 0.2);
          float reach = 2.5 * thickness / along;
          float lo = 0.0, hi = reach;
          bool onMap = true;
          for (int k = 1; k <= 16; ++k) {
            float d = reach * float(k) / 16.0;
            float3 q = entry + inside * d;
            uint2 t = mapTexel(q, u.glassMatrix, origin, mapSize, onMap);
            if (!onMap || maps.farNormal.read(t).w < 0.5 || lightDistance(q, u.light) >= maps.farMap.read(t).r) { hi = d; break; }
            lo = d;
          }
          for (int k = 0; k < 6; ++k) {
            float mid = 0.5 * (lo + hi);
            float3 q = entry + inside * mid;
            uint2 t = mapTexel(q, u.glassMatrix, origin, mapSize, onMap);
            if (!onMap || maps.farNormal.read(t).w < 0.5 || lightDistance(q, u.light) >= maps.farMap.read(t).r) hi = mid; else lo = mid;
          }
          float3 exit = entry + inside * lo;

          // out of the glass at the far surface, unless it reflects back inside.
          uint2 t = mapTexel(exit, u.glassMatrix, origin, mapSize, onMap);
          float3 N1 = normalize(maps.farNormal.read(t).xyz);
          if (dot(N1, inside) < 0.0) N1 = -N1;
          float3 out = refract(inside, -N1, ior);
          if (dot(out, out) < 1e-6) return false;
          start = exit;
          direction = normalize(out);
          kept *= transmitted(dot(direction, N1), ior);
        }
        return true;
      }

      // refracts a ray through the glass and marches it across the screen until it passes behind the surface it lands on
      static bool land(constant U& u, Maps maps, float3 entry, float3 N0, float thickness, float3 incident,
                       uint2 origin, uint2 mapSize, thread float3 &hit, thread uint2 &landedPixel, thread float &kept)
      {
        float3 start, direction;
        if (!through(u, maps, entry, N0, thickness, incident, origin, mapSize, start, direction, kept)) return false;
        float3 eyeStart = (u.view * float4(start, 1.0)).xyz;
        float3 eyeDirection = normalize((u.view * float4(direction, 0.0)).xyz);
        float2 screen = u.march.zw;
        int steps = int(u.march.y);
        float reach = u.march.x;
        float before = 0.0;
        for (int k = 1; k <= steps; ++k) {
          float t = reach * float(k * k) / float(steps * steps);
          float3 q = eyeStart + eyeDirection * t;
          float4 c = u.proj * float4(q, 1.0);
          if (c.w <= 1e-4) return false;
          float2 suv = c.xy / c.w * 0.5 + 0.5;
          if (any(suv < 0.0) || any(suv >= 1.0)) return false;
          uint2 pixel = uint2(suv * screen);
          if (maps.normals.read(pixel).a < 0.5) { before = t; continue; }
          float sceneZ = maps.positions.read(pixel).z;
          if (q.z < sceneZ) {
            // passing behind something far in front isn't landing on it.
            if (sceneZ - q.z > max(t - before, 0.05 * abs(sceneZ))) return false;
            float lo = before, hi = t;
            landedPixel = pixel;
            for (int b = 0; b < 6; ++b) {
              float mid = 0.5 * (lo + hi);
              float3 m = eyeStart + eyeDirection * mid;
              float4 mc = u.proj * float4(m, 1.0);
              uint2 mp = uint2(clamp(mc.xy / mc.w * 0.5 + 0.5, 0.0, 0.9999) * screen);
              if (m.z < maps.positions.read(mp).z) { hi = mid; landedPixel = mp; } else lo = mid;
            }
            hit = start + direction * hi;
            return true;
          }
          before = t;
        }
        return false;
      }

      kernel void compute_main(constant U& u [[buffer(0)]],
                               device Bundle* bundles [[buffer(1)]],
                               texture2d<float> nearMap [[texture(0)]],
                               texture2d<float> nearNormal [[texture(1)]],
                               texture2d<float> farMap [[texture(2)]],
                               texture2d<float> farNormal [[texture(3)]],
                               texture2d<float> transmitMap [[texture(4)]],
                               texture2d<float> positions [[texture(5)]],
                               texture2d<float> normals [[texture(6)]],
                               uint id [[thread_position_in_grid]])
      {
        uint grid = uint(u.params.x);
        if (id >= grid * grid) return;
        Bundle bundle;
        bundle.hit = float4(0.0);
        bundle.power = float4(0.0);
        bundle.normal = float4(0.0);
        bundle.acrossX = float4(0.0);
        bundle.acrossY = float4(0.0);

        // the grid shifts by a fresh fraction of a cell each frame and the viewport blends them, so the caustics come from far more rays
        float2 shift = fract(0.5 + u.params.z * float2(0.7548776662, 0.5698402910));
        uint2 cell = uint2(id % grid, id / grid);
        float2 uv = (float2(cell) + shift) / float(grid);
        uint2 origin = uint2(u.tile.xy);
        uint2 mapSize = uint2(u.tile.zw);
        uint2 texel = origin + min(uint2(uv * float2(mapSize)), mapSize - 1);
        float4 n0 = nearNormal.read(texel);
        if (n0.w < 0.5) { bundles[id] = bundle; return; }

        float4 near = nearMap.read(texel);
        float3 entry = near.xyz;
        float3 N0 = normalize(n0.xyz);
        float thickness = farMap.read(texel).r - near.w;
        if (thickness <= 1e-4 * max(abs(near.w), 1.0)) thickness = 0.0;
        Maps maps = { farMap, farNormal, positions, normals };

        // the light's center and how far its width and height reach across the glass, a square as big as the disc for the sun
        float3 forward = normalize(float3(u.glassMatrix[0][3], u.glassMatrix[1][3], u.glassMatrix[2][3]));
        float distance = u.light.w > 0.5 ? length(entry - u.light.xyz) : 1.0;
        float3 halfX, halfY;
        float3 ax, ay;
        if (u.light.w > 0.5) {
          float tube = length(u.shapeX.xyz);
          across(tube > 0.0 ? normalize(cross(forward, u.shapeX.xyz / tube)) : forward, ax, ay);
          if (tube > 0.0) {
            halfX = u.shapeX.xyz;
            halfY = length(u.shapeY.xyz) > 0.0 ? u.shapeY.xyz : normalize(cross(forward, halfX)) * u.shapeX.w;
          } else {
            halfX = ax * u.shapeX.w * 0.886;
            halfY = ay * u.shapeX.w * 0.886;
          }
        } else {
          across(normalize(u.light.xyz), ax, ay);
          halfX = ax * u.params.w * 0.886;
          halfY = ay * u.params.w * 0.886;
        }

        float3 incident = u.light.w > 0.5 ? normalize(entry - u.light.xyz) : -normalize(u.light.xyz);
        float3 hit;
        uint2 landedPixel = uint2(0);
        float kept = 1.0;
        if (!land(u, maps, entry, N0, thickness, incident, origin, mapSize, hit, landedPixel, kept)) { bundles[id] = bundle; return; }

        // where the ray lands from the far edges of the light, so even a small light softens a caustic's edge and overlapping ones blend
        float3x3 rotate = float3x3(u.view[0].xyz, u.view[1].xyz, u.view[2].xyz);
        float3 surface = normalize(transpose(rotate) * normals.read(landedPixel).xyz);
        for (int axis = 0; axis < 2; ++axis) {
          float3 offset = axis == 0 ? halfX : halfY;
          if (length(offset) < 0.002 * distance) continue;
          float3 edge = u.light.w > 0.5 ? normalize(entry - u.light.xyz - offset) : -normalize(normalize(u.light.xyz) + offset);
          float3 start, direction;
          float edgeKept;
          if (!through(u, maps, entry, N0, thickness, edge, origin, mapSize, start, direction, edgeKept)) continue;
          float facing = dot(direction, surface);
          if (facing > -1e-3) continue;
          float3 moved = start + direction * (dot(hit - start, surface) / facing);
          float4 sweep = float4(2.0 * (moved - hit), 1.0);
          if (axis == 0) bundle.acrossX = sweep; else bundle.acrossY = sweep;
        }

        float3 row0 = float3(u.glassMatrix[0][0], u.glassMatrix[1][0], u.glassMatrix[2][0]);
        float3 row1 = float3(u.glassMatrix[0][1], u.glassMatrix[1][1], u.glassMatrix[2][1]);
        float cell2 = 2.0 / float(grid);

        // the light a grid cell carries, its solid angle or for the sun its cross section, through all the glass it crossed
        float carried = (cell2 / length(row0)) * (cell2 / length(row1));
        if (u.light.w > 0.5) {
          float facing = max(dot(incident, forward), 0.1);
          carried *= facing * facing * facing;
        }
        float3 tint = exp(-transmitMap.read(texel).rgb);
        bundle.hit = float4(hit, 1.0);
        bundle.power = float4(tint * carried * kept, 0.0);
        bundle.normal = float4(normalize(normals.read(landedPixel).xyz), 0.0);
        bundles[id] = bundle;
      }
      """#

    /// draws each grid cell's two triangles between where its corners landed, so gathered rays shrink them brighter and crossings add up into bright lines
    fileprivate static let meshMSL = #"""
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
        float4x4 view;
        float4x4 proj;
        float4 light;
        float4 params;
        float4 strength;
      };

      struct Bundle
      {
        float4 hit;
        float4 power;
        float4 normal;
        float4 acrossX;
        float4 acrossY;
      };

      // the cell's corners b, c and d from a in the surface's plane through a, each triangle's sweeps and light
      struct VertOut
      {
        float4 position [[position]];
        float3 a [[flat]];
        float2 b [[flat]];
        float2 c [[flat]];
        float2 d [[flat]];
        float4 sweep0 [[flat]];
        float4 sweep1 [[flat]];
        float3 planeX [[flat]];
        float3 planeY [[flat]];
        float3 irradiance0 [[flat]];
        float3 irradiance1 [[flat]];
        float2 q;
        float slack [[flat]];
      };

      struct GBufferImage
      {
        texture2d<float> image [[id(0)]];
      };

      constant float2 bounds[6] = { float2(0.0, 0.0), float2(1.0, 0.0), float2(1.0, 1.0),
                                    float2(0.0, 0.0), float2(1.0, 1.0), float2(0.0, 1.0) };

      static float cross2(float2 a, float2 b) { return a.x * b.y - a.y * b.x; }

      // corners on differently facing surfaces or spread far apart straddle a gap rather than lie on one surface
      static bool onOneSurface(Bundle a, Bundle b, Bundle c, float reach)
      {
        if (min(a.hit.w, min(b.hit.w, c.hit.w)) < 0.5) return false;
        if (min(dot(a.normal.xyz, b.normal.xyz), min(dot(a.normal.xyz, c.normal.xyz), dot(b.normal.xyz, c.normal.xyz))) < 0.8) return false;
        return max(distance(a.hit.xyz, b.hit.xyz), max(distance(a.hit.xyz, c.hit.xyz), distance(b.hit.xyz, c.hit.xyz))) <= reach;
      }

      // only sweeps every corner traced, so the triangle moves as one
      static float3 sweepOf(float4 a, float4 b, float4 c, float3x3 rotate)
      {
        return min(a.w, min(b.w, c.w)) > 0.5 ? rotate * (a.xyz + b.xyz + c.xyz) / 3.0 : float3(0.0);
      }

      vertex VertOut vert_main(VertIn in [[stage_in]],
                               constant U& u [[buffer(2)]],
                               const device Bundle* bundles [[buffer(5)]])
      {
        VertOut out = {};
        int grid = int(u.params.w);
        int index = int(in.a_position.x);
        int slot = int(in.a_position.y);
        int2 cell = int2(index % grid, index / grid);
        if (cell.x >= grid - 1 || cell.y >= grid - 1) return out;

        int base = cell.y * grid + cell.x;
        Bundle a = bundles[base];
        Bundle b = bundles[base + 1];
        Bundle c = bundles[base + grid + 1];
        Bundle d = bundles[base + grid];
        bool first = onOneSurface(a, b, c, u.params.z);
        bool second = onOneSurface(a, c, d, u.params.z);
        if (!first && !second) return out;

        // everything in eye space, in the plane of the surface the corners landed on
        float3x3 rotate = float3x3(u.view[0].xyz, u.view[1].xyz, u.view[2].xyz);
        float3 A = (u.view * float4(a.hit.xyz, 1.0)).xyz;
        float3 B = (u.view * float4(b.hit.xyz, 1.0)).xyz;
        float3 C = (u.view * float4(c.hit.xyz, 1.0)).xyz;
        float3 D = (u.view * float4(d.hit.xyz, 1.0)).xyz;
        float3 normal = normalize((first ? b.normal.xyz : float3(0.0)) + (second ? d.normal.xyz : float3(0.0)) + a.normal.xyz + c.normal.xyz);
        float3 helper = abs(normal.y) < 0.99 ? float3(0.0, 1.0, 0.0) : float3(1.0, 0.0, 0.0);
        float3 px = normalize(cross(helper, normal));
        float3 py = cross(normal, px);
        float2 b2 = float2(dot(B - A, px), dot(B - A, py));
        float2 c2 = float2(dot(C - A, px), dot(C - A, py));
        float2 d2 = float2(dot(D - A, px), dot(D - A, py));

        float3 sx0 = first ? sweepOf(a.acrossX, b.acrossX, c.acrossX, rotate) : float3(0.0);
        float3 sy0 = first ? sweepOf(a.acrossY, b.acrossY, c.acrossY, rotate) : float3(0.0);
        float3 sx1 = second ? sweepOf(a.acrossX, c.acrossX, d.acrossX, rotate) : float3(0.0);
        float3 sy1 = second ? sweepOf(a.acrossY, c.acrossY, d.acrossY, rotate) : float3(0.0);
        float4 sweep0 = float4(dot(sx0, px), dot(sx0, py), dot(sy0, px), dot(sy0, py));
        float4 sweep1 = float4(dot(sx1, px), dot(sx1, py), dot(sy1, px), dot(sy1, py));

        // one quad around both triangles at every point of their sweep, a pixel wider so no edge is cut
        float pixel = 2.0 * abs(A.z) / (abs(u.proj[1][1]) * u.params.y);
        float2 spread = 0.5 * max(abs(sweep0.xy) + abs(sweep0.zw), abs(sweep1.xy) + abs(sweep1.zw)) + pixel;
        float2 lo = float2(0.0), hi = float2(0.0);
        if (first) { lo = min(lo, min(b2, c2)); hi = max(hi, max(b2, c2)); }
        if (second) { lo = min(lo, min(c2, d2)); hi = max(hi, max(c2, d2)); }
        float2 corner = mix(lo - spread, hi + spread, bounds[slot]);
        float4 clip = u.proj * float4(A + px * corner.x + py * corner.y, 1.0);
        if (clip.w <= 1e-4) return out;

        // half a cell's light over each triangle's area, at least half a pixel so a flat folded triangle stays finite
        float minimum = 0.5 * pixel * pixel;
        out.position = clip;
        out.a = A;
        out.b = b2;
        out.c = c2;
        out.d = d2;
        out.sweep0 = sweep0;
        out.sweep1 = sweep1;
        out.planeX = px;
        out.planeY = py;
        out.irradiance0 = first ? (a.power.rgb + b.power.rgb + c.power.rgb) / 6.0 / max(0.5 * abs(cross2(b2, c2)), minimum) : float3(0.0);
        out.q = corner;
        out.slack = 2.0 * pixel;
        out.irradiance1 = second ? (a.power.rgb + c.power.rgb + d.power.rgb) / 6.0 / max(0.5 * abs(cross2(c2, d2)), minimum) : float3(0.0);
        return out;
      }

      // narrows a segment's span to the part on the kept side of one line
      static void keep(thread float& t0, thread float& t1, float a, float b)
      {
        if (abs(b) < 1e-12) { if (a < 0.0) t1 = -1e30; }
        else if (b > 0.0) t0 = max(t0, -a / b);
        else t1 = min(t1, -a / b);
      }

      // the share of the light's square inside all three lines, summed along its boundary so nothing leaves registers
      static float squareInside(float3 l, float2 g0, float2 g1, float2 g2)
      {
        float2 g[3] = { g0, g1, g2 };
        float area = 0.0;
        const float2 corners[4] = { float2(-0.5, -0.5), float2(0.5, -0.5), float2(0.5, 0.5), float2(-0.5, 0.5) };
        for (int k = 0; k < 4; ++k) {
          float2 p = corners[k], d = corners[(k + 1) & 3] - p;
          float t0 = 0.0, t1 = 1.0;
          for (int i = 0; i < 3; ++i) keep(t0, t1, l[i] + dot(g[i], p), dot(g[i], d));
          if (t1 > t0) area += cross2(p + t0 * d, p + t1 * d);
        }
        for (int i = 0; i < 3; ++i) {
          float gg = dot(g[i], g[i]);
          if (gg < 1e-16) continue;
          float2 p = -l[i] * g[i] / gg, d = float2(g[i].y, -g[i].x);
          float t0 = -1e30, t1 = 1e30;
          keep(t0, t1, 0.5 - p.x, -d.x);
          keep(t0, t1, 0.5 + p.x, d.x);
          keep(t0, t1, 0.5 - p.y, -d.y);
          keep(t0, t1, 0.5 + p.y, d.y);
          for (int j = 0; j < 3; ++j) if (j != i) keep(t0, t1, l[j] + dot(g[j], p), dot(g[j], d));
          if (t1 > t0) area += cross2(p + t0 * d, p + t1 * d);
        }
        return saturate(0.5 * area);
      }

      // the share of the light whose sweeping triangle covers p, as its width and height move it
      static float coverage(float2 p, float2 e1, float2 e2, float4 sweep)
      {
        float det = cross2(e1, e2);
        if (abs(det) < 1e-12) return 0.0;
        float2x2 inverse = float2x2(float2(e2.y, -e1.y), float2(-e2.x, e1.x)) / det;
        float2 at = inverse * p;
        float2 alongX = -(inverse * sweep.xy);
        float2 alongY = -(inverse * sweep.zw);

        // only pixels on a caustic's soft border need the exact share
        float3 edge = float3(at.x, at.y, 1.0 - at.x - at.y);
        float2 gx = float2(alongX.x, alongY.x);
        float2 gy = float2(alongX.y, alongY.y);
        float2 gz = -float2(alongX.x + alongX.y, alongY.x + alongY.y);
        float3 reach = 0.5 * float3(abs(gx.x) + abs(gx.y), abs(gy.x) + abs(gy.y), abs(gz.x) + abs(gz.y));
        if (any(edge + reach < 0.0)) return 0.0;
        if (all(edge - reach >= 0.0)) return 1.0;

        return squareInside(edge, gx, gy, gz);
      }

      // whether the swept triangle can reach p at all, widened a little on the surface
      static bool reaches(float2 p, float2 e1, float2 e2, float4 sweep, float slack)
      {
        float det = cross2(e1, e2);
        if (abs(det) < 1e-12) return false;
        float2x2 inverse = float2x2(float2(e2.y, -e1.y), float2(-e2.x, e1.x)) / det;
        float2 at = inverse * p;
        float2 alongX = -(inverse * sweep.xy);
        float2 alongY = -(inverse * sweep.zw);
        float3 edge = float3(at.x, at.y, 1.0 - at.x - at.y);
        float2 gx = float2(alongX.x, alongY.x);
        float2 gy = float2(alongX.y, alongY.y);
        float2 gz = -float2(alongX.x + alongX.y, alongY.x + alongY.y);
        float3 reach = 0.5 * float3(abs(gx.x) + abs(gx.y), abs(gy.x) + abs(gy.y), abs(gz.x) + abs(gz.y));

        // how far the slack moves each barycentric
        float2 r0 = float2(inverse[0][0], inverse[1][0]);
        float2 r1 = float2(inverse[0][1], inverse[1][1]);
        float3 widen = slack * float3(length(r0), length(r1), length(r0 + r1));
        return all(edge + reach + widen >= 0.0);
      }

      fragment float4 frag_main(VertOut in [[stage_in]],
                                constant U& u [[buffer(2)]],
                                constant GBufferImage& positions [[buffer(5)]],
                                constant GBufferImage& normals [[buffer(6)]])
      {
        // the caustic texture has its own size and the gbuffer the render's, the quad's plane rules out most pixels before any gbuffer read
        bool may0 = any(in.irradiance0 > 0.0) && reaches(in.q, in.b, in.c, in.sweep0, in.slack);
        bool may1 = any(in.irradiance1 > 0.0) && reaches(in.q, in.c, in.d, in.sweep1, in.slack);
        if (!may0 && !may1) discard_fragment();

        float2 gbufferSize = float2(positions.image.get_width(), positions.image.get_height());
        float2 perCausticPixel = gbufferSize / max(u.params.xy, float2(1.0));
        uint2 pixel = uint2(clamp(in.position.xy * perCausticPixel, float2(0.0), gbufferSize - 1.0));
        float4 n = normals.image.read(pixel);
        if (n.a < 0.5) discard_fragment();
        float3 x = positions.image.read(pixel).xyz;
        float3 offset = x - in.a;

        // only on the surface the cell lies on, not whatever stands in front of or behind it
        if (abs(dot(offset, cross(in.planeX, in.planeY))) > 0.01 + 0.02 * abs(x.z)) discard_fragment();

        float2 p = float2(dot(offset, in.planeX), dot(offset, in.planeY));
        float3 irradiance = float3(0.0);
        if (may0) irradiance += in.irradiance0 * coverage(p, in.b, in.c, in.sweep0);
        if (may1) irradiance += in.irradiance1 * coverage(p, in.c, in.d, in.sweep1);
        if (all(irradiance <= 0.0)) discard_fragment();

        float3 toLight = u.light.w > 0.5 ? (u.view * float4(u.light.xyz, 1.0)).xyz - x : (u.view * float4(u.light.xyz, 0.0)).xyz;
        float3 light;
        if (u.strength.w > 0.0) {
          // a local light's caustics add up with every other's as irradiance, faded the way the lighting pass fades its light
          float reach = length_squared(toLight) / u.strength.w;
          float window = saturate(1.0 - reach * reach);
          light = irradiance * u.strength.rgb * window * window;
        } else {
          // the sun's as a share of the light it would bring without the glass
          light = irradiance / max(dot(normalize(n.xyz), normalize(toLight)), 0.05);
        }
        return float4(min(light, float3(60000.0)), 0.0);
      }
      """#
  }

  /// a graph buffer's texture by reference, only outside the graph's own run.
  func texture(_ ref: Akari.RenderGraph.TextureRef) -> GLuint
  {
    runtime.texture(ref.buffer, named: ref.texture)
  }

  /// traces the sun's bundles, or every local light's.
  fileprivate func traceGlass(sun: Bool)
  {
    for glass in transparency.glass where (glass.tile == Akari.RenderGraph.GlassAtlas.sunTile) == sun
    {
      glassCaustics.trace(glass, camera: (transparency.view, transparency.projection), textures: transparency.glassTextures,
                          screen: SIMD2(Float(sizes.render.width), Float(sizes.render.height)), ior: Self.transparencyIOR)
    }
  }

  /// splats the sun's bundles, or every local light's into one caustic texture.
  fileprivate func splatGlass(sun: Bool)
  {
    for glass in transparency.glass where (glass.tile == Akari.RenderGraph.GlassAtlas.sunTile) == sun
    {
      // the caustic textures are half the render's size, and the splat works in their pixels.
      glassCaustics.splat(glass, camera: (transparency.view, transparency.projection), gbuffer: transparency.glassTextures.gbuffer,
                          size: SIMD2(Float(sizes.half.width), Float(sizes.half.height)))
    }
  }

  func attachGlassCaustics()
  {
    let userdata = Unmanaged.passUnretained(self).toOpaque()
    runtime.setPassCallback(.traceGlassSun, callback: akariTraceGlassSun, userdata: userdata)
    runtime.setPassCallback(.traceGlassLocal, callback: akariTraceGlassLocal, userdata: userdata)
    runtime.setPassCallback(.splatGlassSun, callback: akariSplatGlassSun, userdata: userdata)
    runtime.setPassCallback(.splatGlassLocal, callback: akariSplatGlassLocal, userdata: userdata)
  }
}

/// `Runtime.setPassCallback` takes plain c function pointers, one per stage for the sun and for the local lights.
private func engine(_ userdata: UnsafeMutableRawPointer?) -> Akari.LabFXEngine?
{
  userdata.map { Unmanaged<Akari.LabFXEngine>.fromOpaque($0).takeUnretainedValue() }
}

private func akariTraceGlassSun(_ userdata: UnsafeMutableRawPointer?, _: Int32, _: Int32)
{
  engine(userdata)?.traceGlass(sun: true)
}

private func akariTraceGlassLocal(_ userdata: UnsafeMutableRawPointer?, _: Int32, _: Int32)
{
  engine(userdata)?.traceGlass(sun: false)
}

private func akariSplatGlassSun(_ userdata: UnsafeMutableRawPointer?, _: Int32, _: Int32)
{
  engine(userdata)?.splatGlass(sun: true)
}

private func akariSplatGlassLocal(_ userdata: UnsafeMutableRawPointer?, _: Int32, _: Int32)
{
  engine(userdata)?.splatGlass(sun: false)
}
