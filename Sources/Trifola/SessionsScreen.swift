import SwiftUI
import TrifolaKit

/// The fleet browser: search + tier/state filters + sortable session list on
/// the left, live inspector on the right.
struct SessionsScreen: View {
    @EnvironmentObject var services: AppServices

    enum SortKey: String, CaseIterable, Identifiable {
        case recent = "Recent", cost = "Cost", context = "Context", tokens = "Tokens"
        var id: String { rawValue }
    }

    @AppStorage(AppRestorationKeys.sessionsQuery) private var query = ""
    @AppStorage(AppRestorationKeys.sessionsTier) private var tierFilterRaw = ""
    @AppStorage(AppRestorationKeys.sessionsMachine) private var machineFilterRaw = ""
    @AppStorage(AppRestorationKeys.sessionsActiveOnly) private var activeOnly = false
    @AppStorage(AppRestorationKeys.sessionsHeavyOnly) private var heavyOnly = false
    @AppStorage(AppRestorationKeys.sessionsSort) private var sortRaw = SortKey.recent.rawValue

    private var tierFilter: ModelTier? { ModelTier(rawValue: tierFilterRaw) }
    private var machineFilter: String? { machineFilterRaw.isEmpty ? nil : machineFilterRaw }
    private var sort: SortKey { SortKey(rawValue: sortRaw) ?? .recent }

    private var filtered: [SessionSummary] {
        var out = services.sessions.sessions
        if let tierFilter { out = out.filter { $0.tier == tierFilter } }
        if let machineFilter { out = out.filter { $0.machineID == machineFilter } }
        if activeOnly { out = out.filter(\.isActive) }
        if heavyOnly { out = out.filter(\.isContextHeavy) }
        if !query.isEmpty {
            let q = query.lowercased()
            out = out.filter {
                $0.project.lowercased().contains(q)
                    || $0.displayTitle.lowercased().contains(q)
                    || $0.cwd.lowercased().contains(q)
                    || $0.id.lowercased().hasPrefix(q)
            }
        }
        // Deterministic ties (W6 wave 4): Swift's sort is not stable — without a
        // tiebreaker, equal-valued rows can swap places on every recompute (each
        // heartbeat tick), which reads as rows flapping for no reason.
        switch sort {
        case .recent: out.sort { ($0.lastActivity ?? .distantPast, $1.id) > ($1.lastActivity ?? .distantPast, $0.id) }
        case .cost:
            // Decorate-sort-undecorate over INDICES: the comparator must not
            // recompute `cost` O(n log n) times (measured ~290ms of main-thread
            // stall per body pass over 5.3k sessions), and it must not move the
            // heavy SessionSummary structs through every swap either — sort the
            // (cost, id, index) keys, then reorder once.
            let keys = out.enumerated()
                .map { (i: $0.offset, c: $0.element.cost, id: $0.element.id) }
                .sorted { ($0.c, $1.id) > ($1.c, $0.id) }
            out = keys.map { out[$0.i] }
        case .context: out.sort { ($0.contextWeight, $1.id) > ($1.contextWeight, $0.id) }
        case .tokens: out.sort { ($0.usage.total, $1.id) > ($1.usage.total, $0.id) }
        }
        return out
    }

    var body: some View {
        HStack(spacing: 0) {
            listColumn
                .frame(width: 430)
                .sectionRevealBlock(index: 0)
            Divider()
            inspector
                .frame(maxWidth: .infinity)
                .launchReveal(.content)
                .sectionRevealBlock(index: 1)
        }
        .centeredContentColumn()
        .reorderMotion(value: services.selectedSessionID)
    }

    // MARK: List column

