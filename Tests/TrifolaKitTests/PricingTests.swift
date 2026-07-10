import Foundation
import Testing
@testable import TrifolaKit

// W2 — the per-MODEL pricing catalog. These tests pin the brief's hard
// requirements: Anthropic-authoritative per-model rates (opus-4-8 ≠ opus-4-1),
// the DATE-DEPENDENT Sonnet-5 rule, id normalization, tier fallback for unknown
// models, the 5m/1h cache-write split, and the accumulator recording all of it.

// MARK: - Catalog rates

@Suite("Pricing catalog")
struct PricingCatalogTests {

    @Test func sonnet5IsDateDependent() {
        let cat = PricingCatalog.bundled
        // Intro era (through 2026-08-31): $2 in / $10 out — NOT $3/$15.
        let intro = cat.rate(model: "claude-sonnet-5", onDay: "2026-07-06")!
        #expect(intro.input == 2 && intro.output == 10)
        #expect(abs(intro.cacheRead - 0.20) < 1e-9)
        #expect(abs(intro.cacheWrite5m - 2.50) < 1e-9)
        #expect(abs(intro.cacheWrite1h - 4.0) < 1e-9)
        // Boundary day 2026-09-01 and after: $3/$15.
        let std = cat.rate(model: "claude-sonnet-5", onDay: "2026-09-01")!
        #expect(std.input == 3 && std.output == 15)
        let later = cat.rate(model: "claude-sonnet-5", onDay: "2027-01-15")!
        #expect(later.input == 3 && later.output == 15)
        // Day before the boundary is still intro.
        let aug31 = cat.rate(model: "claude-sonnet-5", onDay: "2026-08-31")!
        #expect(aug31.input == 2)
    }

    @Test func opusGenerationsPriceDifferently() {
        let cat = PricingCatalog.bundled
        // Opus 4.8 (current) = $5/$25; Opus 4.1 (deprecated) = $15/$75 —
        // the flat per-tier table priced BOTH at one rate, which is the W2 bug.
        let o48 = cat.rate(model: "claude-opus-4-8")!
        #expect(o48.input == 5 && o48.output == 25)
        #expect(abs(o48.cacheRead - 0.50) < 1e-9)
        #expect(abs(o48.cacheWrite5m - 6.25) < 1e-9)
        #expect(abs(o48.cacheWrite1h - 10.0) < 1e-9)
        let o41 = cat.rate(model: "claude-opus-4-1")!
        #expect(o41.input == 15 && o41.output == 75)
        // Haiku 4.5 anchor.
        let haiku = cat.rate(model: "claude-haiku-4-5")!
        #expect(haiku.input == 1 && haiku.output == 5)
    }

    @Test func fable5AndHaiku35ConstantsAndDatedIDsArePinned() throws {
        let cat = PricingCatalog.bundled
        let fable = try #require(cat.rate(model: "claude-fable-5-20260301"))
        #expect(fable.input == 10)
        #expect(fable.output == 50)
        #expect(fable.cacheRead == 1)
        #expect(fable.cacheWrite5m == 12.5)
        #expect(fable.cacheWrite1h == 20)

        let haiku = try #require(cat.rate(model: "claude-3-5-haiku-20241022"))
        #expect(haiku.input == 0.8)
        #expect(haiku.output == 4)
        #expect(abs(haiku.cacheRead - 0.08) < 1e-12)
        #expect(haiku.cacheWrite5m == 1)
        #expect(abs(haiku.cacheWrite1h - 1.6) < 1e-12)
    }

    @Test func unknownModelFallsBackToTierRate() {
        let cat = PricingCatalog.bundled
        #expect(cat.rate(model: "glm-4.7") == nil)
        // resolvedRate: unknown → the model's TIER fallback ("opus" alias → opus
        // tier $5/$25; a fully unknown id → other tier $5/$25).
        let alias = cat.resolvedRate(model: "opus")
        #expect(alias.input == 5 && alias.output == 25)
        let other = cat.resolvedRate(model: "glm-4.7")
        #expect(other.input == ModelTier.other.rates.inp)
        #expect(other.output == ModelTier.other.rates.out)
        #expect(abs(other.cacheWrite5m - other.input * 1.25) < 1e-9)
        let synthetic = cat.resolvedRate(model: "<synthetic>")
        #expect(synthetic.input == 5)
    }

