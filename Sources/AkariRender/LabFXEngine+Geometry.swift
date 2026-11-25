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
import HydraKit
import LabFX
import LabGL
import simd

extension Akari.LabFXEngine
{
  /// per prim shading flags the record sorts meshes by.
  struct PrimFlags
  {
    /// prims with stylized shading or assembly, drawn through the deformer for their per corner vertices.
    var styled: Set<Int32> = []
    /// prims the transparency pass draws, always deformer drawn.
    var transparent: Set<Int32> = []
    var emitters: Set<Int32> = []
    /// prims seen only from the front, their back faces drop out of the view.
    var singleSided: Set<Int32> = []
    var opacity: [Int32: Float] = [:]
    /// opaque prims whose materials never cut holes in their shadows.
    var solidShadow: Set<Int32> = []
  }

  /// what the captures last recorded, and when.
  struct RecordState
  {
    var restyled = false
    var count = 0
    var at = Date.distantPast
    /// records that rebuilt the captures, not the deformer moving animated meshes.
    var rebuilds = 0
    var rebuiltAt = Date.distantPast
    /// the unique triangles the last record could hold.
    var budget = 0
    /// what the static and instanced captures last recorded.
    var staticKey: UInt64 = 0
    var instancedKey: UInt64 = 0
    /// the unique triangles the static captures last recorded.
    var triangles = 0
  }

  /// how the instances pick their levels.
  struct InstanceLOD
  {
    /// how much coarser than the camera's own pixels the instances pick their levels at, fit to the drawn budget.
    var detail: Float = 1
    /// the pixels a unit radius covers at unit clip w, for the camera's instance cull.
    var pixelScale: Float = 1
    /// whether `detail` is a record's fit yet, rather than its starting value.
    var fitted = false
  }

  /// the view the static captures were chosen for, and the viewport's eye since, to choose again once it settles somewhere new.
  struct ViewTracking
  {
    var camera: RecordCamera?
    var lastEye = SIMD3<Float>(repeating: .nan)
    var lastForward = SIMD3<Float>(repeating: .nan)
    var lastPixelScale: Float = .nan
    var eyeMoved = Date.distantPast
    var resized = Date.distantPast
    var reframe = false
    var reframing: Reframing?
  }

  /// the scene split into animated meshes and the rest, each in its own capture, so animated frames only rerecord what moves
  struct SceneGeometry
  {
    var staticCapture: LabGLCaptureBuffer?
    /// whether the gbuffer also drew the late culled static draws this frame, which the back layer then draws too
    var lateCulled = false
    /// what the shadows and probes draw for the static meshes, unwelded or with cages for refined meshes.
    var staticShadowCapture: LabGLCaptureBuffer?
    /// too many static triangles to unweld them all, the shadows draw `staticCapture`.
    var staticShadowShared = false
    /// static instanced prototypes, each drawn once per instance set.
    var staticInstancedCapture: LabGLCaptureBuffer?
    var dynamicCapture: LabGLCaptureBuffer?
    let staticRecorder = Akari.Geom.Recorder(keepsTopology: false)
    /// keeps the instanced prototypes caches apart from the static meshes.
    let instancedRecorder = Akari.Geom.Recorder(keepsTopology: false)
    /// builds the static shadow capture when refined meshes cast from their cages.
    let shadowRecorder = Akari.Geom.Recorder(keepsTopology: false)
    /// lays the animated meshes out once and deforms them on the gpu per frame.
    let deformer = Akari.Geom.Deformer()

    /// every visible mesh, by path key, kept current from the scene's drained changes.
    var meshes: [UInt64: Akari.Geom.Recorder.RawMesh] = [:]
    /// instance sets by key, so the meshes of one prototype share one copy.
    var instanceSets: [UInt64: Akari.Geom.Matrices] = [:]
    /// each cached mesh's prim id, to pick meshes out without copying them.
    var primIds: [UInt64: Int32] = [:]
    /// per mesh, a key of its data and transform.
    var changes: [UInt64: UInt64] = [:]
    /// meshes that changed after they appeared, they stay dynamic so a pause doesn't rerecord the static capture
    var animated: Set<UInt64> = []
    /// animated meshes the scene took away, kept laid out but not drawn.
    var hidden: Set<UInt64> = []
    /// mesh key to the keys of its per instance fallback copies.
    var expansions: [UInt64: [UInt64]] = [:]
    /// simplified meshes by content and triangle count, kept while they're drawn.
    var details: [UInt64: Detail] = [:]
    var flags = PrimFlags()
    var record = RecordState()
    var instanceLOD = InstanceLOD()
    var view = ViewTracking()

