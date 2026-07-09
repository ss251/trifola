import Foundation
import Testing
@testable import TrifolaKit

// The Deadline Board is a JOIN no other tool can compute, so test its three pure
// halves hard: the deterministic PARSER (fixture MEMORY.md/NOTES.md text →
// extracted (project, date, sourceLine, raw)), the JEOPARDY metric (idle ÷ runway),
// and the five-state CLASSIFIER — plus the operative-deadline picker (the "finale
// attached to the submission" trap), the .toml override, the merge precedence, the
// app-owned write boundary, and the board sort.

private let utc: Calendar = {
    var c = Calendar(identifier: .gregorian)
    c.timeZone = TimeZone(identifier: "UTC")!
    return c
}()
private func day(_ y: Int, _ mo: Int, _ d: Int, _ hh: Int = 23, _ mm: Int = 59) -> Date {
    utc.date(from: DateComponents(year: y, month: mo, day: d, hour: hh, minute: mm, second: 0))!
}
private let now0 = day(2026, 7, 6, 12, 0)   // fixed clock: Jul 6 2026, noon UTC

// A trimmed but faithful slice of the real MEMORY.md Active Projects index — the
// index lines carry a ~/Developer/<name>/ path that anchors the project.
private let memoryFixture = """
## Active Projects
- [OSS Plugin Challenge](project_alpha_hackathon.md) — deadline Jul 13 2026; build = **Widgets**. `~/Developer/alpha-hackathon/`
- [OSS Sprint hackathon — Webapp](project_webapp_hackathon.md) — Webapp BUILT+LIVE; submission Jul 19, finale Jul 30; state ~/Developer/webapp/NOTES.md
- [DevPost Challenge — Api-Gateway](project_api_gateway.md) — orchestrator hiring agents; Submit before Jul 17. `~/Developer/api-gateway/`
- [Quarterly budget review](project_ops_review.md) — cost dashboard; gates Jul 12 / Aug 11 / Sep 10; ~/Developer/ops-review/
- [Protocol audit bounty](project_security_audit.md) — audit done, coverage monitor armed; ~/Developer/security-audit/
"""

// MARK: - Parser

@Suite("Deadline parser")
struct DeadlineParserTests {

    @Test func parsesExplicitYearDateWithProjectAndProvenance() {
        let parsed = DeadlineParser.parse(text: memoryFixture, file: "MEMORY.md", now: now0, calendar: utc)
        let slack = parsed.first { $0.projectKey == "alpha-hackathon" }
        #expect(slack != nil)
        #expect(slack?.date == day(2026, 7, 13))                 // Jul 13 2026, default 23:59
        #expect(slack?.source.raw.contains("Jul 13 2026") == true)   // verbatim on disk
        #expect(slack?.source.line == 2)                          // 1-based source line
        #expect(slack?.source.file == "MEMORY.md")
        #expect(slack?.source.confirmed == false)                // a finding, not a verdict
        #expect(slack?.kind == .hackathon)
    }

    @Test func inferMissingYearAsNextOccurrence() {
        let parsed = DeadlineParser.parse(text: memoryFixture, file: "MEMORY.md", now: now0, calendar: utc)
        let apiGateway = parsed.first { $0.projectKey == "api-gateway" }
        #expect(apiGateway?.date == day(2026, 7, 17))   // "Submit before Jul 17" → 2026 (ref year)
    }

    @Test func nextYearWhenMonthDayAlreadyPassed() {
        // "Jan 5" parsed on Jul 6 2026 → the NEXT Jan 5 (2027).
        let text = "the review is due Jan 5 for ~/Developer/foo/"
        let parsed = DeadlineParser.parse(text: text, file: "x.md", now: now0, calendar: utc)
        #expect(parsed.first?.date == day(2027, 1, 5))
    }

