import SwiftUI
import TrifolaKit

/// Forces the main window frontmost at launch. Without this the app runs but
/// never reliably presents (snapshot.sh captures whatever was already on
/// screen), so every launch-time hook that can win the activation race is here:
/// activate by app, join the active Space, key + order-front regardless.
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private var presentTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        forceFront(attempt: 0)
    }

    /// The SwiftUI WindowGroup window may not exist yet at didFinishLaunching;
    /// retry briefly until it does.
    private func forceFront(attempt: Int) {
        NSApp.activate(ignoringOtherApps: true)
        let window = NSApp.windows.first {
            $0.canBecomeKey && !($0.className.contains("StatusBar"))
        }
        if let window {
            // canJoinAllSpaces is stickier than moveToActiveSpace when the user
            // is actively on another Space (e.g. mid-capture).
            window.collectionBehavior.insert(.canJoinAllSpaces)
            // Snapshot/present mode: pin above the user's active windows so the
            // capture reliably shows the app even while they're working elsewhere.
            // `.floating` lost to full-screen browsers and other floating panels
            // in practice, so present mode goes to `.statusBar` and keeps
            // re-asserting for a minute — the capture window snapshot.sh needs.
            let environment = ProcessInfo.processInfo.environment
            if environment["TRIFOLA_PRESENT"] != nil || environment["CMC_PRESENT"] != nil {
                window.level = .statusBar
                if let screen = window.screen ?? NSScreen.main {
                    let vf = screen.visibleFrame
                    let w = min(1440, vf.width - 32)
                    let h = min(900, vf.height - 16)
                    window.setFrame(NSRect(x: (vf.midX - w / 2).rounded(),
                                           y: (vf.midY - h / 2).rounded(),
                                           width: w, height: h), display: true)
                }
                presentTimer?.invalidate()
                let deadline = Date().addingTimeInterval(60)
                presentTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak window, weak self] t in
                    guard let window, Date() < deadline else {
                        t.invalidate()
                        Task { @MainActor [weak self] in self?.presentTimer = nil }
                        return
                    }
                    Task { @MainActor in
                        NSApp.activate(ignoringOtherApps: true)
                        window.orderFrontRegardless()
                    }
                }
            }
            window.makeKeyAndOrderFront(nil)
            window.orderFrontRegardless()
        } else if attempt < 20 {
            Task { @MainActor [weak self] in
                try? await Task.sleep(for: .milliseconds(100))
                self?.forceFront(attempt: attempt + 1)
            }
        }
    }

    // Clicking the Dock icon with no visible window re-presents it.
    func applicationShouldHandleReopen(_ sender: NSApplication,
                                       hasVisibleWindows flag: Bool) -> Bool {
        if !flag { forceFront(attempt: 0) }
        return true
    }
}

struct TrifolaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var services = AppServices()
    // Menu-bar on/off lives on its OWN low-frequency object so `.commands` + the
    // MenuBarExtra don't observe the high-frequency `services` (render-storm fix —
    // see MenuBarPresence.swift).
    @StateObject private var menuPresence = MenuBarPresence()

    var body: some Scene {
        WindowGroup("Trifola", id: "main") {
            RootView()
                .environmentObject(services)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1440, height: 900)
        .commands {
            CommandGroup(after: .toolbar) {
                Button("Refresh Data") { services.refreshAll() }
                    .keyboardShortcut("r", modifiers: .command)
                // The command palette's front door (VISION 3.4) — everything
                // reachable in three keystrokes.
                Button("Command Palette") { services.showPalette.toggle() }
                    .keyboardShortcut("k", modifiers: .command)
                // The road back when the strip is hidden: the dropdown's own
                // toggle is unreachable once the item leaves the bar, so the
                // main window's View menu always carries the switch.
                Button(menuPresence.enabled ? "Hide Menu-Bar Strip" : "Show Menu-Bar Strip") {
                    menuPresence.enabled.toggle()
                }
            }
        }

        // MENU-BAR PRESENCE (plan 03): the judgment strip. `isInserted:` gates
        // the NSStatusItem behind the persisted setting (default ON) or the
        // CMC_MENUBAR launch pin — the main window app works identically with
        // it off, so this never becomes the only door into the app.
        MenuBarExtra(isInserted: menuPresence.boundEnabled) {
            MenuBarContent()
                .environmentObject(services)
                .environmentObject(menuPresence)
        } label: {
            MenuBarLabel()
                .environmentObject(services)
        }
        .menuBarExtraStyle(.window)

        Settings {
            TrifolaSettingsView(menuPresence: menuPresence,
                                notifier: services.notifier,
                                preferences: services.preferences,
                                machines: services.machines)
        }
    }
}

