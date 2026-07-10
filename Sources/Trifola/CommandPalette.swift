import SwiftUI
import AppKit
import TrifolaKit

// MARK: - The command palette (⌘K) — VISION 3.4
// The command center's front door: type "webapp" → jump to the session; a skill
// → its detail or Launch; a recipe → spawn it. Everything reachable in three
// keystrokes. The scoring is a PURE function
// (TrifolaKit.FuzzyMatch / PaletteRanker); this file is the overlay + the
// index it feeds — it recomputes nothing, it reuses every store the app already
// holds.
//
// The rows are the app's grammar at palette density: a session wears the door
// light (the state-dot + its 1pt tier ring — POLISH C10/II.A) and its machine
// chip when the fleet is cross-machine; every id / path / slug / keystroke is
// mono, everything the app says is sans (POLISH II.C). One accent — the system
// selection wash — marks the active row.

// MARK: Kind

/// The five indices the palette searches. `rawValue` doubles as the ranker's
/// group order (screens first, then actions, recipes, sessions, skills) — so the
/// empty-query view opens on screens + actions + recent work, and skills surface
/// once you start typing.
enum PaletteKind: Int, CaseIterable {
    case screen = 0, action = 1, recipe = 2, session = 3, skill = 4

    /// The lowercase type tag on each row (POLISH bans tracked-uppercase eyebrows).
    var tag: String {
        switch self {
        case .screen: return "screen"
        case .action: return "action"
        case .recipe: return "recipe"
        case .session: return "session"
        case .skill: return "skill"
        }
    }
    /// The leading glyph for non-session rows (a session wears the door light).
    var icon: String {
        switch self {
        case .screen: return "rectangle.on.rectangle"
        case .action: return "bolt"
        case .recipe: return "paperplane"
        case .session: return "circle"
        case .skill: return "puzzlepiece.extension"
        }
    }
}

// MARK: Entry (view row + its ranking candidate)

/// One palette row. The display fields live here; the ranking fields live on
/// `candidate` (joined back by `id` after ranking). `hint` is baked font-only
/// (mono runs for disk-truth, sans for prose) so the selected row's selection
/// cascade recolors it in one place.
struct PaletteEntry: Identifiable {
    let id: String
    let kind: PaletteKind
    let title: String
    /// Font-styled but NOT colored — the row applies ink/faint or selection text.
    let hint: Text
    let icon: String
    // Session door-light + fleet chip.
    var tier: ModelTier? = nil
    var state: AttentionState? = nil
    var machineID: String? = nil
    // Recipe doctrine flag.
    var warn: Bool = false
    let candidate: PaletteCandidate
    /// The label of the alternate (⌘↵) action, shown on the selected row.
    var altLabel: String? = nil
    // The actions touch the MainActor stores, so the closures are MainActor-typed
    // (they are built + invoked on the main actor).
    let run: @MainActor () -> Void
    var runAlt: (@MainActor () -> Void)? = nil
}

// MARK: Row

private struct PaletteRow: View {
    let entry: PaletteEntry
    let selected: Bool

    private var titleColor: Color { selected ? Theme.selectionText : Theme.ink }
    private var hintColor: Color { selected ? Theme.selectionText : Theme.faint }
    private var tagColor: Color { selected ? Theme.selectionText.opacity(0.75) : Theme.faint }

