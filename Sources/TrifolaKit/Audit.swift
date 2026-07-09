import Foundation
import Combine

// MARK: - AUDIT pillar
// "The whole point": attribute workflow WASTE TO A CAUSE. The frontier
// (ccusage / CodexBar / OpenUsage) stops at cost TOTALS; this file computes the
// four findings that name the cause — all as pure, testable value types over the
// session index the app already builds. No AppKit, no I/O beyond what the caller
// hands in, so every number here is unit-tested against synthetic fixtures and
// reproduced live in `--selfcheck`.
//
// Doctrine (Armstrong, 6.1k♥): make usage visible; the goal is fewer tokens
// WASTED — NOT a nag. Findings are evidence, ranked, with the offending
// transcript one click away. Heuristics are labeled review-candidates, never
// verdicts. Every hero number carries its denominator (the "99%" lesson).

// MARK: 1 ── Re-sent context: THE LEAK vs first-touch (the flagship "$20 hey")

/// One session's re-sent-context finding, split honestly (W2):
///  • `leakDollars` — fresh input a warm cache would have served at the ~0.10×
///    read rate: the AVOIDABLE part, what the card leads with.
///  • `firstTouchDollars` — cache CREATION (5m 1.25×, 1h 2×): the unavoidable
///    cost of building cache. NOT a leak; never summed into one.
/// The hit-rate denominator rides along so the number stays honest.
public struct CacheMissFinding: Identifiable, Sendable, Hashable {
    public let id: String
    public let project: String
    public let shortID: String
    public let filePath: String
    public let tier: ModelTier
    public let leakDollars: Double       // re-sent above the warm-cache floor (avoidable)
    public let firstTouchDollars: Double // cache creation (unavoidable first-touch)
    public let cacheHitRate: Double
    public let billedInput: Int          // fresh + cache-creation tokens (paid above floor)
    public let cacheReadTokens: Int      // the warm-cache slice (billed at ~10%)
    public let contextWeight: Int        // tokens re-sent on the most recent message
    public let isSubagent: Bool

    public init(_ s: SessionSummary) {
        self.id = s.id
        self.project = s.project
        self.shortID = s.shortID
        self.filePath = s.filePath
        self.tier = s.tier
        self.leakDollars = s.cacheLeakDollars
        self.firstTouchDollars = s.firstTouchDollars
        self.cacheHitRate = s.cacheHitRate
        self.billedInput = s.usage.billedInput
        self.cacheReadTokens = s.usage.cacheReadTokens
        self.contextWeight = s.contextWeight
        self.isSubagent = s.isSubagent
    }

    /// Direct construction — used by the headless render seed and tests.
    public init(id: String, project: String, shortID: String, filePath: String,
                tier: ModelTier, leakDollars: Double, firstTouchDollars: Double,
                cacheHitRate: Double, billedInput: Int, cacheReadTokens: Int,
                contextWeight: Int, isSubagent: Bool) {
        self.id = id; self.project = project; self.shortID = shortID
        self.filePath = filePath; self.tier = tier
        self.leakDollars = leakDollars; self.firstTouchDollars = firstTouchDollars
        self.cacheHitRate = cacheHitRate
        self.billedInput = billedInput; self.cacheReadTokens = cacheReadTokens
        self.contextWeight = contextWeight; self.isSubagent = isSubagent
    }
}

// MARK: 2 ── Dead-skill ledger + prompt tax

/// One skill's usage stats — either a skill that fired (invocations > 0) or a
/// dead catalog skill (invocations 0, priced by its description's prompt tax).
public struct SkillLedgerEntry: Identifiable, Sendable, Hashable {
    public var id: String { name }
    public let name: String
    public let invocations: Int          // explicit Skill-tool calls (auto-loaded undercounted)
    public let sessionsTouched: Int
    public let lastFired: Date?
    public let inCatalog: Bool           // false = fired but no matching skills/ folder (plugin/namespaced/removed)
    public let descriptionTokens: Int    // est. tokens this skill's description rides in every system prompt

    public init(name: String, invocations: Int, sessionsTouched: Int,
                lastFired: Date?, inCatalog: Bool, descriptionTokens: Int) {
        self.name = name; self.invocations = invocations
        self.sessionsTouched = sessionsTouched; self.lastFired = lastFired
        self.inCatalog = inCatalog; self.descriptionTokens = descriptionTokens
    }
}

