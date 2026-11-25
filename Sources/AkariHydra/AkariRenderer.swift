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
import HydraKit

/// registers a live akari render engine with hydra
public func registerAkariRenderer(engine: Akari.RenderEngine)
{
  // explicitly make its TF_REGISTRY_FUNCTION run.
  AkariHdEnsureLinked()

  AkariHydraSetRenderEngine(Unmanaged.passRetained(engine).toOpaque())
  AkariHydraSetRenderDelegate(Unmanaged.passRetained(Akari.RenderDelegate()).toOpaque())
}

/// runs `body` with `engine` as the engine new akari render delegates draw with, so a second hydra engine gets its own, `engine` must outlive what `body` makes
public func withAkariRenderer<T>(_ engine: Akari.RenderEngine, _ body: () -> T) -> T
{
  let registered = AkariHydraGetRenderEngine()
  AkariHydraSetRenderEngine(Unmanaged.passUnretained(engine).toOpaque())
  defer { AkariHydraSetRenderEngine(registered) }
  return body()
}

/// clears and releases the registered engine and delegate
public func unregisterAkariRenderer()
{
  if let raw = AkariHydraGetRenderEngine()
  {
    Unmanaged<Akari.RenderEngine>.fromOpaque(raw).release()
    AkariHydraSetRenderEngine(nil)
  }

  if let raw = AkariHydraGetRenderDelegate()
  {
    Unmanaged<Akari.RenderDelegate>.fromOpaque(raw).release()
    AkariHydraSetRenderDelegate(nil)
  }
}

/// the per-frame callback the c++ `HdAkariRenderPass` invokes.
#if canImport(HgiMetal)
  @_cdecl("AkariEngineRenderFrame")
  public func AkariEngineRenderFrame(_ engine: UnsafeMutableRawPointer?,
                                     _ hgi: Pixar.HgiMetal?,
                                     _ renderParam: Pixar.HdAkariRenderParam,
                                     _ colorBuffer: Pixar.HdAkariRenderBuffer?,
                                     _ depthBuffer: Pixar.HdAkariRenderBuffer?,
                                     _ primIdBuffer: Pixar.HdAkariRenderBuffer?,
                                     _ instanceIdBuffer: Pixar.HdAkariRenderBuffer?,
                                     _ viewMatrix: UnsafePointer<Double>?,
                                     _ projMatrix: UnsafePointer<Double>?,
                                     _ width: Int32,
                                     _ height: Int32)
  {
    guard let engine, let hgi else { return }
    let renderer = Unmanaged<Akari.RenderEngine>.fromOpaque(engine).takeUnretainedValue()

    renderer.renderFrame(hgi: hgi,
                         renderParam: renderParam,
                         color: colorBuffer,
                         depth: depthBuffer,
                         primId: primIdBuffer,
                         instanceId: instanceIdBuffer,
                         view: floats16(viewMatrix),
                         projection: floats16(projMatrix),
                         width: Int(width),
                         height: Int(height))
  }
#else
  @_cdecl("AkariEngineRenderFrame")
  public func AkariEngineRenderFrame(_ engine: UnsafeMutableRawPointer?,
                                     _ hgi: UnsafeMutableRawPointer?,
                                     _ renderParam: Pixar.HdAkariRenderParam,
                                     _ colorBuffer: Pixar.HdAkariRenderBuffer?,
                                     _ depthBuffer: Pixar.HdAkariRenderBuffer?,
                                     _ primIdBuffer: Pixar.HdAkariRenderBuffer?,
                                     _ instanceIdBuffer: Pixar.HdAkariRenderBuffer?,
                                     _ viewMatrix: UnsafePointer<Double>?,
                                     _ projMatrix: UnsafePointer<Double>?,
                                     _ width: Int32,
                                     _ height: Int32)
  {
    guard let engine, let hgi else { return }
    let renderer = Unmanaged<Akari.RenderEngine>.fromOpaque(engine).takeUnretainedValue()
    let hgiMetal = hgi.assumingMemoryBound(to: Pixar.HgiMetal.self)

    renderer.renderFrame(hgi: hgiMetal.pointee,
                         renderParam: renderParam,
                         color: colorBuffer,
                         depth: depthBuffer,
                         primId: primIdBuffer,
                         instanceId: instanceIdBuffer,
                         view: floats16(viewMatrix),
                         projection: floats16(projMatrix),
                         width: Int(width),
                         height: Int(height))
  }
#endif

/// copy a 4x4 double matrix into 16 floats.
private func floats16(_ p: UnsafePointer<Double>?) -> [Float]
{
  guard let p else { return Akari.Matrix4.identity.m }
  return (0 ..< 16).map { Float(p[$0]) }
}
