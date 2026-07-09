import Foundation

// MARK: - REROUTE RECEIPTS (spree #2 — fallback/reroute-trend forensics)
// docs/RESEARCH_spree_synthesis.md re-ranked build queue, item 2: Anthropic
// admitted the Opus fallback (Jul 1 — "a mandatory safety classifier that
// quietly reroutes risky requests to Opus 4.8"); field rates run 0.25%
// (hedderichpro, hand-grepped his own logs) to 75% (a security-phrased
// benchmark). Upstream demand is on the record: anthropics/claude-code
// #74778 / #74780 / #74734 / #74783. This extends the shipped per-session
// OpusFallback detector (CustomRush.swift §3a) into per-FLIP receipts and a
// daily trend — free forensics over what already happened, never a probe.
//
// HONEST SEMANTICS (the receipt says what it can and cannot know): the
// transcript cannot see the router, so a "silent reroute" here is defined
// mechanically — two consecutive assistant TURNS answered by DIFFERENT
// normalized model ids with NO `/model` command line between them. A flip
// that follows a `/model` command is recorded as a deliberate switch and is
// NEVER counted as a reroute. `<synthetic>` error placeholders are ignored
// entirely (an API error is not a model change). What this can't distinguish:
// a reroute the user asked for by some out-of-band means — hence "evidence,
// never an accusation" (the OpusFallback doctrine, inherited verbatim).

/// One mid-session model change, captured positionally by the accumulator at
/// the assistant-turn boundary (streaming chunks share `message.id` and never
/// mint a flip). Stored on the summary → rides the index cache (v13).
public struct ModelFlip: Identifiable, Sendable, Hashable, Codable {
    /// Normalized model id of the PREVIOUS assistant turn (disk truth, mono in UI).
    public let fromModel: String
    /// Normalized model id of the turn that flipped.
    public let toModel: String
    /// The flipping turn's own timestamp; nil on old logs without one.
    public let timestamp: Date?
    /// LOCAL calendar day key ("yyyy-MM-dd"), "" when the line carried no
    /// parseable timestamp — the trend drops "" honestly instead of guessing.
    public let day: String
    /// The flipping assistant `message.id` — the receipt's message ref.
    public let messageID: String?
    /// True when a `/model` command line appeared between the two turns —
    /// a deliberate switch, listed but never counted as a reroute.
    public let userInitiated: Bool

    public init(fromModel: String, toModel: String, timestamp: Date?,
                day: String, messageID: String?, userInitiated: Bool) {
        self.fromModel = fromModel
        self.toModel = toModel
        self.timestamp = timestamp
        self.day = day
        self.messageID = messageID
        self.userInitiated = userInitiated
    }

    public var id: String {
        "\(messageID ?? "?")·\(fromModel)→\(toModel)·\(timestamp?.timeIntervalSince1970 ?? 0)"
    }

    /// "claude-opus-4-8 → claude-sonnet-5" — the pair key the trend groups on.
    public var pair: String { "\(fromModel) → \(toModel)" }

    /// Direction by display tier — a downshift (opus→sonnet, sonnet→haiku) is
    /// the classic fallback shape; an upshift (sonnet→opus) is the classifier
    /// intercept shape. Same tier both sides (opus-4-8→opus-4-1) reads flat.
    public enum Direction: Sendable { case downshift, upshift, lateral }
    public var direction: Direction {
        // ModelTier declaration order IS capability order (opus > sonnet > haiku).
        let order: [ModelTier: Int] = [.opus: 0, .sonnet: 1, .haiku: 2, .user: 3, .other: 4]
        let f = order[ModelTier(raw: fromModel)] ?? 4
        let t = order[ModelTier(raw: toModel)] ?? 4
        if f == t { return .lateral }
        return t > f ? .downshift : .upshift
    }
}

/// One session's reroute receipt: its silent flips (when, from→to, message
/// ref), the deliberate switches it is NOT counting, and the turn census as
/// the honest denominator.
public struct RerouteReceipt: Identifiable, Sendable, Hashable {
    public let id: String
    public let project: String
    public let shortID: String
    public let filePath: String
    public let tier: ModelTier
    public let isSubagent: Bool
    /// Mid-conversation flips with NO `/model` between turns — the receipts.
    public let silentFlips: [ModelFlip]
    /// Flips that followed a `/model` command — listed, never counted.
    public let userSwitches: Int
    /// All assistant turns (any model) — the denominator.
    public let totalTurns: Int

    public init(id: String, project: String, shortID: String, filePath: String,
                tier: ModelTier, isSubagent: Bool, silentFlips: [ModelFlip],
                userSwitches: Int, totalTurns: Int) {
        self.id = id; self.project = project; self.shortID = shortID
        self.filePath = filePath; self.tier = tier; self.isSubagent = isSubagent
        self.silentFlips = silentFlips
        self.userSwitches = userSwitches
        self.totalTurns = totalTurns
    }

