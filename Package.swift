// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "oMLXInspector",
    platforms: [.macOS("27.0")],  // Matches the app build (Tools/build.sh) and Info.plist.
    products: [.library(name: "InspectorCore", targets: ["InspectorCore"])],
    targets: [
        .target(name: "InspectorCore"),
        .executableTarget(name: "InspectorApp", dependencies: ["InspectorCore"]),
        .testTarget(name: "InspectorCoreTests", dependencies: ["InspectorCore"]),
        .testTarget(name: "InspectorAppTests", dependencies: ["InspectorApp", "InspectorCore"])
    ]
)
