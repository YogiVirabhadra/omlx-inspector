// swift-tools-version: 6.0
import PackageDescription
let package = Package(name: "oMLXInspector", platforms: [.macOS(.v15)], products: [.library(name: "InspectorCore", targets: ["InspectorCore"])], targets: [.target(name: "InspectorCore"), .testTarget(name: "InspectorCoreTests", dependencies: ["InspectorCore"])])
