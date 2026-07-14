import Foundation
import Darwin
import SQLite3
import Testing
@testable import TrifolaKit

@Suite("Conversation search index")
struct SearchIndexTests {
    private final class ProgressRecorder: @unchecked Sendable {
        private let lock = NSLock()
        private var _partialResults = 0
        private var _events: [SearchIndexBatchProgress] = []

        func record(_ progress: SearchIndexBatchProgress, results: Int) {
            lock.lock()
            _events.append(progress)
            _partialResults = max(_partialResults, results)
            lock.unlock()
        }

        var snapshot: (events: [SearchIndexBatchProgress], partialResults: Int) {
            lock.lock()
            defer { lock.unlock() }
            return (_events, _partialResults)
        }
    }

    private func withTempDirectory<T>(_ body: (URL) throws -> T) throws -> T {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("trifola-search-\(UUID().uuidString)",
                                    isDirectory: true)
        try FileManager.default.createDirectory(at: url,
                                                withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: url) }
        return try body(url)
    }

    private func summary(id: String, file: URL, provider: Provider = .claude,
                         title: String? = nil, project: String = "search-fixture",
                         lastActivity: Date? = Date(timeIntervalSince1970: 1_700_000_000))
        -> SessionSummary {
        SessionSummary(
            id: id, provider: provider, project: project,
            cwd: "/fixture/\(project)", model: nil,
            lastActivity: lastActivity, messageCount: 2,
            usage: SessionUsage(), contextWeight: 0,
            filePath: file.path, lastUserMessage: "fixture prompt",
            name: title ?? "Synthetic \(id)")
    }

    private func write(_ lines: [String], to url: URL) throws {
        try lines.joined(separator: "\n").data(using: .utf8)!.write(to: url)
    }

    private func index(in root: URL) throws -> SearchIndex {
        try SearchIndex(storageURL: root.appendingPathComponent("search.sqlite3"))
    }

    @Test("tokenization lowercases and uses Unicode alphanumeric boundaries")
    func tokenization() {
        #expect(SearchText.tokens(in: "Keychain_QUOTA, café42 + X")
            == ["keychain", "quota", "café42"])
        #expect(SearchText.tokens(in: "密钥配额问题") == ["密钥配额问题"])
        #expect(SearchText.tokens(in: "密钥").first == "密钥")
        #expect(!SearchText.tokens(in: "密").contains("密"))
    }

    @Test("indexes Claude and Codex user/assistant prose but excludes tool output")
    func providerProjectionAndToolExclusion() throws {
        try withTempDirectory { root in
            let claude = root.appendingPathComponent("claude.jsonl")
            try write([
                #"{"type":"user","uuid":"u1","message":{"content":"Keychain quota question"}}"#,
                #"{"type":"assistant","uuid":"a1","message":{"content":[{"type":"text","text":"The quota is documented"}]}}"#,
                #"{"type":"user","uuid":"u2","message":{"content":[{"type":"tool_result","content":"secret tool needle"}]}}"#,
            ], to: claude)
            let codex = root.appendingPathComponent("codex.jsonl")
            try write([
                #"{"timestamp":"2026-07-11T09:10:02Z","type":"event_msg","payload":{"type":"item_completed","item":{"id":"user-1","type":"user_message","message":"Remembered rollover budget"}}}"#,
                #"{"timestamp":"2026-07-11T09:10:05Z","type":"event_msg","payload":{"type":"item_completed","item":{"id":"agent-1","type":"agent_message","message":"Budget notes are ready"}}}"#,
                #"{"timestamp":"2026-07-11T09:10:07Z","type":"event_msg","payload":{"type":"item_completed","item":{"id":"result-1","type":"function_call_output","output":"codex tool needle"}}}"#,
            ], to: codex)

            let sessions = [
                summary(id: "claude", file: claude),
                summary(id: "codex", file: codex, provider: .codex),
            ]
            let index = SearchIndex.update(try index(in: root), sessions: sessions).index
            #expect(index.query(SearchQuery("keychain quota"),
                                scope: .conversationText).map(\.id) == ["claude"])
            #expect(index.query(SearchQuery("rollover budget"),
                                scope: .conversationText).map(\.id) == ["codex"])
            #expect(index.query(SearchQuery("tool needle"),
                                scope: .conversationText).isEmpty)
        }
    }

    @Test("incremental update reuses unchanged files and replaces rewrites")
    func incrementalRewrite() throws {
        try withTempDirectory { root in
            let file = root.appendingPathComponent("session.jsonl")
            try write([
                #"{"type":"user","message":{"content":"original orchard term"}}"#,
            ], to: file)
            let session = summary(id: "rewrite", file: file)
            let first = SearchIndex.update(try index(in: root), sessions: [session])
            #expect(first.succeeded, Comment(rawValue: first.failureReason ?? "unknown"))
            #expect(first.rebuiltDocuments == 1)
            let unchanged = SearchIndex.update(first.index, sessions: [session])
            #expect(unchanged.succeeded,
                    Comment(rawValue: unchanged.failureReason ?? "unknown"))
            #expect(unchanged.reusedDocuments == 1)

            let handle = try FileHandle(forWritingTo: file)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(
                "\n{\"type\":\"user\",\"message\":{\"content\":\"appended delta lighthouse\"}}".utf8))
            try handle.close()
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: 1)],
                ofItemAtPath: file.path)
            let appended = SearchIndex.update(unchanged.index, sessions: [session])
            #expect(appended.succeeded,
                    Comment(rawValue: appended.failureReason ?? "unknown"))
            #expect(appended.appendedDocuments == 1)
            #expect(appended.index.query(SearchQuery("appended lighthouse"),
                                          scope: .conversationText).map(\.id) == ["rewrite"])

            try write([
                #"{"type":"user","message":{"content":"replacement harbor term"}}"#,
            ], to: file)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: 2)],
                ofItemAtPath: file.path)
            let rewritten = SearchIndex.update(appended.index, sessions: [session])
            #expect(rewritten.rebuiltDocuments == 1)
            #expect(rewritten.index.query(SearchQuery("original orchard"),
                                          scope: .conversationText).isEmpty)
            #expect(rewritten.index.query(SearchQuery("replacement harbor"),
                                          scope: .conversationText).map(\.id) == ["rewrite"])
        }
    }

    @Test("a poisoned fingerprint (parsed_offset=0, size>0) heals on the next update")
    func poisonedFingerprintHeals() throws {
        try withTempDirectory { root in
            let file = root.appendingPathComponent("session.jsonl")
            try write([
                #"{"type":"user","message":{"content":"poisoned lantern content"}}"#,
            ], to: file)
            let session = summary(id: "poisoned", file: file)
            let built = SearchIndex.update(try index(in: root), sessions: [session])
            #expect(built.succeeded, Comment(rawValue: built.failureReason ?? "unknown"))

            // Simulate the historical read-failure poison: fingerprint claims the
            // file at full size while zero bytes were parsed and no rows exist.
            var raw: OpaquePointer?
            #expect(sqlite3_open(built.index.databaseURL.path, &raw) == SQLITE_OK)
            defer { sqlite3_close(raw) }
            #expect(sqlite3_exec(raw, """
                DELETE FROM search_rows WHERE document_key IN
                    (SELECT key FROM documents WHERE session_id = 'poisoned');
                UPDATE documents SET parsed_offset = 0 WHERE session_id = 'poisoned';
                """, nil, nil, nil) == SQLITE_OK)
            #expect(built.index.query(SearchQuery("poisoned lantern"),
                                      scope: .conversationText).isEmpty)

            let healed = SearchIndex.update(built.index, sessions: [session])
            #expect(healed.succeeded,
                    Comment(rawValue: healed.failureReason ?? "unknown"))
            #expect(healed.index.query(SearchQuery("poisoned lantern"),
                                       scope: .conversationText).map(\.id) == ["poisoned"])
        }
    }

    @Test("exact phrase outranks bag of words and recency breaks equal hits")
    func ranking() throws {
        try withTempDirectory { root in
            let phrase = root.appendingPathComponent("a-phrase.jsonl")
            let bag = root.appendingPathComponent("b-bag.jsonl")
            let recent = root.appendingPathComponent("c-recent.jsonl")
            try write([#"{"type":"user","message":{"content":"keychain quota repair"}}"#],
                      to: phrase)
            try write([#"{"type":"user","message":{"content":"quota notes about keychain repair"}}"#],
                      to: bag)
            try write([#"{"type":"user","message":{"content":"harbor notes"}}"#],
                      to: recent)
            let now = Date(timeIntervalSince1970: 1_800_000_000)
            let sessions = [
                summary(id: "phrase", file: phrase,
                        lastActivity: now.addingTimeInterval(-300 * 86_400)),
                summary(id: "bag", file: bag, lastActivity: now),
                summary(id: "old", file: bag,
                        lastActivity: now.addingTimeInterval(-100 * 86_400)),
                summary(id: "recent", file: recent, lastActivity: now),
            ]
            let index = SearchIndex.update(try index(in: root), sessions: sessions).index
            let keychain = index.query(SearchQuery("keychain quota"),
                                       scope: .conversationText, now: now)
            #expect(keychain.first?.id == "phrase")
            #expect(keychain.first?.exactPhrase == true)
            let harbor = index.query(SearchQuery("harbor"),
                                     scope: .conversationText, now: now)
            #expect(harbor.first?.id == "recent")
        }
    }

    @Test("search cache round-trips and version mismatch loudly rebuilds")
    func cacheVersionLadder() throws {
        try withTempDirectory { root in
            let file = root.appendingPathComponent("session.jsonl")
            try write([#"{"type":"user","message":{"content":"cache ladder term"}}"#],
                      to: file)
            let index = SearchIndex.update(
                try index(in: root), sessions: [summary(id: "cache", file: file)]).index
            switch SearchIndex.load(from: index.databaseURL) {
            case .ready(let loaded):
                #expect(loaded.query(SearchQuery("cache ladder"),
                                     scope: .conversationText).map(\.id) == ["cache"])
            default:
                Issue.record("current cache version did not load")
            }
            var database: OpaquePointer?
            #expect(sqlite3_open(index.databaseURL.path, &database) == SQLITE_OK)
            #expect(sqlite3_exec(database, "PRAGMA user_version=1", nil, nil, nil)
                == SQLITE_OK)
            sqlite3_close(database)
            switch SearchIndex.load(from: index.databaseURL) {
            case .versionMismatch(let found): #expect(found == 1)
            default: Issue.record("old cache did not report version mismatch")
            }
        }
    }

    @Test("snippets are reread from exact user or assistant text")
    func snippets() throws {
        try withTempDirectory { root in
            let file = root.appendingPathComponent("session.jsonl")
            try write([
                #"{"type":"user","message":{"content":"Please inspect the Keychain quota before release."}}"#,
                #"{"type":"assistant","message":{"content":[{"type":"text","text":"I found the quota record."}]}}"#,
            ], to: file)
            let index = SearchIndex.update(
                try index(in: root), sessions: [summary(id: "snippet", file: file)]).index
            let candidate = try #require(index.query(
                SearchQuery("keychain quota"), scope: .conversationText).first)
            let snippet = try #require(SearchSnippetExtractor.snippet(
                for: candidate, query: SearchQuery("keychain quota")))
            #expect(snippet.text == "Please inspect the Keychain quota before release.")
            #expect(snippet.role == "You")
            #expect(snippet.highlights.count == 2)
        }
    }

    @Test("batch commits expose partial results and removed sessions disappear")
    func progressiveBatchesAndDeletion() throws {
        try withTempDirectory { root in
            var sessions: [SessionSummary] = []
            for number in 0..<3 {
                let file = root.appendingPathComponent("progress-\(number).jsonl")
                try write([
                    #"{"type":"user","message":{"content":"progressive lighthouse #(number)"}}"#,
                ], to: file)
                sessions.append(summary(id: "progress-\(number)", file: file))
            }
            let index = try index(in: root)
            let recorder = ProgressRecorder()
            let update = SearchIndex.update(
                index, sessions: sessions, batchSize: 1) { progress in
                    let results = progress.indexed < progress.total
                        ? index.query(SearchQuery("progressive lighthouse"),
                                      scope: .conversationText).count
                        : 0
                    recorder.record(progress, results: results)
                }
            #expect(update.succeeded,
                    Comment(rawValue: update.failureReason ?? "unknown"))
            let captured = recorder.snapshot
            #expect(captured.events.map(\.indexed) == [1, 2, 3])
            #expect(captured.partialResults > 0)

            let deleted = SearchIndex.update(update.index,
                                             sessions: Array(sessions.dropLast()))
            #expect(deleted.succeeded)
            #expect(deleted.removedDocuments == 1)
            #expect(deleted.index.statistics.documentCount == 2)
            #expect(!deleted.index.query(
                SearchQuery("progressive lighthouse"),
                scope: .conversationText).map(\.id).contains("progress-2"))
        }
    }

    @Test("successful SQLite rebuild removes the legacy JSON cache")
    @MainActor
    func legacyMigrationDeletion() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("trifola-search-migration-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let project = root.appendingPathComponent("projects/fixture", isDirectory: true)
        try FileManager.default.createDirectory(
            at: project, withIntermediateDirectories: true)
        let transcript = project.appendingPathComponent("migration.jsonl")
        try write([
            #"{"type":"user","cwd":"/tmp/migration","sessionId":"migration-session","timestamp":"2026-01-01T10:00:00.000Z","message":{"content":"migration lighthouse prose"}}"#,
            #"{"type":"assistant","sessionId":"migration-session","requestId":"migration-request","timestamp":"2026-01-01T10:00:01.000Z","message":{"id":"migration-message","model":"claude-opus-4-8","content":[{"type":"text","text":"migration lighthouse ready"}],"usage":{"input_tokens":1,"output_tokens":1,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#,
        ], to: transcript)
        let paths = ClaudePaths(
            root: root, source: .environmentOverride,
            sessionIndexCacheURL: root.appendingPathComponent("session-index.json"))
        try Data("{\"version\":1}".utf8).write(
            to: paths.legacySearchIndexCacheURL)
        let store = SessionStore(
            paths: paths,
            codexPaths: CodexPaths(
                root: root.appendingPathComponent("codex", isDirectory: true),
                source: .environmentOverride))
        store.sources = [.claude(root: paths.projects)]
        await store.refreshNow()

        let deadline = Date().addingTimeInterval(5)
        while store.searchState != .ready, Date() < deadline {
            try await Task.sleep(for: .milliseconds(20))
        }
        #expect(store.searchState == .ready)
        #expect(FileManager.default.fileExists(
            atPath: paths.searchIndexCacheURL.path))
        #expect(!FileManager.default.fileExists(
            atPath: paths.legacySearchIndexCacheURL.path))
        #expect(store.searchIndex.query(
            SearchQuery("migration lighthouse"),
            scope: .conversationText).map(\.id) == ["migration-session"])
    }

    @Test("7k synthetic corpus stays inside the documented search budget")
    func syntheticPerformanceBudget() throws {
        try withTempDirectory { root in
            var sessions: [SessionSummary] = []
            sessions.reserveCapacity(7_000)
            for index in 0..<7_000 {
                let file = root.appendingPathComponent("session-\(index).jsonl")
                try write([
                    #"{"type":"user","message":{"content":"Synthetic keychain quota fixture number \#(index)"}}"#,
                    #"{"type":"assistant","message":{"content":[{"type":"text","text":"Documented retry boundary for generated fixture"}]}}"#,
                ], to: file)
                sessions.append(summary(
                    id: "perf-\(index)", file: file,
                    lastActivity: Date(timeIntervalSince1970: 1_800_000_000 - Double(index))))
            }

            let memoryBefore = peakResidentBytes()
            let buildStart = Date()
            let index = SearchIndex.update(
                try index(in: root), sessions: sessions).index
            let buildSeconds = Date().timeIntervalSince(buildStart)
            let memoryAfter = peakResidentBytes()
            let memoryDelta = memoryAfter >= memoryBefore
                ? memoryAfter - memoryBefore : 0
            let cacheBytes = index.statistics.estimatedBytes

            _ = index.query(
                SearchQuery("keychain quota"),
                scope: .conversationText, limit: 20,
                now: Date(timeIntervalSince1970: 1_800_000_000))
            var queryDurations: [Double] = []
            queryDurations.reserveCapacity(50)
            for _ in 0..<50 {
                let start = Date()
                _ = index.query(
                    SearchQuery("keychain quota"),
                    scope: .conversationText, limit: 20,
                    now: Date(timeIntervalSince1970: 1_800_000_000))
                queryDurations.append(Date().timeIntervalSince(start))
            }
            queryDurations.sort()
            let queryMedian = queryDurations[queryDurations.count / 2]
            let queryP95 = queryDurations[Int(Double(queryDurations.count - 1) * 0.95)]
            let queryMaximum = queryDurations.last ?? 0
            print(String(format:
                "SEARCH_PERF sessions=7000 build=%.3fs peak_rss=%.1fMB delta_rss=%.1fMB cache=%.1fMB query_p50=%.3fms query_p95=%.3fms query_max=%.3fms",
                buildSeconds,
                Double(memoryAfter) / 1_048_576,
                Double(memoryDelta) / 1_048_576,
                Double(cacheBytes) / 1_048_576,
                queryMedian * 1_000,
                queryP95 * 1_000,
                queryMaximum * 1_000))

            #expect(index.statistics.documentCount == 7_000)
            #expect(buildSeconds < 15)
            #expect(memoryDelta < 250 * 1_048_576)
            #expect(cacheBytes < 100 * 1_048_576)
            #if DEBUG
            // The acceptance target describes the shipped/release app. Keep a
            // bounded debug guard too, while release runs pin the <50 ms target.
            #expect(queryMedian < 0.15)
            #else
            #expect(queryMedian < 0.05)
            #endif
        }
    }

    private func peakResidentBytes() -> UInt64 {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        return UInt64(max(0, usage.ru_maxrss))
    }
}
