// swift-tools-version: 6.0
import PackageDescription

// Signs shaders for Akari's hot reload and asks a running Akari to reload them.
// It shares its signing format with Akari through a symlink to AkariRender's ShaderSigning.swift.
let package = Package(
  name: "ShaderSign",
  platforms: [.macOS(.v15)],
  products: [
    .executable(name: "akari-sign", targets: ["akari-sign"])
  ],
  targets: [
    .executableTarget(name: "akari-sign")
  ]
)
