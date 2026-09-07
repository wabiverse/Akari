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
import LabGL

public extension Akari
{
  /// One depth atlas shared by every shadow casting light, carved into a
  /// grid of fixed size pages.
  final class ShadowAtlas
  {
    /// A rendered shadow view, everything the deferred shader needs to
    /// sample it.
    public struct View: Sendable
    {
      /// world -> atlas UV with depth remapped to [0, 1].
      public var matrix: Matrix4
      /// (uMin, vMin, uMax, vMax) the filter taps clamp to.
      public var rect: SIMD4<Float>
      /// View depth this cascade covers up to.
      public var splitFar: Float
    }

    /// A resident tile and what it was rendered against.
    private struct Tile
    {
      var pageX: Int
      var pageY: Int
      var pages: Int
      var lightKey: UInt64
      var sceneRevision: UInt64
      var lastUsedFrame: UInt64
    }

    /// The sampleable atlas, 0 until the first successful build.
    public private(set) var texture: GLuint = 0

    private var depthTexture: GLuint = 0
    private var shader: GLuint = 0
    private var target: GLuint = 0
    private var atlasSize = 0
    private var pageSize = 0
    private var pagesPerSide = 0
    private var pageUsed: [Bool] = []
    private var tiles: [Int: Tile] = [:]

    public init()
    {}

    deinit
    {
      release()
    }

    /// Fits the sun cascades, redraws the tiles that went stale, and
    /// returns how to sample each one. Empty when the atlas could not
    /// be built or there is nothing to shadow.
    ///
    /// - Parameters:
    ///   - capture: the geometry capture the main pass replays.
    ///   - camera: the view the cascades are fitted to.
    ///   - lightDirection: world space direction toward the light.
    ///   - sceneBounds: world bounds of everything that can cast.
    ///   - sceneRevision: geometry revision, tiles cache against it.
    ///   - frameIndex: drives least recently used eviction.
    ///   - settings: atlas layout and filtering.
    public func render(capture: OpaquePointer,
                       camera: Camera,
                       lightDirection: SIMD3<Float>,
                       sceneBounds: (min: SIMD3<Float>, max: SIMD3<Float>),
                       sceneRevision: UInt64,
                       frameIndex: UInt64,
                       settings: ShadowSettings) -> [View]
    {
      guard ensureResources(settings) else { return [] }

      let corners = sceneCorners(sceneBounds)
      let cascades = fitCascades(camera: camera,
                                 lightDirection: lightDirection,
                                 sceneCorners: corners,
                                 settings: settings)
      guard !cascades.isEmpty else { return [] }

      let tilePages = min(settings.cascadePages, pagesPerSide)
      let tileSize = tilePages * pageSize

      var placements: [(index: Int, cascade: Cascade, tile: Tile)] = []
      placements.reserveCapacity(cascades.count)
      for (index, cascade) in cascades.enumerated()
      {
        guard let tile = resolveTile(index: index, pages: tilePages, frameIndex: frameIndex)
        else { continue }
        placements.append((index, cascade, tile))
      }
      guard !placements.isEmpty else { return [] }

      let stalePlacements = placements.filter
      {
        $0.tile.lightKey != $0.cascade.key || $0.tile.sceneRevision != sceneRevision
      }

      if !stalePlacements.isEmpty
      {
        beginAtlasPass()
        for placement in stalePlacements
        {
          draw(capture: capture, cascade: placement.cascade,
               x: placement.tile.pageX * pageSize, y: placement.tile.pageY * pageSize,
               size: tileSize)
          tiles[placement.index]?.lightKey = placement.cascade.key
          tiles[placement.index]?.sceneRevision = sceneRevision
        }
        endAtlasPass()
      }

      var views: [View] = []
      views.reserveCapacity(placements.count)
      let scale = Float(tileSize) / Float(atlasSize)
      // half a texel in, so a filter tap on the tile
      // edge cannot reach into a neighbouring cascade.
      let inset = 0.5 / Float(atlasSize)

      for placement in placements
      {
        let origin = SIMD2(Float(placement.tile.pageX * pageSize) / Float(atlasSize),
                           Float(placement.tile.pageY * pageSize) / Float(atlasSize))
        views.append(View(matrix: Matrix4.atlasRect(origin: origin, size: SIMD2(scale, scale))
            * placement.cascade.viewProjection,
          rect: SIMD4(origin.x + inset, origin.y + inset,
                      origin.x + scale - inset, origin.y + scale - inset),
          splitFar: placement.cascade.splitFar))
      }
      return views
    }

