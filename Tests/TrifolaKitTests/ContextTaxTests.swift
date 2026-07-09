import Foundation
import Testing
@testable import TrifolaKit

// Spree #1 — CONTEXT-TAX GAUGE + fresh-session advisor (the "$20 hey" killer).
// These tests pin the pure math (warm = cache-read rate, cold = fresh-input
// rate, at the session's OWN model rates), the receipt-consistency contract
// (gauge cold == costPerMessageColdCache, blend == costPerMessage — same rate
// path, asserted so the gauge can never disagree with the receipts), the
// honest-threshold advisor semantics, and the live-pool doctrine (subagents
// and dead sessions are never advised).

private func sess(_ id: String, model: String? = "claude-opus-4-8",
                  ctx: Int, ageSecs: TimeInterval? = 60,
                  usage: SessionUsage = SessionUsage(inputTokens: 100_000),
                  subagent: Bool = false) -> SessionSummary {
    let path = subagent ? "/x/p/s/subagents/agent-\(id).jsonl" : "/x/p/\(id).jsonl"
    return SessionSummary(id: id, project: "p", cwd: "/x/p", model: model,
                          lastActivity: ageSecs.map { Date().addingTimeInterval(-$0) },
                          messageCount: 3, usage: usage,
                          contextWeight: ctx, filePath: path)
}

@Suite("Context tax — pure math")
struct ContextTaxMathTests {

    @Test func warmAndColdPriceAtTheSessionsOwnModelRates() {
        // The field-report case: 847k resent on one word, opus-4-8 ($5 in, $0.50 read).
        let g = ContextTax.gauge(sess("hey", ctx: 847_000))
        #expect(abs(g.warmPerMessage - 0.847 * 0.50) < 1e-9)   // $0.4235 warm
        #expect(abs(g.coldPerMessage - 0.847 * 5.0) < 1e-9)    // $4.235 — the "$20 hey"
        // Opus 4.1 ($15 in, $1.50 read) prices the SAME context 3× the opus-4-8
        // cache-read rate — per-model rates, not a flat tier table.
        let f = ContextTax.gauge(sess("f", model: "claude-opus-4-1", ctx: 265_000))
        #expect(abs(f.warmPerMessage - 0.3975) < 1e-9)
        #expect(abs(f.coldPerMessage - 3.975) < 1e-9)
        #expect(f.taxLine == "next message ≈ $0.40 warm / $3.98 cold")
        #expect(f.modelID == "claude-opus-4-1")                // normalized disk truth
    }

    @Test func cacheColdSessionBlendsToTheColdPrice() {
        // A session that has NEVER hit cache (hit rate 0): the blend IS the cold
        // price — no phantom warmth invented for a cache-cold history.
        let cold = sess("cold", ctx: 400_000,
                        usage: SessionUsage(inputTokens: 900_000, cacheReadTokens: 0))
        let g = ContextTax.gauge(cold)
        #expect(g.cacheHitRate == 0)
        #expect(abs(g.blendedPerMessage - g.coldPerMessage) < 1e-12)
        // And a fully-warm session (all reads) blends to the warm floor.
        let warm = sess("warm", ctx: 400_000,
                        usage: SessionUsage(inputTokens: 0, cacheReadTokens: 5_000_000))
        let w = ContextTax.gauge(warm)
        #expect(w.cacheHitRate == 1)
        #expect(abs(w.blendedPerMessage - w.warmPerMessage) < 1e-12)
    }

    @Test func gaugeAgreesWithTheReceiptMachinery() {
        // The consistency contract: cold == costPerMessageColdCache and
        // blend == costPerMessage, byte-for-byte the same rate path — the gauge
        // and the receipts can never tell two stories.
        let mixed = sess("m", model: "claude-opus-4-1", ctx: 312_400,
                         usage: SessionUsage(inputTokens: 60_000, cacheReadTokens: 940_000))
        let g = ContextTax.gauge(mixed)
        #expect(abs(g.coldPerMessage - mixed.costPerMessageColdCache) < 1e-12)
        #expect(abs(g.blendedPerMessage - mixed.costPerMessage) < 1e-12)
        #expect(abs(g.cacheHitRate - mixed.cacheHitRate) < 1e-12)
        // Unknown model → the SAME tier fallback the receipts use.
        let odd = sess("odd", model: "glm-4.7", ctx: 500_000)
        let og = ContextTax.gauge(odd)
        #expect(abs(og.coldPerMessage - odd.costPerMessageColdCache) < 1e-12)
        #expect(abs(og.blendedPerMessage - odd.costPerMessage) < 1e-12)
    }

