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
import CxxStdlib
import Foundation
import HdAkari
import HydraKit

#if canImport(Darwin)
  import Darwin
#endif

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

extension Kraken
{
  /// opens and makes the stages kraken works on, and sets up the app around them
  enum StageManager
  {
    /// raises the open file limit to 8192, launchd starts apps with a much lower one
    static func raiseOpenFileLimit()
    {
      #if canImport(Darwin)
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return }
        let cap: rlim_t = 8192
        let target = limit.rlim_max == rlim_t(bitPattern: -1) ? cap : min(limit.rlim_max, cap)
        guard target > limit.rlim_cur else { return }
        limit.rlim_cur = target
        _ = setrlimit(RLIMIT_NOFILE, &limit)
      #endif
    }

    /// ios starts apps at the root of the file system, so relative paths go to the app's documents instead
    static func enterWorkingFolder()
    {
      #if !os(macOS)
        FileManager.default.changeCurrentDirectoryPath(URL.documentsDirectory.path)
      #endif
    }

    static func registerAkariPlugin()
    {
      guard let url = Bundle.hdAkari.url(forResource: "plugInfo", withExtension: "json")
      else
      {
        Console.warn("plugInfo.json is missing from the bundle so Akari won't register", from: .akari)
        return
      }

      Pixar.PlugRegistry.GetInstance().RegisterPlugins(std.string(url.deletingLastPathComponent().path))
      Console.detail("registered \(url.path)", from: .akari)
    }

    /// frames the stage from the front right and above, back far enough to see around it.
    static func frameStartView(_ hydra: Hydra.RenderEngine)
    {
      hydra.setupCamera()
      hydra.viewCamera.rotation = Pixar.GfVec3d(-30, 45, 0)
      hydra.viewCamera.distance *= 2
    }

    /// a new default cube scene, only in memory until it's saved.
    static func newStage() -> UsdStage
    {
      let stage = UsdStage.createInMemory("untitled.usda")
      _ = UsdGeom.setUpAxis(for: stage, to: .y)
      _ = UsdGeom.setMetersPerUnit(for: stage, to: 1)
      UsdGeom.Xform.define(stage, path: Sdf.Path("/World"))

      stage.definePrim("/Materials", type: .scope)
      let material = UsdShade.Material.define(stage, path: Sdf.Path("/Materials/DefaultMaterial"))
      var shader = UsdShade.Shader.define(stage, path: Sdf.Path("/Materials/DefaultMaterial/PxrSurface"))
      shader.createIdAttr(.pxrSurface)
      shader.createInput(for: .diffuseGain, type: .float).set(Float(1))
      shader.createInput(for: .diffuseColor, type: .color3f).set(Pixar.GfVec3f(0.8, 0.8, 0.8))
      shader.createInput(for: .specularFaceColor, type: .color3f).set(Pixar.GfVec3f(0.04, 0.04, 0.04))
      shader.createInput(for: .specularEdgeColor, type: .color3f).set(Pixar.GfVec3f(1, 1, 1))
      shader.createInput(for: .specularRoughness, type: .float).set(Float(0.2))
      material.createSurfaceOutput(renderContext: .riRenderContext).connectTo(source: shader.createOutput(for: .out, type: .token))

      let cube = UsdGeom.Cube.define(stage, path: Sdf.Path("/World/Cube"))
      UsdShade.MaterialBindingAPI.apply(cube).bind(material)

      return stage
    }

    static func buildStage() -> (stage: UsdStage, fileURL: URL?)
    {
      (newStage(), nil)
    }

    static func openOrCreateStage() -> (stage: UsdStage, fileURL: URL?)
    {
      guard let path = Kraken.parseArgs().scene else { return buildStage() }
      guard let problem = KrakenArgs.usdProblem(path) else
      {
        let stage = UsdStage.open(path)
        SceneEdit.adoptLegacyBindings(stage)
        return (stage: stage, fileURL: URL(filePath: path))
      }
      Console.error(problem.message)
      exit(problem.code)
    }
  }
}