public struct SkillLedger: Sendable, Equatable {
    public let catalogCount: Int         // skills/ folders + top-level *.md
    public let distinctFired: Int        // distinct skills ever explicit-fired
    public let firedInCatalog: Int       // fired AND present in the catalog
    public let deadCount: Int            // catalog skills never explicit-fired
    public let deadPromptTaxTokens: Int  // sum of dead-skill description tokens
    public let sessionCount: Int         // interactive sessions the catalog rides in
    public let fired: [SkillLedgerEntry] // sorted by invocations desc
    public let dead: [SkillLedgerEntry]  // sorted by prompt-tax desc (most expensive dead first)

    public static let empty = SkillLedger(catalogCount: 0, distinctFired: 0,
        firedInCatalog: 0, deadCount: 0, deadPromptTaxTokens: 0, sessionCount: 0,
        fired: [], dead: [])

    public init(catalogCount: Int, distinctFired: Int, firedInCatalog: Int,
                deadCount: Int, deadPromptTaxTokens: Int, sessionCount: Int,
                fired: [SkillLedgerEntry], dead: [SkillLedgerEntry]) {
        self.catalogCount = catalogCount; self.distinctFired = distinctFired
        self.firedInCatalog = firedInCatalog; self.deadCount = deadCount
        self.deadPromptTaxTokens = deadPromptTaxTokens; self.sessionCount = sessionCount
        self.fired = fired; self.dead = dead
    }
}

// MARK: 3 ── Model-mismatch review candidates

/// A heavy frontier session whose transcript SHAPE (few messages, no Agent
/// fan-out) looks like cheaper-model work. A review candidate with evidence —
/// NEVER a verdict (transcript shape is a heuristic, not proof).
public struct MismatchCandidate: Identifiable, Sendable, Hashable {
    public let id: String
    public let project: String
    public let shortID: String
    public let filePath: String
    public let tier: ModelTier
    public let cost: Double
    public let estOverspend: Double      // cost − (same tokens repriced at Sonnet)
    public let messageCount: Int
    public let fileEdits: Int
    public let agentCalls: Int

    public init(id: String, project: String, shortID: String, filePath: String,
                tier: ModelTier, cost: Double, estOverspend: Double,
                messageCount: Int, fileEdits: Int, agentCalls: Int) {
        self.id = id; self.project = project; self.shortID = shortID
        self.filePath = filePath; self.tier = tier; self.cost = cost
        self.estOverspend = estOverspend; self.messageCount = messageCount
        self.fileEdits = fileEdits; self.agentCalls = agentCalls
    }
}

// MARK: - The report (all four findings, computed once)

public struct AuditReport: Sendable, Equatable {
    public let cacheMiss: [CacheMissFinding]
    /// THE LEAK — fleet total of fresh input re-sent above the warm-cache floor
    /// (the avoidable part; leads the card).
    public let totalLeakDollars: Double
    /// FIRST-TOUCH — fleet total of cache creation (unavoidable; shown
    /// separately, never summed into the leak).
    public let totalFirstTouchDollars: Double
    public let skillLedger: SkillLedger
    public let mismatches: [MismatchCandidate]
    public let totalMismatchOverspend: Double
    /// Full count of review candidates (the `mismatches` list is capped to top-N
    /// for display; this is how many there really are).
    public let mismatchCount: Int

    public static let empty = AuditReport(
        cacheMiss: [], totalLeakDollars: 0, totalFirstTouchDollars: 0,
        skillLedger: .empty, mismatches: [],
        totalMismatchOverspend: 0, mismatchCount: 0)

    public init(cacheMiss: [CacheMissFinding], totalLeakDollars: Double,
                totalFirstTouchDollars: Double,
                skillLedger: SkillLedger, mismatches: [MismatchCandidate],
                totalMismatchOverspend: Double, mismatchCount: Int) {
        self.cacheMiss = cacheMiss; self.totalLeakDollars = totalLeakDollars
        self.totalFirstTouchDollars = totalFirstTouchDollars
        self.skillLedger = skillLedger; self.mismatches = mismatches
        self.totalMismatchOverspend = totalMismatchOverspend; self.mismatchCount = mismatchCount
    }

    // Tunable knobs, named so tests and UI share one source.
    public static let cacheMissTopN = 12
    public static let mismatchTopN = 12
    /// Model-mismatch gate — the "looks like Sonnet work" shape: a short
    /// transcript (few turns), at most one file touched, NO Agent fan-out, yet a
    /// frontier bill above the floor. Deliberately strict so the candidate list
    /// is reviewable, not "most of your Opus sessions".
    public static let mismatchMaxMessages = 40
    public static let mismatchMaxEdits = 1
    public static let mismatchMinCost = 5.0