    var staticBatch = BatchSummary()
    var instancedBatch = BatchSummary()
    var dynamicBatch = BatchSummary()
    var cameraCull = CameraCull()
    /// this frame's deformed draws are encoded to the ones that reach into the camera
    var dynamicCulled = false
    /// the instanced capture's instances were culled to the camera this frame.
    var instancesCulled = false

    /// the non empty captures, static first.
    var captures: [LabGLCaptureBuffer]
    {
      [staticBatch.isEmpty ? nil : staticCapture,
       instancedBatch.isEmpty ? nil : staticInstancedCapture,
       dynamicBatch.isEmpty ? nil : dynamicCapture].compactMap(\.self)
    }

    var staticShadow: LabGLCaptureBuffer?
    {
      staticShadowShared ? staticCapture : staticShadowCapture
    }

    /// what the light probes capture, the static scene without what animates, unless nothing stands still
    var probeCaptures: [LabGLCaptureBuffer]
    {
      let still = [staticBatch.isEmpty ? nil : staticShadow, instancedBatch.isEmpty ? nil : staticInstancedCapture].compactMap(\.self)
      return still.isEmpty ? shadowCaptures : still
    }

    var shadowCaptures: [LabGLCaptureBuffer]
    {
      [staticBatch.isEmpty ? nil : staticShadow,
       instancedBatch.isEmpty ? nil : staticInstancedCapture,
       dynamicBatch.isEmpty ? nil : dynamicCapture].compactMap(\.self)
    }
  }

  /// the view the static captures are chosen for.
  struct RecordCamera
  {
    var planes: [SIMD4<Float>]
    var eye: SIMD3<Float>
    var pixelScale: Float
    /// the viewport's view, its half angle widened by `margin`.
    var forward: SIMD3<Float>
    var cone: Float
    static let margin: Float = 20 * .pi / 180

    init(view: Akari.Matrix4, projection: Akari.Matrix4, height: Int, frustum: Bool)
    {
      let m = (projection * view).simd
      func row(_ i: Int) -> SIMD4<Float>
      {
        SIMD4(m.columns.0[i], m.columns.1[i], m.columns.2[i], m.columns.3[i])
      }

      planes = !frustum ? [] : [row(3) + row(0), row(3) - row(0), row(3) + row(1), row(3) - row(1), row(3)].map
      {
        $0 / max(simd_length(SIMD3($0.x, $0.y, $0.z)), 1e-12)
      }

      eye = view.inverse().transform(.zero)
      pixelScale = abs(projection.simd.columns.1.y) * Float(max(height, 1)) / 2
      forward = simd_normalize(view.inverse().transform(SIMD3(0, 0, -1)) - eye)
      let tanX = 1 / max(abs(projection.simd.columns.0.x), 1e-6), tanY = 1 / max(abs(projection.simd.columns.1.y), 1e-6)
      cone = frustum ? .pi : min(atan((tanX * tanX + tanY * tanY).squareRoot()) + Self.margin, .pi)
    }

    /// the radius in pixels a sphere covers, zero when it's out of view or under half a pixel.
    func pixels(center: SIMD3<Float>, radius: Float) -> Float
    {
      for p in planes where simd_dot(SIMD3(p.x, p.y, p.z), center) + p.w < -radius
      {
        return 0
      }

      let distance = max(simd_distance(center, eye), 1e-4)
      var px = radius * pixelScale / distance
      if cone < .pi, acos(min(max(simd_dot(center - eye, forward) / distance, -1), 1)) - asin(min(radius / distance, 1)) > cone
      {
        px /= 3
      }

      return px < 0.5 ? 0 : px
    }
  }