    private var listColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.blockGap) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sessions")
                        .font(.system(size: 28, weight: .bold))
                        .tracking(-0.4)
                        .foregroundStyle(Theme.ink)
                    Text("Find a session by project or task · dollar values are API-rate estimates, not your bill")
                        .font(.subheadline)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(2)
                }
                .frame(minHeight: ScreenScaffoldMetrics.headerHeight, alignment: .top)
                .padding(.top, ScreenScaffoldMetrics.topInset)
                .padding(.horizontal, Theme.gutter)
                .launchReveal(.header)

                Divider()
                    .launchReveal(.header)

                VStack(alignment: .leading, spacing: Theme.sectionGap) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(.footnote.weight(.medium))
                            .foregroundStyle(Theme.muted)
                        TextField("Search project, task, path or id…", text: $query)
                            .textFieldStyle(.plain)
                            .font(.subheadline)
                            .foregroundStyle(Theme.ink)
                    }
                    .padding(.horizontal, Theme.intraCell)
                    .padding(.vertical, Theme.rhythm)
                    .background {
                        RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
                            .fill(Theme.codeFill)
                        RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
                            .strokeBorder(Theme.cardStroke, lineWidth: 1)
                    }

                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            FilterChip(label: "Active", isOn: activeOnly) {
                                activeOnly.toggle()
                            }
                            FilterChip(label: "Heavy context", isOn: heavyOnly) {
                                heavyOnly.toggle()
                            }
                            // Machine filter — only when the fleet spans more than one
                            // machine, so single-machine users see zero cross-machine chrome.
                            if services.isCrossMachine {
                                ForEach(services.sessions.fleetMachines) { m in
                                    FilterChip(label: m.chipLabel, isOn: machineFilter == m.id) {
                                        machineFilterRaw = machineFilter == m.id ? "" : m.id
                                    }
                                }
                            }
                            ForEach(ModelTier.allCases.filter { $0 != .other }, id: \.self) { tier in
                                FilterChip(label: tier.label, isOn: tierFilter == tier) {
                                    tierFilterRaw = tierFilter == tier ? "" : tier.rawValue
                                }
                            }
                        }
                    }
                    .scrollIndicators(.never)

                    HStack {
                        Text("\(filtered.count) shown")
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                        Spacer()
                        Picker("Sort sessions", selection: Binding(
                            get: { sort },
                            set: { sortRaw = $0.rawValue }
                        )) {
                            ForEach(SortKey.allCases) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.menu)
                        .controlSize(.small)
                        .fixedSize()
                    }
                }
                .padding(.horizontal, Theme.gutter)
                .launchReveal(.content)
            }
            .padding(.bottom, Theme.intraCell)

            Divider()

            ScrollViewReader { proxy in
                let shown = Array(filtered.prefix(400))
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(shown) { s in
                            SessionRow(session: s, isSelected: services.selectedSessionID == s.id)
                                .id(s.id)
                                .motionRowTransition()
                        }
                        if filtered.count > 400 {
                            Text("Showing first 400 — refine the search to narrow down.")
                                .font(.caption)
                                .foregroundStyle(Theme.muted)
                                .padding(.vertical, Theme.codePadding)
                        }
                    }
                    .padding(.horizontal, Theme.codePadding)
                    .padding(.top, Theme.intraCell)
                    .padding(.bottom, Theme.blockGap)
                    // The one app-standard reorder motion (W6 wave 4): when a rank
                    // genuinely changes, the row glides — never teleports. Keyed on
                    // the id order so in-place value updates animate nothing.
                    .reorderMotion(value: shown.map(\.id))
                }
                .scrollIndicators(.never)
                .onAppear {
                    if let id = services.selectedSessionID {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
                .onChange(of: services.terminalTranscriptReveal?.generation) {
                    guard let request = services.terminalTranscriptReveal else { return }
                    proxy.scrollTo(request.sessionID, anchor: .center)
                }
            }
            .launchReveal(.content)
        }
        .onChange(of: services.sessions.scanProgress.isInProgress, initial: true) { _, _ in
            clearStaleRestorationIfIndexReady()
        }
    }

    private func clearStaleRestorationIfIndexReady() {
        guard services.sessions.scanPresentation == .liveRefreshing,
              !services.sessions.scanProgress.isInProgress else { return }
        if !tierFilterRaw.isEmpty, ModelTier(rawValue: tierFilterRaw) == nil {
            tierFilterRaw = ""
        }
        if SortKey(rawValue: sortRaw) == nil { sortRaw = SortKey.recent.rawValue }
        if !machineFilterRaw.isEmpty,
           !services.sessions.fleetMachines.contains(where: { $0.id == machineFilterRaw }) {
            machineFilterRaw = ""
        }
    }

    // MARK: Inspector

    @ViewBuilder
    private var inspector: some View {
        if let session = services.selectedSession {
            SessionInspector(session: session)
                .id(session.id)
                .motionRowTransition()
        } else {
            EmptyState(
                icon: "square.stack.3d.up",
                title: "Pick a session",
                detail: "Select any session on the left to see its live transcript, token economics and hand-off controls.")
                .motionRowTransition()
        }
    }
}

