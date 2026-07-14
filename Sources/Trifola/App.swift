import SwiftUI
import TrifolaKit

/// One presentation gate for the app's single main window. Every caller first
/// reuses the identified window; `openWindow` is reached only when no main
/// window exists. The installed creation action lets notification/deep-link
/// paths obey the same rule even though they do not own a SwiftUI environment.
@MainActor
enum MainWindowPresenter {
    static let windowIdentifier = NSUserInterfaceItemIdentifier("trifola.main")
    private static var installedCreationAction: (@MainActor () -> Void)?

    static func install(creationAction: @escaping @MainActor () -> Void) {
        installedCreationAction = creationAction
    }

    static var existingWindow: NSWindow? {
        NSApp.windows.first { window in
            window.identifier == windowIdentifier
                || (window.title == "Trifola"
                    && window.canBecomeKey
                    && !window.className.contains("StatusBar"))
        }
    }

    static func present(createIfNeeded: (@MainActor () -> Void)? = nil) {
        NSApp.activate(ignoringOtherApps: true)
        if let window = existingWindow {
            window.makeKeyAndOrderFront(nil)
            return
        }
        (createIfNeeded ?? installedCreationAction)?()
    }
}

/// One registry owns every navigation/open key equivalent and the glyph shown
/// for it. Scene commands, the rail and the command palette all consume this
/// map, so a painted shortcut can never exist without a registered command.
struct AppCommandSpec {
    let title: String
    let key: KeyEquivalent
    let modifiers: EventModifiers
    let glyph: String

    var shortcut: KeyboardShortcut { KeyboardShortcut(key, modifiers: modifiers) }
}

enum AppCommandMap {
    static let openMain = AppCommandSpec(
        title: "Open Trifola", key: "o", modifiers: .command, glyph: "⌘O")
    static let refresh = AppCommandSpec(
        title: "Refresh Data", key: "r", modifiers: .command, glyph: "⌘R")
    static let palette = AppCommandSpec(
        title: "Command Palette", key: "k", modifiers: .command, glyph: "⌘K")

    static func navigation(for section: AppSection) -> AppCommandSpec {
        switch section {
        case .overview:
            AppCommandSpec(title: section.title, key: "1", modifiers: .command, glyph: "⌘1")
        case .live:
            AppCommandSpec(title: section.title, key: "2", modifiers: .command, glyph: "⌘2")
        case .fleet:
            AppCommandSpec(title: section.title, key: "3", modifiers: .command, glyph: "⌘3")
        case .deadlines:
            AppCommandSpec(title: section.title, key: "d", modifiers: .command, glyph: "⌘D")
        case .sessions:
            AppCommandSpec(title: section.title, key: "4", modifiers: .command, glyph: "⌘4")
        case .spend:
            AppCommandSpec(title: section.title, key: "5", modifiers: .command, glyph: "⌘5")
        case .audit:
            AppCommandSpec(title: section.title, key: "6", modifiers: .command, glyph: "⌘6")
        case .ledger:
            AppCommandSpec(title: section.title, key: "7", modifiers: .command, glyph: "⌘7")
        case .launch:
            AppCommandSpec(title: section.title, key: "8", modifiers: .command, glyph: "⌘8")
        case .stack:
            AppCommandSpec(title: section.title, key: "9", modifiers: .command, glyph: "⌘9")
        }
    }
}

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
            if CommandLine.arguments.contains("--benchmark-nav-live") {
                // The live harness drives the exact sidebar action itself. Ignore
                // incidental pointer input so a human click cannot contaminate
                // cold/warm labels while the real window is being measured.
                window.ignoresMouseEvents = true
            }
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
                // Screenshot capture reasserts frontmost state because a human
                // may keep working in another app. The navigation benchmark
                // already ignores pointer input and owns the foreground window;
                // a one-second orderFront timer would inject unrelated AppKit
                // damage/draw work into the measured click path.
                if !CommandLine.arguments.contains("--benchmark-nav-live") {
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

private struct TrifolaSceneCommands: Commands {
    @ObservedObject var services: AppServices
    @ObservedObject var menuPresence: MenuBarPresence
    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Button(AppCommandMap.refresh.title) {
                services.refreshAll(refreshSelectedOpenAction: true)
            }
                .keyboardShortcut(AppCommandMap.refresh.key,
                                  modifiers: AppCommandMap.refresh.modifiers)
            Button(AppCommandMap.palette.title) { services.showPalette.toggle() }
                .keyboardShortcut(AppCommandMap.palette.key,
                                  modifiers: AppCommandMap.palette.modifiers)
            Button(menuPresence.enabled ? "Hide Menu-Bar Strip" : "Show Menu-Bar Strip") {
                menuPresence.enabled.toggle()
            }
        }

        CommandMenu("Navigate") {
            Button(AppCommandMap.openMain.title) { presentMainWindow() }
                .keyboardShortcut(AppCommandMap.openMain.key,
                                  modifiers: AppCommandMap.openMain.modifiers)
            Divider()
            ForEach(AppSection.allCases) { section in
                let command = AppCommandMap.navigation(for: section)
                Button(command.title) {
                    services.select(section, origin: .keyboard)
                    presentMainWindow()
                }
                .keyboardShortcut(command.key, modifiers: command.modifiers)
            }
        }
    }

    private func presentMainWindow() {
        MainWindowPresenter.present {
            openWindow(id: "main")
        }
    }
}