    @Test func attachesClockTimeAndUTCZone() {
        let text = "- api-gateway submission Jul 17 2026 23:59 UTC ~/Developer/api-gateway/"
        let parsed = DeadlineParser.parse(text: text, file: "x.md", now: now0, calendar: utc)
        #expect(parsed.first?.date == day(2026, 7, 17, 23, 59))
    }

    @Test func parsesISOInstantWithOffset() {
        let text = "deadline = 2026-07-13T23:59:00-07:00 for ~/Developer/alpha-hackathon/"
        let parsed = DeadlineParser.parse(text: text, file: "x.toml", now: now0, calendar: utc)
        // -07:00 → 2026-07-14T06:59:00Z (the honest instant, offset respected).
        #expect(parsed.first?.date == utc.date(from: DateComponents(year: 2026, month: 7, day: 14, hour: 6, minute: 59, second: 0)))
    }

    @Test func mapsByProjectHintWhenNoPathPresent() {
        let text = "- beta-hackathon submission closes Aug 10 2026"
        let parsed = DeadlineParser.parse(text: text, file: "x.md",
                                          projectHints: ["beta-hackathon", "webapp"], now: now0, calendar: utc)
        #expect(parsed.first?.projectKey == "beta-hackathon")
        #expect(parsed.first?.date == day(2026, 8, 10))
    }

    @Test func projectHintsMatchOnTokenBoundariesOnly() {
        // THE field false positive: MEMORY.md's "both .jsonl deleted by Jul 6 cleanup"
        // sits on a line saying "Hackathon session IDs (transcripts deleted)" — the
        // context gate passes on "Hackathon", the date parses, and the hint "scripts"
        // used to SUBSTRING-match inside "tranSCRIPTS", minting a phantom project that
        // topped the jeopardy sort. Token-boundary matching kills it.
        let line = "- [Hackathon session IDs (transcripts deleted)] — both .jsonl deleted by Jul 6 cleanup, NOT resumable"
        let parsed = DeadlineParser.parse(text: line, file: "MEMORY.md",
                                          projectHints: ["scripts"], now: now0, calendar: utc)
        // The date+context still parse (the line does say "Hackathon … by Jul 6"), but
        // with token-boundary hints no project claims it — and a keyless finding never
        // reaches the board: operativeDeadlines drops it.
        #expect(parsed.allSatisfy { $0.projectKey == nil })
        #expect(DeadlineParser.operativeDeadlines(parsed, now: now0).isEmpty)

        // …while `_` / `-` / `/` still count as boundaries, so real references keep matching.
        #expect(DeadlineParser.containsToken("see project_parser-lib_bounty.md", "parser-lib"))
        #expect(DeadlineParser.containsToken("~/developer/webapp/notes_file.md", "webapp"))
        #expect(DeadlineParser.containsToken("alpha-hackathon deadline", "alpha-hackathon"))
        #expect(!DeadlineParser.containsToken("transcripts deleted", "scripts"))
        #expect(!DeadlineParser.containsToken("scripted cleanup", "script"))
    }

    @Test func perFileDefaultProjectForNotesFile() {
        let text = "## STATUS\nSubmit before Jul 17 23:59 UTC.\n"
        let parsed = DeadlineParser.parse(text: text, file: "api-gateway/NOTES.md",
                                          defaultProject: "api-gateway", now: now0, calendar: utc)
        #expect(parsed.first?.projectKey == "api-gateway")
    }

    @Test func operativePicksSubmissionOverFinale() {
        // "submission Jul 19, finale Jul 30" → operative must be Jul 19, not Jul 30.
        let parsed = DeadlineParser.parse(text: memoryFixture, file: "MEMORY.md", now: now0, calendar: utc)
        let operative = DeadlineParser.operativeDeadlines(parsed, now: now0)
        #expect(operative["webapp"]?.date == day(2026, 7, 19))
        #expect(operative["webapp"]?.label == "submission")
    }

