import Foundation
import Testing
@testable import TrifolaKit

// W3 — COST PROVENANCE ("show the math"). These tests pin the brief's hard
// requirements: exact per-leg arithmetic on a fixture corpus (incl. a
// date-dependent sonnet-5 leg at $2/$10 pre-Sep-2026 and a $3/$15 leg after),
// Σ legs == the displayed total to the cent (the receipt can NEVER disagree
// with the headline — same code path), the dedup counts, and the "" undated
// bucket. Fixtures use only bundled-catalog models, so `.current` (which the
// headline paths call) resolves them identically to the bundled seed.

// MARK: - fixtures

private func modelDaySession(
    id: String = "fx",
    byModelDay: [String: [String: SessionUsage]],
    messages: [String: [String: Int]] = [:],
    rawUsageBlocks: Int = 0,
    lastActivity: Date? = nil,
    model: String? = nil
) -> SessionSummary {
    // Derive the tier + day maps the way the accumulator would, so fallback
    // paths (usageByDay) behave like real summaries.
    var byTier: [ModelTier: SessionUsage] = [:]
    var byDay: [String: [ModelTier: SessionUsage]] = [:]
    var byModel: [String: SessionUsage] = [:]
    var usage = SessionUsage()
    for (day, models) in byModelDay {
        for (m, u) in models {
            usage = usage + u
            byTier[ModelTier(raw: m)] = (byTier[ModelTier(raw: m)] ?? SessionUsage()) + u
            byModel[m] = (byModel[m] ?? SessionUsage()) + u
            if !day.isEmpty {
                byDay[day, default: [:]][ModelTier(raw: m)] =
                    (byDay[day]?[ModelTier(raw: m)] ?? SessionUsage()) + u
            }
        }
    }
    return SessionSummary(id: id, project: "fixture", cwd: "/tmp/fixture", model: model,
                          lastActivity: lastActivity, messageCount: 1, usage: usage,
                          contextWeight: 0, usageByTier: byTier, usageByDay: byDay,
                          usageByModel: byModel, usageByModelDay: byModelDay,
                          messagesByModelDay: messages, rawUsageBlocks: rawUsageBlocks)
}

// MARK: - the receipt

@Suite("Cost provenance — receipts")
struct CostProvenanceTests {

