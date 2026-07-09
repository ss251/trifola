import Foundation
import Testing
@testable import TrifolaKit

// Plan 07 — "today's spend" agrees across every surface (fix synthetic-session
// drift). `BurnGovernor` already had an inline fallback for summaries built
// without per-message data (synthetic/pre-W2 cache entries): attribute the
// whole session cost to `lastActivity`'s LOCAL day. `cost(onDay:)` — the
// shared accessor three other surfaces (menu-bar tray, hog alert, MCP
// `cost_today`) drive off — lacked it and silently returned 0 for those
// sessions. These tests pin the fix at all three surfaces it reaches.

/// A "synthetic" summary: no `usageByModelDay`, no `usageByDay`, no
/// `usageByTier` — the pre-W2 shape. `cost` still resolves (via the
/// single-tier `perTierUsage` fallback), but there is no per-day breakdown
/// at all, so every day-scoped accessor must fall back to `lastActivity`.
private func syntheticSession(_ id: String, lastActivity: Date,
                              model: String = "claude-opus-4-8",
                              input: Int = 4_000_000, output: Int = 200_000,
                              subagent: Bool = false) -> SessionSummary {
    let path = subagent ? "/x/p/s/subagents/agent-\(id).jsonl" : "/x/p/\(id).jsonl"
    return SessionSummary(id: id, project: "p", cwd: "/x/p", model: model,
                          lastActivity: lastActivity, messageCount: 20,
                          usage: SessionUsage(inputTokens: input, outputTokens: output),
                          contextWeight: 0, filePath: path)
}

/// A normal, per-message-priced summary: `usageByModelDay` carries the day's
/// real (model, day) slice — the modern shape every other fixture in this
/// suite is contrasted against.
private func normalSession(_ id: String, lastActivity: Date, day: String,
                           input: Int, output: Int = 0,
                           model: String = "claude-sonnet-5") -> SessionSummary {
    let u = SessionUsage(inputTokens: input, outputTokens: output)
    return SessionSummary(id: id, project: "p", cwd: "/x/p", model: model,
                          lastActivity: lastActivity, messageCount: 20, usage: u,
                          contextWeight: 0, filePath: "/x/p/\(id).jsonl",
                          usageByModelDay: [day: [model: u]])
}

@Suite("Today's spend — synthetic sessions agree across every surface")
struct CostByDayTests {

    @Test func costOnDayAttributesWholeCostToLastActivityDay() {
        let now = Date()
        let day = localDayKey(now)
        let s = syntheticSession("solo", lastActivity: now)
        #expect(s.usageByModelDay.isEmpty)
        #expect(s.usageByDay.isEmpty)
        #expect(s.cost > 0)                          // fallback tier pricing gives a real number
        #expect(s.cost(onDay: day) == s.cost)         // NOT 0 — the bug this plan fixes
        #expect(s.cost(onDay: "1999-01-01") == 0)     // only ITS day, never leaks onto another
    }

    @Test func hogAlertDayTotalIncludesSyntheticSessions() {
        // A single synthetic session, alone, is 100% of a well-above-$20 day —
        // the hog alert must fire, and its dayTotal must count the session
        // (would be $0 pre-fix, since dayTotal sums via `cost(onDay:)`).
        let now = Date()
        let day = localDayKey(now)
        let hog = syntheticSession("hog", lastActivity: now, input: 28_000_000)
        let alert = OrchestratorHog.alert(sessions: [hog], day: day)
        #expect(alert != nil)
        #expect(alert?.sessionID == "hog")
        #expect(alert?.dayTotal == hog.cost(onDay: day))
        #expect((alert?.dayTotal ?? 0) >= OrchestratorHog.minimumDayTotal)
    }

    @Test func mcpCostTodayTotalMatchesBurnGovernor() {
        // Mixed corpus: one normal (per-model-day priced) session + one
        // synthetic (whole-session, lastActivity-bucketed) session, both
        // active today. MCP `cost_today`'s total must equal what the
        // Overview/sidebar burn tile shows for the same day — the whole
        // point of this plan.
        let now = Date()
        let day = localDayKey(now)
        let normal = normalSession("normal", lastActivity: now, day: day, input: 2_000_000)
        let synthetic = syntheticSession("synthetic", lastActivity: now, input: 1_000_000, output: 50_000)
        let sessions = [normal, synthetic]
        let srv = MCPIntrospectionServer(sessions: { sessions }, quota: { .unavailable("test") },
                                         now: { now })
        let json = srv.costToday(sessions)
        let total = json["total_usd"] as? Double
        let expected = BurnGovernor(sessions: sessions, now: now).today.cost
        #expect(total != nil)
        #expect(abs((total ?? -1) - expected) < 0.001)
        // The synthetic contribution is visible, not silently merged into an
        // existing model row (it has no model split to attribute it to).
        let rows = json["by_model"] as? [[String: Any]]
        #expect(rows?.contains { ($0["model"] as? String) == "(pre-upgrade)" } == true)
    }
}
