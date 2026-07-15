import SwiftUI
import AppKit
import TrifolaKit

struct RootView: View {
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency
    // RENDER-STORM ROOT CAUSE (2026-07-08): RootView is the WindowGroup's ROOT view.
    // On macOS 26, every time the scene's root view re-evaluates, SwiftUI re-enters the
    // Liquid-Glass `glassEffectBackdropObserver` update loop and never reaches a fixed
    // point → 99% CPU while the window is frontmost (App Nap suspends it in the
    // background, which masked the storm and derailed the diagnosis for a long time). A
    // *child* view re-rendering does NOT trigger it — only a re-render of the scene root.
    //
    // THE FIX: RootView.body must not read ANY `services` property, so a data publish
    // never re-renders this body. Everything that observes the high-frequency `services`
    // lives one level down — Sidebar / ContentColumn (the content), CommandPaletteHost
    // (the ⌘K overlay), and RootLifecycle (start() + Dock badge). Re-introducing a
    // `services` read here — even one — brings the storm straight back.
    var body: some View {
        AppMotionScope {
            HStack(spacing: 0) {
                Sidebar()
                    .frame(width: Theme.Layout.sidebarWidth)
                    .background {
                        Theme.surfaceSidebar.ignoresSafeArea()
                    }
                    .launchReveal(.rail)
                Divider()
                    .ignoresSafeArea()
                ContentColumn()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background {
                        Theme.surfaceWindow.ignoresSafeArea()
                        if !reduceTransparency {
                            VisualEffectBackground(material: .underWindowBackground)
                                .opacity(0.16)
                                .ignoresSafeArea()
                        }
                    }
            }
            .background(WindowConfigurator())
            .frame(minWidth: Theme.Layout.minimumWindowWidth,
                   minHeight: Theme.Layout.minimumWindowHeight)
            .overlay { CommandPaletteHost() }
            .overlay { OnboardingPresentationHost() }
            .background(WorkspaceAccessPromptHost())
            .background(RootLifecycle())
        }
    }
}

/// A child bridge publishes the non-observable one-shot registry into the view
/// environment without making the scene root observe AppServices (the render-
/// storm invariant above remains intact).
private struct AppMotionScope<Content: View>: View {
    @EnvironmentObject private var services: AppServices
    @ViewBuilder let content: () -> Content

    var body: some View {
        content().environment(\.revealRegistry, services.reveals)
    }
}

/// The ⌘K command palette (VISION 3.4) — a floating overlay over the whole window.
/// Observes `services.showPalette` HERE (a child), so toggling the palette re-renders
/// this view, never the scene root (see RootView's render-storm note).
private struct CommandPaletteHost: View {
    @EnvironmentObject var services: AppServices
    var body: some View {
        ZStack {
            if services.showPalette {
                CommandPalette()
            }
        }
    }
}

/// The at-value Accessibility explainer lives in a child presentation host so
/// its one rare publication never makes the scene root observe AppServices. The
/// nested presenter observes only the dedicated low-frequency coordinator.
private struct WorkspaceAccessPromptHost: View {
    @EnvironmentObject private var coordinator: WorkspaceAccessCoordinator

    var body: some View {
        WorkspaceAccessPromptPresenter(coordinator: coordinator)
    }
}

private struct WorkspaceAccessPromptPresenter: View {
    @ObservedObject var coordinator: WorkspaceAccessCoordinator

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .alert(
                WorkspaceAccessCopy.title,
                isPresented: Binding(
                    get: { coordinator.pendingPrompt != nil },
                    // Both dismissal routes are explicit buttons below; leaving
                    // this setter inert prevents SwiftUI from resolving Not Now
                    // before the primary action runs.
                    set: { _ in })
            ) {
                Button(WorkspaceAccessCopy.openSettingsButton) {
                    coordinator.resolvePrompt(with: .settingsOpened)
                }
                Button(WorkspaceAccessCopy.notNowButton, role: .cancel) {
                    coordinator.resolvePrompt(with: .notNow)
                }
            } message: {
                Text(WorkspaceAccessCopy.body)
            }
            .onDisappear { coordinator.cancelPendingPrompt() }
    }
}

