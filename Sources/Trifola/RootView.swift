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
                .frame(width: 220)
                .background(VisualEffectBackground(material: .sidebar).ignoresSafeArea())
            Divider()
                .ignoresSafeArea()
            ContentColumn()
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(VisualEffectBackground(material: .underWindowBackground).ignoresSafeArea())
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
                    .transition(.opacity)
            }
        }
        .animation(.easeOut(duration: 0.12), value: services.showPalette)
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

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Wordmark()
                .padding(.top, 48)   // clear the traffic lights
                .padding(.horizontal, Theme.gutter)

            VStack(spacing: 2) {
                ForEach(AppSection.allCases) { section in
                    SidebarItem(section: section)
                }
            }
            .padding(.horizontal, 10)
            .padding(.top, 24)

            Spacer()

            SidebarFooter()
                .padding(.horizontal, Theme.gutter)
                .padding(.bottom, 14)
        }
    }
}

private struct Wordmark: View {
    @EnvironmentObject var services: AppServices

    var body: some View {
        // The door light leads the name (POLISH II.A): the mark's fill is ink; its
        // ring takes the fleet's WORST live state — red / amber / green, faint when
        // quiet — the exact mapping the menu bar uses. A static rendering of a real
        // value (recomputed with the existing refresh), never an animation. Still at
        // the door is honest; the tint is the signal.
        let worst = services.attentionBoard(now: services.now).worst
        HStack(spacing: 9) {
            SeatMark(fill: Theme.ink, ring: (worst?.color ?? Theme.faint),
                     size: 15, ringWidth: 1.5, gapped: true)
                .help(worstHelp(worst))
            VStack(alignment: .leading, spacing: 2) {
                Text("Mission Control")
                    .font(.headline)
                    .foregroundStyle(Theme.ink)
                Text("Claude Code fleet")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
        }
    }

    private func worstHelp(_ worst: AttentionState?) -> String {
        switch worst {
        case .blocked: return "The door light — a session is blocked on you"
        case .waiting: return "The door light — a session is waiting on you"
        case .running: return "The door light — the fleet is running, nothing needs you"
        default:       return "The door light — the fleet is quiet"
        }
    }
}

private struct SidebarItem: View {
    @EnvironmentObject var services: AppServices
    let section: AppSection
    @State private var hovering = false

    private var isSelected: Bool { services.section == section }

    private var badge: Int? {
        if section == .live {
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
            HStack(spacing: 8) {
                Image(systemName: section.icon)
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(isSelected ? Theme.selectionText : Theme.muted)
                    .frame(width: 18)
                Text(section.title)
                    .font(.subheadline.weight(isSelected ? .semibold : .regular))
                    .foregroundStyle(isSelected ? Theme.selectionText : Theme.ink)
                Spacer()
                if let badge {
                    Text("\(badge)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(isSelected ? Theme.selectionText : Theme.muted)
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
        }
        .background {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
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
        VStack(alignment: .leading, spacing: Theme.rhythm) {
            // The credit-era burn governor replaces the retired Jul-7 countdown
            // (VISION 2.5): today's API-equiv burn + the recent-run-rate month pace.
            let burn = services.sessions.burnGovernor(now: services.now)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "chart.line.uptrend.xyaxis")
                        .font(.caption2)
                        .foregroundStyle(Theme.muted)
                    Text("today \(fmtUSD(burn.today.cost)) · ≈\(fmtUSD(burn.monthProjection))/mo")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }
                Text("API-equiv, not your credit bill")
                    .font(.caption2)
                    .foregroundStyle(Theme.faint)
            }

            Text("updated \(fmtAgo(services.sessions.lastRefresh))")
                .font(.caption2)
                .foregroundStyle(Theme.faint)
        }
    }
}
