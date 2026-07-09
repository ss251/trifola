import Foundation
import Testing
@testable import TrifolaKit

// W3 — RECONCILE vs CodexBar. Pins the brief's hard requirements: the cache
// parser against a fixture JSON in the EXACT packed shape
// ([input, cacheRead, cacheCreate, output, costNanos, rowCount,
//   costPricedCount, cacheCreate1h]), the Δ computation + the green rule
// (BOTH the $0.01 and 0.5% arms), the staleness note (lastScan older than our
// scan → the calm lag explanation), and absent-file grace.

// MARK: - fixtures

/// The exact on-disk shape (a trimmed slice of the real 2026-07-05 cache —
/// opus-4-8 $132.823985 + haiku-4-5 $0.3833434). `files` is present and must
/// be ignored by the parser.
private let fixtureJSON = #"""
{
  "version": 1,
  "lastScanUnixMs": 1783362952120,
  "scanSinceKey": "2026-06-07",
  "scanUntilKey": "2026-07-08",
  "days": {
    "2026-07-05": {
      "claude-opus-4-8": [2194627, 50200040, 8524768, 460126, 132823985000, 718, 718, 8524768],
      "claude-haiku-4-5": [49, 105264, 182934, 1380, 383343400, 6, 6, 182934]
    },
    "2026-07-06": {
      "claude-sonnet-5": [308, 18971200, 668618, 139774, 7084080000, 154, 154, 146626]
    }
  },
  "files": { "/Users/dev/.claude/projects/a/b.jsonl": [12, 99] }
}
"""#

private func localDate(_ day: String, hour: Int = 12) -> Date {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.timeZone = TimeZone.current
    f.dateFormat = "yyyy-MM-dd HH:mm"
    return f.date(from: "\(day) \(String(format: "%02d", hour)):00")!
}

// MARK: - parser

@Suite("CodexBar reconcile — cache parser")
struct CodexBarParserTests {

    @Test func parsesExactPackedShape() {
        let cache = CodexBarReconcile.parse(Data(fixtureJSON.utf8))
        #expect(cache != nil)
        guard let cache else { return }

        #expect(cache.version == 1)
        #expect(cache.scanSinceKey == "2026-06-07")
        #expect(cache.scanUntilKey == "2026-07-08")
        // lastScanUnixMs is MILLISECONDS since epoch.
        #expect(abs(cache.lastScan!.timeIntervalSince1970 - 1_783_362_952.120) < 0.001)
        #expect(cache.days.count == 2)

        // Every packed slot lands on its named field.
        let opus = cache.days["2026-07-05"]!["claude-opus-4-8"]!
        #expect(opus.input == 2_194_627)
        #expect(opus.cacheRead == 50_200_040)
        #expect(opus.cacheCreate == 8_524_768)
        #expect(opus.output == 460_126)
        #expect(opus.costNanos == 132_823_985_000)
        #expect(opus.rowCount == 718)
        #expect(opus.costPricedCount == 718)
        #expect(opus.cacheCreate1h == 8_524_768)
        // costNanos ÷ 1e9 = dollars.
        #expect(abs(opus.dollars - 132.823985) < 1e-9)

        // Day total = Σ per-model dollars.
        #expect(abs(cache.dayTotal("2026-07-05") - (132.823985 + 0.3833434)) < 1e-6)
        #expect(cache.dayTotal("2026-01-01") == 0)     // absent day → $0, no crash
    }

    @Test func malformedRowsAndGarbageAreSkippedNotFatal() {
        // A short packed array (7 slots) must be skipped; the good row survives.
        let mixed = #"{"version":1,"days":{"2026-07-05":{"bad":[1,2,3,4,5,6,7],"claude-haiku-4-5":[49,105264,182934,1380,383343400,6,6,182934]}}}"#
        let cache = CodexBarReconcile.parse(Data(mixed.utf8))
        #expect(cache?.days["2026-07-05"]?.count == 1)
        #expect(cache?.days["2026-07-05"]?["claude-haiku-4-5"] != nil)
        // Garbage → nil, never a crash.
        #expect(CodexBarReconcile.parse(Data("not json".utf8)) == nil)
        #expect(CodexBarReconcile.parse(Data(#"{"version":1}"#.utf8)) == nil)   // no days key
    }

    @Test func absentFileIsGracefulMissing() {
        let nowhere = URL(fileURLWithPath: "/tmp/definitely-not-here-\(UUID().uuidString).json")
        guard case .missing = CodexBarReconcile.load(url: nowhere) else {
            Issue.record("expected .missing for an absent cache file")
            return
        }
        // Unreadable shape → .unreadable with a reason, still no throw.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("reconcile-test-\(UUID().uuidString)")
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bad = dir.appendingPathComponent("claude-v4.json")
        try? Data("not json at all".utf8).write(to: bad)
        guard case .unreadable = CodexBarReconcile.load(url: bad) else {
            Issue.record("expected .unreadable for garbage bytes")
            return
        }
    }
}

// MARK: - Δ + the green rule

@Suite("CodexBar reconcile — Δ and the green rule")
struct ReconcileDeltaTests {

    /// BOTH arms of the tolerance: the $0.01 absolute floor (tiny days) and
    /// the 0.5% band (big days) — plus the red cases just outside each.
    @Test func greenRuleBothArms() {
        // Cent arm: $0.008 gap on near-zero totals → green.
        #expect(CodexBarReconcile.withinTolerance(ours: 0.008, theirs: 0.0))
        // Just past the cent arm on tiny totals → red (0.5% of $0.05 ≈ $0.00025).
        #expect(!CodexBarReconcile.withinTolerance(ours: 0.05, theirs: 0.02))
        // Percent arm: $2 gap on $600 (0.33%) → green even though > $0.01.
        #expect(CodexBarReconcile.withinTolerance(ours: 600.0, theirs: 598.0))
        // Past the percent arm: $10 on $600 (1.7%) → red.
        #expect(!CodexBarReconcile.withinTolerance(ours: 600.0, theirs: 590.0))
        // Exact match is always green.
        #expect(CodexBarReconcile.withinTolerance(ours: 134.57, theirs: 134.57))
    }

    /// `compare` prices OUR side through the same per-model-day catalog path
    /// as `--spend-by-model`; a fixture where both sides agree lands green
    /// with Δ 0 and full per-model drill-in maps.
    @Test func compareAgreesWithCatalogPricedFixture() {
        // Ours: opus-4-8, 1M fresh input on 2026-07-05 → $5.00 exactly.
        let u = SessionUsage(inputTokens: 1_000_000)
        let s = SessionSummary(id: "fx", project: "p", cwd: "/tmp", model: "claude-opus-4-8",
                               lastActivity: nil, messageCount: 1, usage: u, contextWeight: 0,
                               usageByTier: [.opus: u],
                               usageByModel: ["claude-opus-4-8": u],
                               usageByModelDay: ["2026-07-05": ["claude-opus-4-8": u]])
        // Theirs: the same day at costNanos $5.00.
        let json = #"{"version":1,"lastScanUnixMs":0,"days":{"2026-07-05":{"claude-opus-4-8":[1000000,0,0,0,5000000000,10,10,0]}}}"#
        let cache = CodexBarReconcile.parse(Data(json.utf8))!
        let rows = CodexBarReconcile.compare(sessions: [s], cache: cache, days: ["2026-07-05"])
        #expect(rows.count == 1)
        #expect(abs(rows[0].ours - 5.0) < 0.0001)
        #expect(abs(rows[0].theirs - 5.0) < 0.0001)
        #expect(abs(rows[0].delta) < 0.0001)
        #expect(rows[0].matches)
        #expect(rows[0].likelyCause(lastScan: nil) == nil)       // green days explain nothing
        #expect(abs((rows[0].ourModels["claude-opus-4-8"] ?? 0) - 5.0) < 0.0001)
        #expect(abs((rows[0].theirModels["claude-opus-4-8"] ?? 0) - 5.0) < 0.0001)
    }

    /// The staleness note: CodexBar's lastScan on/before the compared day →
    /// the calm "it lags live sessions" explanation, never panic language.
    @Test func staleScanExplainsLagCalmly() {
        let row = ReconcileDay(day: "2026-07-06", ours: 580.15, theirs: 536.82,
                               ourModels: ["claude-opus-4-8": 455.99],
                               theirModels: ["claude-opus-4-8": 412.67])
        #expect(!row.matches)
        // lastScan mid-day ON the compared day → the day closed after the scan.
        let cause = row.likelyCause(lastScan: localDate("2026-07-06", hour: 14),
                                    now: localDate("2026-07-07", hour: 10))
        #expect(cause?.contains("lags live sessions") == true)
        #expect(cause?.contains("last scanned") == true)
        // No alarm words — calm by contract.
        #expect(cause?.lowercased().contains("error") == false)
        #expect(cause?.lowercased().contains("wrong") == false)
    }

    /// A fresh scan (after the day closed) with a real gap names the model
    /// with the largest per-model |Δ| instead — a lead, not a verdict.
    @Test func freshScanMismatchNamesLargestModelGap() {
        let row = ReconcileDay(day: "2026-07-05", ours: 140.0, theirs: 134.57,
                               ourModels: ["claude-opus-4-8": 138.0, "claude-haiku-4-5": 2.0],
                               theirModels: ["claude-opus-4-8": 132.82, "claude-haiku-4-5": 1.75])
        #expect(!row.matches)
        let cause = row.likelyCause(lastScan: localDate("2026-07-07", hour: 0),
                                    now: localDate("2026-07-07", hour: 10))
        #expect(cause?.contains("largest gap on claude-opus-4-8") == true)
        #expect(cause?.contains("rate or dedup difference") == true)
    }

    /// A day CodexBar simply hasn't scanned reads as its own calm cause.
    @Test func missingCodexBarDayIsExplained() {
        let row = ReconcileDay(day: "2026-05-01", ours: 12.0, theirs: 0,
                               ourModels: ["claude-opus-4-8": 12.0], theirModels: [:])
        let cause = row.likelyCause(lastScan: localDate("2026-07-07"),
                                    now: localDate("2026-07-07", hour: 10))
        #expect(cause?.contains("no rows") == true)
        #expect(cause?.contains("scan window") == true)
    }

    @Test func lastClosedDaysExcludeToday() {
        let now = localDate("2026-07-07", hour: 10)
        let days = CodexBarReconcile.lastClosedDays(2, now: now)
        #expect(days == ["2026-07-06", "2026-07-05"])
    }
}
