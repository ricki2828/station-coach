// swift-tools-version: 5.9
import PackageDescription

let package = Package(
  name: "CoachUI",
  platforms: [.iOS(.v17), .watchOS(.v10)],
  products: [.library(name: "CoachUI", targets: ["CoachUI"])],
  dependencies: [.package(path: "../CoachKit")],
  targets: [
    .target(name: "CoachUI", dependencies: [.product(name: "CoachKit", package: "CoachKit")]),
    .testTarget(name: "CoachUITests", dependencies: ["CoachUI", .product(name: "CoachKit", package: "CoachKit")]),
  ]
)
