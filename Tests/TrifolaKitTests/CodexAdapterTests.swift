import Foundation
import Testing
@testable import TrifolaKit

private func codexTempDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("trifola-codex-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func writeRollout(_ lines: [String], to url: URL) throws {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try (lines.joined(separator: "\n") + "\n")
        .write(to: url, atomically: true, encoding: .utf8)
}

private func codexMetadata(id: String, cwd: String = "/tmp/codex-project",
                           historyMode: String = "legacy",
                           timestamp: String = "2026-07-10T10:00:00Z") -> String {
    #"{"timestamp":"\#(timestamp)","type":"session_meta","payload":{"id":"\#(id)","cwd":"\#(cwd)","history_mode":"\#(historyMode)","source":"exec","thread_source":"user"}}"#
}

private func codexTurn(model: String = "gpt-5.6-sol",
                       timestamp: String = "2026-07-10T10:00:30Z") -> String {
    #"{"timestamp":"\#(timestamp)","type":"turn_context","payload":{"turn_id":"turn-1","model":"\#(model)"}}"#
}

private func codexTokenCount(
    lastInput: Int, lastCached: Int, lastOutput: Int, lastReasoning: Int,
    totalInput: Int, totalCached: Int, totalOutput: Int, totalReasoning: Int,
    timestamp: String
) -> String {
    #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"last_token_usage":{"input_tokens":\#(lastInput),"cached_input_tokens":\#(lastCached),"output_tokens":\#(lastOutput),"reasoning_output_tokens":\#(lastReasoning),"total_tokens":\#(lastInput + lastOutput)},"total_token_usage":{"input_tokens":\#(totalInput),"cached_input_tokens":\#(totalCached),"output_tokens":\#(totalOutput),"reasoning_output_tokens":\#(totalReasoning),"total_tokens":\#(totalInput + totalOutput)}},"rate_limits":null}}"#
}

private func codexCumulativeOnly(
    input: Int, cached: Int, output: Int, reasoning: Int,
    timestamp: String
) -> String {
    #"{"timestamp":"\#(timestamp)","type":"event_msg","payload":{"type":"token_count","info":{"total_token_usage":{"input_tokens":\#(input),"cached_input_tokens":\#(cached),"output_tokens":\#(output),"reasoning_output_tokens":\#(reasoning)}},"rate_limits":null}}"#
}

@Suite("Codex read adapter")
struct CodexAdapterTests {
    @Test func providerDefaultsToClaudeAndLegacyDecodeStaysClaude() throws {
        let summary = SessionSummary(
            id: "legacy", project: "p", cwd: "/tmp/p", model: nil,
            lastActivity: nil, messageCount: 0, usage: SessionUsage(),
            contextWeight: 0)
        #expect(summary.provider == .claude)

        let encoded = try JSONEncoder().encode(summary)
        var object = try #require(
            JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        object.removeValue(forKey: "provider")
        let legacy = try JSONDecoder().decode(
            SessionSummary.self,
            from: JSONSerialization.data(withJSONObject: object))
        #expect(legacy.provider == .claude)
    }