    /// The brief's fixture corpus: an opus-4-8 leg with the 5m/1h cache-write
    /// split, a date-dependent sonnet-5 leg in the intro era ($2/$10) AND one
    /// after the 2026-09-01 flip ($3/$15) — every leg's arithmetic asserted
    /// exactly, and Σ == the session's own displayed cost to the cent.
    @Test func perLegArithmeticIncludingDateDependentSonnet() {
        let s = modelDaySession(
            byModelDay: [
                "2026-07-05": [
                    // fresh 0.1M×$5=0.50 · cw5m 0.2M×$6.25=1.25 · cw1h 0.3M×$10=3.00 → $4.75
                    "claude-opus-4-8": SessionUsage(inputTokens: 100_000, cacheCreateTokens: 500_000,
                                                    cacheCreate1hTokens: 300_000),
                    // intro era: 1M × $2 = $2.00 (the tier table would say $3)
                    "claude-sonnet-5": SessionUsage(inputTokens: 1_000_000),
                ],
                "2026-09-02": [
                    // standard era: 1M × $3 = $3.00 — same model, its OWN date
                    "claude-sonnet-5": SessionUsage(inputTokens: 1_000_000),
                ],
            ],
            messages: ["2026-07-05": ["claude-opus-4-8": 3, "claude-sonnet-5": 2],
                       "2026-09-02": ["claude-sonnet-5": 1]],
            rawUsageBlocks: 9)

        let r = CostProvenance.corpusReceipt(sessions: [s])

        // Three legs — sonnet-5 SPLITS per rate era.
        #expect(r.legs.count == 3)
        let opus = r.legs.first { $0.model == "claude-opus-4-8" }!
        #expect(abs(opus.dollars - 4.75) < 0.0001)
        #expect(opus.messages == 3)
        #expect(opus.ruleNote == nil)          // single-era model: no rule note
        // The three cost lines: fresh + cw5m + cw1h (zero-token lines omitted).
        #expect(opus.lines.count == 3)
        #expect(abs(opus.lines[0].dollars - 0.50) < 0.0001)
        #expect(abs(opus.lines[1].dollars - 1.25) < 0.0001)
        #expect(abs(opus.lines[2].dollars - 3.00) < 0.0001)

        let sonnetLegs = r.legs.filter { $0.model == "claude-sonnet-5" }
            .sorted { $0.dollars < $1.dollars }
        #expect(sonnetLegs.count == 2)
        #expect(abs(sonnetLegs[0].dollars - 2.00) < 0.0001)      // intro era
        #expect(sonnetLegs[0].ruleNote == "$2/$10 through 2026-08-31")
        #expect(sonnetLegs[0].days == ["2026-07-05"])
        #expect(abs(sonnetLegs[1].dollars - 3.00) < 0.0001)      // standard era
        #expect(sonnetLegs[1].ruleNote == "$3/$15 from 2026-09-01")

        // THE INVARIANT: Σ legs == the displayed total, to the cent — the same
        // `cost(rate:)` the headline sums, only regrouped.
        #expect(abs(r.total - s.cost) < 0.005)
        #expect(abs(r.total - 9.75) < 0.0001)

        // Dedup + provenance footers.
        #expect(r.dedupNote == "9 raw usage blocks → 6 unique messageId:requestId (last-chunk-wins)")
        #expect(r.pricingSource.contains("bundled \(PricingCatalog.bundledDate)"))
        #expect(r.plainText.contains("Σ legs = $9.75"))
        #expect(r.plainText.contains("last-chunk-wins"))
    }

    /// The "" undated bucket: priced at today's era (exactly what
    /// `ModelPricing.rate(onDay:)` does for the headline), labeled "undated",
    /// and never dropped from Σ.
    @Test func undatedBucketIsPricedAndLabeled() {
        let s = modelDaySession(
            byModelDay: ["": ["claude-haiku-4-5": SessionUsage(inputTokens: 1_000_000)]],
            messages: ["": ["claude-haiku-4-5": 1]], rawUsageBlocks: 1)
        let r = CostProvenance.corpusReceipt(sessions: [s])
        #expect(r.legs.count == 1)
        #expect(abs(r.legs[0].dollars - 1.00) < 0.0001)     // 1M × $1
        #expect(r.legs[0].days == [""])
        #expect(r.legs[0].daysLabel == "undated")
        #expect(abs(r.total - s.cost) < 0.005)
        #expect(r.plainText.contains("undated"))
        #expect(r.bucketingNote.contains("undated lines priced at today's rates"))
    }

    /// A pre-W2 summary (no per-model data) falls back to tier-rate slices in
    /// `reduceSlices`; the receipt takes the SAME fallback, labels it, and the
    /// corpus Σ still equals the corpus headline.
    @Test func tierFallbackSessionsKeepReceiptEqualToHeadline() {
        let modern = modelDaySession(
            byModelDay: ["2026-07-05": ["claude-opus-4-8": SessionUsage(inputTokens: 1_000_000)]],
            messages: ["2026-07-05": ["claude-opus-4-8": 1]], rawUsageBlocks: 1)
        let legacy = SessionSummary(id: "old", project: "fixture", cwd: "/tmp", model: "claude-opus-4-8",
                                    lastActivity: nil, messageCount: 4,
                                    usage: SessionUsage(inputTokens: 1_000_000), contextWeight: 0,
                                    usageByTier: [.opus: SessionUsage(inputTokens: 1_000_000)])
        let sessions = [modern, legacy]
        let r = CostProvenance.corpusReceipt(sessions: sessions)
        let headline = sessions.reduce(0.0) { $0 + $1.cost }
        #expect(abs(r.total - headline) < 0.005)
        #expect(abs(r.total - 10.0) < 0.0001)              // 1M×$5 + 1M×$5
        let fallback = r.legs.first { $0.model.contains("tier fallback") }
        #expect(fallback != nil)
        #expect(fallback?.ruleNote == "flat tier rates — summary predates per-model data")
        #expect(fallback?.messages == 0)                   // unknown, shown as none
    }