    var body: some View {
        HStack(spacing: 10) {
            mark.frame(width: 18, alignment: .center)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(entry.title)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(titleColor)
                        .lineLimit(1)
                    if let m = entry.machineID { MachineChip(machineID: m, compact: true) }
                    if entry.warn {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .font(.caption2).foregroundStyle(Theme.amber)
                    }
                }
                entry.hint
                    .foregroundStyle(hintColor)
                    .lineLimit(1)
            }
            Spacer(minLength: 8)
            if selected, let alt = entry.altLabel {
                HStack(spacing: 3) {
                    Text("⌘↵").font(.system(.caption2, design: .monospaced))
                    Text(alt).font(.caption2)
                }
                .foregroundStyle(selected ? Theme.selectionText.opacity(0.85) : Theme.muted)
            }
            Text(entry.kind.tag)
                .font(.caption)
                .foregroundStyle(tagColor)
        }
        .padding(Theme.rowInsets)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
                .fill(selected ? Theme.selectionBG : .clear)
        }
        .contentShape(Rectangle())
    }

    @ViewBuilder private var mark: some View {
        if entry.kind == .session, let tier = entry.tier {
            // The door light at palette density: state fill + 1pt tier ring — the
            // same session-dot object the Fleet floor and the strip wear.
            SeatMark(fill: (entry.state ?? .idle).color, ring: tier.color, size: 9)
        } else {
            Image(systemName: entry.icon)
                .font(.footnote.weight(.medium))
                .foregroundStyle(selected ? Theme.selectionText : Theme.muted)
        }
    }
}

// MARK: Panel (shared by the live overlay + `--render-palette`)

/// The panel chrome — search field, ranked rows, keyboard legend — parameterized
/// on its input field so the live overlay mounts a real focused `TextField` and
/// the headless render passes styled `Text` (ImageRenderer can't rasterize a live
/// control). Everything else is one shared, pure view (POLISH C11).
struct PalettePanel<Field: View>: View {
    let query: String
    let results: [PaletteEntry]
    let selection: Int
    /// Live overlay scrolls; the render uses a plain stack (ImageRenderer can't
    /// size an unbounded ScrollView — see AuditRender).
    var scrolls: Bool = true
    @ViewBuilder var field: () -> Field
    var onHover: @MainActor (Int) -> Void = { _ in }
    var onInvoke: @MainActor (Int) -> Void = { _ in }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                Image(systemName: "magnifyingglass")
                    .font(.system(size: 15))
                    .foregroundStyle(Theme.muted)
                field()
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 13)

            Divider()

            if results.isEmpty {
                emptyState
            } else if scrolls {
                ScrollViewReader { proxy in
                    ScrollView(.vertical, showsIndicators: false) { rows }
                        .frame(maxHeight: 430)
                        .onChange(of: selection) { _, s in
                            guard results.indices.contains(s) else { return }
                            proxy.scrollTo(results[s].id, anchor: .center)
                        }
                }
            } else {
                rows
            }

            Divider()
            legend
        }
        .frame(width: 640)
        .background {
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(Color(nsColor: .windowBackgroundColor))
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .shadow(color: .black.opacity(0.22), radius: 16, x: 0, y: 8)
    }

    private var rows: some View {
        VStack(spacing: 2) {
            ForEach(Array(results.enumerated()), id: \.element.id) { i, e in
                PaletteRow(entry: e, selected: i == selection)
                    .id(e.id)
                    .onHover { if $0 { onHover(i) } }
                    .onTapGesture { onInvoke(i) }
            }
        }
        .padding(6)
    }

    private var emptyState: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.faint)
            Text(query.isEmpty ? "Type to search the fleet." : "No matches for “\(query)”.")
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 18)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            legendKey("↑↓", "navigate")
            legendKey("↵", "open")
            // The footer names the VERB (UI_GRIND PAL-1): "alt" was a hint that
            // needed a hint — say what ⌘↵ does to the selected row, dynamically;
            // hide the key when the selection has no alternate action.
            if let alt = results.indices.contains(selection)
                ? results[selection].altLabel : nil {
                legendKey("⌘↵", alt)
            }
            legendKey("esc", "close")
            Spacer()
            Text("\(results.count) result\(results.count == 1 ? "" : "s")")
                .font(.caption2)
                .foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private func legendKey(_ key: String, _ label: String) -> some View {
        HStack(spacing: 4) {
            Text(key).font(.system(.caption2, design: .monospaced)).foregroundStyle(Theme.muted)
            Text(label).font(.caption2).foregroundStyle(Theme.faint)
        }
    }
}

