// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TouchBridge",
    platforms: [.macOS(.v14)],
    targets: [
        .target(name: "TouchCore"),
        .target(name: "TouchPlatform", dependencies: ["TouchCore"]),
        .executableTarget(name: "TouchBridgeApp", dependencies: ["TouchCore", "TouchPlatform"]),
        .testTarget(name: "TouchCoreTests", dependencies: ["TouchCore"], resources: [.copy("Fixtures")]),
        .testTarget(name: "TouchPlatformTests", dependencies: ["TouchPlatform", "TouchCore"]),
    ]
)