    @Test func providerSurvivesTagPriceAndNameCopyPaths() throws {
        let codex = SessionSummary(
            id: "codex-copy", provider: .codex,
            project: "p", cwd: "/tmp/p", model: "gpt-5.6-sol",
            lastActivity: nil, messageCount: 0, usage: SessionUsage(),
            contextWeight: 0)
        #expect(codex.taggedWith("workstation").provider == .codex)
        #expect(codex.computingCostBundle().provider == .codex)

        let named = try #require(SessionStore.applyNames(
            [codex], names: ["codex-copy": "Claude-only name"]).first)
        #expect(named.provider == .codex)
        #expect(named.name == nil)
    }

    @Test func inclusiveCachedInputConvertsWithoutDoubleBilling() throws {
        let native = CodexTokenUsage(
            inputTokens: 1_000_000,
            cachedInputTokens: 400_000,
            outputTokens: 100_000,
            reasoningOutputTokens: 80_000)
        let usage = native.sessionUsage
        #expect(usage.inputTokens == 600_000)
        #expect(usage.cacheReadTokens == 400_000)
        #expect(usage.cacheCreateTokens == 0)
        #expect(usage.cacheCreate1hTokens == 0)
        #expect(usage.outputTokens == 100_000)
        #expect(usage.totalInput == native.inputTokens)

        let rate = try #require(
            PricingCatalog.bundled.rate(model: "gpt-5.6-sol"))
        // 0.6M fresh × $5 + 0.4M cached × $0.50 + 0.1M output × $30
        // = $3 + $0.20 + $3 = $6.20. Reasoning is already in output.
        #expect(abs(usage.cost(rate: rate) - 6.20) < 0.000_001)
    }

    @Test func cachedInputGreaterThanInputIsClampedWithoutNegativeMoney() throws {
        let lines = [
            codexMetadata(id: "malformed-cache"),
            codexTurn(),
            codexTokenCount(
                lastInput: 100, lastCached: 150,
                lastOutput: 10, lastReasoning: 0,
                totalInput: 100, totalCached: 150,
                totalOutput: 10, totalReasoning: 0,
                timestamp: "2026-07-10T10:01:00Z"),
        ]
        var accumulator = CodexRolloutAccumulator(defaultID: "fallback")
        accumulator.ingest(Data((lines.joined(separator: "\n") + "\n").utf8))
        let summary = accumulator.summary(filePath: "/malformed-cache.jsonl")

        #expect(summary.usage.inputTokens == 0)
        #expect(summary.usage.cacheReadTokens == 150)
        #expect(summary.usage.outputTokens == 10)
        #expect(summary.cost >= 0)
    }

    @Test func cumulativeCounterResetStartsFreshEpochWithoutNegativeOrOverwrite() {
        let lines = [
            codexMetadata(id: "counter-reset"),
            codexTurn(),
            codexTokenCount(
                lastInput: 100, lastCached: 40,
                lastOutput: 10, lastReasoning: 4,
                totalInput: 100, totalCached: 40,
                totalOutput: 10, totalReasoning: 4,
                timestamp: "2026-07-10T10:01:00Z"),
            codexCumulativeOnly(
                input: 200, cached: 80, output: 20, reasoning: 8,
                timestamp: "2026-07-10T10:02:00Z"),
            // A repeated cumulative heartbeat must not replace the non-zero
            // slice already stored under this total tuple.
            codexCumulativeOnly(
                input: 200, cached: 80, output: 20, reasoning: 8,
                timestamp: "2026-07-10T10:02:30Z"),
            codexCumulativeOnly(
                input: 100, cached: 40, output: 10, reasoning: 4,
                timestamp: "2026-07-10T10:03:00Z"),
        ]
        var accumulator = CodexRolloutAccumulator(defaultID: "fallback")
        accumulator.ingest(Data((lines.joined(separator: "\n") + "\n").utf8))
        let summary = accumulator.summary(filePath: "/counter-reset.jsonl")

        #expect(summary.usage.inputTokens == 180)
        #expect(summary.usage.cacheReadTokens == 120)
        #expect(summary.usage.outputTokens == 30)
        #expect(summary.usage.totalInput == 300)
        #expect(summary.rawUsageBlocks == 3)
        #expect(summary.cost >= 0)
        #expect(accumulator.usageReconcilesWithLatestTotal == nil)
    }

    @Test func reasoningOnlyCounterChangesDoNotAlterBillingOrStartResetEpoch() {
        let lines = [
            codexMetadata(id: "reasoning-only"),
            codexTurn(),
            codexTokenCount(
                lastInput: 100, lastCached: 40,
                lastOutput: 10, lastReasoning: 4,
                totalInput: 100, totalCached: 40,
                totalOutput: 10, totalReasoning: 4,
                timestamp: "2026-07-10T10:01:00Z"),
            codexCumulativeOnly(
                input: 100, cached: 40, output: 10, reasoning: 5,
                timestamp: "2026-07-10T10:02:00Z"),
            codexCumulativeOnly(
                input: 100, cached: 40, output: 10, reasoning: 3,
                timestamp: "2026-07-10T10:03:00Z"),
        ]
        var accumulator = CodexRolloutAccumulator(defaultID: "fallback")
        accumulator.ingest(Data((lines.joined(separator: "\n") + "\n").utf8))
        let summary = accumulator.summary(filePath: "/reasoning-only.jsonl")

        #expect(summary.usage.inputTokens == 60)
        #expect(summary.usage.cacheReadTokens == 40)
        #expect(summary.usage.outputTokens == 10)
        #expect(summary.rawUsageBlocks == 1)
        #expect(accumulator.usageReconcilesWithLatestTotal == true)
    }

    @Test func legacyRolloutProducesProviderNeutralSummaryAndReconciles() throws {
        let lines = [
            codexMetadata(id: "019-codex", cwd: "/repo/trifola"),
            codexTurn(),
            codexTokenCount(
                lastInput: 1_000, lastCached: 400,
                lastOutput: 100, lastReasoning: 70,
                totalInput: 1_000, totalCached: 400,
                totalOutput: 100, totalReasoning: 70,
                timestamp: "2026-07-10T10:01:00Z"),
            codexTokenCount(
                lastInput: 2_000, lastCached: 1_600,
                lastOutput: 200, lastReasoning: 100,
                totalInput: 3_000, totalCached: 2_000,
                totalOutput: 300, totalReasoning: 170,
                timestamp: "2026-07-10T10:02:00Z"),
        ]
        var accumulator = CodexRolloutAccumulator(defaultID: "fallback")
        accumulator.ingest(Data((lines.joined(separator: "\n") + "\n").utf8))
        let summary = accumulator.summary(filePath: "/rollout.jsonl")

        #expect(accumulator.historyMode == .legacy)
        #expect(accumulator.usageReconcilesWithLatestTotal == true)
        #expect(summary.id == "019-codex")
        #expect(summary.provider == .codex)
        #expect(summary.cwd == "/repo/trifola")
        #expect(summary.project == "trifola")
        #expect(summary.model == "gpt-5.6-sol")
        #expect(summary.messageCount == 4)
        #expect(summary.usage.inputTokens == 1_000)
        #expect(summary.usage.cacheReadTokens == 2_000)
        #expect(summary.usage.outputTokens == 300)
        #expect(summary.usage.totalInput == 3_000)
        #expect(summary.contextWeight == 2_000)
        #expect(summary.usageByModel["gpt-5.6-sol"] == summary.usage)
        #expect(summary.rawUsageBlocks == 2)
        #expect(summary.messagesByModelDay["2026-07-10"]?["gpt-5.6-sol"] == 2)
    }

    @Test func paginatedHistoryConsumesDiscriminatedCompletedTokenItem() {
        let nested = #"{"timestamp":"2026-07-10T10:01:00Z","type":"event_msg","payload":{"type":"item_completed","item":{"type":"token_count","info":{"last_token_usage":{"input_tokens":500,"cached_input_tokens":300,"output_tokens":50,"reasoning_output_tokens":40},"total_token_usage":{"input_tokens":500,"cached_input_tokens":300,"output_tokens":50,"reasoning_output_tokens":40}}}}}"#
        var accumulator = CodexRolloutAccumulator(defaultID: "fallback")
        accumulator.ingest(Data((
            codexMetadata(id: "page", historyMode: "paginated") + "\n"
            + codexTurn() + "\n" + nested + "\n").utf8))
        let summary = accumulator.summary(filePath: "/page.jsonl")
        #expect(accumulator.historyMode == .paginated)
        #expect(summary.usage.inputTokens == 200)
        #expect(summary.usage.cacheReadTokens == 300)
        #expect(summary.usage.outputTokens == 50)
    }

    @Test func firstSessionMetadataRemainsAuthoritativeWhenParentHistoryIsReplayed() {
        let child = #"{"timestamp":"2026-07-10T10:00:00Z","type":"session_meta","payload":{"id":"child-thread","session_id":"parent-thread","cwd":"/repo/child","history_mode":"paginated","source":{"subagent":{"thread_spawn":{"parent_thread_id":"parent-thread"}}},"thread_source":"subagent"}}"#
        let replayedParent = #"{"timestamp":"2026-07-10T10:00:01Z","type":"session_meta","payload":{"id":"parent-thread","session_id":"parent-thread","cwd":"/repo/parent","history_mode":"legacy","source":"exec","thread_source":"user"}}"#
        var accumulator = CodexRolloutAccumulator(defaultID: "fallback")
        accumulator.ingest(Data((child + "\n" + replayedParent + "\n").utf8))
        let summary = accumulator.summary(filePath: "/rollout-child.jsonl")
        #expect(summary.id == "child-thread")
        #expect(summary.cwd == "/repo/child")
        #expect(accumulator.historyMode == .paginated)
    }

    @Test func sourceDedupDropsImportedThreadsAndRefreshesManifestOnWarmScan() throws {
        let root = try codexTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let day = sessions.appendingPathComponent("2026/07/10", isDirectory: true)
        try writeRollout(
            [codexMetadata(id: "native"), codexTurn()],
            to: day.appendingPathComponent("rollout-native.jsonl"))
        try writeRollout(
            [codexMetadata(id: "imported"), codexTurn()],
            to: day.appendingPathComponent("rollout-imported.jsonl"))
        try writeRollout(
            [codexMetadata(id: "wrong-shape"), codexTurn()],
            to: day.appendingPathComponent("session-index-like.jsonl"))
        let outside = root.appendingPathComponent("outside.jsonl")
        try writeRollout([codexMetadata(id: "symlinked")], to: outside)
        try FileManager.default.createSymbolicLink(
            at: day.appendingPathComponent("rollout-link.jsonl"),
            withDestinationURL: outside)
        let manifestURL = root.appendingPathComponent(
            "external_agent_session_imports.json")
        let firstManifest = #"{"records":[{"source_path":"/tmp/source.jsonl","content_sha256":"abc","imported_thread_id":"imported"}]}"#
        try firstManifest.write(to: manifestURL, atomically: true, encoding: .utf8)
        let source = SessionSource.codex(
            root: sessions, importManifestURL: manifestURL)

        let first = SessionIndex.update(SessionIndex(), source: source)
        #expect(first.summaries.map(\.id) == ["native"])
        #expect(first.summaries.allSatisfy { $0.provider == .codex })

        // Manifest changes must invalidate an otherwise reusable entry.
        let secondManifest = #"{"records":[{"source_path":"/tmp/a.jsonl","content_sha256":"abc","imported_thread_id":"imported"},{"source_path":"/tmp/b.jsonl","content_sha256":"def","imported_thread_id":"native"}]}"#
        try secondManifest.write(to: manifestURL, atomically: true, encoding: .utf8)
        let warm = SessionIndex.update(first, source: source)
        #expect(warm.summaries.isEmpty)
    }

    @Test func codexHomeResolutionExposesOnlyExplicitStatePaths() {
        let home = URL(fileURLWithPath: "/tmp/trifola-home", isDirectory: true)
        let defaults = CodexPaths.resolve(home: home, environment: [:])
        #expect(defaults.root.path == "/tmp/trifola-home/.codex")
        #expect(defaults.sessions.path == "/tmp/trifola-home/.codex/sessions")
        #expect(defaults.sessionIndexJSONL.path == "/tmp/trifola-home/.codex/session_index.jsonl")
        #expect(defaults.externalAgentImportsJSON.path
                == "/tmp/trifola-home/.codex/external_agent_session_imports.json")

        let overridden = CodexPaths.resolve(
            home: home, environment: ["CODEX_HOME": "/tmp/codex-fixture"])
        #expect(overridden.source == .environmentOverride)
        #expect(overridden.sessions.path == "/tmp/codex-fixture/sessions")
    }

    @Test func importManifestReaderRejectsSymbolicLinks() throws {
        let root = try codexTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let target = root.appendingPathComponent("target.json")
        try #"{"records":[{"content_sha256":"abc","source_path":"/tmp/a","imported_thread_id":"imported"}]}"#
            .write(to: target, atomically: true, encoding: .utf8)
        let link = root.appendingPathComponent(
            "external_agent_session_imports.json")
        try FileManager.default.createSymbolicLink(
            at: link, withDestinationURL: target)
        #expect(CodexImportManifest.load(from: link) == CodexImportManifest())
    }

    @Test func codexCacheRoundTripUsesVersion20AndRejectsVersion19() throws {
        let root = try codexTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let rollout = sessions.appendingPathComponent(
            "2026/07/10/rollout-cache.jsonl")
        try writeRollout(
            [codexMetadata(id: "cache"), codexTurn()],
            to: rollout)
        let source = SessionSource.codex(
            root: sessions,
            importManifestURL: root.appendingPathComponent("imports.json"))
        let index = SessionIndex.update(SessionIndex(), source: source)
        let cache = root.appendingPathComponent("index.json")
        SessionStore.saveIndexCache(index, to: cache)

        let cacheObject = try #require(
            JSONSerialization.jsonObject(with: Data(contentsOf: cache))
                as? [String: Any])
        #expect((cacheObject["version"] as? NSNumber)?.intValue == 20)
        let loaded = try #require(SessionStore.loadIndexCache(from: cache))
        #expect(loaded.summaries.first?.provider == .codex)
        #expect(loaded.summaries.first?.id == "cache")
        #expect(loaded.summaries.first?.tier == .codex)

        var staleObject = cacheObject
        staleObject["version"] = 19
        try JSONSerialization.data(withJSONObject: staleObject)
            .write(to: cache, options: .atomic)
        #expect(SessionStore.loadIndexCache(from: cache) == nil)
    }

    @Test(
        .enabled(if: FileManager.default.isExecutableFile(
            atPath: "/opt/homebrew/bin/zstd")
            || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/zstd"))
    )
    func compressedRolloutIsDecompressedAndParsed() throws {
        let root = try codexTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let archive = sessions.appendingPathComponent(
            "2026/07/10/rollout-archive.jsonl.zst")
        try FileManager.default.createDirectory(
            at: archive.deletingLastPathComponent(), withIntermediateDirectories: true)
        let encoded = "KLUv/QRYpQQAUoogHmBJqwNA7GrIXxLjBUEl3ABvksTUgpZ9+ZgMQ+Bj8USMZ/wOUgA47QzXs1XcGmFb4ZQoi0EbRIyHCRmWXb+KWwIX7rcIbt5pC3hxhWtdXK8O0s2P6pdwvVo/6BViBpG7OepticLrvX3Xr4N984FMzdQ0BNI4AXmQI4/rXUP9tq3+IQUAQE6Q7yDmPj2FQidTZvNWwA8="
        try #require(Data(base64Encoded: encoded)).write(to: archive)

        let index = SessionIndex.update(
            SessionIndex(),
            source: .codex(
                root: sessions,
                importManifestURL: root.appendingPathComponent("imports.json")))
        let summary = try #require(index.summaries.first)
        #expect(summary.id == "zstd-session")
        #expect(summary.provider == .codex)
        #expect(summary.model == "gpt-5.6-sol")
    }

    @Test func decompressorSubprocessIsBoundedByTimeoutAndOutputCap() throws {
        let sleep = URL(fileURLWithPath: "/bin/sleep")
        let printf = URL(fileURLWithPath: "/usr/bin/printf")
        #expect(FileManager.default.isExecutableFile(atPath: sleep.path))
        #expect(FileManager.default.isExecutableFile(atPath: printf.path))

        let started = Date()
        let timedOut = CodexRolloutFile.runBounded(
            executable: sleep, arguments: ["5"],
            timeout: 0.2, maxOutputBytes: 1_024)
        #expect(timedOut == nil)
        #expect(Date().timeIntervalSince(started) < 5)

        // The cap and success legs test BYTE bounds, not deadlines — their
        // timeouts are deliberately generous so CI scheduler contention can't
        // starve a healthy printf past its deadline (a loaded runner turned the
        // exact-cap success into a spurious timeout at 2s once).
        let capped = CodexRolloutFile.runBounded(
            executable: printf, arguments: ["123456"],
            timeout: 10, maxOutputBytes: 5)
        #expect(capped == nil)
        let exact = CodexRolloutFile.runBounded(
            executable: printf, arguments: ["123456"],
            timeout: 10, maxOutputBytes: 6)
        #expect(exact == Data("123456".utf8))
    }

    @Test @MainActor
    func codexAttentionSignalsDriveWaitingRunningIdleAndNeverBlocked() async throws {
        let root = try codexTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let rollout = root.appendingPathComponent("rollout-attention.jsonl")
        let completedAt = "2026-07-10T10:05:00Z"
        let taskComplete = #"{"timestamp":"2026-07-10T10:05:00Z","type":"event_msg","payload":{"type":"task_complete","last_agent_message":"done"}}"#
        try writeRollout([codexMetadata(id: "attention"), taskComplete], to: rollout)
        let completedDate = try #require(parseDate(completedAt))
        let session = SessionSummary(
            id: "attention", provider: .codex,
            project: "p", cwd: "/tmp/p", model: "gpt-5.6-sol",
            lastActivity: completedDate, messageCount: 2,
            usage: SessionUsage(), contextWeight: 0, filePath: rollout.path)

        let store = AttentionStore()
        await store.refresh(candidates: [session])
        let signals = try #require(store.signals[session.id])
        #expect(signals.lastKind == .turnComplete)
        #expect(!signals.canObserveBlocking)
        let waiting = AttentionBoard.build(
            sessions: [session], signals: store.signals,
            now: completedDate.addingTimeInterval(60))
        #expect(waiting.items.first?.state == .waiting)
        #expect(waiting.blockedCount == 0)
        let idle = AttentionBoard.build(
            sessions: [session], signals: store.signals,
            now: completedDate.addingTimeInterval(AttentionState.idleThreshold + 1))
        #expect(idle.items.first?.state == .idle)

        let activity = #"{"timestamp":"2026-07-10T10:06:00Z","type":"response_item","payload":{"type":"function_call","name":"request_user_input"}}"#
        try writeRollout([codexMetadata(id: "attention"), taskComplete, activity], to: rollout)
        await store.refresh(candidates: [session])
        let runningSignals = try #require(store.signals[session.id])
        #expect(runningSignals.lastKind == .runtimeActivity)
        #expect(AttentionState.classify(
            runningSignals,
            now: try #require(parseDate("2026-07-10T10:06:31Z"))) == .running)
        #expect(AttentionState.classify(
            runningSignals,
            now: try #require(parseDate("2026-07-10T10:21:01Z"))) == .idle)
    }

    @Test func providerCorpusPresenceDetectsNoneClaudeCodexAndBoth() throws {
        let root = try codexTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let claude = root.appendingPathComponent("claude/projects", isDirectory: true)
        let codex = root.appendingPathComponent("codex/sessions", isDirectory: true)
        try FileManager.default.createDirectory(at: claude, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: codex, withIntermediateDirectories: true)
        let sources: [SessionSource] = [.claude(root: claude), .codex(root: codex)]

        try Data("{}\n".utf8).write(to: codex.appendingPathComponent("session_index.jsonl"))
        #expect(ProviderCorpusPresence.detect(sources: sources).isEmpty)

        let claudeFile = claude.appendingPathComponent("project/session.jsonl")
        try writeRollout([#"{"type":"user"}"#], to: claudeFile)
        #expect(ProviderCorpusPresence.detect(sources: sources).providers == [.claude])

        let codexFile = codex.appendingPathComponent(
            "2026/07/11/rollout-codex.jsonl.zst")
        try FileManager.default.createDirectory(
            at: codexFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data([0x00]).write(to: codexFile)
        #expect(ProviderCorpusPresence.detect(sources: sources).providers == [.claude, .codex])

        try FileManager.default.removeItem(at: claudeFile)
        #expect(ProviderCorpusPresence.detect(sources: sources).providers == [.codex])
    }

    @Test func noNetworkQuotaProviderReadsFreshestRolloutLimits() async throws {
        let root = try codexTempDirectory()
        defer { try? FileManager.default.removeItem(at: root) }
        let sessions = root.appendingPathComponent("sessions", isDirectory: true)
        let rollout = sessions.appendingPathComponent(
            "2026/07/10/rollout-quota.jsonl")
        let rateLine = #"{"timestamp":"2026-07-10T10:01:00Z","type":"event_msg","payload":{"type":"token_count","info":null,"rate_limits":{"primary":{"used_percent":37.5,"window_minutes":300,"resets_at":1783723793},"secondary":{"used_percent":62.25,"window_minutes":10080,"resets_at":1784310593},"credits":{"has_credits":true,"unlimited":false,"balance":"12.50"},"plan_type":"pro"}}}"#
        try writeRollout(
            [codexMetadata(id: "quota"), rateLine],
            to: rollout)
        let now = Date(timeIntervalSince1970: 1_783_700_000)
        let result = await CodexQuotaProvider(
            sessionsRoot: sessions, now: { now }).snapshot()
        let snapshot: QuotaSnapshot
        switch result {
        case .success(let value): snapshot = value
        case .failure(let error):
            Issue.record("unexpected quota failure: \(error)")
            return
        }
        #expect(snapshot.fetchedAt == now)
        #expect(snapshot.fiveHour?.title == "Session (5h)")
        #expect(snapshot.fiveHour?.usedPercent == 37.5)
        #expect(snapshot.fiveHour?.resetsAt == Date(timeIntervalSince1970: 1_783_723_793))
        #expect(snapshot.weekly?.title == "Weekly (all models)")
        #expect(snapshot.weekly?.usedPercent == 62.25)
        #expect(snapshot.scoped.isEmpty)
        #expect(snapshot.credits == QuotaCredits(
            hasCredits: true, unlimited: false, balance: "12.50"))
    }
}
