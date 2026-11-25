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
import simd

public extension Akari
{
  /// the shadow tile and page pipeline every shadow casting light shares
  final class ShadowAtlas
  {
    /// a rendered directional view, everything the deferred shader needs to sample it.
    public struct View: Sendable
    {
      /// world -> light clip space.
      public var matrix: Matrix4
      /// view depth this cascade covers up to, or a clipmap level's own light space radius.
      public var splitFar: Float
    }

    /// the froxel grid the volume scatter pass lights this frame.
    public struct VolumeFroxels: Sendable
    {
      /// froxels per slice, the volume atlas's 8x8 slice tiles.
      public var gridWidth: Int
      public var gridHeight: Int
      /// view depth range, slices spaced across it.
      public var near: Float
      public var far: Float
      public var inverseProjection: Matrix4
      /// farthest view depth per froxel column.
      public var depthTexture: GLuint
      /// the sun level offset for froxels.
      public var sunLevelBias: Int

      public init(gridWidth: Int, gridHeight: Int, near: Float, far: Float,
                  inverseProjection: Matrix4, depthTexture: GLuint, sunLevelBias: Int)
      {
        self.gridWidth = gridWidth
        self.gridHeight = gridHeight
        self.near = near
        self.far = far
        self.inverseProjection = inverseProjection
        self.depthTexture = depthTexture
        self.sunLevelBias = sunLevelBias
      }
    }

    /// the directional light's fitted basis, as the deferred shader samples it.
    public struct Sun: Sendable
    {
      /// pure light rotation basis.
      public var rotation: Matrix4 = .identity
      public var eyeToLightRotation: Matrix4 = .identity
      public var refOffset: SIMD3<Float> = .zero
      public var isClipmap = true
      public var lodMin: Int32 = 0
      public var lodMax: Int32 = 0
      /// level bias the shading pick must add.
      public var lodBias: Float = 0
    }
    
    public struct ShadowSunPayload
    {
      let smooth: SIMD3<Float>
      let snapped: SIMD3<Float>
    }

    public internal(set) var sun = Sun()
    /// shared page pool.
    public internal(set) var atlas: GLuint = 0
    /// each page's depth from static casters alone, what dynamic casters redraw on top of
    var staticAtlas: GLuint = 0
    /// per tilemap slot data.
    public internal(set) var data: GLuint = 0
    public internal(set) var pageTable: GLuint = 0

    var kernels = Akari.ComputeKernels<Kernel>()
    var depthShader: GLuint = 0
    var buffers = Akari.GPUBuffers<Buffer>()
    /// per directional view, its tilemap slot when it has tiles to render.
    var renderViewReadback: GLuint = 0
    var frames: [Frame] = []
    var ringCursor = 0
    var frame: Frame
    {
      frames.isEmpty ? Frame() : frames[ringCursor]
    }

    var culling: [DrawCulling] = []
    var casters = CasterBounds()
    var amplification = Amplification()
    /// transient depth test, one tilemap of texels.
    var atlasDepth: GLuint = 0
    var atlasTarget: GLuint = 0
    var dataPixels = [Float](repeating: 0, count: dataTextureWidth * 4 * maxTilemaps)
    var resourcesReady = false

    var sunMotion = SunMotion()
    var directionalHistory = DirectionalHistory()
    var punctualHistory = PunctualHistory()
    var lastSceneRevision: UInt64 = .max
    /// this frame's fit, made before the usage tags so they land on the tiles it draws.
    var frameFit = FrameFit()
    var casterMotion = CasterMotion()
    var staticMotion = CasterMotion()
    var casterRedraw = CasterRedraw.none
    var pressure = PunctualPressure()
    /// the slots whose lights keep full resolution until the pool runs out for them too.
    public var mainSlots: Set<Int> = []
    /// the material atlas, whose opacity lets light through the static casters.
    public var materialAtlas: GLuint = 0
    /// untextured materials' constants, what the alpha test reads for them
    public var materialConstants: GLuint = 0
    /// each prim's style texels, whose emitter flag keeps a mesh out of the maps.
    public var styles: GLuint = 0
    /// whether the sun's glass map shadows the glass, which keeps it out of the sun's views here.
    public var glassSun = false
    /// the punctual slots whose lights shadow the glass through their glass maps, a bit a slot.
    public var glassSlots: UInt32 = 0

    public init()
    {}

    deinit
    {
      release()
    }

    /// lods added to the punctual bias for a slot, the main lights match the screen and the rest start a step coarser
    public func lodBias(slot: Int) -> Float
    {
      mainSlots.contains(slot)
        ? Float(min(pressure.level / 2 - 1, Self.lodMax))
        : Float(min(1 + (pressure.level + 1) / 2, Self.lodMax))
    }

    /// raised while the page pool runs short, coarsening the secondary lights first.
    struct PunctualPressure
    {
      var level = 0
      var headroom = 0
      var hold = 60
      var sinceDrop = Int.max / 2
      var settle = 0

