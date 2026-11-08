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
import HydraKit

public extension Akari
{
  /// The viewport looks through a stage camera, following
  /// it as time plays, until the view is orbited, panned
  /// or zoomed off it.
  final class CameraView: @unchecked Sendable
  {
    public weak var hydra: Hydra.RenderEngine?
    public weak var akari: Akari.RenderEngine?

    /// Called on the main actor when the view has eased into the camera.
    public var onArrive: (@MainActor @Sendable () -> Void)?
    /// Called on the main actor when the viewport is moved off the camera.
    public var onLeave: (@MainActor @Sendable () -> Void)?

    /// How long the view eases between shots.
    public static let smoothView = 0.2

    /// The render frame's width over its height, safe to set from any thread.
    public var aspect: Double
    {
      get { lock.withLock { _aspect } }
      set { lock.withLock { _aspect = newValue } }
    }

    private let lock = NSLock()
    private var _aspect = 16.0 / 9.0
    private var request: String??
    private let isZUp: Bool
    private var camera: UsdGeom.Camera?
    private var saved: FinalRender.ViewState?
    private var posed: [Double]?
    private var transition: (from: Shot, start: Double)?

    /// Where a view is, and what it sees.
    private struct Shot
    {
      var eye: Pixar.GfVec3d
      var rotation: Pixar.GfQuatd
      var fov: Double
      var near: Double?
      var far: Double?

      init(_ view: Hydra.Camera)
      {
        let transform = view.getTransform()
        eye = transform.ExtractTranslation()
        rotation = transform.ExtractRotationQuat()
        fov = 2 * atan(0.5 * Double(view.gfCamera.horizontalAperture) / Double(view.gfCamera.focalLength))
        near = view.nearClipOverride
        far = view.farClipOverride
      }
    }

    public init(hydra: Hydra.RenderEngine, akari: Akari.RenderEngine)
    {
      self.hydra = hydra
      self.akari = akari
      isZUp = UsdGeom.getUpAxis(for: hydra.stage) == .z
    }

    /// Looks through the camera at `path`, or back at the viewport's own view when `nil`.
    public func look(through path: String?)
    {
      lock.withLock { request = .some(path) }
    }

    /// The fraction of the viewport's height the render frame fills, leaving a margin around it.
    public static func frameHeight(viewAspect: Double, aspect: Double) -> Double
    {
      0.9 * min(1, viewAspect / max(aspect, 0.001))
    }

    /// Poses the viewport, on the frame queue before each frame.
    func update()
    {
      guard let hydra, let akari else { return }
      let (request, aspect) = lock.withLock
      {
        defer { self.request = nil }
        return (self.request, _aspect)
      }

      let view = hydra.viewCamera
      let now = ProcessInfo.processInfo.systemUptime

      if let request
      {
        let next = request.map { UsdGeom.Camera(hydra.stage.getPrim(at: $0)) }
        if let next, next.GetPrim().isValid
        {
          if saved == nil { saved = FinalRender.ViewState(view, timeCode: hydra.currentTimeCode) }
          transition = (Shot(view), now)
          camera = next
        }
        else if camera != nil
        {
          transition = (Shot(view), now)
          camera = nil
        }

        posed = nil
      }

      if let posed, posed != Self.placement(view)
      {
        orbitAhead(view)
        leave(notify: camera != nil)
        return
      }

      akari.labfx.usdVolume = Pixar.HdAkariStageVolumeAt(hydra.stage, hydra.currentTimeCode)
      akari.labfx.usdFogDisturbers = FinalRender.fogDisturbers(hydra.stage, hydra.currentTimeCode)
      let fogSim = akari.labfx.fogSim, time = hydra.currentTimeCode, zUp = UsdGeom.getUpAxis(for: hydra.stage) == .z
      let fps = Pixar.HdAkariTimeCodesPerSecond(hydra.stage)
      akari.labfx.waterTime = time / (fps > 0 ? fps : 24)
      akari.labfx.sceneFrameRate = fps > 0 ? fps : 24
      akari.labfx.fogSimRequest = { [hydra] in FinalRender.advanceFogSim(fogSim, stage: hydra.stage, to: time, zUp: zUp, framesPerSecond: fps, preview: true) }
      var lens = Pixar.HdAkariCameraLens()
      lens.focalLength = Double(view.gfCamera.focalLength)
      lens.horizontalAperture = Double(view.gfCamera.horizontalAperture)
      akari.labfx.viewportLens = lens
      akari.labfx.focusObjectDistance = Self.focusDistance(view, settings: akari.settings.depthOfField, stage: hydra.stage, time: time)
      guard camera != nil || transition != nil else { return }
      let size = akari.viewportSize
      guard size.width > 1, size.height > 1 else { return }

      if let camera
      {
        let viewAspect = Double(size.width) / Double(size.height)
        FinalRender.pose(view, from: camera.GetCamera(Usd.TimeCode(hydra.currentTimeCode)),
                         aspect: aspect * Self.frameHeight(viewAspect: viewAspect, aspect: aspect), isZUp: isZUp)
        let shutter = Pixar.HdAkariCameraShutter(hydra.stage, std.string(camera.GetPrim().GetPath().string), hydra.currentTimeCode)
        akari.labfx.usdCameraShutter = SIMD2(Float(shutter.open), Float(shutter.close))
        akari.labfx.usdCameraLens = Pixar.HdAkariCameraLensAt(hydra.stage, std.string(camera.GetPrim().GetPath().string), hydra.currentTimeCode)
      }
      else
      {
        akari.labfx.usdCameraShutter = nil
        akari.labfx.usdCameraLens = nil
        saved?.restore(hydra, time: false)
      }

      if let transition
      {
        let t = (now - transition.start) / Self.smoothView
        if t < 1
        {
          apply(Self.blend(transition.from, Shot(view), t * t * (3 - 2 * t)), to: view)
        }
        else
        {
          self.transition = nil
          if camera == nil
          {
            leave(notify: false)
            return
          }

          if let onArrive { Task { @MainActor in onArrive() } }
        }
      }

      posed = Self.placement(view)
    }

