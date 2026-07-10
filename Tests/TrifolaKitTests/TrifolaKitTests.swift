import Foundation
import Testing
@testable import TrifolaKit

// MARK: - Helpers

private func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("mck-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private let userLine = #"{"type":"user","cwd":"/tmp/proj-x","sessionId":"abc-123-def-456","timestamp":"2026-01-01T10:00:00.000Z","message":{"content":"hello"}}"#
private let asst1 = #"{"type":"assistant","timestamp":"2026-01-01T10:00:05.000Z","message":{"model":"claude-sonnet-5","usage":{"input_tokens":100,"output_tokens":50,"cache_creation_input_tokens":1000,"cache_read_input_tokens":2000}}}"#
private let asst2 = #"{"type":"assistant","timestamp":"2026-01-01T10:00:09.000Z","message":{"model":"claude-sonnet-5","usage":{"input_tokens":200,"output_tokens":80,"cache_creation_input_tokens":0,"cache_read_input_tokens":5000}}}"#

// A three-message, two-model session where the LAST responder (opus) is NOT
// the DOMINANT one by billed tokens (sonnet, 1500 vs opus's 150 combined) —
// the exact shape that exposed the "tag the whole session with the last
// model" bug.
private let asstOpusSmall1 = #"{"type":"assistant","timestamp":"2026-01-01T10:00:01.000Z","message":{"model":"claude-opus-4-8","usage":{"input_tokens":50,"output_tokens":25,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
private let asstSonnetBig = #"{"type":"assistant","timestamp":"2026-01-01T10:00:02.000Z","message":{"model":"claude-sonnet-5","usage":{"input_tokens":1000,"output_tokens":500,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
private let asstOpusSmall2 = #"{"type":"assistant","timestamp":"2026-01-01T10:00:03.000Z","message":{"model":"claude-opus-4-8","usage":{"input_tokens":50,"output_tokens":25,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#

// Three STREAMING chunks of ONE assistant message — same message.id + requestId,
// each carrying the running CUMULATIVE usage (input 10 → 20 → 30). Claude Code
// writes these as separate JSONL lines; summing them (the old bug) counted 60 not
// the true 30. `streamB` is a DISTINCT message (its own id/reqId) at input 7.
private let streamA1 = #"{"type":"assistant","requestId":"req-1","timestamp":"2026-01-01T10:00:01.000Z","message":{"id":"msg-1","model":"claude-opus-4-8","usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
private let streamA2 = #"{"type":"assistant","requestId":"req-1","timestamp":"2026-01-01T10:00:02.000Z","message":{"id":"msg-1","model":"claude-opus-4-8","usage":{"input_tokens":20,"output_tokens":10,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
private let streamA3 = #"{"type":"assistant","requestId":"req-1","timestamp":"2026-01-01T10:00:03.000Z","message":{"id":"msg-1","model":"claude-opus-4-8","usage":{"input_tokens":30,"output_tokens":15,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
private let streamB = #"{"type":"assistant","requestId":"req-2","timestamp":"2026-01-01T10:00:04.000Z","message":{"id":"msg-2","model":"claude-opus-4-8","usage":{"input_tokens":7,"output_tokens":3,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#

// MARK: - Tiers & rates

@Suite("Model tiers")
struct TierTests {
    @Test func rawMapping() {
        #expect(ModelTier(raw: "claude-opus-4-8") == .opus)
        #expect(ModelTier(raw: "claude-sonnet-5") == .sonnet)
        #expect(ModelTier(raw: "claude-haiku-4-5-20251001") == .haiku)
        #expect(ModelTier(raw: "gpt-oss") == .other)
        #expect(ModelTier(raw: nil) == .other)
        #expect(ModelTier(raw: "CLAUDE-OPUS-4-8") == .opus)   // case-insensitive
    }

    @Test func rates() {
        #expect(ModelTier.opus.rates == (5, 25))
        #expect(ModelTier.sonnet.rates == (3, 15))
        #expect(ModelTier.haiku.rates == (1, 5))
    }

    @Test func userTierIsOptionalAndConfigurable() {
        // Unset, `.user` is never matched by init(raw:).
        ModelTier.configureUserTier(nil)
        #expect(ModelTier(raw: "acme-model-1") == .other)
        // Configured, matching ids route into the user tier with its rate/label.
        ModelTier.configureUserTier(.init(match: "acme", label: "Acme", rate: (2, 8)))
        #expect(ModelTier(raw: "acme-model-1") == .user)
        #expect(ModelTier.user.rates == (2, 8))
        #expect(ModelTier.user.label == "Acme")
        // Built-in tiers still win over a user match.
        #expect(ModelTier(raw: "claude-opus-4-8") == .opus)
        ModelTier.configureUserTier(nil)   // reset shared state for other tests
    }
}

// MARK: - Cost math

@Suite("Cost math")
struct CostTests {
    let usage = SessionUsage(inputTokens: 1_000_000, outputTokens: 200_000,
                             cacheCreateTokens: 400_000, cacheReadTokens: 2_000_000)

    @Test func totals() {
        #expect(usage.totalInput == 3_400_000)
        #expect(usage.total == 3_600_000)
        #expect(usage.billedInput == 1_400_000)
    }

    @Test func addition() {
        let sum = usage + SessionUsage(inputTokens: 1, outputTokens: 2,
                                       cacheCreateTokens: 3, cacheReadTokens: 4)
        #expect(sum.inputTokens == 1_000_001)
        #expect(sum.outputTokens == 200_002)
        #expect(sum.cacheCreateTokens == 400_003)
        #expect(sum.cacheReadTokens == 2_000_004)
    }

    @Test func sonnetCost() {
        // fresh 1M×$3 + write 0.4M×$3×1.25 + read 2M×$3×0.10 + out 0.2M×$15
        // = 3.00 + 1.50 + 0.60 + 3.00 = 8.10
        #expect(abs(usage.cost(.sonnet) - 8.10) < 0.0001)
    }

    @Test func cacheSavings() {
        // Gross read discount $5.40 minus the 400k 5m-write premium $0.30.
        #expect(abs(usage.cacheSavings(.sonnet) - 5.10) < 0.0001)

        // Mixed 5m/1h writes: $5.40 gross − $0.075 (100k×$0.75/M)
        // − $0.90 (300k×$3/M) = $4.425 true net.
        let mixed = SessionUsage(cacheCreateTokens: 400_000, cacheReadTokens: 2_000_000,
                                 cacheCreate1hTokens: 300_000)
        #expect(abs(mixed.cacheSavings(.sonnet) - 4.425) < 0.0001)

        // A write-heavy slice stays negative; no per-slice floor hides it.
        let writeOnly = SessionUsage(cacheCreateTokens: 1_000_000,
                                     cacheCreate1hTokens: 1_000_000)
        #expect(abs(writeOnly.cacheSavings(.sonnet) - (-3.0)) < 0.0001)
    }

    @Test func cacheHitRate() {
        #expect(abs(usage.cacheHitRate - 2_000_000.0 / 3_400_000.0) < 0.0001)
        #expect(SessionUsage().cacheHitRate == 0)
    }

    @Test func zeroUsageCostsNothing() {
        #expect(SessionUsage().cost(.sonnet) == 0)
    }
}

// MARK: - Session summary derived values

@Suite("Session summary")
struct SummaryTests {
    private func make(model: String?, contextWeight: Int, last: Date?) -> SessionSummary {
        SessionSummary(id: "0123456789abcdef", project: "p", cwd: "/tmp/p", model: model,
                       lastActivity: last, messageCount: 10,
                       usage: SessionUsage(inputTokens: 1000), contextWeight: contextWeight)
    }

    @Test func derived() {
        let s = make(model: "claude-sonnet-5", contextWeight: 250_000, last: Date())
        #expect(s.tier == .sonnet)
        #expect(s.shortID == "01234567")
        #expect(s.isContextHeavy)
        // Sonnet 5 is date-dependent pricing: $2/M input through 2026-08-31,
        // $3/M from 2026-09-01 (Pricing.swift). costPerMessage resolves
        // against today, so pre-cutover: 250k × $2/M = $0.50 per trivial message.
        #expect(abs(s.costPerMessage - 0.50) < 0.0001)
        #expect(s.isActive)
    }

    @Test func staleness() {
        #expect(!make(model: nil, contextWeight: 0, last: Date(timeIntervalSinceNow: -16 * 60)).isActive)
        #expect(!make(model: nil, contextWeight: 0, last: nil).isActive)
        #expect(!make(model: nil, contextWeight: 200_000, last: nil).isContextHeavy) // boundary: strictly >
    }

    @Test func tierAndCostFallBackToWholeSessionWhenNoPerTierData() {
        // Summaries built without usageByTier (tests, synthetic sessions, and
        // any pre-upgrade cache entry) must behave exactly like the old
        // single-tier model: `tier` from the raw model string, `cost` from
        // pricing the whole usage at that tier.
        let s = make(model: "claude-opus-4-8", contextWeight: 0, last: nil)
        #expect(s.usageByTier.isEmpty)
        #expect(s.tier == .opus)
        #expect(s.perTierUsage == [.opus: s.usage])
        #expect(abs(s.cost - s.usage.cost(.opus)) < 0.0000001)
    }

    @Test func dominantTierPicksTheTierWithMostBilledTokensNotLastModel() {
        // model string says "opus" (whatever answered last), but usageByTier
        // says sonnet billed far more — dominant tier must follow the tokens.
        let s = SessionSummary(id: "id", project: "p", cwd: "/tmp/p", model: "claude-opus-4-8",
                               lastActivity: nil, messageCount: 2,
                               usage: SessionUsage(inputTokens: 1100, outputTokens: 550),
                               contextWeight: 0,
                               usageByTier: [
                                   .opus: SessionUsage(inputTokens: 100, outputTokens: 50),
                                   .sonnet: SessionUsage(inputTokens: 1000, outputTokens: 500)
                               ])
        #expect(s.tier == .sonnet)
        let expected = SessionUsage(inputTokens: 100, outputTokens: 50).cost(.opus)
                     + SessionUsage(inputTokens: 1000, outputTokens: 500).cost(.sonnet)
        #expect(abs(s.cost - expected) < 0.0000001)
    }
}

// MARK: - Per-tier spend attribution (SessionStore aggregation + routing audit)

@Suite("Tier attribution")
struct TierAttributionTests {
    /// A session whose ENTIRE usage bills under one tier.
    private func pureSession(id: String, tier: ModelTier, inputTokens: Int) -> SessionSummary {
        let u = SessionUsage(inputTokens: inputTokens)
        return SessionSummary(id: id, project: "p", cwd: "/tmp/p", model: tier.rawValue,
                              lastActivity: nil, messageCount: 1, usage: u, contextWeight: 0,
                              usageByTier: [tier: u])
    }

    /// A mixed session: `dominant` billed `dominantTokens`, `minor` billed
    /// `minorTokens` (dominant > minor), so `dominant` is the resolved tier
    /// but `minor`'s slice must still land in its OWN tier's aggregate.
    private func mixedSession(id: String, dominant: ModelTier, dominantTokens: Int,
                              minor: ModelTier, minorTokens: Int) -> SessionSummary {
        let dominantUsage = SessionUsage(inputTokens: dominantTokens)
        let minorUsage = SessionUsage(inputTokens: minorTokens)
        return SessionSummary(id: id, project: "p", cwd: "/tmp/p", model: dominant.rawValue,
                              lastActivity: nil, messageCount: 2,
                              usage: dominantUsage + minorUsage, contextWeight: 0,
                              usageByTier: [dominant: dominantUsage, minor: minorUsage])
    }

    @Test func aggregateTiersAttributesMixedSessionSliceToItsOwnTier() {
        let a = pureSession(id: "a", tier: .opus, inputTokens: 1_000_000)      // cost 5
        let b = pureSession(id: "b", tier: .sonnet, inputTokens: 1_000_000)    // cost 3
        let c = mixedSession(id: "c", dominant: .opus, dominantTokens: 1_000_000,
                             minor: .sonnet, minorTokens: 100_000)             // cost 5 + 0.3 = 5.3

        let stats = SessionStore.aggregateTiers([a, b, c])
        let opus = stats.first { $0.tier == .opus }
        let sonnet = stats.first { $0.tier == .sonnet }

        // sessions counted once, under their DOMINANT tier: a + c → opus (2),
        // b → sonnet (1). c's sonnet slice does NOT bump sonnet's session count.
        #expect(opus?.sessions == 2)
        #expect(sonnet?.sessions == 1)

        // tokens/cost attributed to the tier that actually billed them.
        #expect(opus?.tokens == 2_000_000)          // a's 1M + c's opus 1M
        #expect(sonnet?.tokens == 1_100_000)         // b's 1M + c's sonnet 100k
        #expect(abs((opus?.cost ?? 0) - 10) < 0.0001)    // 5 + 5
        #expect(abs((sonnet?.cost ?? 0) - 3.3) < 0.0001) // 3 + 0.3

        // no session's whole pile silently lands on one tier: total across
        // tiers must equal the sum of each session's own (per-tier) cost.
        let totalFromStats = stats.reduce(0.0) { $0 + $1.cost }
        let totalFromSessions = [a, b, c].reduce(0.0) { $0 + $1.cost }
        #expect(abs(totalFromStats - totalFromSessions) < 0.0001)
    }

    @Test func routingAuditOpusPercentExcludesOtherTiersSliceOfMixedSessions() {
        // Opus tokens are 2M so Opus is a MAJORITY of spend and the >50% flag fires.
        let a = pureSession(id: "a", tier: .opus, inputTokens: 2_000_000)      // cost 10
        let b = pureSession(id: "b", tier: .sonnet, inputTokens: 1_000_000)    // cost 3
        let c = mixedSession(id: "c", dominant: .opus, dominantTokens: 2_000_000,
                             minor: .sonnet, minorTokens: 100_000)             // cost 10 + 0.3 = 10.3
        // total = 23.3, correct opus-only spend = 20 (Int(20/23.3*100)=85%); the old
        // bug summed whole-session cost for every dominant-opus session (a + c = 20.3, 87%).
        let flags = RoutingAudit.computeFlags(defaultModel: "claude-sonnet-5", sessions: [a, b, c])
        #expect(flags.contains { $0.title == "Opus is 85% of all-time spend" })
        #expect(!flags.contains { $0.title.contains("87%") })
    }
}

// MARK: - Formatting

@Suite("Formatting")
struct FormatTests {
    @Test func tokens() {
        #expect(fmtTokens(950) == "950")
        #expect(fmtTokens(1_500) == "1.5k")
        #expect(fmtTokens(2_500_000) == "2.5M")
        #expect(fmtTokens(3_100_000_000) == "3.1B")
    }

    @Test func usd() {
        #expect(fmtUSD(0.5) == "$0.50")
        #expect(fmtUSD(12) == "$12")
        #expect(fmtUSD(1_234) == "$1.2k")
    }

    @Test func pctAndAgo() {
        #expect(fmtPct(0.853) == "85%")
        #expect(fmtAgo(nil) == "—")
        #expect(fmtAgo(Date(timeIntervalSinceNow: -5)).hasSuffix("s ago"))
        #expect(fmtAgo(Date(timeIntervalSinceNow: -3 * 3600)) == "3h ago")
    }
}

// MARK: - Accumulator (transcript aggregation)

@Suite("Session accumulator")
struct AccumulatorTests {
    @Test func wholeFile() {
        var acc = SessionAccumulator(defaultID: "fallback")
        acc.ingest(Data((userLine + "\n" + asst1 + "\n" + asst2 + "\n").utf8))
        let s = acc.summary(filePath: "/x.jsonl")

        #expect(s.id == "abc-123-def-456")
        #expect(s.project == "proj-x")
        #expect(s.cwd == "/tmp/proj-x")
        #expect(s.tier == .sonnet)
        #expect(s.messageCount == 3)
        #expect(s.usage.inputTokens == 300)
        #expect(s.usage.outputTokens == 130)
        #expect(s.usage.cacheCreateTokens == 1000)
        #expect(s.usage.cacheReadTokens == 7000)
        // context weight = what the LAST message resent: 200 + 0 + 5000
        #expect(s.contextWeight == 5200)
        #expect(s.lastActivity != nil)
        #expect(s.filePath == "/x.jsonl")
        #expect(s.lastUserMessage == "hello")
    }

    @Test func chunkedMidLine() {
        // Split the byte stream mid-way through asst1 — accumulation must be identical.
        let full = Data((userLine + "\n" + asst1 + "\n" + asst2 + "\n").utf8)
        let cut = userLine.utf8.count + 40
        var acc = SessionAccumulator(defaultID: "fallback")
        acc.ingest(full.prefix(cut))
        acc.ingest(full.suffix(full.count - cut))
        let s = acc.summary(filePath: "")
        #expect(s.messageCount == 3)
        #expect(s.usage.cacheReadTokens == 7000)
        #expect(s.contextWeight == 5200)
    }

    @Test func pendingLineParsedProvisionally() {
        // No trailing newline: the last line still counts in the summary snapshot,
        // but resumeOffset stays before it so a later append can re-deliver safely.
        var acc = SessionAccumulator(defaultID: "fallback")
        acc.ingest(Data((userLine + "\n" + asst1).utf8))
        #expect(acc.summary(filePath: "").messageCount == 2)
        #expect(acc.resumeOffset == UInt64(userLine.utf8.count + 1))
    }

    @Test func garbageLinesIgnored() {
        var acc = SessionAccumulator(defaultID: "fb")
        acc.ingest(Data("this is not json\n\n{\"type\":\"unknown\"}\n".utf8))
        let s = acc.summary(filePath: "")
        #expect(s.id == "fb")
        #expect(s.messageCount == 1)   // the valid-but-unknown JSON line counts
        #expect(s.usage.total == 0)
    }

    @Test func malformedTokenFieldsAreClampedBeforeUsageConstruction() {
        let negative = #"{"type":"assistant","requestId":"r-neg","message":{"id":"m-neg","model":"claude-opus-4-8","usage":{"input_tokens":-10,"output_tokens":-20,"cache_creation_input_tokens":-30,"cache_read_input_tokens":-40,"cache_creation":{"ephemeral_1h_input_tokens":-50}}}}"#
        let oversized = #"{"type":"assistant","requestId":"r-big","message":{"id":"m-big","model":"claude-opus-4-8","usage":{"input_tokens":1,"output_tokens":2,"cache_creation_input_tokens":100,"cache_read_input_tokens":3,"cache_creation":{"ephemeral_1h_input_tokens":900}}}}"#
        var acc = SessionAccumulator(defaultID: "fb")
        acc.ingest(Data((negative + "\n" + oversized + "\n").utf8))
        let u = acc.summary(filePath: "").usage
        #expect(u.inputTokens == 1)
        #expect(u.outputTokens == 2)
        #expect(u.cacheCreateTokens == 100)
        #expect(u.cacheReadTokens == 3)
        #expect(u.cacheCreate1hTokens == 100)
    }

    @Test func nonstandardPricingModesAreCountedAfterDedup() {
        let standard = #"{"type":"assistant","requestId":"r-std","message":{"id":"m-std","model":"claude-opus-4-8","usage":{"input_tokens":1,"speed":"standard"}}}"#
        let fastFirstChunk = #"{"type":"assistant","requestId":"r-fast","message":{"id":"m-fast","model":"claude-opus-4-8","usage":{"input_tokens":1,"speed":"fast"}}}"#
        let fastLastChunk = #"{"type":"assistant","requestId":"r-fast","message":{"id":"m-fast","model":"claude-opus-4-8","usage":{"input_tokens":2,"service_tier":"batch"}}}"#
        var acc = SessionAccumulator(defaultID: "fb")
        acc.ingest(Data((standard + "\n" + fastFirstChunk + "\n" + fastLastChunk + "\n").utf8))
        let summary = acc.summary(filePath: "")
        #expect(summary.unsupportedPricingEntryCount == 1)
        #expect(summary.usage.inputTokens == 3)
    }

    @Test func lastUserMessageTracksMostRecentRealPrompt() {
        // A real (string-content) prompt, then an automatic tool_result
        // continuation, then an isMeta image-dimensions reminder: the tracked
        // "last user message" should stay pinned to the real typed prompt,
        // not be clobbered by either follow-up "user"-typed line.
        let firstPrompt = #"{"type":"user","message":{"content":"fix the login bug"}}"#
        let toolResultContinuation = #"{"type":"user","message":{"content":[{"tool_use_id":"t1","type":"tool_result","content":"ls output here"}]}}"#
        let metaImageNote = #"{"type":"user","isMeta":true,"message":{"content":"[Image: dims note]"}}"#
        var acc = SessionAccumulator(defaultID: "fb")
        acc.ingest(Data((firstPrompt + "\n" + toolResultContinuation + "\n" + metaImageNote + "\n").utf8))
        #expect(acc.summary(filePath: "").lastUserMessage == "fix the login bug")
    }

    @Test func lastUserMessageSkipsCompactionSummary() {
        // On auto-compact, Claude Code injects a giant "This session is being
        // continued…" user message flagged isCompactSummary (+ isVisibleInTranscriptOnly),
        // NOT isMeta. It must never become lastUserMessage: it would poison any
        // session-transport match that fingerprints a session by its last real
        // prompt. This was the actual "resuming a session opened a stale tab"
        // bug on long sessions.
        let realPrompt = #"{"type":"user","message":{"content":"open the settings please"}}"#
        let compaction = #"{"type":"user","isCompactSummary":true,"isVisibleInTranscriptOnly":true,"message":{"content":"This session is being continued from a previous conversation that ran out of context. The summary below covers the earlier portion."}}"#
        var acc = SessionAccumulator(defaultID: "fb")
        acc.ingest(Data((realPrompt + "\n" + compaction + "\n").utf8))
        #expect(acc.summary(filePath: "").lastUserMessage == "open the settings please")
    }

    @Test func lastUserMessageExtractsTextBlockArray() {
        // content as an array of blocks: only "text" blocks count, and a later
        // real prompt overwrites an earlier one.
        let older = #"{"type":"user","message":{"content":[{"type":"text","text":"first prompt"}]}}"#
        let newer = #"{"type":"user","message":{"content":[{"type":"text","text":"second prompt"}]}}"#
        var acc = SessionAccumulator(defaultID: "fb")
        acc.ingest(Data((older + "\n" + newer + "\n").utf8))
        #expect(acc.summary(filePath: "").lastUserMessage == "second prompt")
    }

    @Test func lastUserMessageNilWhenNoRealPromptSeen() {
        var acc = SessionAccumulator(defaultID: "fb")
        acc.ingest(Data((asst1 + "\n").utf8))
        #expect(acc.summary(filePath: "").lastUserMessage == nil)
    }

    @Test func mixedModelSessionAttributesUsagePerMessageNotLastResponder() {
        // opus(small) → sonnet(huge) → opus(small): the LAST message is opus,
        // but sonnet billed 10x the tokens. The old bug tagged the whole
        // session with the last model and priced every token at its rate;
        // the fix must bucket each message's usage under its OWN model.
        var acc = SessionAccumulator(defaultID: "fb")
        acc.ingest(Data((asstOpusSmall1 + "\n" + asstSonnetBig + "\n" + asstOpusSmall2 + "\n").utf8))
        let s = acc.summary(filePath: "")

        #expect(s.usageByTier[.opus] == SessionUsage(inputTokens: 100, outputTokens: 50))
        #expect(s.usageByTier[.sonnet] == SessionUsage(inputTokens: 1000, outputTokens: 500))
        // dominant tier = sonnet (1500 billed tokens) even though opus answered last.
        #expect(s.tier == .sonnet)
        // each (model, day) slice priced at its OWN catalog rate and summed —
        // NOT the whole 1100/550 token pile priced at the last responder's
        // (opus) rate, and NOT the sonnet slice priced at the ModelTier flat
        // fallback (3, 15): claude-sonnet-5 is date-dependent pricing and on
        // 2026-01-01 (the fixture's timestamp, pre-2026-09-01 cutover) the
        // catalog rate is (2, 10), not the tier fallback.
        let sonnetRate = PricingCatalog.current.resolvedRate(model: "claude-sonnet-5", onDay: "2026-01-01")
        let expected = SessionUsage(inputTokens: 100, outputTokens: 50).cost(.opus)
                     + SessionUsage(inputTokens: 1000, outputTokens: 500).cost(rate: sonnetRate)
        #expect(abs(s.cost - expected) < 0.0000001)
        // sanity: the buggy whole-pile-at-last-model-rate number is materially
        // different, so this assertion would fail under the old behavior.
        let buggyCost = s.usage.cost(.opus)
        #expect(abs(s.cost - buggyCost) > 0.01)
    }

    // THE flagship correctness fix: Claude Code writes several streaming lines per
    // assistant message, each sharing message.id + requestId and carrying the
    // running CUMULATIVE usage. The accumulator must keep the LAST chunk per key,
    // not SUM them (which over-counted spend ~2.6x on real data).
    @Test func streamingChunksSharingIdDedupToLastCumulativeChunk() {
        var acc = SessionAccumulator(defaultID: "fb")
        acc.ingest(Data((streamA1 + "\n" + streamA2 + "\n" + streamA3 + "\n" + streamB + "\n").utf8))
        let s = acc.summary(filePath: "")
        // msg-1's three cumulative chunks (10/20/30) collapse to the LAST (30);
        // msg-2 is distinct (7). Total = 30 + 7 = 37 input — NOT the summed
        // 10+20+30+7 = 67. Output: 15 + 3 = 18, NOT 5+10+15+3 = 33.
        #expect(s.usage.inputTokens == 37)
        #expect(s.usage.outputTokens == 18)
        // usageByTier reflects the SAME deduped set (all opus here).
        #expect(s.usageByTier[.opus] == SessionUsage(inputTokens: 37, outputTokens: 18))
        // Explicit guard against a regression to the old summed value.
        #expect(s.usage.inputTokens != 67)
        // Priced cost tracks the deduped tokens, not the inflated sum.
        #expect(abs(s.cost - SessionUsage(inputTokens: 37, outputTokens: 18).cost(.opus)) < 1e-9)
    }

    // Dedup composes with the incremental tail-append: a streaming message whose
    // chunks straddle an append boundary still collapses to its last cumulative
    // chunk (the per-key map is carried in accumulator state across the append).
    @Test func streamingDedupSurvivesIncrementalAppend() {
        var acc = SessionAccumulator(defaultID: "fb")
        acc.ingest(Data((streamA1 + "\n" + streamA2 + "\n").utf8))   // first two chunks
        acc.ingest(Data((streamA3 + "\n" + streamB + "\n").utf8))    // final chunk + distinct msg
        let s = acc.summary(filePath: "")
        #expect(s.usage.inputTokens == 37)
        #expect(s.usage.outputTokens == 18)
    }

    // Per-message-DAY bucketing: two distinct messages on different timestamp days
    // land in separate `usageByDay` buckets (the burn governor's honesty input).
    @Test func usageByDayBucketsEachMessageOnItsOwnTimestampDay() {
        // 24h apart → different LOCAL calendar days in every time zone.
        let day1 = #"{"type":"assistant","requestId":"r1","timestamp":"2026-01-01T10:00:00.000Z","message":{"id":"m1","model":"claude-opus-4-8","usage":{"input_tokens":100,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
        let day2 = #"{"type":"assistant","requestId":"r2","timestamp":"2026-01-02T10:00:00.000Z","message":{"id":"m2","model":"claude-opus-4-8","usage":{"input_tokens":200,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
        var acc = SessionAccumulator(defaultID: "fb")
        acc.ingest(Data((day1 + "\n" + day2 + "\n").utf8))
        let s = acc.summary(filePath: "")
        // Two distinct days, each with exactly its own message's usage.
        #expect(s.usageByDay.count == 2)
        let inputs = s.usageByDay.values.flatMap { $0.values }.map(\.inputTokens).sorted()
        #expect(inputs == [100, 200])
        // Every day bucket is opus, and each day's cost is its own message's cost.
        let costs = s.usageByDay.keys.map { s.cost(onDay: $0) }.sorted()
        #expect(abs(costs[0] - SessionUsage(inputTokens: 100).cost(.opus)) < 1e-9)
        #expect(abs(costs[1] - SessionUsage(inputTokens: 200).cost(.opus)) < 1e-9)
    }
}

// MARK: - Incremental index

@Suite("Session index (incremental scan)")
struct IndexTests {
    @Test func timezoneIdentityChangesDayKeysAndInvalidatesPersistedIndex() throws {
        let utc = try #require(TimeZone(identifier: "UTC"))
        let kolkata = try #require(TimeZone(identifier: "Asia/Kolkata"))
        let instant = try #require(ISO8601DateFormatter().date(from: "2026-07-04T23:30:00Z"))
        #expect(localDayKey(instant, timeZone: utc) == "2026-07-04")
        #expect(localDayKey(instant, timeZone: kolkata) == "2026-07-05")

        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let transcript = dir.appendingPathComponent("session.jsonl")
        try (asst1 + "\n").write(to: transcript, atomically: true, encoding: .utf8)
        let index = SessionIndex.update(SessionIndex(), dir: dir)
        let cache = dir.appendingPathComponent("session-index.json")
        SessionStore.saveIndexCache(index, to: cache, timeZone: utc)
        #expect(SessionStore.loadIndexCache(from: cache, timeZone: utc) != nil)
        #expect(SessionStore.loadIndexCache(from: cache, timeZone: kolkata) == nil)
    }

    @Test func incrementalAppendMatchesFullParse() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let proj = dir.appendingPathComponent("p")
        try FileManager.default.createDirectory(at: proj, withIntermediateDirectories: true)
        let file = proj.appendingPathComponent("sess.jsonl")

        try (userLine + "\n" + asst1 + "\n").write(to: file, atomically: true, encoding: .utf8)
        let first = SessionIndex.update(SessionIndex(), dir: dir)
        #expect(first.summaries.count == 1)
        #expect(first.summaries[0].messageCount == 2)

        // append one more assistant turn → only the tail should be parsed
        let fh = try FileHandle(forWritingTo: file)
        try fh.seekToEnd()
        try fh.write(contentsOf: Data((asst2 + "\n").utf8))
        try fh.close()

        let second = SessionIndex.update(first, dir: dir)
        let s = second.summaries[0]
        #expect(s.messageCount == 3)
        #expect(s.usage.cacheReadTokens == 7000)
        #expect(s.contextWeight == 5200)

        // must be byte-identical to a cold full parse
        var cold = SessionAccumulator(defaultID: "sess")
        cold.ingest(try Data(contentsOf: file))
        #expect(cold.summary(filePath: file.path).usage == s.usage)
    }

    @Test func unchangedFileIsReused() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("a.jsonl")
        try (userLine + "\n").write(to: file, atomically: true, encoding: .utf8)
        let first = SessionIndex.update(SessionIndex(), dir: dir)
        let second = SessionIndex.update(first, dir: dir)
        #expect(second.summaries.count == 1)
        #expect(second.summaries[0].messageCount == 1)
    }

    @Test func shrunkFileReparsesFully() throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("b.jsonl")
        try (userLine + "\n" + asst1 + "\n").write(to: file, atomically: true, encoding: .utf8)
        let first = SessionIndex.update(SessionIndex(), dir: dir)
        #expect(first.summaries[0].messageCount == 2)

        try (userLine + "\n").write(to: file, atomically: true, encoding: .utf8)
        let second = SessionIndex.update(first, dir: dir)
        #expect(second.summaries[0].messageCount == 1)
        #expect(second.summaries[0].usage.total == 0)
    }
}

