// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Localhost",
    platforms: [.macOS(.v14)],
    dependencies: [
        // Updates. The only network access the app makes, and only when the
        // panel opens or the user asks. See LocalhostUI/Updates.swift.
        .package(url: "https://github.com/sparkle-project/Sparkle", exact: "2.10.0"),
    ],
    targets: [
        // Discovery and attribution. No UI, and no ability to signal a process.
        .target(name: "LocalhostKit"),
        // Views and view state, separated from the executable so that layout
        // can be rendered and asserted on in tests.
        .target(
            name: "LocalhostUI",
            dependencies: ["LocalhostKit", .product(name: "Sparkle", package: "Sparkle")]),
        .executableTarget(
            name: "Localhost",
            dependencies: ["LocalhostKit", "LocalhostUI"],
            // Sparkle.framework is copied into Contents/Frameworks by bundle.sh.
            linkerSettings: [.unsafeFlags(["-Xlinker", "-rpath", "-Xlinker", "@executable_path/../Frameworks"])]),
        .testTarget(name: "LocalhostKitTests", dependencies: ["LocalhostKit"]),
        .testTarget(name: "LocalhostUITests", dependencies: ["LocalhostUI", "LocalhostKit"]),
    ]
)
