import Foundation
import Testing
@testable import TrifolaKit

// Spree #2 — REROUTE RECEIPTS + ORCHESTRATOR-HOG ALERT.
// These tests pin the honest-semantics contract (silent flip = mid-conversation
// model change with NO /model command between turns; deliberate switches are
// listed, NEVER counted), the trend aggregation (per-day, per-pair, undated
// flips dropped honestly rather than smeared), the hog threshold edge
// (exactly 80% is at the bar, not over it — strictly greater-than, matching
// isContextHeavy), and the single-pricing-path contract (alert numbers come
// from cost(onDay:) — the same machinery every other surface prints).

private func flip(_ from: String, _ to: String, day: String = "2026-07-07",
                  msg: String? = "msg_x", user: Bool = false,
                  ts: Date? = Date(timeIntervalSince1970: 1_780_000_000)) -> ModelFlip {
    ModelFlip(fromModel: from, toModel: to, timestamp: ts, day: day,
              messageID: msg, userInitiated: user)
}

private func sess(_ id: String, model: String? = "claude-ghost-5",
                  flips: [ModelFlip] = [],
                  turns: [String: Int] = ["claude-ghost-5": 10],
                  subagent: Bool = false) -> SessionSummary {
    let path = subagent ? "/x/p/s/subagents/agent-\(id).jsonl" : "/x/p/\(id).jsonl"
    return SessionSummary(id: id, project: "p", cwd: "/x/p", model: model,
                          lastActivity: Date(), messageCount: 20,
                          usage: SessionUsage(inputTokens: 100_000),
                          contextWeight: 0, filePath: path,
                          assistantTurnsByModel: turns, modelFlips: flips)
}

private func costSess(_ id: String, day: String, input: Int, output: Int = 0,
                      model: String = "claude-opus-4-8",
                      subagent: Bool = false) -> SessionSummary {
    let u = SessionUsage(inputTokens: input, outputTokens: output)
    let path = subagent ? "/x/p/s/subagents/agent-\(id).jsonl" : "/x/p/\(id).jsonl"
    return SessionSummary(id: id, project: "p", cwd: "/x/p", model: model,
                          lastActivity: Date(), messageCount: 20, usage: u,
                          contextWeight: 0, filePath: path,
                          usageByModelDay: [day: [model: u]])
}

@Suite("Reroute receipts — honest semantics")
struct RerouteReceiptTests {

    @Test func cleanSessionHasNoReceiptAtAll() {
        // Zero flips → nil receipt (nothing renders), and the fleet report
        // still censuses the session without inventing a row for it.
        #expect(Reroutes.receipt(for: sess("clean")) == nil)
        let report = Reroutes.build(sessions: [sess("clean")])
        #expect(report.receipts.isEmpty)
        #expect(report.totalSilent == 0)
        #expect(report.days.isEmpty)
        #expect(report.sessionsCensused == 1)
    }

    @Test func silentRerouteIsCountedWithItsEvidence() {
        let f = flip("claude-ghost-5", "claude-opus-4-8", msg: "msg_01Xq7fRw2Kd9")
        let r = Reroutes.receipt(for: sess("s", flips: [f],
                                           turns: ["claude-ghost-5": 8, "claude-opus-4-8": 2]))!
        #expect(r.silentFlips.count == 1)
        #expect(r.userSwitches == 0)
        #expect(r.silentFlips[0].messageID == "msg_01Xq7fRw2Kd9")   // the message ref survives
        #expect(r.silentFlips[0].pair == "claude-ghost-5 → claude-opus-4-8")
        #expect(r.totalTurns == 10)                                  // honest denominator
    }

    @Test func userInitiatedModelSwitchIsListedButNeverCounted() {
        let deliberate = flip("claude-ghost-5", "claude-sonnet-5", user: true)
        let r = Reroutes.receipt(for: sess("s", flips: [deliberate]))!
        #expect(r.silentFlips.isEmpty)
        #expect(r.userSwitches == 1)
        // A switch-only session contributes NOTHING to the trend.
        let report = Reroutes.build(sessions: [sess("s", flips: [deliberate])])
        #expect(report.totalSilent == 0)
        #expect(report.receipts.isEmpty)          // no silent flips → no receipt row
        #expect(report.totalUserSwitches == 1)    // …but the exclusion is on the record
    }