    @Test func operativePicksEarliestFutureGate() {
        // "gates Jul 12 / Aug 11 / Sep 10" → the next gate (Jul 12).
        let parsed = DeadlineParser.parse(text: memoryFixture, file: "MEMORY.md", now: now0, calendar: utc)
        let operative = DeadlineParser.operativeDeadlines(parsed, now: now0)
        #expect(operative["ops-review"]?.date == day(2026, 7, 12))
        #expect(operative["ops-review"]?.kind == .gate)
    }

    @Test func bountyAndAuditKindsInferred() {
        let bounty = "- Parser Lib bounty — 1k bug bounty closes Aug 15 2026 ~/Developer/parser-lib/"
        #expect(DeadlineParser.parse(text: bounty, file: "m", now: now0, calendar: utc).first?.kind == .bounty)
        let audit = "- Sherlock audit contest ends Aug 20 2026 ~/Developer/some-audit/"
        #expect(DeadlineParser.parse(text: audit, file: "m", now: now0, calendar: utc).first?.kind == .audit)
    }

    @Test func contextGateDropsAmbientDates() {
        // Changelog / timestamp / epoch dates with NO deadline signal must never become
        // deadlines — the difference between reading notes and hallucinating them.
        let noise = """
        - Wave 0 (14:50 IST): shipped the data-layer fix on 2026-07-06 (commit abc)
        - START: 2026-07-06 14:50 IST (epoch 1783329622)
        - updated Jul 6 2026 · re-auth worked 2026-07-03
        """
        #expect(DeadlineParser.parse(text: noise, file: "NOTES.md", defaultProject: "x", now: now0, calendar: utc).isEmpty)
    }

    @Test func perProjectFileMapsToItsOwnProjectNotAReferencedToolDir() {
        // A webapp changelog referencing a tool dir must attribute to webapp, not the tool.
        let line = "- referenced ~/Developer/browser-harness/SKILL.md · submission Jul 19 2026"
        let parsed = DeadlineParser.parse(text: line, file: "webapp/NOTES.md", defaultProject: "webapp",
                                          projectHints: ["browser-harness"], now: now0, calendar: utc)
        #expect(parsed.first?.projectKey == "webapp")
    }

    @Test func emDashSentinelNeverClaimsADeadline() {
        // The empty-project sentinel "—" (and too-short tokens) must not match prose.
        let line = "- some note — deadline Jul 13 2026 (no project path here)"
        let parsed = DeadlineParser.parse(text: line, file: "MEMORY.md", projectHints: ["—", "ab"],
                                          now: now0, calendar: utc)
        #expect(parsed.first?.projectKey == nil)   // no bogus "—" attribution
    }

    @Test func realSlateMapsEveryKnownProject() {
        let parsed = DeadlineParser.parse(text: memoryFixture, file: "MEMORY.md", now: now0, calendar: utc)
        let operative = DeadlineParser.operativeDeadlines(parsed, now: now0)
        #expect(Set(operative.keys).isSuperset(of: ["alpha-hackathon", "webapp", "api-gateway", "ops-review"]))
    }
}

// MARK: - Metric

@Suite("Jeopardy metric")
struct JeopardyMetricTests {

    @Test func runwayIsDeadlineMinusNow() {
        #expect(DeadlineMetric.runway(deadline: day(2026, 7, 13), now: day(2026, 7, 6)) == 7 * 86400)
    }

    @Test func idleIsNowMinusLastActivity() {
        let idle = DeadlineMetric.idle(lastActivity: day(2026, 7, 2), now: day(2026, 7, 6), runway: 7 * 86400)
        #expect(idle == 4 * 86400)
    }

    @Test func jeopardyIsIdleOverRunway() {
        // idle 4d, runway 7d → 0.571…
        let j = DeadlineMetric.jeopardy(idle: 4 * 86400, runway: 7 * 86400)
        #expect(abs(j - 4.0 / 7.0) < 1e-9)
    }

