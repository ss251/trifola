import SwiftUI
import AppKit
import TrifolaKit

struct RootView: View {
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
                        VisualEffectBackground(material: .underWindowBackground).opacity(0.16).ignoresSafeArea()
                    }
            }
            .background(WindowConfigurator())
            .frame(minWidth: Theme.Layout.minimumWindowWidth,
                   minHeight: Theme.Layout.minimumWindowHeight)
            .overlay { CommandPaletteHost() }
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
    @EnvironmentObject var services: AppServices

    var body: some View {
        ZStack {
            sectionView
                .onAppear { services.navigationDidAppear(services.section) }
                .id(services.section)
                .sectionTransition(enabled: services.navigationOrigin == .pointer)
                .sectionFirstAppearance(services.firstAppearanceSection == services.section)
        }
    }

    @ViewBuilder private var sectionView: some View {
        switch services.section {
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
    let selected: AppSection
    let worstState: AttentionState?
    let liveCount: Int
    let pendingLessonCount: Int
    let todayCost: Double
    let monthProjection: Double
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

    var body: some View {
        let burn = services.sessions.burnGovernor(now: services.now)
        let progress = services.sessions.scanProgress
        let refreshText: String? = {
            guard services.sessions.scanPresentation == .liveRefreshing,
                  progress.isInProgress else { return nil }
            guard progress.totalEstimate > 0 else { return "refreshing" }
            return "refreshing \(fmtGrouped(progress.scanned))/~\(fmtGrouped(progress.totalEstimate))"
        }()
        return SidebarRail(snapshot: SidebarSnapshot(
            selected: services.section,
            worstState: services.attentionBoard(now: services.now).worst,
            liveCount: services.sessions.activeSessions.count,
            pendingLessonCount: services.pendingLessonCount,
            todayCost: burn.today.cost,
            monthProjection: burn.monthProjection,
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
                    .fill(Theme.selectionBG)
                    .sidebarSelectionTravel(in: selectionNamespace)
            }
        }
        .animation(animatesSelection && !reduceMotion ? Theme.Motion.nav : nil,
                   value: isSelected)
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
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.muted)
                    let burnLine = "today \(fmtUSD(snapshot.todayCost)) · ≈\(fmtUSD(snapshot.monthProjection))/mo"
                    Text(burnLine)
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                        .liveNumericTransition(value: burnLine)
                }
                Text("public API rates — not your bill")
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