    /// "2 silent reroutes across 41 assistant turns" — count + denominator.
    public var headline: String {
        "\(silentFlips.count) silent reroute\(silentFlips.count == 1 ? "" : "s") across \(totalTurns) assistant turns"
    }

    /// The honest exclusion, shown faint under the receipts; nil when clean.
    public var switchNote: String? {
        guard userSwitches > 0 else { return nil }
        return "\(userSwitches) /model switch\(userSwitches == 1 ? "" : "es") excluded — user-initiated, not reroutes"
    }
}

/// One trend day: silent reroutes that landed on this LOCAL calendar day.
public struct RerouteDay: Identifiable, Sendable, Hashable {
    public var id: String { day }
    public let day: String
    public let count: Int
    /// Pair label → count that day.
    public let byPair: [String: Int]
    public init(day: String, count: Int, byPair: [String: Int]) {
        self.day = day; self.count = count; self.byPair = byPair
    }
}

public struct ReroutePairCount: Identifiable, Sendable, Hashable {
    public var id: String { pair }
    public let pair: String
    public let count: Int
    public init(pair: String, count: Int) { self.pair = pair; self.count = count }
}

/// The fleet rollup: per-session receipts + the daily trend.
public struct RerouteReport: Sendable {
    /// Sessions with ≥1 silent flip, most flips first (id tiebreak — no flap).
    public let receipts: [RerouteReceipt]
    /// Dated silent flips bucketed by LOCAL day, ascending. Undated flips are
    /// NOT smeared onto a day — they surface in `undatedSilent` instead.
    public let days: [RerouteDay]
    /// from→to pairs across all silent flips, most common first.
    public let pairs: [ReroutePairCount]
    public let totalSilent: Int
    public let undatedSilent: Int
    /// Deliberate `/model` switches across all sessions — the honest exclusion.
    public let totalUserSwitches: Int
    /// Sessions that carried ANY turn census (the receipt's own denominator:
    /// pre-v13 cache entries carry no flip data and stay honestly quiet).
    public let sessionsCensused: Int

    /// The one-sentence semantics, shared by UI + selfcheck so the copy can't
    /// fork (the ContextTax `taxLine` rule).
    public static let semantics = "counts only mid-conversation model flips with no /model command between turns — deliberate switches are listed, never counted; the router itself is not on disk"

    public init(receipts: [RerouteReceipt], days: [RerouteDay],
                pairs: [ReroutePairCount], totalSilent: Int, undatedSilent: Int,
                totalUserSwitches: Int, sessionsCensused: Int) {
        self.receipts = receipts; self.days = days; self.pairs = pairs
        self.totalSilent = totalSilent; self.undatedSilent = undatedSilent
        self.totalUserSwitches = totalUserSwitches
        self.sessionsCensused = sessionsCensused
    }

    public static let empty = RerouteReport(receipts: [], days: [], pairs: [],
                                            totalSilent: 0, undatedSilent: 0,
                                            totalUserSwitches: 0, sessionsCensused: 0)

    /// Reroutes/day over the trailing `window` days ending at `now` — the
    /// sparkline series (missing days are honest zeros).
    public func trend(window: Int = 14, now: Date = Date()) -> [(day: String, count: Int)] {
        let byDay = Dictionary(days.map { ($0.day, $0.count) }, uniquingKeysWith: { a, _ in a })
        var out: [(String, Int)] = []
        let cal = Calendar.current
        let start = cal.startOfDay(for: now)
        for back in stride(from: window - 1, through: 0, by: -1) {
            let d = cal.date(byAdding: .day, value: -back, to: start) ?? start
            let key = RerouteReport.dayKey(d)
            out.append((key, byDay[key] ?? 0))
        }
        return out
    }

    static func dayKey(_ d: Date) -> String { localDayKey(d) }
}

public enum Reroutes {

    /// One session's receipt — nil when the session carries no flips at all
    /// (clean sessions produce no chrome; evidence, not decoration). A session
    /// with ONLY deliberate switches still gets a receipt so the exclusion is
    /// visible where the user made it.
    public static func receipt(for s: SessionSummary) -> RerouteReceipt? {
        guard !s.modelFlips.isEmpty else { return nil }
        let silent = s.modelFlips.filter { !$0.userInitiated }
        return RerouteReceipt(
            id: s.id, project: s.project, shortID: s.shortID, filePath: s.filePath,
            tier: s.tier, isSubagent: s.isSubagent, silentFlips: silent,
            userSwitches: s.modelFlips.count - silent.count,
            totalTurns: s.assistantTurnsByModel.values.reduce(0, +))
    }

