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

#if canImport(AkariCore)
  import AkariCore
#endif
import CryptoKit
import Darwin
import Foundation

extension Akari
{
  /// proves a shader edited while the app runs came from whoever holds the signing key, the signer builds this file too
  enum ShaderSigning
  {
    /// the loopback port a running akari listens on for the names of shaders to reload
    static let defaultPort: UInt16 = 47_118

    /// the port from `AKARI_SHADER_PORT` when set, otherwise the default
    static var port: UInt16
    {
      ProcessInfo.processInfo.environment["AKARI_SHADER_PORT"].flatMap(UInt16.init) ?? defaultPort
    }

    /// the loopback address for `port` so it only listens on this machine
    static func loopback(_ port: UInt16) -> sockaddr_in
    {
      var address = sockaddr_in()
      address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
      address.sin_family = sa_family_t(AF_INET)
      address.sin_port = port.bigEndian
      address.sin_addr.s_addr = INADDR_LOOPBACK.bigEndian
      return address
    }

    /// the file a shader source lives in, `<name>.msl`
    static func sourceFile(_ name: String, in folder: URL) -> URL
    {
      folder.appendingPathComponent("\(name).msl")
    }

    /// the signature next to a shader source, `<name>.msl.sig`
    static func signatureFile(for source: URL) -> URL
    {
      source.appendingPathExtension("sig")
    }

    /// the bytes a signature covers, the shader name and its exact contents so one shader's source can't stand in for another
    static func message(name: String, source: Data) -> Data
    {
      Data("akari shader v1\u{0}\(name)\u{0}".utf8) + source
    }

    /// whether `signature` was made over this shader by the private half of `publicKey`
    static func verify(name: String, source: Data, signature: Data, publicKey: Data) -> Bool
    {
      guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: publicKey) else { return false }

      return key.isValidSignature(signature, for: message(name: name, source: source))
    }

    /// whether the reload port accepts this name, a plain file stem that can't reach outside the shader folder
    static func isValidName(_ name: String) -> Bool
    {
      guard !name.isEmpty, name.count <= 128, !name.hasPrefix(".") else { return false }

      return name.unicodeScalars.allSatisfy { CharacterSet.alphanumerics.contains($0) && $0.isASCII || "._-".unicodeScalars.contains($0) }
    }

    static func hex(_ data: Data) -> String
    {
      data.map { String(format: "%02x", $0) }.joined()
    }

    /// decodes hex `text` ignoring surrounding whitespace, nil when it isn't even length hex
    static func bytes(hex text: String) -> Data?
    {
      let digits = Array(text.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
      guard digits.count.isMultiple(of: 2) else { return nil }

      var data = Data(capacity: digits.count / 2)
      for index in stride(from: 0, to: digits.count, by: 2)
      {
        guard let byte = UInt8(String(decoding: digits[index ... index + 1], as: UTF8.self), radix: 16) else { return nil }
        data.append(byte)
      }

      return data
    }
  }
}
