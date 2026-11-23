// swift-tools-version:5.9
import PackageDescription

let package = Package(
    name: "WindowSnapshot",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "wsnap", targets: ["wsnap"]),
        .library(name: "WSnapCore", targets: ["WSnapCore"]),
    ],
    targets: [
        // Pure logic: models, parsing, matching, planning. No system or private API calls.
        .target(name: "WSnapCore"),
        // CLI + everything that talks to macOS.
        .executableTarget(name: "wsnap", dependencies: ["WSnapCore"]),
        .testTarget(name: "WSnapCoreTests", dependencies: ["WSnapCore"]),
    ]
)
