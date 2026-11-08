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
@_exported import SwiftCrossUI
#if canImport(Metal)
  import Metal
#endif

public extension Akari
{
  /// Renders stage frames for output. Each frame is its time code, seen through
  /// the output camera, accumulated over the render sample count from a clean
  /// history, read back, and written as an image or a movie frame.
  ///
  /// The whole job runs on Hydra's frame queue, so the interactive viewport
  /// waits rather than interleaving its own frames (and sizes) between samples.
  final class FinalRender: @unchecked Sendable
  {
    public enum Job: Sendable, Equatable
    {
      /// One frame, `F12`.
      case image(frame: Int)
      /// Every frame of the output range, `Ctrl F12`.
      case animation
    }

    public enum Status: Sendable, Equatable
    {
      case preparing
      case rendering
      case finished
      case cancelled
      case failed(String)

      public var isActive: Bool
      {
        self == .preparing || self == .rendering
      }
    }

    /// A finished frame, display encoded RGBA, rows top to bottom.
    public struct Image: Sendable
    {
      public let width: Int
      public let height: Int
      public let rgba: [UInt8]
    }

    public struct Progress: Sendable
    {
      public var job: Job
      public var status: Status = .preparing
      /// The frame being rendered (a time code).
      public var frame: Int
      /// Position of `frame` in the job, from 1.
      public var frameNumber = 0
      public var frameCount: Int
      public var sample = 0
      public var samples: Int
      /// Set to `frame` once that frame is written.
      public var finishedFrame: Int?
      public var elapsed: TimeInterval = 0
      public var lastFrameTime: TimeInterval = 0
      /// Estimated from the average frame time so far.
      public var remaining: TimeInterval?
      /// The most recently finished frame.
      public var image: Image?
      /// Where the most recent frame or the movie was written.
      public var output: URL?
    }

    public weak var hydra: Hydra.RenderEngine?
    public weak var akari: Akari.RenderEngine?
    public private(set) var stageInfo: Pixar.HdAkariStageInfo
    public private(set) var hasAuthoredTimeCodeRange: Bool

    private let lock = NSLock()
    private var _cancelled = false
    private var _running = false
    private var _lastFrame: Frame?

    /// The most recently rendered frame, at its full color depth.
    public var lastFrame: Frame?
    {
      lock.withLock { _lastFrame }
    }

    public init(hydra: Hydra.RenderEngine, akari: Akari.RenderEngine)
    {
      self.hydra = hydra
      self.akari = akari
      stageInfo = Pixar.HdAkariInspectStage(hydra.stage)
      hasAuthoredTimeCodeRange = hydra.stage.HasAuthoredTimeCodeRange()
    }

    /// Reads the cameras, frame range and soundtrack of the stage hydra now shows.
    public func adoptStage()
    {
      guard let hydra else { return }
      stageInfo = Pixar.HdAkariInspectStage(hydra.stage)
      hasAuthoredTimeCodeRange = hydra.stage.HasAuthoredTimeCodeRange()
    }

    public var isRunning: Bool
    {
      lock.withLock { _running }
    }

    /// Stops after the current sample, keeping what was written.
    public func cancel()
    {
      lock.withLock { _cancelled = true }
    }

    private var isCancelled: Bool
    {
      lock.withLock { _cancelled }
    }

    /// Starts `job` on the frame queue, reporting on the main actor.
    /// Returns `false` when a render is already running.
    @discardableResult
    public func start(_ job: Job,
                      output: OutputSettings,
                      onProgress: @escaping @MainActor @Sendable (Progress) -> Void) -> Bool
    {
      let began = lock.withLock
      {
        guard !_running else { return false }
        _running = true
        _cancelled = false
        return true
      }

      guard began, let hydra else { lock.withLock { _running = false }; return false }

      hydra.performOnFrameQueue
      { [self] in
        run(job, output: output) { progress in Task { @MainActor in onProgress(progress) } }
        lock.withLock { _running = false }
      }

      return true
    }

    /// Runs `job` on the calling thread, for background (`-b`) renders.
    /// Call it from a thread that isn't drawing a viewport.
    public func runBlocking(_ job: Job, output: OutputSettings, onProgress: @escaping @Sendable (Progress) -> Void)
    {
      guard let hydra else { return }
      lock.withLock
      {
        _running = true
        _cancelled = false
      }

      hydra.frameQueue.sync
      {
        run(job, output: output, report: onProgress)
      }

      lock.withLock { _running = false }
    }