    /// Drops every GPU resource, the next `render` rebuilds them.
    public func release()
    {
      if target != 0
      {
        gl.deleteRenderTarget(target)
        target = 0
      }
      for var tex in [texture, depthTexture] where tex != 0
      {
        gl.deleteTextures(count: 1, textures: &tex)
      }
      texture = 0
      depthTexture = 0
      if shader != 0
      {
        gl.deleteShader(shader)
        shader = 0
      }
      atlasSize = 0
      pageSize = 0
      pagesPerSide = 0
      pageUsed = []
      tiles = [:]
    }

    /// One cascade's light transform and the slice it covers.
    private struct Cascade
    {
      var view: Matrix4
      var projection: Matrix4
      var viewProjection: Matrix4
      var splitFar: Float
      var key: UInt64
    }

    private func fitCascades(camera: Camera,
                             lightDirection: SIMD3<Float>,
                             sceneCorners: [SIMD3<Float>],
                             settings: ShadowSettings) -> [Cascade]
    {
      let projection = camera.projection

      guard projection[2, 3] < -0.5 else { return [] }

      // recover the camera's depth range from its projection so the
      // cascades split the frustum that is actually being rendered.
      let a = projection[2, 2]
      let b = projection[3, 2]
      guard abs(a - 1) > 1e-6, abs(a + 1) > 1e-6 else { return [] }
      let frustumNear = b / (a - 1)
      let frustumFar = b / (a + 1)

      var farthestVisibleCorner: Float = 0
      for corner in sceneCorners
      {
        farthestVisibleCorner = max(farthestVisibleCorner, -camera.view.transform(corner).z)
      }
      let bandFactor: Float = 1.05
      let band = (log(max(farthestVisibleCorner, 1)) / log(bandFactor)).rounded(.up)
      let quantizedCorner = pow(bandFactor, band)
      let paddedReach = quantizedCorner * 1.5
      let shadowFar = min(frustumFar, max(settings.maxDistance, paddedReach))
      guard frustumNear > 0, shadowFar > frustumNear else { return [] }

      // half extents of the frustum one unit ahead of the camera.
      let halfWidth = 1 / projection[0, 0]
      let halfHeight = 1 / projection[1, 1]
      let k2 = halfWidth * halfWidth + halfHeight * halfHeight
      let k = k2.squareRoot()

      let inverseView = camera.view.inverse()
      let resolution = Float(min(settings.cascadePages, pagesPerSide) * pageSize)
      let travel = Matrix.normalize(-lightDirection)
      let up = abs(travel.y) > 0.99 ? SIMD3<Float>(0, 0, 1) : SIMD3<Float>(0, 1, 0)
      let rotation = Matrix4.lookAt(eye: .zero, target: travel, up: up)

      // depth is fitted to the whole scene once rather than per cascade.
      var sceneNear = Float.greatestFiniteMagnitude
      var sceneFar = -Float.greatestFiniteMagnitude
      for p in sceneCorners
      {
        let z = rotation.transform(p).z
        sceneNear = min(sceneNear, z)
        sceneFar = max(sceneFar, z)
      }
      guard sceneFar > sceneNear else { return [] }

      let margin = max((sceneFar - sceneNear) * 0.01, 1)
      let eyeDepth = sceneFar + margin
      let depthFar = sceneFar - sceneNear + 2 * margin

      let count = settings.resolvedCascadeCount
      var cascades: [Cascade] = []
      cascades.reserveCapacity(count)
      var sliceNear = frustumNear

      for i in 0 ..< count
      {
        let sliceFar = split(index: i + 1, count: count, near: frustumNear,
                             far: shadowFar, distribution: settings.splitDistribution)

        // exact bounding sphere of the slice, solved from the frustum shape alone.
        let n = sliceNear
        let f = sliceFar
        let centerDepth: Float
        let radius: Float
        if k2 >= (f - n) / (f + n)
        {
          centerDepth = -f
          radius = f * k
        }
        else
        {
          centerDepth = -0.5 * (f + n) * (1 + k2)
          radius = 0.5 * ((f - n) * (f - n)
            + 2 * (f * f + n * n) * k2
            + (f + n) * (f + n) * k2 * k2).squareRoot()
        }
        guard radius > 1e-6 else { continue }

        // snap the centre to whole texels in light space.
        let texel = 2 * radius / resolution
        var lightCenter = rotation.transform(inverseView.transform(SIMD3(0, 0, centerDepth)))
        lightCenter.x = (lightCenter.x / texel).rounded() * texel
        lightCenter.y = (lightCenter.y / texel).rounded() * texel

        // pulled back behind the whole scene.
        let view = Matrix4.translation(SIMD3(-lightCenter.x, -lightCenter.y, -eyeDepth)) * rotation

        let projectionMatrix = Matrix4.ortho(left: -radius, right: radius,
                                             bottom: -radius, top: radius,
                                             near: margin, far: depthFar)
        let viewProjection = projectionMatrix * view

        cascades.append(Cascade(view: view,
                                projection: projectionMatrix,
                                viewProjection: viewProjection,
                                splitFar: sliceFar,
                                key: fingerprint(viewProjection)))
        sliceNear = sliceFar
      }
      return cascades
    }

