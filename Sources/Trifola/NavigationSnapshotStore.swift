import Foundation
import Combine
import TrifolaKit

/// The complete Sessions query. Views own/persist the controls; this Sendable
/// value crosses the actor boundary so sorting/filtering never runs in `body`.
struct SessionProjectionFilter: Sendable, Equatable, Hashable {
    enum Mode: String, Sendable, Hashable {
        case lineage = "Lineage"
        case flat = "Flat"
    }

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
    var mode: Mode = .lineage
    var liveInTerminalOnly = SessionBrowserFilter.defaultLiveInTerminalOnly
    var sort: Sort = .recent
}

struct SessionLineageCounts: Sendable, Equatable {
    var subagents = 0
    var remoteTasks = 0
    var codex = 0
    var imports = 0
    var heuristic = 0

    var total: Int { subagents + remoteTasks + codex + imports + heuristic }
}

/// Ready-to-paint Sessions value. It intentionally contains no transcript
/// usage maps or `SessionSummary`: the main actor receives at most the display
/// cap, while the full corpus remains inside detached projection inputs.
struct SessionLineageDisplayRow: Identifiable, Sendable, Equatable {
    let id: String
    let sessionID: String
    let provider: Provider
    let project: String
    let cwd: String
    let title: String
    let tier: ModelTier
    let model: String?
    let lastActivity: Date?
    let duration: TimeInterval?
    let cost: Double
    let machineID: String
    let isRemote: Bool
    let isActive: Bool
    let isContextHeavy: Bool
    let isMetadataOnly: Bool
    let transcriptNote: String?
    let edgeKind: LineageEdgeKind?
    let confidence: LineageConfidence?
    let edgeDetail: String?
    let spawnDepth: Int
    let displayDepth: Int
    let parentKey: String?
    let parentTitle: String?
    let parentMissingNote: String?
    let hasChildren: Bool
    let descendantCounts: SessionLineageCounts
    let totalDescendantCost: Double
    let isContextOnly: Bool
}

