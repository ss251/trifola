import SwiftUI
import TrifolaKit

private struct SessionRecencyKey {
    let index: Int
    let date: Date
    let id: String
}

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
    @AppStorage(AppRestorationKeys.sessionsTopLevelOnly)
    private var topLevelOnly = SessionBrowserFilter.defaultTopLevelOnly
    @AppStorage(AppRestorationKeys.sessionsLiveInTerminalOnly)
    private var liveInTerminalOnly = SessionBrowserFilter.defaultLiveInTerminalOnly
    @AppStorage(AppRestorationKeys.sessionsSort) private var sortRaw = SortKey.recent.rawValue

    private var tierFilter: ModelTier? { ModelTier(rawValue: tierFilterRaw) }
    private var machineFilter: String? { machineFilterRaw.isEmpty ? nil : machineFilterRaw }
    private var sort: SortKey { SortKey(rawValue: sortRaw) ?? .recent }

    private func makeFilteredSessions() -> [SessionSummary] {
        var out = SessionBrowserFilter(
            topLevelOnly: topLevelOnly,
            liveInTerminalOnly: liveInTerminalOnly
        ).apply(
            to: services.sessions.sessions,
            liveTerminalSessionIDs: services.liveTerminalSessionIDs
        )
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
        case .recent:
            let keys: [SessionRecencyKey] = out.enumerated()
                .map { pair in
                    SessionRecencyKey(index: pair.offset,
                                      date: pair.element.lastActivity ?? .distantPast,
                                      id: pair.element.id)
                }
                .sorted {
                    $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date
                }
            out = keys.map { out[$0.index] }
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
        let filtered = Perf.span("main:nav.sessionsProjection") {
            makeFilteredSessions()
        }
        HStack(spacing: 0) {
            listColumn(filtered: filtered)
                .frame(width: 440)
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

    private func listColumn(filtered: [SessionSummary]) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.blockGap) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sessions")
                        .font(Theme.Typography.screenTitle)
                        .tracking(-0.55)
                        .foregroundStyle(Theme.ink)
                    Text("Search projects and task handles · costs are API-rate estimates, not bills")
                        .font(Theme.Typography.body)
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
                            .font(Theme.Typography.metadataMedium)
                            .foregroundStyle(Theme.muted)
                        TextField("Search project, task, path or id…", text: $query)
                            .textFieldStyle(.plain)
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.ink)
                    }
                    .padding(.horizontal, Theme.intraCell)
                    .padding(.vertical, Theme.rhythm)
                    .background {
                        RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
                            .fill(Theme.codeFill)
                        RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
                            .strokeBorder(Theme.cardStroke, lineWidth: Theme.hairlineWidth)
                    }

                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            FilterChip(label: "Top-level", isOn: topLevelOnly) {
                                topLevelOnly.toggle()
                            }
                            FilterChip(label: "Live in terminal", isOn: liveInTerminalOnly) {
                                liveInTerminalOnly.toggle()
                            }
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
                        Text("\(filtered.count) session\(filtered.count == 1 ? "" : "s")")
                            .font(Theme.Typography.metadata)
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
                    .help(liveInTerminalOnly && services.liveTerminalSnapshotFailure != nil
                        ? "Live terminal registry unavailable; no sessions can be verified"
                        : "Count after every selected filter")
                }
                .padding(.horizontal, Theme.gutter)
                .launchReveal(.content)
            }
            .padding(.bottom, Theme.intraCell)

            Divider()

            SessionListColumns()
                .padding(.horizontal, Theme.codePadding + Theme.intraCell)
                .padding(.vertical, Theme.micro)

            Divider()

            ScrollViewReader { proxy in
                let shown = Array(filtered.prefix(400))
                ScrollView {
                    LazyVStack(spacing: Theme.micro / 2) {
                        ForEach(shown) { s in
                            SessionRow(session: s, isSelected: services.selectedSessionID == s.id)
                                .id(s.id)
                                .motionRowTransition()
                        }
                        if filtered.count > 400 {
                            Text("Showing first 400 — refine the search to narrow down.")
                                .font(Theme.Typography.metadata)
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

// MARK: - Session table

/// Fixed columns turn the browser into an instrument panel: identity gets every
/// spare point while the comparable facts never drift as titles change length.
private enum SessionListMetrics {
    static let markWidth = Theme.iconGutter
    static let ageWidth = Theme.microColWidth
    static let costWidth = Theme.subValueColWidth
    static let stateWidth = Theme.valueColWidth
}

private struct SessionListColumns: View {
    var body: some View {
        HStack(spacing: Theme.intraCell) {
            Color.clear.frame(width: SessionListMetrics.markWidth, height: 1)
            Eyebrow("Project / handle")
                .frame(maxWidth: .infinity, alignment: .leading)
            Eyebrow("Age")
                .frame(width: SessionListMetrics.ageWidth, alignment: .trailing)
            Eyebrow("Cost")
                .frame(width: SessionListMetrics.costWidth, alignment: .trailing)
            Eyebrow("State")
                .frame(width: SessionListMetrics.stateWidth, alignment: .trailing)
        }
    }
}

// Selection uses the app's native luminance step. Hover, press and keyboard
// focus continue to come from HoverRow/TapButton, so all input paths share the
// same feedback grammar and remain immune to the macOS render storm.

private struct SessionRow: View {
    @EnvironmentObject var services: AppServices
    let session: SessionSummary
    let isSelected: Bool
    var stateOverride: AttentionState? = nil
    var suppressedOverride: Bool? = nil

    private var primary: Color { isSelected ? Theme.selectionText : Theme.ink }
    private var secondary: Color { isSelected ? Theme.selectionText.opacity(0.8) : Theme.muted }

    var body: some View {
        let suppressed = suppressedOverride
            ?? (services.agency.reason(for: session, now: services.now) != nil)
        let state = stateOverride
            ?? services.attentionBoard(now: services.now).items
                .first(where: { $0.id == session.id })?.state
            ?? (session.isActive ? AttentionState.running : .idle)

        HoverRow {
            services.selectedSessionID = session.id
        } content: {
            HStack(spacing: Theme.intraCell) {
                VStack(spacing: Theme.micro / 2) {
                    SeatMark(state: DoorLightState(state), size: 8)
                    if suppressed { SuppressionMark() }
                }
                .frame(width: SessionListMetrics.markWidth)

                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(session.project)
                            .font(Theme.Typography.bodyMedium)
                            .foregroundStyle(primary)
                            .lineLimit(1)
                            .layoutPriority(1)
                        if services.isCrossMachine {
                            MachineChip(machineID: session.machineID)
                        }
                    }
                    identitySubtitle
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(session.lastActivity.map {
                    fmtAgeShort(max(0, services.now.timeIntervalSince($0)))
                } ?? "—")
                    .font(Theme.Typography.metadata)
                    .monospacedDigit()
                    .foregroundStyle(secondary)
                    .frame(width: SessionListMetrics.ageWidth, alignment: .trailing)

                Text(fmtUSD(session.cost))
                    .font(Theme.Typography.metadataMedium)
                    .monospacedDigit()
                    .foregroundStyle(primary)
                    .frame(width: SessionListMetrics.costWidth, alignment: .trailing)

                stateCell(state)
                    .frame(width: SessionListMetrics.stateWidth, alignment: .trailing)
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

    private var identitySubtitle: Text {
        (Text(session.displayTitle)
            .font(Theme.Typography.body)
            .foregroundStyle(secondary)
        + Text("  ·  \(session.tier.label)  ·  ")
            .font(Theme.Typography.metadata)
            .foregroundStyle(secondary.opacity(0.8))
        + Text(session.shortID)
            .font(Theme.Typography.mono)
            .foregroundStyle(secondary.opacity(0.7)))
    }

    @ViewBuilder
    private func stateCell(_ state: AttentionState) -> some View {
        if state.needsAttention {
            AttentionStatusPill(state: state)
        } else {
            Text(state == .running ? "Running" : "Idle")
                .font(Theme.Typography.metadataMedium)
                .foregroundStyle(secondary)
        }
    }
}

// MARK: - Inspector detail

private struct SessionInspector: View {
    @EnvironmentObject var services: AppServices
    @Environment(\.openWindow) private var openWindow
    let session: SessionSummary
    var stateOverride: AttentionState? = nil
    var transcriptPreview: AnyView? = nil
    @State private var diagnosticsExpanded = false

    var body: some View {
        let rerouteReceipt = Reroutes.receipt(for: session)

        VStack(alignment: .leading, spacing: 0) {
            identityHeader
            Divider()
            primaryFacts
            Divider()

            diagnostics(receipt: rerouteReceipt)
                .padding(.vertical, Theme.sectionGap)

            HStack(alignment: .firstTextBaseline) {
                SectionLabel("Live transcript")
                Spacer()
                Text("read-only · follows the latest event")
                    .font(Theme.Typography.metadata)
                    .foregroundStyle(Theme.faint)
            }
            .padding(.bottom, Theme.intraCell)

            transcript
                .id("\(session.id):\(transcriptRevealGeneration)")
                .frame(maxHeight: .infinity)
                .layoutPriority(1)
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
    }

    // MARK: Identity

    private var identityHeader: some View {
        let state = attentionStateForInspector

        return VStack(alignment: .leading, spacing: Theme.rhythm) {
            HStack(spacing: Theme.intraCell) {
                SeatMark(state: DoorLightState(state), size: 8)
                Text(state.label.capitalized)
                    .font(Theme.Typography.metadataMedium)
                    .foregroundStyle(state.color)
                TierBadge(tier: session.tier)
                if session.isRemote {
                    MachineChip(machineID: session.machineID)
                }
                Spacer(minLength: 0)
            }

            Text(session.project)
                .font(Theme.Typography.screenTitle)
                .tracking(-0.55)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)

            Text(session.displayTitle)
                .font(Theme.Typography.section)
                .foregroundStyle(Theme.muted)
                .lineLimit(2)

            Text(session.id)
                .font(Theme.Typography.mono)
                .foregroundStyle(Theme.faint)
                .lineLimit(1)
                .textSelection(.enabled)

            HStack(spacing: Theme.rhythm) {
                Image(systemName: "folder")
                    .font(Theme.Typography.metadataMedium)
                    .foregroundStyle(Theme.faint)
                Text(session.cwd.isEmpty ? "no working directory recorded" : session.cwd)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
            }

            HStack(spacing: Theme.intraCell) {
                SessionActions(session: session)
                Spacer(minLength: Theme.intraCell)
                openSessionButton
            }
        }
        .padding(.top, ScreenScaffoldMetrics.topInset)
        .padding(.bottom, Theme.cardPadding)
    }

    private var openSessionButton: some View {
        let openAction = services.sessionOpenAction(for: session)

        return TapButton(
            shortcut: KeyboardShortcut(.return, modifiers: .command),
            action: {
                let presentMain: @MainActor () -> Void = {
                    MainWindowPresenter.present {
                        openWindow(id: "main")
                    }
                }
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
                        .font(Theme.Typography.metadataMedium)
                    Text(openAction.label)
                        .font(Theme.Typography.metadataMedium)
                }
                .foregroundStyle(Theme.ink)
                .padding(.horizontal, Theme.controlHorizontalInset)
                .padding(.vertical, Theme.compactControlVerticalInset)
                .background {
                    RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
                        .fill(Theme.cardFill)
                    RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
                        .strokeBorder(Theme.cardStroke, lineWidth: Theme.hairlineWidth)
                }
            }
            .accessibilityLabel(openAction.label)
            .accessibilityHint(openAction.help)
            .help("\(openAction.help) — ⌘↩")
            .disabled(openAction == .resolving)
    }

    // MARK: Primary facts

    private var primaryFacts: some View {
        VStack(alignment: .leading, spacing: Theme.rhythm) {
            HStack(alignment: .top, spacing: Theme.sectionGap) {
                InspectorFact(label: "API estimate", value: fmtUSD(session.cost))
                Divider().frame(height: Theme.compactRowHeight)
                InspectorFact(label: "Messages", value: "\(session.messageCount)")
                Divider().frame(height: Theme.compactRowHeight)
                InspectorFact(label: "Total tokens", value: fmtTokens(session.usage.total))
            }
            Text("Public API rates applied to recorded usage · not your bill or subscription charge.")
                .font(Theme.Typography.metadata)
                .foregroundStyle(Theme.faint)
        }
        .padding(.vertical, Theme.codePadding)
    }

    // MARK: Secondary evidence

    private func diagnostics(receipt: RerouteReceipt?) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            TapButton(action: { diagnosticsExpanded.toggle() }) {
                HStack(spacing: Theme.intraCell) {
                    Image(systemName: "chevron.right")
                        .font(Theme.Typography.metadataMedium)
                        .foregroundStyle(Theme.faint)
                        .disclosureChevron(isExpanded: diagnosticsExpanded)
                    Text("Usage diagnostics")
                        .font(Theme.Typography.bodyMedium)
                        .foregroundStyle(Theme.ink)
                    Spacer(minLength: Theme.intraCell)
                    Text(diagnosticsSummary(receipt))
                        .font(Theme.Typography.metadata)
                        .monospacedDigit()
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
                .padding(.horizontal, Theme.codePadding)
                .padding(.vertical, Theme.intraCell)
            }
            .accessibilityLabel("Usage diagnostics")
            .accessibilityValue(diagnosticsExpanded ? "Expanded" : "Collapsed")
            .accessibilityHint(diagnosticsExpanded
                ? "Hide cache, context tax, and reroute evidence"
                : "Show cache, context tax, and reroute evidence")

            if diagnosticsExpanded {
                Divider()
                    .padding(.horizontal, Theme.codePadding)

                VStack(alignment: .leading, spacing: Theme.sectionGap) {
                    HStack(alignment: .top, spacing: Theme.sectionGap) {
                        InspectorSecondaryFact(
                            label: "Cache hit",
                            value: fmtPct(session.usage.cacheHitRate))
                        Divider().frame(height: Theme.compactRowHeight)
                        InspectorSecondaryFact(
                            label: "Context / message",
                            value: fmtTokens(session.contextWeight))
                    }

                    if session.contextWeight > 0 {
                        ContextTaxGaugeView(gauge: ContextTax.gauge(session))
                    }

                    if let receipt {
                        RerouteReceiptView(receipt: receipt)
                    }
                }
                .padding(Theme.codePadding)
                .motionRowTransition()
            }
        }
        .background {
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .fill(Theme.cardFill)
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: Theme.hairlineWidth)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
        .reorderMotion(value: diagnosticsExpanded)
    }

    private func diagnosticsSummary(_ receipt: RerouteReceipt?) -> String {
        let base = "\(fmtPct(session.usage.cacheHitRate)) cache · \(fmtTokens(session.contextWeight)) context/msg"
        guard let receipt else { return base }
        return "\(base) · \(receipt.headline)"
    }

    private var transcriptRevealGeneration: Int {
        guard let request = services.terminalTranscriptReveal,
              request.sessionID == session.id else { return 0 }
        return request.generation
    }

    private var attentionStateForInspector: AttentionState {
        stateOverride ?? services.attentionBoard(now: services.now).items
            .first(where: { $0.id == session.id })?.state
            ?? (session.isActive ? .running : .idle)
    }

    @ViewBuilder
    private var transcript: some View {
        if let transcriptPreview {
            transcriptPreview
        } else {
            TranscriptView(filePath: session.filePath)
        }
    }
}

private struct InspectorFact: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.micro) {
            Text(label)
                .font(Theme.Typography.metadataMedium)
                .foregroundStyle(Theme.muted)
            Text(value)
                .font(Theme.Typography.metric)
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
                .liveNumericTransition(value: value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct InspectorSecondaryFact: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.micro / 2) {
            Text(label)
                .font(Theme.Typography.metadata)
                .foregroundStyle(Theme.muted)
            Text(value)
                .font(Theme.Typography.section)
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .liveNumericTransition(value: value)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Deterministic screen projection

/// One seeded row for the headless Sessions render. Keeping the state beside
/// the real SessionSummary lets the harness cover blocked, waiting, running,
/// and idle treatment without mutating the production classifier or stores.
struct SessionsRenderItem: Identifiable {
    let session: SessionSummary
    let state: AttentionState
    var suppressed = false
    var id: String { session.id }
}

/// The production Sessions browser composition over deterministic inputs. The
/// asynchronous transcript tail is the only injected seam; it still renders
/// through TranscriptView and its production TranscriptRow hierarchy.
struct SessionsRenderContent: View {
    let items: [SessionsRenderItem]
    let selectedID: String
    let transcriptEvents: [TranscriptEvent]

    @State private var activeOnly = false
    @State private var heavyOnly = false
    @State private var topLevelOnly = true
    @State private var liveInTerminalOnly = false

    private let liveIDs: Set<String> = ["sess-api-c190", "sess-billing-920a"]

    private var visibleItems: [SessionsRenderItem] {
        items.filter { item in
            (!topLevelOnly || !item.session.isSubagent)
                && (!liveInTerminalOnly || liveIDs.contains(item.id))
                && (!activeOnly || item.session.isActive)
                && (!heavyOnly || item.session.isContextHeavy)
        }
    }

    private var selected: SessionsRenderItem? {
        items.first { $0.id == selectedID }
    }

    var body: some View {
        HStack(spacing: 0) {
            listColumn
                .frame(width: 440)
            Divider()
            if let selected {
                SessionInspector(
                    session: selected.session,
                    stateOverride: selected.state,
                    transcriptPreview: AnyView(TranscriptView(
                        filePath: selected.session.filePath,
                        previewEvents: transcriptEvents)))
                    .frame(maxWidth: .infinity)
            }
        }
        .background(Theme.surfaceWindow)
    }

    private var listColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.blockGap) {
                VStack(alignment: .leading, spacing: 3) {
                    Text("Sessions")
                        .font(Theme.Typography.screenTitle)
                        .tracking(-0.55)
                        .foregroundStyle(Theme.ink)
                    Text("Search projects and task handles · costs are API-rate estimates, not bills")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(2)
                }
                .frame(minHeight: ScreenScaffoldMetrics.headerHeight, alignment: .top)
                .padding(.top, ScreenScaffoldMetrics.topInset)
                .padding(.horizontal, Theme.gutter)

                Divider()

                VStack(alignment: .leading, spacing: Theme.sectionGap) {
                    HStack(spacing: 6) {
                        Image(systemName: "magnifyingglass")
                            .font(Theme.Typography.metadataMedium)
                            .foregroundStyle(Theme.muted)
                        Text("Search project, task, path or id…")
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.faint)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, Theme.intraCell)
                    .padding(.vertical, Theme.rhythm)
                    .background {
                        RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
                            .fill(Theme.codeFill)
                        RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
                            .strokeBorder(Theme.cardStroke, lineWidth: Theme.hairlineWidth)
                    }

                    ScrollView(.horizontal) {
                        HStack(spacing: 6) {
                            FilterChip(label: "Top-level", isOn: topLevelOnly) {
                                topLevelOnly.toggle()
                            }
                            FilterChip(label: "Live in terminal", isOn: liveInTerminalOnly) {
                                liveInTerminalOnly.toggle()
                            }
                            FilterChip(label: "Active", isOn: activeOnly) {
                                activeOnly.toggle()
                            }
                            FilterChip(label: "Heavy context", isOn: heavyOnly) {
                                heavyOnly.toggle()
                            }
                            ForEach([ModelTier.opus, .sonnet], id: \.self) { tier in
                                FilterChip(label: tier.label, isOn: false) {}
                            }
                        }
                    }
                    .scrollIndicators(.never)

                    HStack {
                        Text("\(visibleItems.count) sessions")
                            .font(Theme.Typography.metadata)
                            .foregroundStyle(Theme.muted)
                        Spacer()
                        HStack(spacing: Theme.micro) {
                            Text("Recent")
                            Image(systemName: "chevron.up.chevron.down")
                                .font(Theme.Typography.metadata)
                        }
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.ink)
                    }
                }
                .padding(.horizontal, Theme.gutter)
            }
            .padding(.bottom, Theme.intraCell)

            Divider()
            SessionListColumns()
                .padding(.horizontal, Theme.codePadding + Theme.intraCell)
                .padding(.vertical, Theme.micro)
            Divider()

            VStack(spacing: Theme.micro / 2) {
                ForEach(visibleItems) { item in
                    SessionRow(
                        session: item.session,
                        isSelected: item.id == selectedID,
                        stateOverride: item.state,
                        suppressedOverride: item.suppressed)
                }
            }
            .padding(.horizontal, Theme.codePadding)
            .padding(.top, Theme.intraCell)
            Spacer(minLength: 0)
        }
    }
}
