import Foundation
import AppKit
import SwiftUI
import Combine
import TrifolaKit

enum AppRestorationKeys {
    static let section = "trifola.restoration.section"
    static let inspectorSessionID = "trifola.restoration.inspectorSessionID"
    static let sessionsQuery = "trifola.restoration.sessions.query"
    static let sessionsTier = "trifola.restoration.sessions.tier"
    static let sessionsMachine = "trifola.restoration.sessions.machine"
    static let sessionsActiveOnly = "trifola.restoration.sessions.activeOnly"
    static let sessionsHeavyOnly = "trifola.restoration.sessions.heavyOnly"
    static let sessionsTopLevelOnly = "trifola.restoration.sessions.topLevelOnly"
    static let sessionsLiveInTerminalOnly = "trifola.restoration.sessions.liveInTerminalOnly"
    static let sessionsSort = "trifola.restoration.sessions.sort"
}

enum AppSection: String, CaseIterable, Identifiable {
    // Fleet Board rides next to Live Now — the two converge (the Board is the room;
    // the transcript tiles are the drill-in desk view). VISION Pillar 4 / docs/FLEET_BOARD.md.
    // The Ledger rides between AUDIT and LAUNCH — the closed loop is SEE → AUDIT →
    // DREAMING LEDGER → LAUNCH, so the capstone sits where the findings become
    // fixes. docs/DREAMING_LEDGER.md §2.
    // The Deadline Board rides right after the Fleet Board — the Floor's sibling, one
    // horizon over (docs/DEADLINE_BOARD.md §2): the Floor asks "who needs me NOW?",
    // the Deadline Board asks "what's due and ROTTING?".
    case overview, live, fleet, deadlines, sessions, spend, audit, ledger, launch, stack
    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: return "Overview"
        case .live: return "Live Now"
        case .fleet: return "Fleet Board"
        case .deadlines: return "Deadlines"
        case .sessions: return "Sessions"
        case .spend: return "Spend & Routing"
        case .audit: return "Audit"
        case .ledger: return "Ledger"
        case .launch: return "Launch"
        case .stack: return "Stack"
        }
    }
    var icon: String {
        switch self {
        case .overview: return "gauge.with.dots.needle.67percent"
        case .live: return "dot.radiowaves.left.and.right"
        case .fleet: return "square.grid.3x3"
        case .deadlines: return "calendar.badge.exclamationmark"
        case .sessions: return "square.stack.3d.up"
        case .spend: return "chart.pie"
        case .audit: return "exclamationmark.magnifyingglass"
        case .ledger: return "moon.stars"
        case .launch: return "paperplane"
        case .stack: return "server.rack"
        }
    }
}

/// Navigation motion is a property of the input, not the destination. Pointer
/// selection earns spatial continuity; keyboard, palette, restoration and deep
/// links remain hard cuts through the single transaction in `select`.
enum NavOrigin {
    case pointer
    case keyboard
    case programmatic
}

/// A fresh generation is published for every Tier-3 reveal, even if the same
/// session inspector is already selected. The UI keys scroll/highlight/toast
/// behavior from this token, making fallback observably non-idempotent.
struct TerminalTranscriptReveal: Equatable {
    let sessionID: String
    let generation: Int
    let feedback: TerminalLaunchFeedback
}

/// Owns the stores, the FSEvents wiring and the navigation state. One instance
/// for the whole app; everything on the MainActor.
@MainActor
final class AppServices: ObservableObject {
    let navigation = AppNavigation()
    let navigationSnapshots = NavigationSnapshotStore()
    let claudePaths: ClaudePaths
    let codexPaths: CodexPaths
    let sessions: SessionStore
    let audit: RoutingAudit
    let stack = StackStore()
    let skills: SkillsStore
    let attention = AttentionStore()
    /// The AUDIT pillar: cache-miss dollars, dead-skill ledger, subagent doctrine,
    /// model-mismatch review candidates — the four findings, computed from disk.
    let auditReport = AuditStore()
    /// The LAUNCH pillar: saved recipes + composition/spawn plumbing.
    let launch = LaunchStore()
    /// The Fleet Board ("the Floor"): per-session now-line signals (subagents
    /// included) + the persistent arrival ledger that gives every bay a stable seat.
    let fleet = FleetStore()
    /// THE DREAMING LEDGER (v1 · Lessons): mints copy-able candidate fixes from the
    /// audit report + settings, deterministically. The capstone / moat.
    let ledger = LedgerStore()
    /// THE DEADLINE BOARD (docs/DEADLINE_BOARD.md): parses deadlines from
    /// MEMORY.md/NOTES.md → confirm → .toml override (canonical, app-owned), and
    /// drives the one-way Linear exporter. The Floor's sibling under Pillar 4.
    let deadlines = DeadlineStore()
    /// THE CROSS-MACHINE FLEET (the differentiator): loads the fleet config (seeded
    /// with workstation), mirrors each remote's transcripts READ-ONLY over Tailscale SSH,
    /// and holds the per-remote online/offline status. The SessionStore merges the
    /// mirrors in, so every pillar covers the whole fleet, not half of it.
    let machines = MachineStore()
    /// settings.json defaults (model + effort) — the L-005 effort-furnace input,
    /// refreshed with the fleet.
    private(set) var settings = ClaudeSettings()
    /// WALK-AWAY NOTIFY (frontier #2): the ONE allowed notification. Each refresh +
    /// heartbeat tick diffs the board's BLOCKED set and posts a single macOS
    /// notification on the RISING edge, so a walk-away operator knows a session needs
    /// them without watching the window. Opt-in (default OFF), persisted to the app's
    /// own dir; degrades silently when unauthorized.
    let notifier = BlockedNotifierService()
    /// Low-frequency Settings preferences (quiet hours + default snooze).
    let preferences = AppPreferencesModel()
    /// Optional Accessibility trust UX for exact terminal-workspace jumps. This
    /// stays on its own observable so a rare prompt/status refresh never becomes
    /// another high-frequency AppServices publication source.
    let permissionFlowGate: PermissionFlowSessionGate
    let workspaceAccess: WorkspaceAccessCoordinator
    let automationAccess: AutomationAccessCoordinator
    /// Persistent snooze/mute agency plus the visual blocked→running closure beat.
    let agency = AgencyController()
    /// PLAN QUOTA (W7): the REAL rate-limit windows (5h · weekly · model-scoped)
    /// from the OAuth usage endpoint, read-only. Its own 5-min throttle keeps the
    /// FSEvents-driven refreshAll() calls cheap.
    let quota: QuotaStore
    /// One-shot launch choreography state. It is intentionally not published:
    /// claiming a reveal must never turn a decorative animation into a render
    /// source for the whole app.
    let reveals = Reveal.Registry()
    /// First-run truth across every supported local provider. Checked at launch
    /// and after each coalesced refresh, never in a hot SwiftUI body.
    @Published private(set) var providerCorpusPresence: ProviderCorpusPresence

