import Foundation
import Combine
import TrifolaKit

/// The complete Sessions query. Views own/persist the controls; this Sendable
/// value crosses the actor boundary so sorting/filtering never runs in `body`.
struct SessionProjectionFilter: Sendable, Equatable, Hashable {
    enum Sort: String, Sendable, Hashable {
        case recent = "Recent"
        case cost = "Cost"
        case context = "Context"
        case tokens = "Tokens"
    }

    var query = ""
    var provider: Provider?
    var tier: ModelTier?
    var machineID: String?
    var activeOnly = false
    var heavyOnly = false
    var topLevelOnly = SessionBrowserFilter.defaultTopLevelOnly
    var liveInTerminalOnly = SessionBrowserFilter.defaultLiveInTerminalOnly
    var sort: Sort = .recent
}

struct SessionProjectionSnapshot: Sendable, Equatable {
    let rows: [SessionSummary]
    let conversationResults: [SearchResult]
    let searchState: SearchIndexState
    let sourceCount: Int
    let filter: SessionProjectionFilter
    let generation: Int
}

private struct SessionProjectionCostKey {
    let index: Int
    let cost: Double
    let id: String
}

struct FleetProjectionSnapshot: Sendable, Equatable {
    let board: FleetBoard
    let attention: AttentionBoard
    let machineRollups: [MachineRollup]
    let generation: Int
}

struct DeadlineProjectionSnapshot: Sendable, Equatable {
    let cards: [DeadlineCard]
    let tiers: [String: ModelTier]
    let generation: Int
}

/// Store-owned, ready-to-paint navigation data. Every O(corpus) projection is
/// built in detached work and generation-checked on publish. A destination can
/// therefore mount from a ready value or paint its cheap shell while this store
/// hydrates; no click transaction performs sorting, grouping, or deadline joins.
@MainActor
final class NavigationSnapshotStore: ObservableObject {
    @Published private(set) var corpus: CorpusProjection?
    @Published private(set) var sessionSearch =
        SearchSnapshotState<SessionProjectionSnapshot>()
    @Published private(set) var fleet: FleetProjectionSnapshot?
    @Published private(set) var deadlines: DeadlineProjectionSnapshot?
    @Published private(set) var sessionFilter: SessionProjectionFilter

    var sessions: SessionProjectionSnapshot? { sessionSearch.displayed }

    private struct Inputs: Sendable {
        let sessions: [SessionSummary]
        let attentionSignals: [String: AttentionSignals]
        let fleetSignals: [String: AttentionSignals]
        let arrival: ArrivalLedger
        let deadlineRecords: [String: DeadlineRecord]
        let machines: [Machine]
        let liveTerminalSessionIDs: Set<String>
        let searchIndex: SearchIndex
        let searchState: SearchIndexState
        let now: Date
    }

    private var inputs: Inputs?
    private var sessionGeneration = 0
    private var corpusGeneration = 0
    private var fleetGeneration = 0
    private var deadlineGeneration = 0
    private var sessionTask: Task<Void, Never>?
    private var corpusTask: Task<Void, Never>?
    private var fleetTask: Task<Void, Never>?
    private var deadlineTask: Task<Void, Never>?
    private var heartbeatTask: Task<Void, Never>?
    private var sourceGeneration = 0

    init(defaults: UserDefaults = .standard,
         initialCorpus: CorpusProjection? = nil) {
        func bool(_ key: String, fallback: Bool) -> Bool {
            defaults.object(forKey: key) == nil
                ? fallback : defaults.bool(forKey: key)
        }
        let providerRaw = defaults.string(
            forKey: "trifola.restoration.sessions.provider") ?? ""
        let tierRaw = defaults.string(
            forKey: AppRestorationKeys.sessionsTier) ?? ""
        let machineRaw = defaults.string(
            forKey: AppRestorationKeys.sessionsMachine) ?? ""
        sessionFilter = SessionProjectionFilter(
            query: defaults.string(
                forKey: AppRestorationKeys.sessionsQuery) ?? "",
            provider: Provider(rawValue: providerRaw),
            tier: ModelTier(rawValue: tierRaw),
            machineID: machineRaw.isEmpty ? nil : machineRaw,
            activeOnly: bool(
                AppRestorationKeys.sessionsActiveOnly, fallback: false),
            heavyOnly: bool(
                AppRestorationKeys.sessionsHeavyOnly, fallback: false),
            topLevelOnly: bool(
                AppRestorationKeys.sessionsTopLevelOnly,
                fallback: SessionBrowserFilter.defaultTopLevelOnly),
            liveInTerminalOnly: bool(
                AppRestorationKeys.sessionsLiveInTerminalOnly,
                fallback: SessionBrowserFilter.defaultLiveInTerminalOnly),
            sort: SessionProjectionFilter.Sort(rawValue:
                defaults.string(forKey: AppRestorationKeys.sessionsSort) ?? "")
                ?? .recent)
        corpus = initialCorpus
    }