    private func run(_ job: Job, output: OutputSettings, report: (Progress) -> Void)
    {
      let frames: [Int] = switch job
      {
        case let .image(frame): [frame]
        case .animation: output.frames
      }

      let samples = max(akari?.settings.renderSamples ?? 1, 1)
      var progress = Progress(job: job, frame: frames.first ?? 0, frameCount: frames.count, samples: samples)

      guard let hydra, let akari
      else
      {
        progress.status = .failed("the render engine went away")
        return report(progress)
      }
      #if canImport(Metal)
        let size = output.pixelSize
        let camera = output.cameraPath.map { UsdGeom.Camera(hydra.stage.getPrim(at: $0)) }
        if let path = output.cameraPath, camera?.GetPrim().isValid != true
        {
          progress.status = .failed("no camera at \(path)")
          return report(progress)
        }

        let movie: MovieWriter?
        do
        {
          movie = try makeMovie(job, output: output)
        }
        catch
        {
          progress.status = .failed("\(error)")
          return report(progress)
        }

        let saved = ViewState(hydra.viewCamera, timeCode: hydra.currentTimeCode)
        let isZUp = UsdGeom.getUpAxis(for: hydra.stage) == .z
        let began = Date()
        defer
        {
          Self.clearStageOverrides(akari)
          saved.restore(hydra)
        }

        progress.status = .rendering
        report(progress)

        var placeholder: URL?
        for (index, frame) in frames.enumerated()
        {
          let frameBegan = Date()
          progress.frame = frame
          progress.frameNumber = index + 1
          progress.sample = 0
          report(progress)

          let url = output.fileURL(frame: frame)
          if movie == nil, job == .animation, !output.overwrite, FileManager.default.fileExists(atPath: url.path)
          {
            continue
          }

          if movie == nil, job == .animation, output.placeholders
          {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if FileManager.default.createFile(atPath: url.path, contents: nil) { placeholder = url }
          }

          let timeCode = Double(frame)
          hydra.currentTimeCode = timeCode
          let pose: (Double) -> Void =
          { time in
            guard let camera else { return }
            Self.pose(hydra.viewCamera, from: camera.GetCamera(Usd.TimeCode(time)),
                      aspect: Double(size.width) / Double(size.height), isZUp: isZUp)
          }

          pose(timeCode)
          applyStageOverrides(at: timeCode, cameraPath: output.cameraPath, hydra: hydra, akari: akari, isZUp: isZUp)

          guard let texture = accumulate(at: timeCode, size: size, samples: samples,
                                         hydra: hydra, akari: akari, pose: pose,
                                         progress: &progress, report: report)
          else
          {
            progress.status = isCancelled ? .cancelled : .failed("frame \(frame) did not render")
            break
          }

          guard let image = autoreleasepool(invoking: { Self.readback(texture, queue: Self.queue(hydra), depth: output.colorDepth) })
          else
          {
            progress.status = .failed("frame \(frame) could not be read back")
            break
          }

          lock.withLock { _lastFrame = image }
          do
          {
            if let written = try Self.write(image, index: index, to: movie, url: url, animation: job == .animation,
                                            output: output)
            {
              placeholder = nil
              progress.output = written
            }
          }
          catch
          {
            progress.status = .failed("\(error)")
            break
          }

          progress.image = image.display
          progress.finishedFrame = frame
          progress.lastFrameTime = Date().timeIntervalSince(frameBegan)
          progress.elapsed = Date().timeIntervalSince(began)
          progress.remaining = progress.elapsed / Double(index + 1) * Double(frames.count - index - 1)
          report(progress)

          if isCancelled
          {
            progress.status = .cancelled
            break
          }
        }

        if let movie
        {
          movie.finish()
        }

        if let placeholder
        {
          try? FileManager.default.removeItem(at: placeholder)
        }

        if progress.status == .rendering { progress.status = .finished }
        progress.elapsed = Date().timeIntervalSince(began)
        progress.remaining = nil
        report(progress)
      #else
        progress.status = .failed("final renders need Metal")
        report(progress)
      #endif
    }

    #if canImport(Metal)