    /// An unknown model id prices at its tier fallback (unchanged from W2) and
    /// the receipt SAYS so instead of pretending it's a catalog row.
    @Test func unknownModelLegIsLabeledAsFallback() {
        let s = modelDaySession(
            byModelDay: ["2026-07-05": ["glm-4.7": SessionUsage(inputTokens: 1_000_000)]],
            messages: ["2026-07-05": ["glm-4.7": 1]], rawUsageBlocks: 1)
        let r = CostProvenance.corpusReceipt(sessions: [s])
        #expect(r.legs.count == 1)
        #expect(r.legs[0].model == "glm-4.7")
        #expect(r.legs[0].ruleNote == "not in catalog — Other tier fallback rates")
        #expect(abs(r.total - s.cost) < 0.005)
        #expect(abs(r.total - 5.0) < 0.0001)               // other tier $5/M
    }

    /// The leak receipt: fresh input × (input − cacheRead) per leg — the exact
    /// `cacheLeakDollars` the Audit card displays.
    @Test func leakReceiptMatchesAuditLeak() {
        let s = modelDaySession(
            byModelDay: ["2026-07-05": [
                "claude-opus-4-8": SessionUsage(inputTokens: 1_000_000, cacheCreateTokens: 500_000,
                                                cacheReadTokens: 2_000_000, cacheCreate1hTokens: 300_000),
            ]],
            messages: ["2026-07-05": ["claude-opus-4-8": 5]], rawUsageBlocks: 13)
        let r = CostProvenance.sessionReceipt(s, metric: .cacheLeak)
        // 1M × ($5.00 − $0.50) = $4.50
        #expect(abs(r.total - 4.50) < 0.0001)
        #expect(abs(r.total - s.cacheLeakDollars) < 0.005)
        #expect(r.legs[0].lines[0].label == "fresh input")
        #expect(r.legs[0].lines[0].math.contains("$5.00/M") && r.legs[0].lines[0].math.contains("$0.50/M"))

        // First-touch (never summed into the leak): 0.2M×$6.25 + 0.3M×$10 = $4.25.
        let ft = CostProvenance.sessionReceipt(s, metric: .firstTouch)
        #expect(abs(ft.total - 4.25) < 0.0001)
        #expect(abs(ft.total - s.firstTouchDollars) < 0.005)
    }

    /// The mismatch receipt reproduces `AuditReport.frontierOverspend` exactly
    /// — per-day-slice `max(0, actual − repriced)`, frontier legs only — on
    /// BOTH the per-model-day path and the tier-fallback path.
    @Test func mismatchReceiptMatchesFrontierOverspend() {
        // Model-day path: opus 1M in + 100k out on 07-05 → actual $7.50,
        // sonnet-5 intro $3.00 → over $4.50. Sonnet slice must be ignored.
        let s = modelDaySession(
            byModelDay: ["2026-07-05": [
                "claude-opus-4-8": SessionUsage(inputTokens: 1_000_000, outputTokens: 100_000),
                "claude-sonnet-5": SessionUsage(inputTokens: 500_000),
            ]],
            messages: ["2026-07-05": ["claude-opus-4-8": 2, "claude-sonnet-5": 1]])
        let r = CostProvenance.mismatchReceipt(s)
        #expect(abs(r.total - 4.50) < 0.0001)
        #expect(abs(r.total - AuditReport.frontierOverspend(s)) < 0.005)
        #expect(r.legs.count == 1)
        #expect(r.legs[0].model == "claude-opus-4-8")
        #expect(abs(r.legs[0].lines[0].dollars - 7.50) < 0.0001)   // actual
        #expect(abs(r.legs[0].lines[1].dollars - 3.00) < 0.0001)   // repriced

        // Tier-fallback path (synthetic summary): opus 1M in → $5 actual,
        // $2 sonnet intro on the pinned fallback day → over $3.
        let legacy = SessionSummary(id: "old", project: "fixture", cwd: "/tmp", model: "claude-opus-4-8",
                                    lastActivity: nil, messageCount: 3,
                                    usage: SessionUsage(inputTokens: 1_000_000), contextWeight: 0,
                                    usageByTier: [.opus: SessionUsage(inputTokens: 1_000_000)])
        let r2 = CostProvenance.mismatchReceipt(legacy, fallbackDay: "2026-07-05")
        #expect(abs(r2.total - 3.0) < 0.0001)
        #expect(abs(r2.total - AuditReport.frontierOverspend(legacy, fallbackDay: "2026-07-05")) < 0.005)
    }

