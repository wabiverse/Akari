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
  /// One shadow tile/page pipeline shared by every shadow casting light.
  final class ShadowAtlas
  {
    /// A rendered directional view, everything the deferred shader needs to sample it.
    public struct View: Sendable
    {
      /// world -> light clip space.
      public var matrix: Matrix4
      /// View depth this cascade covers up to, or a clipmap level's own light space radius.
      public var splitFar: Float
    }

    /// The froxel grid the volume scatter pass lights this frame.
    public struct VolumeFroxels: Sendable
    {
      /// Froxels per slice, the volume atlas's 8x8 slice tiles.
      public var gridWidth: Int
      public var gridHeight: Int
      /// View depth range, slices spaced across it.
      public var near: Float
      public var far: Float
      public var inverseProjection: Matrix4
      /// Farthest view depth per froxel column.
      public var depthTexture: GLuint

      public init(gridWidth: Int, gridHeight: Int, near: Float, far: Float,
                  inverseProjection: Matrix4, depthTexture: GLuint)
      {
        self.gridWidth = gridWidth
        self.gridHeight = gridHeight
        self.near = near
        self.far = far
        self.inverseProjection = inverseProjection
        self.depthTexture = depthTexture
      }
    }

    /// The directional light's fitted basis, as the deferred shader samples it.
    public struct Sun: Sendable
    {
      /// Pure light rotation basis.
      public var rotation: Matrix4 = .identity
      public var eyeToLightRotation: Matrix4 = .identity
      public var refOffset: SIMD3<Float> = .zero
      public var isClipmap = true
      public var lodMin: Int32 = 0
      public var lodMax: Int32 = 0
      /// Level bias the shading pick must add.
      public var lodBias: Float = 0
    }

    public internal(set) var sun = Sun()
    /// Shared page pool.
    public internal(set) var atlas: GLuint = 0
    /// Per tilemap slot data.
    public internal(set) var data: GLuint = 0
    public internal(set) var pageTable: GLuint = 0

    var kernels = Kernels()
    var depthShader: GLuint = 0
    var buffers = Buffers()
    var frames: [Frame] = []
    var ringCursor = 0
    var frame: Frame
    {
      frames.isEmpty ? Frame() : frames[ringCursor]
    }

    var culling = DrawCulling()
    var casters = CasterBounds()
    var amplification = Amplification()
    /// Transient depth test, one tilemap of texels.
    var atlasDepth: GLuint = 0
    var atlasTarget: GLuint = 0
    var dataPixels = [Float](repeating: 0, count: dataTextureWidth * 4 * maxTilemaps)
    var resourcesReady = false

    var sunMotion = SunMotion()
    var directionalHistory = DirectionalHistory()
    var punctualHistory = PunctualHistory()
    var lastSceneRevision: UInt64 = .max
    var lastRenderSceneRevision: UInt64 = .max

    public init()
    {}

    deinit
    {
      release()
    }

    /// Dispatches the whole GPU pipeline.
    public func markPageUsage(gbufferPosition: GLuint,
                              camera: Camera,
                              screenWidth: Int,
                              screenHeight: Int,
                              settings _: ShadowSettings,
                              lights: [Akari.Lux.PointLight],
                              sceneRevision: UInt64,
                              volume: VolumeFroxels? = nil)
    {
      guard
        gbufferPosition != 0,
        screenWidth > 0,
        screenHeight > 0,
        ensureResources()
      else { return }

      var punctualDirty = punctualHistory.pendingDirty
      punctualHistory.pendingDirty = 0

      if sceneRevision != lastSceneRevision { punctualDirty = -1 }
      lastSceneRevision = sceneRevision

      ringCursor = (ringCursor + 1) % Self.bufferRing
      dispatchBeginFrame(dirty: punctualDirty)

      let invView = camera.view.inverse()
      let lightCount = min(lights.count, Self.maxPunctualLights)
      let sunActive = !directionalHistory.slots.isEmpty

      if let volume, sunActive || lightCount > 0
      {
        dispatchTagUsageVolume(volume,
                               invView: invView,
                               camera: camera,
                               screenWidth: screenWidth,
                               screenHeight: screenHeight,
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
                                 camera: camera,
                                 lights: lights,
                                 lightCount: lightCount)
      }

      dispatchPageAllocation(lightCount: lightCount)
    }

    /// Fits every active tilemap and draws its stale views.
    public func render(capture: OpaquePointer,
                       camera: Camera,
                       lightDirection: SIMD3<Float>,
                       sceneBounds: (min: SIMD3<Float>, max: SIMD3<Float>),
                       casterBounds: [Float],
                       sceneRevision: UInt64,
                       frameIndex _: UInt64,
                       settings: ShadowSettings,
                       lights: [Akari.Lux.PointLight],
                       punctualFarDistance: Float) -> [View]
    {
      guard ensureResources() else { return [] }

      let castersMoved = sceneRevision != lastRenderSceneRevision
      lastRenderSceneRevision = sceneRevision

      let corners = Self.sceneCorners(sceneBounds)
      let technique = Self.resolveTechnique(camera: camera)

      let sunChanged = sunMotion.advance(to: Self.quantize(lightDirection))
      var fitSettings = settings
      fitSettings.levelLodBias = (settings.levelLodBias + sunMotion.lodBias).rounded()

      let fit: DirectionalFit = switch technique
      {
        case .cascaded:
          Self.fitCascades(camera: camera,
                           lightDirection: lightDirection,
                           sceneCorners: corners,
                           settings: fitSettings)
        case .clipmap:
          Self.fitLevels(camera: camera,
                         lightDirection: lightDirection,
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
        return Self.fitPunctual(lightPosition: lights[slot].position,
                                near: max(lights[slot].radius, 0.02),
                                far: punctualFarDistance)
      }

      let inverseView = camera.view.inverse()
      writeDataTexture(directional: directional,
                       directionalSlots: directionalSlots,
                       punctualFaces: punctualFaces,
                       inverseView: inverseView)
      punctualHistory.update(punctualFaces)
      directionalHistory.updateShifts(directional, slots: directionalSlots)
      dispatchTilemapShift(forceFullShift: castersMoved)

      uploadLevelParams(directional: directional, directionalSlots: directionalSlots,
                        inverseView: inverseView)
      dispatchTileMapMaintenance(casterBounds: casterBounds,
                                 slotCount: directionalSlots.isEmpty ? 0 : Self.maxDirectionalTilemaps,
                                 lightZ: lightDirection,
                                 cameraWorld: SIMD3(inverseView[3, 0],
                                                    inverseView[3, 1],
                                                    inverseView[3, 2]),
                                 castersMoved: castersMoved)
      dispatchPageTable()
      dispatchSelectViews()

      let forcePunctual = camera.view.simd != directionalHistory.view.simd || punctualHistory.invalidated
      punctualHistory.invalidated = punctualHistory.pendingDirty != 0

      let drawn = drawViews(capture: capture, directional: directional,
                            directionalSlots: directionalSlots, punctualFaces: punctualFaces,
                            forced: sunChanged ? Set(directionalSlots) : [],
                            forcePunctual: forcePunctual)

      retireDrawn(views: sunChanged ? drawn : drawn.filter { $0 >= Self.punctualViewBase })
      if sunChanged || forcePunctual, !drawn.isEmpty { dispatchPageTable() }

      directionalHistory.slots = directionalSlots
      directionalHistory.view = camera.view

      return directional.map { View(matrix: $0.viewProjection, splitFar: $0.splitFar) }
    }
  }
}