    @Test func fallbackChainGroupsByPairAndDay() {
        // The Jul 1 shape: an opus→haiku fallback the day before, then the
        // opus→sonnet fallback repeated the next day — pair counts must group.
        let chain = [
            flip("claude-opus-4-8", "claude-haiku-4-5", day: "2026-07-01"),
            flip("claude-opus-4-8", "claude-sonnet-5", day: "2026-07-02"),
            flip("claude-opus-4-8", "claude-sonnet-5", day: "2026-07-02"),
        ]
        let report = Reroutes.build(sessions: [sess("s", flips: chain)])
        #expect(report.totalSilent == 3)
        #expect(report.days.map(\.day) == ["2026-07-01", "2026-07-02"])
        #expect(report.days[1].count == 2)
        #expect(report.pairs.first?.pair == "claude-opus-4-8 → claude-sonnet-5")
        #expect(report.pairs.first?.count == 2)
        // Direction semantics pin the declared capability order
        // (opus > sonnet > haiku): both hops here are downshifts,
        // and the reverse hop is the classifier-intercept upshift.
        #expect(chain[0].direction == .downshift)
        #expect(chain[1].direction == .downshift)
        #expect(flip("claude-sonnet-5", "claude-opus-4-8").direction == .upshift)
        #expect(flip("claude-opus-4-8", "claude-opus-4-8").direction == .lateral)
    }

    @Test func undatedFlipsAreDroppedHonestlyNotSmeared() {
        let dated = flip("claude-ghost-5", "claude-opus-4-8", day: "2026-07-07")
        let undated = flip("claude-ghost-5", "claude-opus-4-8", day: "", ts: nil)
        let report = Reroutes.build(sessions: [sess("s", flips: [dated, undated])])
        #expect(report.totalSilent == 2)                        // both are real reroutes
        #expect(report.days.reduce(0) { $0 + $1.count } == 1)   // only one has a day
        #expect(report.undatedSilent == 1)                      // the drop is on the record
    }

    @Test func semanticsStringAdmitsWhatTheTranscriptCannotKnow() {
        // The receipt copy must carry the mechanical definition and the
        // exclusion — this string is UI-load-bearing (printed in selfcheck).
        #expect(RerouteReport.semantics.contains("/model"))
        #expect(RerouteReport.semantics.contains("never counted"))
    }

    @Test func trendStepsCalendarDaysNotFixedSecondsAcrossDST() {
        // Plan 08: fixed-86400s stepping drifts the wall clock ±1h across a
        // DST transition, producing a duplicated day-key and a skipped one.
        // Calendar day-stepping must always yield `window` unique local keys —
        // pin this both at a real US DST boundary (2026-03-08, spring-forward)
        // and as a timezone-independent invariant.
        let report = RerouteReport.empty
        var dstComponents = DateComponents()
        dstComponents.year = 2026; dstComponents.month = 3; dstComponents.day = 10
        dstComponents.hour = 12
        let dstNow = Calendar.current.date(from: dstComponents)!
        let dstResult = report.trend(window: 14, now: dstNow)
        #expect(dstResult.count == 14)
        #expect(Set(dstResult.map(\.day)).count == 14)   // no duplicate/skipped day

        // Timezone-independent invariant, whatever `now` happens to be.
        let result = report.trend(window: 14, now: Date())
        #expect(result.count == 14)
        #expect(Set(result.map(\.day)).count == 14)
    }

    @Test func trendPlacesAFlipInTheRightSlotAcrossTheWindow() {
        // A flip whose `day` falls inside the window appears with its count
        // at the right slot, and days without flips are honest zeros.
        var dstComponents = DateComponents()
        dstComponents.year = 2026; dstComponents.month = 3; dstComponents.day = 10
        dstComponents.hour = 12
        let now = Calendar.current.date(from: dstComponents)!
        let f = flip("claude-ghost-5", "claude-opus-4-8", day: "2026-03-09")
        let report = Reroutes.build(sessions: [sess("s", flips: [f])])
        let result = report.trend(window: 14, now: now)
        #expect(result.first(where: { $0.day == "2026-03-09" })?.count == 1)
        #expect(result.filter { $0.day != "2026-03-09" }.allSatisfy { $0.count == 0 })
    }