    /// Build every finding from the session index + skill catalog. Pure and
    /// Sendable-in/Sendable-out so the caller can run it off the main actor.
    public static func build(sessions: [SessionSummary], skills: [Skill]) -> AuditReport {
        let (cm, leakTotal, firstTouchTotal) = cacheMissLeaders(sessions)
        let ledger = skillLedger(sessions: sessions, catalog: skills)
        let (mm, mmTotal, mmCount) = mismatchCandidates(sessions)
        return AuditReport(cacheMiss: cm, totalLeakDollars: leakTotal,
                           totalFirstTouchDollars: firstTouchTotal,
                           skillLedger: ledger, mismatches: mm,
                           totalMismatchOverspend: mmTotal, mismatchCount: mmCount)
    }

    // MARK: finding 1 — re-sent-context leaders (leak vs first-touch)

    /// Ranked by THE LEAK (re-sent fresh input above the warm-cache floor) —
    /// first-touch cache creation is totaled separately and NEVER decides the
    /// ranking (building cache is not a leak; W2 fix).
    public static func cacheMissLeaders(_ sessions: [SessionSummary],
                                        limit: Int = cacheMissTopN)
        -> (top: [CacheMissFinding], totalLeak: Double, totalFirstTouch: Double) {
        var totalLeak = 0.0
        var totalFirstTouch = 0.0
        var findings: [CacheMissFinding] = []
        findings.reserveCapacity(sessions.count)
        for s in sessions {
            let f = CacheMissFinding(s)
            totalLeak += f.leakDollars
            totalFirstTouch += f.firstTouchDollars
            if f.leakDollars > 0 { findings.append(f) }
        }
        findings.sort { $0.leakDollars > $1.leakDollars }
        return (Array(findings.prefix(limit)), totalLeak, totalFirstTouch)
    }

    // MARK: finding 2 — dead-skill ledger + prompt tax

    /// Rough token estimate for a description that rides every system prompt
    /// (~4 chars/token). Labeled "est." everywhere it surfaces.
    static func estimateTokens(_ text: String) -> Int { max(1, text.count / 4) }

    public static func skillLedger(sessions: [SessionSummary], catalog: [Skill]) -> SkillLedger {
        // Aggregate explicit Skill-tool invocations AND slash-command invocations
        // across the index (task #41) — a skill fired only via `/name` emits no
        // Skill tool_use, so the two lanes are merged per-session before the
        // dead/fired split, not tracked as separate ledgers.
        var counts: [String: Int] = [:]
        var touched: [String: Int] = [:]
        var lastFired: [String: Date] = [:]
        for s in sessions {
            var merged = s.skillInvocations
            for (name, n) in s.commandInvocations { merged[name, default: 0] += n }
            guard !merged.isEmpty else { continue }
            for (name, n) in merged {
                counts[name, default: 0] += n
                touched[name, default: 0] += 1
                if let d = s.lastActivity, d > (lastFired[name] ?? .distantPast) {
                    lastFired[name] = d
                }
            }
        }
        let firedNames = Set(counts.keys)

        // A catalog skill "fired" if the invocation arg matched its folder id OR
        // its frontmatter name. Namespaced/plugin names (codex:setup) and skills
        // registered outside skills/ never match → they don't shrink the dead list.
        func catalogFired(_ sk: Skill) -> Bool {
            firedNames.contains(sk.id) || firedNames.contains(sk.name)
        }
        let catalogNames = Set(catalog.flatMap { [$0.id, $0.name] })

        let fired: [SkillLedgerEntry] = counts.map { name, n in
            SkillLedgerEntry(name: name, invocations: n,
                             sessionsTouched: touched[name] ?? 0,
                             lastFired: lastFired[name], inCatalog: catalogNames.contains(name),
                             descriptionTokens: 0)
        }.sorted { $0.invocations != $1.invocations ? $0.invocations > $1.invocations : $0.name < $1.name }

        let deadSkills = catalog.filter { !catalogFired($0) }
        let dead: [SkillLedgerEntry] = deadSkills.map { sk in
            SkillLedgerEntry(name: sk.name, invocations: 0, sessionsTouched: 0,
                             lastFired: nil, inCatalog: true,
                             descriptionTokens: estimateTokens(sk.description))
        }.sorted { $0.descriptionTokens != $1.descriptionTokens
            ? $0.descriptionTokens > $1.descriptionTokens : $0.name < $1.name }

        let firedInCatalog = catalog.filter(catalogFired).count
        let sessionCount = sessions.filter { !$0.isSubagent }.count

        return SkillLedger(
            catalogCount: catalog.count,
            distinctFired: firedNames.count,
            firedInCatalog: firedInCatalog,
            deadCount: deadSkills.count,
            deadPromptTaxTokens: dead.reduce(0) { $0 + $1.descriptionTokens },
            sessionCount: sessionCount,
            fired: fired, dead: dead)
    }