// MARK: - Row
// Selection uses the system selection background and the text flips to the
// selection text color — the exact CodexBar highlight cascade.

private struct SessionRow: View {
    @EnvironmentObject var services: AppServices
    let session: SessionSummary
    let isSelected: Bool

    private var primary: Color { isSelected ? Theme.selectionText : Theme.ink }
    private var secondary: Color { isSelected ? Theme.selectionText.opacity(0.8) : Theme.muted }
    private var suppressed: Bool {
        services.agency.reason(for: session, now: services.now) != nil
    }
    private var attentionState: AttentionState? {
        services.attentionBoard(now: services.now).items.first(where: { $0.id == session.id })?.state
    }

    var body: some View {
        HoverRow {
            services.selectedSessionID = session.id
        } content: {
            HStack(spacing: 8) {
                // The door light (UI_GRIND §2.1): state fill + 1pt tier ring —
                // never a tier-colored disc (which read as an alarm in the app's
                // own dot language). Stays lit through selection, like the palette.
                SeatMark(state: DoorLightState(attentionState
                         ?? (session.isActive ? .running : .idle)), size: 8)
                if suppressed { SuppressionMark() }
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text("\(session.project) · \(session.displayTitle)")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(primary)
                            .lineLimit(1)
                        if services.isCrossMachine {
                            MachineChip(machineID: session.machineID)
                        }
                    }
                    (Text(session.shortID)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(secondary.opacity(0.8))
                     + Text(" · \(fmtAgo(session.lastActivity)) · \(session.tier.label) · \(session.messageCount) messages · \(fmtUSD(session.cost)) API estimate")
                        .font(.caption2)
                        .foregroundStyle(secondary)
                     + Text(session.isContextHeavy ? " · \(fmtTokens(session.contextWeight)) context tokens / message" : "")
                        .font(.caption2)
                        .foregroundStyle(secondary))
                    .lineLimit(1)
                }
                Spacer(minLength: 8)
                if let attentionState, attentionState.needsAttention {
                    AttentionStatusPill(state: attentionState)
                }
            }
            .padding(.horizontal, Theme.intraCell)
            .frame(minHeight: Theme.sessionRowHeight)
        }
        .opacity(suppressed ? 0.45 : 1)
        .help("Session \(session.id)")
        .contextMenu { SessionAgencyMenu(session: session) }
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
                    .fill(Theme.selectionBG)
            }
        }
    }
}

// MARK: - Inspector detail

private struct SessionInspector: View {
    @EnvironmentObject var services: AppServices
    @Environment(\.openWindow) private var openWindow
    let session: SessionSummary

