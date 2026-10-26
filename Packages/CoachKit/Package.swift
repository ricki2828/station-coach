// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "CoachKit",
  platforms: [.iOS(.v17), .watchOS(.v10), .macOS(.v14)],
  products: [.library(name: "CoachKit", targets: ["CoachKit"])],
  targets: [
    .target(name: "CoachKit"),
    .testTarget(name: "CoachKitTests", dependencies: ["CoachKit"]),
  ]
)
