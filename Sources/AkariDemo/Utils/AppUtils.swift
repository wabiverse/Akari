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

import Foundation
import HydraKit
import OpenUSDKit

#if os(Android)
  import AndroidBackend

  public typealias PlatformBackend = AndroidBackend
#elseif os(Linux)
  import GtkBackend

  public typealias PlatformBackend = GtkBackend
#elseif os(Windows)
  import WinUIBackend

  public typealias PlatformBackend = WinUIBackend
#elseif os(macOS)
  import AppKitBackend

  public typealias PlatformBackend = AppKitBackend
#else
  import UIKitBackend

  public typealias PlatformBackend = UIKitBackend
#endif

public enum AppUtils
{
  public static func registerAkariPlugin()
  {
    guard let url = Bundle.module.url(forResource: "plugInfo", withExtension: "json")
    else
    {
      print("[akari] WARNING: plugInfo.json missing from bundle - 'Akari' will not register")
      return
    }

    Pixar.PlugRegistry.GetInstance().RegisterPlugins(std.string(url.deletingLastPathComponent().path))
    print("[akari] registered plugInfo -> \(url.path)")
  }

  public static func buildStage() -> UsdStage
  {
    let usda = """
      #usda 1.0
      (
          upAxis = "Y"
          metersPerUnit = 1
      )

      def Xform "World"
      {
          def Sphere "Ball"
          {
              double radius = 1
              color3f[] primvars:displayColor = [(0.8, 0.8, 0.8)]
          }

          def Cube "Cube"
          {
              double size = 2
              color3f[] primvars:displayColor = [(0.8, 0.8, 0.8)]
              double3 xformOp:translate = (3, 0, 0)
              uniform token[] xformOpOrder = ["xformOp:translate"]
          }

          def DistantLight "Sun"
          {
              float inputs:intensity = 3
              float inputs:angle = 0.53
          }
      }
      """

    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("akari-demo-\(UUID().uuidString).usda")
    try? usda.write(to: url, atomically: true, encoding: .utf8)
    defer { try? FileManager.default.removeItem(at: url) }

    return UsdStage.open(url.path)
  }
  
  public static func usdScenePathFromArguments() -> String?
  {
    let arguments = CommandLine.arguments
    if let index = arguments.firstIndex(of: "--usd"), index + 1 < arguments.count
    {
      return arguments[index + 1]
    }
    if let path = ProcessInfo.processInfo.environment["LATTICE_USD_SCENE"], !path.isEmpty
    {
      return path
    }
    return nil
  }
  
  public static func openOrCreateStage() -> UsdStage
  {
    if let path = AppUtils.usdScenePathFromArguments()
    {
      return UsdStage.open(path)
    }
    else
    {
      return AppUtils.buildStage()
    }
  }
}