    var body: some View {
        let openAction = services.sessionOpenAction(for: session)
        VStack(alignment: .leading, spacing: Theme.cardPadding) {
            // header
            VStack(alignment: .leading, spacing: Theme.rhythm) {
                HStack(spacing: 8) {
                    // The door light has an idle rendering (faint fill) — absence
                    // was a third, unsanctioned state (UI_GRIND CLB-3).
                    SeatMark(state: DoorLightState(attentionStateForInspector), size: 8)
                    Text("\(session.project) · \(session.displayTitle)")
                        .font(.system(size: 28, weight: .bold))
                        .tracking(-0.4)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    TierBadge(tier: session.tier)
                    if session.isRemote {
                        MachineChip(machineID: session.machineID)
                    }
                    Spacer()
                    TapButton(
                        shortcut: KeyboardShortcut(.return, modifiers: .command),
                        action: {
                            let presentMain: @MainActor () -> Void = { openWindow(id: "main") }
                            if session.isRemote {
                                services.showTranscript(
                                    session,
                                    message: "Remote session — showing transcript",
                                    openMainWindow: presentMain
                                )
                            } else {
                                services.openTerminal(session, openMainWindow: presentMain)
                            }
                        }) {
                            HStack(spacing: Theme.rhythm) {
                                Image(systemName: openAction.icon)
                                    .font(.caption.weight(.medium))
                                Text(openAction.label)
                                    .font(.caption.weight(.medium))
                            }
                            .foregroundStyle(Theme.ink)
                            .padding(.horizontal, Theme.intraCell)
                            .padding(.vertical, Theme.micro)
                            .background(Theme.cardFill,
                                        in: RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous))
                        }
                        .accessibilityLabel(openAction.label)
                        .accessibilityHint(openAction.help)
                        .help("\(openAction.help) — ⌘↩")
                }
                Text(session.id)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Theme.faint)
                Text(session.cwd.isEmpty ? "no working directory recorded" : session.cwd)
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
                SessionActions(session: session)
            }
            .padding(.top, ScreenScaffoldMetrics.topInset)
            .frame(minHeight: ScreenScaffoldMetrics.topInset + ScreenScaffoldMetrics.headerHeight,
                   alignment: .top)

            Divider()

            // economics strip
            StatRow {
                InspectorStat(label: "API-rate estimate", value: fmtUSD(session.cost))
                Divider()
                InspectorStat(label: "Messages", value: "\(session.messageCount)")
                Divider()
                InspectorStat(label: "Total tokens", value: fmtTokens(session.usage.total))
                Divider()
                InspectorStat(label: "Cache hit", value: fmtPct(session.usage.cacheHitRate))
                Divider()
                InspectorStat(label: "Context tokens / message", value: fmtTokens(session.contextWeight))
            }
            Text("Estimated from public API rates for recorded usage — not your bill or subscription charge.")
                .font(.caption2)
                .foregroundStyle(Theme.muted)

            // CONTEXT-TAX GAUGE (spree #1): what the next message re-sends,
            // priced warm/cold at this session's own model rates. The advisor
            // line rides inside the gauge — live + over-threshold only.
            if session.contextWeight > 0 {
                ContextTaxGaugeView(gauge: ContextTax.gauge(session))
            }

            // REROUTE RECEIPTS (spree #2): mid-session model flips with the
            // /model switches honestly excluded. Clean sessions render nothing.
            if let rerouteReceipt = Reroutes.receipt(for: session) {
                RerouteReceiptView(receipt: rerouteReceipt)
            }

            Divider()

            SectionLabel("Live transcript")
            TranscriptView(filePath: session.filePath)
                .id("\(session.id):\(transcriptRevealGeneration)")
                .frame(maxHeight: .infinity)
                .overlay {
                    if transcriptRevealGeneration > 0 {
                        RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                            .strokeBorder(Theme.amber.opacity(0.9), lineWidth: 2)
                            .allowsHitTesting(false)
                    }
                }
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.bottom, Theme.paneInset)
        .overlay(alignment: .top) {
            if let request = services.terminalTranscriptReveal,
               request.sessionID == session.id {
                Toast(text: request.message)
                    .id(request.generation)
                    .padding(.top, Theme.sectionGap)
                    .allowsHitTesting(false)
            }
        }
        .motion(Theme.Motion.move, value: services.terminalTranscriptReveal?.generation)
        .task(id: session.id) {
            services.prepareSessionOpenAction(for: session)
        }
        .onChange(of: services.sessions.lastRefresh) { _, _ in
            services.prepareSessionOpenAction(for: session)
        }
    }

    private var transcriptRevealGeneration: Int {
        guard let request = services.terminalTranscriptReveal,
              request.sessionID == session.id else { return 0 }
        return request.generation
    }

    private var attentionStateForInspector: AttentionState {
        services.attentionBoard(now: services.now).items
            .first(where: { $0.id == session.id })?.state
            ?? (session.isActive ? .running : .idle)
    }
}

private struct InspectorStat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.muted)
            Text(value)
                .font(.headline)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