    @Test func neverTouchedReadsAsFullyIdle() {
        // no last-activity → idle == runway → jeopardy ≈ 1 (stalled when near).
        let runway: TimeInterval = 5 * 86400
        let idle = DeadlineMetric.idle(lastActivity: nil, now: now0, runway: runway)
        #expect(idle == runway)
        #expect(DeadlineMetric.jeopardy(idle: idle, runway: runway) == 1)
    }

    @Test func epsilonGuardsTheDeadlineCrossing() {
        // runway 0 → divide by epsilon, not zero.
        let j = DeadlineMetric.jeopardy(idle: 3600, runway: 0)
        #expect(j.isFinite)
    }
}

// MARK: - Classifier

@Suite("Deadline classifier")
struct DeadlineClassifierTests {
    private let cfg = DeadlineConfig()

    @Test func farAndUntouchedIsOnTrack() {
        // 24 days out, untouched 5 days is FINE (the doc's canonical non-alarm).
        let runway: TimeInterval = 24 * 86400, idle: TimeInterval = 5 * 86400
        let j = DeadlineMetric.jeopardy(idle: idle, runway: runway)
        #expect(DeadlineClassifier.classify(runway: runway, jeopardy: j, shipped: false, blocked: false, config: cfg) == .onTrack)
    }

    @Test func nearAndHighJeopardyIsStalled() {
        // 7 days out, idle 4 days → jeopardy 0.57 ≥ 0.5, near → STALLED (the alarm).
        let runway: TimeInterval = 7 * 86400, idle: TimeInterval = 4 * 86400
        let j = DeadlineMetric.jeopardy(idle: idle, runway: runway)
        #expect(DeadlineClassifier.classify(runway: runway, jeopardy: j, shipped: false, blocked: false, config: cfg) == .stalled)
    }

    @Test func nearAndModerateJeopardyIsAtRisk() {
        // 6 days out, idle ~1.8 days → jeopardy 0.30 (≥0.2, <0.5) → AT-RISK.
        let runway: TimeInterval = 6 * 86400, idle: TimeInterval = Int(1.8 * 86400).doubleValue
        let j = DeadlineMetric.jeopardy(idle: idle, runway: runway)
        #expect(DeadlineClassifier.classify(runway: runway, jeopardy: j, shipped: false, blocked: false, config: cfg) == .atRisk)
    }

    @Test func blockedNearIsAtRiskEvenWhenFresh() {
        let runway: TimeInterval = 3 * 86400
        let j = DeadlineMetric.jeopardy(idle: 60, runway: runway)   // fresh, low jeopardy
        #expect(DeadlineClassifier.classify(runway: runway, jeopardy: j, shipped: false, blocked: true, config: cfg) == .atRisk)
    }

    @Test func shippedIsConfirmedNeverInferred() {
        // Even inside the near-window with high jeopardy, a CONFIRMED shipped wins.
        #expect(DeadlineClassifier.classify(runway: 86400, jeopardy: 5, shipped: true, blocked: true, config: cfg) == .shipped)
    }

    @Test func pastDeadlineIsOverdue() {
        #expect(DeadlineClassifier.classify(runway: -86400, jeopardy: 99, shipped: false, blocked: false, config: cfg) == .overdue)
    }
}

// MARK: - Card + board

@Suite("Deadline board")
struct DeadlineBoardTests {
    // A `now` inside the near-window for the seeded July deadlines.
    private let nowB = day(2026, 7, 8, 12, 0)

    private func rec(_ key: String, _ deadline: Date, shipped: Bool = false) -> DeadlineRecord {
        DeadlineRecord(projectKey: key, deadline: deadline, kind: .hackathon,
                       source: DeadlineSource(file: "m", line: 1, raw: key, confirmed: true), shipped: shipped)
    }
    private func act(_ key: String, last: Date?, cost: Double = 10, sessions: Int = 3, live: Bool = false) -> ProjectActivity {
        ProjectActivity(project: key, lastActivity: last, cost: cost, sessionCount: sessions,
                        machineID: Machine.localID, isLive: live, blocked: false)
    }

