// swift-tools-version: 6.0
import PackageDescription

// fits the linearly transformed cosine tables akari's area lights shade glossy highlights with, swift run -c release akari-ltc-fit writes LTC_GGX.bin
let package = Package(
  name: "LTCFit",
  platforms: [.macOS(.v15)],
  products: [
    .executable(name: "akari-ltc-fit", targets: ["akari-ltc-fit"])
  ],
  targets: [
    .executableTarget(name: "akari-ltc-fit", swiftSettings: [.unsafeFlags(["-Ounchecked"])])
  ]
)
