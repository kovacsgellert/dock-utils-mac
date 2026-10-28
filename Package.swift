// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "dock-utils-mac",
  platforms: [.macOS(.v14)],
  products: [
    .executable(name: "dock-utils", targets: ["dock-utils"])
  ],
  targets: [
    .executableTarget(
      name: "dock-utils",
      path: "src"
    ),
    // Swift Testing (ships with the Command Line Tools; no Xcode needed).
    .testTarget(
      name: "DockUtilsTests",
      dependencies: ["dock-utils"],
      path: "Tests/DockUtilsTests"
    ),
  ],
  swiftLanguageModes: [.v5]
)
