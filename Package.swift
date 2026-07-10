// swift-tools-version: 6.0
import PackageDescription
import Foundation

let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
let versionFile = packageRoot.appendingPathComponent("VERSION")
let releaseVersion: String
do {
    releaseVersion = try String(contentsOf: versionFile, encoding: .utf8)
        .trimmingCharacters(in: .whitespacesAndNewlines)
} catch {
    fatalError("Unable to read release version at \(versionFile.path): \(error)")
}

let versionParts = releaseVersion.split(separator: ".", omittingEmptySubsequences: false)
precondition(versionParts.count == 3 && versionParts.allSatisfy { part in
    !part.isEmpty && part.allSatisfy(\.isNumber)
}, "VERSION must contain a numeric major.minor.patch release")

let package = Package(
    name: "Trifola",
    platforms: [.macOS(.v15)],
    targets: [
        // VERSION is compiled through one tiny C seam because SwiftPM does not
        // support string-valued Swift defines. Package.swift reads the root
        // VERSION file once and supplies this literal to every TrifolaKit build.
        .target(
            name: "TrifolaVersion",
            path: "Sources/TrifolaVersion",
            publicHeadersPath: "include",
            cSettings: [
                .define("TRIFOLA_RELEASE_VERSION", to: "\"\(releaseVersion)\"")
            ]
        ),
        // Data layer: parsing, aggregation, live tailing, file watching.
        // Pure Foundation/Combine — no AppKit/SwiftUI — so it is fully unit-testable.
        .target(
            name: "TrifolaKit",
            dependencies: ["TrifolaVersion"],
            path: "Sources/TrifolaKit"
        ),
        // The app: glassmorphic SwiftUI command center + `--selfcheck` headless mode.
        .executableTarget(
            name: "Trifola",
            dependencies: ["TrifolaKit"],
            path: "Sources/Trifola",
            swiftSettings: [
                .unsafeFlags(["-warnings-as-errors"])
            ]
        ),
        .testTarget(
            name: "TrifolaKitTests",
            dependencies: ["TrifolaKit"],
            path: "Tests/TrifolaKitTests"
        )
    ]
)