    // MENU-BAR PRESENCE lives on its own `MenuBarPresence` object (not here) so the
    // App scene's menu/MenuBarExtra don't observe this high-frequency store — see
    // MenuBarPresence.swift for the render-storm rationale.

    /// A skill ref the Skill hierarchy asked to seed the builder with (its Launch
    /// button). LaunchScreen consumes + clears it on appear.
    @Published var pendingSkillSeed: String? = nil

    /// The ⌘K command palette is up (VISION 3.4). Toggled by the App scene's ⌘K
    /// command; RootView presents the overlay while it's true.
    @Published var showPalette = false

    @AppStorage(AppRestorationKeys.inspectorSessionID) private var persistedInspectorID = ""

    // Read-only compatibility for commands, render fixtures, and the launch
    // benchmark. AppNavigation is deliberately not forwarded through this
    // object's publisher, so section selection cannot invalidate store views.
    var section: AppSection { navigation.section }
    var firstAppearanceSection: AppSection? { navigation.firstAppearanceSection }
    var navigationOrigin: NavOrigin { navigation.navigationOrigin }
    var navigationMetricGeneration: Int { navigation.navigationMetricGeneration }
    var navigationMetricJourney: NavigationMetricJourney? {
        navigation.navigationMetricJourney
    }
    @Published var selectedSessionID: String? = nil {
        didSet {
            guard selectedSessionID != oldValue else { return }
            if let selectedSessionID {
                pendingRestoredSessionID = nil
                persistedInspectorID = selectedSessionID
            } else if pendingRestoredSessionID == nil {
                persistedInspectorID = ""
            }
            if let selectedSessionID,
               let session = sessions.sessions.first(where: { $0.id == selectedSessionID }) {
                prepareSessionOpenAction(for: session, force: true)
            }
        }
    }
    @Published private(set) var terminalTranscriptReveal: TerminalTranscriptReveal? = nil
    @Published private(set) var sessionOpenActions: [String: SessionOpenActionPresentation] = [:]
    @Published private(set) var liveTerminalSessionIDs: Set<String> = []
    @Published private(set) var liveTerminalSnapshotFailure: String? = nil
    /// Heartbeat so relative timestamps ("3m ago", `isActive`) re-render.
    @Published var now = Date()

    private var watcher: FSEventsWatcher?
    private var ticker: Task<Void, Never>?
    private var sessionsDebounce: Task<Void, Never>?
    private var pendingDebouncedSessionPaths: Set<String> = []
    private var pendingDebouncedSettings = false
    private var refreshTask: Task<Void, Never>?
    private var refreshQueued = false
    private var refreshQueuedSessionPaths: Set<String> = []
    private var refreshQueuedNeedsFullSessionScan = false
    private var refreshQueuedOpenAction = false
    private var terminalLaunchTask: Task<Void, Never>?
    /// The session whose terminal launch is in flight. Drives the button's
    /// immediate "Opening…" state and coalesces repeat clicks — the ladder can
    /// legitimately take seconds (it spawns the workspace host's controller
    /// binary several times), and silence read as a dead button.
    @Published private(set) var launchingSessionID: String?
    private var terminalRevealGeneration = 0
    private var pendingRestoredSessionID: String?
    private var pendingSessionOpenActionIDs: Set<String> = []
    private var didRunLaunchDream = false
    private var forwarders: Set<AnyCancellable> = []

