import Foundation

// MARK: - Credit-era burn governor (VISION 2.5)
// The successor to the dead Jul-7 countdown: daily API-rate-equivalent burn plus a
// month projection from the recent daily run-rate. Pure value types over the
// existing cost math (`SessionSummary.perTierUsage`, each slice priced at its OWN
// tier rate), so the whole thing is unit-testable without a store or the GUI.
//
// HONEST LIMIT — these are API-rate EQUIVALENTS, not the real subscription/credit
// bill. The plan/credit balance is not on disk, so nothing here can know your true
// spend; every surface that shows a figure labels it "API-equiv". A session is
// bucketed into the calendar day of its `lastActivity` (a SessionSummary keeps only
// that one timestamp, not per-message times), so a day's burn is "the sessions last
// active that day, priced at API rates". Visibility + trend only — no nags, no red
// panic banners (the Armstrong no-nag doctrine, RESEARCH.md).

/// One calendar day's API-rate-equivalent burn, bucketed from the sessions last
/// active that day, carrying the per-tier cost mix for the day.
public struct DailyBurn: Identifiable, Sendable, Equatable {
    /// Start-of-day (calendar) — the bucket key and the sparkline's time axis.
    public let day: Date
    /// Total API-equiv cost of the sessions last active this day (each tier's
    /// slice priced at its OWN rate, via `perTierUsage`).
    public let cost: Double
    /// Sessions last active this day.
    public let sessions: Int
    /// Per-tier API-equiv cost for the day — the day's model mix, the same split
    /// the Overview "spend by tier" bar uses, but per-day (the evidence grammar).
    public let byTier: [ModelTier: Double]

    public var id: Date { day }

    public init(day: Date, cost: Double, sessions: Int, byTier: [ModelTier: Double]) {
        self.day = day
        self.cost = cost
        self.sessions = sessions
        self.byTier = byTier
    }

    /// Opus share of this day's API-equiv cost — the tile's "N% Opus".
    public var opusShare: Double { cost > 0 ? (byTier[.opus] ?? 0) / cost : 0 }

    /// The day's non-zero tier slices, cost-descending — feeds the per-day stacked
    /// bar in the sparkline.
    public var tierSlices: [(tier: ModelTier, cost: Double)] {
        // Deterministic ties (W6 wave 4): dictionary order + an unstable sort let
        // equal-cost slices swap between recomputes — bar segments must not flap.
        byTier.filter { $0.value > 0 }
            .map { (tier: $0.key, cost: $0.value) }
            .sorted { ($0.cost, $1.tier.rawValue) > ($1.cost, $0.tier.rawValue) }
    }
}

/// The burn governor: a gap-filled per-day series over a trailing window plus a
/// month projection from the recent daily run-rate. Pure aggregation over the
/// existing session summaries — it does NOT re-scan the transcript index.
public struct BurnGovernor: Sendable, Equatable {
    /// One bucket per calendar day across the window, OLDEST first, gap-filled with
    /// zero-cost days so the sparkline has an honest, evenly-spaced time axis (no
    /// phantom compression of quiet days). The last element is always today.
    public let days: [DailyBurn]
    /// Mean API-equiv cost/day over the recent COMPLETE days (today excluded) —
    /// "at this pace, $X/day".
    public let dailyRunRate: Double
    /// The run-rate scaled to a 30-day month — "at this pace ≈$Y/mo". An
    /// API-equiv estimate, never presented as the real credit bill.
    public let monthProjection: Double
    /// How many complete days fed the run-rate — the honest denominator shown
    /// beside the projection.
    public let runRateDays: Int

    /// Today's bucket (the last day in the window — always present because the
    /// window is gap-filled up to `now`).
    public var today: DailyBurn {
        days.last ?? DailyBurn(day: Date(), cost: 0, sessions: 0, byTier: [:])
    }

    /// Total API-equiv cost across the whole visible window.
    public var windowCost: Double { days.reduce(0) { $0 + $1.cost } }

