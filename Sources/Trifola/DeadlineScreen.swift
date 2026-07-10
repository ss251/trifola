import SwiftUI
import AppKit
import Combine
import TrifolaKit

// MARK: - THE DEADLINE BOARD (docs/DEADLINE_BOARD.md) — the Floor's sibling
//
// The evidence grammar, pointed at the calendar: a jeopardy-sorted table where the
// door light leads every row, the rank bar IS the alarm, and every date carries its
// source line. The LOCAL board is canonical and stands alone; the Linear exporter is
// a one-way push behind a calm "Connect Linear" affordance — off by default, losing
// the board nothing. Pure `DeadlineContent` rasterizes headlessly via
// `--render-deadlines` (snapshot.sh is Space-broken).

// MARK: - State + kind color (reuses the semantic status hues — no new palette)

extension DeadlineState {
    var color: Color {
        switch self {
        case .onTrack: return Theme.green
        case .atRisk:  return Theme.amber
        case .stalled: return Theme.red
        case .shipped: return Theme.faint
        // The worst state never wears the calmest color (UI_GRIND DLN-1/§2.6): a
        // full gray bar read as "track/disabled" everywhere else in the app. Red,
        // stated once — still a fact, not a nag (no banner, no pulse).
        case .overdue: return Theme.red
        }
    }
    var chipGlyph: String {
        switch self {
        case .onTrack: return "arrowtriangle.up.fill"
        case .atRisk:  return "circle.lefthalf.filled"
        case .stalled: return "pause.fill"
        case .shipped: return "checkmark"
        // OVERDUE is the most CERTAIN state a deadline can have — a question
        // mark was the wrong glyph for it (UI_GRIND DLN-2).
        case .overdue: return "exclamationmark.circle"
        }
    }
}

private extension DeadlineCard {
    var doorLightState: DoorLightState {
        if isLive { return .running }
        switch state {
        case .stalled, .overdue: return .blocked
        case .atRisk: return .waiting
        case .onTrack, .shipped: return .idle
        }
    }
}

// MARK: - The Linear connection (drives the affordance's two honest states)

enum LinearConnection: Equatable {
    case notConnected
    case connected(team: String?, lastSync: Date?, backgroundSync: Bool)
}

// MARK: - The store (parse → confirm → override; Linear connection + one-way sync)

@MainActor
final class DeadlineStore: ObservableObject {
    /// The canonical record set (app-owned; the project's files are read-only to it).
    @Published private(set) var records: [String: DeadlineRecord] = [:]
    @Published private(set) var linearKeyPresent = false
    @Published private(set) var settings = LinearSettings()
    @Published private(set) var teams: [LinearTeam] = []
    @Published private(set) var linearMap: [String: String] = [:]
    @Published private(set) var lastSync: Date? = nil
    /// The visible result of the last sync — per-project rows the panel lists so
    /// "what just happened?" is never a silent status line.
    @Published private(set) var lastSyncReport: [LinearSyncRow] = []
    @Published var syncStatus: String? = nil
    @Published var isSyncing = false
    /// The secure-field draft (never persisted — it goes straight to the Keychain).
    @Published var keyDraft = ""

    private let recordStore = DeadlineRecordStore()
    private let mapStore = LinearMapStore()
    private let settingsStore = LinearSettingsStore()
    let keychain: LinearKeychain = KeychainLinearStore()
    let transport: LinearTransport = URLSessionLinearTransport()

    var connection: LinearConnection {
        linearKeyPresent
            ? .connected(team: settings.teamName, lastSync: lastSync, backgroundSync: settings.backgroundSync)
            : .notConnected
    }

    func start() {
        records = recordStore.load()
        linearMap = mapStore.load()
        settings = settingsStore.load()
        refreshConnection()
    }

    /// Presence-only — never decrypts the key (that decryption, in the launch/render
    /// path, was the render storm: a core pegged in Security crypto + a frozen "buffering"
    /// UI). The full key is read only on an explicit Linear sync, off the main path.
    func refreshConnection() { linearKeyPresent = keychain.keyPresent() }

    // MARK: parse → confirm → override

