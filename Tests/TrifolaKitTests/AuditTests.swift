import Foundation
import Testing
@testable import TrifolaKit

// The AUDIT pillar's math is the product — test every finding's pure helper hard,
// and reproduce the briefed on-disk shapes (dead-skill diff) as deterministic
// assertions over synthetic fixtures. Live numbers move with ~/.claude; these
// fixtures never do.

// MARK: - Re-sent context: the LEAK vs first-touch (finding 1, W2 split)

@Suite("Cache leak vs first-touch")
struct CacheLeakTests {
    @Test func leakIsFreshInputPremiumOnly_firstTouchIsCacheBuild() {
        // fresh 1M, cache-create 0.4M (all 5m), cache-read 2M on Opus 4.8
        // ($5 in / $0.50 read / $6.25 cw5m):
        //   LEAK        = 1M   × ($5 − $0.50) = 4.50   (re-sent fresh input)
        //   FIRST-TOUCH = 0.4M × $6.25        = 2.50   (cache build — NOT leak)
        //   reads are the warm slice — in neither number.
        let u = SessionUsage(inputTokens: 1_000_000, outputTokens: 200_000,
                             cacheCreateTokens: 400_000, cacheReadTokens: 2_000_000)
        let opus = ModelRate(input: 5, output: 25)
        #expect(abs(u.cacheLeakDollars(rate: opus) - 4.50) < 0.0001)
        #expect(abs(u.firstTouchDollars(rate: opus) - 2.50) < 0.0001)
        // The old combined "cacheMissDollars" (4.50 + 0.4M×$5×1.15 = 6.80)
        // charged first-touch cache creation as leak — the W2 fix splits it.
    }

    @Test func firstTouchSplitsThe1hSliceAt2x() {
        // cache-create 0.4M of which 0.3M is the 1h slice on Opus 4.8:
        //   5m slice 0.1M × $6.25 = 0.625
        //   1h slice 0.3M × $10   = 3.000   → first-touch 3.625
        let u = SessionUsage(cacheCreateTokens: 400_000, cacheCreate1hTokens: 300_000)
        let opus = ModelRate(input: 5, output: 25)
        #expect(abs(u.firstTouchDollars(rate: opus) - 3.625) < 0.0001)
        #expect(u.cacheLeakDollars(rate: opus) == 0)   // no fresh input → no leak
    }

    @Test func pureWarmCacheHasNoLeakAndNoFirstTouch() {
        // All input served from cache reads → nothing above the floor, nothing built.
        let u = SessionUsage(inputTokens: 0, cacheCreateTokens: 0, cacheReadTokens: 5_000_000)
        let opus = ModelRate(input: 5, output: 25)
        #expect(u.cacheLeakDollars(rate: opus) == 0)
        #expect(u.firstTouchDollars(rate: opus) == 0)
    }

    @Test func sessionAggregatesAcrossTiers() {
        // A mixed session: each tier's slice priced at its OWN input rate.
        //   opus:   fresh 1M × ($5 − $0.50) = 4.50
        //   sonnet: fresh 1M × ($3 − $0.30) = 2.70
        let s = SessionSummary(id: "s", project: "p", cwd: "/tmp/p", model: "claude-opus-4-8",
                               lastActivity: nil, messageCount: 2,
                               usage: SessionUsage(inputTokens: 2_000_000, cacheReadTokens: 500_000),
                               contextWeight: 0,
                               usageByTier: [
                                   .opus: SessionUsage(inputTokens: 1_000_000),
                                   .sonnet: SessionUsage(inputTokens: 1_000_000)
                               ])
        #expect(abs(s.cacheLeakDollars - 7.20) < 0.0001)   // opus 4.50 + sonnet 2.70
        #expect(s.firstTouchDollars == 0)                    // no cache creation at all
        #expect(abs(s.cacheHitRate - 500_000.0 / 2_500_000.0) < 0.0001)
    }

