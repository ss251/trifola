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
        HStack(spacing: 0) {
            Sidebar()
                .frame(width: 248)
                .background {
                    Theme.surfaceSidebar.ignoresSafeArea()
                }
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
        .frame(minWidth: 1120, minHeight: 720)
        .overlay { CommandPaletteHost() }
        .background(RootLifecycle())
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
    var body: some View {
        Color.clear
            .task {
                AppBrand.applyDockIcon()
                services.start()
            }
            .onChange(of: services.blockedCount, initial: true) { _, n in
                AppBrand.updateDockBadge(blockedCount: n)
            }
    }
}

// MARK: - Content switch

private struct ContentColumn: View {
    @EnvironmentObject var services: AppServices

    var body: some View {
        ZStack {
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
        .id(services.section)
        .transition(.opacity)
        .animation(.easeOut(duration: 0.18), value: services.section)
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

    private let v1Sections: [AppSection] = [
        .overview, .fleet, .sessions, .spend, .audit, .stack,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Wordmark(worst: snapshot.worstState)
                .padding(.horizontal, Theme.gutter)
                .padding(.top, Theme.codePadding)
                .frame(height: ScreenScaffoldMetrics.headerHeight, alignment: .top)
                .padding(.top, ScreenScaffoldMetrics.topInset)

            Divider()

            VStack(spacing: 2) {
                ForEach(v1Sections) { section in
                    SidebarItem(section: section,
                                isSelected: snapshot.selected == section,
                                badge: snapshot.badge(for: section)) {
                        onSelect(section)
                    }
                }
            }
            .padding(.horizontal, Theme.intraCell)
            .padding(.top, Theme.blockGap)

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
            machine: Host.current().localizedName ?? "this Mac")) { section in
                services.section = section
                if section != .sessions { services.selectedSessionID = nil }
        }
    }
}

private struct Wordmark: View {
    let worst: AttentionState?

    var body: some View {
        HStack(spacing: Theme.intraCell) {
            SeatMark(state: worst.map(DoorLightState.init) ?? .idle,
                     fill: Theme.ink,
                     ring: worst?.color ?? Theme.ink.opacity(0.35),
                     size: 10,
                     coreUsesState: false)
            VStack(alignment: .leading, spacing: Theme.micro / 2) {
                Text("Trifola")
                    .font(.body.weight(.semibold))
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
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        TapButton(shortcut: KeyboardShortcut(section.shortcut, modifiers: .command), action: action) {
            HStack(spacing: Theme.codePadding) {
                Image(systemName: section.icon)
                    .font(.system(size: 16, weight: .medium))
                    .foregroundStyle(isSelected ? Theme.selectionText : Theme.muted)
                    .frame(width: 20)
                Text(section.title)
                    .font(.body.weight(isSelected ? .semibold : .medium))
                    .foregroundStyle(isSelected ? Theme.selectionText : Theme.ink)
                Spacer()
                if let badge {
                    Text("\(badge)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(isSelected ? Theme.selectionText : Theme.muted)
                }
            }
            .padding(.horizontal, Theme.intraCell)
            .frame(height: 32)
            .contentShape(Rectangle())
        }
        .background {
            RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
                .fill(isSelected
                      ? Theme.selectionBG
                      : hovering
                        ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor).opacity(0.6)
                        : .clear)
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
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
                    Text("today \(fmtUSD(snapshot.todayCost)) · ≈\(fmtUSD(snapshot.monthProjection))/mo")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                }
                Text("public API rates — not your bill")
                    .font(.caption)
                    .foregroundStyle(Theme.faint)
            }

            HStack(spacing: Theme.rhythm) {
                Text(snapshot.updatedText)
                if let refreshText = snapshot.refreshText {
                    ProgressView().controlSize(.mini)
                    Text(refreshText)
                }
            }
            .font(.caption)
            .foregroundStyle(Theme.faint)

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
        .padding(.horizontal, Theme.codePadding)
        .padding(.vertical, Theme.intraCell)
        .background {
            RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
                .fill(Theme.cardFill)
            RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 1)
        }
    }
}