/// The always-visible menu-bar glyph. RESEARCH finding #5: the market has
/// credit-bars (OpenUsage/CodexBar) but no *attention* bar. This owns that corner
/// — and it's the door light at its fourth distance (POLISH II.A): a TEMPLATE
/// rendering of the mark, not a rented SF gauge. Three honest states — hollow ring
/// (quiet), dot-in-ring (running), filled dot + ring (needs you) — plus the BLOCKED
/// count so you see it without opening anything.
struct MenuBarLabel: View {
    @EnvironmentObject var services: AppServices

    var body: some View {
        // The reducer owns the semantics (tested + selfchecked on the real
        // corpus); this view only paints. Title = BLOCKED count ("9+" capped),
        // or today's whole-$ when the orchestrator-hog alert fires with nothing
        // blocked — the "bleeding money" state visible without opening anything.
        let board = services.alertingAttentionBoard(now: services.now)
        let dayKey = CostProvenance.dayKey(for: services.now)
        let hog = OrchestratorHog.alert(sessions: services.sessions.sessions, day: dayKey)
        let today = services.sessions.sessions.reduce(0) { $0 + $1.cost(onDay: dayKey) }
        HStack(spacing: 3) {
            Image(nsImage: AppBrand.markImage(size: 15,
                                              state: markState(MenuBarReducer.glyph(board: board)),
                                              template: true))
            if let title = MenuBarReducer.titleText(board: board, hogFiring: hog != nil,
                                                    todayCost: today) {
                Text(title)
            }
        }
    }

    private func markState(_ glyph: MenuBarGlyphState) -> AppBrand.MarkState {
        switch glyph {
        case .needsYou: return .needsYou   // ball in your court
        case .running:  return .running    // work streaming
        case .quiet:    return .quiet      // hollow ring
        }
    }
}

/// The judgment strip's dropdown (plan 03) — NOT a mini dashboard. Renders the
/// tested `MenuBarReducer.model` verbatim: who needs me (blocked, then waiting,
/// stuck-longest first), am I bleeding money (fleet $-today + hog evidence),
/// and any quota window over 80% — then one button to the fuller picture. The
/// calm state says so and shows nothing else (Cat Wu, RESEARCH #4: build only
/// what the live control plane can't — judgment, not duplication).
struct MenuBarContent: View {
    @EnvironmentObject var services: AppServices
    @EnvironmentObject var menuPresence: MenuBarPresence
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        let now = services.now
        let dayKey = CostProvenance.dayKey(for: now)
        let sessions = services.sessions.sessions
        let rawBoard = services.attentionBoard(now: now)
        let suppression = services.attentionSuppression(now: now)
        let mb = MenuBarReducer.model(
            board: suppression.alertingBoard,
            cards: services.deadlineCards(now: now),
            todayCost: sessions.reduce(0) { $0 + $1.cost(onDay: dayKey) },
            hog: OrchestratorHog.alert(sessions: sessions, day: dayKey),
            quota: services.quota.snapshot,
            now: now)
        let rawMB = MenuBarReducer.model(
            board: rawBoard, cards: [], todayCost: 0, now: now)
        let suppressedIDs = Set(suppression.suppressedRows.map(\.id))
        let suppressedBlocked = rawMB.blocked.filter { suppressedIDs.contains($0.id) }
        let suppressedWaiting = rawMB.waiting.filter { suppressedIDs.contains($0.id) }

