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

public enum AppUtils
{
  /// Increase the open file limit (up to 8192),
  /// othwerwise macOS defaults to a much lower
  /// limit (up to 256) when launched from launchd.
  public static func raiseOpenFileLimit()
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

  public static func registerAkariPlugin()
  {
    guard let url = Bundle.hdAkari.url(forResource: "plugInfo", withExtension: "json")
    else
    {
      print("[akari] WARNING: plugInfo.json missing from bundle - 'Akari' will not register")
      return
    }

    Pixar.PlugRegistry.GetInstance().RegisterPlugins(std.string(url.deletingLastPathComponent().path))
    print("[akari] registered plugInfo -> \(url.path)")
  }

  /// Frames the stage from the front right and above, back far enough to see around it.
  public static func frameStartView(_ hydra: Hydra.RenderEngine)
  {
    hydra.setupCamera()
    hydra.viewCamera.rotation = Pixar.GfVec3d(-30, 45, 0)
    hydra.viewCamera.distance *= 2
  }

  /// A new default cube scene, only in memory until it's saved.
  public static func newStage() -> UsdStage
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

  public static func buildStage() -> (stage: UsdStage, fileURL: URL?)
  {
    (newStage(), nil)
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

  public static func openOrCreateStage() -> (stage: UsdStage, fileURL: URL?)
  {
    if let path = usdScenePathFromArguments()
    {
      guard FileManager.default.isReadableFile(atPath: path) else { fatalError("USD scene not found or unreadable: \(path)") }
      guard Pixar.HdAkariLayerOpens(std.string(path)) else { fatalError("USD scene failed to parse: \(path)") }
      return (stage: UsdStage.open(path), fileURL: URL(filePath: path))
    }
    else
    {
      return buildStage()
    }
  }

  /// Final render options, to render with Akari from the command line.
  public struct RenderArguments
  {
    /// `-b`, render without opening the viewport while keeping Akari in the Dock.
    public var background = false
    /// Internal entry point for the child process that performs a `-b` render.
    var backgroundWorker = false
    /// `-a` renders the animation, `-f <frame>` one frame.
    public var job: Akari.FinalRender.Job?
    /// `-o <path>`, `#` runs become the frame number.
    public var path: String?
    /// `-s <frame>`, `-e <frame>`, `-j <step>`.
    public var frameStart: Int?
    public var frameEnd: Int?
    public var frameStep: Int?
    /// `-F PNG|MPEG4` (`FFMPEG` is accepted too).
    public var format: OutputFormat?
    /// `--resolution <w>x<h>`, `--percentage <n>`.
    public var resolution: (width: Int, height: Int)?
    public var percentage: Int?
    /// `--samples <n>`, the render sample count.
    public var samples: Int?
    /// `--camera <prim path>`, or `viewport`.
    public var camera: String?
    /// `--fps <rate>`.
    public var frameRate: Double?
    /// `--quality <featureset>`.
    public var quality: RenderQuality?
  }

  public static func renderArguments() -> RenderArguments
  {
    var options = RenderArguments()
    let arguments = Array(CommandLine.arguments.dropFirst())
    var i = 0
    func next() -> String?
    {
      i += 1
      return i < arguments.count ? arguments[i] : nil
    }
    while i < arguments.count
    {
      switch arguments[i]
      {
        case "-b", "--background": options.background = true
        case "--akari-background-worker": options.backgroundWorker = true
        case "-a", "--render-anim": options.job = .animation
        case "-f", "--render-frame": if let frame = next().flatMap(Int.init) { options.job = .image(frame: frame) }
        case "-o", "--render-output": options.path = next()
        case "-s", "--frame-start": options.frameStart = next().flatMap(Int.init)
        case "-e", "--frame-end": options.frameEnd = next().flatMap(Int.init)
        case "-j", "--frame-jump": options.frameStep = next().flatMap(Int.init)
        case "-F", "--render-format":
          switch next()?.uppercased()
          {
            case "PNG": options.format = .png
            case "MPEG4", "FFMPEG", "MP4": options.format = .mpeg4
            default: break
          }
        case "--resolution":
          let size = next()?.lowercased().split(separator: "x").compactMap { Int($0) } ?? []
          if size.count == 2 { options.resolution = (size[0], size[1]) }
        case "--percentage": options.percentage = next().flatMap(Int.init)
        case "--samples": options.samples = next().flatMap(Int.init)
        case "--camera": options.camera = next()
        case "--fps": options.frameRate = next().flatMap(Double.init)
        case "--quality": options.quality = next().flatMap(RenderQuality.init)
        default: break
      }

      i += 1
    }

    return options
  }
}