    @Test func gaugeFractionUsesTheSharedFullScaleAndCaps() {
        #expect(ContextTax.gaugeFullScale == 400_000)          // ContextBar's scale
        #expect(abs(ContextTax.gauge(sess("q", ctx: 100_000)).gaugeFraction - 0.25) < 1e-9)
        #expect(ContextTax.gauge(sess("h", ctx: 847_000)).gaugeFraction == 1) // capped
    }
}

@Suite("Context tax — advisor")
struct ContextTaxAdvisorTests {

    @Test func advisoryIsStrictlyOverTheSameBarAsIsContextHeavy() {
        // One definition of "heavy" in the whole app: strictly > 200k.
        #expect(ContextTax.advisoryTokens == 200_000)
        let at = sess("at", ctx: 200_000)
        #expect(!ContextTax.gauge(at).advisory && !at.isContextHeavy)
        let over = sess("over", ctx: 200_001)
        #expect(ContextTax.gauge(over).advisory && over.isContextHeavy)
    }

    @Test func advisorLineNamesTheThresholdAndBothPrices() {
        let g = ContextTax.gauge(sess("a", ctx: 312_400,
                                      usage: SessionUsage(inputTokens: 60_000,
                                                          cacheReadTokens: 940_000)))
        let line = try! #require(g.advisorLine)
        // A visible threshold is a measurement; an invisible one is a nag.
        #expect(line.contains("threshold 200.0k"))
        #expect(line.contains("312.4k tokens ride every message"))
        #expect(line.contains("$0.16 warm"))                   // 0.3124 × $0.50
        #expect(line.contains("$1.56 if the cache went cold")) // 0.3124 × $5
        #expect(line.hasPrefix("fresh-session advised"))
        // Below the bar: no line at all — evidence, never noise.
        #expect(ContextTax.gauge(sess("b", ctx: 84_000)).advisorLine == nil)
    }
}

@Suite("Context tax — live pool")
struct ContextTaxPoolTests {

    @Test func poolKeepsOnlyLiveMainsWithContext() {
        let report = ContextTax.build(sessions: [
            sess("live-heavy", ctx: 847_000),                       // in, advisory
            sess("live-light", ctx: 84_000),                        // in, ok
            sess("idle", ctx: 900_000, ageSecs: 16 * 60),           // idle — excluded, never nagged
            sess("dateless", ctx: 900_000, ageSecs: nil),           // no lastActivity — excluded
            sess("sub", ctx: 900_000, subagent: true),              // nobody types "hey" into one
            sess("zero", ctx: 0),                                   // no context, no tax
        ])
        #expect(report.live.map(\.id) == ["live-heavy", "live-light"]) // cold desc
        #expect(report.advisories.map(\.id) == ["live-heavy"])
        #expect(report.heaviest?.id == "live-heavy")
        #expect(abs(report.liveWarmTotal - (0.847 + 0.084) * 0.50) < 1e-9)
        #expect(abs(report.liveColdTotal - (0.847 + 0.084) * 5.0) < 1e-9)
    }

    @Test func liveWindowMatchesIsActive() {
        // 14m59s → live; 15m01s → not: the SAME 15-minute window as isActive.
        #expect(ContextTax.liveWindow == 15 * 60)
        let now = Date()
        let just = sess("just", ctx: 10_000, ageSecs: 15 * 60 - 1)
        let past = sess("past", ctx: 10_000, ageSecs: 15 * 60 + 1)
        #expect(ContextTax.gauge(just, now: now).isLive)
        #expect(!ContextTax.gauge(past, now: now).isLive)
    }

