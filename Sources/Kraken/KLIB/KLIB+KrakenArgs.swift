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

/// everything kraken takes on its command line, parsed once
public struct KrakenArgs
{
  /// a usage problem and the exit code it gets, 2 for a wrong flag or file kind and 1 for a missing file
  public struct Problem
  {
    public var message: String
    public var code: Int32
  }

  /// final render options for rendering with akari from the command line
  public struct Render
  {
    /// b renders without opening the viewport while keeping akari in the dock
    public var background = false
    /// the child process that performs a background render
    var backgroundWorker = false
    /// a renders the animation, f one frame
    public var job: Akari.FinalRender.Job?
    /// o, with runs of hashes becoming the frame number
    public var path: String?
    /// s, e and j
    public var frameStart: Int?
    public var frameEnd: Int?
    public var frameStep: Int?
    /// png or mpeg4
    public var format: OutputFormat?
    public var resolution: (width: Int, height: Int)?
    public var percentage: Int?
    public var samples: Int?
    /// a camera prim path or viewport
    public var camera: String?
    public var frameRate: Double?
    public var quality: RenderQuality?
  }

  /// how the viewport starts
  public struct Viewport
  {
    public var shading: ViewportShading?
    public var overlays = true
    /// subdivision surfaces refine once unless asked otherwise
    public var refineLevel = 1
    public var frame: Double?
    public var play = false
  }

  /// the swift scripts to run and how
  public struct Scripts
  {
    public var files: [URL] = []
    /// the exit code when a script fails, quitting after the scripts
    public var failureCode: Int32?
    public var quit = false
    /// builds the script module, prints the flags editors need and exits
    public var sdk = false
    /// the view follows what the scripts build
    public var follow = false
    /// seconds to wait between edits
    public var pace: Double?
    /// opens the script socket at launch for outside tools
    public var socket = false
    /// everything after a double dash, the scripts own arguments
    public var passthrough: [String] = []
  }

  /// the scene to open, absolute
  public var scene: String?
  /// a lattice motion file with its prototype ranges beside it as json
  public var latticeMotion: String?
  /// an image the sculpting tab shows and paints from, absolute
  public var sculptReference: String?
  /// the look the sculpting tab starts in, clay, studio or painterly
  public var sculptShading: String?
  public var render = Render()
  public var viewport = Viewport()
  public var scripts = Scripts()
  /// usage problems that stop kraken before it launches
  public var problems: [Problem] = []
  /// flags kraken ignored
  public var warnings: [String] = []
  /// h prints the usage and exits
  public var help = false

  /// what kraken help prints
  public static let usage = """
    usage: kraken [scene.usda] [options] [-- script arguments]

    scene
      --usd <file>                  open a .usd, .usda, .usdc or .usdz scene, a bare scene path works too

    viewport
      --shading <mode>              start in solid, material, rendered or wireframe shading
      --no-overlays                 start with the overlays hidden
      --refine-level <0-8>          the viewport max subdivision, 1 by default, render properties simplify sets the rest
      --frame <frame>               start on this frame
      --play                        start playing
      --sculpt-reference <image>    an image the sculpting tab shows over the sculpt and projects paint from
      --sculpt-shading <look>       start the sculpting tab in clay, studio or painterly

    render
      -b, --background              render without opening the viewport, or run scripts then quit
      -a, --render-anim             render the animation
      -f, --render-frame <frame>    render one frame
      -o, --render-output <path>    where renders go, runs of # become the frame number
      -s, --frame-start <frame>     the first frame of the animation
      -e, --frame-end <frame>       the last frame of the animation
      -j, --frame-jump <step>       render every nth frame
      -F, --render-format <format>  PNG or MPEG4
      --resolution <w>x<h>          the render size
      --percentage <n>              scale the render size
      --samples <n>                 render samples
      --camera <path>               the camera prim to render through, or viewport
      --fps <rate>                  the animation frame rate
      --quality <quality>           \(RenderQuality.allCases.map { "\($0)" }.joined(separator: ", "))

    scripts
      -S, --swift, --script <file>  run a .swift script once the scene is up, a bare script path works too
      --swift-expr <code>           run swift statements as a script
      --script-exit-code <code>     the exit code when a script fails, quitting after the scripts
      --follow                      the view follows what the scripts build
      --pace <seconds>              wait between edits to watch a script build
      --script-sdk                  build the script module and print the flags editors need
      --script-socket               open the script socket at launch so outside tools can drive kraken
      --                            everything after goes to the scripts as their own arguments

    other
      --lattice-motion <file>       drive the lattice bulb from a motion file
      -h, --help                    print this and exit
    """