// MARK: - Transcript parser

@Suite("Transcript parser")
struct ParserTests {
    private func parse(_ json: String) -> [TranscriptEvent] {
        TranscriptParser.events(fromLine: Data(json.utf8), fallbackID: "fb")
    }

    @Test func userString() {
        let evs = parse(#"{"type":"user","uuid":"u1","message":{"content":"fix the bug"}}"#)
        #expect(evs.count == 1)
        #expect(evs[0].kind == .userPrompt("fix the bug"))
        #expect(evs[0].id == "u1")
    }

    @Test func assistantBlocks() {
        let evs = parse(#"{"type":"assistant","uuid":"a1","message":{"content":[{"type":"thinking","thinking":"hmm"},{"type":"text","text":"done"},{"type":"tool_use","name":"Bash","input":{"command":"swift build"}}]}}"#)
        #expect(evs.count == 3)
        #expect(evs[0].kind == .thinking("hmm"))
        #expect(evs[1].kind == .assistantText("done"))
        #expect(evs[2].kind == .toolUse(name: "Bash", detail: "swift build"))
        #expect(evs[2].id == "a1-2")
    }

    @Test func toolResultError() {
        let evs = parse(#"{"type":"user","message":{"content":[{"type":"tool_result","is_error":true,"content":"boom"}]}}"#)
        #expect(evs.count == 1)
        #expect(evs[0].kind == .toolResult(preview: "boom", isError: true))
    }

    @Test func systemAndSummary() {
        #expect(parse(#"{"type":"system","subtype":"turn_limit","content":"limit hit"}"#).count == 1)
        let sum = parse(#"{"type":"summary","summary":"Fixed the parser"}"#)
        #expect(sum.first?.kind == .summary("Fixed the parser"))
    }

    @Test func noiseIsDropped() {
        #expect(parse(#"{"type":"user","isMeta":true,"message":{"content":"meta"}}"#).isEmpty)
        #expect(parse(#"{"type":"file-history-snapshot"}"#).isEmpty)
        #expect(parse("not json").isEmpty)
        #expect(parse(#"{"type":"assistant","message":{"content":[{"type":"text","text":"   "}]}}"#).isEmpty)
    }

    @Test func sidechainFlag() {
        let evs = parse(#"{"type":"user","isSidechain":true,"message":{"content":"sub"}}"#)
        #expect(evs.first?.isSidechain == true)
    }

    @Test func toolDetailShapes() {
        #expect(TranscriptParser.toolDetail(name: "Bash", input: ["command": "ls -la"]) == "ls -la")
        #expect(TranscriptParser.toolDetail(name: "TaskUpdate",
                                            input: ["taskId": "4", "status": "completed"]) == "#4 → completed")
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let d = TranscriptParser.toolDetail(name: "Read", input: ["file_path": home + "/x.txt"])
        #expect(d == "~/x.txt")
    }
}

// MARK: - Credit-era burn governor (VISION 2.5)

@Suite("Burn governor")
struct BurnGovernorTests {

    // A fixed UTC calendar so start-of-day bucketing is deterministic everywhere.
    private static func utc() -> Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    private static func at(_ cal: Calendar, _ y: Int, _ m: Int, _ d: Int, hour: Int = 12) -> Date {
        var comps = DateComponents()
        comps.year = y; comps.month = m; comps.day = d; comps.hour = hour
        return cal.date(from: comps)!
    }
    private static func burnSession(_ id: String, _ tier: ModelTier, at: Date?,
                                    input: Int, output: Int = 0) -> SessionSummary {
        let u = SessionUsage(inputTokens: input, outputTokens: output)
        return SessionSummary(id: id, project: "p", cwd: "/tmp/p", model: tier.rawValue,
                              lastActivity: at, messageCount: 1, usage: u, contextWeight: 0,
                              usageByTier: [tier: u])
    }

    // Fixture: sessions dated across a 30-day window ending 2026-06-30, plus one
    // session OUTSIDE the window and one with no date — both must be ignored.
    @Test func bucketsCostByLastActivityDay() {
        let cal = Self.utc()
        let now = Self.at(cal, 2026, 6, 30)

        let opusToday = Self.burnSession("t-opus", .opus, at: Self.at(cal, 2026, 6, 30, hour: 9), input: 1_000_000)
        let sonnetToday = Self.burnSession("t-son", .sonnet, at: Self.at(cal, 2026, 6, 30, hour: 15), input: 2_000_000)
        let sonnetYesterday = Self.burnSession("y-son", .sonnet, at: Self.at(cal, 2026, 6, 29, hour: 20), input: 500_000)
        let opusMid = Self.burnSession("m-opus", .opus, at: Self.at(cal, 2026, 6, 15), input: 3_000_000)
        let outside = Self.burnSession("old", .opus, at: Self.at(cal, 2026, 5, 20), input: 9_000_000)
        let dateless = Self.burnSession("nil", .opus, at: nil, input: 9_000_000)

        let gov = BurnGovernor(
            sessions: [opusToday, sonnetToday, sonnetYesterday, opusMid, outside, dateless],
            now: now, window: 30, calendar: cal)

        // Gap-filled: exactly `window` contiguous days, last == today.
        #expect(gov.days.count == 30)
        #expect(cal.isDate(gov.days.last!.day, inSameDayAs: Self.at(cal, 2026, 6, 30)))
        #expect(cal.isDate(gov.days.first!.day, inSameDayAs: Self.at(cal, 2026, 6, 1)))

        // Today's bucket: two sessions, cost priced per tier.
        let costOpusToday = SessionUsage(inputTokens: 1_000_000).cost(.opus)
        let costSonToday = SessionUsage(inputTokens: 2_000_000).cost(.sonnet)
        #expect(gov.today.sessions == 2)
        #expect(abs(gov.today.cost - (costOpusToday + costSonToday)) < 1e-9)
        #expect(abs(gov.today.opusShare - costOpusToday / (costOpusToday + costSonToday)) < 1e-9)
        // Per-tier day mix.
        #expect(abs((gov.today.byTier[.opus] ?? 0) - costOpusToday) < 1e-9)
        #expect(abs((gov.today.byTier[.sonnet] ?? 0) - costSonToday) < 1e-9)

        // Yesterday (06-29) and the mid-window day (06-15).
        let d29 = gov.days.first { cal.isDate($0.day, inSameDayAs: Self.at(cal, 2026, 6, 29)) }!
        #expect(d29.sessions == 1)
        #expect(abs(d29.cost - SessionUsage(inputTokens: 500_000).cost(.sonnet)) < 1e-9)
        let d15 = gov.days.first { cal.isDate($0.day, inSameDayAs: Self.at(cal, 2026, 6, 15)) }!
        #expect(d15.sessions == 1)
        #expect(abs(d15.cost - SessionUsage(inputTokens: 3_000_000).cost(.opus)) < 1e-9)

        // A quiet in-window day is a real zero, not a missing gap.
        let d10 = gov.days.first { cal.isDate($0.day, inSameDayAs: Self.at(cal, 2026, 6, 10)) }!
        #expect(d10.cost == 0)
        #expect(d10.sessions == 0)

        // Out-of-window + dateless sessions are excluded from the window total.
        let inWindow = costOpusToday + costSonToday
            + SessionUsage(inputTokens: 500_000).cost(.sonnet)
            + SessionUsage(inputTokens: 3_000_000).cost(.opus)
        #expect(abs(gov.windowCost - inWindow) < 1e-9)
    }

    // Per-message-DAY bucketing: ONE session whose messages span two days must
    // split its cost across those days — NOT smear the whole pile onto its
    // `lastActivity` day (the old behavior, which is now the no-per-day fallback).
    @Test func bucketsEachMessageDayNotJustLastActivity() {
        let cal = Self.utc()
        let now = Self.at(cal, 2026, 6, 30)
        let u28 = SessionUsage(inputTokens: 1_000_000)   // priced on sonnet
        let u29 = SessionUsage(inputTokens: 3_000_000)
        // lastActivity is 06-29; the old code would dump BOTH days onto 06-29.
        let s = SessionSummary(
            id: "multi", project: "p", cwd: "/tmp/p", model: "sonnet",
            lastActivity: Self.at(cal, 2026, 6, 29), messageCount: 2,
            usage: u28 + u29, contextWeight: 0,
            usageByTier: [.sonnet: u28 + u29],
            usageByDay: ["2026-06-28": [.sonnet: u28], "2026-06-29": [.sonnet: u29]])
        let gov = BurnGovernor(sessions: [s], now: now, window: 30, calendar: cal)
        let d28 = gov.days.first { cal.isDate($0.day, inSameDayAs: Self.at(cal, 2026, 6, 28)) }!
        let d29 = gov.days.first { cal.isDate($0.day, inSameDayAs: Self.at(cal, 2026, 6, 29)) }!
        #expect(abs(d28.cost - u28.cost(.sonnet)) < 1e-9)
        #expect(abs(d29.cost - u29.cost(.sonnet)) < 1e-9)
        // 06-29 carries ONLY its own day, not the whole session — the anti-smear.
        #expect(abs(d29.cost - s.cost) > 1e-9)
        // Both days count the session as active that day.
        #expect(d28.sessions == 1)
        #expect(d29.sessions == 1)
        // Window total still equals the session's full cost (nothing lost/double).
        #expect(abs(gov.windowCost - s.cost) < 1e-9)
    }

    // The month projection is a pure function of the recent COMPLETE daily costs.
    @Test func monthlyProjectionIsMeanTimes30() {
        // mean(10,20,30) = 20 → ×30 = 600
        #expect(abs(BurnGovernor.monthlyProjection(recentDailyCosts: [10, 20, 30]) - 600) < 1e-9)
        // suffix(lookback): only the LAST 3 count → mean(8,9,10)=9 → 270
        #expect(abs(BurnGovernor.monthlyProjection(recentDailyCosts: [1,2,3,4,5,6,7,8,9,10], lookback: 3) - 270) < 1e-9)
        // Fewer values than lookback → averages what exists.
        #expect(abs(BurnGovernor.monthlyProjection(recentDailyCosts: [50], lookback: 7) - 1500) < 1e-9)
        // No history → 0.
        #expect(BurnGovernor.monthlyProjection(recentDailyCosts: []) == 0)
    }

    // Projection through the governor: excludes today (partial), includes quiet days.
    @Test func projectionExcludesTodayAndCountsQuietDays() {
        let cal = Self.utc()
        let now = Self.at(cal, 2026, 6, 30)
        // window 4 → days [06-27, 06-28, 06-29, 06-30]; lookback 3 → the 3 complete days.
        // Give 06-27/28/29 known costs; 06-30 (today) a big cost that must NOT count.
        let s27 = Self.burnSession("a", .sonnet, at: Self.at(cal, 2026, 6, 27), input: 1_000_000) // $3
        let s28 = Self.burnSession("b", .sonnet, at: Self.at(cal, 2026, 6, 28), input: 2_000_000) // $6
        let s29 = Self.burnSession("c", .sonnet, at: Self.at(cal, 2026, 6, 29), input: 3_000_000) // $9
        let sToday = Self.burnSession("d", .opus, at: Self.at(cal, 2026, 6, 30), input: 10_000_000) // $50 @ opus $5/M, excluded

        let gov = BurnGovernor(sessions: [s27, s28, s29, sToday],
                               now: now, window: 4, projectionLookback: 3, calendar: cal)
        let c27 = SessionUsage(inputTokens: 1_000_000).cost(.sonnet)
        let c28 = SessionUsage(inputTokens: 2_000_000).cost(.sonnet)
        let c29 = SessionUsage(inputTokens: 3_000_000).cost(.sonnet)
        let mean = (c27 + c28 + c29) / 3
        #expect(gov.runRateDays == 3)
        #expect(abs(gov.dailyRunRate - mean) < 1e-9)
        #expect(abs(gov.monthProjection - mean * 30) < 1e-9)
        // Today's Opus session ($50 at $5/M) is in the window total + today bucket, but
        // not the pace — it's >5× the $6 daily run-rate (was 10× at the old $15/M Opus rate).
        #expect(gov.today.cost > gov.monthProjection / 30 * 5)
    }

    // Quiet recent days drag the run-rate down (they're real, not skipped).
    @Test func quietRecentDaysLowerTheRunRate() {
        let cal = Self.utc()
        let now = Self.at(cal, 2026, 6, 30)
        // Only 06-29 has cost; 06-25..06-28 are silent. lookback 5 over complete days
        // 06-25..06-29 → mean = cost/5, not cost/1.
        let s29 = Self.burnSession("c", .sonnet, at: Self.at(cal, 2026, 6, 29), input: 5_000_000)
        let gov = BurnGovernor(sessions: [s29], now: now, window: 6, projectionLookback: 5, calendar: cal)
        let c29 = SessionUsage(inputTokens: 5_000_000).cost(.sonnet)
        #expect(gov.runRateDays == 5)
        #expect(abs(gov.dailyRunRate - c29 / 5) < 1e-9)
    }

    // Empty corpus: no crash, a full gap-filled window of zeros, zero projection.
    @Test func emptyCorpusIsAllZeros() {
        let cal = Self.utc()
        let gov = BurnGovernor(sessions: [], now: Self.at(cal, 2026, 6, 30), window: 30, calendar: cal)
        #expect(gov.days.count == 30)
        #expect(gov.windowCost == 0)
        #expect(gov.today.cost == 0)
        #expect(gov.monthProjection == 0)
        #expect(gov.dailyRunRate == 0)
        #expect(gov.today.opusShare == 0)
    }
}

private extension Result {
    var isFailure: Bool { if case .failure = self { return true } else { return false } }
}
