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

import CryptoKit
import Darwin
import Foundation

/// The namespace AkariCore gives the shared signing file inside Akari.
enum Akari {}

let usage = """
  usage: akari-sign keygen              make the signing key and print the public key to bake into Akari
         akari-sign key                 print the signing key's public key
         akari-sign <name.msl> ...      sign each shader and ask the running Akari to reload it

  options:
    --key <path>    the signing key, AKARI_SIGNING_KEY or ~/.config/akari/shader-signing.key
    --port <port>   the port Akari listens on, AKARI_SHADER_PORT or \(Akari.ShaderSigning.defaultPort)
    --no-reload     sign without asking Akari to reload
  """

struct Failure: Error, CustomStringConvertible
{
  let description: String
  init(_ description: String) { self.description = description }
}

struct Options
{
  var key = ProcessInfo.processInfo.environment["AKARI_SIGNING_KEY"].map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
    ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".config/akari/shader-signing.key")
  var port = Akari.ShaderSigning.port
  var reload = true
  var words: [String] = []

  init(_ arguments: ArraySlice<String>) throws
  {
    var arguments = arguments
    while let argument = arguments.popFirst()
    {
      switch argument
      {
        case "--key":
          guard let path = arguments.popFirst() else { throw Failure("--key needs a path") }
          key = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
        case "--port":
          guard let value = arguments.popFirst(), let number = UInt16(value) else { throw Failure("--port needs a port number") }
          port = number
        case "--no-reload":
          reload = false
        case "-h", "--help":
          print(usage)
          exit(0)
        default:
          words.append(argument)
      }
    }
  }
}

/// Makes a new private key, readable by its owner alone, and never replaces one already there.
func makeKey(at file: URL) throws -> Curve25519.Signing.PrivateKey
{
  let manager = FileManager.default
  guard !manager.fileExists(atPath: file.path) else { throw Failure("\(file.path) already holds a signing key, it was left alone") }
  try manager.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true,
                              attributes: [.posixPermissions: 0o700])
  let key = Curve25519.Signing.PrivateKey()
  let contents = Data((Akari.ShaderSigning.hex(key.rawRepresentation) + "\n").utf8)
  guard manager.createFile(atPath: file.path, contents: contents, attributes: [.posixPermissions: 0o600])
  else { throw Failure("can't write \(file.path)") }
  return key
}

func loadKey(at file: URL) throws -> Curve25519.Signing.PrivateKey
{
  guard let text = try? String(contentsOf: file, encoding: .utf8)
  else { throw Failure("no signing key at \(file.path), make one with `akari-sign keygen`") }
  guard let bytes = Akari.ShaderSigning.bytes(hex: text), let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: bytes)
  else { throw Failure("\(file.path) doesn't hold a signing key") }
  return key
}

func printPublicKey(_ key: Curve25519.Signing.PrivateKey)
{
  let hex = Akari.ShaderSigning.hex(key.publicKey.rawRepresentation)
  print("public key \(hex)")
  print("bake it into Sources/AkariRender/ShaderSigningKey.swift as:")
  print("  static let publicKey = bytes(hex: \"\(hex)\") ?? Data()")
}

/// Signs one shader source and writes its signature beside it, returning the shader's name.
func sign(_ path: String, with key: Curve25519.Signing.PrivateKey) throws -> String
{
  let file = URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
  guard file.pathExtension == "msl" else { throw Failure("\(path) isn't a .msl shader source") }
  let name = file.deletingPathExtension().lastPathComponent
  guard Akari.ShaderSigning.isValidName(name) else { throw Failure("\(name) isn't a shader name Akari takes") }
  guard let source = try? Data(contentsOf: file) else { throw Failure("can't read \(path)") }
  guard String(data: source, encoding: .utf8) != nil else { throw Failure("\(path) isn't UTF-8 text") }

  let signature = try key.signature(for: Akari.ShaderSigning.message(name: name, source: source))
  try Data((Akari.ShaderSigning.hex(signature) + "\n").utf8)
    .write(to: Akari.ShaderSigning.signatureFile(for: file), options: .atomic)
  return name
}

/// Names the shaders on Akari's reload port and returns its reply, nothing when no Akari is listening.
func requestReload(_ names: [String], port: UInt16) -> String?
{
  let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
  guard socket >= 0 else { return nil }
  defer { close(socket) }
  var address = Akari.ShaderSigning.loopback(port)
  let connected = withUnsafePointer(to: &address)
  {
    $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
  }
  guard connected == 0 else { return nil }

  let request = Array((names.joined(separator: "\n") + "\n").utf8)
  _ = request.withUnsafeBytes { write(socket, $0.baseAddress, $0.count) }
  shutdown(socket, SHUT_WR)

  var reply = [UInt8](repeating: 0, count: 256)
  let count = read(socket, &reply, reply.count)
  return count > 0 ? String(decoding: reply[..<count], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) : ""
}

do
{
  let options = try Options(CommandLine.arguments.dropFirst())
  switch options.words.first
  {
    case nil:
      print(usage)
      exit(1)
    case "keygen":
      let key = try makeKey(at: options.key)
      print("made the signing key at \(options.key.path), keep it private")
      printPublicKey(key)
    case "key":
      printPublicKey(try loadKey(at: options.key))
    default:
      let key = try loadKey(at: options.key)
      let names = try options.words.map { try sign($0, with: key) }
      print("signed \(names.joined(separator: ", "))")
      guard options.reload else { break }
      if let reply = requestReload(names, port: options.port) { print("akari \(reply)") }
      else { print("no Akari is listening on port \(options.port), it picks the signed edits up at its next launch") }
  }
}
catch
{
  FileHandle.standardError.write(Data("akari-sign: \(error)\n".utf8))
  exit(1)
}