    /// The day receipt mirrors the burn governor's bucketing exactly — the
    /// per-message-day path AND the lastActivity fallback — so the Burn tile's
    /// "Today" and its receipt can never disagree.
    @Test func dayReceiptMatchesBurnGovernorToday() {
        let cal = Calendar.current
        let now = Date()
        let today = CostProvenance.dayKey(for: now)
        let modern = modelDaySession(
            byModelDay: [today: ["claude-opus-4-8": SessionUsage(inputTokens: 1_000_000)]],
            messages: [today: ["claude-opus-4-8": 4]],
            lastActivity: now)
        // Fallback session: NO per-day maps → whole session on lastActivity day.
        let legacy = SessionSummary(id: "old", project: "fixture", cwd: "/tmp", model: "claude-sonnet-4-6",
                                    lastActivity: now, messageCount: 2,
                                    usage: SessionUsage(inputTokens: 1_000_000), contextWeight: 0,
                                    usageByTier: [.sonnet: SessionUsage(inputTokens: 1_000_000)])
        let sessions = [modern, legacy]
        let governor = BurnGovernor(sessions: sessions, now: now, calendar: cal)
        let r = CostProvenance.dayReceipt(sessions: sessions, dayKey: today, calendar: cal)
        #expect(abs(r.total - governor.today.cost) < 0.005)
        #expect(abs(r.total - 8.0) < 0.0001)               // $5 opus + $3 sonnet tier
    }

    /// The tier receipt mirrors `perTierCostMap` grouping: models grouped by
    /// display tier but each priced at its OWN rate (sonnet-5 $2 ≠ sonnet-4-6 $3).
    @Test func tierReceiptMatchesPerTierCostMap() {
        let s = modelDaySession(
            byModelDay: ["2026-07-05": [
                "claude-sonnet-5": SessionUsage(inputTokens: 1_000_000),
                "claude-sonnet-4-6": SessionUsage(inputTokens: 1_000_000),
                "claude-opus-4-8": SessionUsage(inputTokens: 1_000_000),
            ]],
            messages: ["2026-07-05": ["claude-sonnet-5": 1, "claude-sonnet-4-6": 1, "claude-opus-4-8": 1]])
        let r = CostProvenance.tierReceipt(sessions: [s], tier: .sonnet)
        #expect(abs(r.total - 5.0) < 0.0001)               // $2 + $3, never $6
        #expect(abs(r.total - (s.perTierCostMap[.sonnet] ?? 0)) < 0.005)
        #expect(r.legs.count == 2)                          // two models, two rates
        #expect(!r.legs.contains { $0.model == "claude-opus-4-8" })
    }