    @Test func normalizeStripsPrefixesAndSuffixes() {
        #expect(PricingCatalog.normalize("us.anthropic.claude-opus-4-8") == "claude-opus-4-8")
        #expect(PricingCatalog.normalize("claude-opus-4-8@default") == "claude-opus-4-8")
        #expect(PricingCatalog.normalize("anthropic/claude-sonnet-5") == "claude-sonnet-5")
        #expect(PricingCatalog.normalize("claude-haiku-4-5-20251001") == "claude-haiku-4-5")
        #expect(PricingCatalog.normalize("claude-opus-4-8[1m]") == "claude-opus-4-8")
        #expect(PricingCatalog.normalize("CLAUDE-OPUS-4-8") == "claude-opus-4-8")
        #expect(PricingCatalog.normalize("claude-sonnet-5") == "claude-sonnet-5") // idempotent
        #expect(PricingCatalog.normalize(nil) == "")
        // A date-stamped id must resolve to the SAME rate as its base id.
        let cat = PricingCatalog.bundled
        #expect(cat.rate(model: "us.anthropic.claude-haiku-4-5-20251001@x")?.input == 1)
    }

    @Test func costSplitsCacheWritesInto5mAnd1hSlices() {
        // 1M fresh + 1M cache-create of which 400k is the 1h slice, on Opus 4.8:
        //   fresh 1M × $5            = 5.000
        //   cw5m  0.6M × $6.25       = 3.750
        //   cw1h  0.4M × $10 (2×)    = 4.000   ← the slice the old 1.25× lump undercounted
        //   total                    = 12.750
        let u = SessionUsage(inputTokens: 1_000_000, cacheCreateTokens: 1_000_000,
                             cacheCreate1hTokens: 400_000)
        let rate = PricingCatalog.bundled.rate(model: "claude-opus-4-8")!
        #expect(abs(u.cost(rate: rate) - 12.75) < 0.0001)
        // The pre-W2 lump (all creates at 1.25×) would have said 5 + 1M×6.25 = 11.25.
        let lumped = SessionUsage(inputTokens: 1_000_000, cacheCreateTokens: 1_000_000)
        #expect(abs(lumped.cost(rate: rate) - 11.25) < 0.0001)
    }

    @Test func tierFallbackCostMatchesOldTierMathWhenNo1hSlice() {
        // The tier overload prices via ModelRate(tier:) — identical to the old
        // flat math for usages without a 1h slice:
        // fresh 1M×$3 + cw 0.4M×$3×1.25 + cr 2M×$3×0.10 + out 0.2M×$15 = 8.10
        let u = SessionUsage(inputTokens: 1_000_000, outputTokens: 200_000,
                             cacheCreateTokens: 400_000, cacheReadTokens: 2_000_000)
        #expect(abs(u.cost(.sonnet) - 8.10) < 0.0001)
    }

    @Test func overlayOnlyAddsNeverOverwritesBundledRows() throws {
        // A models.dev overlay claiming a WRONG opus-4-8 rate and a NEW model:
        // the bundled (Anthropic-authoritative) row must win; the new id is added.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("pricing-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let url = dir.appendingPathComponent("pricing.json")
        let overlay = PricingCatalog.OverlayFile(fetchedAt: Date(), models: [
            "claude-opus-4-8": ModelRate(input: 99, output: 99),   // must be IGNORED
            "claude-nova-6": ModelRate(input: 7, output: 35),      // must be ADDED
        ])
        try JSONEncoder().encode(overlay).write(to: url)

        let cat = PricingCatalog.load(overlay: url)
        #expect(cat.rate(model: "claude-opus-4-8")?.input == 5)    // bundled wins
        #expect(cat.rate(model: "claude-nova-6")?.input == 7)      // overlay added
        #expect(cat.refreshedAdded == 1)
        #expect(cat.refreshedAt != nil)
        #expect(cat.sourceLabel.contains("refreshed"))
        // Missing overlay → pure bundled seed, labeled as such.
        let missing = PricingCatalog.load(overlay: dir.appendingPathComponent("nope.json"))
        #expect(missing.refreshedAt == nil)
        #expect(missing.sourceLabel == "bundled \(PricingCatalog.bundledDate)")
    }

