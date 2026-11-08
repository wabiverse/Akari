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

public extension Akari.Geom
{
  /// Instance matrices, sixteen floats each, read in place from USD's array when they come from one,
  /// so a scene's instances aren't held twice.
  struct Matrices: RandomAccessCollection, ExpressibleByArrayLiteral, @unchecked Sendable
  {
    private final class Storage: @unchecked Sendable
    {
      let usd: Pixar.VtMatrix4fArray?
      let owned: UnsafeMutablePointer<Float>?

      init(usd: Pixar.VtMatrix4fArray)
      {
        self.usd = usd
        owned = nil
      }

      init(copying floats: [Float])
      {
        usd = nil
        let owned = UnsafeMutablePointer<Float>.allocate(capacity: Swift.max(floats.count, 1))
        floats.withUnsafeBufferPointer { owned.update(from: $0.baseAddress!, count: floats.count) }
        self.owned = owned
      }

      deinit
      {
        owned?.deallocate()
      }
    }

    private let storage: Storage?
    private let base: UnsafePointer<Float>?
    public let count: Int

    public init()
    {
      storage = nil
      base = nil
      count = 0
    }

    public init(_ floats: [Float])
    {
      let storage = floats.isEmpty ? nil : Storage(copying: floats)
      self.storage = storage
      base = storage.flatMap { $0.owned.map { UnsafePointer($0) } }
      count = storage == nil ? 0 : floats.count
    }

    public init(usd matrices: Pixar.VtMatrix4fArray)
    {
      let storage = Storage(usd: matrices)
      self.storage = storage
      base = storage.usd.flatMap { Pixar.HdAkariMatrixFloats($0) }
      count = base == nil ? 0 : Int(matrices.size()) * 16
    }

    public init(arrayLiteral elements: Float...)
    {
      self.init(elements)
    }

    public var startIndex: Int
    {
      0
    }

    public var endIndex: Int
    {
      count
    }

    public subscript(i: Int) -> Float
    {
      base![i]
    }

    public func withUnsafeBufferPointer<R>(_ body: (UnsafeBufferPointer<Float>) throws -> R) rethrows -> R
    {
      try body(UnsafeBufferPointer(start: base, count: count))
    }

    public func withUnsafeBytes<R>(_ body: (UnsafeRawBufferPointer) throws -> R) rethrows -> R
    {
      try body(UnsafeRawBufferPointer(UnsafeBufferPointer(start: base, count: count)))
    }
  }
}