    /// Practical split scheme, blending a uniform and a logarithmic distribution.
    private func split(index: Int, count: Int, near: Float, far: Float, distribution: Float) -> Float
    {
      let p = Float(index) / Float(count)
      let logarithmic = near * pow(far / near, p)
      let uniform = near + (far - near) * p
      return uniform + (logarithmic - uniform) * min(max(distribution, 0), 1)
    }

    private func sceneCorners(_ bounds: (min: SIMD3<Float>, max: SIMD3<Float>)) -> [SIMD3<Float>]
    {
      (0 ..< 8).map
      { i in
        SIMD3(i & 1 == 0 ? bounds.min.x : bounds.max.x,
              i & 2 == 0 ? bounds.min.y : bounds.max.y,
              i & 4 == 0 ? bounds.min.z : bounds.max.z)
      }
    }

    /// FNV-1a over the matrix bits, so an unchanged light skips its redraw.
    private func fingerprint(_ matrix: Matrix4) -> UInt64
    {
      var hash: UInt64 = 0xCBF2_9CE4_8422_2325
      for value in matrix.m
      {
        var bits = UInt64(value.bitPattern)
        for _ in 0 ..< 4
        {
          hash = (hash ^ (bits & 0xFF)) &* 0x100_0000_01B3
          bits >>= 8
        }
      }
      return hash
    }

    /// Opens the atlas for writing without
    /// disturbing tiles that are not being
    /// redrawn this pass.
    private func beginAtlasPass()
    {
      gl.bindRenderTarget(target)

      gl.disable(GLenum(GL_BLEND))
      gl.enable(GL_DEPTH_TEST)
      gl.depthFunc(GL_LESS)
      gl.depthMask(GLboolean(1))

      // slope scaled offset.
      gl.enable(GLenum(GL_POLYGON_OFFSET_FILL))
      gl.polygonOffset(factor: 2, units: 4)
      gl.enable(GLenum(GL_SCISSOR_TEST))
    }

    private func endAtlasPass()
    {
      gl.disable(GLenum(GL_SCISSOR_TEST))
      gl.disable(GLenum(GL_POLYGON_OFFSET_FILL))
      gl.bindRenderTarget(gl.rootRenderTarget())
    }