/// App launch + Dock badge, isolated in a zero-size child. The Dock badge = count of
/// BLOCKED sessions (the one alert the no-nag doctrine allows). Keeping the
/// `blockedCount` observation (and the launch `start()`) out of RootView.body is what
/// stops a data publish from re-rendering the scene root.
private struct RootLifecycle: View {
    @EnvironmentObject var services: AppServices
    @Environment(\.openWindow) private var openWindow
    var body: some View {
        Color.clear
            .task {
                MainWindowPresenter.install {
                    openWindow(id: "main")
                }
                AppBrand.applyDockIcon()
                services.start()
                if CommandLine.arguments.contains("--benchmark-nav-live") {
                    await NavBenchmark.driveRealClickPath(using: services)
                }
            }
            .onChange(of: services.blockedCount, initial: true) { _, n in
                AppBrand.updateDockBadge(blockedCount: n)
            }
            .onDisappear {
                services.reveals.windowDidClose()
            }
    }
}

// MARK: - Content switch

private struct ContentColumn: View {
    @EnvironmentObject var navigation: AppNavigation
    @EnvironmentObject var navigationSnapshots: NavigationSnapshotStore
    @State private var presentedGeneration = 0

    // The destination is rendered from exactly ONE structural position and the
    // shell overlays it — never an if/else sibling swap. Rendering the
    // destination from different branches as `presentedGeneration` caught up
    // gave it a new SwiftUI identity one main-queue tick after it appeared, so
    // every section switch mounted the heavy screen TWICE (state reset, scroll
    // reset, a visible double-freeze — the "janky switch"). Probe activity is a
    // parameter, not presence, for the same reason. The phase
    // decision itself is pure and pinned: NavigationPresentation (TrifolaKit).
    var body: some View {
        let generation = navigation.navigationMetricGeneration
        let isPending = presentedGeneration != generation
        let isReady = navigationSnapshots.isReady(for: navigation.section)
        let phase = NavigationPresentation.resolve(
            isPending: isPending,
            cold: navigation.navigationCold,
            ready: isReady)
        let contentCarriesFirstFrame = NavigationPresentation.contentCarriesFirstFrame(
            isPending: isPending,
            cold: navigation.navigationCold,
            ready: isReady)
        let animates = navigation.navigationOrigin == .pointer
        ZStack {
            if phase == .content {
                destination
                    .id(navigation.section)
                    .sectionTransition(enabled: animates)
                    .navigationFirstDrawProbe(
                        generation: generation,
                        milestone: .firstFrame,
                        journey: navigation.navigationMetricJourney,
                        activity: contentCarriesFirstFrame ? .active : .ownedElsewhere,
                        onDraw: presentDestination)
                    .navigationFirstDrawProbe(
                        generation: generation,
                        milestone: .hydratedContent,
                        journey: navigation.navigationMetricJourney,
                        activity: NavigationPresentation.hydratedContentProbeActivity(
                            isReady: isReady))
                    .onAppear {
                        navigation.navigationDidAppear(navigation.section)
                    }
            }
            if phase == .shell {
                destinationShell
                    .shellExitTransition(enabled: animates)
                    .onAppear {
                        navigation.navigationDidAppear(navigation.section)
                    }
                    .navigationFirstDrawProbe(
                        generation: generation,
                        milestone: .firstFrame,
                        journey: navigation.navigationMetricJourney,
                        onDraw: presentDestination)
            }
        }
    }

    private func presentDestination() {
        let generation = navigation.navigationMetricGeneration
        // Mutate after AppKit completes this draw pass. A shell is therefore
        // a committed visual frame before the heavy destination mounts; a
        // warm destination merely retires its own first-frame probe (the
        // state write changes no structure, so nothing remounts).
        DispatchQueue.main.async {
            guard generation == navigation.navigationMetricGeneration else { return }
            presentedGeneration = generation
        }
    }

    private var destination: some View {
        sectionView(for: navigation.section)
    }

    private var destinationShell: some View {
        VStack(alignment: .leading, spacing: Theme.blockGap) {
            VStack(alignment: .leading, spacing: Theme.micro) {
                Text(navigation.section.title)
                    .font(Theme.Typography.screenTitle)
                    .foregroundStyle(Theme.ink)
                Text("Preparing the latest local snapshot…")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.muted)
            }
            .frame(minHeight: ScreenScaffoldMetrics.headerHeight,
                   alignment: .topLeading)
            .padding(.top, ScreenScaffoldMetrics.topInset)
            Divider()
            HStack(spacing: Theme.rhythm) {
                Image(systemName: "circle.dotted")
                    .foregroundStyle(Theme.muted)
                Text("Loading \(navigation.section.title.lowercased())…")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
        }
        .padding(.horizontal, Theme.gutter)
        .background(Theme.surfaceWindow)
        .frame(maxWidth: .infinity, maxHeight: .infinity,
               alignment: .topLeading)
    }