// MARK: - The overlay (live, wired to the stores + ⌘K)

struct CommandPalette: View {
    @EnvironmentObject var services: AppServices
    @State private var query = ""
    @State private var selection = 0
    @State private var entries: [PaletteEntry] = []
    @State private var keyMonitor: Any?
    /// The ranking clock, FROZEN at open (W6 wave 4): ranking against the live
    /// heartbeat `now` re-scored recency every 10s tick — rows could shift under
    /// a held arrow-key selection mid-flight. Results now change only when the
    /// user types.
    @State private var openedAt = Date()
    @FocusState private var focused: Bool

    /// The ranked rows for the current query — the pure ranker over the built
    /// index, mapped back to display rows.
    private var results: [PaletteEntry] {
        let byID = Dictionary(entries.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return PaletteRanker.rank(entries.map(\.candidate), query: query,
                                  now: openedAt, limit: 60)
            .compactMap { byID[$0.id] }
    }

    var body: some View {
        ZStack(alignment: .top) {
            Color.black.opacity(0.16)
                .ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { close() }

            PalettePanel(query: query, results: results, selection: selection, field: {
                TextField("Search sessions, skills, screens, recipes, actions…", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .foregroundStyle(Theme.ink)
                    .focused($focused)
                    .onSubmit { invoke(selection, alt: false) }
            }, onHover: { selection = $0 }, onInvoke: { invoke($0, alt: false) })
            .padding(.top, 96)
        }
        .onAppear {
            query = ""
            selection = 0
            openedAt = Date()
            entries = PaletteEntries.build(services: services)
            focused = true
            installMonitor()
        }
        .onDisappear { removeMonitor() }
        .onChange(of: query) { _, _ in selection = 0 }
    }

    private func close() {
        removeMonitor()
        services.showPalette = false
    }

    private func invoke(_ index: Int, alt: Bool) {
        let r = results
        guard r.indices.contains(index) else { return }
        let entry = r[index]
        close()
        if alt, let runAlt = entry.runAlt { runAlt() } else { entry.run() }
    }

    // Arrow / enter / escape handling. A local key monitor is the robust path
    // while the TextField holds first-responder focus (arrow keys would otherwise
    // just move the insertion point). Removed on dismiss so nothing leaks.
    private func installMonitor() {
        removeMonitor()
        // The local key monitor fires on the main run loop, so its work is safely
        // MainActor (assumeIsolated). Only primitives cross the isolation boundary —
        // the NSEvent itself never does (it isn't Sendable) — and the handler
        // returns nil to swallow a navigation key, or the event to pass typing on.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let keyCode = event.keyCode
            let cmd = event.modifierFlags.contains(.command)
            let ctrl = event.modifierFlags.contains(.control)
            let ch = event.charactersIgnoringModifiers
            let handled: Bool = MainActor.assumeIsolated {
                let count = results.count
                func move(_ delta: Int) { if count > 0 { selection = min(max(selection + delta, 0), count - 1) } }
                switch keyCode {
                case 125: move(1); return true                      // ↓
                case 126: move(-1); return true                     // ↑
                case 36, 76: invoke(selection, alt: cmd); return true // return / enter
                case 53: close(); return true                       // escape
                default:
                    if ctrl, ch == "n" { move(1); return true }     // ⌃n
                    if ctrl, ch == "p" { move(-1); return true }    // ⌃p
                    return false
                }
            }
            return handled ? nil : event
        }
    }

    private func removeMonitor() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
    }
}

// MARK: - Index builder — reuse every store, recompute nothing

enum PaletteEntries {

    /// Build the full searchable index from the live stores. Cheap per open
    /// (a snapshot while the palette is up); the ranker does the per-keystroke work.
    @MainActor
    static func build(services: AppServices) -> [PaletteEntry] {
        var out: [PaletteEntry] = []
        out += screens(services)
        out += actions(services)
        out += recipes(services)
        out += sessions(services)
        out += skills(services)
        return out
    }