    @Test func stalledPinnedTopShippedSunkBottom() {
        let records = [
            "slack": rec("slack", day(2026, 7, 13)),          // ~5.5d out, idle ~6.5d → stalled
            "webapp": rec("webapp", day(2026, 7, 30)),          // far, live → on-track
            "audit-tool": rec("audit-tool", day(2026, 7, 1), shipped: true),   // shipped
        ]
        let activity = [
            "slack": act("slack", last: day(2026, 7, 2)),
            "webapp": act("webapp", last: day(2026, 7, 8, 11, 55), live: true),
            "audit-tool": act("audit-tool", last: day(2026, 7, 1)),
        ]
        let cards = DeadlineBoard.build(records: records, activity: activity, now: nowB)
        #expect(cards.first?.projectKey == "slack")
        #expect(cards.first?.state == .stalled)
        #expect(cards.last?.state == .shipped)
        #expect(DeadlineBoard.worst(cards)?.projectKey == "slack")   // never a shipped card
    }

    @Test func jeopardyBarNormalizesButSortIsByRankThenJeopardy() {
        // Two stalled cards → the higher-jeopardy one sorts first.
        let records = ["a": rec("a", day(2026, 7, 10)), "b": rec("b", day(2026, 7, 12))]
        let activity = [
            "a": act("a", last: day(2026, 6, 30)),   // shorter runway, longer idle → very high jeopardy
            "b": act("b", last: day(2026, 7, 3)),    // longer runway, shorter idle → lower
        ]
        let cards = DeadlineBoard.build(records: records, activity: activity, now: nowB)
        #expect(cards.map(\.projectKey) == ["a", "b"])
        #expect(cards[0].jeopardy > cards[1].jeopardy)
    }

    @Test func cardCapturesActivityJoin() {
        let cards = DeadlineBoard.build(records: ["slack": rec("slack", day(2026, 7, 13))],
                                        activity: ["slack": act("slack", last: day(2026, 7, 2), cost: 41, sessions: 12)],
                                        now: nowB)
        let c = cards[0]
        #expect(c.cost == 41)
        #expect(c.sessionCount == 12)
        #expect(Int(c.runway / 86400) == 5)         // ~5.5 days of runway
        #expect(c.isReddening() == false)           // still outside the 72h redden window
    }
}

// MARK: - Activity roll-up

@Suite("Deadline activity")
struct DeadlineActivityTests {
    private func session(_ id: String, project: String, ageSecs: TimeInterval, cost: Double,
                         subagent: Bool = false) -> SessionSummary {
        let path = subagent ? "/x/\(project)/p/subagents/agent-\(id).jsonl" : "/x/\(project)/\(id).jsonl"
        return SessionSummary(id: subagent ? "p/\(id)" : id, project: project, cwd: "/x/\(project)",
                              model: "claude-opus-4-8", lastActivity: now0.addingTimeInterval(-ageSecs),
                              messageCount: 5, usage: SessionUsage(inputTokens: Int(cost / 5 * 1_000_000)),
                              contextWeight: 1000, filePath: path)
    }

    @Test func groupsByProjectSummingCostCountingMains() {
        let sessions = [
            session("a", project: "slack", ageSecs: 60, cost: 10),
            session("b", project: "slack", ageSecs: 300, cost: 20),
            session("s", project: "slack", ageSecs: 30, cost: 5, subagent: true),  // cost counts, not a "session"
            session("c", project: "webapp", ageSecs: 40 * 60, cost: 7),
        ]
        let act = DeadlineActivity.summarize(sessions, now: now0)
        #expect(act["slack"]?.sessionCount == 2)                       // subagent excluded from count
        #expect(abs((act["slack"]?.cost ?? 0) - 35) < 1e-6)           // all spend counted
        #expect(act["slack"]?.isLive == true)                         // a main active <15m
        #expect(act["webapp"]?.isLive == false)                        // 40m old
        #expect(act["slack"]?.lastActivity == now0.addingTimeInterval(-60))
    }