    @Test func trendDoesNotTrapOnDuplicateDayKeysInDays() {
        // CORRECTNESS-03 (Reroutes.swift:168): the internal `byDay` lookup
        // used `Dictionary(uniqueKeysWithValues:)`, which traps on a
        // duplicate day-key. `days` is always producer-unique today, but a
        // RerouteReport built by hand (or a future/decode caller) could
        // carry two RerouteDays sharing a `day` — trend() must collapse
        // rather than crash.
        let dupDays = [
            RerouteDay(day: "2026-07-05", count: 3, byPair: [:]),
            RerouteDay(day: "2026-07-05", count: 7, byPair: [:]),
        ]
        let report = RerouteReport(receipts: [], days: dupDays, pairs: [],
                                   totalSilent: 10, undatedSilent: 0,
                                   totalUserSwitches: 0, sessionsCensused: 0)
        var comps = DateComponents()
        comps.year = 2026; comps.month = 7; comps.day = 10; comps.hour = 12
        let now = Calendar.current.date(from: comps)!
        let result = report.trend(window: 14, now: now)   // must not trap
        #expect(result.count == 14)
        #expect(result.first(where: { $0.day == "2026-07-05" }) != nil)
    }
}

@Suite("Orchestrator-hog alert — threshold + single pricing path")
struct OrchestratorHogTests {
    let day = "2026-07-07"

    @Test func firesAboveThresholdAndNamesTheSession() {
        // ~$422 of ~$469 (the simonw shape) — well above 80% of a ≥$20 day.
        let hog = costSess("main", day: day, input: 28_000_000)      // opus-4-8 $5/M in
        let side = costSess("sub", day: day, input: 1_000_000, model: "claude-sonnet-5")
        let alert = OrchestratorHog.alert(sessions: [hog, side], day: day)
        #expect(alert != nil)
        #expect(alert?.sessionID == "main")
        #expect(alert?.line.contains("delegate more to cheaper subagents") == true)
    }

    @Test func exactlyEightyPercentDoesNotFire() {
        // The house rule: strictly greater-than. Construct an exact 80/20
        // split from identical rate paths: 8M vs 2M input on the same model.
        let a = costSess("a", day: day, input: 8_000_000)
        let b = costSess("b", day: day, input: 2_000_000)
        let alert = OrchestratorHog.alert(sessions: [a, b], day: day)
        let shareA = a.cost(onDay: day) / (a.cost(onDay: day) + b.cost(onDay: day))
        #expect(abs(shareA - 0.80) < 1e-9)   // fixture really is at the bar
        #expect(alert == nil)                // at the bar, not over it
        // One token over the bar fires.
        let a2 = costSess("a", day: day, input: 8_000_100)
        #expect(OrchestratorHog.alert(sessions: [a2, b], day: day) != nil)
    }

    @Test func quietDaysNeverAlert() {
        // 100% share of a sub-$20 day is not advice-worthy.
        let solo = costSess("solo", day: day, input: 3_000_000)   // $15 < $20 floor
        #expect(solo.cost(onDay: day) < OrchestratorHog.minimumDayTotal)
        #expect(OrchestratorHog.alert(sessions: [solo], day: day) == nil)
    }

    @Test func subagentsCannotBeTheHogButCountInTheDenominator() {
        // The subagent outspends everyone — but it IS the delegation, so the
        // top-level session is the only hog candidate, and here it's under
        // threshold once the subagent's spend joins the denominator.
        let sub = costSess("big-sub", day: day, input: 20_000_000, subagent: true)
        let main = costSess("main", day: day, input: 4_000_000)
        let alert = OrchestratorHog.alert(sessions: [sub, main], day: day)
        #expect(alert == nil)
        // Remove the subagent spend and main is 100% of a $20 day — fires,
        // and the hog named is never the subagent even when it costs more.
        let alert2 = OrchestratorHog.alert(sessions: [main], day: day)
        #expect(alert2?.sessionID == "main")
    }

    @Test func alertNumbersComeFromTheOneTrueCostPath() {
        // Consistency contract (the ContextTax rule): sessionCost and dayTotal
        // must equal cost(onDay:) sums exactly — no second pricing path.
        let hog = costSess("main", day: day, input: 28_000_000, output: 500_000)
        let side = costSess("sub", day: day, input: 1_000_000, model: "claude-sonnet-5")
        let alert = OrchestratorHog.alert(sessions: [hog, side], day: day)!
        #expect(alert.sessionCost == hog.cost(onDay: day))
        #expect(alert.dayTotal == hog.cost(onDay: day) + side.cost(onDay: day))
        #expect(abs(alert.share - alert.sessionCost / alert.dayTotal) < 1e-12)
    }
}