    init(claudePaths: ClaudePaths = .process,
         codexPaths: CodexPaths = .process) {
        let permissionFlowGate = PermissionFlowSessionGate()
        self.permissionFlowGate = permissionFlowGate
        self.workspaceAccess = WorkspaceAccessCoordinator(
            sessionGate: permissionFlowGate)
        self.automationAccess = AutomationAccessCoordinator(
            sessionGate: permissionFlowGate)
        self.claudePaths = claudePaths
        self.codexPaths = codexPaths
        self.sessions = SessionStore(paths: claudePaths, codexPaths: codexPaths)
        self.audit = RoutingAudit(paths: claudePaths)
        self.skills = SkillsStore(paths: claudePaths)
        self.quota = QuotaStore(paths: claudePaths)
        self.providerCorpusPresence = ProviderCorpusPresence.detect(
            claudePaths: claudePaths,
            codexPaths: codexPaths)

        self.pendingRestoredSessionID = persistedInspectorID.isEmpty
            ? nil : persistedInspectorID

        // Nested-ObservableObject trap: views observe THIS object, but the data
        // lives in child stores. Forward every child publish so progressive scan
        // results (and any other store change) actually re-render the UI.
        sessions.objectWillChange
            .merge(with: audit.objectWillChange, stack.objectWillChange)
            .merge(with: attention.objectWillChange)
            .merge(with: skills.objectWillChange, auditReport.objectWillChange)
            .merge(with: launch.objectWillChange, fleet.objectWillChange)
            .merge(with: ledger.objectWillChange, machines.objectWillChange)
            .merge(with: notifier.objectWillChange, deadlines.objectWillChange)
            .merge(with: quota.objectWillChange)
            .merge(with: preferences.objectWillChange, agency.objectWillChange)
            // THROTTLE the merged forward, ~7/sec max. Every child publish here
            // triggers a FULL-tree re-render (the whole window observes AppServices);
            // a child that publishes rapidly (a progressive scan, the Tailscale
            // machine mirror) drove the tree to re-render at its raw rate →
            // a 100% CPU render storm INDEPENDENT of the FSEvents debounces (which is
            // why widening those alone didn't fix it). Coalescing here caps the
            // re-render rate regardless of which store spams; 140ms is imperceptible
            // for a dashboard. `latest: true` keeps the final state of each burst.
            // 1s, not 140ms: a single full re-render over ~5k sessions costs ~140ms
            // (the Overview/burn aggregations walk every session), so a 140ms floor
            // left the tree rendering back-to-back (~100% CPU). A 1s floor puts the
            // render at ~14% duty cycle; 1s update latency is invisible on a dashboard.
            .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &forwarders)

        // Each committed FTS batch is immediately queryable through WAL. Refresh
        // the detached search projection at a bounded cadence so a first-run query
        // gains partial results without waiting for the final batch.
        sessions.$searchProgress
            .removeDuplicates()
            .dropFirst()
            .throttle(for: .milliseconds(250), scheduler: DispatchQueue.main,
                      latest: true)
            .sink { [weak self] _ in self?.refreshNavigationSnapshots() }
            .store(in: &forwarders)