      private func makeMovie(_ job: Job, output: OutputSettings) throws -> MovieWriter?
      {
        guard job == .animation, output.format == .mpeg4 else { return nil }
        let size = output.pixelSize
        return try MovieWriter(url: output.movieURL, width: size.width, height: size.height,
                               frameRate: output.frameRate,
                               soundtrack: output.audio ? soundtrack(frameStart: output.frameStart,
                                                                     frameRate: output.frameRate) : nil)
      }

      /// The camera, volume and fog the stage gives the frame at `timeCode`.
      private func applyStageOverrides(at timeCode: Double, cameraPath: String?, hydra: Hydra.RenderEngine,
                                       akari: Akari.RenderEngine, isZUp: Bool)
      {
        akari.labfx.usdCameraShutter = cameraPath.map
        {
          let shutter = Pixar.HdAkariCameraShutter(hydra.stage, std.string($0), timeCode)
          return SIMD2(Float(shutter.open), Float(shutter.close))
        }

        akari.labfx.usdCameraLens = cameraPath.map { Pixar.HdAkariCameraLensAt(hydra.stage, std.string($0), timeCode) }
        akari.labfx.usdVolume = Pixar.HdAkariStageVolumeAt(hydra.stage, timeCode)
        akari.labfx.usdFogDisturbers = Self.fogDisturbers(hydra.stage, timeCode)
        let fogSim = akari.labfx.fogSim, fps = stageInfo.timeCodesPerSecond > 0 ? stageInfo.timeCodesPerSecond : 24
        akari.labfx.waterTime = timeCode / fps
        akari.labfx.fogSimRequest = { [hydra] in Self.advanceFogSim(fogSim, stage: hydra.stage, to: timeCode, zUp: isZUp, framesPerSecond: fps) }
      }

      private static func clearStageOverrides(_ akari: Akari.RenderEngine)
      {
        akari.finalRenderSample = nil
        akari.labfx.usdCameraShutter = nil
        akari.labfx.usdCameraLens = nil
        akari.labfx.usdVolume = nil
        akari.labfx.usdFogDisturbers = []
        akari.labfx.fogSimRequest = nil
      }

      /// Appends the frame to the movie, or writes its PNG for an animation, returning where it went.
      private static func write(_ image: Frame, index: Int, to movie: MovieWriter?, url: URL, animation: Bool,
                                output: OutputSettings) throws -> URL?
      {
        if let movie
        {
          try movie.append(image.display, index: index)
          return output.movieURL
        }

        guard animation else { return nil }
        try writePNG(image, to: url, color: output.colorMode)
        return url
      }

      /// Where the stage's soundtrack starts, relative to the first frame.
      private func soundtrack(frameStart: Int, frameRate: Double) -> MovieWriter.Soundtrack?
      {
        let info = stageInfo
        let path = String(info.soundtrack)
        guard !path.isEmpty, FileManager.default.fileExists(atPath: path) else { return nil }
        let timeCodesPerSecond = info.timeCodesPerSecond > 0 ? info.timeCodesPerSecond : frameRate
        return MovieWriter.Soundtrack(url: URL(fileURLWithPath: path),
                                      delay: (info.soundtrackStartTimeCode - Double(frameStart)) / timeCodesPerSecond,
                                      mediaOffset: info.soundtrackMediaOffset)
      }

