// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Localhost",
    platforms: [.macOS(.v14)],
    targets: [
        // Discovery and attribution. No UI, no ability to signal a process.
        .target(name: "LocalhostKit"),
        .executableTarget(name: "Localhost", dependencies: ["LocalhostKit"]),
        .testTarget(name: "LocalhostKitTests", dependencies: ["LocalhostKit"]),
    ]
)