    /// How far ahead of the view its focus object's point is, along the view.
    private static func focusDistance(_ view: Hydra.Camera, settings: DepthOfFieldSettings, stage: UsdStage, time: Double) -> Double?
    {
      guard !settings.focusObject.isEmpty else { return nil }
      var p = [settings.focusPoint.x, settings.focusPoint.y, settings.focusPoint.z]
      _ = Pixar.HdAkariPrimTransformPoint(stage, std.string(settings.focusObject), time, false, &p)
      let transform = view.getTransform()
      let eye = transform.ExtractTranslation()
      let ahead = transform.TransformDir(Pixar.GfVec3d(0, 0, -1))
      let length = max((ahead[0] * ahead[0] + ahead[1] * ahead[1] + ahead[2] * ahead[2]).squareRoot(), 1e-9)
      let along = ((p[0] - eye[0]) * ahead[0] + (p[1] - eye[1]) * ahead[1] + (p[2] - eye[2]) * ahead[2]) / length
      return along > 0 ? along : nil
    }

    private static func blend(_ a: Shot, _ b: Shot, _ t: Double) -> Shot
    {
      var shot = b
      shot.eye = Pixar.GfVec3d(a.eye[0] + (b.eye[0] - a.eye[0]) * t,
                               a.eye[1] + (b.eye[1] - a.eye[1]) * t,
                               a.eye[2] + (b.eye[2] - a.eye[2]) * t)
      shot.rotation = Pixar.GfSlerp(t, a.rotation, b.rotation)
      shot.fov = a.fov + (b.fov - a.fov) * t
      shot.near = b.near ?? a.near
      shot.far = b.far ?? a.far
      return shot
    }

    private func apply(_ shot: Shot, to view: Hydra.Camera)
    {
      var transform = Pixar.GfMatrix4d(1.0)
      _ = transform.SetRotate(shot.rotation)
      _ = transform.SetTranslateOnly(shot.eye)
      var lens = Gf.Camera()
      lens.transform = transform
      lens.focalLength = 50
      lens.horizontalAperture = Float(100 * tan(shot.fov / 2))
      FinalRender.pose(view, from: lens, aspect: 1, isZUp: isZUp)
      view.nearClipOverride = shot.near
      view.farClipOverride = shot.far
    }

    /// Leaves the view where the camera was, with the viewport's own lens,
    /// orbiting the point on its view nearest where the viewport orbited
    /// before.
    private func orbitAhead(_ view: Hydra.Camera)
    {
      guard let saved else { return }
      let transform = view.getTransform()
      let eye = transform.ExtractTranslation()
      let ahead = transform.TransformDir(Pixar.GfVec3d(0, 0, -1))
      let length = max((ahead[0] * ahead[0] + ahead[1] * ahead[1] + ahead[2] * ahead[2]).squareRoot(), 1e-9)
      let along = ((saved.focus[0] - eye[0]) * ahead[0] + (saved.focus[1] - eye[1]) * ahead[1]
        + (saved.focus[2] - eye[2]) * ahead[2]) / length
      let distance = along > 0.01 ? along : 1
      view.focus = Pixar.GfVec3d(eye[0] + ahead[0] / length * distance,
                                 eye[1] + ahead[1] / length * distance,
                                 eye[2] + ahead[2] / length * distance)
      view.distance = distance
      view.gfCamera = saved.lens
      view.nearClipOverride = saved.near
      view.farClipOverride = saved.far
    }

    private func leave(notify: Bool)
    {
      // the free view has no shutter or lens of the camera it left.
      akari?.labfx.usdCameraShutter = nil
      akari?.labfx.usdCameraLens = nil
      camera = nil
      saved = nil
      posed = nil
      transition = nil
      guard notify, let onLeave else { return }
      Task { @MainActor in onLeave() }
    }

    private static func placement(_ view: Hydra.Camera) -> [Double]
    {
      [view.rotation[0], view.rotation[1], view.rotation[2],
       view.focus[0], view.focus[1], view.focus[2], view.distance]
    }
  }
}