struct TrifolaApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var services = AppServices()
    // Menu-bar on/off lives on its OWN low-frequency object so `.commands` + the
    // MenuBarExtra don't observe the high-frequency `services` (render-storm fix —
    // see MenuBarPresence.swift).
    @StateObject private var menuPresence = MenuBarPresence()

    init() {
        Theme.Motion.prepareForLaunch()
    }

    var body: some Scene {
        Window("Trifola", id: "main") {
            RootView()
                .environmentObject(services)
                .environmentObject(services.navigation)
                .environmentObject(services.navigationSnapshots)
                .environmentObject(services.workspaceAccess)
                .environmentObject(services.automationAccess)
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: Theme.Layout.defaultWindowWidth,
                     height: Theme.Layout.defaultWindowHeight)
        .windowResizability(.contentMinSize)
        .commands {
            TrifolaSceneCommands(services: services, menuPresence: menuPresence)
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
                                workspaceAccess: services.workspaceAccess,
                                machines: services.machines,
                                agency: services.agency)
        }
    }
}

/// The always-visible menu-bar glyph. RESEARCH finding #5: the market has
/// credit-bars (OpenUsage/CodexBar) but no *attention* bar. This owns that corner
/// — and it's the identity shell around the Door Light core at its fourth
/// distance: a TEMPLATE rendering, not a rented SF gauge. Three honest states —
/// hollow aperture (quiet), small core (running), full core (needs you) — plus
/// the BLOCKED count so you see it without opening anything.
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
        let provisional = services.sessions.scanPresentation.isProvisional
        let glyph: MenuBarGlyphState = provisional
            ? .running : MenuBarReducer.glyph(board: board)
        let title = provisional ? nil : MenuBarReducer.titleText(
            board: board, hogFiring: hog != nil, todayCost: today)
        HStack(spacing: 3) {
            Image(nsImage: AppBrand.markImage(size: 18,
                                              state: markState(glyph),
                                              template: true))
            if let title {
                Text(title)
                    .liveNumericTransition(value: title)
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
        let mb = services.sessions.scanPresentation.isProvisional
            ? MenuBarReducer.readingModel(progress: services.sessions.scanProgress)
            : MenuBarReducer.model(
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

        let sessionsByID = Dictionary(
            sessions.map { ($0.id, $0) },
            uniquingKeysWith: { existing, candidate in
                // Cross-provider imports and remote mirrors can legitimately
                // repeat an id. Prefer this Mac, then the fresher transcript;
                // the popover must never trap while building its lookup.
                if existing.machineID == Machine.localID,
                   candidate.machineID != Machine.localID { return existing }
                if candidate.machineID == Machine.localID,
                   existing.machineID != Machine.localID { return candidate }
                return (candidate.lastActivity ?? .distantPast)
                    > (existing.lastActivity ?? .distantPast) ? candidate : existing
            })

        return MenuBarPanel(
            model: mb,
            legendSuffix: suppression.legendSuffix,
            suppressedBlocked: suppressedBlocked,
            suppressedWaiting: suppressedWaiting,
            sessionsByID: sessionsByID,
            onInspect: { id in
                guard let session = sessionsByID[id] else { return }
                inspect(session)
            },
            onOpenMain: presentMainWindow)
            .onAppear { services.start() }
    }

    private func presentMainWindow() {
        MainWindowPresenter.present {
            openWindow(id: "main")
        }
    }

    private func inspect(_ session: SessionSummary) {
        services.inspect(session)
        presentMainWindow()
    }

}

/// Store-free projection of the production menu-bar popover. The live wrapper
/// computes this model from AppServices; the render harness supplies a seeded
/// model, so both paths exercise the same hierarchy, rows, and interaction shell.
struct MenuBarPanel: View {
    @EnvironmentObject private var services: AppServices

    let model: MenuBarModel
    var legendSuffix = ""
    var suppressedBlocked: [MenuBarModel.AttentionRow] = []
    var suppressedWaiting: [MenuBarModel.AttentionRow] = []
    var sessionsByID: [String: SessionSummary] = [:]
    var onInspect: (String) -> Void = { _ in }
    var onOpenMain: () -> Void = {}

    var body: some View {
        let hasAttentionRows = !model.blocked.isEmpty || !model.waiting.isEmpty
            || !suppressedBlocked.isEmpty || !suppressedWaiting.isEmpty
        let hasSignals = model.hogLine != nil || model.jeopardy != nil || model.quotaLine != nil

        VStack(alignment: .leading, spacing: 0) {
            // The dropdown opens dozens of times a day, so its Door Light is a
            // complete AppKit raster: stateful, but with no first-appearance draw.
            HStack(spacing: Theme.codePadding) {
                Image(nsImage: AppBrand.markImage(
                    size: Theme.blockGap,
                    state: markState(model.glyph),
                    template: true))
                    .foregroundStyle(Theme.ink)
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: Theme.micro) {
                    Text(statusHeadline)
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text(model.fleetLine + legendSuffix + " · API-rate estimate")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(2)
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, Theme.cardPadding)
            .padding(.vertical, Theme.sectionGap)

            if hasAttentionRows {
                Divider()
                VStack(alignment: .leading, spacing: Theme.micro) {
                    ForEach(model.blocked) { row in
                        attentionRow(row, state: .blocked)
                    }
                    ForEach(model.waiting) { row in
                        attentionRow(row, state: .waiting)
                    }
                    ForEach(suppressedBlocked) { row in
                        attentionRow(row, state: .blocked, suppressed: true)
                    }
                    ForEach(suppressedWaiting) { row in
                        attentionRow(row, state: .waiting, suppressed: true)
                    }
                }
                .padding(.horizontal, Theme.rhythm)
                .padding(.vertical, Theme.intraCell)
            }

            // Money/time warnings remain evidence-gated and visually secondary
            // to the sessions that need an immediate human decision.
            if hasSignals {
                Divider()
                VStack(alignment: .leading, spacing: Theme.micro) {
                    if let hogLine = model.hogLine {
                        signalRow(icon: "flame.fill", tint: Theme.red, text: hogLine)
                    }
                    if let jeopardy = model.jeopardy {
                        signalRow(icon: "clock.badge.exclamationmark", tint: Theme.amber,
                                  text: "\(jeopardy.projectKey) — \(jeopardy.stateLabel) · \(jeopardy.countdown)")
                    }
                    if let quotaLine = model.quotaLine {
                        signalRow(icon: "gauge.high", tint: Theme.amber, text: quotaLine)
                    }
                }
                .padding(.horizontal, Theme.cardPadding)
                .padding(.vertical, Theme.intraCell)
            }

            Divider()
            HoverRow(action: onOpenMain) {
                HStack(spacing: Theme.intraCell) {
                    Text("Open Trifola")
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.ink)
                    Spacer()
                    Text(AppCommandMap.openMain.glyph)
                        .font(.caption2)
                        .foregroundStyle(Theme.faint)
                }
                .padding(.horizontal, Theme.intraCell)
                .frame(minHeight: Theme.compactRowHeight)
            }
            .padding(.horizontal, Theme.rhythm)
            .padding(.vertical, Theme.micro)
            .help("Open the Trifola dashboard")
        }
        .frame(width: Theme.Layout.menuWidth)
        .background(.regularMaterial)
        .reorderMotion(value: model.blocked.map(\.id) + model.waiting.map(\.id)
            + suppressedBlocked.map { "suppressed:\($0.id)" }
            + suppressedWaiting.map { "suppressed:\($0.id)" })
    }

    private var statusHeadline: String {
        if model.isReading { return "Reading sessions" }
        let needsYou = model.blocked.count + model.waiting.count
        if needsYou == 1 { return "1 session needs you" }
        if needsYou > 1 { return "\(needsYou) sessions need you" }

        let signals = [model.hogLine != nil, model.jeopardy != nil, model.quotaLine != nil]
            .filter { $0 }.count
        if signals == 1 { return "1 signal to review" }
        if signals > 1 { return "\(signals) signals to review" }
        return "All clear"
    }

    private func markState(_ glyph: MenuBarGlyphState) -> AppBrand.MarkState {
        switch glyph {
        case .needsYou: return .needsYou
        case .running: return .running
        case .quiet: return .quiet
        }
    }

    /// One attention row: Door Light, human identity, state/age/model, and an
    /// explicit inspector chevron. The primary click stays inside Trifola;
    /// terminal handoff is an explicit context-menu action only.
    private func attentionRow(_ row: MenuBarModel.AttentionRow,
                              state: AttentionState,
                              suppressed: Bool = false) -> some View {
        HoverRow(action: { onInspect(row.id) }) {
            HStack(spacing: Theme.intraCell) {
                SeatMark(state: DoorLightState(state), size: 8,
                         firstAppearanceDraw: false)
                if suppressed { SuppressionMark() }
                VStack(alignment: .leading, spacing: 1) {
                    Text("\(row.project) · \(row.title)")
                        .font(.subheadline.weight(state == .blocked ? .semibold : .regular))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    HStack(spacing: Theme.micro) {
                        Text(state.label.lowercased())
                            .font(.caption2.weight(.medium))
                            .foregroundStyle(state.color)
                        Text("· \(fmtAgeShort(row.age)) · \(row.tierLabel)")
                            .font(.caption2)
                            .foregroundStyle(Theme.muted)
                    }
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.faint)
            }
            .padding(.horizontal, Theme.intraCell)
            .padding(.vertical, Theme.micro)
            .frame(minHeight: Theme.compactRowHeight)
        }
        .opacity(suppressed ? 0.45 : 1)
        .motionRowTransition()
        .contextMenu {
            if let session = sessionsByID[row.id] {
                SessionAgencyMenu(session: session,
                                  includesOpenTerminal: !session.isRemote)
            }
        }
        .help("Open this session in Trifola")
    }

    /// A money/time signal line (hog · jeopardy · hot quota) — icon + one
    /// sentence of evidence, never a bare nag.
    private func signalRow(icon: String, tint: Color, text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Theme.intraCell) {
            Image(systemName: icon)
                .font(.caption.weight(.medium))
                .foregroundStyle(tint)
            Text(text)
                .font(.caption)
                .foregroundStyle(Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, Theme.intraCell)
        .padding(.vertical, Theme.micro)
        .frame(minHeight: Theme.compactRowHeight)
    }
}