      /// Renders `samples` jittered passes at `timeCode` from a clean history,
      /// after waiting out the light probe bake, returning the last color AOV.
      private func accumulate(at timeCode: Double,
                              size: (width: Int, height: Int),
                              samples: Int,
                              hydra: Hydra.RenderEngine,
                              akari: Akari.RenderEngine,
                              pose: (Double) -> Void,
                              progress: inout Progress,
                              report: (Progress) -> Void) -> MTLTexture?
      {
        let viewSize = CGSize(width: size.width, height: size.height)

        akari.finalRenderSample = 0
        var bake = 0
        while akari.settings.features.contains(.lightProbes), akari.labfx.lightProbes.isBaking,
              bake < Self.maxProbeBakePasses, !isCancelled
        {
          _ = autoreleasepool { Self.render(hydra, at: timeCode, size: viewSize) }
          bake += 1
        }
        // streamed Ptex tiles arrive over frames, the samples wait for the ones in view.
        var streamed = 0
        while akari.labfx.ptex.isStreaming, streamed < Self.maxPtexStreamPasses, !isCancelled
        {
          _ = autoreleasepool { Self.render(hydra, at: timeCode, size: viewSize) }
          streamed += 1
        }

        akari.labfx.resetHistory()
        // a shutter spreads the samples over it, each blurred over its own slice of it.
        let shutter = SIMD2<Double>(akari.labfx.usdCameraShutter ?? akari.labfx.cameraShutter)
        let blur = akari.settings.features.contains(.motionBlur) && shutter.y > shutter.x
        let slice = (shutter.y - shutter.x) / Double(max(samples, 1))
        if blur
        {
          akari.labfx.motionBlurSubframes = samples
          pose(timeCode + shutter.x - 0.5 * slice)
          _ = autoreleasepool { Self.render(hydra, at: timeCode + shutter.x - 0.5 * slice, size: viewSize) }
          akari.labfx.restartAccumulation()
        }

        defer
        {
          akari.labfx.motionBlurSubframes = 0
          if blur { pose(timeCode) }
        }

        var texture: MTLTexture?
        for sample in 0 ..< samples
        {
          if isCancelled { return nil }
          akari.finalRenderSample = sample
          if blur { pose(timeCode + shutter.x + (Double(sample) + 0.5) * slice) }
          // each pass drains its own command buffers and encoders, a long render would hold them all.
          texture = autoreleasepool
          {
            Self.render(hydra, at: blur ? timeCode + shutter.x + (Double(sample) + 0.5) * slice : timeCode, size: viewSize)
          }

          progress.sample = sample + 1
          if sample + 1 == samples || (sample + 1) % 8 == 0 { report(progress) }
        }

        return texture
      }

      /// A probe bake that never settles (a layout that keeps moving) stops here.
      private static let maxProbeBakePasses = 2048
      private static let maxPtexStreamPasses = 600

      /// One Hydra frame, the same bracket the viewport's renderer draws in.
      private static func render(_ hydra: Hydra.RenderEngine, at timeCode: Double, size: CGSize) -> MTLTexture?
      {
        #if canImport(Hgi)
          let hgi = hydra.getHgi()
        #else
          var hgi = hydra.getHgi()
        #endif
        hgi.StartFrame()
        let hgiTexture = hydra.render(at: timeCode, viewSize: size)
        hgi.CommitPrimaryCommandBuffer(.init(rawValue: 0), false)
        hgi.EndFrame()
        #if canImport(Hgi)
          return hgiTexture?.asMetalTexture
        #else
          return hgiTexture.asMetalTexture
        #endif
      }

      private static func queue(_ hydra: Hydra.RenderEngine) -> MTLCommandQueue
      {
        hydra.getHgi().GetQueue()
      }

    #endif

    /// The stage's fog disturbers at `timeCode`, eight floats each, velocity over the `window` frames before.
    public static func fogDisturbers(_ stage: UsdStage, _ timeCode: Double, window: Double = 1) -> [Float]
    {
      var out = [Float](repeating: 0, count: Akari.LabFXEngine.maxFogDisturbers * 8)
      let count = out.withUnsafeMutableBufferPointer
      {
        Int(Pixar.HdAkariFogDisturbersAt(stage, timeCode, $0.baseAddress!, Int32(Akari.LabFXEngine.maxFogDisturbers), window))
      }

      return Array(out.prefix(count * 8))
    }

    /// Steps the fog smoke simulation to `timeCode` with the stage's `akari:fogSim:*` and fog settings,
    /// or with a `preview`'s single substep and fewer pressure iterations, for the viewport to play back.
    public static func advanceFogSim(_ sim: Akari.FogSim, stage: UsdStage, to timeCode: Double, zUp: Bool,
                                     framesPerSecond: Double, preview: Bool = false)
    {
      sim.advance(to: timeCode, framesPerSecond: framesPerSecond,
                  frameAt: { preview ? fogSimPreview(fogSimFrame(stage, $0, zUp: zUp)) : fogSimFrame(stage, $0, zUp: zUp) },
                  disturbersAt: { fogDisturbers(stage, $0, window: $1) })
    }

    static func fogSimPreview(_ frame: Akari.FogSim.Frame) -> Akari.FogSim.Frame
    {
      var f = frame
      f.substeps = 1
      f.pressureIterations = 8
      f.catchUp = 1
      return f
    }

