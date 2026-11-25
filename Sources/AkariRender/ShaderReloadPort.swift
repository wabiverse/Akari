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
import Darwin
import Foundation
import os

extension Akari
{
  /// waits on a loopback port for the names of shaders to reload so nothing polls the shader folder
  enum ShaderReloadPort
  {
    private static let requested = OSAllocatedUnfairLock(initialState: [String]())
    private static let started = OSAllocatedUnfairLock(initialState: false)

    /// starts listening on `port` of the loopback address, only once
    static func start(port: UInt16)
    {
      let isFirstStart = started.withLock
      { running in
        defer { running = true }
        return !running
      }

      guard isFirstStart else { return }

      guard let socket = listen(on: port)
      else
      {
        print("[akari/shaders] can't listen on port \(port) for shader reloads: \(String(cString: strerror(errno)))")
        return
      }

      let thread = Thread { serve(socket) }
      thread.name = "akari shader reload"
      thread.start()

      print("[akari/shaders] reloading signed shaders when asked on port \(port)")
    }

    /// the shader names asked for since the last call
    static func take() -> [String]
    {
      requested.withLock
      { names in
        defer { names.removeAll() }
        return names
      }
    }

    private static func listen(on port: UInt16) -> Int32?
    {
      let socket = Darwin.socket(AF_INET, SOCK_STREAM, 0)
      guard socket >= 0 else { return nil }

      var reuse: Int32 = 1
      setsockopt(socket, SOL_SOCKET, SO_REUSEADDR, &reuse, socklen_t(MemoryLayout<Int32>.size))

      var address = ShaderSigning.loopback(port)
      let bound = withUnsafePointer(to: &address)
      {
        $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(socket, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
      }

      guard bound == 0, Darwin.listen(socket, 8) == 0
      else
      {
        close(socket)
        return nil
      }

      return socket
    }

    /// takes one connection at a time, each sends shader names one per line and then closes
    private static func serve(_ socket: Int32)
    {
      while true
      {
        let client = accept(socket, nil, nil)
        guard client >= 0 else { continue }
        defer { close(client) }

        // a stalled client gets two seconds before it loses the port
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var quiet: Int32 = 1
        setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &quiet, socklen_t(MemoryLayout<Int32>.size))

        var received = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while received.count < 16_384
        {
          let count = read(client, &buffer, buffer.count)
          guard count > 0 else { break }
          received.append(buffer, count: count)
        }

        let names = String(decoding: received, as: UTF8.self)
          .split(whereSeparator: \.isNewline)
          .map { $0.trimmingCharacters(in: .whitespaces) }
          .filter { !$0.isEmpty }

        let accepted = names.filter(ShaderSigning.isValidName)
        requested.withLock { $0 += accepted }

        let reply = Array("queued \(accepted.count) of \(names.count)\n".utf8)
        _ = reply.withUnsafeBytes { write(client, $0.baseAddress, $0.count) }
      }
    }
  }
}
