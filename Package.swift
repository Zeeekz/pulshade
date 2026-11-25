// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Pulshade",
    platforms: [.macOS("26.0")],
    products: [
        // What Pulshade Admin, which lives in its own folder, builds on.
        .library(name: "PulshadeShared", targets: ["PulshadeShared"]),
    ],
    targets: [
        .executableTarget(
            name: "Pulshade",
            dependencies: ["PulshadeTor", "PulshadeShared", "CArgon2"],
            path: "Sources/Pulshade",
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedFramework("Security"), .linkedFramework("SystemConfiguration"), .linkedLibrary("resolv")]
        ),
        // What the app and Pulshade Admin (which lives in its own folder, outside this repository) both need:
        // announcements, profile links and notes, and sealed reports.
        .target(
            name: "PulshadeShared",
            path: "Sources/PulshadeShared",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Argon2id, the reference C code (see Sources/CArgon2/README.md), for turning the passcode into a key.
        .target(
            name: "CArgon2",
            path: "Sources/CArgon2",
            exclude: ["LICENSE", "README.md"],
            cSettings: [.define("ARGON2_NO_THREADS")]
        ),
        // Tor (Arti). Build it first with ./scripts/build-tor.sh.
        .binaryTarget(name: "PulshadeTor", path: "tor/build/PulshadeTor.xcframework"),
        .testTarget(
            name: "PulshadeTests",
            dependencies: ["Pulshade", "PulshadeShared", "CArgon2"],
            path: "Tests/PulshadeTests",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
    ]
)
