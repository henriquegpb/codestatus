// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "CodeStatus",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "CodeStatusCore", targets: ["CodeStatusCore"]),
        .executable(name: "CodeStatusApp", targets: ["CodeStatusApp"]),
        // Deliberately Foundation-free: this runs on every agent tool call.
        .executable(name: "codestatus-hook", targets: ["codestatus-hook"]),
    ],
    targets: [
        .target(name: "CodeStatusCore"),
        // Scanner and wire format, shared with the tests so the privacy
        // guarantee is checked as a pure function, not only end to end.
        .target(name: "HookCore"),
        .executableTarget(name: "CodeStatusApp", dependencies: ["CodeStatusCore"]),
        .executableTarget(name: "codestatus-hook", dependencies: ["HookCore"]),
        .testTarget(name: "CodeStatusCoreTests", dependencies: ["CodeStatusCore", "HookCore"]),
    ]
)