  /// a mesh simplified to the screen it covers.
  struct Detail
  {
    var points: Pixar.VtVec3fArray
    var tris: Pixar.VtVec3iArray
    var uvs: Pixar.VtVec2fArray
    /// the original of each triangle when it was pruned, empty when clustered.
    var sources: Pixar.VtIntArray
  }

  /// what a recorded batch leaves behind for bounds and shadow casters.
  struct BatchSummary
  {
    var bounds: (min: SIMD3<Float>, max: SIMD3<Float>)?
    var casterBounds: [Float] = []
    var casterKeys: [UInt64] = []

    var isEmpty: Bool
    {
      bounds == nil
    }
  }

  func createCaptures() -> Bool
  {
    guard
      let staticCapture = labgl.captureCreate(),
      let staticShadowCapture = labgl.captureCreate(),
      let staticInstancedCapture = labgl.captureCreate(),
      let dynamicCapture = labgl.captureCreate()
    else { return false }

    // a capture made after another was destroyed can come back still holding that one's draws
    for capture in [staticCapture, staticShadowCapture, staticInstancedCapture, dynamicCapture]
    {
      labgl.captureClear(capture)
    }

    geometry.staticCapture = staticCapture
    geometry.staticShadowCapture = staticShadowCapture
    geometry.staticInstancedCapture = staticInstancedCapture
    geometry.dynamicCapture = dynamicCapture
    runtime.setMeshCapture(.meshStatic, buffer: staticCapture)
    let userdata = Unmanaged.passUnretained(self).toOpaque()
    runtime.setPassCallback(.drawDynamicGeometry, callback: akariDynamicGeometryCallback, userdata: userdata)
    runtime.setPassCallback(.drawStaticInstancedGeometry,
                            callback: akariStaticInstancedGeometryCallback, userdata: userdata)
    runtime.setPassCallback(.drawStaticGeometryBack, callback: akariStaticGeometryBackCallback, userdata: userdata)
    runtime.setPassCallback(.drawStaticInstancedGeometryBack,
                            callback: akariStaticInstancedGeometryBackCallback, userdata: userdata)
    runtime.setPassCallback(.drawDynamicGeometryBack, callback: akariDynamicGeometryBackCallback, userdata: userdata)
    return true
  }

  func destroyCaptures()
  {
    for capture in [geometry.staticCapture, geometry.staticShadowCapture,
                    geometry.staticInstancedCapture, geometry.dynamicCapture].compactMap(\.self)
    {
      labgl.captureDestroy(capture)
    }

    geometry = SceneGeometry()
  }

  /// drops what the scene that went away cached, its meshes would otherwise stay recorded under the new stage
  func adoptScene(_ id: UInt64)
  {
    // the first scene of a session has nothing cached yet, only a replacement does.
    let previous = lastSceneId
    lastSceneId = id
    guard previous != 0 else { return }

    destroyCaptures()
    releaseOutline()
    guard createCaptures(), createOutlineCapture()
    else
    {
      // keeping the old id has the next frame try again instead of drawing nothing for the whole scene.
      lastSceneId = previous
      return
    }

    lastGeometryRevision = 0
    sceneBounds = nil
    probes.automaticBox = nil
    water = nil
    waterKeys = []
    styles.revision = .max
    styles.transparent = []
    styles.emitters = []
    styles.singleSided = []
    styles.opacity = [:]
    styles.solidShadow = []
    pointLights.slots = []
    pointLights.mains = []
    pointLights.mainSince = [:]
    pointLights.importance = [:]
    pointLights.positions = [:]
    pointLights.following = []
    shadowAtlas.mainSlots = []
    transparency.causticKey = 0
    transparency.causticsTraced = false
    transparency.causticsFull = false
    transparency.glassMapKey = 0
    transparency.glassMapsDrawn = false

    // a new scene counts its revisions from the start again, so each sync below is made to run rather than trusted to see a change
    forceDomeReload = true
    atmosphere.revision = .max
    volumes.revision = .max
    probes.overrideRevision = .max
    probes.overrides = []
    probes.structuralRevision = 0
    environment.sunSceneBounds = nil
    environment.authoredSun = .dome("\u{0}")
    shadowAtlas.forgetScene()
    lightProbes.forgetScene()
    glassCaustics.forgetRays()
    resetHistory()
  }

