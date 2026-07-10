import Foundation
import AppKit
import SwiftUI
import Combine
import TrifolaKit

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
    var shortcut: KeyEquivalent {
        switch self {
        case .overview: return "1"
        case .live: return "2"
        case .fleet: return "3"
        case .deadlines: return "d"
        case .sessions: return "4"
        case .spend: return "5"
        case .audit: return "6"
        case .ledger: return "7"
        case .launch: return "8"
        case .stack: return "9"
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
    let message: String
}

/// Owns the stores, the FSEvents wiring and the navigation state. One instance
/// for the whole app; everything on the MainActor.
@MainActor
final class AppServices: ObservableObject {
    private static let initialSection: AppSection =
        (ProcessInfo.processInfo.environment["TRIFOLA_SECTION"]
            ?? ProcessInfo.processInfo.environment["CMC_SECTION"])
            .flatMap(AppSection.init(rawValue:)) ?? .overview

    let sessions = SessionStore()
    let audit = RoutingAudit()
    let stack = StackStore()
    let skills = SkillsStore()
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
    /// Persistent snooze/mute agency plus the visual blocked→running closure beat.
    let agency = AgencyController()
    /// PLAN QUOTA (W7): the REAL rate-limit windows (5h · weekly · model-scoped)
    /// from the OAuth usage endpoint, read-only. Its own 5-min throttle keeps the
    /// FSEvents-driven refreshAll() calls cheap.
    let quota = QuotaStore()
    /// One-shot launch choreography state. It is intentionally not published:
    /// claiming a reveal must never turn a decorative animation into a render
    /// source for the whole app.
    let reveals = Reveal.Registry()
    /// First-run truth: whether the local Claude Code corpus exists and contains
    /// at least one transcript. Checked at launch and after each coalesced refresh,
    /// never in a hot SwiftUI body.
    @Published private(set) var hasLocalClaudeCorpus = AppServices.detectLocalClaudeCorpus()

    // MENU-BAR PRESENCE lives on its own `MenuBarPresence` object (not here) so the
    // App scene's menu/MenuBarExtra don't observe this high-frequency store — see
    // MenuBarPresence.swift for the render-storm rationale.

    /// A skill ref the Skill hierarchy asked to seed the builder with (its Launch
    /// button). LaunchScreen consumes + clears it on appear.
    @Published var pendingSkillSeed: String? = nil

    /// The ⌘K command palette is up (VISION 3.4). Toggled by the App scene's ⌘K
    /// command; RootView presents the overlay while it's true.
    @Published var showPalette = false

    /// `TRIFOLA_SECTION=spend` (etc.) opens the app on a given screen — the snapshot
    /// loop uses it to capture every screen without UI scripting.
    @Published var section: AppSection = AppServices.initialSection
    @Published private(set) var firstAppearanceSection: AppSection? = AppServices.initialSection
    private(set) var seenSections: Set<AppSection> = [AppServices.initialSection]
    @Published var selectedSessionID: String? = nil
    @Published private(set) var terminalTranscriptReveal: TerminalTranscriptReveal? = nil
    /// Heartbeat so relative timestamps ("3m ago", `isActive`) re-render.
    @Published var now = Date()

    private var watcher: FSEventsWatcher?
    private var ticker: Task<Void, Never>?
    private var sessionsDebounce: Task<Void, Never>?
    private var terminalRevealGeneration = 0
    private var forwarders: Set<AnyCancellable> = []

    init() {

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

        // Walk-Away Notify: clicking a BLOCKED banner focuses that session's live
        // detail (the honest bridge falls back to activating the app).
        notifier.onActivateSession = { [weak self] id in
            guard let self, let s = self.sessions.sessions.first(where: { $0.id == id }) else { return }
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

    /// The only section mutation point. A nil/disabled transaction suppresses
    /// every transition and matched-geometry effect for non-pointer origins;
    /// no screen or sidebar item needs to know how navigation was initiated.
    func select(_ newSection: AppSection, origin: NavOrigin) {
        guard section != newSection else { return }
        let isFirstAppearance = seenSections.insert(newSection).inserted
        var transaction = Transaction(
            animation: origin == .pointer
                ? Theme.motion(Theme.Motion.nav, reduceMotion: false)
                : nil)
        transaction.disablesAnimations = origin != .pointer
        withTransaction(transaction) {
            firstAppearanceSection = isFirstAppearance ? newSection : nil
            section = newSection
        }
    }

    /// The Skill hierarchy's Launch button: jump to the builder, seeded with a
    /// skill ref. The builder folds it into the current draft on appear.
    func seedLaunch(skill: String) {
        pendingSkillSeed = skill
        select(.launch, origin: .programmatic)
    }

    /// Distinct existing `<cwd>/.claude/skills` dirs across recent sessions — the
    /// project lane for the skill hierarchy (capped so the scan stays cheap).
    private func projectSkillDirs() -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        let fm = FileManager.default
        for s in sessions.sessions where !s.cwd.isEmpty && !s.isSubagent {
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

        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let watcher = FSEventsWatcher(paths: [home + "/.claude"]) { [weak self] paths in
            var sessionsDirty = false, settingsDirty = false
            for p in paths {
                if p.contains("/.claude/projects/") && p.hasSuffix(".jsonl") { sessionsDirty = true }
                else if p.hasSuffix("/.claude/settings.json") { settingsDirty = true }
            }
            guard sessionsDirty || settingsDirty else { return }
            let s = sessionsDirty, g = settingsDirty
            Task { @MainActor [weak self] in
                self?.handleChanges(sessions: s, settings: g)
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
                self.evaluateNotifications()
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
    func evaluateNotifications() {
        let raw = attentionBoard(now: now)
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
        settings = ClaudeSettings.load()
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

    func refreshAll() {
        Task {
            await Perf.span("await:sessions.refreshNow") { await sessions.refreshNow() }
            let corpusAvailable = Self.detectLocalClaudeCorpus()
            if hasLocalClaudeCorpus != corpusAvailable {
                hasLocalClaudeCorpus = corpusAvailable
            }
            Perf.span("main:audit.refresh") { audit.refresh(sessions: sessions.sessions) }
            await Perf.span("await:attention.refresh") { await attention.refresh(candidates: attentionCandidates()) }
            await Perf.span("await:fleet.refresh") { await fleet.refresh(sessions: sessions.sessions, now: Date()) }
            now = Date()
            // Fresh signals in hand → notify on any session that just entered BLOCKED.
            Perf.span("main:evaluateNotifications") { evaluateNotifications() }
            // The AUDIT pillar needs the skill catalog (dead-skill ledger); make
            // sure it's loaded, then build all four findings from the fresh index.
            // Feed the project lane from real session cwds before scanning.
            skills.projectDirs = Perf.span("main:projectSkillDirs") { projectSkillDirs() }
            await skills.refreshIfStale()
            await Perf.span("await:auditReport.refresh") {
                await auditReport.refresh(sessions: sessions.sessions, skills: skills.skills)
            }
            // DREAMING LEDGER: re-mint lessons from the fresh findings + settings so
            // the queue + sidebar count stay truthful. Silent (no dream-log line) —
            // an actual recorded pass runs on the Ledger screen's on-launch task and
            // on "Dream now". Deterministic: same findings → same lessons.
            settings = ClaudeSettings.load()
            Perf.span("main:ledger.remint") {
                ledger.remint(report: auditReport.report, catalog: skills.skills, settings: settings)
            }
            // LAUNCH pillar: load saved recipes from the app's own dir.
            launch.reload()
            // DEADLINE BOARD: re-parse the deadline sources (MEMORY.md/NOTES.md) →
            // operative deadline → .toml override → persist to the app's OWN store. The
            // card JOIN (against live activity) is rebuilt at render time. The source
            // read + regex parse (~190ms measured) runs detached — never on main.
            await Perf.span("await:deadlines.refresh") {
                await deadlines.refresh(sessions: sessions.sessions, now: Date())
            }
            // Cross-Machine Fleet: recompute the calm online/offline indicators from
            // the freshly-merged fleet's per-machine session counts.
            machines.refreshStatuses(sessionCounts: machineSessionCounts())
            // Warm the Stack screen in the background; the stale guard keeps
            // this from re-spawning probe subprocesses on every FS event.
            await stack.refreshIfStale(120)
            // PLAN QUOTA (W7): read-only OAuth windows; its own minInterval +
            // 429 cooldown make this a no-op on most refresh cycles.
            await Perf.span("await:quota.refresh") { await quota.refresh() }
        }
    }

    private static func detectLocalClaudeCorpus() -> Bool {
        let projects = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/projects", isDirectory: true)
        guard FileManager.default.fileExists(atPath: projects.path),
              let files = FileManager.default.enumerator(
                at: projects,
                includingPropertiesForKeys: nil,
                options: [.skipsPackageDescendants]) else { return false }
        for case let url as URL in files where url.pathExtension == "jsonl" {
            return true
        }
        return false
    }

    private func handleChanges(sessions sessionsDirty: Bool, settings settingsDirty: Bool) {
        if sessionsDirty || settingsDirty {
            guard sessionsDebounce == nil else { return }
            sessionsDebounce = Task { [weak self] in
                // 5s, not 1.2s: under heavy multi-agent activity ~/.claude/projects
                // is written many times a second, so FSEvents fires continuously. The
                // full refresh cascade + SwiftUI re-render over thousands of sessions
                // exceeded a 1.2s window, so the debounce cleared and re-triggered
                // back-to-back → permanent 100% CPU. A 5s floor guarantees idle time.
                try? await Task.sleep(for: .seconds(5))
                guard let self, !Task.isCancelled else { return }
                self.sessionsDebounce = nil
                await Perf.span("await:sessions.refreshNow") { await self.sessions.refreshNow() }
                Perf.span("main:audit.refresh") { self.audit.refresh(sessions: self.sessions.sessions) }
                await Perf.span("await:attention.refresh") {
                    await self.attention.refresh(candidates: self.attentionCandidates())
                }
                await Perf.span("await:fleet.refresh") {
                    await self.fleet.refresh(sessions: self.sessions.sessions, now: Date())
                }
                await Perf.span("await:auditReport.refresh") {
                    await self.auditReport.refresh(sessions: self.sessions.sessions, skills: self.skills.skills)
                }
                if settingsDirty { self.settings = ClaudeSettings.load() }
                Perf.span("main:ledger.remint") {
                    self.ledger.remint(report: self.auditReport.report, catalog: self.skills.skills,
                                       settings: self.settings)
                }
                await Perf.span("await:deadlines.refresh") {
                    await self.deadlines.refresh(sessions: self.sessions.sessions, now: Date())
                }
                self.now = Date()
                Perf.span("main:evaluateNotifications") { self.evaluateNotifications() }
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

    /// Deep-link: jump to a session's live detail from anywhere.
    func inspect(_ session: SessionSummary) {
        selectedSessionID = session.id
        select(.sessions, origin: .programmatic)
    }

    /// Opens the exact local session when possible. Every unsuccessful typed
    /// outcome executes a deterministic main-window transcript reveal instead of
    /// selecting an arbitrary keyable window or silently preserving current state.
    func openTerminal(_ session: SessionSummary) {
        openTerminal(session) {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first(where: {
                $0.title == "Trifola" && $0.canBecomeKey
            })?.makeKeyAndOrderFront(nil)
        }
    }

    func openTerminal(_ session: SessionSummary,
                      openMainWindow: @escaping @MainActor () -> Void) {
        guard !session.isRemote else {
            showTranscript(session, message: "Remote session — showing transcript",
                           openMainWindow: openMainWindow)
            return
        }
        TerminalLauncher.open(
            session: session,
            openMainWindow: openMainWindow,
            selectSession: { [weak self] id in
                guard let self else { return }
                self.selectedSessionID = id
                self.select(.sessions, origin: .programmatic)
            },
            revealTranscript: { [weak self] id, outcome in
                self?.publishTranscriptReveal(
                    sessionID: id,
                    message: outcome.fallbackMessage
                        ?? "No live terminal found — showing transcript"
                )
            }
        )
    }

    /// Remote sessions intentionally expose Transcript, never Terminal. This path
    /// contains no resolver call and remains visibly repeatable from the inspector.
    func showTranscript(_ session: SessionSummary, message: String? = nil,
                        openMainWindow: @escaping @MainActor () -> Void) {
        NSApp.activate(ignoringOtherApps: true)
        openMainWindow()
        inspect(session)
        publishTranscriptReveal(
            sessionID: session.id,
            message: message ?? "No live terminal found — showing transcript"
        )
    }

    private func publishTranscriptReveal(sessionID: String, message: String) {
        terminalRevealGeneration += 1
        let generation = terminalRevealGeneration
        terminalTranscriptReveal = TerminalTranscriptReveal(
            sessionID: sessionID,
            generation: generation,
            message: message
        )
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2.5))
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
}