  /// points at the usage after a bad flag
  public static let hint = "run kraken --help to see every flag"

  /// the files the usd flag opens
  public static let usdExtensions: Set<String> = ["usd", "usda", "usdc", "usdz"]

  /// the launch arguments, parsed on first use
  nonisolated(unsafe) static let current = parse(CommandLine.arguments)

  /// why a file cant be opened as a scene and its exit code, nil when it opens
  public static func usdProblem(_ path: String, parse: Bool = true) -> Problem?
  {
    let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
    if ext == "swift" { return Problem(message: "\(path) is a Swift script, run it with -S \(path)", code: 2) }
    if !usdExtensions.contains(ext) { return Problem(message: "\(path) isn't a USD scene, --usd opens .usd, .usda, .usdc and .usdz files", code: 2) }
    if !FileManager.default.isReadableFile(atPath: path) { return Problem(message: "USD scene not found or unreadable: \(path)", code: 1) }
    if parse, !Pixar.HdAkariLayerOpens(std.string(path)) { return Problem(message: "USD scene failed to parse: \(path)", code: 1) }
    return nil
  }

  /// why a file cant be run as a script and its exit code, nil when it can
  public static func scriptProblem(_ url: URL, as given: String) -> Problem?
  {
    let ext = url.pathExtension.lowercased()
    if usdExtensions.contains(ext) { return Problem(message: "\(given) is a USD scene, open it with --usd \(given)", code: 2) }
    if ext != "swift" { return Problem(message: "\(given) isn't a Swift script, -S runs .swift files", code: 2) }
    if !FileManager.default.isReadableFile(atPath: url.path) { return Problem(message: "Swift script not found or unreadable: \(url.path)", code: 1) }
    return nil
  }

