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

extension Akari.ShadowAtlas
{
  enum Buffer: Akari.GPUBufferName
  {
    case tiles, pagesFree, pagesInfo, pagesCached
    case renderMap, clearArgs, renderRect
    /// The tiles to render whose static depth is stale too, and their dirty rect per view.
    case renderMapStatic, clearArgsStatic, renderRectStatic
    /// Per tilemap depth range, as ordered ints so it can be atomically min/maxed.
    case tilemapsClip
    /// Per view, its stale tiles and how many of them fit this frame's budget.
    case dirtyCount, allowance

    var usage: GLuint
    {
      switch self
      {
        case .tiles, .pagesFree, .pagesInfo, .pagesCached:
          LGL_BUFFER_COMPUTE_READ | LGL_BUFFER_COMPUTE_WRITE | LGL_BUFFER_MAP_WRITE
        default:
          LGL_BUFFER_COMPUTE_READ | LGL_BUFFER_COMPUTE_WRITE
      }
    }

    /// Every element is four bytes.
    var bytes: Int
    {
      4 * count
    }

    private var count: Int
    {
      switch self
      {
        case .tiles: maxTiles
        case .pagesFree: maxPage
        case .pagesInfo: 8
        case .pagesCached: maxPage * 2
        case .renderMap, .renderMapStatic: maxViews * tilemapRes * tilemapRes
        case .clearArgs, .clearArgsStatic: 3
        case .tilemapsClip: maxTilemaps * 2
        case .renderRect, .renderRectStatic, .dirtyCount, .allowance: maxViews
      }
    }
  }

  /// Everything the CPU rewrites per frame, one set per frame in flight.
  struct Frame
  {
    var data: GLuint = 0
    var buffers = Akari.GPUBuffers<FrameBuffer>()

    subscript(buffer: FrameBuffer) -> GLuint
    {
      buffers[buffer]
    }
  }

  enum FrameBuffer: Akari.GPUBufferName
  {
    case gridShift, levelParams
    /// Fit order view index -> tilemap slot, for the page table kernel.
    case slotOfView
    /// Per view, nonzero when this frame's draw rendered it.
    case drawnView
    case clearList, clearListStatic, runViews, runXf, punctualViews, viewXf
    /// Old and new boxes of the casters that moved, six floats each, and the same for the static captures.
    case movedBoxes, movedStaticBoxes

    var usage: GLuint
    {
      switch self
      {
        case .clearList, .clearListStatic: LGL_BUFFER_COMPUTE_READ | LGL_BUFFER_COMPUTE_WRITE
        case .gridShift: LGL_BUFFER_COMPUTE_READ | LGL_BUFFER_COMPUTE_WRITE | LGL_BUFFER_MAP_WRITE
        default: LGL_BUFFER_COMPUTE_READ | LGL_BUFFER_MAP_WRITE
      }
    }

    /// Every element is four bytes.
    var bytes: Int
    {
      4 * count
    }

    private var count: Int
    {
      switch self
      {
        case .gridShift: maxDirectionalTilemaps * 2
        case .levelParams: maxDirectionalTilemaps * levelParamsStride
        case .slotOfView: maxDirectionalTilemaps
        case .drawnView: maxViews
        case .clearList, .clearListStatic: maxPage
        case .runViews: maxRuns * maxAmplificationViews
        case .runXf: maxRuns * maxAmplificationViews * 16
        case .punctualViews: maxViews
        case .viewXf: maxViews * 16
        case .movedBoxes, .movedStaticBoxes: maxMovedCasters * 6
      }
    }
  }

  /// The capture's per draw bounds and the cull outputs sized to them.
  struct DrawCulling
  {
    var capture: OpaquePointer?
    var bounds: GLuint = 0
    var visibility: GLuint = 0
    var instanceView: GLuint = 0
    var capacity = 0
    var count = 0
    var generation: UInt64 = .max

    var buffers: [GLuint]
    {
      [bounds, visibility, instanceView]
    }
  }

  /// One world AABB per shadow caster, six floats.
  struct CasterBounds
  {
    var buffer: GLuint = 0
    var capacity = 0
  }

  struct Amplification
  {
    var views: GLuint = 0
    var viewports: GLuint = 0
  }

  /// Allocates the atlas and its tables if they don't exist yet.
  @discardableResult
  public func prepare() -> Bool
  {
    ensureResources()
  }

  /// Starts the tile management kernels and the depth shader compiling in the background.
  func precompileShaders()
  {
    guard depthShader == 0 else { return }

    kernels = .precompile()
    depthShader = gl.precompileShader(name: "akari-shadow-depth",
                                      vertexGLSL: Self.depthVertexGLSL,
                                      fragmentGLSL: Self.depthFragmentGLSL,
                                      vertexMSL: Self.depthMSL,
                                      fragmentMSL: nil)
  }

