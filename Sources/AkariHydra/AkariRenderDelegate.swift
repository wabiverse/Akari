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
import HdAkari

public extension Akari
{
  /// The Swift implementation of Akari's Hydra render delegate.
  final class RenderDelegate
  {
    public init() {}

    /// The Hydra prim type tokens (`HdPrimTypeTokens`) Akari renders.
    /// Raw values must match Hydra's spelling exactly.
    enum Prim
    {
      enum Rprim: String, CaseIterable { case mesh, sphere, cube }
      enum Sprim: String, CaseIterable { case camera, material }
      enum Bprim: String, CaseIterable { case renderBuffer }
    }

    public func supportedRprimTypes() -> [String]
    {
      Prim.Rprim.allCases.map(\.rawValue)
    }

    public func supportedSprimTypes() -> [String]
    {
      Prim.Sprim.allCases.map(\.rawValue)
    }

    public func supportedBprimTypes() -> [String]
    {
      Prim.Bprim.allCases.map(\.rawValue)
    }

    /// Returns Akari's raw default AOV descriptor for a given `name`.
    public func defaultAovDescriptor(forName name: String) -> Int32
    {
      switch name
      {
        case "color":
          AK_AOV_FORMAT_COLOR.rawValue
        case "depth":
          AK_AOV_FORMAT_DEPTH.rawValue
        case "primId", "instanceId", "elementId":
          AK_AOV_FORMAT_ID.rawValue
        default:
          AK_AOV_FORMAT_INVALID.rawValue
      }
    }

    public func rprimClassName(forType typeId: String) -> String?
    {
      Prim.Rprim(rawValue: typeId)?.rawValue
    }

    public func sprimClassName(forType typeId: String) -> String?
    {
      Prim.Sprim(rawValue: typeId)?.rawValue
    }

    public func bprimClassName(forType typeId: String) -> String?
    {
      Prim.Bprim(rawValue: typeId)?.rawValue
    }
  }
}

private func activeDelegate(_ raw: UnsafeMutableRawPointer?) -> Akari.RenderDelegate?
{
  guard let raw else { return nil }
  return Unmanaged<Akari.RenderDelegate>.fromOpaque(raw).takeUnretainedValue()
}

/// Shared body behind the three `AKRenderDelegateSupportedXPrimTypes` entry
/// points below, which differ only in which list they report.
private func reportSupportedTypes(_ delegate: UnsafeMutableRawPointer?,
                                  _ cb: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void,
                                  _ ctx: UnsafeMutableRawPointer?,
                                  _ types: (Akari.RenderDelegate) -> [String])
{
  guard let delegate = activeDelegate(delegate) else { return }
  for name in types(delegate)
  {
    name.withCString { cb($0, ctx) }
  }
}

@_cdecl("AKRenderDelegateSupportedRprimTypes")
public func AKRenderDelegateSupportedRprimTypes(_ delegate: UnsafeMutableRawPointer?,
                                                _ cb: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void,
                                                _ ctx: UnsafeMutableRawPointer?)
{
  reportSupportedTypes(delegate, cb, ctx) { $0.supportedRprimTypes() }
}

@_cdecl("AKRenderDelegateSupportedSprimTypes")
public func AKRenderDelegateSupportedSprimTypes(_ delegate: UnsafeMutableRawPointer?,
                                                _ cb: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void,
                                                _ ctx: UnsafeMutableRawPointer?)
{
  reportSupportedTypes(delegate, cb, ctx) { $0.supportedSprimTypes() }
}

@_cdecl("AKRenderDelegateSupportedBprimTypes")
public func AKRenderDelegateSupportedBprimTypes(_ delegate: UnsafeMutableRawPointer?,
                                                _ cb: @convention(c) (UnsafePointer<CChar>?, UnsafeMutableRawPointer?) -> Void,
                                                _ ctx: UnsafeMutableRawPointer?)
{
  reportSupportedTypes(delegate, cb, ctx) { $0.supportedBprimTypes() }
}

@_cdecl("AKRenderDelegateDefaultAovDescriptor")
public func AKRenderDelegateDefaultAovDescriptor(_ delegate: UnsafeMutableRawPointer?,
                                                 _ name: UnsafePointer<CChar>?) -> Int32
{
  guard
    let delegate = activeDelegate(delegate),
    let name
  else
  {
    return AK_AOV_FORMAT_INVALID.rawValue
  }
  return delegate.defaultAovDescriptor(forName: String(cString: name))
}

/// C string copies of every prim type name, allocated once and never
/// freed so Hydra can hold onto the pointers for the process lifetime,
/// never mutated after this initializer, hence `nonisolated(unsafe)`.
private nonisolated(unsafe) let internedPrimNames: [String: UnsafePointer<CChar>] = {
  typealias Prim = Akari.RenderDelegate.Prim
  let allNames = Prim.Rprim.allCases.map(\.rawValue)
    + Prim.Sprim.allCases.map(\.rawValue)
    + Prim.Bprim.allCases.map(\.rawValue)

  return Dictionary(uniqueKeysWithValues: allNames.map
  { name in
    let bytes = Array(name.utf8CString)
    let buffer = UnsafeMutablePointer<CChar>.allocate(capacity: bytes.count)
    buffer.update(from: bytes, count: bytes.count)
    return (name, UnsafePointer(buffer))
  })
}()

/// Shared body behind the three `AKRenderDelegateXClassName` entry points
/// below, which differ only in which lookup method they call.
private func classNameLookup(_ delegate: UnsafeMutableRawPointer?,
                             _ typeId: UnsafePointer<CChar>?,
                             _ resolve: (Akari.RenderDelegate, String) -> String?) -> UnsafePointer<CChar>?
{
  guard let delegate = activeDelegate(delegate), let typeId else { return nil }
  guard let className = resolve(delegate, String(cString: typeId)) else { return nil }
  return internedPrimNames[className]
}

@_cdecl("AKRenderDelegateRprimClassName")
public func AKRenderDelegateRprimClassName(_ delegate: UnsafeMutableRawPointer?,
                                           _ typeId: UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
{
  classNameLookup(delegate, typeId) { $0.rprimClassName(forType: $1) }
}

@_cdecl("AKRenderDelegateSprimClassName")
public func AKRenderDelegateSprimClassName(_ delegate: UnsafeMutableRawPointer?,
                                           _ typeId: UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
{
  classNameLookup(delegate, typeId) { $0.sprimClassName(forType: $1) }
}

@_cdecl("AKRenderDelegateBprimClassName")
public func AKRenderDelegateBprimClassName(_ delegate: UnsafeMutableRawPointer?,
                                           _ typeId: UnsafePointer<CChar>?) -> UnsafePointer<CChar>?
{
  classNameLookup(delegate, typeId) { $0.bprimClassName(forType: $1) }
}
