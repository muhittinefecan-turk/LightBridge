// swift-tools-version: 5.9
import PackageDescription

let package = Package(
    name: "LightBridgeCore",
    platforms: [.macOS(.v13), .iOS(.v16)],
    products: [.library(name: "LightBridgeCore", targets: ["LightBridgeCore"])],
    targets: [
        .target(name: "LightBridgeCore"),
        .testTarget(name: "LightBridgeCoreTests", dependencies: ["LightBridgeCore"]),
    ]
)