  func ensureResources() -> Bool
  {
    if resourcesReady { return true }

    precompileShaders()
    let failed = kernels.wait()
    guard
      Kernel.required.isDisjoint(with: failed),
      gl.waitShader(depthShader) != 0
    else { return fail("shader compilation failed") }
    if failed.contains(.tagUsageVolume)
    {
      print("[akari/shadow] volume usage tagging failed to compile, fog shadows fall back to surface pages")
    }

    if failed.contains(.tagUpdatePunctual)
    {
      print("[akari/shadow] point light update tagging failed to compile, moving casters redraw every face")
    }

    guard makeBuffers() else { return fail("SSBO allocation failed") }

    amplification.views = gl.genInstanceTransforms(count: GLsizei(Self.maxAmplificationViews))
    amplification.viewports = gl.genInstanceViewports(count: GLsizei(Self.maxAmplificationViews))
    guard
      amplification.views != 0,
      amplification.viewports != 0
    else { return fail("amplification handle allocation failed") }

    let viewRes = Self.tilemapRes * Self.pageResolution
    atlasDepth = gl.createMemorylessDepthTexture(width: GLsizei(viewRes),
                                                 height: GLsizei(viewRes),
                                                 layers: 1,
                                                 internalFormat: GLenum(GL_DEPTH_COMPONENT32F))
    guard atlasDepth != 0 else { return fail("shadow raster target allocation failed") }

    atlas = gl.createTextureArray(width: GLsizei(Self.pagesPerLayer * Self.pageResolution),
                                  height: GLsizei(Self.pageResolution),
                                  layers: GLsizei(Self.poolLayers),
                                  format: GLenum(GL_R32UI))
    guard atlas != 0 else { return fail("atlas texture allocation failed") }
    staticAtlas = gl.createTextureArray(width: GLsizei(Self.pagesPerLayer * Self.pageResolution),
                                        height: GLsizei(Self.pageResolution),
                                        layers: GLsizei(Self.poolLayers),
                                        format: GLenum(GL_R32UI))
    guard staticAtlas != 0 else { return fail("static atlas texture allocation failed") }

    var rt: GLuint = 0
    gl.genRenderTarget(hasDepth: GLboolean(1), target: &rt)
    guard rt != 0 else { return fail("glGenRenderTarget failed") }
    gl.renderTargetTexture(target: rt, attachment: GLenum(GL_DEPTH_ATTACHMENT), texture: atlasDepth)
    atlasTarget = rt
    precompileDepthVariants()

    frames = (0 ..< Self.bufferRing).compactMap { _ in makeFrame() }
    pageTable = makeTexture(width: Self.tilesPerTilemap,
                            height: Self.maxTilemaps,
                            internalFormat: GL_RGBA16F,
                            format: GL_RGBA)
    guard
      frames.count == Self.bufferRing,
      pageTable != 0
    else { return fail("frame buffer or page table allocation failed") }
    data = frames[0].data

    renderViewReadback = gl.createComputeReadback(sizeBytes: GLsizei(Self.maxViews * MemoryLayout<UInt32>.size),
                                                  ringSize: 3)
    guard renderViewReadback != 0 else { return fail("render view readback allocation failed") }

    resourcesReady = true

    return true
  }

  /// Drops every GPU resource, the next `markPageUsage`/`render` rebuilds them.
  public func release()
  {
    if atlasTarget != 0 { gl.deleteRenderTarget(atlasTarget) }
    for var tex in [atlas, staticAtlas, atlasDepth, pageTable] + frames.map(\.data) where tex != 0
    {
      gl.deleteTextures(count: 1, textures: &tex)
    }

    buffers.release()
    for var frame in frames
    {
      frame.buffers.release()
    }

    for buf in culling.flatMap(\.buffers) + [casters.buffer] where buf != 0
    {
      gl.deleteBuffer(buf)
    }

    if renderViewReadback != 0 { gl.deleteComputeReadback(renderViewReadback) }
    kernels.release()
    if depthShader != 0 { gl.deleteShader(depthShader) }
    if amplification.views != 0
    {
      var handle = amplification.views
      gl.deleteInstanceTransforms(count: 1, handles: &handle)
    }

    if amplification.viewports != 0
    {
      var handle = amplification.viewports
      gl.deleteInstanceViewports(count: 1, handles: &handle)
    }

    atlasTarget = 0; atlas = 0; staticAtlas = 0; atlasDepth = 0; data = 0; pageTable = 0
    frames = []; ringCursor = 0; renderViewReadback = 0
    culling = []
    casters = CasterBounds()
    depthShader = 0
    amplification = Amplification()

    resourcesReady = false
    lastSceneRevision = .max
    frameFit = FrameFit()
    casterMotion = CasterMotion()
    staticMotion = CasterMotion()
    casterRedraw = .none
    punctualHistory = PunctualHistory()
    directionalHistory = DirectionalHistory()
    sunMotion = SunMotion()
    sun.lodBias = 0
  }