    /// Re-parse the deadline SOURCES (MEMORY.md + per-project NOTES.md/README),
    /// pick the operative deadline per project, fold in any user `.toml` override, and
    /// persist the resolved set to the app's OWN store — never the user's files.
    ///
    /// The source read + regex parse measured ~190ms over the real corpus and
    /// used to run ON the main actor every refresh tick — a per-tick UI stall.
    /// It is pure (files in → records out), so it hops to a detached task; only
    /// the compare-and-publish comes back to the main actor.
    func refresh(sessions: [SessionSummary], now: Date) async {
        let persisted = records
        var withIds = await Task.detached(priority: .userInitiated) {
            Self.resolveRecords(sessions: sessions, now: now, persisted: persisted)
        }.value
        // Carry the persisted Linear ids forward into the resolved set.
        for (k, id) in linearMap where withIds[k] != nil { withIds[k]?.linearProjectId = id }
        // Compare-before-assign (W6 wave 4): a re-parse that resolved the same
        // records must not republish (or rewrite) anything.
        if records != withIds {
            records = withIds
            recordStore.save(withIds)
        }
    }

    /// The pure resolve: parse sources → operative deadline per project → fold
    /// `.toml` overrides → merge with the persisted set → seed the Custom
    /// cutoff. No main-actor state; safe on any executor.
    nonisolated static func resolveRecords(sessions: [SessionSummary], now: Date,
                                           persisted: [String: DeadlineRecord]) -> [String: DeadlineRecord] {
        let hints = Array(Set(sessions.filter { !$0.isSubagent }.map(\.project))).sorted()
        var parsed: [ParsedDeadline] = []

        if let mem = readMemory() {
            parsed += DeadlineParser.parse(text: mem.text, file: mem.path, projectHints: hints, now: now)
        }
        for cwd in projectDirs(sessions) {
            let base = (cwd as NSString).lastPathComponent
            for name in ["NOTES.md", "README.md"] {
                let path = (cwd as NSString).appendingPathComponent(name)
                if let text = try? String(contentsOfFile: path, encoding: .utf8) {
                    parsed += DeadlineParser.parse(text: text, file: path, defaultProject: base,
                                                   projectHints: hints, now: now)
                }
            }
        }

        let operative = DeadlineParser.operativeDeadlines(parsed, now: now)
        let overrides = readOverrides(sessions: sessions)
        let merged = DeadlineMerge.resolve(parsed: operative, persisted: persisted, overrides: overrides)
        return merged
    }

    func cards(sessions: [SessionSummary], now: Date, blocked: Set<String>) -> [DeadlineCard] {
        let activity = DeadlineActivity.summarize(sessions, now: now, blockedProjects: blocked)
        return DeadlineBoard.build(records: records, activity: activity, now: now)
    }

    // MARK: confirm / edit / ship (the confirm step — writes ONLY the app's store)

    func confirm(_ key: String) {
        guard var r = records[key] else { return }
        r.source.confirmed = true
        records[key] = r
        recordStore.save(records)
    }

    func setDeadline(_ key: String, date: Date) {
        guard var r = records[key] else { return }
        r.deadline = date
        r.source = DeadlineSource(file: r.source.file, line: r.source.line, raw: r.source.raw,
                                  confirmed: true, origin: .manual)
        records[key] = r
        recordStore.save(records)
    }

    func setShipped(_ key: String, _ shipped: Bool) {
        guard var r = records[key] else { return }
        r.shipped = shipped
        records[key] = r
        recordStore.save(records)
    }

    // MARK: Linear (key → Keychain → GraphQL)

    /// Paste the personal API key straight into the Keychain — never a file, never a log.
    func saveKey() {
        let key = keyDraft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !key.isEmpty else { return }
        _ = keychain.writeKey(key)
        keyDraft = ""
        refreshConnection()
        syncStatus = "Key saved to Keychain"
        Task { await fetchTeams() }
    }

    func disconnect() {
        _ = keychain.deleteKey()
        refreshConnection()
        syncStatus = nil
    }

    func fetchTeams() async {
        let exporter = LinearExporter(transport: transport, keychain: keychain, teamID: settings.teamID ?? "")
        do {
            let t = try await exporter.fetchTeams()
            teams = t
            // Default to the sole team when there's only one.
            if settings.teamID == nil, t.count == 1 { pickTeam(t[0]) }
        } catch { syncStatus = describe(error) }
    }

    func pickTeam(_ team: LinearTeam) {
        settings.teamID = team.id
        settings.teamName = team.name
        settingsStore.save(settings)
    }

    func setBackgroundSync(_ on: Bool) {
        settings.backgroundSync = on
        settingsStore.save(settings)
    }