    @Test func leadersSortByLeakAndTotalsCoverAll() {
        func sess(_ id: String, fresh: Int, create: Int = 0) -> SessionSummary {
            SessionSummary(id: id, project: id, cwd: "/tmp/\(id)", model: "claude-opus-4-8",
                           lastActivity: nil, messageCount: 1,
                           usage: SessionUsage(inputTokens: fresh, cacheCreateTokens: create),
                           contextWeight: fresh,
                           usageByTier: [.opus: SessionUsage(inputTokens: fresh, cacheCreateTokens: create)])
        }
        // "zero" has NO fresh input but a big cache-create — under the old
        // combined metric it would out-rank "mid"; as a first-touch-only session
        // it must be EXCLUDED from the leak list (yet counted in first-touch).
        let sessions = [sess("small", fresh: 100_000), sess("big", fresh: 2_000_000),
                        sess("mid", fresh: 500_000), sess("zero", fresh: 0, create: 3_000_000)]
        let (top, totalLeak, totalFirstTouch) = AuditReport.cacheMissLeaders(sessions, limit: 2)
        #expect(top.map(\.id) == ["big", "mid"])        // sorted by LEAK desc
        #expect(top.count == 2)                          // limit honored
        // leak total covers ALL sessions; first-touch total counts "zero"'s build.
        let expectedLeak = sessions.reduce(0.0) { $0 + $1.cacheLeakDollars }
        #expect(abs(totalLeak - expectedLeak) < 0.0001)
        #expect(abs(totalFirstTouch - 3.0 * 6.25) < 0.0001)   // 3M × $6.25 (5m slice)
    }
}

// MARK: - Accumulator tool-call census

@Suite("Accumulator tool census")
struct ToolCensusTests {
    private func asstToolUse(_ blocks: String) -> String {
        #"{"type":"assistant","message":{"model":"claude-opus-4-8","content":[\#(blocks)],"usage":{"input_tokens":10,"output_tokens":5}}}"#
    }

    @Test func countsSkillAgentAndEditToolCalls() {
        let blocks = [
            #"{"type":"tool_use","name":"Skill","input":{"skill":"code-review"}}"#,
            #"{"type":"tool_use","name":"Skill","input":{"skill":"api-client"}}"#,
            #"{"type":"tool_use","name":"Skill","input":{"skill":"code-review"}}"#,
            #"{"type":"tool_use","name":"Agent","input":{"description":"build it"}}"#,
            #"{"type":"tool_use","name":"Edit","input":{"file_path":"/x.swift"}}"#,
            #"{"type":"tool_use","name":"Write","input":{"file_path":"/y.swift"}}"#,
            #"{"type":"text","text":"done"}"#,
        ].joined(separator: ",")
        var acc = SessionAccumulator(defaultID: "fb")
        acc.ingest(Data((asstToolUse(blocks) + "\n").utf8))
        let s = acc.summary(filePath: "/x.jsonl")
        #expect(s.skillInvocations["code-review"] == 2)
        #expect(s.skillInvocations["api-client"] == 1)
        #expect(s.agentCalls == 1)
        #expect(s.fileEdits == 2)
    }

    @Test func noToolCallsLeavesCensusEmpty() {
        // asst1-shaped line (usage only, no content array) must not crash or count.
        let line = #"{"type":"assistant","message":{"model":"claude-opus-4-8","usage":{"input_tokens":100,"output_tokens":50}}}"#
        var acc = SessionAccumulator(defaultID: "fb")
        acc.ingest(Data((line + "\n").utf8))
        let s = acc.summary(filePath: "")
        #expect(s.skillInvocations.isEmpty)
        #expect(s.agentCalls == 0 && s.fileEdits == 0)
    }
}

// MARK: - Skill ledger (finding 2 — reproduces the dead-skill diff)

@Suite("Skill ledger")
struct SkillLedgerTests {
    private func skill(_ id: String, name: String? = nil, desc: String = "a skill") -> Skill {
        Skill(id: id, name: name ?? id, description: desc, version: nil, triggers: [],
              allowedTools: [], hasManifest: true, wordCount: 100, fileCount: 1,
              modified: .distantPast, path: "/skills/\(id)")
    }
    private func session(_ fires: [String: Int], last: Date? = Date(),
                         sub: Bool = false,
                         provider: Provider = .claude) -> SessionSummary {
        SessionSummary(id: UUID().uuidString, provider: provider,
                       project: "p", cwd: "/tmp/p", model: "claude-opus-4-8",
                       lastActivity: last, messageCount: 1, usage: SessionUsage(), contextWeight: 0,
                       filePath: sub ? "/x/PARENT/subagents/agent-1.jsonl" : "/x/s.jsonl",
                       skillInvocations: fires)
    }