    @Test func parsesModelsDevPayloadShapes() {
        // Live shape: root["anthropic"]["models"][id]["cost"].
        let live = #"{"anthropic":{"models":{"claude-sonnet-5":{"cost":{"input":2,"output":10,"cache_read":0.2,"cache_write":2.5}}}},"openai":{"models":{}}}"#
        let parsed = PricingCatalog.parseModelsDev(Data(live.utf8))
        #expect(parsed["claude-sonnet-5"]?.input == 2)
        #expect(parsed["claude-sonnet-5"]?.cacheWrite5m == 2.5)
        #expect(abs((parsed["claude-sonnet-5"]?.cacheWrite1h ?? 0) - 4.0) < 1e-9) // derived 2×
        // CodexBar cache wrapper: root["catalog"]["providers"]["anthropic"]….
        let wrapped = #"{"catalog":{"providers":{"anthropic":{"models":{"claude-opus-4-1-20250805":{"cost":{"input":15,"output":75,"cache_read":1.5,"cache_write":18.75}}}}}},"version":1}"#
        let parsed2 = PricingCatalog.parseModelsDev(Data(wrapped.utf8))
        // Keyed NORMALIZED (date stamp stripped).
        #expect(parsed2["claude-opus-4-1"]?.input == 15)
        // Garbage → empty, never a crash.
        #expect(PricingCatalog.parseModelsDev(Data("not json".utf8)).isEmpty)
    }
}

// MARK: - Per-model accumulation end-to-end

@Suite("Per-model accumulation")
struct PerModelAccumulationTests {

    private func asst(model: String, day: String, id: String, input: Int,
                      cc: Int = 0, cc1h: Int = 0, output: Int = 0) -> String {
        let cacheCreation = cc1h > 0
            ? #","cache_creation":{"ephemeral_5m_input_tokens":\#(cc - cc1h),"ephemeral_1h_input_tokens":\#(cc1h)}"#
            : ""
        return #"{"type":"assistant","requestId":"r-\#(id)","timestamp":"\#(day)T10:00:00.000Z","message":{"id":"m-\#(id)","model":"\#(model)","usage":{"input_tokens":\#(input),"output_tokens":\#(output),"cache_creation_input_tokens":\#(cc),"cache_read_input_tokens":0\#(cacheCreation)}}}"#
    }

    @Test func accumulatorRecordsNormalizedModelAnd1hSlice() {
        // A provider-prefixed opus message with a 1h cache-write slice, and a
        // sonnet-5 message — usageByModel must key NORMALIZED ids and carry the
        // 1h split through to the summary.
        let l1 = asst(model: "us.anthropic.claude-opus-4-8", day: "2026-07-05", id: "a",
                      input: 100_000, cc: 500_000, cc1h: 300_000)
        let l2 = asst(model: "claude-sonnet-5", day: "2026-07-05", id: "b", input: 50_000)
        var acc = SessionAccumulator(defaultID: "fb")
        acc.ingest(Data((l1 + "\n" + l2 + "\n").utf8))
        let s = acc.summary(filePath: "/x.jsonl")

        #expect(Set(s.usageByModel.keys) == ["claude-opus-4-8", "claude-sonnet-5"])
        let opus = s.usageByModel["claude-opus-4-8"]!
        #expect(opus.cacheCreateTokens == 500_000)
        #expect(opus.cacheCreate1hTokens == 300_000)
        #expect(opus.cacheCreate5mTokens == 200_000)
        // Day-keyed per-model map drives date-aware pricing.
        #expect(s.usageByModelDay["2026-07-05"]?["claude-sonnet-5"]?.inputTokens == 50_000)
        // Tier view still works for display grouping.
        #expect(s.usageByTier[.opus]?.cacheCreate1hTokens == 300_000)
    }

