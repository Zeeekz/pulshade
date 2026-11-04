// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pulshade",
    platforms: [.macOS("26.0")],
    targets: [
        .executableTarget(
            name: "Pulshade",
            dependencies: ["PulshadeTor", "PulshadeShared"],
            path: "Sources/Pulshade",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("Security"), .linkedFramework("SystemConfiguration"), .linkedLibrary("resolv")]
        ),
        // What the app shares with the operator's tools: announcements and sealed reports.
        .target(
            name: "PulshadeShared",
            path: "Sources/PulshadeShared",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Tor (Arti). Build it first with ./scripts/build-tor.sh.
        .binaryTarget(name: "PulshadeTor", path: "tor/build/PulshadeTor.xcframework"),
        .testTarget(
            name: "PulshadeTests",
            dependencies: ["Pulshade", "PulshadeShared"],
            path: "Tests/PulshadeTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