    /// One-way local→Linear sync of the current board; idempotent via the local map.
    /// Only CONFIRMED records sync (an unconfirmed parse is a finding, not a
    /// deadline); stale mapped projects get canceled in Linear and pruned. The
    /// result lands in `lastSyncReport` so the panel shows exactly what happened.
    func sync(cards: [DeadlineCard]) async {
        guard let team = settings.teamID, !team.isEmpty else { syncStatus = "Pick a team first"; return }
        isSyncing = true
        defer { isSyncing = false }
        let exporter = LinearExporter(transport: transport, keychain: keychain, teamID: team)
        do {
            let result = try await exporter.upsert(cards, map: linearMap, now: Date())
            linearMap = result.map
            mapStore.save(result.map)
            // The map is now the whole truth: pruned keys lose their id too.
            for k in records.keys { records[k]?.linearProjectId = result.map[k] }
            recordStore.save(records)
            lastSync = Date()
            lastSyncReport = result.rows
            syncStatus = Self.syncHeadline(result)
        } catch { syncStatus = describe(error) }
    }

    /// The one-line summary above the report rows — counts, in plain words.
    static func syncHeadline(_ r: LinearSyncResult) -> String {
        let n = r.created.count + r.updated.count
        var parts = ["Synced \(n) project\(n == 1 ? "" : "s") to Linear\(r.created.isEmpty ? "" : " (\(r.created.count) new)")"]
        if !r.skipped.isEmpty { parts.append("\(r.skipped.count) kept local (unconfirmed)") }
        if !r.canceled.isEmpty { parts.append("\(r.canceled.count) canceled in Linear") }
        if !r.cancelDenied.isEmpty { parts.append("\(r.cancelDenied.count) unlinked (cancel denied)") }
        return parts.joined(separator: " · ")
    }

    // MARK: source readers (READ-only; the app never writes ~/.claude or the notes)
    // nonisolated static: they run inside `resolveRecords`' detached task.

    private nonisolated static func readMemory() -> (text: String, path: String)? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let slug = home.path.replacingOccurrences(of: "/", with: "-")
        let candidates = [
            home.appendingPathComponent(".claude/projects/\(slug)/memory/MEMORY.md").path,
        ]
        for p in candidates {
            if let text = try? String(contentsOfFile: p, encoding: .utf8) {
                return (text, "MEMORY.md")   // home-relativized name for the provenance line
            }
        }
        return nil
    }

    private nonisolated static func projectDirs(_ sessions: [SessionSummary]) -> [String] {
        var seen = Set<String>(), out: [String] = []
        for s in sessions where !s.isSubagent && !s.cwd.isEmpty {
            guard seen.insert(s.cwd).inserted else { continue }
            out.append(s.cwd)
            if out.count >= 24 { break }
        }
        return out
    }

    private nonisolated static func readOverrides(sessions: [SessionSummary]) -> [DeadlineOverride] {
        var out: [DeadlineOverride] = []
        let home = FileManager.default.homeDirectoryForCurrentUser
        // Global, user-owned override.
        let global = home.appendingPathComponent(".claude/mission-control/deadlines.toml").path
        if let text = try? String(contentsOfFile: global, encoding: .utf8) {
            out += DeadlineTOML.parse(text)
        }
        // Per-project `<cwd>/.claude/deadline.toml`.
        for cwd in projectDirs(sessions) {
            let base = (cwd as NSString).lastPathComponent
            let path = (cwd as NSString).appendingPathComponent(".claude/deadline.toml")
            if let text = try? String(contentsOfFile: path, encoding: .utf8) {
                out += DeadlineTOML.parse(text, defaultProject: base)
            }
        }
        return out
    }

    private func describe(_ error: Error) -> String {
        switch error {
        case LinearError.noKey: return "Connect Linear first (paste your key)"
        case LinearError.auth: return "Linear rejected the key — check it's a personal API key"
        case LinearError.graphQL(let m): return "Linear error: \(m)"
        case LinearError.badResponse: return "Unexpected Linear response"
        default: return "Network error — the board still works locally"
        }
    }
}

// MARK: - The screen

struct DeadlineScreen: View {
    @EnvironmentObject var services: AppServices

    private var cards: [DeadlineCard] {
        services.deadlineCards(now: services.now)
    }

