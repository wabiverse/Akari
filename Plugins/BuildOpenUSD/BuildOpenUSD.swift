import PackagePlugin
import Foundation

@main
struct OpenUSDBuilderPlugin: BuildToolPlugin
{
  func createBuildCommands(context: PluginContext, target: Target) async throws -> [Command]
  {
    // points to the external C/C++ OpenUSD project root.
    // todo: default pull from git, else let users override with their own usd builds.
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
    
    var outputLibPath = cmakeBuildPath
    for dylib in [
      "usd_usd",
      // todo: others...
    ] {
      outputLibPath = cmakeBuildPath.appending(path: "lib/lib\(dylib)\(libExt)")
    }

    return [
      // build OpenUSD with build_usd.py
      .buildCommand(
        displayName: "Building OpenUSD project with build_usd.py",
        executable: .init(filePath: "/usr/bin/python3")!,
        arguments: [ "\(externalProjectPath.path)/build_scripts/build_usd.py", "--cmake-build-args", "TBB,\"-march=arm64\"", cmakeBuildPath.path ],
        environment: [
          "PATH": "$PATH:/Users/$USER/Library/Python/3.9/bin:/opt/homebrew/bin:usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin", // for pyside6-uic
          "PYTHONPATH": "/Users/$USER/Library/Python/3.9/lib/python/site-packages", // for PyOpenGL
          "OS": "Darwin"
        ],
        inputFiles: [ externalProjectPath.appending(path: "pxr/usd/usd/stage.h") ],
        outputFiles: [ outputLibPath ]
      ),
    ]
  }
}
