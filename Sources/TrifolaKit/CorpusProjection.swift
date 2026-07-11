import Foundation

/// One project row in the corpus-wide spend projection.
///
/// A named value type replaces the store's tuple so the projection can cross a
/// concurrency boundary without losing its `Sendable` guarantee.
public struct ProjectSpendRow: Identifiable, Sendable, Equatable {
    public var id: String { project }
    public let project: String
    public let cost: Double
    public let sessions: Int

    public init(project: String, cost: Double, sessions: Int) {
        self.project = project
        self.cost = cost
        self.sessions = sessions
    }
}

/// Immutable, corpus-wide values consumed by Overview, Spend, and the sidebar.
///
/// Construction is pure and has no actor or I/O dependency, so callers can
/// build it in a detached task and publish the finished snapshot on the main
/// actor. Every ordering is total: the same summaries and `now` produce the
/// same rows even when the input array arrives in a different order.
public struct CorpusProjection: Sendable {
    public let totalUsage: SessionUsage
    public let totalCost: Double
    public let totalCacheSavings: Double
    public let activeSessions: [SessionSummary]
    public let tierStats: [TierStat]
    public let topModelsByID: [ModelSpendStat]
    public let projectSpend: [ProjectSpendRow]
    public let burnGovernor: BurnGovernor
    public let rerouteReport: RerouteReport
    public let orchestratorHog: OrchestratorHogAlert?
    public let distinctProjectCount: Int

    /// Every non-subagent session over the shared context-heavy threshold.
    public let contextHeavy: [SessionSummary]
    /// Up to `contextRowLimit` rows: heavy sessions when any exist, otherwise
    /// the heaviest non-subagent sessions. This pins the Overview fallback in
    /// the same off-main snapshot as the rest of the corpus values.
    public let topContextRows: [SessionSummary]
    public let usesContextFallback: Bool

    /// Session last-touch counts for the trailing 24 one-hour buckets, oldest
    /// first. Unlike the UI's normalized bars, these retain the source counts.
    public let activityHistogram24h: [Int]

    public nonisolated init(
        sessions: [SessionSummary],
        now: Date,
        burnWindow: Int = 30,
        contextRowLimit: Int = 5
    ) {
        // All floating-point folds use one canonical input order. Session ids
        // are provider/machine scoped in the merged corpus; file path is the
        // final stable discriminator for synthetic or partially merged input.
        let ordered = sessions.sorted(by: Self.canonicalSessionOrder)

        var usage = SessionUsage()
        var cost = 0.0
        var savings = 0.0
        var active: [SessionSummary] = []
        var projects: [String: (cost: Double, sessions: Int)] = [:]
        var contextCandidates: [SessionSummary] = []

        active.reserveCapacity(ordered.count)
        contextCandidates.reserveCapacity(ordered.count)

        for session in ordered {
            usage = usage + session.usage
            cost += session.cost
            savings += session.cacheSavingsDollars

            if session.isActive(at: now) {
                active.append(session)
            }

            var project = projects[session.project] ?? (cost: 0, sessions: 0)
            project.cost += session.cost
            project.sessions += 1
            projects[session.project] = project

            if !session.isSubagent {
                contextCandidates.append(session)
            }
        }

        active.sort(by: Self.activeSessionOrder)
        contextCandidates.sort(by: Self.contextSessionOrder)
        let heavy = contextCandidates.filter(\.isContextHeavy)
        let fallsBack = heavy.isEmpty
        let contextPool = fallsBack ? contextCandidates : heavy

        self.totalUsage = usage
        self.totalCost = cost
        self.totalCacheSavings = savings
        self.activeSessions = active
        self.tierStats = SessionStore.aggregateTiers(ordered).sorted {
            if $0.cost != $1.cost { return $0.cost > $1.cost }
            return $0.tier.rawValue < $1.tier.rawValue
        }
        self.topModelsByID = SessionStore.aggregateModelsByID(ordered)
        self.projectSpend = projects.map {
            ProjectSpendRow(project: $0.key, cost: $0.value.cost,
                            sessions: $0.value.sessions)
        }.sorted {
            if $0.cost != $1.cost { return $0.cost > $1.cost }
            return $0.project < $1.project
        }
        self.burnGovernor = BurnGovernor(
            sessions: ordered,
            now: now,
            window: burnWindow)
        self.rerouteReport = Reroutes.build(sessions: ordered)
        self.orchestratorHog = OrchestratorHog.alert(
            sessions: ordered,
            day: CostProvenance.dayKey(for: now))
        self.distinctProjectCount = projects.count
        self.contextHeavy = heavy
        self.topContextRows = Array(contextPool.prefix(max(0, contextRowLimit)))
        self.usesContextFallback = fallsBack
        self.activityHistogram24h = SessionStore.activityHistogram(
            ordered,
            hours: 24,
            now: now)
    }

    /// Heartbeats only move the rolling activity window. Rebuilding exact-model
    /// spend, reroutes, project totals, and context rankings every ten seconds
    /// spent hundreds of milliseconds of CPU on unchanged data. Refresh the two
    /// genuinely time-sensitive fields in O(n) without re-sorting the corpus.
    public nonisolated func refreshingActivity(
        sessions: [SessionSummary],
        now: Date
    ) -> CorpusProjection {
        var active = sessions.filter { $0.isActive(at: now) }
        active.sort(by: Self.activeSessionOrder)
        return CorpusProjection(
            base: self,
            activeSessions: active,
            activityHistogram24h: SessionStore.activityHistogram(
                sessions, hours: 24, now: now))
    }

    private init(
        base: CorpusProjection,
        activeSessions: [SessionSummary],
        activityHistogram24h: [Int]
    ) {
        totalUsage = base.totalUsage
        totalCost = base.totalCost
        totalCacheSavings = base.totalCacheSavings
        self.activeSessions = activeSessions
        tierStats = base.tierStats
        topModelsByID = base.topModelsByID
        projectSpend = base.projectSpend
        burnGovernor = base.burnGovernor
        rerouteReport = base.rerouteReport
        orchestratorHog = base.orchestratorHog
        distinctProjectCount = base.distinctProjectCount
        contextHeavy = base.contextHeavy
        topContextRows = base.topContextRows
        usesContextFallback = base.usesContextFallback
        self.activityHistogram24h = activityHistogram24h
    }

    private nonisolated static func canonicalSessionOrder(
        _ lhs: SessionSummary,
        _ rhs: SessionSummary
    ) -> Bool {
        (lhs.provider.rawValue, lhs.machineID, lhs.id, lhs.filePath)
            < (rhs.provider.rawValue, rhs.machineID, rhs.id, rhs.filePath)
    }

    private nonisolated static func activeSessionOrder(
        _ lhs: SessionSummary,
        _ rhs: SessionSummary
    ) -> Bool {
        let left = lhs.lastActivity ?? .distantPast
        let right = rhs.lastActivity ?? .distantPast
        if left != right { return left > right }
        return canonicalSessionOrder(lhs, rhs)
    }

    private nonisolated static func contextSessionOrder(
        _ lhs: SessionSummary,
        _ rhs: SessionSummary
    ) -> Bool {
        if lhs.contextWeight != rhs.contextWeight {
            return lhs.contextWeight > rhs.contextWeight
        }
        let left = lhs.lastActivity ?? .distantPast
        let right = rhs.lastActivity ?? .distantPast
        if left != right { return left > right }
        return canonicalSessionOrder(lhs, rhs)
    }
}