  // every pass that replays the deformed draws looks through the camera, so it skips the ones wholly outside it
  fileprivate func drawDynamicGeometry()
  {
    guard !geometry.dynamicBatch.isEmpty, let dynamicCapture = geometry.dynamicCapture else { return }
    guard geometry.dynamicCulled else { return labgl_capturePlaybackIndirect(dynamicCapture) }
    labgl.capturePlaybackIndirectCulled(dynamicCapture, slot: Self.dynamicCameraSlot)
  }

  fileprivate func drawStaticInstancedGeometry()
  {
    guard !geometry.instancedBatch.isEmpty, let capture = geometry.staticInstancedCapture else { return }
    if geometry.instancesCulled { labgl.capturePlaybackInstancesCulled(capture, slot: 0) }
    else { labgl.capturePlayback(capture) }
  }

  // culls front faces for the back layer, then turns culling off again as every later pass expects

  private func withFrontFacesCulled(_ draw: () -> Void)
  {
    // the gl face names, spelled out since two modules both declare the back one
    let front = GLenum(0x0404), back = GLenum(0x0405)

    gl.enable(GL_CULL_FACE)
    gl.cullFace(front)
    draw()
    gl.cullFace(back)
    gl.disable(GL_CULL_FACE)
  }

  fileprivate func drawStaticGeometryBack()
  {
    guard let capture = geometry.staticCapture else { return }
    withFrontFacesCulled
    {
      // the same camera culled draws the gbuffer replayed, early and late, or every draw when culling failed
      guard geometry.cameraCull.encoded else { return labgl_capturePlaybackIndirect(capture) }
      labgl.capturePlaybackIndirectCulled(capture, slot: UInt32(Self.cameraCullSlot))
      if geometry.lateCulled { labgl.capturePlaybackIndirectCulled(capture, slot: UInt32(Self.cameraLateCullSlot)) }
    }
  }

  fileprivate func drawStaticInstancedGeometryBack()
  {
    withFrontFacesCulled { drawStaticInstancedGeometry() }
  }

  fileprivate func drawDynamicGeometryBack()
  {
    withFrontFacesCulled { drawDynamicGeometry() }
  }
}

/// `Runtime.setPassCallback` takes a plain c function pointer.
private func akariDynamicGeometryCallback(_ userdata: UnsafeMutableRawPointer?, _: Int32, _: Int32)
{
  guard let userdata else { return }
  Unmanaged<Akari.LabFXEngine>.fromOpaque(userdata).takeUnretainedValue().drawDynamicGeometry()
}

/// `Runtime.setPassCallback` takes a plain c function pointer.
private func akariStaticGeometryBackCallback(_ userdata: UnsafeMutableRawPointer?, _: Int32, _: Int32)
{
  guard let userdata else { return }
  Unmanaged<Akari.LabFXEngine>.fromOpaque(userdata).takeUnretainedValue().drawStaticGeometryBack()
}

/// `Runtime.setPassCallback` takes a plain c function pointer.
private func akariStaticInstancedGeometryBackCallback(_ userdata: UnsafeMutableRawPointer?, _: Int32, _: Int32)
{
  guard let userdata else { return }
  Unmanaged<Akari.LabFXEngine>.fromOpaque(userdata).takeUnretainedValue().drawStaticInstancedGeometryBack()
}

/// `Runtime.setPassCallback` takes a plain c function pointer.
private func akariDynamicGeometryBackCallback(_ userdata: UnsafeMutableRawPointer?, _: Int32, _: Int32)
{
  guard let userdata else { return }
  Unmanaged<Akari.LabFXEngine>.fromOpaque(userdata).takeUnretainedValue().drawDynamicGeometryBack()
}

/// `Runtime.setPassCallback` takes a plain c function pointer.
private func akariStaticInstancedGeometryCallback(_ userdata: UnsafeMutableRawPointer?, _: Int32, _: Int32)
{
  guard let userdata else { return }
  Unmanaged<Akari.LabFXEngine>.fromOpaque(userdata).takeUnretainedValue().drawStaticInstancedGeometry()
}