  /// parses kraken arguments, the first being the executable
  public static func parse(_ arguments: [String]) -> KrakenArgs
  {
    var args = KrakenArgs()
    let list = Array(arguments.dropFirst())

    // a relaunched background render runs from elsewhere so relative paths are the shells
    let cwd = URL(fileURLWithPath: ProcessInfo.processInfo.environment["AKARI_CWD"] ?? FileManager.default.currentDirectoryPath,
                  isDirectory: true)
    func resolve(_ path: String) -> URL
    {
      URL(fileURLWithPath: (path as NSString).expandingTildeInPath, relativeTo: cwd).standardizedFileURL
    }

    var i = 0
    var flag = ""
    func next() -> String?
    {
      i += 1
      return i < list.count ? list[i] : nil
    }

    func needs(_ what: String)
    {
      args.problems.append(Problem(message: "\(flag) needs \(what)", code: 2))
    }

    func number<T: LosslessStringConvertible>(_ what: String) -> T?
    {
      guard let value = next().flatMap(T.init) else { needs(what); return nil }
      return value
    }

    func script(_ given: String)
    {
      let url = resolve(given)
      if let problem = scriptProblem(url, as: given) { args.problems.append(problem) } else { args.scripts.files.append(url) }
    }

    func scene(_ given: String)
    {
      let path = resolve(given).path
      if let problem = usdProblem(path, parse: false)
      {
        args.problems.append(Problem(message: problem.message.replacingOccurrences(of: path, with: given), code: problem.code))
      }
      else
      {
        args.scene = path
      }
    }

    while i < list.count
    {
      flag = list[i]
      switch flag
      {
        case "--":
          args.scripts.passthrough = Array(list[(i + 1)...])
          i = list.count
        case "-h", "--help": args.help = true
        case "--usd":
          if let path = next() { scene(path) } else { needs("a .usd, .usda, .usdc or .usdz file") }
        case "--sculpt-shading":
          if let look = next() { args.sculptShading = look } else { needs("clay, studio or painterly") }
        case "--sculpt-reference":
          if let path = next() { args.sculptReference = resolve(path).path } else { needs("an image file") }
        case "--lattice-motion":
          if let path = next() { args.latticeMotion = resolve(path).path } else { needs("a motion file") }

        case "-b", "--background": args.render.background = true
        case "--akari-background-worker": args.render.backgroundWorker = true
        case "-a", "--render-anim": args.render.job = .animation
        case "-f", "--render-frame": if let frame: Int = number("a frame number") { args.render.job = .image(frame: frame) }
        case "-o", "--render-output": if let path = next() { args.render.path = path } else { needs("an output path") }
        case "-s", "--frame-start": args.render.frameStart = number("a frame number")
        case "-e", "--frame-end": args.render.frameEnd = number("a frame number")
        case "-j", "--frame-jump": args.render.frameStep = number("a frame step")
        case "-F", "--render-format":
          switch next()?.uppercased()
          {
            case "PNG": args.render.format = .png
            case "MPEG4", "FFMPEG", "MP4": args.render.format = .mpeg4
            default: needs("PNG or MPEG4")
          }
        case "--resolution":
          let size = next()?.lowercased().split(separator: "x").compactMap { Int($0) } ?? []
          if size.count == 2 { args.render.resolution = (size[0], size[1]) } else { needs("a width and height like 1920x1080") }
        case "--percentage": args.render.percentage = number("a percentage")
        case "--samples": args.render.samples = number("a sample count")
        case "--camera": if let camera = next() { args.render.camera = camera } else { needs("a camera prim path or viewport") }
        case "--fps": args.render.frameRate = number("a frame rate")
        case "--quality":
          if let quality = next().flatMap(RenderQuality.init) { args.render.quality = quality }
          else { needs("one of \(RenderQuality.allCases.map { "\($0)" }.joined(separator: ", "))") }

        case "--shading":
          var name = next()?.lowercased() ?? ""
          if name == "material" { name = "materialpreview" }
          if let shading = ViewportShading.allCases.first(where: { "\($0)".lowercased() == name }) { args.viewport.shading = shading }
          else { needs("solid, material, rendered or wireframe") }
        case "--no-overlays": args.viewport.overlays = false
        case "--refine-level":
          if let level: Int = number("a level from 0 to 8") { args.viewport.refineLevel = min(max(level, 0), 8) }
        case "--frame": args.viewport.frame = number("a frame number")
        case "--play": args.viewport.play = true

        case "-S", "--swift", "--script":
          if let file = next() { script(file) } else { needs("a .swift file") }
        case "--swift-expr", "--script-expr":
          if let code = next()
          {
            let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("kraken-expr-\(getpid())-\(i).swift")
            try? "import Kraken\n\n\(code)\n".write(to: url, atomically: true, encoding: .utf8)
            args.scripts.files.append(url)
          }
          else { needs("swift statements") }
        case "--script-exit-code":
          if let code: Int32 = number("an exit code") { args.scripts.failureCode = code }
          args.scripts.quit = true
        case "--script-sdk": args.scripts.sdk = true
        case "--follow": args.scripts.follow = true
        case "--pace": args.scripts.pace = number("seconds")
        case "--script-socket": args.scripts.socket = true

        default:
          // a bare scene or script path opens or runs it
          if !flag.hasPrefix("-")
          {
            let ext = URL(fileURLWithPath: flag).pathExtension.lowercased()
            if usdExtensions.contains(ext), args.scene == nil { scene(flag) }
            else if ext == "swift" { script(flag) }
            else { args.warnings.append("ignoring \(flag)") }
          }

          // macos adds its own flags to apps it launches
          else if !["-NS", "-Apple", "-psn"].contains(where: flag.hasPrefix)
          {
            args.warnings.append("ignoring unknown flag \(flag)")

            // a plain word after it is most likely its value
            if i + 1 < list.count, !list[i + 1].hasPrefix("-")
            {
              let ext = URL(fileURLWithPath: list[i + 1]).pathExtension.lowercased()
              if ext != "swift", !usdExtensions.contains(ext) { i += 1 }
            }
          }
      }

      i += 1
    }

    if args.scene == nil, let path = ProcessInfo.processInfo.environment["KRAKEN_USD_SCENE"], !path.isEmpty { scene(path) }

    // background only quits after scripts, a background render handles itself
    if args.render.background, !args.scripts.files.isEmpty { args.scripts.quit = true }
    if args.scripts.files.isEmpty { args.scripts.quit = false }
    return args
  }
}

extension Kraken
{
  /// the launch arguments, parsed once
  nonisolated static func parseArgs() -> KrakenArgs
  {
    KrakenArgs.current
  }
}
