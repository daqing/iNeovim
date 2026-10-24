// swift-tools-version:6.2
import PackageDescription

let package = Package(
    name: "GhosttySupport",
    platforms: [.macOS(.v14)],
    products: [
        // Dynamic on purpose: the app's debug dylib and the XCTest bundle
        // both run in the test-host process, and a static product gives each
        // its own copy of libghostty's global state (two uninitialized
        // copies = undefined behavior). One dynamic framework = one copy.
        .library(name: "GhosttySupport", type: .dynamic, targets: ["GhosttySupport"]),
        .library(name: "GhosttyKit", targets: ["GhosttyKit"]),
    ],
    targets: [
        // Built from ghostty 1.3.2-main+246f702 with Zig 0.16.0; see
        // Sources/GhosttySupport/ADAPTATION.md for the vendoring notes.
        .binaryTarget(name: "GhosttyKit", path: "Vendor/GhosttyKit.xcframework"),
        // Swift 5 language mode: the vendored sources come from Ghostty's
        // Xcode framework target and predate Swift 6 strict concurrency.
        // linkedLibrary: GhosttyKit's static library contains C++
        // (glslang), so every consumer link needs libc++.
        .target(
            name: "GhosttySupport",
            dependencies: ["GhosttyKit"],
            swiftSettings: [.swiftLanguageMode(.v5)],
            linkerSettings: [.linkedLibrary("c++")]
        ),
    ]
)