    // SCREENS — jump to any section (VISION 3.4). Keyword synonyms make screens
    // findable by what they DO, not only their title.
    @MainActor private static func screens(_ services: AppServices) -> [PaletteEntry] {
        AppSection.allCases.map { section in
            let key = String(section.shortcut.character)
            let id = "screen:\(section.rawValue)"
            let hint = Text("⌘\(key)").font(.system(.caption2, design: .monospaced))
                + Text(" · jump to section").font(.caption2)
            return PaletteEntry(
                id: id, kind: .screen, title: section.title, hint: hint, icon: section.icon,
                candidate: PaletteCandidate(id: id, primary: section.title,
                                            secondary: [section.rawValue] + synonyms(section),
                                            group: PaletteKind.screen.rawValue),
                run: { [weak services] in services?.section = section })
        }
    }

    private static func synonyms(_ section: AppSection) -> [String] {
        switch section {
        case .overview: return ["home", "dashboard", "vitals"]
        case .live:     return ["now", "streaming", "tiles"]
        case .fleet:    return ["board", "kanban", "attention", "blocked", "waiting"]
        case .deadlines: return ["deadline", "due", "jeopardy", "countdown", "linear", "hackathon", "stalled"]
        case .sessions: return ["transcripts", "history", "index"]
        case .spend:    return ["cost", "routing", "dollars", "tier", "money"]
        case .audit:    return ["findings", "waste", "doctrine", "dead skills", "mismatch"]
        case .ledger:   return ["dreaming", "lessons", "fixes"]
        case .launch:   return ["builder", "recipe", "compose", "spawn"]
        case .stack:    return ["probes", "tools", "toolchain", "skills", "mcp"]
        }
    }

    // ACTIONS — Dream now, Refresh, etc. (VISION 3.4).
    @MainActor private static func actions(_ services: AppServices) -> [PaletteEntry] {
        func action(_ slug: String, _ title: String, _ desc: String, _ icon: String,
                    _ keywords: [String], _ run: @escaping @MainActor () -> Void) -> PaletteEntry {
            let id = "action:\(slug)"
            return PaletteEntry(
                id: id, kind: .action, title: title,
                hint: Text(desc).font(.caption2), icon: icon,
                candidate: PaletteCandidate(id: id, primary: title, secondary: keywords,
                                            group: PaletteKind.action.rawValue),
                run: run)
        }
        return [
            action("refresh", "Refresh data", "re-scan sessions, skills, audit",
                   "arrow.clockwise", ["reload", "rescan", "sync data"]) { [weak services] in
                services?.refreshAll()
            },
            action("dream", "Distill findings", "mint lessons from the latest findings",
                   "moon.stars", ["ledger", "lessons", "dreaming"]) { [weak services] in
                guard let services else { return }
                services.dreamNow(trigger: .manual)
                services.section = .ledger
            },
            action("sync-fleet", "Sync fleet", "pull remote transcripts over Tailscale",
                   "arrow.triangle.2.circlepath", ["cross machine", "workstation", "remote", "tailscale"]) { [weak services] in
                services?.machines.syncInBackground()
            },
            action("new-recipe", "New recipe", "compose a launch recipe from scratch",
                   "plus", ["builder", "launch", "compose"]) { [weak services] in
                services?.section = .launch
            },
        ]
    }