    deinit {
        sessionTask?.cancel()
        corpusTask?.cancel()
        fleetTask?.cancel()
        deadlineTask?.cancel()
        heartbeatTask?.cancel()
    }

    func rebuild(
        sessions: [SessionSummary],
        attentionSignals: [String: AttentionSignals],
        fleetSignals: [String: AttentionSignals],
        arrival: ArrivalLedger,
        deadlineRecords: [String: DeadlineRecord],
        machines: [Machine],
        liveTerminalSessionIDs: Set<String>,
        searchIndex: SearchIndex,
        searchState: SearchIndexState,
        now: Date
    ) {
        sourceGeneration += 1
        inputs = Inputs(
            sessions: sessions,
            attentionSignals: attentionSignals,
            fleetSignals: fleetSignals,
            arrival: arrival,
            deadlineRecords: deadlineRecords,
            machines: machines,
            liveTerminalSessionIDs: liveTerminalSessionIDs,
            searchIndex: searchIndex,
            searchState: searchState,
            now: now)
        scheduleCorpus()
        scheduleSessions()
        scheduleFleet()
        scheduleDeadlines()
    }

    /// The ten-second clock tick only changes age-derived fleet/attention state
    /// and the Overview activity window. Session sorting, exact-model spend,
    /// reroutes, project totals, and deadlines are input-driven and remain on
    /// the full rebuild path. This keeps heartbeat CPU from contending with a
    /// user's navigation click while preserving time-driven BLOCKED transitions.
    func refreshHeartbeat(attention: AttentionBoard, now: Date) {
        guard let inputs, let currentCorpus = corpus else { return }
        heartbeatTask?.cancel()
        let sourceGeneration = self.sourceGeneration
        let previousFleetGeneration = fleet?.generation ?? fleetGeneration
        heartbeatTask = Task { [weak self] in
            let result = await Task.detached(priority: .background) {
                let metric = NavigationMetrics.beginProjection(
                    .fleet, generation: previousFleetGeneration)
                let board = FleetBoard.build(
                    sessions: inputs.sessions,
                    signals: inputs.fleetSignals,
                    now: now,
                    arrival: inputs.arrival).board
                let rollups = FleetMerge.rollups(
                    inputs.sessions, machines: inputs.machines)
                let corpus = currentCorpus.refreshingActivity(
                    sessions: inputs.sessions, now: now)
                _ = NavigationMetrics.endProjection(metric)
                return (board, rollups, corpus)
            }.value
            guard !Task.isCancelled,
                  let self,
                  self.sourceGeneration == sourceGeneration else { return }

            let nextFleet = FleetProjectionSnapshot(
                board: result.0,
                attention: attention,
                machineRollups: result.1,
                generation: previousFleetGeneration)
            if self.fleet?.board != nextFleet.board
                || self.fleet?.attention != nextFleet.attention
                || self.fleet?.machineRollups != nextFleet.machineRollups {
                self.fleet = nextFleet
            }

            let oldActive = self.corpus?.activeSessions.map(\.id) ?? []
            let nextActive = result.2.activeSessions.map(\.id)
            if oldActive != nextActive
                || self.corpus?.activityHistogram24h
                    != result.2.activityHistogram24h {
                self.corpus = result.2
            }
        }
    }

    func updateSessionFilter(_ next: SessionProjectionFilter) {
        guard sessionFilter != next else { return }
        let queryChanged = sessionFilter.query != next.query
        sessionFilter = next
        persistSessionFilter(next)
        scheduleSessions(
            debounce: queryChanged && !SearchQuery(next.query).isEmpty)
    }

