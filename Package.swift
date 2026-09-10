// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Localhost",
    platforms: [.macOS(.v14)],
    targets: [
        // Discovery and attribution. No UI, and no ability to signal a process.
        .target(name: "LocalhostKit"),
        // Views and view state, separated from the executable so that layout
        // can be rendered and asserted on in tests.
        .target(name: "LocalhostUI", dependencies: ["LocalhostKit"]),
        .executableTarget(name: "Localhost", dependencies: ["LocalhostKit", "LocalhostUI"]),
        .testTarget(name: "LocalhostKitTests", dependencies: ["LocalhostKit"]),
        .testTarget(name: "LocalhostUITests", dependencies: ["LocalhostUI", "LocalhostKit"]),
    ]
)