struct SessionProjectionSnapshot: Sendable, Equatable {
    let rows: [SessionLineageDisplayRow]
    let conversationResults: [SearchResult]
    let conversationParentTitles: [String: String]
    let forcedExpandedParentKeys: Set<String>
    let searchState: SearchIndexState
    let sourceCount: Int
    let lineageCounts: SessionLineageCounts
    let isLineageResolving: Bool
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
        let lineageEvidence: SessionLineageEvidence
        let showHeuristicLinks: Bool
        let lineageIsProvisional: Bool
        let now: Date
    }

    private var inputs: Inputs?
    private var sessionGeneration = 0
    /// Resolved forest for one rebuild's inputs. Keystrokes and same-source
    /// refreshes must never pay the ~10k-session resolve again.
    private var lineageMemo:
        (source: Int, includeHeuristics: Bool, forest: SessionLineageForest)?
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
        let mode: SessionProjectionFilter.Mode = {
            if let raw = defaults.string(forKey: AppRestorationKeys.sessionsMode),
               let mode = SessionProjectionFilter.Mode(rawValue: raw) {
                return mode
            }
            // One-way compatibility with the superseded Top-level toggle.
            return bool(AppRestorationKeys.sessionsTopLevelOnly,
                        fallback: true) ? .lineage : .flat
        }()
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
            mode: mode,
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
        lineageEvidence: SessionLineageEvidence,
        showHeuristicLinks: Bool,
        lineageIsProvisional: Bool,
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
            lineageEvidence: lineageEvidence,
            showHeuristicLinks: showHeuristicLinks,
            lineageIsProvisional: lineageIsProvisional,
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
            defaults.set(value.mode.rawValue,
                         forKey: AppRestorationKeys.sessionsMode)
            defaults.set(value.mode == .lineage,
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
        let source = sourceGeneration
        let memo = lineageMemo
        sessionTask?.cancel()
        var state = sessionSearch
        let request = state.begin(query: filter.query)
        sessionSearch = state
        sessionTask = Task { [weak self] in
            if debounce {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            let (result, resolvedLineage) = await Task.detached(priority: .userInitiated) {
                let metric = NavigationMetrics.beginProjection(
                    .sessions, generation: generation)
                var eligibilityFilter = filter
                eligibilityFilter.query = ""
                let eligible = Self.projectEligibleSessions(
                    inputs.sessions,
                    liveTerminalSessionIDs: inputs.liveTerminalSessionIDs,
                    filter: eligibilityFilter,
                    now: inputs.now)
                // The forest depends only on the rebuild inputs, never the
                // filter: keystrokes and same-source refreshes reuse the memo
                // instead of re-resolving ~10k sessions per publish.
                let lineage: SessionLineageForest
                if let memo, memo.source == source,
                   memo.includeHeuristics == inputs.showHeuristicLinks {
                    lineage = memo.forest
                } else {
                    lineage = SessionLineage.resolve(
                        sessions: inputs.sessions,
                        evidence: inputs.lineageEvidence,
                        includeHeuristicLinks: inputs.showHeuristicLinks)
                }
                let projected = Self.projectLineage(
                    lineage,
                    summaries: inputs.sessions,
                    liveTerminalSessionIDs: inputs.liveTerminalSessionIDs,
                    filter: filter,
                    now: inputs.now)
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
                    results = candidates.prefix(20).map { candidate in
                        // Index-served snippets: query-time file rereads took
                        // 15s+ against multi-hundred-MB live transcripts. The
                        // stored row IS the parsed truth (same triggers keep
                        // it in sync); the reread survives only as a fallback.
                        let snippet: SearchSnippet?
                        if let stored = inputs.searchIndex.bestMatchContent(
                            sessionID: candidate.id,
                            filePath: candidate.filePath,
                            query: query) {
                            let excerpt = SearchSnippetExtractor.excerpt(
                                from: stored, terms: query.tokens)
                            snippet = SearchSnippet(
                                text: excerpt,
                                highlights: SearchSnippetExtractor.highlights(
                                    in: excerpt, terms: query.tokens),
                                role: "")
                        } else {
                            snippet = SearchSnippetExtractor.snippet(
                                for: candidate, query: query)
                        }
                        return SearchResult(candidate: candidate, snippet: snippet)
                    }
                }
                let conversationParents = Dictionary(
                    results.compactMap { result -> (String, String)? in
                        guard let parent = projected.parentTitlesBySessionID[result.id]
                        else { return nil }
                        return (result.id, parent)
                    }, uniquingKeysWith: { first, _ in first })
                _ = NavigationMetrics.endProjection(metric)
                return (SessionProjectionSnapshot(
                    rows: projected.rows,
                    conversationResults: results,
                    conversationParentTitles: conversationParents,
                    forcedExpandedParentKeys: projected.forcedExpandedParentKeys,
                    searchState: inputs.searchState,
                    sourceCount: inputs.sessions.count,
                    lineageCounts: projected.counts,
                    isLineageResolving: inputs.lineageIsProvisional,
                    filter: filter,
                    generation: generation), lineage)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.lineageMemo = (
                source: source,
                includeHeuristics: inputs.showHeuristicLinks,
                forest: resolvedLineage)
            guard self.sessionGeneration == generation else { return }
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

    private struct ProjectedLineage {
        let rows: [SessionLineageDisplayRow]
        let counts: SessionLineageCounts
        let forcedExpandedParentKeys: Set<String>
        let parentTitlesBySessionID: [String: String]
    }

    private nonisolated static func projectEligibleSessions(
        _ sessions: [SessionSummary],
        liveTerminalSessionIDs: Set<String>,
        filter: SessionProjectionFilter,
        now: Date
    ) -> [SessionSummary] {
        var rows = sessions
        if filter.liveInTerminalOnly {
            rows.removeAll { !liveTerminalSessionIDs.contains($0.id) }
        }
        if let provider = filter.provider {
            rows.removeAll { $0.provider != provider }
        }
        if let tier = filter.tier { rows.removeAll { $0.tier != tier } }
        if let machineID = filter.machineID {
            rows.removeAll { $0.machineID != machineID }
        }
        if filter.activeOnly { rows.removeAll { !$0.isActive(at: now) } }
        if filter.heavyOnly { rows.removeAll { !$0.isContextHeavy } }
        return rows
    }

    private nonisolated static func sortSessions(
        _ input: [SessionSummary], by sort: SessionProjectionFilter.Sort
    ) -> [SessionSummary] {
        var rows = input
        switch sort {
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

    private nonisolated static func projectLineage(
        _ forest: SessionLineageForest,
        summaries: [SessionSummary],
        liveTerminalSessionIDs: Set<String>,
        filter: SessionProjectionFilter,
        now: Date
    ) -> ProjectedLineage {
        let summaryByKey = Dictionary(
            summaries.map { (SessionLineage.key($0), $0) },
            uniquingKeysWith: { first, _ in first })
        var counts = SessionLineageCounts()
        for node in forest.allNodes where node.spawnDepth > 0 {
            switch node.edgeKind {
            case .subagent: counts.subagents += 1
            case .remoteTask: counts.remoteTasks += 1
            case .codexSpawn, .codexFork: counts.codex += 1
            case .importBridge: counts.imports += 1
            case .orchestrated: counts.heuristic += 1
            case nil: break
            }
        }

        func matchesStructure(_ node: LineageNode) -> Bool {
            let reference = node.session
            if let provider = filter.provider, reference.provider != provider { return false }
            if let tier = filter.tier, reference.tier != tier { return false }
            if let machine = filter.machineID, reference.machineID != machine { return false }
            if filter.liveInTerminalOnly,
               !liveTerminalSessionIDs.contains(reference.id) { return false }
            guard let summary = summaryByKey[reference.stableKey] else {
                return !filter.activeOnly && !filter.heavyOnly
            }
            if filter.activeOnly && !summary.isActive(at: now) { return false }
            if filter.heavyOnly && !summary.isContextHeavy { return false }
            return true
        }

        let query = filter.query.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        func matchesQuery(_ node: LineageNode) -> Bool {
            guard !query.isEmpty else { return true }
            let value = node.session
            return value.project.lowercased().contains(query)
                || value.title.lowercased().contains(query)
                || value.cwd.lowercased().contains(query)
                || value.id.lowercased().hasPrefix(query)
        }

        var descendantCountCache: [String: SessionLineageCounts] = [:]
        func descendantCounts(_ node: LineageNode) -> SessionLineageCounts {
            if let cached = descendantCountCache[node.session.stableKey] {
                return cached
            }
            var result = SessionLineageCounts()
            for child in node.children {
                switch child.edgeKind {
                case .subagent: result.subagents += 1
                case .remoteTask: result.remoteTasks += 1
                case .codexSpawn, .codexFork: result.codex += 1
                case .importBridge: result.imports += 1
                case .orchestrated: result.heuristic += 1
                case nil: break
                }
                let nested = descendantCounts(child)
                result.subagents += nested.subagents
                result.remoteTasks += nested.remoteTasks
                result.codex += nested.codex
                result.imports += nested.imports
                result.heuristic += nested.heuristic
            }
            descendantCountCache[node.session.stableKey] = result
            return result
        }

        var descendantCostCache: [String: Double] = [:]
        func descendantCost(_ node: LineageNode) -> Double {
            if let cached = descendantCostCache[node.session.stableKey] {
                return cached
            }
            let cost = node.children.reduce(0) { partial, child in
                partial + child.session.cost + descendantCost(child)
            }
            descendantCostCache[node.session.stableKey] = cost
            return cost
        }

        func ordered(_ nodes: [LineageNode]) -> [LineageNode] {
            nodes.sorted { lhs, rhs in
                switch filter.sort {
                case .recent:
                    let l = lhs.session.lastActivity ?? .distantPast
                    let r = rhs.session.lastActivity ?? .distantPast
                    return l == r ? lhs.id < rhs.id : l > r
                case .cost:
                    return lhs.session.cost == rhs.session.cost
                        ? lhs.id < rhs.id : lhs.session.cost > rhs.session.cost
                case .context:
                    return lhs.session.contextWeight == rhs.session.contextWeight
                        ? lhs.id < rhs.id
                        : lhs.session.contextWeight > rhs.session.contextWeight
                case .tokens:
                    return lhs.session.totalTokens == rhs.session.totalTokens
                        ? lhs.id < rhs.id
                        : lhs.session.totalTokens > rhs.session.totalTokens
                }
            }
        }

        func displayRow(_ node: LineageNode, parent: LineageNode?,
                        contextOnly: Bool) -> SessionLineageDisplayRow {
            let summary = summaryByKey[node.session.stableKey]
            return SessionLineageDisplayRow(
                id: node.session.stableKey,
                sessionID: node.session.id,
                provider: node.session.provider,
                project: node.session.project,
                cwd: node.session.cwd,
                title: node.session.title,
                tier: node.session.tier,
                model: node.session.model,
                lastActivity: node.session.lastActivity,
                duration: node.session.duration,
                cost: node.session.cost,
                machineID: node.session.machineID,
                isRemote: node.session.machineID != Machine.localID,
                isActive: summary?.isActive(at: now) ?? false,
                isContextHeavy: summary?.isContextHeavy ?? false,
                isMetadataOnly: node.session.isMetadataOnly,
                transcriptNote: node.session.transcriptNote,
                edgeKind: node.edgeKind,
                confidence: node.confidence,
                edgeDetail: node.edgeDetail,
                spawnDepth: node.spawnDepth,
                displayDepth: node.displayDepth,
                parentKey: parent?.session.stableKey,
                parentTitle: parent?.session.title,
                parentMissingNote: node.parentMissingNote,
                hasChildren: !node.children.isEmpty,
                descendantCounts: descendantCounts(node),
                totalDescendantCost: descendantCost(node),
                isContextOnly: contextOnly)
        }

        var rows: [SessionLineageDisplayRow] = []
        var forced: Set<String> = []
        var parentTitles: [String: String] = [:]

        @discardableResult
        func appendLineage(_ node: LineageNode, parent: LineageNode?) -> Bool {
            let ownMatch = matchesStructure(node) && matchesQuery(node)
            var childGroups: [[SessionLineageDisplayRow]] = []
            var anyChild = false
            for child in ordered(node.children) {
                let start = rows.count
                let matched = appendLineage(child, parent: node)
                if matched {
                    childGroups.append(Array(rows[start...]))
                    rows.removeSubrange(start...)
                    anyChild = true
                }
            }
            let include = ownMatch || anyChild
            guard include else { return false }
            let contextOnly = !ownMatch && anyChild
            rows.append(displayRow(node, parent: parent, contextOnly: contextOnly))
            if anyChild && !query.isEmpty { forced.insert(node.session.stableKey) }
            for group in childGroups { rows.append(contentsOf: group) }
            if let parent {
                parentTitles[node.session.id] = parent.session.title
            }
            return true
        }

        if filter.mode == .flat {
            let eligible = projectEligibleSessions(
                summaries,
                liveTerminalSessionIDs: liveTerminalSessionIDs,
                filter: filter,
                now: now)
            let matches = SessionBrowserSearch.titlePathMatches(
                eligible, query: filter.query)
            rows = sortSessions(matches, by: filter.sort).prefix(400).map { summary in
                let reference = LineageSessionReference(summary: summary)
                let node = LineageNode(
                    session: reference, children: [], edgeKind: nil,
                    confidence: nil, spawnDepth: 0, displayDepth: 0,
                    parentMissingNote: nil, edgeDetail: nil)
                return displayRow(node, parent: nil, contextOnly: false)
            }
        } else {
            for root in ordered(forest.roots) {
                _ = appendLineage(root, parent: nil)
                if rows.count >= 400 { break }
            }
            rows = Array(rows.prefix(400))
        }
        return ProjectedLineage(
            rows: rows,
            counts: counts,
            forcedExpandedParentKeys: forced,
            parentTitlesBySessionID: parentTitles)
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