        return VStack(alignment: .leading, spacing: Theme.intraCell) {
            // One template mark + one sans status line: identity and judgment,
            // without turning the dropdown into another dashboard.
            HStack(spacing: Theme.intraCell) {
                Image(nsImage: AppBrand.markImage(
                    size: 15,
                    state: markState(mb.glyph),
                    template: true))
                Text(mb.fleetLine + suppression.legendSuffix + " · API-rate estimate")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
            }

            // WHO NEEDS ME — the strip's reason to exist.
            if mb.blocked.isEmpty && mb.waiting.isEmpty {
                HStack(spacing: 7) {
                    SeatMark(fill: Theme.green, size: 7)
                    Text("Nothing needs you")
                        .font(.subheadline)
                        .foregroundStyle(Theme.muted)
                    Spacer()
                }
            } else {
                ForEach(mb.blocked) { row in
                    attentionRow(row, state: .blocked)
                }
                ForEach(mb.waiting) { row in
                    attentionRow(row, state: .waiting)
                }
            }
            ForEach(suppressedBlocked) { row in
                attentionRow(row, state: .blocked, suppressed: true)
            }
            ForEach(suppressedWaiting) { row in
                attentionRow(row, state: .waiting, suppressed: true)
            }

            // AM I BLEEDING MONEY / TIME — evidence-gated; absent when calm.
            if mb.hogLine != nil || mb.jeopardy != nil || mb.quotaLine != nil {
                Divider()
            }
            if let hogLine = mb.hogLine {
                signalRow(icon: "flame.fill", tint: Theme.red, text: hogLine)
            }
            if let j = mb.jeopardy {
                signalRow(icon: "clock.badge.exclamationmark", tint: Theme.amber,
                          text: "\(j.projectKey) — \(j.stateLabel) · \(j.countdown)")
            }
            if let quotaLine = mb.quotaLine {
                signalRow(icon: "gauge.high", tint: Theme.amber, text: quotaLine)
            }
            Divider()
            HoverRow(action: {
                NSApp.activate(ignoringOtherApps: true)
                openWindow(id: "main")
            }) {
                HStack {
                    Text("open trifola").font(.footnote).foregroundStyle(Theme.muted)
                    Spacer()
                    Text("⌘O").font(.caption2).foregroundStyle(Theme.faint)
                }
                .frame(minHeight: Theme.compactRowHeight)
            }
        }
        .padding(Theme.cardPadding)
        .frame(width: 320)
        .background(.regularMaterial)
        .onAppear { services.start() }
    }

    private func markState(_ glyph: MenuBarGlyphState) -> AppBrand.MarkState {
        switch glyph {
        case .needsYou: return .needsYou
        case .running: return .running
        case .quiet: return .quiet
        }
    }

    /// One attention row: door-light dot in the state's color, the session's
    /// name, then "state · stuck-time · model". Clicking hands off to the main
    /// window's live detail — the strip is a doorway, not a destination.
    private func attentionRow(_ row: MenuBarModel.AttentionRow,
                              state: AttentionState,
                              suppressed: Bool = false) -> some View {
        HoverRow(action: {
            if let s = services.sessions.sessions.first(where: { $0.id == row.id }) {
                services.openTerminal(s)
            }
        }) {
            HStack(spacing: 8) {
                SeatMark(fill: state.color, size: 7, active: state.needsAttention)
                if suppressed { SuppressionMark() }
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(row.project) · \(row.title)")
                        .font(.subheadline.weight(state == .blocked ? .semibold : .regular))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text("\(state.label.lowercased()) \(fmtAgeShort(row.age)) · \(row.tierLabel)")
                        .font(.caption2)
                        .foregroundStyle(Theme.faint)
                }
                Spacer()
            }
            .frame(minHeight: Theme.compactRowHeight)
        }
        .opacity(suppressed ? 0.45 : 1)
        .contextMenu {
            if let session = services.sessions.sessions.first(where: { $0.id == row.id }) {
                SessionAgencyMenu(session: session)
            }
        }
        .help("Opens your terminal — macOS asks permission the first time")
    }

    /// A money/time signal line (hog · jeopardy · hot quota) — icon + one
    /// sentence of evidence, never a bare nag.
    private func signalRow(icon: String, tint: Color, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 7) {
            Image(systemName: icon)
                .font(.caption.weight(.medium))
                .foregroundStyle(tint)
            Text(text)
                .font(.caption)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(minHeight: Theme.compactRowHeight)
    }
}