    static func fogSimFrame(_ stage: UsdStage, _ timeCode: Double, zUp: Bool) -> Akari.FogSim.Frame
    {
      let s = Pixar.HdAkariFogSimAt(stage, timeCode)
      let v = Pixar.HdAkariStageVolumeAt(stage, timeCode)
      var f = Akari.FogSim.Frame()
      f.enable = s.enable
      f.boundsMin = SIMD3(Float(s.minX), Float(s.minY), Float(s.minZ))
      f.boundsMax = SIMD3(Float(s.maxX), Float(s.maxY), Float(s.maxZ))
      f.resolution = Int(s.resolution)
      f.startFrame = s.startFrame
      f.substeps = Int(s.substeps)
      f.vorticity = Float(s.vorticity)
      f.dissipation = Float(s.dissipation)
      f.settle = Float(s.settle)
      f.replenish = Float(s.replenish)
      f.damping = Float(s.damping)
      f.density = v.hasDensity ? Float(v.density) : 0.02
      f.floorHeight = Float(v.floorHeight)
      f.heightFalloff = Float(v.heightFalloff)
      f.noiseAmount = Float(v.noiseAmount)
      f.noiseScale = Float(v.noiseScale)
      f.wind = SIMD3(Float(v.windX), Float(v.windY), Float(v.windZ))
      f.zUp = zUp
      return f
    }

    /// Points the orbit camera Hydra renders through exactly along a USD camera.
    /// No orbit distance, focus at the camera, and the rotation that rebuilds its
    /// world matrix through `Hydra.Camera.getTransform()`.
    static func pose(_ view: Hydra.Camera, from camera: Gf.Camera, aspect: Double, isZUp: Bool)
    {
      let m = camera.transform
      let rows = [m.TransformDir(Pixar.GfVec3d(1, 0, 0)),
                  m.TransformDir(Pixar.GfVec3d(0, 1, 0)),
                  m.TransformDir(Pixar.GfVec3d(0, 0, 1))]
      var w = rows.map { [$0[0], $0[1], $0[2]] }
      if isZUp
      {
        // undo the quarter turn about x the orbit camera appends for z up stages.
        w = w.map { [$0[0], $0[2], -$0[1]] }
      }

      let r = (0 ..< 3).map { i in (0 ..< 3).map { j in w[j][i] } }
      let degrees = 180 / Double.pi
      view.rotation = Pixar.GfVec3d(asin(min(max(-r[1][2], -1), 1)) * degrees,
                                    atan2(r[0][2], r[2][2]) * degrees,
                                    atan2(r[1][0], r[1][1]) * degrees)
      view.focus = m.ExtractTranslation()
      view.distance = 0

      // hydra's frustum takes its aperture angle as the vertical field of
      // view, so the horizontal aperture is fitted down to the image's height.
      var lens = view.gfCamera
      lens.projection = camera.projection
      lens.focalLength = camera.focalLength
      lens.horizontalAperture = Float(Double(camera.horizontalAperture) / aspect)
      lens.verticalAperture = camera.verticalAperture
      view.gfCamera = lens
      let clipping = camera.clippingRange
      view.nearClipOverride = Double(clipping.GetMin())
      view.farClipOverride = Double(clipping.GetMax())
    }

    /// The viewport's camera and time, put back once a render ends.
    struct ViewState
    {
      let rotation: Pixar.GfVec3d
      let focus: Pixar.GfVec3d
      let distance: Double
      let lens: Gf.Camera
      let near: Double?
      let far: Double?
      let timeCode: Double

      init(_ camera: Hydra.Camera, timeCode: Double)
      {
        rotation = camera.rotation
        focus = camera.focus
        distance = camera.distance
        lens = camera.gfCamera
        near = camera.nearClipOverride
        far = camera.farClipOverride
        self.timeCode = timeCode
      }

      func restore(_ hydra: Hydra.RenderEngine, time: Bool = true)
      {
        let camera = hydra.viewCamera
        camera.rotation = rotation
        camera.focus = focus
        camera.distance = distance
        camera.gfCamera = lens
        camera.nearClipOverride = near
        camera.farClipOverride = far
        if time { hydra.currentTimeCode = timeCode }
      }
    }
  }
}
