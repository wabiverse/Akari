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
  /// Per prim shading flags the record sorts meshes by.
  struct PrimFlags
  {
    /// Prims with stylized shading or assembly, drawn through the deformer for their per corner vertices.
    var styled: Set<Int32> = []
    /// Prims the transparency pass draws, always deformer drawn.
    var transparent: Set<Int32> = []
    var emitters: Set<Int32> = []
    var opacity: [Int32: Float] = [:]
    /// Opaque prims whose materials never cut holes in their shadows.
    var solidShadow: Set<Int32> = []
  }

  /// What the captures last recorded, and when.
  struct RecordState
  {
    var restyled = false
    var count = 0
    var at = Date.distantPast
    /// Records that rebuilt the captures, not the deformer moving animated meshes.
    var rebuilds = 0
    var rebuiltAt = Date.distantPast
    /// The unique triangles the last record could hold.
    var budget = 0
    /// What the static and instanced captures last recorded.
    var staticKey: UInt64 = 0
    var instancedKey: UInt64 = 0
    /// The unique triangles the static captures last recorded.
    var triangles = 0
  }

  /// How the instances pick their levels.
  struct InstanceLOD
  {
    /// How much coarser than the camera's own pixels the instances pick their levels at, fit to the drawn budget.
    var detail: Float = 1
    /// The pixels a unit radius covers at unit clip w, for the camera's instance cull.
    var pixelScale: Float = 1
    /// Whether `detail` is a record's fit yet, rather than its starting value.
    var fitted = false
  }

  /// The view the static captures were chosen for, and the viewport's eye since, to choose again once it settles somewhere new.
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

  /// The scene split into meshes that have animated and the rest, each
  /// in its own capture, so animated frames only rerecord what moves.
  struct SceneGeometry
  {
    var staticCapture: LabGLCaptureBuffer?
    /// The static meshes unwelded, which the shadows and probes draw faster.
    var staticShadowCapture: LabGLCaptureBuffer?
    /// Too many static triangles to unweld them all, the shadows draw `staticCapture`.
    var staticShadowShared = false
    /// Static instanced prototypes, each drawn once per instance set.
    var staticInstancedCapture: LabGLCaptureBuffer?
    var dynamicCapture: LabGLCaptureBuffer?
    let staticRecorder = Akari.Geom.Recorder(keepsTopology: false)
    /// Keeps the instanced prototypes caches apart from the static meshes.
    let instancedRecorder = Akari.Geom.Recorder(keepsTopology: false)
    /// Lays the animated meshes out once and deforms them on the GPU per frame.
    let deformer = Akari.Geom.Deformer()

    /// Every visible mesh, by path key, kept current from the scene's drained changes.
    var meshes: [UInt64: Akari.Geom.Recorder.RawMesh] = [:]
    /// Instance sets by key, so the meshes of one prototype share one copy.
    var instanceSets: [UInt64: Akari.Geom.Matrices] = [:]
    /// Each cached mesh's prim id, to pick meshes out without copying them.
    var primIds: [UInt64: Int32] = [:]
    /// Per mesh, a key of its data and transform.
    var changes: [UInt64: UInt64] = [:]
    /// Meshes that changed after they first appeared. They stay dynamic, a pause
    /// demoting them would rerecord the static capture and rebuild them on the way back.
    var animated: Set<UInt64> = []
    /// Animated meshes the scene took away, kept laid out but not drawn.
    var hidden: Set<UInt64> = []
    /// Mesh key to the keys of its per instance fallback copies.
    var expansions: [UInt64: [UInt64]] = [:]
    /// Simplified meshes by content and triangle count, kept while they're drawn.
    var details: [UInt64: Detail] = [:]
    var flags = PrimFlags()
    var record = RecordState()
    var instanceLOD = InstanceLOD()
    var view = ViewTracking()

    var staticBatch = BatchSummary()
    var instancedBatch = BatchSummary()
    var dynamicBatch = BatchSummary()
    var cameraCull = CameraCull()
    /// The instanced capture's instances were culled to the camera this frame.
    var instancesCulled = false

    /// The non empty captures, static first.
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

    var shadowCaptures: [LabGLCaptureBuffer]
    {
      [staticBatch.isEmpty ? nil : staticShadow,
       instancedBatch.isEmpty ? nil : staticInstancedCapture,
       dynamicBatch.isEmpty ? nil : dynamicCapture].compactMap(\.self)
    }
  }

  /// The view the static captures are chosen for.
  struct RecordCamera
  {
    var planes: [SIMD4<Float>]
    var eye: SIMD3<Float>
    var pixelScale: Float
    /// The viewport's view, its half angle widened by `margin`.
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

    /// The radius in pixels a sphere covers, zero when it's out of view or under half a pixel.
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

  /// A mesh simplified to the screen it covers.
  struct Detail
  {
    var points: Pixar.VtVec3fArray
    var tris: Pixar.VtVec3iArray
    var uvs: Pixar.VtVec2fArray
    /// The original of each triangle when it was pruned, empty when clustered.
    var sources: Pixar.VtIntArray
  }

  /// What a recorded batch leaves behind for bounds and shadow casters.
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

    geometry.staticCapture = staticCapture
    geometry.staticShadowCapture = staticShadowCapture
    geometry.staticInstancedCapture = staticInstancedCapture
    geometry.dynamicCapture = dynamicCapture
    runtime.setMeshCapture(.meshStatic, buffer: staticCapture)
    let userdata = Unmanaged.passUnretained(self).toOpaque()
    runtime.setPassCallback(.drawDynamicGeometry, callback: akariDynamicGeometryCallback, userdata: userdata)
    runtime.setPassCallback(.drawStaticInstancedGeometry,
                            callback: akariStaticInstancedGeometryCallback, userdata: userdata)
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

  fileprivate func drawDynamicGeometry()
  {
    guard !geometry.dynamicBatch.isEmpty, let dynamicCapture = geometry.dynamicCapture else { return }
    labgl_capturePlaybackIndirect(dynamicCapture)
  }

  fileprivate func drawStaticInstancedGeometry()
  {
    guard !geometry.instancedBatch.isEmpty, let capture = geometry.staticInstancedCapture else { return }
    if geometry.instancesCulled { labgl.capturePlaybackInstancesCulled(capture, slot: 0) }
    else { labgl.capturePlayback(capture) }
  }
}

/// `Runtime.setPassCallback` takes a plain C function pointer.
private func akariDynamicGeometryCallback(_ userdata: UnsafeMutableRawPointer?, _: Int32, _: Int32)
{
  guard let userdata else { return }
  Unmanaged<Akari.LabFXEngine>.fromOpaque(userdata).takeUnretainedValue().drawDynamicGeometry()
}

/// `Runtime.setPassCallback` takes a plain C function pointer.
private func akariStaticInstancedGeometryCallback(_ userdata: UnsafeMutableRawPointer?, _: Int32, _: Int32)
{
  guard let userdata else { return }
  Unmanaged<Akari.LabFXEngine>.fromOpaque(userdata).takeUnretainedValue().drawStaticInstancedGeometry()
}