    /// Build the fleet report. Subagents ARE included — the classifier does
    /// not care who typed the prompt, and a rerouted subagent bills the same.
    public static func build(sessions: [SessionSummary]) -> RerouteReport {
        var receipts: [RerouteReceipt] = []
        var dayCounts: [String: Int] = [:]
        var dayPairs: [String: [String: Int]] = [:]
        var pairCounts: [String: Int] = [:]
        var undated = 0, switches = 0, censused = 0
        for s in sessions {
            if !s.assistantTurnsByModel.isEmpty { censused += 1 }
            guard let r = receipt(for: s) else { continue }
            switches += r.userSwitches
            if !r.silentFlips.isEmpty { receipts.append(r) }
            for f in r.silentFlips {
                pairCounts[f.pair, default: 0] += 1
                if f.day.isEmpty {
                    undated += 1
                } else {
                    dayCounts[f.day, default: 0] += 1
                    dayPairs[f.day, default: [:]][f.pair, default: 0] += 1
                }
            }
        }
        receipts.sort {
            $0.silentFlips.count != $1.silentFlips.count
                ? $0.silentFlips.count > $1.silentFlips.count : $0.id < $1.id
        }
        let days = dayCounts.keys.sorted().map {
            RerouteDay(day: $0, count: dayCounts[$0] ?? 0, byPair: dayPairs[$0] ?? [:])
        }
        let pairs = pairCounts
            .map { ReroutePairCount(pair: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.pair < $1.pair }
        return RerouteReport(receipts: receipts, days: days, pairs: pairs,
                             totalSilent: pairs.reduce(0) { $0 + $1.count },
                             undatedSilent: undated,
                             totalUserSwitches: switches,
                             sessionsCensused: censused)
    }
}

// MARK: - ORCHESTRATOR-HOG ALERT (spree #2b — cost attribution, not a nag)
// The simonw datapoint (validated 2026-07-07 on this corpus: the user's main
// session ≈ $422 of ≈$750 daily API-equivalent): when ONE top-level session
// hogs the day's spend, the fix is structural — delegate to cheaper subagents
// — and the alert names the offending session with the day's arithmetic.
// Reuses the EXISTING cost machinery (`SessionSummary.cost(onDay:)`, the
// SessionCostBundle path) — never a second pricing path; consistency is
// asserted in tests and `--selfcheck` exactly like ContextTax.

public struct OrchestratorHogAlert: Sendable, Equatable {
    public let day: String
    public let sessionID: String
    public let project: String
    public let shortID: String
    /// The hog's API-equiv cost on `day`, via `cost(onDay:)` — the same
    /// number every other surface prints for this session-day.
    public let sessionCost: Double
    /// Σ `cost(onDay:)` across ALL sessions (subagents included — they are
    /// the denominator the advice is about).
    public let dayTotal: Double

    public init(day: String, sessionID: String, project: String, shortID: String,
                sessionCost: Double, dayTotal: Double) {
        self.day = day; self.sessionID = sessionID; self.project = project
        self.shortID = shortID; self.sessionCost = sessionCost; self.dayTotal = dayTotal
    }

    public var share: Double { dayTotal > 0 ? sessionCost / dayTotal : 0 }

    /// The advisor line — evidence with the threshold IN the copy (the
    /// ContextTax rule: a visible threshold is a measurement, not a nag).
    public var line: String {
        "delegate more to cheaper subagents — \(project) (\(shortID)) billed "
            + "\(fmtUSD(sessionCost)) of today's \(fmtUSD(dayTotal)) (\(fmtPct(share)); "
            + "threshold \(fmtPct(OrchestratorHog.shareThreshold)) of a ≥\(fmtUSD(OrchestratorHog.minimumDayTotal)) day)"
    }
}

public enum OrchestratorHog {
    /// Fires strictly ABOVE this share — matching the house rule
    /// (`isContextHeavy` / `ContextTax.advisory` are strictly greater-than):
    /// exactly 80% is at the bar, not over it.
    public static let shareThreshold = 0.80
    /// A quiet day is never hog-worthy: below this total the alert stays
    /// silent (one $3 session is 100% of a $3 day and needs no advice).
    public static let minimumDayTotal = 20.0

    /// The alert for a LOCAL day key, or nil. The hog candidate is the
    /// top-costing TOP-LEVEL session (subagents can't be the hog — they ARE
    /// the delegation); the denominator is every session's spend that day.
    public static func alert(sessions: [SessionSummary], day: String) -> OrchestratorHogAlert? {
        var dayTotal = 0.0
        var top: (s: SessionSummary, cost: Double)?
        for s in sessions {
            let c = s.cost(onDay: day)
            dayTotal += c
            guard !s.isSubagent, c > 0 else { continue }
            if top == nil || c > top!.cost || (c == top!.cost && s.id < top!.s.id) {
                top = (s, c)
            }
        }
        guard let top, dayTotal >= minimumDayTotal,
              top.cost / dayTotal > shareThreshold else { return nil }
        return OrchestratorHogAlert(day: day, sessionID: top.s.id,
                                    project: top.s.project, shortID: top.s.shortID,
                                    sessionCost: top.cost, dayTotal: dayTotal)
    }

    /// Today's alert (LOCAL calendar).
    public static func today(sessions: [SessionSummary], now: Date = Date()) -> OrchestratorHogAlert? {
        alert(sessions: sessions, day: localDayKey(now))
    }
}
