import Foundation
import Darwin
import Testing
@testable import TrifolaKit

@Suite("Conversation search index")
struct SearchIndexTests {
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
            let index = SearchIndex.update(SearchIndex(), sessions: sessions).index
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
            let first = SearchIndex.update(SearchIndex(), sessions: [session])
            #expect(first.rebuiltDocuments == 1)
            let unchanged = SearchIndex.update(first.index, sessions: [session])
            #expect(unchanged.reusedDocuments == 1)

            try write([
                #"{"type":"user","message":{"content":"replacement harbor term"}}"#,
            ], to: file)
            try FileManager.default.setAttributes(
                [.modificationDate: Date(timeIntervalSinceNow: 2)],
                ofItemAtPath: file.path)
            let rewritten = SearchIndex.update(unchanged.index, sessions: [session])
            #expect(rewritten.rebuiltDocuments == 1)
            #expect(rewritten.index.query(SearchQuery("original orchard"),
                                          scope: .conversationText).isEmpty)
            #expect(rewritten.index.query(SearchQuery("replacement harbor"),
                                          scope: .conversationText).map(\.id) == ["rewrite"])
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
            let index = SearchIndex.update(SearchIndex(), sessions: sessions).index
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
                SearchIndex(), sessions: [summary(id: "cache", file: file)]).index
            switch SearchIndex.load(data: try index.cacheData()) {
            case .ready(let loaded):
                #expect(loaded.query(SearchQuery("cache ladder"),
                                     scope: .conversationText).map(\.id) == ["cache"])
            default:
                Issue.record("current cache version did not load")
            }
            switch SearchIndex.load(data: try index.cacheData(version: 0)) {
            case .versionMismatch(let found): #expect(found == 0)
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
                SearchIndex(), sessions: [summary(id: "snippet", file: file)]).index
            let candidate = try #require(index.query(
                SearchQuery("keychain quota"), scope: .conversationText).first)
            let snippet = try #require(SearchSnippetExtractor.snippet(
                for: candidate, query: SearchQuery("keychain quota")))
            #expect(snippet.text == "Please inspect the Keychain quota before release.")
            #expect(snippet.role == "You")
            #expect(snippet.highlights.count == 2)
        }
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
                SearchIndex(), sessions: sessions).index
            let buildSeconds = Date().timeIntervalSince(buildStart)
            let memoryAfter = peakResidentBytes()
            let memoryDelta = memoryAfter >= memoryBefore
                ? memoryAfter - memoryBefore : 0
            let cacheBytes = try index.cacheData().count

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
            #expect(queryMedian < 0.075)
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