    @Test func deadCountIsCatalogMinusFiredMatchingByIdOrName() {
        // Catalog of 5. Fired: "code-review" (NOT in catalog → external),
        // "api-client" (matches folder id), "diagram" (matches frontmatter name).
        let catalog = [
            skill("api-client"),
            skill("dia", name: "diagram"),
            skill("unused-one"),
            skill("unused-two"),
            skill("unused-three"),
        ]
        let sessions = [
            session(["code-review": 20, "api-client": 6]),
            session(["api-client": 5, "diagram": 2]),
        ]
        let led = AuditReport.skillLedger(sessions: sessions, catalog: catalog)

        #expect(led.catalogCount == 5)
        #expect(led.distinctFired == 3)                 // code-review, api-client, diagram
        #expect(led.firedInCatalog == 2)                // api-client + diagram map to catalog
        #expect(led.deadCount == 3)                     // 5 catalog − 2 fired-in-catalog
        #expect(led.dead.map(\.name).sorted() == ["unused-one", "unused-three", "unused-two"])
        // top fired = code-review ×20 (aggregated across sessions: 20), then api-client ×11.
        #expect(led.fired.first?.name == "code-review")
        #expect(led.fired.first?.invocations == 20)
        #expect(led.fired.first?.inCatalog == false)    // fired but no matching folder → "ext"
        let ar = led.fired.first { $0.name == "api-client" }
        #expect(ar?.invocations == 11)                  // 6 + 5 across two sessions
        #expect(ar?.sessionsTouched == 2)
    }

    @Test func promptTaxSumsDeadDescriptionTokensOnly() {
        // Two dead skills with known-length descriptions (~4 chars/token).
        let d40 = String(repeating: "x", count: 40)   // ≈10 tok
        let d80 = String(repeating: "y", count: 80)   // ≈20 tok
        let catalog = [skill("fired-one", desc: "short"),
                       skill("dead-a", desc: d40),
                       skill("dead-b", desc: d80)]
        let led = AuditReport.skillLedger(sessions: [session(["fired-one": 1])], catalog: catalog)
        #expect(led.deadCount == 2)
        #expect(led.deadPromptTaxTokens == 10 + 20)
        // dead sorted by prompt tax desc → the 80-char one first.
        #expect(led.dead.first?.name == "dead-b")
    }

    @Test func sessionCountExcludesSubagents() {
        let led = AuditReport.skillLedger(
            sessions: [session(["x": 1]), session(["x": 1], sub: true)],
            catalog: [skill("x")])
        #expect(led.sessionCount == 1)                  // subagent not counted
    }

    @Test func codexSessionsCannotChangeClaudeDeadSkillsOrPromptTaxDenominator() {
        let catalog = [skill("used"), skill("dead")]
        let claude = session(["used": 2])
        let codex = session(
            ["dead": 99, "codex-only": 7], provider: .codex)
        let claudeOnly = AuditReport.skillLedger(
            sessions: [claude], catalog: catalog)
        let mixed = AuditReport.skillLedger(
            sessions: [claude, codex], catalog: catalog)

        #expect(mixed == claudeOnly)
        #expect(mixed.sessionCount == 1)
        #expect(mixed.dead.map(\.name) == ["dead"])
        #expect(!mixed.fired.contains { $0.name == "codex-only" })
    }
}

// MARK: - Subagent doctrine

@Suite("Subagent doctrine")
struct SubagentDoctrineTests {
    @Test func parentSessionIDFromDirectAndWorkflowPaths() {
        #expect(AuditReport.parentSessionID("/x/PARENT/subagents/agent-abc.jsonl") == "PARENT")
        #expect(AuditReport.parentSessionID("/x/PARENT/subagents/workflows/wf_1/agentXYZ.jsonl") == "PARENT")
        // no /subagents/ marker → falls back to the file stem.
        #expect(AuditReport.parentSessionID("/x/top.jsonl") == "top")
    }
}

// MARK: - Model-mismatch candidates (finding 3)

@Suite("Model mismatch")
struct MismatchTests {
    private func sess(id: String, tier: ModelTier, fresh: Int, msgs: Int,
                      agents: Int, edits: Int,
                      provider: Provider = .claude) -> SessionSummary {
        SessionSummary(id: id, provider: provider,
                       project: id, cwd: "/tmp/\(id)", model: tier.rawValue,
                       lastActivity: nil, messageCount: msgs,
                       usage: SessionUsage(inputTokens: fresh), contextWeight: 0,
                       filePath: "/x/\(id).jsonl",
                       usageByTier: [tier: SessionUsage(inputTokens: fresh)],
                       agentCalls: agents, fileEdits: edits)
    }

