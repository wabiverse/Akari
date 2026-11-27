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

import AkariRender
import CryptoKit
import Foundation
#if os(macOS)
  import AppKit
  import UniformTypeIdentifiers
#endif

extension Kraken
{
  /// compiles kraken scripts with the toolchain on this mac and runs them
  enum ScriptHost
  {
    struct Failure: Error, CustomStringConvertible
    {
      var description: String
    }

    /// the kraken module sources shipped with the app
    nonisolated static func moduleSources() -> [URL]
    {
      guard let folder = Bundle.akariResource("ScriptKit", in: "Akari_Kraken") else { return [] }

      let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
      return files.filter { $0.pathExtension == "swift" }.sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// runs a tool and gives back its output and exit status
    nonisolated static func shell(_ tool: String, _ arguments: [String], environment: [String: String]? = nil)
      -> (output: String, status: Int32)
    {
      #if os(macOS)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        if let environment { process.environment = environment }
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return ("couldn't run \(tool): \(error)", -1) }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (String(decoding: data, as: UTF8.self), process.terminationStatus)
      #else
        return ("", 0)
      #endif
    }

    nonisolated private static func hash(_ parts: [Data]) -> String
    {
      var hasher = SHA256()
      for part in parts { hasher.update(data: part) }
      return hasher.finalize().prefix(8).map { String(format: "%02x", $0) }.joined()
    }

    /// builds the kraken module once per source and compiler version
    nonisolated static func prepareModule() throws -> URL
    {
      let sources = moduleSources()
      guard !sources.isEmpty else { throw Failure(description: "the Kraken script module's sources are missing from the app") }
      let version = shell("/usr/bin/xcrun", ["swiftc", "--version"])
      guard version.status == 0 else { throw Failure(description: "scripts need the Swift toolchain, xcode-select --install\n\(version.output)") }
      let key = hash(sources.compactMap { try? Data(contentsOf: $0) } + [Data(version.output.utf8)])
      let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
      let folder = caches.appendingPathComponent("Kraken/Scripts/\(key)", isDirectory: true)
      let library = folder.appendingPathComponent("libKraken.dylib")
      if FileManager.default.fileExists(atPath: library.path) { return folder }
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let built = shell("/usr/bin/xcrun", ["swiftc", "-parse-as-library", "-emit-library", "-emit-module", "-module-name", "Kraken",
                                           "-O", "-o", library.path,
                                           "-emit-module-path", folder.appendingPathComponent("Kraken.swiftmodule").path,
                                           "-Xlinker", "-install_name", "-Xlinker", "@rpath/libKraken.dylib"] + sources.map(\.path))
      guard built.status == 0 else
      {
        try? FileManager.default.removeItem(at: folder)
        throw Failure(description: "couldn't build the Kraken module:\n\(built.output)")
      }

      return folder
    }

    /// the flags an editor or swiftc needs to import kraken
    nonisolated static func sdkFlags(_ module: URL) -> [String]
    {
      ["-I", module.path, "-L", module.path, "-lKraken", "-Xlinker", "-rpath", "-Xlinker", module.path]
    }

    /// compiles a script against the module, cached by its source
    nonisolated static func compile(_ script: URL, module: URL) throws -> URL
    {
      guard let source = try? Data(contentsOf: script) else { throw Failure(description: "couldn't read \(script.path)") }
      let folder = module.appendingPathComponent("built", isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
      let name = script.deletingPathExtension().lastPathComponent.filter { $0.isLetter || $0.isNumber }
      let binary = folder.appendingPathComponent("\(name.isEmpty ? "script" : name)-\(hash([source, Data(script.path.utf8)]))")
      if FileManager.default.isExecutableFile(atPath: binary.path) { return binary }
      let text = String(decoding: source, as: UTF8.self)
      let library = text.contains("@main") ? ["-parse-as-library"] : []
      let built = shell("/usr/bin/xcrun", ["swiftc"] + library + [script.path, "-o", binary.path] + sdkFlags(module))
      guard built.status == 0 else { throw Failure(description: built.output) }
      return binary
    }

    /// runs the scripts in order then calls done with the first failing exit status
    @MainActor
    static func run(_ scripts: [URL], layout: Layout, arguments: [String] = [], follow: Bool = false, pace: Double? = nil,
                    done: @escaping @MainActor (Int32) -> Void = { _ in })
    {
      let server = ScriptServer.start(layout)
      let socket = server.socketPath
      let status: @Sendable (String) -> Void = { text in DispatchQueue.main.async { layout.status = text } }
      Thread.detachNewThread
      {
        var code: Int32 = 0
        do
        {
          status("Building the Kraken script module…")
          let module = try prepareModule()
          for script in scripts
          {
            status("Compiling \(script.lastPathComponent)…")
            let binary = try compile(script, module: module)
            status("Running \(script.lastPathComponent)…")
            Console.info("running \(Console.paint(script.lastPathComponent, .bold)) \(Console.paint(script.deletingLastPathComponent().path, .dim))")
            var environment = ProcessInfo.processInfo.environment
            environment["KRAKEN_SOCKET"] = socket
            environment["KRAKEN_SCRIPT"] = script.path
            if Console.colors { environment["AKARI_COLOR"] = "1" }
            if follow { environment["KRAKEN_FOLLOW"] = "1" }
            if let pace { environment["KRAKEN_PACE"] = String(pace) }
            
            #if os(macOS)
              let process = Process()
              process.executableURL = binary
              process.arguments = arguments
              process.environment = environment
              process.currentDirectoryURL = script.deletingLastPathComponent()
              let pipe = Pipe()
              process.standardOutput = pipe
              process.standardError = pipe
              pipe.fileHandleForReading.readabilityHandler =
              { handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                let text = String(decoding: data, as: UTF8.self)
                FileHandle.standardOutput.write(Data(text.utf8))
                if let last = text.split(separator: "\n").last { status(String(last)) }
              }

              try process.run()
              process.waitUntilExit()
              pipe.fileHandleForReading.readabilityHandler = nil
              if process.terminationStatus != 0
              {
                code = process.terminationStatus
                status("\(script.lastPathComponent) failed with exit code \(code)")
                break
              }
            #endif

            status("Ran \(script.lastPathComponent)")
          }
        }
        catch
        {
          Console.error("\(error)")
          status("Script failed, see the console")
          code = 1
        }

        let result = code
        DispatchQueue.main.async { done(result) }
      }
    }

    /// runs the launch scripts and quits after when asked
    @MainActor
    static func runLaunchScripts(_ options: KrakenArgs.Scripts, layout: Layout)
    {
      guard !options.files.isEmpty else { return }
      run(options.files, layout: layout, arguments: options.passthrough, follow: options.follow, pace: options.pace)
      { code in
        guard options.quit else { return }
        exit(code == 0 ? 0 : options.failureCode ?? code)
      }
    }

    #if os(macOS)
      /// file run script
      @MainActor
      static func choose(layout: Layout)
      {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "swift")].compactMap { $0 }
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        run([url], layout: layout)
      }
    #endif
  }
}
