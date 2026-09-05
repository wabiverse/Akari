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
import PackagePlugin

@main
struct OpenUSDBuilderPlugin: BuildToolPlugin
{
  func createBuildCommands(context: PluginContext, target _: Target) async throws -> [Command]
  {
    // points to the external C/C++ OpenUSD project root.
    // TODO: default pull from git, else let users override with their own usd builds.
    let externalProjectPath = context.package.directoryURL.appending(path: "../OpenUSD")

    // use SwiftPM's isolated plugin output directory.
    let cmakeBuildPath = context.pluginWorkDirectoryURL.appending(path: "cmake_build")

    // target outputs based on OS platform
    #if os(Windows)
      let libExt = ".dll"
    #elseif os(Linux)
      let libExt = ".so"
    #else
      let libExt = ".dylib"
    #endif

    var outputLibPath: URL = []
    for dylib in [
      "usd_usd",
      // TODO: others...
    ]
    {
      outputLibPath.append(cmakeBuildPath.appending(path: "lib/lib\(dylib)\(libExt)"))
    }

    return [
      // build OpenUSD with build_usd.py
      .buildCommand(
        displayName: "Building OpenUSD project with build_usd.py",
        executable: .init(filePath: "/usr/bin/python3")!,
        arguments: ["\(externalProjectPath.path)/build_scripts/build_usd.py", "--cmake-build-args", "TBB,\"-march=arm64\"", cmakeBuildPath.path],
        environment: [
          "PATH": "$PATH:/Users/$USER/Library/Python/3.9/bin:/opt/homebrew/bin:usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", // for pyside6-uic
          "PYTHONPATH": "/Users/$USER/Library/Python/3.9/lib/python/site-packages", // for PyOpenGL
          "OS": "Darwin"
        ],
        inputFiles: [externalProjectPath.appending(path: "pxr/usd/usd/stage.h")],
        outputFiles: outputLibPath
      ),
    ]
  }
}