    /// The projection footnote prints the governor's OWN number (same code
    /// path) plus the mean formula that produced it.
    @Test func projectionFootnoteUsesGovernorsOwnNumber() {
        let cal = Calendar.current
        let now = Date()
        let today = cal.startOfDay(for: now)
        func daySession(_ back: Int, _ cost: Double) -> SessionSummary? {
            guard let d = cal.date(byAdding: .day, value: -back, to: today) else { return nil }
            let u = SessionUsage(inputTokens: Int(cost / 5.0 * 1_000_000))   // opus $5/M
            return SessionSummary(id: "b\(back)", project: "p", cwd: "/tmp", model: "claude-opus-4-8",
                                  lastActivity: d.addingTimeInterval(3600), messageCount: 1,
                                  usage: u, contextWeight: 0, usageByTier: [.opus: u])
        }
        let sessions = [daySession(1, 30), daySession(2, 60), daySession(3, 90)].compactMap { $0 }
        let g = BurnGovernor(sessions: sessions, now: now, calendar: cal)
        let note = CostProvenance.projectionFootnote(g)
        #expect(note.contains("mean(last \(g.runRateDays) complete days"))
        #expect(note.contains(String(format: "$%.2f", g.monthProjection)))
        // No-history governor stays honest.
        let empty = BurnGovernor(sessions: [], now: now, calendar: cal)
        #expect(CostProvenance.projectionFootnote(empty).contains("no complete days")
                || empty.runRateDays > 0)
    }

    /// An empty scope still renders a calm, complete receipt.
    @Test func emptyScopeReceiptIsCalm() {
        let r = CostProvenance.corpusReceipt(sessions: [])
        #expect(r.legs.isEmpty)
        #expect(r.total == 0)
        #expect(r.plainText.contains("(no priced usage in this scope)"))
        #expect(r.dedupNote == "no per-message dedup data (synthetic summary)")
    }

    @Test func groupedNumberFormatting() {
        #expect(fmtGrouped(2_194_627) == "2,194,627")
        #expect(fmtGrouped(999) == "999")
        #expect(fmtGrouped(0) == "0")
    }
}

// MARK: - accumulator provenance counters (the disk-truth side of the dedup note)

@Suite("Cost provenance — accumulator counters")
struct ProvenanceAccumulatorTests {

    private func line(model: String, day: String, mid: String?, rid: String?, input: Int) -> String {
        let ids = (mid != nil ? #""id":"\#(mid!)","# : "")
        let req = (rid != nil ? #""requestId":"\#(rid!)","# : "")
        return #"{"type":"assistant",\#(req)"timestamp":"\#(day)T10:00:00.000Z","message":{\#(ids)"model":"\#(model)","usage":{"input_tokens":\#(input),"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
    }

    /// Three streaming chunks of ONE message (same message.id + requestId,
    /// cumulative usage) plus one distinct message: 4 raw usage blocks → 2
    /// unique keys, and only the LAST cumulative chunk of the streamed message
    /// counts — the exact story the receipt's dedup note tells.
    @Test func rawVsDedupedCountsSurviveStreamingChunks() {
        let lines = [
            line(model: "claude-opus-4-8", day: "2026-07-05", mid: "m-a", rid: "r-a", input: 100_000),
            line(model: "claude-opus-4-8", day: "2026-07-05", mid: "m-a", rid: "r-a", input: 200_000),
            line(model: "claude-opus-4-8", day: "2026-07-05", mid: "m-a", rid: "r-a", input: 300_000),
            line(model: "claude-opus-4-8", day: "2026-07-05", mid: "m-b", rid: "r-b", input: 50_000),
        ].joined(separator: "\n") + "\n"
        var acc = SessionAccumulator(defaultID: "fx")
        acc.ingest(Data(lines.utf8))
        let s = acc.summary(filePath: "/x.jsonl")

        #expect(s.rawUsageBlocks == 4)
        #expect(s.dedupedUsageBlocks == 2)
        #expect(s.messagesByModelDay["2026-07-05"]?["claude-opus-4-8"] == 2)
        // Last cumulative chunk wins: 300k + 50k, not 650k.
        #expect(s.usage.inputTokens == 350_000)

        let r = CostProvenance.sessionReceipt(s)
        #expect(r.dedupNote == "4 raw usage blocks → 2 unique messageId:requestId (last-chunk-wins)")
        #expect(r.legs.first?.messages == 2)
        #expect(abs(r.total - s.cost) < 0.005)
    }
}
