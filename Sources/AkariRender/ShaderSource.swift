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
import LabGL

extension Akari
{
  /// shaders editable while the app runs from the `AKARI_SHADERS` folder, an edit only runs when it carries a valid signature
  enum ShaderSource
  {
    /// what a reload did, swapped in the new source, failed to compile it or found its owner gone
    enum Reload
    {
      case swapped, failed, gone
    }

    private struct Watch
    {
      var file: URL
      var reload: (String) -> Reload
    }

    private static let folder: URL? = ProcessInfo.processInfo.environment["AKARI_SHADERS"].flatMap
    { path -> URL? in
      guard !path.isEmpty else { return nil }

      let url = URL(fileURLWithPath: (path as NSString).expandingTildeInPath, isDirectory: true)
      do { try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true) }
      catch
      {
        print("[akari/shaders] can't use \(url.path) for shader sources: \(error)")
        return nil
      }

      print("[akari/shaders] reading signed shader sources in \(url.path)")
      ShaderReloadPort.start(port: ShaderSigning.port)
      return url
    }

    nonisolated(unsafe) private static var watches: [String: [Watch]] = [:]

    /// swapped out programs, deleted a second later once no frame in flight still uses them
    nonisolated(unsafe) private static var retired: [(at: Date, delete: () -> Void)] = []

    static var isWatching: Bool { folder != nil }

    /// the msl to compile for shader `name`, `builtIn` unless the shader folder holds an edited copy
    static func msl(_ name: String, _ builtIn: String) -> String
    {
      guard let folder, !builtIn.isEmpty else { return builtIn }

      let copy = ShaderSigning.sourceFile(name, in: folder)
      let original = ShaderSigning.sourceFile(name, in: folder.appendingPathComponent(".builtin", isDirectory: true))

      if let bytes = try? Data(contentsOf: copy), let edited = String(data: bytes, encoding: .utf8)
      {
        let started = try? String(contentsOf: original, encoding: .utf8)
        if edited != builtIn, edited != started
        {
          // an unsigned edit stays in place for the signer but doesn't run
          guard isSigned(name, bytes, at: copy)
          else
          {
            print("[akari/shaders] \(copy.lastPathComponent) isn't signed with the shader key, using the built in source")
            return builtIn
          }

          if let started, started != builtIn
          {
            print("[akari/shaders] \(name) changed in the build since it was edited, using the edited copy")
          }
          else
          {
            print("[akari/shaders] using \(copy.lastPathComponent)")
          }

          return edited
        }
      }

      write(builtIn, to: copy)
      write(builtIn, to: original)
      return builtIn
    }

    private static func write(_ source: String, to file: URL)
    {
      guard (try? String(contentsOf: file, encoding: .utf8)) != source else { return }

      do
      {
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try source.write(to: file, atomically: true, encoding: .utf8)
      }
      catch { print("[akari/shaders] can't write \(file.path): \(error)") }
    }

    /// calls `reload` with the new source whenever the reload port names this shader with a signed edit
    static func watch(_ name: String, reload: @escaping (String) -> Reload)
    {
      guard let folder else { return }

      watches[name, default: []].append(Watch(file: ShaderSigning.sourceFile(name, in: folder), reload: reload))
    }

    /// deletes a swapped out program once frames still in flight are done with it
    static func retire(_ delete: @escaping () -> Void)
    {
      retired.append((Date(), delete))
    }

    /// reloads the shaders the reload port named since the last frame, only from signed edits
    static func poll()
    {
      guard folder != nil else { return }

      let now = Date()
      for entry in retired where now.timeIntervalSince(entry.at) > 1 { entry.delete() }
      retired.removeAll { now.timeIntervalSince($0.at) > 1 }

      for name in Set(ShaderReloadPort.take()) { reload(name) }
    }

    private static func reload(_ name: String)
    {
      guard let list = watches[name], let first = list.first
      else
      {
        print("[akari/shaders] no running shader is named \(name)")
        return
      }

      guard let bytes = try? Data(contentsOf: first.file), let source = String(data: bytes, encoding: .utf8)
      else
      {
        print("[akari/shaders] can't read \(first.file.lastPathComponent)")
        return
      }

      guard isSigned(name, bytes, at: first.file)
      else
      {
        print("[akari/shaders] \(first.file.lastPathComponent) isn't signed with the shader key, not reloading it")
        return
      }

      var kept: [Watch] = []
      var failed = false
      for watch in list
      {
        switch watch.reload(source)
        {
          case .swapped: kept.append(watch)
          case .failed:
            kept.append(watch)
            failed = true
          case .gone: break
        }
      }

      watches[name] = kept.isEmpty ? nil : kept

      if !kept.isEmpty
      {
        print(failed ? "[akari/shaders] \(name) didn't compile, still running the last one"
                     : "[akari/shaders] reloaded \(name)")
      }
    }

    /// whether `bytes` read from `file` carry a signature from the private half of the baked in key
    private static func isSigned(_ name: String, _ bytes: Data, at file: URL) -> Bool
    {
      guard let text = try? String(contentsOf: ShaderSigning.signatureFile(for: file), encoding: .utf8),
            let signature = ShaderSigning.bytes(hex: text)
      else { return false }

      return ShaderSigning.verify(name: name, source: bytes, signature: signature, publicKey: ShaderSigning.publicKey)
    }

    /// compiles a render shader from the folder and swaps it in when a signed edit reloads, `swap` returns the program it replaced
    static func shader<Owner: AnyObject>(_ name: String, vertexGLSL: String = "", fragmentGLSL: String = "", msl: String,
                                         owner: Owner, swap: @escaping (Owner, GLuint) -> GLuint) -> GLuint
    {
      let program = gl.precompileShader(name: name, vertexGLSL: vertexGLSL, fragmentGLSL: fragmentGLSL,
                                        vertexMSL: Self.msl(name, msl), fragmentMSL: nil)

      watch(name)
      { [weak owner] source in
        guard let owner else { return .gone }

        let fresh = gl.precompileShader(name: name, vertexGLSL: vertexGLSL, fragmentGLSL: fragmentGLSL,
                                        vertexMSL: source, fragmentMSL: nil)
        guard fresh != 0, gl.waitShader(fresh) != 0
        else
        {
          if fresh != 0 { gl.deleteShader(fresh) }
          return .failed
        }

        let old = swap(owner, fresh)
        if old != 0 { retire { gl.deleteShader(old) } }
        return .swapped
      }

      return program
    }
  }
}