    /// projectKey → the tier of the project's most recent interactive session —
    /// the door light's tier ring (UI_GRIND §2.1). A UI-side JOIN; the deadline
    /// data layer stays tier-free.
    private var tiers: [String: ModelTier] {
        var best: [String: (Date, ModelTier)] = [:]
        for s in services.sessions.sessions where !s.isSubagent {
            guard let d = s.lastActivity else { continue }
            if best[s.project] == nil || d > best[s.project]!.0 { best[s.project] = (d, s.tier) }
        }
        return best.mapValues(\.1)
    }

    var body: some View {
        ScreenScaffold(title: "Deadlines",
                       subtitle: subtitle,
                       epithet: "time × inactivity",
                       trailing: { syncButton }) {
            if cards.isEmpty {
                EmptyState(icon: "calendar",
                           title: "No deadlines yet",
                           detail: "Trifola pre-fills from dates in your project notes (NOTES.md, MEMORY.md) and from Linear once connected — it reads your notes, never writes them.")
            } else {
                DeadlineContent(cards: cards, config: DeadlineConfig(),
                                tiers: tiers,
                                onSelect: { open($0) },
                                onConfirm: { services.deadlines.confirm($0.projectKey) },
                                onReveal: { reveal($0) })
                DeadlineConnectPanel(
                    connection: services.deadlines.connection,
                    keyDraft: Binding(get: { services.deadlines.keyDraft },
                                      set: { services.deadlines.keyDraft = $0 }),
                    teams: services.deadlines.teams,
                    selectedTeamID: services.deadlines.settings.teamID,
                    syncStatus: services.deadlines.syncStatus,
                    report: services.deadlines.lastSyncReport,
                    onSaveKey: { services.deadlines.saveKey() },
                    onPickTeam: { services.deadlines.pickTeam($0) },
                    onSync: { Task { await services.deadlines.sync(cards: cards) } },
                    onToggleBackground: { services.deadlines.setBackgroundSync($0) },
                    onDisconnect: { services.deadlines.disconnect() })
            }
        }
    }

    private var subtitle: String {
        let active = cards.filter { $0.state != .shipped }.count
        let stalled = cards.filter { $0.state == .stalled }.count
        let alarm = stalled > 0 ? " · \(stalled) STALLED" : ""
        return "\(active) live deadline\(active == 1 ? "" : "s") · sorted by time pressure (idle time ÷ time left)\(alarm) · dollar values are API-rate estimates, not your bill"
    }

    @ViewBuilder private var syncButton: some View {
        if case .connected = services.deadlines.connection {
            ProminentTapButton(size: .small, action: {
                Task { await services.deadlines.sync(cards: cards) }
            }) {
                Label(services.deadlines.isSyncing ? "Syncing…" : "Sync to Linear",
                      systemImage: "arrow.up.forward.app")
            }
            .disabled(services.deadlines.isSyncing)
        }
    }

    private func open(_ card: DeadlineCard) {
        // Land on the artifact: jump to the project's live session (room → desk).
        if let session = services.sessions.sessions.first(where: { $0.project == card.projectKey }) {
            services.inspect(session)
        }
    }

    private func reveal(_ card: DeadlineCard) {
        // Confirmation is an explicit chip action. Provenance never mutates state.
        let path = (card.source.file as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: path) {
            NSWorkspace.shared.selectFile(path, inFileViewerRootedAtPath: "")
        }
    }
}

// MARK: - The pure content (rasterizes headlessly)

struct DeadlineContent: View {
    let cards: [DeadlineCard]
    var config: DeadlineConfig = .init()
    /// projectKey → the model tier of the project's most recent session — the
    /// door light's 1pt tier ring (UI_GRIND §2.1: one atom, everywhere). The JOIN
    /// happens UI-side; ProjectActivity (data layer) stays untouched. Missing key
    /// = no session backs the row → the ring falls back to the state tone.
    var tiers: [String: ModelTier] = [:]
    var onSelect: (DeadlineCard) -> Void = { _ in }
    var onConfirm: (DeadlineCard) -> Void = { _ in }
    var onReveal: (DeadlineCard) -> Void = { _ in }