        // The optional user-defined tier must be configured BEFORE the first
        // index load: summaries (and their tier roll-ups) derive from cached
        // accumulators at load time, so this re-tiers the whole corpus with no
        // reparse. Changes re-derive existing summaries in place.
        ModelTier.configureUserTier(preferences.value.userTier)
        preferences.$value
            .map(\.userTier)
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] tier in
                ModelTier.configureUserTier(tier)
                self?.sessions.rederiveSummaries()
            }
            .store(in: &forwarders)

        // Apply quota trust changes immediately. Turning a provider off clears
        // its in-memory snapshot without touching that provider's read boundary;
        // turning it on performs the newly-authorized probe once.
        preferences.$value
            .map(QuotaConsent.init(preferences:))
            .removeDuplicates()
            .dropFirst()
            .sink { [weak self] consent in
                guard let self else { return }
                Task { @MainActor in
                    await self.quota.refresh(
                        consent: consent,
                        minInterval: 0)
                }
            }
            .store(in: &forwarders)

        // Walk-Away Notify: clicking a BLOCKED banner focuses that session's live
        // detail (the honest bridge falls back to activating the app).
        notifier.onActivateSession = { [weak self] id in
            guard let self, let s = self.sessions.sessions.first(where: { $0.id == id }) else { return }
            MainWindowPresenter.present()
            self.inspect(s)
        }
        notifier.onSnoozeSession = { [weak self] id in
            guard let self, let s = self.sessions.sessions.first(where: { $0.id == id }) else { return }
            self.agency.snoozeOneHour(s, now: self.now)
        }
        notifier.preferencesProvider = { [weak self] in
            self?.preferences.value ?? AppPreferences()
        }
        machines.onConfigChanged = { [weak self] in
            guard let self else { return }
            self.sessions.remoteSources = self.machines.remoteSources
            self.machines.syncInBackground()
            self.refreshAll()
        }
    }

    /// Compatibility entry point used by commands and deep links. Navigation's
    /// publisher stays isolated from this store-owned application model.
    func select(_ newSection: AppSection, origin: NavOrigin) {
        navigation.select(newSection, origin: origin)
    }

    func navigationDidAppear(_ appearedSection: AppSection) {
        navigation.navigationDidAppear(appearedSection)
    }

    /// The Skill hierarchy's Launch button: jump to the builder, seeded with a
    /// skill ref. The builder folds it into the current draft on appear.
    func seedLaunch(skill: String) {
        pendingSkillSeed = skill
        select(.launch, origin: .programmatic)
    }

    /// Distinct existing `<cwd>/.claude/skills` dirs across recent sessions — the
    /// project lane for the skill hierarchy (capped so the scan stays cheap).
    private nonisolated static func projectSkillDirs(
        sessions: [SessionSummary]
    ) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        let fm = FileManager.default
        for s in sessions where !s.cwd.isEmpty && !s.isSubagent {
            guard seen.insert(s.cwd).inserted else { continue }
            let dir = (s.cwd as NSString).appendingPathComponent(".claude/skills")
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: dir, isDirectory: &isDir), isDir.boolValue { out.append(dir) }
            if out.count >= 12 { break }
        }
        return out
    }

    func start() {
        guard watcher == nil else { return }

        // Deadline Board: hydrate the app-owned records + Linear connection state.
        deadlines.start()

        // Cross-Machine Fleet: load the config (seeds workstation), wire any already-synced
        // mirrors into the SessionStore, then kick a best-effort background sync. When
        // it finishes, re-wire + refresh so newly-mirrored sessions merge in. All of
        // this is bounded/best-effort — a down workstation just leaves the fleet local-only.
        machines.load()
        sessions.remoteSources = machines.remoteSources
        machines.onSynced = { [weak self] in
            guard let self else { return }
            self.sessions.remoteSources = self.machines.remoteSources
            self.machines.refreshStatuses(sessionCounts: self.machineSessionCounts())
            self.refreshAll()
        }
        machines.syncInBackground()

        refreshAll()

        let projectsPrefix = claudePaths.projects.standardizedFileURL.path + "/"
        let settingsPath = claudePaths.settingsJSON.standardizedFileURL.path
        // The SessionStore already scans ~/.codex as a second provider; watch it
        // too (when present) so Codex rollouts refresh live, not just on the next
        // Claude-triggered pass. Codex archives older rollouts as .jsonl.zst.
        let codexPrefix = codexPaths.sessions.standardizedFileURL.path + "/"
        var watchPaths = [claudePaths.root.path]
        if FileManager.default.fileExists(atPath: codexPaths.root.path) {
            watchPaths.append(codexPaths.root.path)
        }
        let watcher = FSEventsWatcher(paths: watchPaths) { [weak self] paths in
            var sessionPaths: Set<String> = [], settingsDirty = false
            for p in paths {
                let standardized = URL(fileURLWithPath: p).standardizedFileURL.path
                if standardized.hasPrefix(projectsPrefix) && standardized.hasSuffix(".jsonl") {
                    sessionPaths.insert(standardized)
                } else if standardized.hasPrefix(codexPrefix)
                            && (standardized.hasSuffix(".jsonl") || standardized.hasSuffix(".jsonl.zst")) {
                    sessionPaths.insert(standardized)
                } else if standardized == settingsPath {
                    settingsDirty = true
                }
            }
            guard !sessionPaths.isEmpty || settingsDirty else { return }
            let changed = sessionPaths, settings = settingsDirty
            Task { @MainActor [weak self] in
                self?.handleChanges(sessionPaths: changed, settings: settings)
            }
        }
        self.watcher = watcher
        watcher.start()

        // heartbeat + belt-and-braces refresh if events were missed. Ticks every
        // 10s (not 30s) so time-driven attention transitions surface fast: a
        // BLOCKED session's file stops changing the instant it blocks, so only
        // this `now` tick can flip RUNNING→BLOCKED at the 30s threshold.
        ticker = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(10))
                guard let self else { return }
                self.now = Date()
                // Catch time-driven flips into BLOCKED (30s threshold, no file event).
                let board = await self.rebuildAttentionBoardOffMain(
                    priority: .background)
                self.evaluateNotifications(board: board)
                self.navigationSnapshots.refreshHeartbeat(
                    attention: board, now: self.now)
                if Date().timeIntervalSince(self.sessions.lastRefresh) > 120 {
                    self.refreshAll()
                }
            }
        }
    }

    // MARK: Attention

    /// The recent pool the attention system reads tails for — sessions touched
    /// within the board window (a bit beyond the 15m live threshold so a cooling
    /// session shows as IDLE for a while), interactive only (no subagents).
    private func attentionCandidates() -> [SessionSummary] {
        let cutoff = Date()
        return sessions.sessions.filter {
            guard let d = $0.lastActivity, !$0.isSubagent else { return false }
            let age = cutoff.timeIntervalSince(d)
            return age >= 0 && age <= AttentionBoard.defaultWindow
        }
    }

    /// One tick's attention board, memoized. Several surfaces rebuild the board
    /// per body pass (the strip, the sidebar wordmark, the dock badge, the
    /// palette, notify evaluation) — each build walks all sessions (~16ms
    /// measured over 5.3k), so per-pass rebuilds multiplied into real main-
    /// thread cost. Inputs are (sessions, signals, now); the store revisions
    /// stamp the first two, so within one heartbeat tick every caller shares
    /// ONE build.
    private var boardCache: (now: Date, sessionsRev: Int, signalsRev: Int, board: AttentionBoard)?

    /// The live attention board, classified against the heartbeat `now`.
    /// Served from the per-tick memo; rebuilt only when sessions, signals, or
    /// `now` actually changed.
    func attentionBoard(now: Date? = nil) -> AttentionBoard {
        let n = now ?? self.now
        if let c = boardCache, c.now == n,
           c.sessionsRev == sessions.revision, c.signalsRev == attention.revision {
            return c.board
        }
        let board = AttentionBoard.build(sessions: sessions.sessions,
                                         signals: attention.signals,
                                         now: n)
        boardCache = (n, sessions.revision, attention.revision, board)
        return board
    }

    private func rebuildAttentionBoardOffMain(
        priority: TaskPriority = .userInitiated
    ) async -> AttentionBoard {
        let summaries = sessions.sessions
        let signals = attention.signals
        let instant = now
        let sessionsRevision = sessions.revision
        let signalsRevision = attention.revision
        let board = await Task.detached(priority: priority) {
            AttentionBoard.build(
                sessions: summaries, signals: signals, now: instant)
        }.value
        if sessions.revision == sessionsRevision,
           attention.revision == signalsRevision,
           now == instant {
            boardCache = (instant, sessionsRevision, signalsRevision, board)
        }
        return board
    }

    /// Agency applied to the raw board. The result retains every row for honest
    /// rendering and exposes a filtered board solely for interrupting surfaces.
    func attentionSuppression(now: Date? = nil) -> AttentionSuppressionResult {
        let n = now ?? self.now
        return agency.result(for: attentionBoard(now: n), now: n)
    }

    func alertingAttentionBoard(now: Date? = nil) -> AttentionBoard {
        attentionSuppression(now: now).alertingBoard
    }

    /// Count of BLOCKED sessions — the dock badge + menu-bar number.
    var blockedCount: Int { alertingAttentionBoard().blockedCount }

    /// Capture immutable inputs on the main actor, then let the projection store
    /// perform every corpus walk off-main. Calling this is cheap and safe from
    /// refresh, heartbeat, and explicit deadline mutations.
    func refreshNavigationSnapshots() {
        navigationSnapshots.rebuild(
            sessions: sessions.sessions,
            attentionSignals: attention.signals,
            fleetSignals: fleet.signals,
            arrival: fleet.arrival,
            deadlineRecords: deadlines.records,
            machines: sessions.fleetMachines,
            liveTerminalSessionIDs: liveTerminalSessionIDs,
            searchIndex: sessions.searchIndex,
            searchState: sessions.searchState,
            now: now)
    }

    // MARK: Deadline Board

    /// Projects with a BLOCKED live session — folded into the deadline classifier so a
    /// blocked-near-deadline project reads AT-RISK.
    func blockedProjects(now: Date? = nil) -> Set<String> {
        Set(attentionBoard(now: now).items.filter { $0.state == .blocked }.map { $0.session.project })
    }

    /// The jeopardy-sorted deadline board — the JOIN of the app-owned deadline records
    /// with the live per-project activity, classified against the heartbeat `now`.
    func deadlineCards(now: Date? = nil) -> [DeadlineCard] {
        let n = now ?? self.now
        return deadlines.cards(sessions: sessions.sessions, now: n, blocked: blockedProjects(now: n))
    }

    /// WALK-AWAY NOTIFY: diff the live board against what was last notified and post
    /// on the rising edge. Called from BOTH the refresh cycle (a file-driven flip)
    /// and the heartbeat ticker (a time-driven RUNNING→BLOCKED at the 30s threshold,
    /// which changes no file). Rising-edge dedup means the two callers never
    /// double-notify.
    func evaluateNotifications(board: AttentionBoard? = nil) {
        let raw = board ?? attentionBoard(now: now)
        agency.observe(board: raw, now: now)
        notifier.evaluate(board: agency.result(for: raw, now: now).alertingBoard,
                          signals: attention.signals)
    }

    // MARK: Dreaming Ledger

    /// Pending lesson count — the sidebar signal (docs §5: "A count in the sidebar
    /// item is the entire signal" — no nags, no badges beyond this).
    var pendingLessonCount: Int { ledger.pending.count }

    /// Run a recorded dream pass from the current findings + settings. Deterministic:
    /// "Dream now" and the on-launch pass share this one path.
    func dreamNow(trigger: DreamTrigger) {
        settings = ClaudeSettings.load(paths: claudePaths)
        ledger.dream(report: auditReport.report, catalog: skills.skills, settings: settings,
                     sessionsScanned: sessions.sessions.count, trigger: trigger)
    }

    // MARK: Fleet Board

    /// The Floor, classified against the heartbeat `now`. Uses the fleet store's
    /// STORED arrival ledger read-only (the returned/advanced ledger is discarded
    /// here) so `now`-driven state changes reclassify tokens in place while bay and
    /// token order stay frozen at their arrival seats. Cheap to rebuild in `body`.
    func fleetBoard(now: Date? = nil) -> FleetBoard {
        FleetBoard.build(sessions: sessions.sessions, signals: fleet.signals,
                         now: now ?? self.now, arrival: fleet.arrival).board
    }

    func refreshAll(changedSessionPaths: Set<String>? = nil,
                    refreshSelectedOpenAction: Bool = false) {
        refreshQueuedOpenAction = refreshQueuedOpenAction || refreshSelectedOpenAction
        guard refreshTask == nil else {
            refreshQueued = true
            if let changedSessionPaths {
                refreshQueuedSessionPaths.formUnion(changedSessionPaths)
            } else {
                refreshQueuedNeedsFullSessionScan = true
            }
            return
        }
        let wantsOpenAction = refreshQueuedOpenAction
        refreshQueuedOpenAction = false
        refreshTask = Task { [weak self] in
            guard let self else { return }
            await self.performRefreshAll(
                changedSessionPaths: changedSessionPaths,
                refreshSelectedOpenAction: wantsOpenAction)
            self.refreshTask = nil
            if self.refreshQueued {
                let nextPaths = self.refreshQueuedNeedsFullSessionScan
                    ? nil : self.refreshQueuedSessionPaths
                self.refreshQueued = false
                self.refreshQueuedNeedsFullSessionScan = false
                self.refreshQueuedSessionPaths = []
                self.refreshAll(
                    changedSessionPaths: nextPaths,
                    refreshSelectedOpenAction: self.refreshQueuedOpenAction)
            }
        }
    }

    var isRefreshCascadeRunning: Bool { refreshTask != nil }

    private func performRefreshAll(changedSessionPaths: Set<String>?,
                                   refreshSelectedOpenAction: Bool) async {
        await Perf.span("await:sessions.refreshNow") {
            await sessions.refreshNow(changedPaths: changedSessionPaths)
        }
        await refreshLiveTerminalSnapshot()
        // Sessions can hydrate immediately from the parsed cache; do not make
        // its first visit wait for audit/ledger/deadline refresh work.
        refreshNavigationSnapshots()
        reconcileRestoredSelection()
        if refreshSelectedOpenAction, let selectedSession {
            prepareSessionOpenAction(for: selectedSession, force: true)
        }

        let claudePaths = self.claudePaths
        let codexPaths = self.codexPaths
        let corpusPresence = await Task.detached(priority: .utility) {
            ProviderCorpusPresence.detect(
                claudePaths: claudePaths, codexPaths: codexPaths)
        }.value
        if providerCorpusPresence != corpusPresence {
            providerCorpusPresence = corpusPresence
        }

        await Perf.span("await:audit.refresh") {
            await audit.refresh(sessions: sessions.sessions)
        }
        await Perf.span("await:attention.refresh") {
            await attention.refresh(candidates: attentionCandidates())
        }
        await Perf.span("await:fleet.refresh") {
            await fleet.refresh(sessions: sessions.sessions, now: Date())
        }
        now = Date()
        let notificationBoard = await rebuildAttentionBoardOffMain()
        evaluateNotifications(board: notificationBoard)

        let projectionSessions = sessions.sessions
        skills.projectDirs = await Task.detached(priority: .utility) {
            Self.projectSkillDirs(sessions: projectionSessions)
        }.value
        await skills.refreshIfStale()
        await Perf.span("await:auditReport.refresh") {
            await auditReport.refresh(
                sessions: sessions.sessions, skills: skills.skills)
        }

        settings = await Task.detached(priority: .utility) {
            ClaudeSettings.load(paths: claudePaths)
        }.value
        if !didRunLaunchDream {
            didRunLaunchDream = true
            await Perf.span("await:ledger.dreamOnLaunch") {
                await ledger.dreamOffMain(
                    report: auditReport.report,
                    catalog: skills.skills,
                    settings: settings,
                    sessionsScanned: sessions.sessions.count,
                    trigger: .onLaunch)
            }
        } else {
            await Perf.span("await:ledger.remint") {
                await ledger.remintOffMain(
                    report: auditReport.report,
                    catalog: skills.skills,
                    settings: settings)
            }
        }

        launch.reload()
        await Perf.span("await:deadlines.refresh") {
            await deadlines.refresh(sessions: sessions.sessions, now: Date())
        }
        refreshNavigationSnapshots()
        machines.refreshStatuses(sessionCounts: machineSessionCounts())
        await stack.refreshIfStale(120)
        let quotaConsent = QuotaConsent(preferences: preferences.value)
        await Perf.span("await:quota.refresh") {
            await quota.refresh(consent: quotaConsent)
        }
    }

    private func handleChanges(sessionPaths: Set<String>, settings settingsDirty: Bool) {
        pendingDebouncedSessionPaths.formUnion(sessionPaths)
        pendingDebouncedSettings = pendingDebouncedSettings || settingsDirty
        if !sessionPaths.isEmpty || settingsDirty {
            guard sessionsDebounce == nil else { return }
            sessionsDebounce = Task { [weak self] in
                // 5s, not 1.2s: under heavy multi-agent activity ~/.claude/projects
                // is written many times a second, so FSEvents fires continuously. The
                // full refresh cascade + SwiftUI re-render over thousands of sessions
                // exceeded a 1.2s window, so the debounce cleared and re-triggered
                // back-to-back → permanent 100% CPU. A 5s floor guarantees idle time.
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                let changed = self.pendingDebouncedSessionPaths
                let settingsChanged = self.pendingDebouncedSettings
                self.pendingDebouncedSessionPaths = []
                self.pendingDebouncedSettings = false
                self.sessionsDebounce = nil
                self.refreshAll(changedSessionPaths: settingsChanged ? nil : changed)
            }
        }
    }

    // MARK: Cross-Machine Fleet

    /// Per-machine session counts from the merged fleet — feeds the offline/online
    /// indicators so an online remote shows its real contribution.
    func machineSessionCounts() -> [String: Int] {
        FleetMerge.machineCounts(sessions.sessions)
    }

    /// True when more than this Mac is contributing — gates the machine filter/chip
    /// so single-machine users see zero cross-machine chrome.
    var isCrossMachine: Bool { sessions.machineCount > 1 || !machines.config.remotes.isEmpty }

    /// Refresh the filter's live set with one process + registry snapshot. The
    /// exact-identity set is intentionally separate from the selected row's CWD
    /// fallback, which cannot distinguish historical sessions in the same repo.
    private func refreshLiveTerminalSnapshot() async {
        let resolver = TerminalLinkResolver(
            registry: FileTerminalSessionRegistryProvider(directory: claudePaths.sessions))
        let snapshot = await Task.detached(priority: .utility) {
            resolver.liveRegisteredSessionSnapshot()
        }.value
        // Sticky on failure: a transiently failing probe must not flap every
        // downstream projection to empty (with "Live in terminal" active this
        // emptied the whole session list mid-search). A SUCCESSFUL empty probe
        // is honest and replaces; a failed one keeps the last good set.
        if snapshot.failureReason == nil {
            liveTerminalSessionIDs = snapshot.sessionIDs
        }
        liveTerminalSnapshotFailure = snapshot.failureReason
    }

    /// Deep-link: jump to a session's live detail from anywhere.
    func inspect(_ session: SessionSummary) {
        selectedSessionID = session.id
        select(.sessions, origin: .programmatic)
    }

    /// Resolve the label shown on the selected session's open action from the
    /// same typed process/registry result the launch flow consumes. Resolution
    /// runs off-main and stays stable until selection changes or refresh is explicit.
    func prepareSessionOpenAction(for session: SessionSummary, force: Bool = false) {
        if ProviderSessionOpenPolicy.route(
            provider: session.provider,
            isRemote: session.isRemote) == .transcript {
            // `sessionOpenAction(for:)` derives this directly from provider
            // policy. Writing the same value on every inspector mount would
            // republish broad AppServices and rebuild the Sessions screen.
            return
        }
        if !force, sessionOpenActions[session.id] != nil { return }
        guard pendingSessionOpenActionIDs.insert(session.id).inserted else { return }
        sessionOpenActions[session.id] = .resolving

        let id = session.id
        let cwd = session.cwd
        let machineID = session.machineID
        let resolver = TerminalLinkResolver(
            registry: FileTerminalSessionRegistryProvider(directory: claudePaths.sessions))
        Task { [weak self] in
            let resolution = await Task.detached(priority: .utility) {
                resolver.resolve(sessionID: id, cwd: cwd, machineID: machineID)
            }.value
            guard let self else { return }
            self.pendingSessionOpenActionIDs.remove(id)
            self.sessionOpenActions[id] = SessionOpenActionPresentation(resolution: resolution)
        }
    }

    /// The actionable denial toast's one action: open the exact Settings pane.
    func openAccessibilitySettingsFromToast() {
        guard workspaceAccess.openAccessibilitySettings() else { return }
        var updated = preferences.value
        updated.hasOpenedAccessibilitySettings = true
        preferences.value = updated
    }

    func performTerminalFeedbackAction(_ action: TerminalFeedbackAction,
                                       sessionID: String) {
        switch action {
        case .openAccessibilitySettings:
            openAccessibilitySettingsFromToast()
        case .openAutomationSettings:
            guard let url = URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Automation") else {
                return
            }
            NSWorkspace.shared.open(url)
        case .copyResumeCommand:
            guard let session = sessions.sessions.first(where: { $0.id == sessionID }) else {
                return
            }
            let command = SessionResume.command(
                sessionID: session.id, cwd: session.cwd)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(command, forType: .string)
        }
    }

    func sessionOpenAction(for session: SessionSummary) -> SessionOpenActionPresentation {
        if ProviderSessionOpenPolicy.route(
            provider: session.provider,
            isRemote: session.isRemote) == .transcript {
            // Same route, two different truths — name the right one.
            return .transcript(session.provider == .codex ? .codexSession : .remoteSession)
        }
        return sessionOpenActions[session.id] ?? .resolving
    }

    /// Opens the exact local session when possible. Every unsuccessful typed
    /// outcome executes a deterministic main-window transcript reveal instead of
    /// selecting an arbitrary keyable window or silently preserving current state.
    func openTerminal(_ session: SessionSummary) {
        openTerminal(session) { MainWindowPresenter.present() }
    }

    /// Async seam consumed by Tier 1.5 when AX would help but access is absent.
    /// The first such attempt presents the explainer; a prior Not Now is honored
    /// without another modal. Only an explicit choice is persisted, never TCC
    /// status. The TerminalLauncher closure below supplies this method directly
    /// to the generic Accessibility adapter.
    func requestWorkspaceAccessExplanation(
        terminalName: String
    ) async -> WorkspaceAccessAction {
        let alreadySeen = preferences.value
            .hasSeenAccessibilityWorkspaceExplainer
        let action = await workspaceAccess.requestExplanation(
            terminalName: terminalName,
            hasSeenExplainer: alreadySeen)
        if !alreadySeen,
           action == .settingsOpened || action == .notNow {
            var updated = preferences.value
            updated.hasSeenAccessibilityWorkspaceExplainer = true
            if action == .settingsOpened {
                updated.hasOpenedAccessibilitySettings = true
            }
            preferences.value = updated
        }
        return action
    }

    func completeFirstLaunchWelcome() {
        guard !preferences.value.hasCompletedFirstLaunchWelcome else { return }
        var updated = preferences.value
        updated.hasCompletedFirstLaunchWelcome = true
        preferences.value = updated
    }

    func prepareTerminalAutomation(
        application: TerminalApplication
    ) async -> TerminalAutomationPreparation {
        let alreadySeen = preferences.value.hasSeenTerminalAutomationPrimer
        let preparation = await automationAccess.prepare(
            terminalName: application.displayName,
            hasSeenPrimer: alreadySeen)
        if !alreadySeen, preparation == .proceed {
            var updated = preferences.value
            updated.hasSeenTerminalAutomationPrimer = true
            preferences.value = updated
        }
        return preparation
    }

    func openTerminal(_ session: SessionSummary,
                      openMainWindow: @escaping @MainActor () -> Void) {
        guard ProviderSessionOpenPolicy.route(
            provider: session.provider,
            isRemote: session.isRemote) == .claudeRegistry else {
            let message = session.provider == .codex
                ? "Codex terminal handoff is not available yet — showing rollout transcript"
                : "Remote session — showing transcript"
            showTranscript(session, message: message,
                           openMainWindow: openMainWindow)
            return
        }
        // The launch ladder spawns the workspace host's controller binary many
        // times and can take seconds. Re-clicking used to CANCEL the in-flight
        // ladder and queue a fresh one behind its remaining synchronous work —
        // the "dead button" the owner felt. Coalesce instead: while a launch
        // for this session is in flight, a repeat click acknowledges honestly
        // and keeps the original working.
        if launchingSessionID == session.id {
            publishTranscriptReveal(
                sessionID: session.id,
                feedback: TerminalLaunchFeedback(
                    message: "Opening session — still working…",
                    semantics: .information))
            return
        }
        terminalLaunchTask?.cancel()
        launchingSessionID = session.id
        terminalLaunchTask = TerminalLauncher.open(
            session: session,
            resolver: TerminalLinkResolver(
                registry: FileTerminalSessionRegistryProvider(
                    directory: claudePaths.sessions)),
            workspacePermissionHandler: { [weak self] terminalName in
                guard let self else { return .cancelled }
                return await self.requestWorkspaceAccessExplanation(
                    terminalName: terminalName)
            },
            automationPermissionHandler: { [weak self] application in
                guard let self else { return .cancelled }
                return await self.prepareTerminalAutomation(
                    application: application)
            },
            openMainWindow: openMainWindow,
            selectSession: { [weak self] id in
                guard let self else { return }
                self.selectedSessionID = id
                self.select(.sessions, origin: .programmatic)
            },
            revealTranscript: { [weak self] id, outcome in
                // An Accessibility denial gets an actionable toast: the
                // one-time explainer can be suppressed (its "seen" flag
                // persists), and a bare sentence stranded the user with no
                // way to grant. The button opens the exact Settings pane.
                self?.publishTranscriptReveal(
                    sessionID: id,
                    feedback: outcome.feedback ?? TerminalLaunchFeedback(
                        message: "Showing the local transcript",
                        semantics: .information)
                )
            },
            confirmLaunch: { [weak self] outcome in
                // A successful open acknowledges in-app so it never reads as a
                // no-op — the same session-scoped banner the fallback uses.
                guard let feedback = outcome.feedback else { return }
                self?.publishTranscriptReveal(
                    sessionID: session.id, feedback: feedback)
            },
            onFinished: { [weak self] in
                guard let self, self.launchingSessionID == session.id else { return }
                self.launchingSessionID = nil
            }
        )
    }

    /// Remote sessions intentionally expose Transcript, never Terminal. This path
    /// contains no resolver call and remains visibly repeatable from the inspector.
    func showTranscript(_ session: SessionSummary, message: String? = nil,
                        openMainWindow: @escaping @MainActor () -> Void) {
        terminalLaunchTask?.cancel()
        terminalLaunchTask = nil
        NSApp.activate(ignoringOtherApps: true)
        openMainWindow()
        inspect(session)
        publishTranscriptReveal(
            sessionID: session.id,
            feedback: TerminalLaunchFeedback(
                message: message ?? "Showing the local transcript",
                semantics: .information)
        )
    }

    private func publishTranscriptReveal(sessionID: String,
                                         feedback: TerminalLaunchFeedback) {
        terminalRevealGeneration += 1
        let generation = terminalRevealGeneration
        terminalTranscriptReveal = TerminalTranscriptReveal(
            sessionID: sessionID,
            generation: generation,
            feedback: feedback
        )
        Task { [weak self] in
            // An actionable toast needs time to be acted on.
            try? await Task.sleep(for: .seconds(feedback.action == nil ? 2.5 : 8))
            guard let self,
                  self.terminalTranscriptReveal?.generation == generation else { return }
            self.terminalTranscriptReveal = nil
        }
    }

    /// Launch a saved recipe from the palette — the exact compose → copy path the
    /// Launch screen's card uses (VISION 3.2/3.4). Skills resolve at runtime, so
    /// the shell one-liner is copied to the clipboard, ready to paste into a
    /// terminal.
    func launchRecipe(_ recipe: Recipe) {
        let cmd = launch.compose(recipe)
        launch.copyToClipboard(cmd.shellCommand)
    }

    var selectedSession: SessionSummary? {
        guard let id = selectedSessionID else { return nil }
        return sessions.sessions.first { $0.id == id }
    }

    /// Restoration waits for the complete index, then either hydrates the
    /// inspector or removes a stale persisted ID. Later refreshes apply the
    /// same stale-selection rule without ever clearing a still-valid inspector.
    private func reconcileRestoredSelection() {
        guard !sessions.scanProgress.isInProgress else { return }
        if let restoredID = pendingRestoredSessionID {
            pendingRestoredSessionID = nil
            if sessions.sessions.contains(where: { $0.id == restoredID }) {
                selectedSessionID = restoredID
            } else {
                selectedSessionID = nil
                persistedInspectorID = ""
            }
            return
        }
        if let selectedSessionID,
           !sessions.sessions.contains(where: { $0.id == selectedSessionID }) {
            self.selectedSessionID = nil
        }
    }
}