    private func draw(capture: OpaquePointer, cascade: Cascade, x: Int, y: Int, size: Int)
    {
      gl.viewport(x: GLint(x), y: GLint(y), width: GLsizei(size), height: GLsizei(size))
      gl.scissor(x: GLint(x), y: GLint(y), width: GLsizei(size), height: GLsizei(size))
      gl.useShader(shader)

      gl.disable(GLenum(GL_POLYGON_OFFSET_FILL))

      gl.matrixMode(GL_PROJECTION)
      gl.loadMatrix(Matrix4.identity.m)
      gl.matrixMode(GL_MODELVIEW)
      gl.loadMatrix(Matrix4.identity.m)

      gl.depthFunc(GLenum(GL_ALWAYS))

      gl.begin(mode: GL_TRIANGLES)
      gl.vertex(x: GLint(-1), y: GLint(-1), z: GLint(1))
      gl.vertex(x: GLint(3), y: GLint(-1), z: GLint(1))
      gl.vertex(x: GLint(-1), y: GLint(3), z: GLint(1))
      gl.end()

      gl.depthFunc(GL_LESS)
      gl.enable(GLenum(GL_POLYGON_OFFSET_FILL))

      gl.matrixMode(GL_PROJECTION)
      gl.loadMatrix(cascade.projection.m)
      gl.matrixMode(GL_MODELVIEW)
      gl.loadMatrix(cascade.view.m)

      labgl.capturePlayback(capture)
      gl.useShader(0)
    }

    /// Returns the tile for `index`, allocating or evicting as needed.
    private func resolveTile(index: Int, pages: Int, frameIndex: UInt64) -> Tile?
    {
      if var tile = tiles[index], tile.pages == pages
      {
        tile.lastUsedFrame = frameIndex
        tiles[index] = tile
        return tile
      }

      if let stale = tiles[index]
      {
        releasePages(stale)
        tiles[index] = nil
      }

      guard let slot = allocate(pages: pages) ?? evictThenAllocate(pages: pages, frameIndex: frameIndex)
      else { return nil }

      let tile = Tile(pageX: slot.x, pageY: slot.y, pages: pages,
                      lightKey: 0, sceneRevision: .max, lastUsedFrame: frameIndex)
      tiles[index] = tile
      return tile
    }

    /// First fit square block of `pages` on a side.
    private func allocate(pages: Int) -> (x: Int, y: Int)?
    {
      guard pages <= pagesPerSide else { return nil }
      for y in 0 ... (pagesPerSide - pages)
      {
        for x in 0 ... (pagesPerSide - pages) where isFree(x: x, y: y, pages: pages)
        {
          mark(x: x, y: y, pages: pages, used: true)
          return (x, y)
        }
      }
      return nil
    }

    private func evictThenAllocate(pages: Int, frameIndex: UInt64) -> (x: Int, y: Int)?
    {
      while let victim = tiles.filter({ $0.value.lastUsedFrame != frameIndex })
        .min(by: { $0.value.lastUsedFrame < $1.value.lastUsedFrame })
      {
        releasePages(victim.value)
        tiles[victim.key] = nil
        if let slot = allocate(pages: pages) { return slot }
      }
      return nil
    }

    private func releasePages(_ tile: Tile)
    {
      mark(x: tile.pageX, y: tile.pageY, pages: tile.pages, used: false)
    }

    private func isFree(x: Int, y: Int, pages: Int) -> Bool
    {
      for py in y ..< (y + pages)
      {
        for px in x ..< (x + pages) where pageUsed[py * pagesPerSide + px]
        {
          return false
        }
      }
      return true
    }

    private func mark(x: Int, y: Int, pages: Int, used: Bool)
    {
      for py in y ..< (y + pages)
      {
        for px in x ..< (x + pages)
        {
          pageUsed[py * pagesPerSide + px] = used
        }
      }
    }