    private var live: [DeadlineCard] { cards.filter { $0.state != .shipped } }
    private var shipped: [DeadlineCard] { cards.filter { $0.state == .shipped } }
    /// Normalize the rank bars to the worst NON-overdue jeopardy — an overdue card's
    /// runway→0 blows jeopardy up astronomically and would flatten every other bar to
    /// nothing (overdue renders a full bar in its own muted tone instead).
    private var topJeopardy: Double {
        let pool = live.filter { $0.state != .overdue && $0.jeopardy.isFinite }.map(\.jeopardy)
        return max(pool.max() ?? 0.0001, 0.0001)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.blockGap) {
            if let worst = DeadlineBoard.worst(cards), worst.state == .stalled || worst.state == .atRisk {
                DeadlineStrip(card: worst, tier: tiers[worst.projectKey]) { onSelect(worst) }
            }
            VStack(alignment: .leading, spacing: 4) {
                Eyebrow("Evidence — deadlines sorted by time pressure (idle time ÷ time left)")
                Text("Usage estimated at public API rates — not your bill")
                    .font(.caption2).foregroundStyle(Theme.faint)
                columnsHeader
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(live) { card in
                        DeadlineCardRow(card: card, topJeopardy: topJeopardy, config: config,
                                        tier: tiers[card.projectKey],
                                        onSelect: onSelect, onConfirm: onConfirm, onReveal: onReveal)
                    }
                }
                // The one app-standard reorder motion (W6 wave 4): jeopardy
                // re-ranks rarely — when it does, rows glide, never teleport.
                .reorderMotion(value: live.map(\.id))
            }
            if !shipped.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    shippedRule
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(shipped) { card in
                            DeadlineCardRow(card: card, topJeopardy: topJeopardy, config: config,
                                            tier: tiers[card.projectKey],
                                            onSelect: onSelect, onConfirm: onConfirm, onReveal: onReveal)
                                .opacity(0.6)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var columnsHeader: some View {
        HStack(spacing: Theme.sectionGap) {
            Text("project").frame(maxWidth: .infinity, alignment: .leading)
            Text("deadline pressure").frame(width: Theme.rankBarWidth, alignment: .leading)
            Text("left").frame(width: 54, alignment: .trailing)
            Text("last touch").frame(width: 70, alignment: .trailing)
            Text("API price").frame(width: Theme.subValueColWidth, alignment: .trailing)
            Text("count").frame(width: Theme.microColWidth, alignment: .trailing)
            Text("state").frame(width: 96, alignment: .leading)
        }
        .font(.caption).foregroundStyle(Theme.faint)
        .padding(.horizontal, Theme.intraCell)
    }

    private var shippedRule: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Theme.hairline).frame(height: 1).frame(maxWidth: .infinity)
            Text("shipped · ember").font(.caption2).foregroundStyle(Theme.faint)
        }
    }
}

// MARK: - The worst-card strip (rides on top — the one still alarm)

private struct DeadlineStrip: View {
    let card: DeadlineCard
    var tier: ModelTier? = nil
    let onTap: () -> Void

    var body: some View {
        TapButton(action: onTap) {
            HStack(spacing: 10) {
                SeatMark(state: card.doorLightState, size: 8)
                Text(card.projectKey).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                Text("— \(card.state.label)").font(.subheadline.weight(.medium)).foregroundStyle(card.state.color)
                Text("· \(fmtCountdown(card.runway)) left, untouched \(fmtAgeShort(card.idle))")
                    .font(.caption).foregroundStyle(Theme.muted)
                Spacer(minLength: 8)
                Text("pressure score \(String(format: "%.2f", card.jeopardy))")
                    .font(.caption).foregroundStyle(Theme.faint).monospacedDigit()
            }
            .padding(.horizontal, Theme.sectionGap).padding(.vertical, Theme.intraCell)
            .contentShape(Rectangle())
        }
        .background {
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .fill(Theme.cardFill)
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 1)
        }
    }
}

// MARK: - One card — the JOIN, three lines

private struct DeadlineCardRow: View {
    let card: DeadlineCard
    let topJeopardy: Double
    var config: DeadlineConfig = .init()
    /// The tier of the session backing this project — the door light's ring.
    var tier: ModelTier? = nil
    var onSelect: (DeadlineCard) -> Void = { _ in }
    var onConfirm: (DeadlineCard) -> Void = { _ in }
    var onReveal: (DeadlineCard) -> Void = { _ in }

