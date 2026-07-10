import Foundation
import Testing
@testable import TrifolaKit

@Suite("Release surface identity")
struct ReleaseSurfaceTests {
    private var versionFile: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("VERSION")
    }

    @Test("root VERSION, bundle fields, and MCP identity share one value")
    func versionEqualityContract() throws {
        let source = try String(contentsOf: versionFile, encoding: .utf8)
        let version = source.trimmingCharacters(in: .whitespacesAndNewlines)

        #expect(version.split(separator: ".").count == 3)
        #expect(MCPIntrospectionServer.serverVersion == version)
        #expect(ReleaseIdentity.versionsAgree(
            versionFileContents: source,
            bundleShortVersion: version,
            bundleBuildVersion: version,
            mcpVersion: MCPIntrospectionServer.serverVersion))
        #expect(!ReleaseIdentity.versionsAgree(
            versionFileContents: source,
            bundleShortVersion: "9.9.9",
            bundleBuildVersion: version,
            mcpVersion: MCPIntrospectionServer.serverVersion))
    }

    @Test("both self-check spellings are headless commands")
    func selfCheckAliasesAndUnknownFlags() {
        #expect(TrifolaCommandLine.isSelfCheck(["--selfcheck"]))
        #expect(TrifolaCommandLine.isSelfCheck(["--self-check"]))
        #expect(TrifolaCommandLine.unknownHeadlessFlags(
            in: ["--self-check", "--render-icon"]).isEmpty)
        #expect(TrifolaCommandLine.unknownHeadlessFlags(
            in: ["--self-chek"]) == ["--self-chek"])
        #expect(TrifolaCommandLine.usage.contains("--help"))
        #expect(TrifolaCommandLine.usage.contains("--render-icon <iconset-dir>"))
    }

    @Test("brand renderer declares Apple's full iconset")
    func completeIconsetManifest() {
        let expected = [
            ("icon_16x16.png", 16),
            ("icon_16x16@2x.png", 32),
            ("icon_32x32.png", 32),
            ("icon_32x32@2x.png", 64),
            ("icon_128x128.png", 128),
            ("icon_128x128@2x.png", 256),
            ("icon_256x256.png", 256),
            ("icon_256x256@2x.png", 512),
            ("icon_512x512.png", 512),
            ("icon_512x512@2x.png", 1024),
        ]
        #expect(BrandAssetManifest.iconset.count == expected.count)
        for (entry, expectedEntry) in zip(BrandAssetManifest.iconset, expected) {
            #expect(entry.filename == expectedEntry.0)
            #expect(entry.pixels == expectedEntry.1)
        }
        #expect(BrandAssetManifest.bannerWidth == 1_280)
        #expect(BrandAssetManifest.bannerHeight == 360)
    }
}