    @Test func flagsHeavyFrontierSmallTaskAndEstimatesSonnetOverspend() {
        // Opus 4.8 @ $5/M, 20 msgs, 0 agents, 2M fresh input → cost $10.
        // Repriced at the DATE-AWARE Sonnet-5 rate (intro era, $2/M through
        // 2026-08-31): 2M × $2 = $4 → overspend 10 − 4 = $6.
        let s = sess(id: "opus-small", tier: .opus, fresh: 2_000_000, msgs: 20, agents: 0, edits: 1)
        let (top, total, count) = AuditReport.mismatchCandidates([s], fallbackDay: "2026-07-06")
        #expect(count == 1 && top.count == 1)
        #expect(abs(top[0].estOverspend - 6.0) < 0.0001)   // 10 − 4
        #expect(abs(total - 6.0) < 0.0001)
    }

    @Test func sonnetRepriceIsDateAware() {
        // The SAME opus session repriced on a post-2026-09-01 day uses Sonnet 5's
        // standard $3/M: 2M × $3 = $6 → overspend 10 − 6 = $4 (was $6 intro-era).
        let s = sess(id: "opus-small", tier: .opus, fresh: 2_000_000, msgs: 20, agents: 0, edits: 1)
        let (top, _, _) = AuditReport.mismatchCandidates([s], fallbackDay: "2026-09-15")
        #expect(abs(top[0].estOverspend - 4.0) < 0.0001)

        // Per-message-day data wins over any fallback: an opus-4-8 leg dated
        // 2026-08-15 reprices at intro Sonnet ($2/M) even with a post-Sep fallback.
        let u = SessionUsage(inputTokens: 2_000_000)
        let dated = SessionSummary(id: "dated", project: "p", cwd: "/tmp/p",
                                   model: "claude-opus-4-8", lastActivity: nil, messageCount: 20,
                                   usage: u, contextWeight: 0, filePath: "/x/dated.jsonl",
                                   usageByTier: [.opus: u],
                                   usageByModel: ["claude-opus-4-8": u],
                                   usageByModelDay: ["2026-08-15": ["claude-opus-4-8": u]])
        let (top2, _, _) = AuditReport.mismatchCandidates([dated], fallbackDay: "2026-10-01")
        #expect(abs(top2[0].estOverspend - 6.0) < 0.0001)  // 10 − 2M×$2, per the leg's OWN day
    }

    @Test func mismatchIgnoresHaikuAndSonnetLegs() {
        // A mixed session: opus 2M fresh (the DOMINANT frontier leg) + haiku
        // 1.5M + sonnet 1M. Pre-W2 the ENTIRE pile was repriced at Sonnet —
        // charging the $1/M haiku leg a Sonnet "equivalent" and distorting the
        // delta. Now ONLY the opus leg is repriced: overspend = (2M×$5) −
        // (2M×$2) = $6, exactly as if the cheap legs didn't exist.
        let opusU = SessionUsage(inputTokens: 2_000_000)
        let haikuU = SessionUsage(inputTokens: 1_500_000)
        let sonnetU = SessionUsage(inputTokens: 1_000_000)
        let mixed = SessionSummary(id: "mixed", project: "p", cwd: "/tmp/p",
                                   model: "claude-opus-4-8", lastActivity: nil, messageCount: 20,
                                   usage: opusU + haikuU + sonnetU, contextWeight: 0,
                                   filePath: "/x/mixed.jsonl",
                                   usageByTier: [.opus: opusU, .haiku: haikuU, .sonnet: sonnetU])
        let (top, total, count) = AuditReport.mismatchCandidates([mixed], fallbackDay: "2026-07-06")
        #expect(count == 1)
        #expect(abs(top[0].estOverspend - 6.0) < 0.0001)
        #expect(abs(total - 6.0) < 0.0001)

        // Direct check on the helper: a PURE sonnet session has zero frontier
        // overspend (nothing to reprice — it is already at/below Sonnet).
        let pureSonnet = sess(id: "s", tier: .sonnet, fresh: 5_000_000, msgs: 10, agents: 0, edits: 0)
        #expect(AuditReport.frontierOverspend(pureSonnet, fallbackDay: "2026-07-06") == 0)
        let pureHaiku = sess(id: "h", tier: .haiku, fresh: 5_000_000, msgs: 10, agents: 0, edits: 0)
        #expect(AuditReport.frontierOverspend(pureHaiku, fallbackDay: "2026-07-06") == 0)
    }