    private var barFraction: Double {
        if card.state == .shipped { return 0 }
        if card.state == .overdue || !card.jeopardy.isFinite { return 1 }   // pinned full, own tone
        return min(1, max(0, card.jeopardy / topJeopardy))
    }
    /// Compact, column-fitting countdown: shipped reads "shipped", overdue "−Nd", else
    /// the coarsened "Nd/Nh/Nm".
    private var countdownText: String {
        if card.state == .shipped { return "shipped" }
        if card.runway < 0 { return "−\(fmtAgeShort(-card.runway))" }
        return fmtCountdown(card.runway)
    }
    private var countdownColor: Color {
        if card.state == .shipped { return Theme.faint }
        if card.runway <= 24 * 3600 { return Theme.red }   // overdue (negative) or ≤24h
        if card.runway <= config.reddenWindow { return Theme.amber }
        return Theme.ink
    }
    /// A ⚠ when the idle is old relative to the runway (the honest silence signal).
    private var idleWarns: Bool { card.state == .stalled || card.state == .atRisk }

    var body: some View {
        HoverRow(radius: Theme.radiusRow, action: { onSelect(card) }) {
            VStack(alignment: .leading, spacing: 2) {
                evidenceLine
                identityLine
                provenanceLine
            }
            .padding(Theme.rowInsets)
        }
    }

    // line 1 — door light · project · jeopardy bar · countdown · last-touch · $ · sess · state
    private var evidenceLine: some View {
        HStack(spacing: Theme.sectionGap) {
            HStack(spacing: 8) {
                // The door light: state fill + TIER ring where a session backs the
                // row (UI_GRIND DLN-5/§2.1) — state-only ring when none does.
                SeatMark(state: card.doorLightState, size: 8)
                Text(card.projectKey)
                    .font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            CapsuleBar(fraction: barFraction, tint: card.state.color)
                .frame(width: Theme.rankBarWidth)

            Text(countdownText)
                .font(.subheadline).foregroundStyle(countdownColor).monospacedDigit()
                .frame(width: 54, alignment: .trailing)

            HStack(spacing: 2) {
                if idleWarns {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 8, weight: .medium)).foregroundStyle(Theme.amber)
                }
                Text(card.lastActivity == nil ? "—" : fmtAgeShort(card.idle))
                    .font(.caption).foregroundStyle(Theme.muted).monospacedDigit()
            }
            .frame(width: 70, alignment: .trailing)

            Text(fmtUSD(card.cost))
                .font(.subheadline).foregroundStyle(Theme.ink).monospacedDigit()
                .frame(width: Theme.subValueColWidth, alignment: .trailing)

            Text(card.sessionCount > 0 ? "\(card.sessionCount)" : "—")
                .font(.caption).foregroundStyle(Theme.faint).monospacedDigit()
                .frame(width: Theme.microColWidth, alignment: .trailing)

            HStack(spacing: 4) {
                Image(systemName: card.state.chipGlyph).font(.system(size: 9, weight: .medium)).foregroundStyle(card.state.color)
                Text(card.state.label).font(.caption.weight(.medium)).foregroundStyle(card.state.color)
            }
            .frame(width: 96, alignment: .leading)
        }
    }

    // line 2 — the identity: mono deadline · kind/platform · live-note · machine chip
    private var identityLine: some View {
        HStack(spacing: 6) {
            Text(fmtDeadlineStamp(card.deadline))
                .font(.caption).foregroundStyle(Theme.muted)
            Text("· \(card.platform ?? card.kind.label)")
                .font(.caption).foregroundStyle(Theme.faint).lineLimit(1)
            if card.isLive {
                Text("· live").font(.caption2).foregroundStyle(Theme.green)
            }
            Spacer(minLength: 8)
            if card.machineID != Machine.localID { MachineChip(machineID: card.machineID) }
        }
    }

    // line 3 — the provenance: mono, faint, click → source file (confirm inline)
    private var provenanceLine: some View {
        HStack(spacing: 6) {
            TapButton(action: { onReveal(card) }) {
                Text(provenanceText)
                    .font(.caption2).foregroundStyle(Theme.faint)
                    .lineLimit(1)
                    .contentShape(Rectangle())
            }
            if card.source.confirmed {
                Text("confirmed")
                    .font(.caption2)
                    .foregroundStyle(Theme.faint)
            } else {
                DeadlineConfirmChip { onConfirm(card) }
            }
        }
    }

    private var provenanceText: String {
        switch card.source.origin {
        case .override: return "override  deadlines.toml"
        case .manual:   return "edited in-app"
        case .seeded:
            // A programmatically-planted, cited fact (the custom-cutoff gate) —
            // the citation IS the provenance, so it prints verbatim.
            let raw = card.source.raw.isEmpty ? "" : "  \"\(card.source.raw)\""
            return "seeded  \(card.source.file)\(raw)"
        case .parsed:
            let loc = card.source.line > 0 ? ":\(card.source.line)" : ""
            let raw = card.source.raw.isEmpty ? "" : "  \"\(card.source.raw)\""
            return "parsed  \(card.source.file)\(loc)\(raw)"
        }
    }
}