    @Test func sessionCostPricesEachModelDaySliceAtItsCatalogRate() {
        // opus-4-8 on 07-05: 100k fresh ($0.50) + cw5m 200k ($1.25) + cw1h 300k ($3.00) = $4.75
        // sonnet-5 on 07-05 (INTRO era): 1M fresh × $2 = $2.00  ← tier table said $3
        let l1 = asst(model: "claude-opus-4-8", day: "2026-07-05", id: "a",
                      input: 100_000, cc: 500_000, cc1h: 300_000)
        let l2 = asst(model: "claude-sonnet-5", day: "2026-07-05", id: "b", input: 1_000_000)
        var acc = SessionAccumulator(defaultID: "fb")
        acc.ingest(Data((l1 + "\n" + l2 + "\n").utf8))
        let s = acc.summary(filePath: "/x.jsonl")
        #expect(abs(s.cost - (4.75 + 2.00)) < 0.0001)
        #expect(abs(s.cost(onDay: "2026-07-05") - 6.75) < 0.0001)
        // The same sonnet-5 message dated after 2026-09-01 bills $3/M.
        let l3 = asst(model: "claude-sonnet-5", day: "2026-09-02", id: "c", input: 1_000_000)
        var acc2 = SessionAccumulator(defaultID: "fb")
        acc2.ingest(Data((l3 + "\n").utf8))
        #expect(abs(acc2.summary(filePath: "/y.jsonl").cost - 3.00) < 0.0001)
    }

    @Test func opus41PricesAtDeprecatedRateNotTierRate() {
        // The flat tier table billed EVERY opus at $5/$25; opus-4-1 is $15/$75.
        let line = asst(model: "claude-opus-4-1", day: "2026-07-05", id: "a",
                        input: 1_000_000, output: 100_000)
        var acc = SessionAccumulator(defaultID: "fb")
        acc.ingest(Data((line + "\n").utf8))
        // 1M × $15 + 0.1M × $75 = 15 + 7.5 = 22.50 (tier table would say 5 + 2.5 = 7.50).
        #expect(abs(acc.summary(filePath: "/x.jsonl").cost - 22.50) < 0.0001)
    }

    @Test func unknownModelSessionKeepsTierFallbackPricing() {
        let line = asst(model: "glm-4.7", day: "2026-07-05", id: "a", input: 1_000_000)
        var acc = SessionAccumulator(defaultID: "fb")
        acc.ingest(Data((line + "\n").utf8))
        let s = acc.summary(filePath: "/x.jsonl")
        // "other" tier fallback: $5/M input — unchanged from pre-W2.
        #expect(abs(s.cost - 5.0) < 0.0001)
        #expect(s.usageByModel["glm-4.7"] != nil)
    }

    @Test func perTierCostMapGroupsModelPricedCostsIntoTiers() {
        // sonnet-5 ($2/M intro) + sonnet-4-6 ($3/M) both land in the .sonnet
        // display tier but are priced at their OWN rates: 1M×2 + 1M×3 = $5.
        let l1 = asst(model: "claude-sonnet-5", day: "2026-07-05", id: "a", input: 1_000_000)
        let l2 = asst(model: "claude-sonnet-4-6", day: "2026-07-05", id: "b", input: 1_000_000)
        var acc = SessionAccumulator(defaultID: "fb")
        acc.ingest(Data((l1 + "\n" + l2 + "\n").utf8))
        let s = acc.summary(filePath: "/x.jsonl")
        #expect(abs((s.perTierCostMap[.sonnet] ?? 0) - 5.0) < 0.0001)
        // The flat tier table would have said 2M × $3 = $6.
    }
}