    @Test func foldsBlockedProjects() {
        let act = DeadlineActivity.summarize([session("a", project: "slack", ageSecs: 60, cost: 10)],
                                             now: now0, blockedProjects: ["slack"])
        #expect(act["slack"]?.blocked == true)
    }
}

// MARK: - .toml override + merge + write boundary

@Suite("Deadline override + merge + store")
struct DeadlineOverrideTests {

    @Test func parsesSectionedToml() {
        let toml = """
        # user-owned override
        [alpha-hackathon]
        deadline = 2026-07-13
        kind = "hackathon-submission"
        shipped = false

        [beta-hackathon]
        deadline = 2026-08-10T23:59:00Z
        platform = "Reddit"
        """
        let ovs = DeadlineTOML.parse(toml)
        let slack = ovs.first { $0.projectKey == "alpha-hackathon" }
        #expect(slack?.deadline == day(2026, 7, 13))
        #expect(slack?.kind == .hackathon)
        #expect(slack?.shipped == false)
        let reddit = ovs.first { $0.projectKey == "beta-hackathon" }
        #expect(reddit?.platform == "Reddit")
        #expect(reddit?.deadline == utc.date(from: DateComponents(year: 2026, month: 8, day: 10, hour: 23, minute: 59, second: 0)))
    }

    @Test func perProjectSectionlessToml() {
        let toml = "deadline = 2026-07-13\nkind = \"hackathon\"\n"
        let ovs = DeadlineTOML.parse(toml, defaultProject: "alpha-hackathon")
        #expect(ovs.first?.projectKey == "alpha-hackathon")
        #expect(ovs.first?.deadline == day(2026, 7, 13))
    }

    @Test func confirmedPersistedRecordBeatsFreshParse() {
        let confirmed = DeadlineRecord(projectKey: "slack", deadline: day(2026, 7, 13), kind: .hackathon,
                                       source: DeadlineSource(file: "m", line: 2, raw: "Jul 13", confirmed: true))
        let parse = ParsedDeadline(projectKey: "slack", date: day(2026, 7, 14), kind: .hackathon,
                                   label: "deadline",
                                   source: DeadlineSource(file: "m", line: 9, raw: "Jul 14", confirmed: false))
        let merged = DeadlineMerge.resolve(parsed: ["slack": parse], persisted: ["slack": confirmed], overrides: [])
        #expect(merged["slack"]?.deadline == day(2026, 7, 13))   // the confirmed word stands
    }

    @Test func overrideBeatsEverythingAndLandsConfirmed() {
        let parse = ParsedDeadline(projectKey: "slack", date: day(2026, 7, 14), kind: .hackathon, label: "deadline",
                                   source: DeadlineSource(file: "m", line: 9, raw: "Jul 14", confirmed: false))
        let ov = DeadlineOverride(projectKey: "slack", deadline: day(2026, 7, 13))
        let merged = DeadlineMerge.resolve(parsed: ["slack": parse], persisted: [:], overrides: [ov])
        #expect(merged["slack"]?.deadline == day(2026, 7, 13))
        #expect(merged["slack"]?.source.confirmed == true)       // authoritative → confirmed
        #expect(merged["slack"]?.source.origin == .override)
    }

    @Test func unconfirmedParseSeedsWhenNotPersisted() {
        let parse = ParsedDeadline(projectKey: "webapp", date: day(2026, 7, 19), kind: .hackathon, label: "submission",
                                   source: DeadlineSource(file: "m", line: 3, raw: "Jul 19", confirmed: false))
        let merged = DeadlineMerge.resolve(parsed: ["webapp": parse], persisted: [:], overrides: [])
        #expect(merged["webapp"]?.deadline == day(2026, 7, 19))
        #expect(merged["webapp"]?.source.confirmed == false)      // a finding awaiting confirm
    }