      /// steps a level coarser when the pool ran short and finer once finer levels comfortably fit
      mutating func adapt(short: Bool, fitsFiner: Bool)
      {
        sinceDrop &+= 1
        if sinceDrop > 3600 { hold = 60 }
        if settle > 0
        {
          settle -= 1
        }
        else if short, level < 2 * lodMax + 2
        {
          // pressed again before the next try was due, so the finer level didn't fit and waits longer.
          if sinceDrop < hold * 4 { hold = min(hold * 2, 1920) }
          level += 1
          headroom = 0
          settle = 8
        }
        else if level > 0, fitsFiner
        {
          headroom += 1
          if headroom >= hold
          {
            level -= 1
            headroom = 0
            settle = 8
            sinceDrop = 0
          }
        }
        else
        {
          headroom = 0
        }
      }
    }

    func adaptPunctualBias()
    {
      withMappedBuffer(buffers[.pagesInfo], as: Int32.self)
      { info in
        // failed pages lose their shadow for a frame, so step coarser while a tenth of the pool is free and finer only with plenty to spare
        let used = Int(info[7])
        pressure.adapt(short: info[5] > 0 || used > Self.maxPage * 9 / 10,
                       fitsFiner: used * 4 < Self.maxPage * 4 / 5)
      }
    }

    /// fits this frame's views, then tags and allocates the pages it samples.
    public func markPageUsage(gbufferPosition: GLuint,
                              camera: Camera,
                              screenWidth: Int,
                              screenHeight: Int,
                              footprintHeight: Int,
                              lightDirection: SIMD3<Float>,
                              sceneBounds: (min: SIMD3<Float>, max: SIMD3<Float>),
                              settings: ShadowSettings,
                              lights: [Akari.Lux.PointLight],
                              punctualFarDistance: Float,
                              sceneRevision: UInt64,
                              staticCasters: [Casters],
                              dynamicCasters: [Casters],
                              volume: VolumeFroxels? = nil,
                              snapSun: Bool = false)
    {
      guard
        gbufferPosition != 0,
        screenWidth > 0,
        screenHeight > 0,
        ensureResources()
      else { return }

      ringCursor = (ringCursor + 1) % Self.bufferRing
      let lightCount = min(lights.count, Self.maxPunctualLights)
      adaptPunctualBias()

      fitViews(camera: camera, lightDirection: lightDirection, sceneBounds: sceneBounds,
               settings: settings, lights: lights, punctualFarDistance: punctualFarDistance,
               snapSun: snapSun)

      var punctualDirty = punctualHistory.pendingDirty
      punctualHistory.pendingDirty = 0

      let sceneChanged = sceneRevision != lastSceneRevision
      lastSceneRevision = sceneRevision
      if sceneChanged
      {
        casterRedraw = findCasterRedraw(dynamicCasters)

        // the static pages hold what the static captures drew, the tiles under what changed in them redraw.
        let staticRedraw = findStaticRedraw(staticCasters)
        if staticRedraw == nil { casterRedraw = .all }
        frameFit.staticRedraw = staticRedraw ?? 0
        if casterRedraw == .all || !kernels[.tagUpdatePunctual].isBuilt || frameFit.staticRedraw > 0 { punctualDirty = -1 }
      }
      else
      {
        frameFit.staticRedraw = 0
      }

      frameFit.castersMoved = sceneChanged
      frameFit.redraw = sceneChanged ? casterRedraw : .none
      dispatchBeginFrame(dirty: punctualDirty)
      dispatchTilemapShift(forceFullShift: frameFit.redraw == .all)
      if sceneChanged, case let .boxes(count) = casterRedraw
      {
        dispatchTagUpdatePunctual(boxCount: count, lights: lights, lightCount: lightCount)
      }

      let invView = camera.view.inverse()
      let sunActive = !directionalHistory.slots.isEmpty

      if let volume, sunActive || lightCount > 0
      {
        dispatchTagUsageVolume(volume,
                               invView: invView,
                               camera: camera,
                               lights: lights,
                               lightCount: lightCount)
      }

      if sunActive
      {
        dispatchTagUsageDirectional(gbufferPosition: gbufferPosition,
                                    eyeToFitEye: directionalHistory.view * invView,
                                    screenWidth: screenWidth,
                                    screenHeight: screenHeight)
      }

      if lightCount > 0
      {
        dispatchTagUsagePunctual(gbufferPosition: gbufferPosition,
                                 invView: invView,
                                 screenWidth: screenWidth,
                                 screenHeight: screenHeight,
                                 footprintHeight: footprintHeight,
                                 camera: camera,
                                 lights: lights,
                                 lightCount: lightCount)
      }

      dispatchPageAllocation()
    }

