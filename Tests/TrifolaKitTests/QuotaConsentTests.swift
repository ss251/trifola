import Foundation
import Testing
@testable import TrifolaKit

private actor BlockingCodexQuotaProvider: QuotaProvider {
    nonisolated let provider: Provider = .codex
    private var started = false
    private var continuation: CheckedContinuation<Void, Never>?

    func snapshot() async -> Result<QuotaSnapshot, QuotaProviderFailure> {
        started = true
        await withCheckedContinuation { continuation = $0 }
        return .success(QuotaSnapshot(
            fiveHour: QuotaWindow(title: "Session (5h)", usedPercent: 42,
                                  resetsAt: nil),
            weekly: nil, scoped: [], fetchedAt: Date()))
    }

    func waitUntilStarted() async {
        while !started { await Task.yield() }
    }

    func release() {
        continuation?.resume()
        continuation = nil
    }
}

@Suite("Quota consent boundary")
@MainActor
struct QuotaConsentTests {
    @Test func bothProvidersRemainOffByDefault() async {
        let store = QuotaStore(
            refreshCoordinator: ProviderRefreshCoordinator(),
            configDirectory: URL(fileURLWithPath: "/unreadable-claude-root"),
            codexProvider: CodexQuotaProvider(
                sessionsRoot: URL(fileURLWithPath: "/unreadable-codex-root")))

        await store.refresh(consent: QuotaConsent(), minInterval: 0)

        #expect(store.snapshots.isEmpty)
        #expect(store.statuses[.claude] == "access off")
        #expect(store.statuses[.codex] == "access off")
    }

    @Test func codexConsentReadsOnlyLocalRolloutLimits() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("trifola-quota-consent-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rollout = root.appendingPathComponent(
            "2026/07/11/rollout-local.jsonl")
        try FileManager.default.createDirectory(
            at: rollout.deletingLastPathComponent(), withIntermediateDirectories: true)
        let line = #"{"timestamp":"2026-07-11T10:01:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":25,"window_minutes":300},"secondary":{"used_percent":50,"window_minutes":10080},"credits":{"has_credits":true,"unlimited":false,"balance":"8.75"}}}}"#
        try Data((line + "\n").utf8).write(to: rollout)

        let store = QuotaStore(
            refreshCoordinator: ProviderRefreshCoordinator(),
            configDirectory: URL(fileURLWithPath: "/must-not-read-claude"),
            codexProvider: CodexQuotaProvider(sessionsRoot: root))
        await store.refresh(
            consent: QuotaConsent(claude: false, codex: true),
            minInterval: 0)

        #expect(store.snapshots[.claude] == nil)
        #expect(store.snapshots[.codex]?.fiveHour?.usedPercent == 25)
        #expect(store.snapshots[.codex]?.weekly?.usedPercent == 50)
        #expect(store.snapshots[.codex]?.credits?.balance == "8.75")
        #expect(store.statuses[.claude] == "access off")
        #expect(store.statuses[.codex] == "ok · local rollouts")
    }

    @Test func disablingProviderClearsItsSnapshot() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("trifola-quota-clear-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rollout = root.appendingPathComponent("rollout-local.jsonl")
        let line = #"{"type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":10,"window_minutes":300}}}}"#
        try FileManager.default.createDirectory(
            at: root, withIntermediateDirectories: true)
        try Data((line + "\n").utf8).write(to: rollout)
        let store = QuotaStore(
            refreshCoordinator: ProviderRefreshCoordinator(),
            codexProvider: CodexQuotaProvider(sessionsRoot: root))

        await store.refresh(consent: QuotaConsent(codex: true), minInterval: 0)
        #expect(store.snapshots[.codex] != nil)
        await store.refresh(consent: QuotaConsent(), minInterval: 0)
        #expect(store.snapshots[.codex] == nil)
        #expect(store.statuses[.codex] == "access off")
    }

    @Test func revokingConsentDuringRefreshDiscardsLateSnapshot() async {
        let provider = BlockingCodexQuotaProvider()
        let store = QuotaStore(
            refreshCoordinator: ProviderRefreshCoordinator(),
            codexProvider: provider)

        let authorizedRefresh = Task {
            await store.refresh(
                consent: QuotaConsent(codex: true), minInterval: 0)
        }
        await provider.waitUntilStarted()

        await store.refresh(consent: QuotaConsent(), minInterval: 0)
        await provider.release()
        await authorizedRefresh.value

        #expect(store.snapshots[.codex] == nil)
        #expect(store.statuses[.codex] == "access off")
    }
}