  /// Every amplified run `drawViews` replays, direct and indirect.
  private func precompileDepthVariants()
  {
    for count in 1 ... Self.maxAmplificationViews
    {
      for flags in [0, LGL_SHADER_VARIANT_INDIRECT, LGL_SHADER_VARIANT_INSTANCED]
      {
        gl.precompileShaderVariant(depthShader,
                                   renderTarget: atlasTarget,
                                   blend: GLboolean(0),
                                   blendSource: 0,
                                   blendDestination: 0,
                                   amplification: GLsizei(count),
                                   flags: GLbitfield(flags))
      }
    }
  }

  func makeBuffer<T>(_ usage: GLuint, _: T.Type, count: Int) -> GLuint
  {
    gl.createBuffer(usage: usage, sizeBytes: GLsizei(count * MemoryLayout<T>.size))
  }

  func withMappedBuffer<T>(_ buffer: GLuint, as _: T.Type, _ body: (UnsafeMutablePointer<T>) -> Void)
  {
    guard let p = gl.mapBuffer(buffer) else { return }
    body(p.assumingMemoryBound(to: T.self))
    gl.unmapBuffer(buffer)
  }

  private func fail(_ message: String) -> Bool
  {
    print("[akari/shadow] \(message)")
    release()

    return false
  }

  private func makeBuffers() -> Bool
  {
    guard let made = Akari.GPUBuffers<Buffer>.make() else { return false }
    buffers = made

    withMappedBuffer(buffers[.tiles], as: UInt32.self)
    {
      $0.initialize(repeating: 0, count: Self.maxTiles)
    }

    withMappedBuffer(buffers[.pagesFree], as: UInt32.self)
    { ptr in
      for slot in 0 ..< Self.maxPage
      {
        let page = Self.maxPage - 1 - slot
        let col = UInt32(page % Self.pagePackRadix), z = UInt32(page / Self.pagePackRadix)
        ptr[slot] = (col & 7) | ((col >> 3) << 3) | (z << 6)
      }
    }

    withMappedBuffer(buffers[.pagesInfo], as: Int32.self)
    { ptr in
      ptr[0] = Int32(Self.maxPage)
      ptr[1] = 0
      ptr[2] = 0
      ptr[3] = 0
      ptr[4] = 0
      ptr[5] = 0
      ptr[6] = 0
      ptr[7] = 0
    }

    withMappedBuffer(buffers[.pagesCached], as: UInt32.self)
    {
      $0.initialize(repeating: 0xFFFF_FFFF, count: Self.maxPage * 2)
    }

    return true
  }

  private func makeFrame() -> Frame?
  {
    let data = makeTexture(width: Self.dataTextureWidth, height: Self.maxTilemaps, internalFormat: GL_RGBA32F, format: GL_RGBA)
    guard data != 0 else { return nil }
    guard let buffers = Akari.GPUBuffers<FrameBuffer>.make()
    else
    {
      var data = data
      gl.deleteTextures(count: 1, textures: &data)
      return nil
    }

    return Frame(data: data, buffers: buffers)
  }

  private func makeTexture(width: Int, height: Int, internalFormat: GLint, format: GLenum) -> GLuint
  {
    var tex: GLuint = 0
    gl.genTextures(count: 1, textures: &tex)

    guard tex != 0 else { return 0 }

    gl.bindTexture(target: GL_TEXTURE_2D, texture: tex)
    gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_MIN_FILTER, param: GLint(GL_NEAREST))
    gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_MAG_FILTER, param: GLint(GL_NEAREST))
    gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_WRAP_S, param: GLint(GL_CLAMP_TO_EDGE))
    gl.texParameter(target: GL_TEXTURE_2D, pname: GL_TEXTURE_WRAP_T, param: GLint(GL_CLAMP_TO_EDGE))
    gl.texImage2D(target: GL_TEXTURE_2D,
                  level: 0,
                  internalFormat: internalFormat,
                  width: GLsizei(width),
                  height: GLsizei(height),
                  border: 0,
                  format: format,
                  type: GL_FLOAT,
                  pixels: nil)

    return tex
  }
}
