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
import AkariRender
import HdAkari
import ImageFormats
import protocol SwiftCrossUI.ObservableObject
import class SwiftCrossUI.Published

extension Kraken
{
  /// A camera an output can render through.
  struct CameraChoice: Equatable, CustomStringConvertible
  {
    /// `nil` is the viewport's own view.
    let path: String?

    static let viewport = CameraChoice(path: nil)

    var description: String
    {
      path.map { String($0.split(separator: "/").last ?? Substring($0)) } ?? "Viewport"
    }
  }

  /// Frame rate menu, a rate is `fps / base`.
  enum FrameRate: Equatable, CaseIterable, CustomStringConvertible
  {
    case fps23_98, fps24, fps25, fps29_97, fps30, fps50, fps59_94, fps60, fps120, fps240, custom

    var rate: (fps: Int, base: Double)?
    {
      switch self
      {
        case .fps23_98: (24, 1.001)
        case .fps24: (24, 1)
        case .fps25: (25, 1)
        case .fps29_97: (30, 1.001)
        case .fps30: (30, 1)
        case .fps50: (50, 1)
        case .fps59_94: (60, 1.001)
        case .fps60: (60, 1)
        case .fps120: (120, 1)
        case .fps240: (240, 1)
        case .custom: nil
      }
    }

    var description: String
    {
      switch self
      {
        case .fps23_98: "23.98 fps"
        case .fps29_97: "29.97 fps"
        case .fps59_94: "59.94 fps"
        case .custom: "Custom"
        default: "\(rate?.fps ?? 0) fps"
      }
    }

    static func preset(fps: Int, base: Double) -> FrameRate?
    {
      allCases.first { $0.rate.map { $0.fps == fps && abs($0.base - base) < 1e-6 } ?? false }
    }
  }

  /// Final renders, the output properties, the running job, and its result.
  @MainActor
  final class RenderJob: ObservableObject
  {
    @Published var resolutionX: Int
    {
      didSet { syncAspect() }
    }

    @Published var resolutionY: Int
    {
      didSet { syncAspect() }
    }

    @Published var percentage: Int
    {
      didSet { syncAspect() }
    }

    @Published var frameStart: Int
    {
      didSet { syncPlayback() }
    }

    @Published var frameEnd: Int
    {
      didSet { syncPlayback() }
    }

    @Published var frameStep: Int
    @Published var fps: Int
    {
      didSet { syncPlayback() }
    }

    @Published var fpsBase: Double
    {
      didSet { syncPlayback() }
    }

    @Published var customFrameRate: Bool
    @Published var camera: CameraChoice?
    @Published var path: String
    @Published var format: OutputFormat?
    @Published var colorMode: ColorMode?
    @Published var colorDepth: ColorDepth?
    @Published var fileExtensions: Bool
    @Published var overwrite: Bool
    @Published var placeholders: Bool
    @Published var audio: Bool

    @Published var progress: Akari.FinalRender.Progress?
    @Published var result: ImageFormats.Image<RGBA>?
    @Published var showsResult = false
    @Published var message: String?
    @Published var lookingThrough = false
    @Published var showsPassepartout = false

    @Published var cameras: [CameraChoice]
    let renderer: Akari.FinalRender
    let cameraView: Akari.CameraView
    let playback: Akari.Playback
    var soundtrack: String?
    var savesSingleFrameOnCompletion: Bool

    var pendingJob: Akari.FinalRender.Job?
    var keyMonitor: Any?

    init(renderer: Akari.FinalRender,
         cameraView: Akari.CameraView,
         playback: Akari.Playback,
         defaultPath: String,
         arguments: AppUtils.RenderArguments)
    {
      self.renderer = renderer
      self.cameraView = cameraView
      self.playback = playback
      savesSingleFrameOnCompletion = arguments.background

      let info = renderer.stageInfo
      let stageCameras = info.cameras.map { CameraChoice(path: String($0)) }
      cameras = [.viewport] + stageCameras
      let track = String(info.soundtrack)
      soundtrack = track.isEmpty ? nil : track

      let defaults = OutputSettings()
      let animated = renderer.hasAuthoredTimeCodeRange
      resolutionX = arguments.resolution?.width ?? defaults.resolutionX
      resolutionY = arguments.resolution?.height ?? defaults.resolutionY
      percentage = arguments.percentage ?? defaults.percentage
      frameStart = arguments.frameStart ?? (animated ? Int(info.startTimeCode.rounded()) : defaults.frameStart)
      frameEnd = arguments.frameEnd ?? (animated ? Int(info.endTimeCode.rounded()) : defaults.frameEnd)
      frameStep = arguments.frameStep ?? defaults.frameStep
      let rate = arguments.frameRate ?? (info.timeCodesPerSecond > 0 ? info.timeCodesPerSecond : defaults.frameRate)
      let rounded = max(Int(rate.rounded()), 1)
      let base = abs(Double(rounded) / rate - 1) < 1e-6 ? 1 : Double(rounded) / rate
      fps = rounded
      fpsBase = base
      customFrameRate = FrameRate.preset(fps: rounded, base: base) == nil
      if let path = arguments.camera
      {
        camera = path.lowercased() == "viewport" ? .viewport : CameraChoice(path: path)
      }
      else
      {
        camera = Self.renderCamera(info) ?? stageCameras.first ?? .viewport
      }

      path = arguments.path ?? defaultPath
      format = arguments.format ?? defaults.format
      colorMode = defaults.colorMode
      colorDepth = defaults.colorDepth
      fileExtensions = defaults.fileExtensions
      overwrite = defaults.overwrite
      placeholders = defaults.placeholders
      audio = defaults.audio
      pendingJob = arguments.job

      if let samples = arguments.samples
      {
        renderer.akari?.settings.renderSamples = max(samples, 1)
      }

      if !arguments.background { installKeyMonitor() }
      syncAspect()
      syncPlayback()
      cameraView.onArrive = { [weak self] in self?.showsPassepartout = self?.lookingThrough == true }
      cameraView.onLeave = { [weak self] in
        self?.lookingThrough = false
        self?.showsPassepartout = false
      }

      if arguments.camera != nil || Self.renderCamera(info) != nil, !arguments.background { lookThrough(camera) }
    }