    // MARK: finding 3 — model-mismatch review candidates

    /// Parent session id from a subagent transcript path — the component right
    /// before `/subagents/`, which is the parent session's UUID (== its summary id).
    public static func parentSessionID(_ path: String) -> String {
        guard let r = path.range(of: "/subagents/") else {
            return ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        }
        return (String(path[..<r.lowerBound]) as NSString).lastPathComponent
    }

    /// Overspend estimate for one session: ONLY the FRONTIER (opus) legs repriced
    /// at the date-aware Sonnet-5 catalog rate — each leg at the rate in force on
    /// ITS OWN day. Legs already at or below Sonnet (sonnet, haiku, other) are
    /// NEVER repriced: charging a $1/M Haiku leg a $2/M "Sonnet equivalent" would
    /// inflate the delta. `fallbackDay` pins the Sonnet-5 era for summaries
    /// WITHOUT per-day data (synthetic/tests); nil = today.
    public static func frontierOverspend(_ s: SessionSummary,
                                         fallbackDay: String? = nil) -> Double {
        let catalog = PricingCatalog.current
        var over = 0.0
        if !s.usageByModelDay.isEmpty {
            for (day, byModel) in s.usageByModelDay {
                for (model, u) in byModel {
                    let t = ModelTier(raw: model)
                    guard t == .opus else { continue }
                    let actual = u.cost(rate: catalog.resolvedRate(model: model, onDay: day))
                    let sonnet = u.cost(rate: catalog.resolvedRate(model: "claude-sonnet-5", onDay: day))
                    over += max(0, actual - sonnet)
                }
            }
            return over
        }
        for (t, u) in s.perTierUsage where t == .opus {
            let actual = u.cost(t)
            let sonnet = u.cost(rate: catalog.resolvedRate(model: "claude-sonnet-5", onDay: fallbackDay))
            over += max(0, actual - sonnet)
        }
        return over
    }

    public static func mismatchCandidates(_ sessions: [SessionSummary],
                                          limit: Int = mismatchTopN,
                                          fallbackDay: String? = nil) -> (top: [MismatchCandidate], total: Double, count: Int) {
        var candidates: [MismatchCandidate] = []
        var total = 0.0
        for s in sessions {
            guard !s.isSubagent,
                  s.tier == .opus,
                  s.agentCalls == 0,
                  s.fileEdits <= mismatchMaxEdits,
                  s.messageCount <= mismatchMaxMessages,
                  s.cost > mismatchMinCost else { continue }
            let overspend = frontierOverspend(s, fallbackDay: fallbackDay)
            guard overspend > 0 else { continue }
            total += overspend
            candidates.append(MismatchCandidate(
                id: s.id, project: s.project, shortID: s.shortID, filePath: s.filePath,
                tier: s.tier, cost: s.cost, estOverspend: overspend,
                messageCount: s.messageCount, fileEdits: s.fileEdits, agentCalls: s.agentCalls))
        }
        candidates.sort { $0.estOverspend > $1.estOverspend }
        return (Array(candidates.prefix(limit)), total, candidates.count)
    }
}

// MARK: - Audit store (computed findings for the UI)

@MainActor
public final class AuditStore: ObservableObject {
    @Published public private(set) var report: AuditReport = .empty
    @Published public private(set) var lastBuilt: Date? = nil

    public init() {}

    /// Recompute off the main actor. `sessions` and `skills` are Sendable value
    /// types, so the whole build hops cleanly to a detached task.
    public func refresh(sessions: [SessionSummary], skills: [Skill]) async {
        let r = await Task.detached(priority: .userInitiated) {
            AuditReport.build(sessions: sessions, skills: skills)
        }.value
        // Compare-before-assign (W6 wave 4): an unchanged report must not
        // republish the Audit + Ledger screens.
        if report != r { report = r }
        lastBuilt = Date()
    }
}
