// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Trifola",
    platforms: [.macOS(.v15)],
    targets: [
        // Data layer: parsing, aggregation, live tailing, file watching.
        // Pure Foundation/Combine — no AppKit/SwiftUI — so it is fully unit-testable.
        .target(
            name: "TrifolaKit",
            path: "Sources/TrifolaKit"
        ),
        // The app: glassmorphic SwiftUI command center + `--selfcheck` headless mode.
        .executableTarget(
            name: "Trifola",
            dependencies: ["TrifolaKit"],
            path: "Sources/Trifola"
        ),
        .testTarget(
            name: "TrifolaKitTests",
            dependencies: ["TrifolaKit"],
            path: "Tests/TrifolaKitTests"
        )
    ]
)