    @Test func sortIsDeterministicUnderEqualPrices() {
        // Equal cold prices → id tiebreak, ascending — rows must not flap.
        let r = ContextTax.build(sessions: [
            sess("bbb", ctx: 300_000), sess("aaa", ctx: 300_000), sess("ccc", ctx: 300_000),
        ])
        #expect(r.live.map(\.id) == ["aaa", "bbb", "ccc"])
        #expect(ContextTax.build(sessions: []).live.isEmpty)
        #expect(ContextTaxReport.empty.heaviest == nil)
    }

    @Test func gaugeCarriesCwdForTheCompositionReaderToUse() {
        // Plan 12: the gauge threads `cwd` through so the UI can locate a
        // project CLAUDE.md without needing the original SessionSummary.
        let s = sess("withcwd", ctx: 10_000)
        #expect(ContextTax.gauge(s).cwd == "/x/p")
    }
}

// MARK: - Context composition (plan 12 — where the resent tokens come from)
// Pins the pure attribution math per the plan's four fixture cases: (a) the
// normal case sums exactly to contextWeight; (b) a zero-context session
// divides nothing and zeros everything (no NaN/Inf); (c) an estimate that
// overshoots contextWeight clamps history to 0, never negative; (d) shares
// always land in [0, 1], even under (c)'s overshoot.

@Suite("Context tax — composition math")
struct ContextCompositionMathTests {

    @Test func compositionSumsToContextWeightInTheNormalCase() {
        let c = ContextComposition(contextWeight: 300_000, claudeMdTokens: 18_000,
                                   mcpTokens: 40_000, mcpServerCount: 6)
        #expect(c.claudeMdTokens + c.mcpTokens + c.historyTokens == c.contextWeight)
        #expect(c.historyTokens == 242_000)
        #expect(c.line == "≈18.0k CLAUDE.md · ≈40.0k in 6 idle MCP tools · ≈242.0k history")
    }

    @Test func zeroContextSessionDividesNothingAndZerosEverything() {
        // No context, no tax: every share is 0 — a 0-denominator never
        // produces NaN/Inf, and there is nothing left to attribute.
        let c = ContextComposition(contextWeight: 0, claudeMdTokens: 5_000,
                                   mcpTokens: 10_000, mcpServerCount: 2)
        #expect(c.claudeMdShare == 0)
        #expect(c.mcpShare == 0)
        #expect(c.historyTokens == 0)
        #expect(!c.claudeMdShare.isNaN && !c.mcpShare.isNaN)
    }

    @Test func overshootingEstimateClampsHistoryToZeroNeverNegative() {
        // CLAUDE.md + MCP alone exceed contextWeight (a coarse-estimate
        // overshoot, e.g. a tiny session with many connected MCP servers) —
        // history floors at 0, it is never a negative token count.
        let c = ContextComposition(contextWeight: 10_000, claudeMdTokens: 8_000,
                                   mcpTokens: 6_000, mcpServerCount: 1)
        #expect(c.historyTokens == 0)
        #expect(c.historyTokens >= 0)
    }

    @Test func sharesAlwaysLandInZeroToOneEvenOnOvershoot() {
        // CLAUDE.md alone is bigger than contextWeight — its raw ratio would
        // read "150%"; the share clamps to 1.0, a bar-fill fraction never a
        // raw ratio.
        let c = ContextComposition(contextWeight: 10_000, claudeMdTokens: 15_000,
                                   mcpTokens: 0, mcpServerCount: 0)
        #expect(c.claudeMdShare == 1)
        #expect(c.mcpShare == 0)
        #expect(c.claudeMdShare >= 0 && c.claudeMdShare <= 1)
        #expect(c.mcpShare >= 0 && c.mcpShare <= 1)
        #expect(c.historyTokens == 0)
    }

    @Test func negativeInputsClampToZeroRatherThanPropagating() {
        // Defensive: a caller passing a negative estimate (should never
        // happen upstream, but the struct doesn't trust it) clamps to 0.
        let c = ContextComposition(contextWeight: -5, claudeMdTokens: -100,
                                   mcpTokens: -50, mcpServerCount: -2)
        #expect(c.contextWeight == 0)
        #expect(c.claudeMdTokens == 0)
        #expect(c.mcpTokens == 0)
        #expect(c.mcpServerCount == 0)
        #expect(c.historyTokens == 0)
    }

