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
                    VisualEffectBackground(material: .sidebar).opacity(0.30).ignoresSafeArea()
                }
            Divider()
                .padding(.top, Theme.blockGap)
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
                NSApp.dockTile.badgeLabel = n > 0 ? "\(n)" : nil
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

private struct Sidebar: View {
    @EnvironmentObject var services: AppServices

    private let v1Sections: [AppSection] = [
        .overview, .fleet, .sessions, .spend, .audit, .stack,
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Wordmark()
                .padding(.horizontal, Theme.gutter)
                // The rail header uses body-scale semibold, so this optical offset
                // aligns its baseline with the 28pt title in the shared header row.
                .padding(.top, Theme.codePadding)
                .frame(height: ScreenScaffoldMetrics.headerHeight, alignment: .top)
                .padding(.top, ScreenScaffoldMetrics.topInset)

            Divider()

            VStack(spacing: 2) {
                ForEach(v1Sections) { section in
                    SidebarItem(section: section)
                }
            }
            .padding(.horizontal, Theme.intraCell)
            .padding(.top, Theme.blockGap)

            Spacer()

            SidebarFooter()
                .padding(.horizontal, Theme.gutter)
                .padding(.bottom, Theme.cardPadding)
        }
    }
}

private struct Wordmark: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Theme.micro / 2) {
            Text("Fleet console")
                .font(.body.weight(.semibold))
                .foregroundStyle(Theme.ink)
            Text("local · read-only")
                .font(.footnote)
                .foregroundStyle(Theme.muted)
        }
    }
}

private struct SidebarItem: View {
    @EnvironmentObject var services: AppServices
    let section: AppSection
    @State private var hovering = false

    private var isSelected: Bool { services.section == section }

    private var badge: Int? {
        if section == .fleet {
            let n = services.sessions.activeSessions.count
            return n > 0 ? n : nil
        }
        // The Ledger's pending-lesson count — the ONLY signal it emits (docs §5:
        // no nags, no dock badge; a count in the sidebar item is the entire signal).
        if section == .ledger {
            let n = services.pendingLessonCount
            return n > 0 ? n : nil
        }
        return nil
    }

    var body: some View {
        TapButton(shortcut: KeyboardShortcut(section.shortcut, modifiers: .command), action: {
            services.section = section
            if section != .sessions { services.selectedSessionID = nil }
        }) {
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
    @EnvironmentObject var services: AppServices

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionGap) {
            // The credit-era burn governor replaces the retired Jul-7 countdown
            // (VISION 2.5): today's API-equiv burn + the recent-run-rate month pace.
            let burn = services.sessions.burnGovernor(now: services.now)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.muted)
                    Text("today \(fmtUSD(burn.today.cost)) · ≈\(fmtUSD(burn.monthProjection))/mo")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                }
                Text("public API rates — not your bill")
                    .font(.caption)
                    .foregroundStyle(Theme.faint)
            }

            HStack(spacing: Theme.rhythm) {
                Text("updated \(fmtAgo(services.sessions.lastRefresh))")
                if services.sessions.scanPresentation == .liveRefreshing,
                   services.sessions.scanProgress.isInProgress {
                    ProgressView().controlSize(.mini)
                    Text(inlineRefreshLabel)
                }
            }
            .font(.caption)
            .foregroundStyle(Theme.faint)

            Divider()

            AppLockup(size: 16, ring: services.alertingAttentionBoard(now: services.now).worst?.color ?? Theme.faint)
        }
    }

    private var inlineRefreshLabel: String {
        let progress = services.sessions.scanProgress
        guard progress.totalEstimate > 0 else { return "refreshing" }
        return "refreshing \(fmtGrouped(progress.scanned))/~\(fmtGrouped(progress.totalEstimate))"
    }
}