    private func persistSessionFilter(_ value: SessionProjectionFilter) {
        Task.detached(priority: .utility) {
            let defaults = UserDefaults.standard
            defaults.set(value.query,
                         forKey: AppRestorationKeys.sessionsQuery)
            defaults.set(value.provider?.rawValue ?? "",
                         forKey: "trifola.restoration.sessions.provider")
            defaults.set(value.tier?.rawValue ?? "",
                         forKey: AppRestorationKeys.sessionsTier)
            defaults.set(value.machineID ?? "",
                         forKey: AppRestorationKeys.sessionsMachine)
            defaults.set(value.activeOnly,
                         forKey: AppRestorationKeys.sessionsActiveOnly)
            defaults.set(value.heavyOnly,
                         forKey: AppRestorationKeys.sessionsHeavyOnly)
            defaults.set(value.topLevelOnly,
                         forKey: AppRestorationKeys.sessionsTopLevelOnly)
            defaults.set(value.liveInTerminalOnly,
                         forKey: AppRestorationKeys.sessionsLiveInTerminalOnly)
            defaults.set(value.sort.rawValue,
                         forKey: AppRestorationKeys.sessionsSort)
        }
    }

    func isReady(for section: AppSection) -> Bool {
        switch section {
        case .overview, .spend: corpus != nil
        case .live: corpus != nil && fleet != nil
        case .sessions: sessions != nil
        case .fleet: fleet != nil
        case .deadlines: deadlines != nil
        default: true
        }
    }