    public init(sessions: [SessionSummary], now: Date = Date(),
                window: Int = 30, projectionLookback: Int = 7,
                calendar: Calendar = .current) {
        let span = max(1, window)
        let today = calendar.startOfDay(for: now)
        guard let earliest = calendar.date(byAdding: .day, value: -(span - 1), to: today) else {
            self.days = []; self.dailyRunRate = 0; self.monthProjection = 0; self.runRateDays = 0
            return
        }

        // One pass: bucket each session's cost + per-tier cost by the day each
        // MESSAGE actually billed (`usageByDay`), NOT the session's lastActivity —
        // a multi-day session must not smear its whole pile onto one day. Sessions
        // built without per-message data (synthetic/pre-upgrade cache) have no
        // `usageByDay`, so they fall back to lastActivity bucketing (old behavior).
        // Sessions outside the window (or dateless with no day data) are ignored.
        var cost: [Date: Double] = [:]
        var count: [Date: Int] = [:]
        var tiers: [Date: [ModelTier: Double]] = [:]
        // Day keys repeat massively across sessions (a 30-day window has ~30
        // distinct keys over thousands of sessions) — parse each distinct key
        // ONCE. Pre-fix, `date(fromDayKey:)` allocated a fresh DateFormatter
        // per (session, day) pair, which alone measured ~340ms per governor
        // build over 5.3k sessions — rebuilt twice per body pass on the main
        // thread. That WAS the heartbeat jank.
        var dayCache: [String: Date?] = [:]
        func day(_ key: String) -> Date? {
            if let hit = dayCache[key] { return hit }
            let d = Self.date(fromDayKey: key, calendar: calendar)
            dayCache[key] = d
            return d
        }
        for s in sessions {
            if s.usageByDay.isEmpty {
                // Fallback: no per-message days — bucket the whole session by lastActivity.
                guard let la = s.lastActivity else { continue }
                let d = calendar.startOfDay(for: la)
                guard d >= earliest, d <= today else { continue }
                cost[d, default: 0] += s.cost
                count[d, default: 0] += 1
                for (tier, u) in s.perTierUsage {
                    let c = u.cost(tier)
                    if c != 0 { tiers[d, default: [:]][tier, default: 0] += c }
                }
                continue
            }
            for dayKey in s.usageByDay.keys {
                guard let d = day(dayKey) else { continue }
                guard d >= earliest, d <= today else { continue }
                cost[d, default: 0] += s.cost(onDay: dayKey)
                count[d, default: 0] += 1   // this session was active on day d
                for (tier, c) in s.perTierCost(onDay: dayKey) {
                    tiers[d, default: [:]][tier, default: 0] += c
                }
            }
        }

        // Gap-fill into a contiguous oldest→newest series.
        var series: [DailyBurn] = []
        series.reserveCapacity(span)
        for i in 0..<span {
            guard let d = calendar.date(byAdding: .day, value: i, to: earliest) else { continue }
            series.append(DailyBurn(day: d, cost: cost[d] ?? 0,
                                    sessions: count[d] ?? 0, byTier: tiers[d] ?? [:]))
        }
        self.days = series

        // Projection: recent COMPLETE days only (drop today — a partial current day
        // would drag the mean down mid-day and understate the pace).
        let complete = Array(series.dropLast().map(\.cost))
        let lookback = max(1, projectionLookback)
        self.monthProjection = Self.monthlyProjection(recentDailyCosts: complete, lookback: lookback)
        self.dailyRunRate = monthProjection / 30
        self.runRateDays = min(complete.count, lookback)
    }

    /// Parse a "yyyy-MM-dd" day key (as minted by the accumulator's local-day
    /// bucketing) into start-of-day in the governor's calendar/time zone, so the
    /// key reads back onto the same bucket the sparkline's time axis uses.
    static func date(fromDayKey key: String, calendar: Calendar) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: key) else { return nil }
        return calendar.startOfDay(for: d)
    }

    /// Project a monthly API-equiv figure from a run of recent COMPLETE daily costs:
    /// the mean of the last `lookback` values × 30. Pure — the caller must exclude
    /// the partial current day. Returns 0 with no history.
    public static func monthlyProjection(recentDailyCosts: [Double], lookback: Int = 7) -> Double {
        let recent = Array(recentDailyCosts.suffix(max(1, lookback)))
        guard !recent.isEmpty else { return 0 }
        return recent.reduce(0, +) / Double(recent.count) * 30
    }
}