    // RECIPES — launch a saved recipe (VISION 3.4). ↵ composes + copies the
    // launch command to the clipboard (the exact path LaunchScreen's card uses).
    @MainActor private static func recipes(_ services: AppServices) -> [PaletteEntry] {
        services.launch.recipes.map { recipe in
            let id = "recipe:\(recipe.id)"
            let cwd = recipe.cwd.isEmpty
                ? "no working dir"
                : recipe.cwd.replacingOccurrences(of: NSHomeDirectory(), with: "~")
            let hint = Text(cwd).font(.system(.caption2, design: .monospaced))
                + Text(" · \(recipe.effort.label) · \(recipe.agents.count) agent\(recipe.agents.count == 1 ? "" : "s")")
                    .font(.caption2)
            return PaletteEntry(
                id: id, kind: .recipe, title: recipe.name, hint: hint, icon: PaletteKind.recipe.icon,
                warn: false,
                candidate: PaletteCandidate(id: id, primary: recipe.name,
                                            secondary: [recipe.cwd] + recipe.skillRefs + recipe.agents.map(\.name),
                                            recency: recipe.updatedAt, group: PaletteKind.recipe.rawValue),
                run: { [weak services] in services?.launchRecipe(recipe) })
        }
    }

    // SESSIONS — jump to the transcript (↵ · services.inspect) or copy the
    // resume command (⌘↵ · SessionResume.command). The door light + machine
    // chip ride each row.
    @MainActor private static func sessions(_ services: AppServices) -> [PaletteEntry] {
        let board = services.attentionBoard(now: services.now)
        let stateByID = Dictionary(board.items.map { ($0.session.id, $0.state) },
                                   uniquingKeysWith: { a, _ in a })
        let crossMachine = services.isCrossMachine
        // Cap at the most-recent mains — the palette targets work you're doing,
        // not every transcript ever written.
        let recent = services.sessions.sessions
            .filter { !$0.isSubagent }
            .sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
            .prefix(500)

        return recent.map { s in
            let id = "session:\(s.id)"
            let hint = Text(s.shortID).font(.system(.caption2, design: .monospaced))
                + Text(" · \(s.tier.label) · \(fmtAgo(s.lastActivity))").font(.caption2)
            let sid = s.id, cwd = s.cwd
            return PaletteEntry(
                id: id, kind: .session, title: s.displayTitle, hint: hint, icon: PaletteKind.session.icon,
                tier: s.tier, state: stateByID[s.id] ?? .idle,
                machineID: crossMachine ? s.machineID : nil,
                candidate: PaletteCandidate(
                    id: id, primary: s.displayTitle,
                    secondary: [s.shortID, (s.cwd as NSString).lastPathComponent, s.tier.label,
                                String((s.lastUserMessage ?? "").prefix(80))].filter { !$0.isEmpty },
                    recency: s.lastActivity, group: PaletteKind.session.rawValue),
                altLabel: "Copy resume",
                run: { [weak services] in services?.inspect(s) },
                runAlt: {
                    let cmd = SessionResume.command(sessionID: sid, cwd: cwd)
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(cmd, forType: .string)
                })
        }
    }

    // SKILLS — open the detail browser (↵ · the Stack screen) or Launch (⌘↵ ·
    // seedLaunch → the Session Builder). From the hierarchy's every-lane list.
    @MainActor private static func skills(_ services: AppServices) -> [PaletteEntry] {
        let all = services.skills.allSkills.isEmpty ? services.skills.skills : services.skills.allSkills
        return all.enumerated().map { i, sk in
            let id = "skill:\(i):\(sk.qualifiedID)"
            let hint = Text("/\(sk.qualifiedID)").font(.system(.caption2, design: .monospaced))
                + Text(" · \(sk.source.lane.title)").font(.caption2)
            return PaletteEntry(
                id: id, kind: .skill, title: sk.name, hint: hint, icon: PaletteKind.skill.icon,
                candidate: PaletteCandidate(
                    id: id, primary: sk.name,
                    secondary: [sk.id, sk.qualifiedID, String(sk.description.prefix(80))]
                        + sk.triggers.map { String($0.prefix(60)) },
                    group: PaletteKind.skill.rawValue),
                altLabel: "Launch",
                run: { [weak services] in services?.section = .stack },
                runAlt: { [weak services] in services?.seedLaunch(skill: sk.id) })
        }
    }
}
