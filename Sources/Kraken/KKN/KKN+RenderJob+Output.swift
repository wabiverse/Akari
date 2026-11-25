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
import Foundation
import HydraKit
import ImageFormats
#if os(macOS)
  import AppKit
#endif

extension Kraken.RenderJob
{
  /// `<scene folder>/render/<scene>_####` next to the stage, or in the home folder for a scene not saved yet
  nonisolated static func defaultOutputPath(for sceneFile: URL?) -> String
  {
    #if os(macOS)
      let sceneURL = sceneFile ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("untitled.usda")
    #else
      let sceneURL = sceneFile ?? URL.documentsDirectory.appendingPathComponent("untitled.usda")
    #endif

    let name = sceneURL.deletingPathExtension().lastPathComponent
    return sceneURL.deletingLastPathComponent()
      .appendingPathComponent("render", isDirectory: true)
      .appendingPathComponent("\(name)_####").path
  }

  /// writes the shown frame to its output file, the same as image save
  func saveImage()
  {
    guard let frame = progress?.frame else { return }

    let url = output.fileURL(frame: frame).deletingPathExtension().appendingPathExtension("png")
    do
    {
      try renderer.saveLastFrame(to: url)
      message = "Saved \(url.path)"
    }
    catch
    {
      message = "\(error)"
    }
  }

  func show(_ progress: Akari.FinalRender.Progress)
  {
    if let image = progress.image,
       image.width != result?.width || image.height != result?.height || self.progress?.frame != progress.frame
       || self.progress?.image == nil
    {
      result = ImageFormats.Image<RGBA>(width: image.width, height: image.height, bytes: image.rgba)
    }

    self.progress = progress
    switch progress.status
    {
      case .finished:
        if savesSingleFrameOnCompletion,
           case let .image(frame) = progress.job,
           renderer.lastFrame != nil
        {
          let url = output.fileURL(frame: frame).deletingPathExtension().appendingPathExtension("png")
          do
          {
            try renderer.saveLastFrame(to: url)
            message = "Saved \(url.path)"
          }
          catch
          {
            message = "\(error)"
          }
        }
        else if let url = progress.output
        {
          message = "Saved \(url.path)"
        }
      case let .failed(reason):
        message = reason
      default:
        break
    }
  }

  /// runs a command line render synchronously in the separate worker process
  func renderInBackground(_ job: Akari.FinalRender.Job) -> Akari.FinalRender.Status
  {
    let renderer = renderer
    let output = output
    let subject = job == .animation ? "animation" : "frame"
    Console.info("rendering \(subject) to \(Console.paint(output.path, .bold))", from: .akari)

    nonisolated(unsafe) var status = Akari.FinalRender.Status.preparing
    renderer.runBlocking(job, output: output)
    { progress in
      status = progress.status
      if progress.status == .rendering, progress.frameCount > 0, progress.samples > 0
      {
        let frame = Double(max(progress.frameNumber - 1, 0)) + Double(progress.sample) / Double(progress.samples)
        print("[akari-progress] \(min(frame / Double(progress.frameCount), 1))")
      }

      Self.logBackgroundProgress(progress, output: output, renderer: renderer)
    }

    return status
  }

  /// prints the saved line with its label in green for terminals
  private nonisolated static func saved(_ url: URL)
  {
    print("\(Console.paint("Saved:", .bold, .green)) '\(url.path)'")
  }

  private nonisolated static func logBackgroundProgress(_ progress: Akari.FinalRender.Progress,
                                                        output: OutputSettings,
                                                        renderer: Akari.FinalRender)
  {
    switch progress.status
    {
      case .rendering where progress.finishedFrame == progress.frame:
        // keeps the usual frame line wording so tools that parse it still work
        let bar = Console.paint("|", .gray)
        let remaining = progress.remaining.map { " \(bar) \(Console.paint("Remaining:", .gray))\(Self.clock($0))" } ?? ""
        print("\(Console.paint("Fra:", .gray))\(Console.paint("\(progress.frame)", .bold)) \(bar) \(Console.paint("Time:", .gray))"
          + "\(Self.clock(progress.lastFrameTime))\(remaining) \(bar) \(Console.paint("Sample", .gray)) \(progress.sample)/\(progress.samples)")
        if let url = progress.output, progress.job == .animation, output.format == .png { saved(url) }
      case .finished:
        if case let .image(frame) = progress.job, renderer.lastFrame != nil
        {
          let url = output.fileURL(frame: frame).deletingPathExtension().appendingPathExtension("png")
          do
          {
            try renderer.saveLastFrame(to: url)
            saved(url)
          }
          catch
          {
            Console.error("could not save render: \(error)", from: .akari)
          }
        }
        else if let url = progress.output, output.format == .mpeg4
        {
          saved(url)
        }

        Console.success("finished in \(Self.clock(progress.elapsed))", from: .akari)
      case .cancelled:
        Console.warn("render cancelled", from: .akari)
      case let .failed(reason):
        Console.error("render failed: \(reason)", from: .akari)
      default:
        break
    }
  }

  /// formats seconds as `h:mm:ss.cc`, leaving out the hours when there are none
  nonisolated static func clock(_ seconds: TimeInterval) -> String
  {
    let total = max(seconds, 0)
    let hours = Int(total) / 3600
    let minutes = Int(total) / 60 % 60
    let rest = total.truncatingRemainder(dividingBy: 60)

    return hours > 0 ? String(format: "%d:%02d:%05.2f", hours, minutes, rest) : String(format: "%02d:%05.2f", minutes, rest)
  }

  /// reloads the stage's layers and images from disk on the frame queue so hydra never draws mid reload
  func reloadStage()
  {
    guard let hydra = renderer.hydra, let akari = renderer.akari else { return }

    nonisolated(unsafe) let labfx = akari.labfx
    labfx.reloadTextures()
    hydra.performOnFrameQueue
    {
      hydra.stage.Reload()
      labfx.reloadProgress = max(labfx.reloadProgress, 0.2)
    }
  }

  /// whether a reload is still running and how far along it is
  var reloadStatus: (pending: Bool, progress: Double)
  {
    guard let labfx = renderer.akari?.labfx else { return (false, 1) }
    return (labfx.reloadPending, Double(labfx.reloadProgress))
  }

  /// f12 renders a frame, ctrl or cmd f12 the animation, f11 shows the result, esc cancels or closes, space plays
  func installKeyMonitor()
  {
    #if os(macOS)
      keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown)
      { [weak self] event in
        guard let self else { return event }
        let handled = MainActor.assumeIsolated { self.handleKey(code: event.keyCode, flags: event.modifierFlags) }
        return handled ? nil : event
      }
    #endif
  }

  #if os(macOS)
    private func handleKey(code: UInt16, flags: NSEvent.ModifierFlags) -> Bool
    {
      if NSApp.keyWindow?.firstResponder is NSText { return false }

      switch code
      {
        case 49:
          playback.toggle(reverse: flags.contains(.shift) && flags.contains(.control))
          return true
        case 123 where flags.contains(.shift), 124 where flags.contains(.shift):
          playback.jump(toEnd: code == 124)
          return true
        case 111:
          flags.contains(.control) || flags.contains(.command) ? renderAnimation() : renderImage()
          return true
        case 103:
          toggleResult()
          return true
        case 82 where flags.contains(.numericPad):
          toggleCameraView()
          return true
        case 53 where showsResult:
          isRendering ? cancel() : closeResult()
          return true
        default:
          return false
      }
    }
  #endif
}
