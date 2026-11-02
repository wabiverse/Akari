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

#if os(macOS)
  import AppKit
  import Foundation
  import SwiftCrossUI

  /// Starts the normal app or a dock icon and macOS status
  /// bar icon running a windowless render session.
  @main
  @MainActor
  enum AkariDemoEntry
  {
    static func main()
    {
      AppUtils.raiseOpenFileLimit()

      let render = AppUtils.renderArguments()
      if render.backgroundWorker
      {
        runBackgroundRenderWorker()
      }

      guard render.background
      else
      {
        AkariDemo.main()
        return
      }
      guard render.job != nil
      else
      {
        print("[akari] -b needs -a (render the animation) or -f <frame>")
        exit(1)
      }

      // macOS 27 only shows "Running in Background" if launched
      // through LaunchServices, required for CLI based rendering.
      if getppid() != 1
      {
        relaunchThroughLaunchServices()
      }

      runBackgroundRender()
    }

    /// Waits on the relaunched app like a batch render, relaying its output and exit status.
    private static func relaunchThroughLaunchServices() -> Never
    {
      let session = URL(filePath: NSTemporaryDirectory()).appendingPathComponent("akari-\(getpid())")
      let output = session.appendingPathExtension("out")
      let status = session.appendingPathExtension("status")
      guard mkfifo(output.path, 0o600) == 0
      else
      {
        print("[akari] could not start background render: \(String(cString: strerror(errno)))")
        exit(1)
      }

      let configuration = NSWorkspace.OpenConfiguration()
      configuration.arguments = Array(CommandLine.arguments.dropFirst())
      configuration.createsNewApplicationInstance = true
      configuration.activates = false
      configuration.addsToRecentItems = false
      var environment = ProcessInfo.processInfo.environment
      environment["AKARI_CWD"] = FileManager.default.currentDirectoryPath
      environment["AKARI_OUTPUT"] = output.path
      environment["AKARI_STATUS"] = status.path
      configuration.environment = environment

      nonisolated(unsafe) var observation: NSKeyValueObservation?
      nonisolated(unsafe) var interrupt: DispatchSourceSignal?
      NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
      { app, error in
        guard let app
        else
        {
          print("[akari] could not start background render: \(error?.localizedDescription ?? "unknown error")")
          finish(output: output, status: status, code: 1)
        }
        signal(SIGINT, SIG_IGN)
        interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .global())
        interrupt?.setEventHandler { @Sendable in kill(app.processIdentifier, SIGTERM) }
        interrupt?.resume()
        observation = app.observe(\.isTerminated, options: [.initial])
        { app, _ in
          if app.isTerminated { finish(output: output, status: status, code: 0) }
        }
      }

      Thread.detachNewThread
      {
        if let fifo = FileHandle(forReadingAtPath: output.path)
        {
          while case let data = fifo.availableData, !data.isEmpty
          {
            try? FileHandle.standardOutput.write(contentsOf: data)
          }
        }
        finish(output: output, status: status, code: 0)
      }
      _ = (observation, interrupt)
      RunLoop.main.run()
      exit(0)
    }

    private nonisolated static func finish(output: URL, status: URL, code: Int32) -> Never
    {
      unlink(output.path)
      let reported = (try? String(contentsOf: status, encoding: .utf8)).flatMap { Int32($0) }
      unlink(status.path)
      exit(reported ?? code)
    }

    private static func runBackgroundRender()
    {
      let environment = ProcessInfo.processInfo.environment
      if let cwd = environment["AKARI_CWD"] { FileManager.default.changeCurrentDirectoryPath(cwd) }
      if let output = environment["AKARI_OUTPUT"]
      {
        signal(SIGPIPE, SIG_IGN)
        freopen(output, "w", stdout)
        dup2(fileno(stdout), STDERR_FILENO)
        setvbuf(stdout, nil, _IOLBF, 0)
      }

      let application = NSApplication.shared
      application.setActivationPolicy(.regular)
      application.mainMenu = makeMainMenu(for: application)

      let delegate = BackgroundRenderHost()
      application.delegate = delegate
      application.run()
    }

    /// The child the host spawns, it stays in the app's process after a quit.
    private static func runBackgroundRenderWorker() -> Never
    {
      signal(SIGPIPE, SIG_IGN)
      setvbuf(stdout, nil, _IOLBF, 0)
      let demo = AkariDemo()
      guard let job = demo.renderJob.pendingJob else { exit(1) }

      signal(SIGTERM, SIG_IGN)
      let renderer = demo.renderJob.renderer
      let terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .global())
      terminate.setEventHandler { @Sendable in renderer.cancel() }
      terminate.resume()

      exit(demo.renderJob.renderInBackground(job) == .finished ? 0 : 1)
    }

    private static func makeMainMenu(for application: NSApplication) -> NSMenu
    {
      let mainMenu = NSMenu()
      let appMenuItem = NSMenuItem(title: ProcessInfo.processInfo.processName,
                                   action: nil,
                                   keyEquivalent: "")
      let appMenu = NSMenu()
      let quit = NSMenuItem(title: "Quit AkariDemo",
                            action: #selector(NSApplication.terminate(_:)),
                            keyEquivalent: "q")
      quit.target = application
      appMenu.addItem(quit)
      appMenuItem.submenu = appMenu
      mainMenu.addItem(appMenuItem)
      return mainMenu
    }
  }

  /// Owns the dock visible app while a child process performs the render,
  /// this lets AppKit complete a user initiated quit while macOS manages
  /// the still running child as background work.
  @MainActor
  private final class BackgroundRenderHost: NSObject, NSApplicationDelegate, NSWindowDelegate
  {
    private let worker = Process()
    private var pendingOutput = Data()
    private var terminate: DispatchSourceSignal?
    private var statusItem: NSStatusItem!
    private var statusMenuItem: NSMenuItem!
    private var cancelMenuItem: NSMenuItem!
    private var progressWindow: NSWindow!
    private var statusField: NSTextField!
    private var progressIndicator: NSProgressIndicator!
    private var cancelButton: NSButton!
    private var cancelRequested = false

    func applicationDidFinishLaunching(_: Notification)
    {
      makeStatusItem()
      makeProgressWindow()

      signal(SIGTERM, SIG_IGN)
      terminate = DispatchSource.makeSignalSource(signal: SIGTERM, queue: .main)
      terminate?.setEventHandler { [weak self] in self?.cancelRender(nil) }
      terminate?.resume()

      let output = Pipe()
      worker.executableURL = Bundle.main.executableURL
      worker.arguments = Array(CommandLine.arguments.dropFirst()) + ["--akari-background-worker"]
      worker.standardOutput = output
      worker.standardError = output
      output.fileHandleForReading.readabilityHandler =
      { [weak self] handle in
        let data = handle.availableData
        guard !data.isEmpty else { return }
        DispatchQueue.main.async { self?.relay(data) }
      }
      worker.terminationHandler =
      { [weak self] worker in
        DispatchQueue.main.async { self?.finish(worker.terminationStatus) }
      }

      do
      {
        try worker.run()
        setStatus("Rendering in background...")
        cancelMenuItem.isEnabled = true
        cancelButton.isEnabled = true
      }
      catch
      {
        print("[akari] could not start render: \(error)")
        finish(1)
      }
    }

    func applicationWillTerminate(_: Notification)
    {
      if worker.isRunning { print("[akari] render continues in the background") }
    }

    /// The Wabi logo from `Branding/Akari.icon`, as a menu bar template.
    private static let orca: NSImage? =
    {
      let svg = #"<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 34 50"><path fill-rule="evenodd" d="m4.87,33.98S1.37,31.13.3,24.1c-.31-2.73.01-5.38,1.02-7.94,1.15-2.93,2.99-5.33,5.51-7.22.5-.38,1.05-.69,1.46-1.18.6-.71.79-1.52.68-2.42-.09-.68-.33-1.3-.59-1.92-.16-.39-.34-.77-.39-1.19-.1-.79.33-1.48,1.07-1.77.78-.31,1.59-.3,2.4-.17,1.26.21,2.48.59,3.67,1.04,2.19.81,4.27,1.85,6.25,3.09,2.3,1.44,4.41,3.11,6.27,5.1,1.34,1.44,2.51,3,3.44,4.73,1.81,3.37,2.41,6.95,1.76,10.73-.23,1.32-.62,2.58-1.3,3.74-1.22,2.09-3.05,3.12-5.46,3.16-1.32.02-2.55-.3-3.75-.81-1.13-.48-2.21-1.05-3.26-1.67-1.17-.69-9.85-6.99-12.05-7.47-1.8.32-3.36.8-4.12,2.47-3.46,3.39,1.97,9.55,1.97,9.55h0Zm17.95-8.31c0-.82-.98-1.62-1.82-1.49-.66.11-.99.67-.76,1.3.23.63.88,1.1,1.55,1.11.59.01,1.03-.38,1.03-.92h0Z"/><path fill-rule="evenodd" d="m21.49,33.4c.27-.15-7.4,8.63-16.65.59-2.3-2-6.77-12.09.52-12.29,4.64-.13,11.83,6.48,11.83,6.48-2.9-1.96-8.72-5.94-12.24-2.8-4.78,4.27,2.44,15.66,16.53,8.02h0Z"/><path fill-rule="evenodd" d="m14.91,35.81c1.07-.31,2.07-.81,3.09-1.24,1.07-.46,2.15-.9,3.3-1.14.71-.15,1.49-.14,1.99.01-.56.82-1.03,1.68-1.56,2.52-.21.34-.46.66-.73.95-1.19,1.26-2.65,1.79-4.28,1.81-.41,0-.83,0-1.32,0,.73.15,1.38.31,2.01.55,1.59.6,2.53,1.76,2.92,3.38.42,1.77.69,3.57,1.15,5.34.14.55.27,1.1.46,1.63.05.13.05.18-.12.16-1.76-.24-3.47-.66-5.02-1.56-1.39-.8-2.48-1.92-3.33-3.28-.8-1.27-1.36-2.65-1.97-4.01-.32-.71-.53-1.29-.95-1.92-.45-.68-1.06-1.25-1.75-1.7-2.84-1.82-4.47-3.89-4.52-3.94,0,0,2.96,3.58,8.5,3.04.73-.15,1.46-.3,2.15-.6h0Z"/></svg>"#
      let image = NSImage(data: Data(svg.utf8))
      image?.size = NSSize(width: 18 * 34 / 50, height: 18)
      image?.isTemplate = true
      return image
    }()

    private func makeStatusItem()
    {
      let menu = NSMenu()
      statusMenuItem = NSMenuItem(title: "Preparing render...", action: nil, keyEquivalent: "")
      statusMenuItem.isEnabled = false
      menu.addItem(statusMenuItem)
      menu.addItem(.separator())

      let cancel = NSMenuItem(title: "Cancel Render",
                              action: #selector(cancelRender(_:)),
                              keyEquivalent: "")
      cancel.target = self
      cancel.isEnabled = false
      cancelMenuItem = cancel
      menu.addItem(cancel)
      menu.addItem(.separator())

      let showProgress = NSMenuItem(title: "Show Render Progress...",
                                    action: #selector(showProgress(_:)),
                                    keyEquivalent: "")
      showProgress.target = self
      menu.addItem(showProgress)
      menu.addItem(.separator())

      let quit = NSMenuItem(title: "Quit AkariDemo",
                            action: #selector(NSApplication.terminate(_:)),
                            keyEquivalent: "")
      quit.target = NSApplication.shared
      menu.addItem(quit)

      statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
      statusItem.button?.image = Self.orca
      statusItem.button?.imagePosition = .imageLeading
      statusItem.button?.toolTip = "Akari background render"
      statusItem.menu = menu
    }

    func windowShouldClose(_: NSWindow) -> Bool
    {
      true
    }

    @objc private func cancelRender(_: Any?)
    {
      guard worker.isRunning else { return }
      cancelRequested = true
      cancelButton.isEnabled = false
      cancelMenuItem.isEnabled = false
      setStatus("Stopping render...")
      worker.terminate()
    }

    @objc private func showProgress(_: Any?)
    {
      progressWindow.makeKeyAndOrderFront(nil)
      NSApplication.shared.activate(ignoringOtherApps: true)
    }

    /// Forwards the worker's output, keeping its progress lines for the bar.
    private func relay(_ data: Data)
    {
      pendingOutput.append(data)
      guard let end = pendingOutput.lastIndex(of: UInt8(ascii: "\n")) else { return }
      let lines = String(decoding: pendingOutput[...end], as: UTF8.self).split(separator: "\n")
      pendingOutput.removeSubrange(...end)

      var forwarded = ""
      for line in lines
      {
        var line = line
        if let marker = line.range(of: "[akari-progress] ")
        {
          if let fraction = Double(line[marker.upperBound...]) { setProgress(fraction) }
          line = line[..<marker.lowerBound]
          if line.isEmpty { continue }
        }
        forwarded += line + "\n"
        if ["Fra:", "[akari] render", "[akari] finished"].contains(where: { line.hasPrefix($0) })
        {
          setStatus(String(line))
        }
      }
      try? FileHandle.standardOutput.write(contentsOf: Data(forwarded.utf8))
    }

    private func setProgress(_ fraction: Double)
    {
      if progressIndicator.isIndeterminate
      {
        progressIndicator.stopAnimation(nil)
        progressIndicator.isIndeterminate = false
        progressIndicator.minValue = 0
        progressIndicator.maxValue = 1
      }
      progressIndicator.doubleValue = fraction
      statusItem.button?.title = "\(Int(fraction * 100))%"
    }

    private func setStatus(_ status: String)
    {
      statusField.stringValue = status
      statusMenuItem.title = status
    }

    private func makeProgressWindow()
    {
      let content = NSView()
      statusField = NSTextField(labelWithString: "Preparing render...")
      statusField.lineBreakMode = .byTruncatingTail
      statusField.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
      progressIndicator = NSProgressIndicator()
      progressIndicator.style = .bar
      progressIndicator.isIndeterminate = true
      progressIndicator.startAnimation(nil)
      cancelButton = NSButton(title: "Cancel Render",
                              target: self,
                              action: #selector(cancelRender(_:)))
      cancelButton.isEnabled = false

      let stack = NSStackView(views: [statusField, progressIndicator, cancelButton])
      stack.orientation = .vertical
      stack.alignment = .leading
      stack.spacing = 10
      stack.translatesAutoresizingMaskIntoConstraints = false
      content.addSubview(stack)
      NSLayoutConstraint.activate([
        stack.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 16),
        stack.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -16),
        stack.topAnchor.constraint(equalTo: content.topAnchor, constant: 16),
        stack.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -16),
        progressIndicator.widthAnchor.constraint(equalTo: stack.widthAnchor),
      ])

      let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 112),
                            styleMask: [.titled, .closable],
                            backing: .buffered,
                            defer: false)
      window.title = "Akari Background Render"
      window.isReleasedWhenClosed = false
      window.contentView = content
      window.delegate = self
      window.center()
      progressWindow = window
    }

    private func finish(_ status: Int32)
    {
      try? FileHandle.standardOutput.write(contentsOf: pendingOutput)
      pendingOutput.removeAll()
      if status == 0, !cancelRequested { setProgress(1) }
      if let path = ProcessInfo.processInfo.environment["AKARI_STATUS"]
      {
        try? String(cancelRequested ? 130 : status).write(toFile: path, atomically: true, encoding: .utf8)
      }
      setStatus(cancelRequested ? "Render cancelled" : status == 0 ? "Render complete" : "Render failed")
      cancelMenuItem.isEnabled = false
      cancelButton.isEnabled = false
      progressIndicator.stopAnimation(nil)
      DispatchQueue.main.asyncAfter(deadline: .now() + 2)
      { NSApplication.shared.terminate(nil) }
    }
  }
#endif
