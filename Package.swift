// swift-tools-version: 6.1
import PackageDescription

let package = Package(
  name: "Akari",
  platforms: [
    .macOS(.v15),
    .visionOS(.v1),
    .iOS(.v17),
    .tvOS(.v17)
  ],
  products: [
    .library(name: "Akari", targets: ["AkariCore", "AkariRender", "AkariHydra", "HdAkari"]),
    .library(name: "AkariCore", targets: ["AkariCore"]),
    .executable(name: "AkariDemo", targets: ["AkariDemo"])
  ],
  dependencies: [
    .package(url: "https://github.com/wabiverse/swift-usd.git", branch: "dev"),
    .package(url: "https://github.com/wabiverse/Lattice.git", branch: "main"),
    .package(url: "https://github.com/furbytm/SwiftLabGL.git", from: "0.0.5"),
  ],
  targets: [
    .target(
      name: "AkariCore",
      dependencies: [
        .product(name: "LabGL", package: "SwiftLabGL"),
      ],
      swiftSettings: [
        .interoperabilityMode(.Cxx)
      ]
    ),

    .target(
      name: "AkariRender",
      dependencies: [
        .target(name: "AkariCore"),
        .target(name: "HdAkari"),
        .product(name: "OpenUSDKit", package: "swift-usd"),
        .product(name: "LatticeCore", package: "Lattice"),
        //.product(name: "LatticeUSD", package: "Lattice"),
        .product(name: "LabGL", package: "SwiftLabGL"),
        .product(name: "LabFX", package: "SwiftLabGL"),
      ],
      resources: [
        .process("Resources")
      ],
      cxxSettings: [
        .define("_LIBCPP_ABI_NO_COMPRESSED_PAIR_PADDING")
      ],
      swiftSettings: [
        .interoperabilityMode(.Cxx)
      ]
    ),

    .target(
      name: "AkariHydra",
      dependencies: [
        .target(name: "AkariRender"),
        .target(name: "HdAkari"),
        .product(name: "OpenUSDKit", package: "swift-usd"),
        .product(name: "HydraKit", package: "swift-usd")
      ],
      cxxSettings: [
        .define("_LIBCPP_ABI_NO_COMPRESSED_PAIR_PADDING")
      ],
      swiftSettings: [
        .interoperabilityMode(.Cxx)
      ]
    ),

    .target(
      name: "HdAkari",
      dependencies: [
        .product(name: "OpenUSDKit", package: "swift-usd"),
        .product(name: "HgiMetal", package: "swift-usd",
                 condition: .when(platforms: [.macOS, .visionOS, .iOS, .tvOS])),
        .product(name: "LabGL", package: "SwiftLabGL"),
      ],
      resources: [
        .process("Resources")
      ],
      cxxSettings: [
        .define("_LIBCPP_ABI_NO_COMPRESSED_PAIR_PADDING"),
        .define("HDAKARI_EXPORTS", to: "1"),
        .define("MFB_PACKAGE_NAME", to: "HdAkari"),
        .define("MFB_ALT_PACKAGE_NAME", to: "HdAkari"),
        .define("MFB_PACKAGE_MODULE", to: "HdAkari")
      ]
    ),

    .executableTarget(
      name: "AkariDemo",
      dependencies: [
        .target(name: "AkariCore"),
        .target(name: "AkariRender"),
        .target(name: "AkariHydra"),
        .target(name: "HdAkari"),
        .product(name: "OpenUSDKit", package: "swift-usd"),
        .product(name: "HydraKit", package: "swift-usd")
      ],
      resources: [
        .process("Resources")
      ],
      cxxSettings: [
        .define("_LIBCPP_ABI_NO_COMPRESSED_PAIR_PADDING")
      ],
      swiftSettings: [
        .interoperabilityMode(.Cxx)
      ]
    ),

    .testTarget(
      name: "AkariCoreTests",
      dependencies: [
        .target(name: "AkariCore")
      ]
    )
  ],
  cxxLanguageStandard: .gnucxx17
)