    @Test func excludesOrchestration_bigSessions_cheapTiers_andSubagents() {
        // All are well over the $5 gate at 2M fresh — so each must be excluded by its
        // STRUCTURAL rule (agents / big msgs / cheap tier / subagent), not by cost.
        let orchestration = sess(id: "orch", tier: .opus, fresh: 2_000_000, msgs: 20, agents: 3, edits: 4)
        let bigSession = sess(id: "big", tier: .opus, fresh: 2_000_000, msgs: 500, agents: 0, edits: 2)
        let cheap = sess(id: "sonnet", tier: .sonnet, fresh: 2_000_000, msgs: 20, agents: 0, edits: 1)
        let tiny = sess(id: "tiny", tier: .opus, fresh: 10_000, msgs: 5, agents: 0, edits: 1) // cost 0.05 < $1
        var subagent = sess(id: "P/agent", tier: .opus, fresh: 500_000, msgs: 20, agents: 0, edits: 1)
        subagent = SessionSummary(id: "P/agent", project: "p", cwd: "/tmp/p", model: "claude-opus-4-8",
                                  lastActivity: nil, messageCount: 20,
                                  usage: SessionUsage(inputTokens: 500_000), contextWeight: 0,
                                  filePath: "/x/P/subagents/agent-1.jsonl",
                                  usageByTier: [.opus: SessionUsage(inputTokens: 500_000)])
        let (top, _, count) = AuditReport.mismatchCandidates(
            [orchestration, bigSession, cheap, tiny, subagent], fallbackDay: "2026-07-06")
        #expect(count == 0)
        #expect(top.isEmpty)
    }

    @Test func codexSessionWithClaudeLikeOpusShapeIsNotRightSizedAgainstClaudeSettings() {
        let codex = sess(
            id: "codex-opus-shape", tier: .opus, fresh: 2_000_000,
            msgs: 20, agents: 0, edits: 1, provider: .codex)
        let result = AuditReport.mismatchCandidates(
            [codex], fallbackDay: "2026-07-06")
        #expect(result.count == 0)
        #expect(result.total == 0)
        #expect(result.top.isEmpty)
        #expect(AuditReport.frontierOverspend(
            codex, fallbackDay: "2026-07-06") == 0)
    }
}

// MARK: - Report smoke test

@Suite("Audit report build")
struct AuditReportBuildTests {
    @Test func buildWiresAllFindings() {
        let catalog = [
            Skill(id: "api-client", name: "api-client", description: "web research",
                  version: nil, triggers: [], allowedTools: [], hasManifest: true,
                  wordCount: 50, fileCount: 1, modified: .distantPast, path: "/s/api-client"),
            Skill(id: "never-used", name: "never-used", description: "dead weight here",
                  version: nil, triggers: [], allowedTools: [], hasManifest: true,
                  wordCount: 50, fileCount: 1, modified: .distantPast, path: "/s/never-used"),
        ]
        let parent = SessionSummary(id: "P1", project: "webapp", cwd: "/tmp/webapp",
                                    model: "claude-opus-4-8", lastActivity: Date(), messageCount: 20,
                                    usage: SessionUsage(inputTokens: 2_000_000), contextWeight: 2_000_000,
                                    filePath: "/x/P1.jsonl",
                                    usageByTier: [.opus: SessionUsage(inputTokens: 2_000_000)],
                                    skillInvocations: ["api-client": 3])
        let r = AuditReport.build(sessions: [parent], skills: catalog)

        #expect(r.totalLeakDollars > 0)                      // finding 1 (the leak)
        #expect(r.skillLedger.deadCount == 1)                // finding 2 (never-used)
        #expect(r.skillLedger.distinctFired == 1)
        #expect(r.mismatchCount == 1)                        // finding 3 (parent: opus, 20 msgs, 0 agents; 2M fresh = $10 > $5 gate)
    }
}
