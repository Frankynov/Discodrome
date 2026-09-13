// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Discodrome",
    platforms: [.macOS(.v15)],
    targets: [
        // Everything that doesn't need a window: the Subsonic client, the gapless
        // engine, tag reading, device scanning and matching. Covered by `swift test`.
        .target(
            name: "DiscodromeCore",
            path: "Sources/DiscodromeCore"
        ),
        .executableTarget(
            name: "Discodrome",
            dependencies: ["DiscodromeCore"],
            path: "Sources/Discodrome",
            swiftSettings: [.unsafeFlags(["-parse-as-library"])]
        ),
        .testTarget(
            name: "DiscodromeCoreTests",
            dependencies: ["DiscodromeCore"],
            path: "Tests/DiscodromeCoreTests"
        ),
    ]
)