    private func ensureResources(_ settings: ShadowSettings) -> Bool
    {
      let size = max(256, settings.atlasSize)
      let page = max(1, min(settings.pageSize, size))
      if texture != 0, atlasSize == size, pageSize == page { return true }

      release()

      let color = makeTexture(size: size, internalFormat: GLint(GL_R32F), format: GLenum(GL_RED))
      let depth = makeTexture(size: size, internalFormat: GLint(GL_DEPTH_COMPONENT32F), format: GLenum(GL_DEPTH_COMPONENT))
      guard color != 0, depth != 0
      else
      {
        print("[akari/shadow] atlas texture allocation failed")
        return false
      }

      var rt: GLuint = 0
      gl.genRenderTarget(hasDepth: GLboolean(1), target: &rt)
      guard rt != 0
      else
      {
        var c = color, d = depth
        gl.deleteTextures(count: 1, textures: &c)
        gl.deleteTextures(count: 1, textures: &d)
        print("[akari/shadow] glGenRenderTarget failed")
        return false
      }
      gl.renderTargetTexture(target: rt, attachment: GLenum(GL_COLOR_ATTACHMENT0), texture: color)
      gl.renderTargetTexture(target: rt, attachment: GLenum(GL_DEPTH_ATTACHMENT), texture: depth)

      shader = gl.defineShader(name: "akari-shadow-depth",
                               vertexGLSL: Self.vertexGLSL, fragmentGLSL: Self.fragmentGLSL,
                               vertexMSL: Self.metal, fragmentMSL: nil)
      guard shader != 0
      else
      {
        print("[akari/shadow] shadow depth shader failed to compile")
        return false
      }

      texture = color
      depthTexture = depth
      target = rt
      atlasSize = size
      pageSize = page
      pagesPerSide = max(1, size / page)
      pageUsed = [Bool](repeating: false, count: pagesPerSide * pagesPerSide)
      tiles = [:]
      return true
    }

    private func makeTexture(size: Int, internalFormat: GLint, format: GLenum) -> GLuint
    {
      var tex: GLuint = 0
      gl.genTextures(count: 1, textures: &tex)
      guard tex != 0 else { return 0 }

      gl.bindTexture(target: GL_TEXTURE_2D, texture: tex)
      gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_MIN_FILTER, param: GLint(GL_NEAREST))
      gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_MAG_FILTER, param: GLint(GL_NEAREST))
      gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_WRAP_S, param: GLint(GL_CLAMP_TO_EDGE))
      gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_WRAP_T, param: GLint(GL_CLAMP_TO_EDGE))
      gl.texImage2D(target: GL_TEXTURE_2D, level: 0, internalFormat: internalFormat,
                    width: GLsizei(size), height: GLsizei(size), border: 0,
                    format: format, type: GL_FLOAT, pixels: nil)
      return tex
    }

    private static let vertexGLSL = """
      #version 330 core
      layout(location = 0) in vec4 a_position;
      uniform mat4 u_modelviewProjection;
      void main()
      {
        gl_Position = u_modelviewProjection * a_position;
      }
      """

    private static let fragmentGLSL = """
      #version 330 core
      layout(location = 0) out vec4 o_depth;
      void main()
      {
        o_depth = vec4(gl_FragCoord.z, 0.0, 0.0, 1.0);
      }
      """

    private static let metal = """
      #include <metal_stdlib>
      using namespace metal;

      struct LabGLBuiltins
      {
        float4x4 u_modelview;
        float4x4 u_projection;
        float4x4 u_modelviewProjection;
        float3x3 u_normalMatrix;
      };

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

      vertex VertOut vert_main(VertIn in [[stage_in]],
                               constant LabGLBuiltins& B [[buffer(3)]])
      {
        VertOut out;
        out.position = B.u_modelviewProjection * in.a_position;
        out.position.z = (out.position.z + out.position.w) * 0.5;
        return out;
      }

      fragment float4 frag_main(VertOut in [[stage_in]])
      {
        return float4(in.position.z, 0.0, 0.0, 1.0);
      }
      """
  }
}

private extension SIMD3 where Scalar == Float
{
  var lengthSquared: Float
  {
    (self * self).sum()
  }
}