    @Test func singularMCPServerCountReadsGrammaticallySingular() {
        let c = ContextComposition(contextWeight: 10_000, claudeMdTokens: 0,
                                   mcpTokens: 6_500, mcpServerCount: 1)
        #expect(c.line.contains("in 1 idle MCP tool ·"))
        #expect(!c.line.contains("idle MCP tools"))
    }
}

// MARK: - Context footprint reader (plan 12 — read-only, injectable paths)
// Every read here goes through a temp-directory fixture, never the user's own
// `~/.claude` — the reader itself never writes anywhere (FileManager
// `attributesOfItem` / `contents` only).

@Suite("Context tax — footprint reader")
struct ContextFootprintReaderTests {

    private func writeFile(_ text: String, name: String = "CLAUDE-\(UUID().uuidString).md") throws -> String {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    @Test func claudeMdTokensSumsByteSizeAcrossPaths() throws {
        // "aaaa" = 4 bytes = 1 token at the ≈4 bytes/token heuristic.
        let a = try writeFile(String(repeating: "a", count: 400))   // 400B → 100 tok
        let b = try writeFile(String(repeating: "b", count: 800))   // 800B → 200 tok
        defer { try? FileManager.default.removeItem(atPath: a); try? FileManager.default.removeItem(atPath: b) }
        #expect(ContextFootprint.claudeMdTokens(paths: [a, b]) == 300)
    }

    @Test func claudeMdTokensTreatsMissingFilesAsZeroNotAnError() {
        let missing = "/nope/does-not-exist-\(UUID().uuidString)/CLAUDE.md"
        #expect(ContextFootprint.claudeMdTokens(paths: [missing]) == 0)
    }

    @Test func claudeMdTokensDedupesTheSamePhysicalPath() throws {
        // A project whose cwd IS the global CLAUDE.md's directory would
        // otherwise double-count the same file as both "global" and
        // "project" — observed on the real corpus (a `.claude` project
        // session). Same path (even via a different tilde spelling) counts once.
        let path = try writeFile(String(repeating: "x", count: 400))  // 100 tok, once
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(ContextFootprint.claudeMdTokens(paths: [path, path]) == 100)
    }

    @Test func connectedMCPCountParsesTheSameShapeMCPConfigParses() throws {
        let json = #"""
        {"mcpServers":{
          "cleanshot":{"type":"stdio","command":"npx"},
          "headroom":{"type":"stdio","command":"headroom"},
          "circle":{"type":"http","url":"https://api.circle.com/mcp"},
          "mission-control":{"type":"stdio","command":"mc"}}}
        """#
        let path = try writeFile(json, name: "claude-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(ContextFootprint.connectedMCPCount(configPath: path) == 4)
        let footprint = ContextFootprint.mcpFootprint(configPath: path)
        #expect(footprint.count == 4)
        #expect(footprint.tokens == 4 * ContextFootprint.tokensPerMCPServer)
    }

    @Test func connectedMCPCountOnUnreadableConfigIsZeroNotAnError() {
        #expect(ContextFootprint.connectedMCPCount(configPath: "/nope/claude-\(UUID().uuidString).json") == 0)
    }

    @Test func compositionWiresTheReaderIntoTheContextComposition() throws {
        let claude = try writeFile(String(repeating: "c", count: 4_000))  // 1000 tok
        let mcpPath = try writeFile(#"{"mcpServers":{"a":{"command":"x"},"b":{"command":"y"}}}"#,
                                    name: "claude-\(UUID().uuidString).json")
        defer {
            try? FileManager.default.removeItem(atPath: claude)
            try? FileManager.default.removeItem(atPath: mcpPath)
        }
        let comp = ContextFootprint.composition(contextWeight: 50_000, claudeMdPaths: [claude],
                                                 mcpConfigPath: mcpPath)
        #expect(comp.claudeMdTokens == 1_000)
        #expect(comp.mcpServerCount == 2)
        #expect(comp.mcpTokens == 2 * ContextFootprint.tokensPerMCPServer)
        #expect(comp.historyTokens == 50_000 - 1_000 - comp.mcpTokens)
    }
}