    private static func renderCamera(_ info: Pixar.HdAkariStageInfo) -> CameraChoice?
    {
      let path = String(info.renderCamera)
      return path.isEmpty ? nil : CameraChoice(path: path)
    }

    /// A newly opened scene's cameras, frame range and rate, looking through its render camera.
    func adoptStage()
    {
      renderer.adoptStage()
      let info = renderer.stageInfo
      let stageCameras = info.cameras.map { CameraChoice(path: String($0)) }
      cameras = [.viewport] + stageCameras
      let track = String(info.soundtrack)
      soundtrack = track.isEmpty ? nil : track
      let defaults = OutputSettings()
      let animated = renderer.hasAuthoredTimeCodeRange
      frameStart = animated ? Int(info.startTimeCode.rounded()) : defaults.frameStart
      frameEnd = animated ? Int(info.endTimeCode.rounded()) : defaults.frameEnd
      let rate = info.timeCodesPerSecond > 0 ? info.timeCodesPerSecond : defaults.frameRate
      let rounded = max(Int(rate.rounded()), 1)
      let base = abs(Double(rounded) / rate - 1) < 1e-6 ? 1 : Double(rounded) / rate
      fps = rounded
      fpsBase = base
      customFrameRate = FrameRate.preset(fps: rounded, base: base) == nil
      let render = Self.renderCamera(info)
      camera = render ?? stageCameras.first ?? .viewport
      lookThrough(render ?? .viewport)
    }

    /// The output properties as the renderer takes them.
    var output: OutputSettings
    {
      var output = OutputSettings()
      output.resolutionX = max(resolutionX, 1)
      output.resolutionY = max(resolutionY, 1)
      output.percentage = max(percentage, 1)
      output.frameStart = frameStart
      output.frameEnd = max(frameEnd, frameStart)
      output.frameStep = max(frameStep, 1)
      output.frameRate = fpsBase > 0 ? Double(max(fps, 1)) / fpsBase : 24
      output.cameraPath = camera?.path
      output.path = path
      output.format = format ?? .png
      output.colorMode = colorMode ?? .rgba
      output.colorDepth = colorDepth ?? .eight
      output.fileExtensions = fileExtensions
      output.overwrite = overwrite
      output.placeholders = placeholders
      output.audio = audio
      return output
    }

    /// The render frame's width over its height.
    var aspect: Double
    {
      let size = output.pixelSize
      return Double(size.width) / Double(size.height)
    }

    var isRendering: Bool
    {
      renderer.isRunning || progress?.status.isActive == true
    }

    /// The frame the viewport is on, what `Render Image` renders.
    var currentFrame: Int
    {
      Int(playback.frame.rounded(.down))
    }

    func renderImage()
    {
      start(.image(frame: currentFrame))
    }

    func renderAnimation()
    {
      start(.animation)
    }

    /// Starts a job the command line asked for, once the window is up.
    func startPendingJob()
    {
      guard let job = pendingJob else { return }
      pendingJob = nil
      start(job)
    }

    func start(_ job: Akari.FinalRender.Job)
    {
      guard !isRendering else { return }
      playback.pause()
      message = nil
      showsResult = true
      let started = renderer.start(job, output: output)
      { [weak self] progress in
        self?.show(progress)
      }

      if !started { message = "a render is already running" }
    }

    /// Looks the viewport through `choice`, the viewport's own view for `.viewport`.
    func lookThrough(_ choice: CameraChoice?)
    {
      cameraView.look(through: choice?.path)
      lookingThrough = choice?.path != nil
      showsPassepartout = false
    }

    /// Numpad 0: in and out of the scene camera's view.
    func toggleCameraView()
    {
      lookThrough(lookingThrough ? .viewport : camera)
    }

    /// The timeline plays the output's frame range at its frame rate.
    private func syncPlayback()
    {
      playback.range = Double(frameStart) ... Double(max(frameEnd, frameStart))
      playback.frameRate = output.frameRate
    }

    private func syncAspect()
    {
      cameraView.aspect = aspect
    }

    func cancel()
    {
      renderer.cancel()
    }

    func toggleResult()
    {
      showsResult.toggle()
    }

    func closeResult()
    {
      guard !isRendering else { return }
      showsResult = false
    }
  }
}
