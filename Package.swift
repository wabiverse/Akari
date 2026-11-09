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
    .executable(name: "Kraken", targets: ["Kraken"])
  ],
  dependencies: [
    .package(url: "https://github.com/wabiverse/swift-usd.git", from: "26.11.1"),
    .package(url: "https://github.com/wabiverse/MetaOneTBB.git", from: "1.0.0"),
    .package(url: "https://github.com/wabiverse/MetaOpenVDB.git", from: "1.0.0"),
    .package(url: "https://github.com/wabiverse/MetaPtex.git", from: "1.0.0"),
    .package(url: "https://github.com/wabiverse/Lattice.git", from: "1.0.0"),
    .package(url: "https://github.com/furbytm/SwiftLabGL.git", from: "0.2.9"),
    .package(url: "https://codeberg.org/furbytm/LabCamera.git", from: "1.0.0"),
    .package(url: "https://github.com/furbytm/Nanocolor.git", from: "1.0.0"),
  ],
  targets: [
    // TODO: support externally provided openusd builds.
    // .plugin(
    //   name: "BuildOpenUSD",
    //   capability: .buildTool()
    // ),
    // .target(
    //   name: "OpenUSD",
    //   plugins: [
    //     // depends on the OpenUSD build_usd.py build script
    //     // to pull in the OpenUSD dependency via this package's
    //     // BuildOpenUSD plugin.
    //     .plugin(name: "BuildOpenUSD")
    //   ]
    // ),

    .target(
      name: "AkariImaging",
      cxxSettings: [
        .define("_LIBCPP_ABI_NO_COMPRESSED_PAIR_PADDING")
      ],
      swiftSettings: [
        .interoperabilityMode(.Cxx)
      ]
    ),

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
        .product(name: "HydraKit", package: "swift-usd"),
        // TODO: support externally provided openusd builds.
        // .target(name: "OpenUSD"),
        // .product(name: "LatticeCore", package: "Lattice"),
        // .product(name: "LatticeUSD", package: "Lattice"),
        .product(name: "Nanocolor", package: "Nanocolor"),
        .product(name: "LabGL", package: "SwiftLabGL"),
        .product(name: "LabFX", package: "SwiftLabGL"),
        .product(name: "LabCamera", package: "LabCamera"),
        .product(name: "LabCameraCxx", package: "LabCamera"),
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
        // TODO: support externally provided openusd builds.
        // .target(name: "OpenUSD"),
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
        .target(name: "AkariImaging"),
        // TODO: support externally provided openusd builds.
        // .target(name: "OpenUSD"),
        .product(name: "HydraKit", package: "swift-usd"),
        .product(name: "OneTBB", package: "MetaOneTBB"),
        .product(name: "OpenVDB", package: "MetaOpenVDB"),
        .product(name: "Ptex", package: "MetaPtex"),
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
      name: "Kraken",
      dependencies: [
        .product(name: "LatticeCore", package: "Lattice"),
        .product(name: "LatticeMetal", package: "Lattice"),
        .product(name: "LatticeUSD", package: "Lattice"),
        .product(name: "lattice", package: "Lattice"),
        .target(name: "AkariCore"),
        .target(name: "AkariRender"),
        .target(name: "AkariHydra"),
        .target(name: "HdAkari"),
        // TODO: support externally provided openusd builds.
        // .target(name: "OpenUSD"),
        .product(name: "HydraKit", package: "swift-usd"),
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
      ],
      swiftSettings: [
        .interoperabilityMode(.Cxx)
      ]
    ),

    .testTarget(
      name: "AkariRenderTests",
      dependencies: [
        .target(name: "AkariCore"),
        .target(name: "AkariRender"),
        .target(name: "AkariHydra"),
      ],
      cxxSettings: [
        .define("_LIBCPP_ABI_NO_COMPRESSED_PAIR_PADDING")
      ],
      swiftSettings: [
        .interoperabilityMode(.Cxx)
      ]
    )
  ],
  cxxLanguageStandard: .gnucxx17
)
