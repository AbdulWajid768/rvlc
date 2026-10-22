// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "RVLCPlayer",
    platforms: [.macOS(.v13)],
    products: [
        .executable(name: "RVLCPlayer", targets: ["RVLCPlayer"]),
        .library(name: "RVLCCore", targets: ["RVLCCore"]),
    ],
    targets: [
        // C bridge to the system/Homebrew libmpv (found through pkg-config).
        .systemLibrary(
            name: "CMpv",
            pkgConfig: "mpv",
            providers: [.brew(["mpv"]), .apt(["libmpv-dev"])]
        ),
        // Pure Foundation logic: subtitles, sync maths, library, preferences, key bindings.
        .target(name: "RVLCCore"),
        // libmpv integration: player state machine, video layer, audio extraction.
        .target(
            name: "RVLCEngine",
            dependencies: ["CMpv", "RVLCCore"],
            // libmpv embeds video through OpenGL on macOS; silence Apple's blanket deprecation notices.
            swiftSettings: [.unsafeFlags(["-Xcc", "-DGL_SILENCE_DEPRECATION"])]
        ),
        // AppKit user interface.
        .target(name: "RVLCApp", dependencies: ["RVLCCore", "RVLCEngine"]),
        // Thin executable entry point.
        .executableTarget(name: "RVLCPlayer", dependencies: ["RVLCApp"]),

        // Shared test helpers: FFmpeg-generated fixtures and run-loop waiting.
        .target(name: "RVLCTestSupport", path: "Tests/RVLCTestSupport"),
        .testTarget(name: "RVLCCoreTests", dependencies: ["RVLCCore"]),
        .testTarget(name: "RVLCEngineTests", dependencies: ["RVLCEngine", "RVLCCore", "RVLCTestSupport"]),
        .testTarget(name: "RVLCAppTests", dependencies: ["RVLCApp", "RVLCEngine", "RVLCCore", "RVLCTestSupport"]),
    ]
)