private struct DeadlineConfirmChip: View {
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        TapButton(focusVisual: .capsule, action: action) {
            Text("Confirm")
                .font(.caption2.weight(.medium))
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, Theme.intraCell)
                .padding(.vertical, 2)
                .background {
                    Capsule().fill(hovering ? Theme.selectionBG : Theme.cardFill)
                    Capsule().strokeBorder(Theme.cardStroke, lineWidth: 1)
                }
        }
        .onHover { hovering = $0 }
        .help("Confirm this parsed deadline")
    }
}

// MARK: - The connect-Linear affordance (calm, both states, never a nag)

struct DeadlineConnectPanel: View {
    let connection: LinearConnection
    var keyDraft: Binding<String> = .constant("")
    var teams: [LinearTeam] = []
    var selectedTeamID: String? = nil
    var syncStatus: String? = nil
    /// The last sync's visible result — one row per project (synced / kept local /
    /// canceled). Silence was the confusion; this list replaces it.
    var report: [LinearSyncRow] = []
    var onSaveKey: (() -> Void)? = nil
    var onPickTeam: ((LinearTeam) -> Void)? = nil
    var onSync: (() -> Void)? = nil
    var onToggleBackground: ((Bool) -> Void)? = nil
    var onDisconnect: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            header
            switch connection {
            case .notConnected: notConnected
            case .connected(let team, let lastSync, let bg): connected(team: team, lastSync: lastSync, backgroundSync: bg)
            }
            if let syncStatus {
                Text(syncStatus).font(.caption2).foregroundStyle(Theme.muted)
            }
            if isConnected, !report.isEmpty { reportList }
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .fill(Theme.cardFill)
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: isConnected ? "link.circle.fill" : "link.circle")
                .font(.footnote.weight(.medium)).foregroundStyle(isConnected ? Theme.green : Theme.muted)
            Text(connectionLine).font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink)
            Spacer()
            if isConnected, let onDisconnect {
                TapButton("Disconnect", action: onDisconnect)
                    .font(.caption).foregroundStyle(Theme.muted)
            }
        }
    }

    private var isConnected: Bool { if case .connected = connection { return true }; return false }
    private var connectionLine: String {
        switch connection {
        case .notConnected: return "Connect Linear"
        case .connected(let team, _, _): return team.map { "Linear connected · team \($0)" } ?? "Linear connected"
        }
    }

    private var notConnected: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Push each confirmed deadline one-way to a Linear project (real name, plain-words description, targetDate, a short status update). Unconfirmed parses stay local until you confirm them. The board is fully useful without it.")
                .font(.caption).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                if onSaveKey != nil {
                    SecureField("Paste your Linear personal API key", text: keyDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 360)
                } else {
                    // Headless render: a static field placeholder (SecureField can't rasterize).
                    HStack(spacing: 6) {
                        Image(systemName: "key.fill").font(.caption2.weight(.medium)).foregroundStyle(Theme.faint)
                        Text("Paste your Linear personal API key").font(.caption).foregroundStyle(Theme.faint)
                        Spacer()
                    }
                    .padding(.horizontal, Theme.intraCell).padding(.vertical, Theme.rhythm).frame(maxWidth: 360)
                    .background {
                        RoundedRectangle(cornerRadius: Theme.radiusRow).fill(Theme.codeFill)
                        RoundedRectangle(cornerRadius: Theme.radiusRow).strokeBorder(Theme.cardStroke, lineWidth: 1)
                    }
                }
                QuietTapButton("Save key") { onSaveKey?() }
                    .disabled(onSaveKey == nil || keyDraft.wrappedValue.isEmpty)
            }
            Text("Stored in your macOS Keychain — never in a file, never logged.")
                .font(.caption2).foregroundStyle(Theme.faint)
        }
    }

    private func connected(team: String?, lastSync: Date?, backgroundSync: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            if team == nil && !teams.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Pick a team").font(.caption).foregroundStyle(Theme.muted)
                    FlowLayout(spacing: 6, lineSpacing: 6) {
                        ForEach(teams) { t in
                            FilterChip(label: t.name, isOn: t.id == selectedTeamID) { onPickTeam?(t) }
                        }
                    }
                }
            }
            HStack(spacing: 10) {
                QuietTapButton("Sync to Linear") { onSync?() }
                    .disabled(onSync == nil || (team == nil && selectedTeamID == nil))
                if let onToggleBackground {
                    TapToggle("Background sync", isOn: Binding(get: { backgroundSync }, set: { onToggleBackground($0) }))
                } else {
                    // Headless render: a static on/off pill (Toggle can't rasterize).
                    HStack(spacing: 5) {
                        Image(systemName: backgroundSync ? "checkmark.circle.fill" : "circle")
                            .font(.caption2.weight(.medium)).foregroundStyle(backgroundSync ? Theme.green : Theme.faint)
                        Text("Background sync").font(.caption).foregroundStyle(Theme.muted)
                    }
                }
                Spacer()
                if let lastSync {
                    Text("last synced \(fmtAgo(lastSync))").font(.caption2).foregroundStyle(Theme.faint)
                }
            }
            Text("One-way local→Linear · confirmed deadlines only (unconfirmed parses stay local) · idempotent (never duplicates).")
                .font(.caption2).foregroundStyle(Theme.faint)
        }
    }

    // MARK: the visible result list — per-project rows, one calm sentence each

    private var reportList: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(report) { row in reportRow(row) }
        }
        .padding(.top, Theme.micro / 2)
    }

    private func reportRow(_ row: LinearSyncRow) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: rowGlyph(row.outcome))
                .font(.system(size: 9, weight: .medium)).foregroundStyle(rowTone(row.outcome))
                .frame(width: 12)
            Text(row.projectKey)
                .font(.caption).foregroundStyle(Theme.ink)
                .lineLimit(1)
            rowSentence(row)
            Spacer(minLength: 0)
        }
    }

    @ViewBuilder private func rowSentence(_ row: LinearSyncRow) -> some View {
        switch row.outcome {
        case .created, .updated:
            HStack(spacing: 4) {
                Text("synced →").font(.caption).foregroundStyle(Theme.muted)
                linkText(row.name, url: row.url, font: .caption.weight(.medium))
                if row.outcome == .created {
                    Text("(new project)").font(.caption2).foregroundStyle(Theme.faint)
                }
            }
        case .skipped:
            Text("skipped — an unconfirmed parse stays local; press confirm? on its card to sync it.")
                .font(.caption).foregroundStyle(Theme.muted)
        case .canceled:
            HStack(spacing: 4) {
                Text("canceled in Linear — no longer a confirmed deadline here.")
                    .font(.caption).foregroundStyle(Theme.muted)
                if row.url != nil {
                    linkText("view", url: row.url, font: .caption2)
                }
            }
        case .cancelDenied:
            Text("unlinked here — Linear declined the cancel; archive it there by hand.")
                .font(.caption).foregroundStyle(Theme.muted)
        }
    }

    /// A clickable Linear-project link that also rasterizes headlessly (SwiftUI's
    /// `Link` draws a placeholder in ImageRenderer — same class of problem as
    /// SecureField/Toggle above, same fix: a plain Button that opens the URL).
    @ViewBuilder private func linkText(_ label: String, url: String?, font: Font) -> some View {
        if let raw = url, let dest = URL(string: raw) {
            TapButton(action: { NSWorkspace.shared.open(dest) }) {
                Text(label).font(font).foregroundStyle(Theme.ink).underline()
            }
        } else {
            Text(label).font(font).foregroundStyle(Theme.ink)
        }
    }

    private func rowGlyph(_ o: LinearSyncRow.Outcome) -> String {
        switch o {
        case .created: return "plus.circle.fill"
        case .updated: return "arrow.up.forward.circle.fill"
        case .skipped: return "minus.circle"
        case .canceled: return "xmark.circle"
        case .cancelDenied: return "exclamationmark.circle"
        }
    }

    private func rowTone(_ o: LinearSyncRow.Outcome) -> Color {
        switch o {
        case .created, .updated: return Theme.green
        case .skipped: return Theme.faint
        case .canceled: return Theme.muted
        case .cancelDenied: return Theme.amber
        }
    }
}

// MARK: - Deadline stamp formatting (local tz display)

func fmtDeadlineStamp(_ date: Date) -> String {
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "MMM d yyyy HH:mm"
    return f.string(from: date)
}
