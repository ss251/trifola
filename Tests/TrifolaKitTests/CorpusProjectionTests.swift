import Foundation
import Testing
@testable import TrifolaKit

@Suite("Corpus projection")
struct CorpusProjectionTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func session(
        _ id: String,
        provider: Provider = .claude,
        project: String,
        model: String = "claude-opus-4-8",
        age: TimeInterval? = 60,
        usage: SessionUsage,
        context: Int = 0,
        subagent: Bool = false,
        usageDay: String? = nil,
        machine: String = "local"
    ) -> SessionSummary {
        let dayUsage = usageDay.map { [$0: [model: usage]] } ?? [:]
        let tier = ModelTier(raw: model)
        let path = subagent
            ? "/tmp/\(project)/subagents/agent-\(id).jsonl"
            : "/tmp/\(project)/\(id).jsonl"
        return SessionSummary(
            id: id,
            provider: provider,
            project: project,
            cwd: "/tmp/\(project)",
            model: model,
            lastActivity: age.map { now.addingTimeInterval(-$0) },
            messageCount: 1,
            usage: usage,
            contextWeight: context,
            filePath: path,
            usageByTier: [tier: usage],
            usageByDay: usageDay.map { [$0: [tier: usage]] } ?? [:],
            usageByModel: [model: usage],
            usageByModelDay: dayUsage,
            machineID: machine)
    }

    @Test func detachedBuildCarriesTotalsProviderModelsAndHistogram() async {
        let claudeUsage = SessionUsage(
            inputTokens: 100_000,
            outputTokens: 20_000,
            cacheReadTokens: 300_000)
        let codexUsage = SessionUsage(
            inputTokens: 200_000,
            outputTokens: 40_000,
            cacheReadTokens: 100_000)
        let grokUsage = SessionUsage(
            inputTokens: 50_000,
            outputTokens: 10_000,
            cacheReadTokens: 75_000)
        let sharedModel = "gpt-5.6-sol"
        let sessions = [
            session("claude", provider: .claude, project: "one",
                    model: sharedModel, age: 30, usage: claudeUsage,
                    usageDay: "2027-01-15"),
            session("codex", provider: .codex, project: "two",
                    model: sharedModel, age: 3_700, usage: codexUsage,
                    usageDay: "2027-01-15"),
            session("grok", provider: .grok, project: "three",
                    model: sharedModel, age: 7_300, usage: grokUsage,
                    usageDay: "2027-01-15"),
        ]

        // The public value is intentionally constructible outside the main
        // actor; only publication into SwiftUI state needs to hop back.
        let projection = await Task.detached {
            CorpusProjection(sessions: sessions, now: now)
        }.value

        #expect(projection.totalUsage == claudeUsage + codexUsage + grokUsage)
        #expect(abs(projection.totalCost - sessions.reduce(0) { $0 + $1.cost }) < 1e-12)
        #expect(abs(projection.totalCacheSavings
                    - sessions.reduce(0) { $0 + $1.cacheSavingsDollars }) < 1e-12)
        #expect(projection.distinctProjectCount == 3)
        #expect(projection.topModelsByID.count == 3)
        #expect(Set(projection.topModelsByID.map(\.provider)) == Set(Provider.allCases))
        #expect(projection.topModelsByID.allSatisfy { $0.model == sharedModel })
        #expect(projection.activityHistogram24h.count == 24)
        #expect(projection.activityHistogram24h[23] == 1)
        #expect(projection.activityHistogram24h[22] == 1)
        #expect(projection.activityHistogram24h.reduce(0, +) == 3)
    }

    @Test func activeContextAndProjectRowsHaveTotalStableOrdering() {
        let oneDollar = SessionUsage(inputTokens: 200_000)
        let twoDollars = SessionUsage(inputTokens: 400_000)
        let sessions = [
            session("b", project: "beta", age: 20, usage: oneDollar,
                    context: 310_000),
            session("a", project: "alpha", age: 20, usage: oneDollar,
                    context: 310_000),
            session("c", project: "gamma", age: 300, usage: twoDollars,
                    context: 250_000),
            session("idle", project: "gamma", age: 1_800, usage: twoDollars,
                    context: 100_000),
            session("agent", project: "agents", age: 10, usage: twoDollars,
                    context: 900_000, subagent: true),
        ]

        let projection = CorpusProjection(sessions: sessions, now: now)

        #expect(projection.activeSessions.map(\.id) == ["agent", "a", "b", "c"])
        #expect(projection.contextHeavy.map(\.id) == ["a", "b", "c"])
        #expect(projection.topContextRows.map(\.id) == ["a", "b", "c"])
        #expect(projection.usesContextFallback == false)
        #expect(projection.projectSpend.map(\.project)
                == ["gamma", "agents", "alpha", "beta"])
        #expect(projection.projectSpend.first?.sessions == 2)
    }

    @Test func contextRowsFallBackToHeaviestRealSessionsAndHonorLimit() {
        let usage = SessionUsage(inputTokens: 10_000)
        let sessions = [
            session("low", project: "p", age: 1, usage: usage, context: 20_000),
            session("high-old", project: "p", age: 90, usage: usage, context: 90_000),
            session("high-new", project: "p", age: 10, usage: usage, context: 90_000),
            session("agent", project: "p", age: 1, usage: usage,
                    context: 999_000, subagent: true),
        ]

        let projection = CorpusProjection(
            sessions: sessions,
            now: now,
            contextRowLimit: 2)

        #expect(projection.contextHeavy.isEmpty)
        #expect(projection.usesContextFallback)
        #expect(projection.topContextRows.map(\.id) == ["high-new", "high-old"])
    }

    @Test func inputPermutationProducesIdenticalProjection() {
        let sessions = [
            session("z", provider: .codex, project: "same", model: "gpt-5.6-sol",
                    age: 45, usage: SessionUsage(inputTokens: 300_000),
                    context: 280_000, usageDay: "2027-01-15"),
            session("a", project: "same", model: "claude-sonnet-4-6",
                    age: 45, usage: SessionUsage(outputTokens: 100_000),
                    context: 280_000, usageDay: "2027-01-15"),
            session("m", project: "other", age: 3_650,
                    usage: SessionUsage(cacheReadTokens: 500_000),
                    context: 50_000),
        ]

        let forward = CorpusProjection(sessions: sessions, now: now)
        let reversed = CorpusProjection(sessions: Array(sessions.reversed()), now: now)

        #expect(forward.totalUsage == reversed.totalUsage)
        #expect(forward.totalCost == reversed.totalCost)
        #expect(forward.totalCacheSavings == reversed.totalCacheSavings)
        #expect(forward.activeSessions == reversed.activeSessions)
        #expect(forward.topModelsByID == reversed.topModelsByID)
        #expect(forward.projectSpend == reversed.projectSpend)
        #expect(forward.burnGovernor == reversed.burnGovernor)
        #expect(forward.rerouteReport.totalSilent
                == reversed.rerouteReport.totalSilent)
        #expect(forward.rerouteReport.totalUserSwitches
                == reversed.rerouteReport.totalUserSwitches)
        #expect(forward.orchestratorHog == reversed.orchestratorHog)
        #expect(forward.contextHeavy == reversed.contextHeavy)
        #expect(forward.topContextRows == reversed.topContextRows)
        #expect(forward.activityHistogram24h == reversed.activityHistogram24h)
        #expect(forward.tierStats.map { ($0.tier.rawValue, $0.tokens, $0.cost, $0.sessions) }
                .map(String.init(describing:))
                == reversed.tierStats.map {
                    ($0.tier.rawValue, $0.tokens, $0.cost, $0.sessions)
                }.map(String.init(describing:)))
    }

    @Test func heartbeatRefreshMovesOnlyRollingActivityFields() {
        let usage = SessionUsage(inputTokens: 50_000, outputTokens: 4_000)
        let sessions = [
            session("fresh", project: "one", age: 30, usage: usage),
            session("old", project: "two", age: 3_700, usage: usage),
        ]
        let initial = CorpusProjection(sessions: sessions, now: now)
        let later = initial.refreshingActivity(
            sessions: sessions,
            now: now.addingTimeInterval(1_000))

        #expect(initial.activeSessions.map(\.id) == ["fresh"])
        #expect(later.activeSessions.isEmpty)
        #expect(later.activityHistogram24h.count == 24)
        #expect(later.totalUsage == initial.totalUsage)
        #expect(later.totalCost == initial.totalCost)
        #expect(later.totalCacheSavings == initial.totalCacheSavings)
        #expect(later.topModelsByID == initial.topModelsByID)
        #expect(later.projectSpend == initial.projectSpend)
        #expect(later.burnGovernor == initial.burnGovernor)
        #expect(later.contextHeavy == initial.contextHeavy)
        #expect(later.topContextRows == initial.topContextRows)
    }
}