    /// fits every active tilemap and lays out its views, before the usage tags.
    private func fitViews(camera: Camera,
                          lightDirection: SIMD3<Float>,
                          sceneBounds: (min: SIMD3<Float>, max: SIMD3<Float>),
                          settings: ShadowSettings,
                          lights: [Akari.Lux.PointLight],
                          punctualFarDistance: Float,
                          snapSun: Bool)
    {
      let corners = Self.sceneCorners(sceneBounds)
      let technique = Self.resolveTechnique(camera: camera)

      let sunChanged = sunMotion.advance(to: lightDirection, snap: snapSun)
      var fitSettings = settings
      fitSettings.levelLodBias = (settings.levelLodBias + sunMotion.lodBias).rounded()

      let fit: DirectionalFit = switch technique
      {
        case .cascaded:
          Self.fitCascades(camera: camera,
                           lightDirection: sunMotion.smoothDirection,
                           sceneCorners: corners,
                           settings: fitSettings)
        case .clipmap:
          Self.fitLevels(camera: camera,
                         lightDirection: sunMotion.smoothDirection,
                         sceneCorners: corners,
                         settings: fitSettings)
      }

      let directional = fit.cascades

      sun = Sun(rotation: fit.rotation,
                eyeToLightRotation: fit.eyeToLightRotation,
                refOffset: fit.refOffset,
                isClipmap: fit.isClipmap,
                lodMin: directional.first?.absoluteLevel ?? 0,
                lodMax: directional.last?.absoluteLevel ?? 0,
                lodBias: technique == .clipmap ? fitSettings.levelLodBias : 0)

      let directionalSlots = directionalHistory.assignSlots(directional, technique: technique)

      let lightCount = min(lights.count, Self.maxPunctualLights)
      let punctualFaces: [[PunctualFace]] = (0 ..< Self.maxPunctualLights).map
      { slot in
        guard slot < lightCount else { return [] }
        let near = max(lights[slot].radius * 0.25, 0.02)
        return Self.fitPunctual(lightPosition: lights[slot].position,
                                near: near,
                                far: max(min(punctualFarDistance, lights[slot].reach), near * 2))
      }

      let inverseView = camera.view.inverse()
      writeDataTexture(directional: directional,
                       directionalSlots: directionalSlots,
                       punctualFaces: punctualFaces,
                       inverseView: inverseView)
      punctualHistory.update(punctualFaces)
      directionalHistory.updateShifts(directional, slots: directionalSlots)
      uploadLevelParams(directional: directional, directionalSlots: directionalSlots,
                        inverseView: inverseView)

      frameFit = FrameFit(directional: directional,
                          slots: directionalSlots,
                          punctualFaces: punctualFaces,
                          lightDirection: sunMotion.smoothDirection,
                          cameraWorld: SIMD3(inverseView[3, 0], inverseView[3, 1], inverseView[3, 2]),
                          sunChanged: sunChanged,
                          isCurrent: true)

      directionalHistory.slots = directionalSlots
      directionalHistory.view = camera.view
    }

    /// draws the stale views of what `markPageUsage` fit this frame.
    public func render(staticCaptures: [OpaquePointer],
                       dynamicCaptures: [OpaquePointer],
                       dynamicDrawBounds: [[Float]?],
                       casters: [Casters]) -> [View]
    {
      guard ensureResources(), frameFit.isCurrent else { return [] }
      frameFit.isCurrent = false

      let directional = frameFit.directional
      let directionalSlots = frameFit.slots
      let punctualFaces = frameFit.punctualFaces
      let redraw = frameFit.redraw

      dispatchTileMapMaintenance(casters: casters,
                                 slotCount: directionalSlots.isEmpty ? 0 : Self.maxDirectionalTilemaps,
                                 lightZ: frameFit.lightDirection,
                                 cameraWorld: frameFit.cameraWorld,
                                 castersMoved: frameFit.castersMoved,
                                 redraw: redraw,
                                 staticRedraw: frameFit.staticRedraw)

      // a turned sun or changed static casters redraw in one frame, so no tile ever shows the old shadow beside the new.
      let atomic = frameFit.sunChanged || frameFit.staticRedraw > 0 || redraw == .all
      dispatchSelectViews(budget: atomic ? Int(Int32.max) : Self.renderTileBudget)
      dispatchPageTable()

      let forceDirectional = frameFit.sunChanged || redraw.isNeeded || frameFit.staticRedraw > 0

      let drawn = drawViews(staticCaptures: staticCaptures, dynamicCaptures: dynamicCaptures,
                            dynamicDrawBounds: dynamicDrawBounds,
                            directional: directional,
                            directionalSlots: directionalSlots, punctualFaces: punctualFaces,
                            forced: forceDirectional ? Set(directionalSlots) : [])

      retireDrawn(views: drawn)
      if !drawn.isEmpty { dispatchPageTable() }

      return directional.map { View(matrix: $0.viewProjection, splitFar: $0.splitFar) }
    }
  }
}
