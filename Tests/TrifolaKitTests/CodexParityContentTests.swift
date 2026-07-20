import Foundation
import Testing
@testable import TrifolaKit

private func parityTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("trifola-codex-content-\(UUID().uuidString)",
                              isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func parityWriteLines(_ lines: [String], to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try (lines.joined(separator: "\n") + "\n")
        .write(to: url, atomically: true, encoding: .utf8)
}

private func parityMetadata(id: String, cwd: String = "/repo/parity") -> String {
    #"{"timestamp":"2026-07-11T10:00:00Z","type":"session_meta","payload":{"id":"\#(id)","cwd":"\#(cwd)","history_mode":"legacy","model_provider":"openai","cli_version":"1.2.3"}}"#
}

private func parityUser(_ message: String) -> String {
    let payload = try! JSONSerialization.data(withJSONObject: [
        "timestamp": "2026-07-11T10:00:01Z",
        "type": "event_msg",
        "payload": ["type": "user_message", "message": message],
    ])
    return String(decoding: payload, as: UTF8.self)
}

@Suite("Codex provider-parity content")
struct CodexParityContentTests {
    @Test func mruThreadIndexUsesNewestExplicitNameAndToleratesBadLines() {
        let index = Data(([
            #"{"id":"same","thread_name":"Older name","updated_at":"2026-07-01T00:00:00Z"}"#,
            "not-json",
            #"{"id":"same","thread_name":"Newest name","updated_at":"2026-07-02T00:00:00Z"}"#,
            #"{"id":"cleared","thread_name":"Old","updated_at":"2026-07-01T00:00:00Z"}"#,
            #"{"id":"cleared","thread_name":"   ","updated_at":"2026-07-03T00:00:00Z"}"#,
            #"{"id":"missing-name","updated_at":"2026-07-04T00:00:00Z"}"#,
        ].joined(separator: "\n") + "\n").utf8)

        let names = CodexSessionNames.parseSessionIndex(index)
        #expect(names == ["same": "Newest name"])
    }

    @Test func resolverRefreshesAndRejectsSymlinkedIndexes() throws {
        let root = try parityTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let index = root.appendingPathComponent("session_index.jsonl")
        try #"{"id":"thread","thread_name":"First","updated_at":"2026-07-01T00:00:00Z"}"#
            .write(to: index, atomically: true, encoding: .utf8)
        let resolver = CodexSessionNameResolver(indexURL: index)
        #expect(resolver.names() == ["thread": "First"])

        try #"{"id":"thread","thread_name":"A longer second title","updated_at":"2026-07-02T00:00:00Z"}"#
            .write(to: index, atomically: true, encoding: .utf8)
        #expect(resolver.names() == ["thread": "A longer second title"])

        let target = root.appendingPathComponent("target.jsonl")
        try FileManager.default.moveItem(at: index, to: target)
        try FileManager.default.createSymbolicLink(at: index, withDestinationURL: target)
        #expect(resolver.names().isEmpty)
    }

    @Test func providerScopedNameApplicationCannotCrossNameCollidingIDs() throws {
        let claude = SessionSummary(
            id: "collision", provider: .claude, project: "c", cwd: "/c",
            model: nil, lastActivity: nil, messageCount: 0,
            usage: SessionUsage(), contextWeight: 0)
        let codex = SessionSummary(
            id: "collision", provider: .codex, project: "x", cwd: "/x",
            model: "gpt-5.6-sol", lastActivity: nil, messageCount: 0,
            usage: SessionUsage(), contextWeight: 0)

        let codexNamed = SessionStore.applyNames(
            [claude, codex], names: ["collision": "Codex title"],
            provider: .codex)
        #expect(codexNamed.first(where: { $0.provider == .claude })?.name == nil)
        #expect(codexNamed.first(where: { $0.provider == .codex })?.name == "Codex title")

        let bothNamed = SessionStore.applyNames(
            codexNamed, names: ["collision": "Claude title"])
        #expect(bothNamed.first(where: { $0.provider == .claude })?.name == "Claude title")
        #expect(bothNamed.first(where: { $0.provider == .codex })?.name == "Codex title")
    }

    @Test func rolloutTitleFallsBackToFirstGenuinePromptAndKeepsLatestPrompt() {
        var accumulator = CodexRolloutAccumulator(defaultID: "fallback")
        accumulator.ingest(Data(([
            parityMetadata(id: "prompt-title"),
            parityUser("/model gpt-5.6-sol"),
            parityUser("fix /repo/parity/Sources/App.swift without changing behavior"),
            parityUser("then run the focused tests"),
        ].joined(separator: "\n") + "\n").utf8))
        let summary = accumulator.summary(filePath: "/rollout.jsonl")

        #expect(summary.name == nil)
        #expect(summary.displayTitle == "Fix App.swift without changing behavior")
        #expect(summary.lastUserMessage == "then run the focused tests")
    }

    @Test @MainActor
    func sessionStoreAppliesCodexMRUNameOverPromptFallback() async throws {
        let root = try parityTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let claudeRoot = root.appendingPathComponent("claude", isDirectory: true)
        let codexRoot = root.appendingPathComponent("codex", isDirectory: true)
        let sessions = codexRoot.appendingPathComponent("sessions", isDirectory: true)
        let rollout = sessions.appendingPathComponent(
            "2026/07/11/rollout-title.jsonl")
        try parityWriteLines([
            parityMetadata(id: "named-thread"),
            parityUser("fallback prompt title"),
        ], to: rollout)
        try #"{"id":"named-thread","thread_name":"Explicit Codex title","updated_at":"2026-07-11T11:00:00Z"}"#
            .write(to: codexRoot.appendingPathComponent("session_index.jsonl"),
                   atomically: true, encoding: .utf8)

        let claudePaths = ClaudePaths(
            root: claudeRoot, source: .environmentOverride,
            sessionIndexCacheURL: root.appendingPathComponent("cache.json"))
        let codexPaths = CodexPaths(root: codexRoot, source: .environmentOverride)
        let store = SessionStore(paths: claudePaths, codexPaths: codexPaths)
        store.sources = [.codex(root: sessions)]
        await store.refreshNow()

        let summary = try #require(store.sessions.first)
        #expect(summary.provider == .codex)
        #expect(summary.name == "Explicit Codex title")
        #expect(summary.handle == "Fallback prompt title")
        #expect(summary.displayTitle == "Explicit Codex title")
    }

    @Test func promptFallbackSurvivesVersion20IndexCacheRoundTrip() throws {
        let root = try parityTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        try parityWriteLines([
            parityMetadata(id: "cached-title"),
            parityUser("recover the cached human title"),
        ], to: sessions.appendingPathComponent(
            "2026/07/11/rollout-cached-title.jsonl"))
        let index = SessionIndex.update(
            SessionIndex(), source: .codex(root: sessions))
        let cache = root.appendingPathComponent("cache.json")
        SessionStore.saveIndexCache(index, to: cache)
        let loaded = try #require(SessionStore.loadIndexCache(from: cache))

        #expect(loaded.summaries.first?.displayTitle == "Recover the cached human title")
        #expect(loaded.summaries.first?.lastUserMessage == "recover the cached human title")
    }

    @Test func onboardingCopyCoversEveryProviderPresenceWithoutClaudeOnlyLeakage() {
        let none = ProviderCorpusPresence(providers: [])
        let claude = ProviderCorpusPresence(providers: [.claude])
        let codex = ProviderCorpusPresence(providers: [.codex])
        let both = ProviderCorpusPresence(providers: [.claude, .codex])
        let grok = ProviderCorpusPresence(providers: [.grok])
        let all = ProviderCorpusPresence(providers: [.claude, .codex, .grok])

        #expect(none.onboardingState == .none)
        #expect(claude.onboardingState == .single(.claude))
        #expect(codex.onboardingState == .single(.codex))
        #expect(both.onboardingState == .multiple([.claude, .codex]))
        #expect(grok.onboardingState == .single(.grok))
        #expect(all.onboardingState == .multiple([.claude, .codex, .grok]))
        #expect(codex.onboardingCopy.headline == "Codex sessions are ready")
        #expect(!codex.onboardingCopy.headline.lowercased().contains("claude"))
        #expect(!codex.onboardingCopy.detail.lowercased().contains("first claude"))
        #expect(both.onboardingCopy.headline.contains("Claude Code and Codex"))
        #expect(grok.onboardingCopy.headline == "Grok sessions are ready")
        #expect(all.onboardingCopy.headline.contains("Claude Code, Codex, and Grok"))
    }

    @Test func rolloutTranscriptRendersMetaTurnsToolsOutputsAndTokens() {
        let functionCall = #"{"timestamp":"2026-07-11T10:00:05Z","type":"response_item","payload":{"type":"function_call","call_id":"call-1","name":"exec_command","arguments":"{\"cmd\":\"swift test --filter Codex\"}"}}"#
        let functionOutput = #"{"timestamp":"2026-07-11T10:00:06Z","type":"response_item","payload":{"type":"function_call_output","call_id":"call-1","output":"27 tests passed"}}"#
        let tokenCount = #"{"timestamp":"2026-07-11T10:00:07Z","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":1000,"cached_input_tokens":400,"output_tokens":100,"reasoning_output_tokens":70}}}}"#
        let lines = [
            "malformed",
            parityMetadata(id: "transcript"),
            #"{"timestamp":"2026-07-11T10:00:02Z","type":"turn_context","payload":{"turn_id":"turn-1","model":"gpt-5.6-sol","effort":"high"}}"#,
            parityUser("ship the provider transcript"),
            #"{"timestamp":"2026-07-11T10:00:03Z","type":"event_msg","payload":{"type":"agent_message","message":"I’ll inspect the rollout."}}"#,
            #"{"timestamp":"2026-07-11T10:00:04Z","type":"event_msg","payload":{"type":"agent_reasoning","text":"Need a tolerant parser."}}"#,
            functionCall,
            functionOutput,
            tokenCount,
            #"{"timestamp":"2026-07-11T10:00:08Z","type":"future_record","payload":{"type":"unknown"}}"#,
        ]
        let events = CodexRolloutTranscriptParser.events(
            from: Data((lines.joined(separator: "\n") + "\n").utf8))

        #expect(events.contains { event in
            guard case .system(let subtype, _) = event.kind else { return false }
            return subtype == "Codex rollout"
        })
        #expect(events.contains { event in
            guard case .userPrompt(let text) = event.kind else { return false }
            return text == "ship the provider transcript"
        })
        #expect(events.contains { event in
            guard case .assistantText(let text) = event.kind else { return false }
            return text.contains("inspect the rollout")
        })
        #expect(events.contains { event in
            guard case .thinking(let text) = event.kind else { return false }
            return text == "Need a tolerant parser."
        })
        #expect(events.contains { event in
            guard case .toolUse(let name, let detail) = event.kind else { return false }
            return name == "exec_command" && detail == "swift test --filter Codex"
        })
        #expect(events.contains { event in
            guard case .toolResult(let preview, let isError) = event.kind else { return false }
            return preview == "27 tests passed" && !isError
        })
        #expect(events.contains { event in
            guard case .system(let subtype, let text) = event.kind else { return false }
            return subtype == "Codex tokens"
                && text == "1000 input · 400 cached · 100 output · 70 reasoning"
        })
    }

    @Test func paginatedCompletedItemsAndMalformedNeighborsRemainReadable() {
        let completed = #"{"timestamp":"2026-07-11T10:00:00Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"custom_tool_call","call_id":"c2","name":"apply_patch","input":"*** Begin Patch"}}}"#
        let output = #"{"timestamp":"2026-07-11T10:00:01Z","type":"response_item","payload":{"type":"item_completed","item":{"type":"custom_tool_call_output","call_id":"c2","output":{"status":"ok","changed":2}}}}"#
        let data = Data(("bad\n" + completed + "\n{}\n" + output + "\n").utf8)
        let events = CodexRolloutTranscriptParser.events(from: data)
        #expect(events.count == 2)
        #expect(events.contains { if case .toolUse = $0.kind { true } else { false } })
        #expect(events.contains { if case .toolResult = $0.kind { true } else { false } })
    }

    @Test(
        // CI cannot spawn subprocesses from swift test (the ProbePrimitives
        // precedent) — the zstd seam is exercised on developer machines.
        .enabled(if: ProcessInfo.processInfo.environment["CI"] == nil
            && (FileManager.default.isExecutableFile(
                atPath: "/opt/homebrew/bin/zstd")
                || FileManager.default.isExecutableFile(
                    atPath: "/usr/local/bin/zstd")))
    )
    func archivedRolloutTranscriptUsesBoundedZstdSeam() throws {
        let root = try parityTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let archive = root.appendingPathComponent("rollout-archive.jsonl.zst")
        let encoded = "KLUv/QRYpQQAUoogHmBJqwNA7GrIXxLjBUEl3ABvksTUgpZ9+ZgMQ+Bj8USMZ/wOUgA47QzXs1XcGmFb4ZQoi0EbRIyHCRmWXb+KWwIX7rcIbt5pC3hxhWtdXK8O0s2P6pdwvVo/6BViBpG7OepticLrvX3Xr4N984FMzdQ0BNI4AXmQI4/rXUP9tq3+IQUAQE6Q7yDmPj2FQidTZvNWwA8="
        try #require(Data(base64Encoded: encoded)).write(to: archive)
        let events = try #require(CodexRolloutTranscriptParser.events(at: archive))

        #expect(events.contains { event in
            guard case .system(let subtype, _) = event.kind else { return false }
            return subtype == "Codex rollout"
        })
    }
}