    @ViewBuilder private func sectionView(for section: AppSection) -> some View {
        switch section {
        case .overview: OverviewScreen()
        case .live: LiveScreen()
        case .fleet: FleetScreen()
        case .deadlines: DeadlineScreen()
        case .sessions: SessionsScreen()
        case .spend: SpendScreen()
        case .audit: AuditScreen()
        case .ledger: LedgerScreen()
        case .launch: LaunchScreen()
        case .stack: StackScreen()
        }
    }

}

// MARK: - Sidebar

struct SidebarSnapshot {
    var selected: AppSection
    let worstState: AttentionState?
    let liveCount: Int
    let pendingLessonCount: Int
    let todayCost: Double
    let monthProjection: Double
    var scanReadingText: String? = nil
    let updatedText: String
    let refreshText: String?
    let account: String
    let machine: String
    var animatesSelection = true

    func badge(for section: AppSection) -> Int? {
        switch section {
        case .fleet: return liveCount > 0 ? liveCount : nil
        case .ledger: return pendingLessonCount > 0 ? pendingLessonCount : nil
        default: return nil
        }
    }

    func selecting(_ section: AppSection) -> SidebarSnapshot {
        var copy = self
        copy.selected = section
        return copy
    }
}

/// Pure production rail chrome. The live app and LayoutRender feed different
/// snapshots into this same view, eliminating the C-5 projection drift.
struct SidebarRail: View {
    let snapshot: SidebarSnapshot
    var onSelect: (AppSection) -> Void = { _ in }
    var onKeyboardSelect: ((AppSection) -> Void)? = nil
    @Namespace private var selectionNamespace

    private let primarySections: [AppSection] = [
        .overview, .fleet, .sessions, .spend, .audit, .stack,
    ]
    private let utilitySections: [AppSection] = [
        .live, .deadlines, .ledger, .launch,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Wordmark(worst: snapshot.worstState)
                .padding(.horizontal, Theme.gutter)
                .frame(height: ScreenScaffoldMetrics.headerHeight, alignment: .top)
                .padding(.top, ScreenScaffoldMetrics.topInset)

            Divider()

            VStack(spacing: 2) {
                ForEach(primarySections) { section in
                    SidebarItem(section: section,
                                isSelected: snapshot.selected == section,
                                badge: snapshot.badge(for: section),
                                selectionNamespace: selectionNamespace,
                                animatesSelection: snapshot.animatesSelection,
                                action: { onSelect(section) },
                                keyboardAction: { (onKeyboardSelect ?? onSelect)(section) })
                }

                Divider().padding(.vertical, Theme.micro)

                ForEach(utilitySections) { section in
                    SidebarItem(section: section,
                                isSelected: snapshot.selected == section,
                                badge: snapshot.badge(for: section),
                                selectionNamespace: selectionNamespace,
                                animatesSelection: snapshot.animatesSelection,
                                quiet: true,
                                action: { onSelect(section) },
                                keyboardAction: { (onKeyboardSelect ?? onSelect)(section) })
                }
            }
            .padding(.horizontal, Theme.intraCell)
            .padding(.top, Theme.paneInset)

            Spacer()

            SidebarFooter(snapshot: snapshot)
                .padding(.horizontal, Theme.gutter)
                .padding(.bottom, Theme.cardPadding)
        }
    }
}

private struct Sidebar: View {
    @EnvironmentObject var services: AppServices
    @EnvironmentObject var navigationSnapshots: NavigationSnapshotStore

    var body: some View {
        let progress = services.sessions.scanProgress
        let refreshText: String? = {
            guard services.sessions.scanPresentation == .liveRefreshing,
                  progress.isInProgress else { return nil }
            guard progress.totalEstimate > 0 else { return "refreshing" }
            return "refreshing \(fmtGrouped(progress.scanned))/~\(fmtGrouped(progress.totalEstimate))"
        }()
        let corpus = navigationSnapshots.corpus
        return SidebarNavigationRail(snapshot: SidebarSnapshot(
            // Replaced by SidebarNavigationRail's isolated navigation read.
            selected: .overview,
            worstState: services.sessions.scanPresentation.isProvisional
                ? .running : navigationSnapshots.fleet?.attention.worst,
            liveCount: corpus?.activeSessions.count ?? 0,
            pendingLessonCount: services.pendingLessonCount,
            todayCost: corpus?.burnGovernor.today.cost ?? 0,
            monthProjection: corpus?.burnGovernor.monthProjection ?? 0,
            scanReadingText: services.sessions.scanPresentation.isProvisional
                ? progress.readingSentence : nil,
            updatedText: "updated \(fmtAgo(services.sessions.lastRefresh))",
            refreshText: refreshText,
            account: NSUserName(),
            machine: Host.current().localizedName ?? "this Mac"),
            onSelect: { section in
                services.select(section, origin: .pointer)
            },
            onKeyboardSelect: { section in
                services.select(section, origin: .keyboard)
            })
    }
}

