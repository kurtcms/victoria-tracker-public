// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "VictoriaTrackerCore",
  platforms: [.macOS(.v13), .iOS(.v17)],
  products: [.library(name: "VictoriaTrackerCore", targets: ["VictoriaTrackerCore"])],
  targets: [
    .target(name: "VictoriaTrackerCore", path: "ios/VictoriaTracker/Core"),
    .testTarget(
      name: "VictoriaTrackerCoreTests", dependencies: ["VictoriaTrackerCore"], path: "tests/swift"),
  ]
)
