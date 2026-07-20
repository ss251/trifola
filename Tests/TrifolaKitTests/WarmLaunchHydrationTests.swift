import Foundation
import Testing
@testable import TrifolaKit

@Suite("Warm launch hydration")
struct WarmLaunchHydrationTests {
    @Test @MainActor
    func publishesEightThousandCachedSessionsWithoutRenumbering() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("trifola-warm-launch-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let claudeRoot = root.appendingPathComponent("claude", isDirectory: true)
        let project = claudeRoot.appendingPathComponent(
            "projects/warm-launch", isDirectory: true)
        let codexRoot = root.appendingPathComponent("codex", isDirectory: true)
        try FileManager.default.createDirectory(
            at: project, withIntermediateDirectories: true)

        let rowCount = 8_192
        var cached = SessionIndex()
        cached.entries.reserveCapacity(rowCount)
        var expectedIDs: [String] = []
        expectedIDs.reserveCapacity(rowCount)

        for number in 0..<rowCount {
            let sessionID = String(format: "session-%05d", number)
            let usageLines = (0..<8).map { message in
                #"{"type":"assistant","cwd":"/repo/warm-launch","requestId":"\#(sessionID)-request-\#(message)","timestamp":"2026-07-20T08:00:00.000Z","message":{"id":"\#(sessionID)-message-\#(message)","model":"claude-opus-4-8","usage":{"input_tokens":100,"output_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
            }
            let transcriptData = Data(
                (usageLines.joined(separator: "\n") + "\n").utf8)
            let file = project.appendingPathComponent("\(sessionID).jsonl")
            try transcriptData.write(to: file)
            let attributes = try FileManager.default.attributesOfItem(atPath: file.path)
            let size = try #require((attributes[.size] as? NSNumber)?.uint64Value)
            let mtime = try #require(attributes[.modificationDate] as? Date)
            var accumulator = SessionAccumulator(defaultID: sessionID)
            accumulator.ingest(transcriptData)
            let state = SessionParserState.claude(accumulator)
            cached.entries[file.path] = SessionIndex.Entry(
                size: size,
                mtime: mtime,
                acc: state,
                provider: .claude,
                machineID: Machine.localID,
                summary: state.summary(
                    filePath: file.path, machineID: Machine.localID))
            expectedIDs.append(sessionID)
        }

        let paths = ClaudePaths(
            root: claudeRoot,
            source: .environmentOverride,
            sessionIndexCacheURL: root.appendingPathComponent("session-index.sqlite3"))
        let saved = try #require(SessionStore.saveIndexCache(cached, to: paths.sessionIndexCacheURL))
        #expect(saved.inserted == rowCount)

        let store = SessionStore(
            paths: paths,
            codexPaths: CodexPaths(root: codexRoot, source: .environmentOverride))
        store.sources = [.claude(root: paths.projects)]
        let started = Date()
        await store.refreshNow()
        let elapsed = -started.timeIntervalSinceNow
        let publishedIDs = store.sessions.map(\.id).sorted()

        #expect(publishedIDs == expectedIDs)
        #expect(store.sessions.count == rowCount)
        #expect(store.sessions.reduce(0) { $0 + $1.usage.inputTokens }
                == rowCount * 800)
        #expect(store.scanPresentation == .liveRefreshing)
        #expect(elapsed < 15)
        print(String(format:
            "WARM_LAUNCH_EVIDENCE cached=%d published=%d unique_ids=%d first=%@ last=%@ input_tokens=%d refresh=%.2fs presentation=liveRefreshing",
            rowCount,
            store.sessions.count,
            Set(publishedIDs).count,
            publishedIDs.first ?? "missing",
            publishedIDs.last ?? "missing",
            store.sessions.reduce(0) { $0 + $1.usage.inputTokens },
            elapsed))
    }
}