    private func scheduleCorpus() {
        guard let inputs else { return }
        corpusGeneration += 1
        let generation = corpusGeneration
        corpusTask?.cancel()
        corpusTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                let overviewMetric = NavigationMetrics.beginProjection(
                    .overview, generation: generation)
                let spendMetric = NavigationMetrics.beginProjection(
                    .spend, generation: generation)
                let projection = CorpusProjection(
                    sessions: inputs.sessions,
                    now: inputs.now)
                _ = NavigationMetrics.endProjection(spendMetric)
                _ = NavigationMetrics.endProjection(overviewMetric)
                return projection
            }.value
            guard !Task.isCancelled,
                  let self,
                  self.corpusGeneration == generation else { return }
            self.corpus = result
        }
    }

    private func scheduleSessions(debounce: Bool = false) {
        guard let inputs else { return }
        sessionGeneration += 1
        let generation = sessionGeneration
        let filter = sessionFilter
        sessionTask?.cancel()
        var state = sessionSearch
        let request = state.begin(query: filter.query)
        sessionSearch = state
        sessionTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            let result = await Task.detached(priority: .userInitiated) {
                let metric = NavigationMetrics.beginProjection(
                    .sessions, generation: generation)
                var eligibilityFilter = filter
                eligibilityFilter.query = ""
                let eligible = Self.projectSessions(
                    inputs.sessions,
                    liveTerminalSessionIDs: inputs.liveTerminalSessionIDs,
                    filter: eligibilityFilter)
                let rows = SessionBrowserSearch.titlePathMatches(
                    eligible, query: filter.query)
                let query = SearchQuery(filter.query)
                let results: [SearchResult]
                if query.isEmpty {
                    results = []
                } else {
                    let eligibleKeys = Set(eligible.map {
                        [$0.provider.rawValue, $0.id, $0.filePath]
                            .joined(separator: "\u{1}")
                    })
                    let candidates = inputs.searchIndex.query(
                        query, scope: .conversationText, limit: 200,
                        now: inputs.now).filter {
                            eligibleKeys.contains([
                                $0.provider.rawValue, $0.id, $0.filePath
                            ].joined(separator: "\u{1}"))
                        }
                    results = candidates.prefix(20).map {
                        SearchResult(
                            candidate: $0,
                            snippet: SearchSnippetExtractor.snippet(
                                for: $0, query: query))
                    }
                }
                _ = NavigationMetrics.endProjection(metric)
                return SessionProjectionSnapshot(
                    rows: rows,
                    conversationResults: results,
                    searchState: inputs.searchState,
                    sourceCount: inputs.sessions.count,
                    filter: filter,
                    generation: generation)
            }.value
            guard !Task.isCancelled,
                  let self,
                  self.sessionGeneration == generation else { return }
            var state = self.sessionSearch
            guard state.publish(result, for: request) else { return }
            self.sessionSearch = state
        }
    }

    private func scheduleFleet() {
        guard let inputs else { return }
        fleetGeneration += 1
        let generation = fleetGeneration
        fleetTask?.cancel()
        fleetTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                let metric = NavigationMetrics.beginProjection(
                    .fleet, generation: generation)
                let attention = AttentionBoard.build(
                    sessions: inputs.sessions,
                    signals: inputs.attentionSignals,
                    now: inputs.now)
                let board = FleetBoard.build(
                    sessions: inputs.sessions,
                    signals: inputs.fleetSignals,
                    now: inputs.now,
                    arrival: inputs.arrival).board
                _ = NavigationMetrics.endProjection(metric)
                return FleetProjectionSnapshot(
                    board: board,
                    attention: attention,
                    machineRollups: FleetMerge.rollups(
                        inputs.sessions, machines: inputs.machines),
                    generation: generation)
            }.value
            guard !Task.isCancelled,
                  let self,
                  self.fleetGeneration == generation else { return }
            self.fleet = result
        }
    }

    private func scheduleDeadlines() {
        guard let inputs else { return }
        deadlineGeneration += 1
        let generation = deadlineGeneration
        deadlineTask?.cancel()
        deadlineTask = Task { [weak self] in
            let result = await Task.detached(priority: .userInitiated) {
                let metric = NavigationMetrics.beginProjection(
                    .deadlines, generation: generation)
                let attention = AttentionBoard.build(
                    sessions: inputs.sessions,
                    signals: inputs.attentionSignals,
                    now: inputs.now)
                let blocked = Set(attention.items.lazy
                    .filter { $0.state == .blocked }
                    .map { $0.session.project })
                let activity = DeadlineActivity.summarize(
                    inputs.sessions,
                    now: inputs.now,
                    blockedProjects: blocked)
                let cards = DeadlineBoard.build(
                    records: inputs.deadlineRecords,
                    activity: activity,
                    now: inputs.now)
                let tiers = Self.projectDeadlineTiers(inputs.sessions)
                _ = NavigationMetrics.endProjection(metric)
                return DeadlineProjectionSnapshot(
                    cards: cards,
                    tiers: tiers,
                    generation: generation)
            }.value
            guard !Task.isCancelled,
                  let self,
                  self.deadlineGeneration == generation else { return }
            self.deadlines = result
        }
    }

    private nonisolated static func projectSessions(
        _ sessions: [SessionSummary],
        liveTerminalSessionIDs: Set<String>,
        filter: SessionProjectionFilter
    ) -> [SessionSummary] {
        var rows = SessionBrowserFilter(
            topLevelOnly: filter.topLevelOnly,
            liveInTerminalOnly: filter.liveInTerminalOnly)
            .apply(to: sessions,
                   liveTerminalSessionIDs: liveTerminalSessionIDs)
        if let provider = filter.provider {
            rows.removeAll { $0.provider != provider }
        }
        if let tier = filter.tier { rows.removeAll { $0.tier != tier } }
        if let machineID = filter.machineID {
            rows.removeAll { $0.machineID != machineID }
        }
        if filter.activeOnly { rows.removeAll { !$0.isActive } }
        if filter.heavyOnly { rows.removeAll { !$0.isContextHeavy } }
        switch filter.sort {
        case .recent:
            rows.sort {
                let lhs = $0.lastActivity ?? .distantPast
                let rhs = $1.lastActivity ?? .distantPast
                return lhs == rhs ? $0.id < $1.id : lhs > rhs
            }
        case .cost:
            let unsortedKeys: [SessionProjectionCostKey] = rows.enumerated().map {
                SessionProjectionCostKey(
                    index: $0.offset,
                    cost: $0.element.cost,
                    id: $0.element.id)
            }
            let keys = unsortedKeys.sorted {
                    $0.cost == $1.cost ? $0.id < $1.id : $0.cost > $1.cost
            }
            rows = keys.map { rows[$0.index] }
        case .context:
            rows.sort {
                $0.contextWeight == $1.contextWeight
                    ? $0.id < $1.id : $0.contextWeight > $1.contextWeight
            }
        case .tokens:
            rows.sort {
                $0.usage.total == $1.usage.total
                    ? $0.id < $1.id : $0.usage.total > $1.usage.total
            }
        }
        return rows
    }

    private nonisolated static func projectDeadlineTiers(
        _ sessions: [SessionSummary]
    ) -> [String: ModelTier] {
        var best: [String: (date: Date, tier: ModelTier)] = [:]
        for session in sessions where !session.isSubagent {
            guard let date = session.lastActivity else { continue }
            if best[session.project] == nil || date > best[session.project]!.date {
                best[session.project] = (date, session.tier)
            }
        }
        return best.mapValues(\.tier)
    }
}