/// Selection is the only changing input on a navigation click. Keeping that
/// observation one level below the operational snapshot prevents highlight
/// movement from rebuilding burn, attention, and fleet projections.
private struct SidebarNavigationRail: View {
    @EnvironmentObject var navigation: AppNavigation
    let snapshot: SidebarSnapshot
    let onSelect: (AppSection) -> Void
    let onKeyboardSelect: (AppSection) -> Void

    var body: some View {
        SidebarRail(
            snapshot: snapshot.selecting(navigation.section),
            onSelect: onSelect,
            onKeyboardSelect: onKeyboardSelect)
    }
}

private struct Wordmark: View {
    let worst: AttentionState?

    var body: some View {
        HStack(spacing: Theme.intraCell) {
            BrandMark(state: worst.map(DoorLightState.init) ?? .idle, size: 24)
            VStack(alignment: .leading, spacing: Theme.micro / 2) {
                Text("Trifola")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                Text("local · read-only")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
            }
        }
    }
}

private struct SidebarItem: View {
    let section: AppSection
    let isSelected: Bool
    let badge: Int?
    let selectionNamespace: Namespace.ID
    var animatesSelection = true
    var quiet = false
    let action: () -> Void
    let keyboardAction: () -> Void

    var body: some View {
        TapButton(keyboardAction: keyboardAction, action: action) {
            HStack(spacing: Theme.codePadding) {
                Image(systemName: section.icon)
                    .font(.system(size: quiet ? 15 : 16, weight: .medium))
                    .foregroundStyle(isSelected ? Theme.selectionText : Theme.muted)
                    .frame(width: 20)
                Text(section.title)
                    .font(Font.body.weight(isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Theme.selectionText : (quiet ? Theme.muted : Theme.ink))
                Spacer()
                if let badge {
                    Text("\(badge)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(isSelected ? Theme.selectionText : Theme.muted)
                        .liveNumericTransition(value: "\(badge)")
                }
            }
            .padding(.horizontal, Theme.intraCell)
            .padding(.leading, quiet ? Theme.micro : 0)
            .frame(height: quiet ? 30 : 32)
            .contentShape(Rectangle())
        }
        .accessibilityLabel(section.title)
        .accessibilityHint("Open \(section.title), \(AppCommandMap.navigation(for: section).glyph)")
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
                    .fill(Theme.selectionBG)
            }
        }
    }
}

private struct SidebarFooter: View {
    let snapshot: SidebarSnapshot

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionGap) {
            // The credit-era burn governor replaces the retired Jul-7 countdown
            // (VISION 2.5): today's API-equiv burn + the recent-run-rate month pace.
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: snapshot.scanReadingText == nil
                          ? "chart.line.uptrend.xyaxis" : "hourglass")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.muted)
                    let burnLine = snapshot.scanReadingText
                        ?? "today \(fmtUSD(snapshot.todayCost)) · ≈\(fmtUSD(snapshot.monthProjection))/mo"
                    Text(burnLine)
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                        .liveNumericTransition(value: burnLine)
                }
                Text(snapshot.scanReadingText == nil
                     ? "public API rates — not your bill"
                     : "Costs and activity appear when this pass settles")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }

            HStack(spacing: Theme.rhythm) {
                Text(snapshot.updatedText)
                if let refreshText = snapshot.refreshText {
                    ProgressView().controlSize(.mini)
                    Text(refreshText)
                }
            }
            .font(.caption)
            .foregroundStyle(Theme.muted)

            Divider()

            AccountChip(account: snapshot.account, machine: snapshot.machine)
        }
    }
}

private struct AccountChip: View {
    let account: String
    let machine: String

    var body: some View {
        HStack(spacing: Theme.intraCell) {
            Image(systemName: "person.crop.circle")
                .font(.body)
                .foregroundStyle(Theme.muted)
            VStack(alignment: .leading, spacing: 1) {
                Text(account)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(Theme.ink)
                Text(machine)
                    .font(.caption2)
                    .foregroundStyle(Theme.faint)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Theme.micro)
    }
}