    @Test func unconfirmedRecordRetractsWhenParseNoLongerFindsIt() {
        // The "scripts" haunting: a parser false-positive got persisted UNCONFIRMED;
        // after the parser fix the fresh parse no longer produces it — the echo must
        // leave the board, not survive forever in deadlines.json.
        let phantom = DeadlineRecord(projectKey: "scripts", deadline: day(2026, 7, 7), kind: .hackathon,
                                     source: DeadlineSource(file: "MEMORY.md", line: 88, raw: "Jul 6", confirmed: false))
        let merged = DeadlineMerge.resolve(parsed: [:], persisted: ["scripts": phantom], overrides: [])
        #expect(merged["scripts"] == nil)
    }

    @Test func confirmedAndShippedRecordsNeverRetract() {
        // Confirmed/shipped are the USER's word — they outlive the parse that seeded them.
        let confirmed = DeadlineRecord(projectKey: "slack", deadline: day(2026, 7, 13), kind: .hackathon,
                                       source: DeadlineSource(file: "m", line: 2, raw: "Jul 13", confirmed: true))
        let shipped = DeadlineRecord(projectKey: "audit-tool", deadline: day(2026, 7, 2), kind: .bounty,
                                     source: DeadlineSource(file: "m", line: 9, raw: "Jul 2", confirmed: false),
                                     shipped: true)
        let merged = DeadlineMerge.resolve(parsed: [:], persisted: ["slack": confirmed, "audit-tool": shipped],
                                           overrides: [])
        #expect(merged["slack"] != nil)
        #expect(merged["audit-tool"] != nil)
    }

    @Test func overriddenRecordNeverRetracts() {
        // A .toml override names the project — it stays even with no fresh parse.
        let echo = DeadlineRecord(projectKey: "webapp", deadline: day(2026, 7, 19), kind: .hackathon,
                                  source: DeadlineSource(file: "m", line: 3, raw: "Jul 19", confirmed: false))
        let ov = DeadlineOverride(projectKey: "webapp", deadline: day(2026, 7, 20))
        let merged = DeadlineMerge.resolve(parsed: [:], persisted: ["webapp": echo], overrides: [ov])
        #expect(merged["webapp"]?.deadline == day(2026, 7, 20))
        #expect(merged["webapp"]?.source.confirmed == true)
    }

    @Test func storeRoundTripsToAppOwnedDirNeverDotClaude() {
        // The write boundary: the default store lives under Application Support, NOT ~/.claude.
        let path = DeadlineRecordStore.defaultURL.path
        #expect(path.contains("Application Support/Trifola/deadlines.json"))
        #expect(!path.contains("/.claude/"))

        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("mc-deadline-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let store = DeadlineRecordStore(url: tmp)
        let recs = ["slack": DeadlineRecord(projectKey: "slack", deadline: day(2026, 7, 13), kind: .hackathon,
                                            source: DeadlineSource(file: "m", line: 2, raw: "Jul 13 2026", confirmed: true),
                                            linearProjectId: "proj_abc")]
        #expect(store.save(recs) == true)
        let back = store.load()
        #expect(back["slack"]?.deadline == day(2026, 7, 13))
        #expect(back["slack"]?.linearProjectId == "proj_abc")
        #expect(back["slack"]?.source.confirmed == true)
    }
}

// MARK: - Countdown formatting (coarsens, never per-second)

@Suite("Countdown formatting")
struct CountdownTests {
    @Test func coarsensByDistance() {
        #expect(fmtCountdown(13 * 86400) == "13d")
        #expect(fmtCountdown(18 * 3600) == "18h")
        #expect(fmtCountdown(52 * 60) == "52m")
    }
    @Test func overduePastTheDeadline() {
        #expect(fmtCountdown(-2 * 86400) == "overdue 2d")
        #expect(fmtCountdown(-3 * 3600) == "overdue 3h")
    }
}

private extension Int { var doubleValue: Double { Double(self) } }
