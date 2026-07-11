import SwiftUI
import TrifolaKit

/// The fleet browser: search + tier/state filters + sortable session list on
/// the left, live inspector on the right.
struct SessionsScreen: View {
    @EnvironmentObject var services: AppServices
    @EnvironmentObject var navigationSnapshots: NavigationSnapshotStore

    enum SortKey: String, CaseIterable, Identifiable {
        case recent = "Recent", cost = "Cost", context = "Context", tokens = "Tokens"
        var id: String { rawValue }
    }

    private var projectionFilter: SessionProjectionFilter {
        navigationSnapshots.sessionFilter
    }
    private var query: String { projectionFilter.query }
    private var providerFilter: Provider? { projectionFilter.provider }
    private var tierFilter: ModelTier? { projectionFilter.tier }
    private var machineFilter: String? { projectionFilter.machineID }
    private var activeOnly: Bool { projectionFilter.activeOnly }
    private var heavyOnly: Bool { projectionFilter.heavyOnly }
    private var topLevelOnly: Bool { projectionFilter.topLevelOnly }
    private var liveInTerminalOnly: Bool { projectionFilter.liveInTerminalOnly }
    private var sort: SortKey {
        SortKey(rawValue: projectionFilter.sort.rawValue) ?? .recent
    }

    private func updateFilter<Value>(
        _ keyPath: WritableKeyPath<SessionProjectionFilter, Value>,
        to value: Value
    ) {
        var copy = projectionFilter
        copy[keyPath: keyPath] = value
        navigationSnapshots.updateSessionFilter(copy)
    }

    private var queryBinding: Binding<String> {
        Binding(get: { query }, set: {
            updateFilter(\.query, to: $0)
        })
    }

    var body: some View {
        Group {
            if let snapshot = navigationSnapshots.sessions,
               snapshot.filter == projectionFilter {
                sessionColumns(filtered: snapshot.rows)
            } else {
                sessionShell
            }
        }
        .reorderMotion(value: services.selectedSessionID)
    }

    private func sessionColumns(filtered: [SessionSummary]) -> some View {
        // Snapshot every corpus-derived/shared input once for the whole list.
        // `SessionStore.fleetMachines` walks the complete session corpus; calling
        // `services.isCrossMachine` from each visible row multiplied that work by
        // the viewport size during the first Sessions draw. The ready fleet
        // projection is already off-main, with one bounded fallback for startup.
        let fleetMachines = navigationSnapshots.fleet?.machineRollups.map(\.machine)
            ?? services.sessions.fleetMachines
        let isCrossMachine = fleetMachines.count > 1
            || !services.machines.config.remotes.isEmpty
        let now = services.now
        let suppressionState = services.agency.suppressionState

        return SessionsAdaptiveSplit(
            compactShowsDetail: services.selectedSession != nil,
            onBack: { services.selectedSessionID = nil }
        ) {
            listColumn(
                filtered: filtered,
                fleetMachines: fleetMachines,
                isCrossMachine: isCrossMachine,
                now: now,
                suppressionState: suppressionState)
        } detail: {
            inspector
                .launchReveal(.content)
        }
    }

    private var sessionShell: some View {
        SessionsAdaptiveSplit(compactShowsDetail: false, onBack: {}) {
            VStack(alignment: .leading, spacing: Theme.sectionGap) {
                Text("Sessions")
                    .font(Theme.Typography.screenTitle)
                    .foregroundStyle(Theme.ink)
                HStack(spacing: Theme.rhythm) {
                    ProgressView().controlSize(.small)
                    Text("Preparing session index…")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
            }
            .padding(Theme.gutter)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } detail: {
            EmptyState(icon: "text.magnifyingglass",
                       title: "Session detail",
                       detail: "The indexed list will appear here without blocking navigation.")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: List column

    private func listColumn(
        filtered: [SessionSummary],
        fleetMachines: [Machine],
        isCrossMachine: Bool,
        now: Date,
        suppressionState: AttentionSuppressionState
    ) -> some View {
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
                        TextField("Search project, task, path or id…",
                                  text: queryBinding)
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

                    FlowLayout(spacing: Theme.rhythm, lineSpacing: Theme.rhythm) {
                        FilterChip(label: "Top-level", isOn: topLevelOnly) {
                            updateFilter(\.topLevelOnly, to: !topLevelOnly)
                        }
                        FilterChip(label: "Live in terminal", isOn: liveInTerminalOnly) {
                            updateFilter(\.liveInTerminalOnly,
                                         to: !liveInTerminalOnly)
                        }
                        FilterChip(label: "Active", isOn: activeOnly) {
                            updateFilter(\.activeOnly, to: !activeOnly)
                        }
                        FilterChip(label: "Heavy context", isOn: heavyOnly) {
                            updateFilter(\.heavyOnly, to: !heavyOnly)
                        }
                        ForEach(Provider.allCases, id: \.self) { provider in
                            FilterChip(label: provider.label,
                                       isOn: providerFilter == provider) {
                                updateFilter(
                                    \.provider,
                                    to: providerFilter == provider ? nil : provider)
                            }
                        }
                        // Machine filter — only when the fleet spans more than one
                        // machine, so single-machine users see zero cross-machine chrome.
                        if isCrossMachine {
                            ForEach(fleetMachines) { m in
                                FilterChip(label: m.chipLabel, isOn: machineFilter == m.id) {
                                    updateFilter(
                                        \.machineID,
                                        to: machineFilter == m.id ? nil : m.id)
                                }
                            }
                        }
                        ForEach(ModelTier.allCases.filter { $0 != .other }, id: \.self) { tier in
                            FilterChip(label: tier.label, isOn: tierFilter == tier) {
                                updateFilter(
                                    \.tier,
                                    to: tierFilter == tier ? nil : tier)
                            }
                        }
                    }

                    HStack {
                        Text("\(filtered.count) session\(filtered.count == 1 ? "" : "s")")
                            .font(Theme.Typography.metadata)
                            .foregroundStyle(Theme.muted)
                        Spacer()
                        Picker("Sort sessions", selection: Binding(
                            get: { sort },
                            set: {
                                updateFilter(
                                    \.sort,
                                    to: SessionProjectionFilter.Sort(
                                        rawValue: $0.rawValue) ?? .recent)
                            }
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
                let shown = filtered.prefix(400)
                let attentionStates = Dictionary(
                    (navigationSnapshots.fleet?.attention.items ?? [])
                        .map { ($0.id, $0.state) },
                    uniquingKeysWith: { current, _ in current })
                ScrollView {
                    LazyVStack(spacing: Theme.micro / 2) {
                        ForEach(shown) { s in
                            SessionRow(
                                session: s,
                                isSelected: services.selectedSessionID == s.id,
                                stateOverride: attentionStates[s.id]
                                    ?? (s.isActive(at: now) ? .running : .idle),
                                suppressedOverride:
                                    suppressionState.isSnoozed(
                                        sessionID: s.id, at: now)
                                    || suppressionState.isMuted(
                                        projectKey: s.project),
                                now: now,
                                isCrossMachine: isCrossMachine,
                                onSelect: { services.selectedSessionID = s.id })
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
                .task {
                    // Restored selection is useful, but forcing a deep scroll
                    // while the first frame lays out can defeat LazyVStack
                    // virtualization. Let the ready browser paint first, then
                    // restore its list position without blocking navigation.
                    if let id = services.selectedSessionID {
                        try? await Task.sleep(for: .milliseconds(250))
                        guard !Task.isCancelled else { return }
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
        .onChange(of: navigationSnapshots.fleet?.generation) {
            clearStaleRestorationIfIndexReady()
        }
    }

    private func clearStaleRestorationIfIndexReady() {
        guard services.sessions.scanPresentation == .liveRefreshing,
              !services.sessions.scanProgress.isInProgress else { return }
        guard let machineRollups = navigationSnapshots.fleet?.machineRollups else {
            return
        }
        if let machineFilter,
           !machineRollups.contains(where: { $0.machine.id == machineFilter }) {
            updateFilter(\.machineID, to: nil)
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
    let session: SessionSummary
    let isSelected: Bool
    var stateOverride: AttentionState? = nil
    var suppressedOverride: Bool? = nil
    let now: Date
    let isCrossMachine: Bool
    let onSelect: () -> Void
    private var primary: Color { isSelected ? Theme.selectionText : Theme.ink }
    private var secondary: Color { isSelected ? Theme.selectionText.opacity(0.8) : Theme.muted }

    var body: some View {
        let suppressed = suppressedOverride ?? false
        let state = stateOverride
            ?? (session.isActive(at: now) ? AttentionState.running : .idle)

        TapButton(action: onSelect) {
            HStack(spacing: Theme.intraCell) {
                VStack(spacing: Theme.micro / 2) {
                    SessionRowSeatMark(state: DoorLightState(state))
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
                        ProviderBadge(provider: session.provider, compact: true)
                        if isCrossMachine {
                            MachineChip(machineID: session.machineID)
                        }
                    }
                    identitySubtitle
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(session.lastActivity.map {
                    fmtAgeShort(max(0, now.timeIntervalSince($0)))
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
            .frame(maxWidth: .infinity)
            .frame(height: Theme.sessionRowHeight)
        }
        .opacity(suppressed ? 0.72 : 1)
        .help("Session \(session.id)")
        .contextMenu { SessionAgencyMenu(session: session) }
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
                    .fill(Theme.selectionBG)
            }
        }
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }

    private var identitySubtitle: some View {
        HStack(spacing: Theme.micro) {
            Text(session.displayTitle)
                .font(Theme.Typography.body)
                .foregroundStyle(secondary)
                .lineLimit(1)
                .truncationMode(.tail)
                .layoutPriority(1)
            Text("· \(session.tier.label)")
                .font(Theme.Typography.metadata)
                .foregroundStyle(secondary.opacity(0.8))
                .fixedSize()
        }
        .accessibilityElement(children: .combine)
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

/// A list row needs the Door Light's steady-state identity, not its 30fps
/// ceremony engine. Keeping the exact ring/core geometry while removing six
/// state slots and a TimelineView per realized row preserves the visual grammar
/// without multiplying animation machinery across a large virtualized list.
private struct SessionRowSeatMark: View {
    let state: DoorLightState
    @Environment(\.displayScale) private var displayScale
    @Environment(\.colorScheme) private var colorScheme

    private let size: CGFloat = 8
    private var ringWidth: CGFloat {
        AppBrand.Geometry.ringWidth(displayScale: displayScale)
    }

    var body: some View {
        ZStack {
            Circle()
                .strokeBorder(Theme.ink.opacity(0.35), lineWidth: ringWidth)
            if colorScheme == .light {
                Circle()
                    .inset(by: ringWidth + 0.25)
                    .stroke(Theme.surfaceWindow, lineWidth: 0.5)
            }
            if state != .idle {
                Circle()
                    .fill(state.color)
                    .frame(width: size * AppBrand.Geometry.coreRatio,
                           height: size * AppBrand.Geometry.coreRatio)
            }
        }
        .frame(width: size, height: size)
        .accessibilityHidden(true)
    }
}

// MARK: - Inspector detail

private struct SessionInspector: View {
    @EnvironmentObject var services: AppServices
    @EnvironmentObject var navigation: AppNavigation
    @EnvironmentObject var navigationSnapshots: NavigationSnapshotStore
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
        .frame(maxWidth: Theme.Layout.sessionsInspectorMaxWidth,
               maxHeight: .infinity,
               alignment: .topLeading)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
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
                ProviderBadge(provider: session.provider)
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
        stateOverride ?? navigationSnapshots.fleet?.attention.items
            .first(where: { $0.id == session.id })?.state
            ?? (session.isActive ? .running : .idle)
    }

    @ViewBuilder
    private var transcript: some View {
        if let transcriptPreview {
            transcriptPreview
        } else {
            TranscriptView(filePath: session.filePath,
                           provider: session.provider,
                           isPaused: navigation.section != .sessions)
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
    @EnvironmentObject var services: AppServices
    let items: [SessionsRenderItem]
    let selectedID: String
    let transcriptEvents: [TranscriptEvent]

    @State private var activeOnly = false
    @State private var heavyOnly = false
    @State private var topLevelOnly = true
    @State private var liveInTerminalOnly = false
    @State private var providerFilter: Provider?

    private let liveIDs: Set<String> = ["sess-api-c190", "sess-billing-920a"]

    private var visibleItems: [SessionsRenderItem] {
        items.filter { item in
            (!topLevelOnly || !item.session.isSubagent)
                && (!liveInTerminalOnly || liveIDs.contains(item.id))
                && (!activeOnly || item.session.isActive)
                && (!heavyOnly || item.session.isContextHeavy)
                && (providerFilter == nil || item.session.provider == providerFilter)
        }
    }

    private var selected: SessionsRenderItem? {
        items.first { $0.id == selectedID }
    }

    var body: some View {
        SessionsAdaptiveSplit(compactShowsDetail: selected != nil, onBack: {}) {
            listColumn
        } detail: {
            if let selected {
                SessionInspector(
                    session: selected.session,
                    stateOverride: selected.state,
                    transcriptPreview: AnyView(TranscriptView(
                        filePath: selected.session.filePath,
                        provider: selected.session.provider,
                        previewEvents: transcriptEvents)))
            }
        }
        .background(Theme.surfaceWindow)
    }

    private var listColumn: some View {
        let renderIsCrossMachine = Set(items.map(\.session.machineID)).count > 1

        return VStack(alignment: .leading, spacing: 0) {
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

                    FlowLayout(spacing: Theme.rhythm, lineSpacing: Theme.rhythm) {
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
                        ForEach(Provider.allCases, id: \.self) { provider in
                            FilterChip(label: provider.label,
                                       isOn: providerFilter == provider) {
                                providerFilter = providerFilter == provider ? nil : provider
                            }
                        }
                        ForEach([ModelTier.opus, .sonnet], id: \.self) { tier in
                            FilterChip(label: tier.label, isOn: false) {}
                        }
                    }

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
                        suppressedOverride: item.suppressed,
                        now: services.now,
                        isCrossMachine: renderIsCrossMachine,
                        onSelect: {})
                }
            }
            .padding(.horizontal, Theme.codePadding)
            .padding(.top, Theme.intraCell)
            Spacer(minLength: 0)
        }
    }
}

/// One responsive master-detail policy for both the live browser and its
/// deterministic evidence renderer. The list grows only until it is comfortably
/// scannable; the inspector then caps its reading measure and surplus window
/// width becomes calm outer margin. At the minimum window the same composition
/// becomes one pane with an explicit route back to the list.
private struct SessionsAdaptiveSplit<Master: View, Detail: View>: View {
    let compactShowsDetail: Bool
    let onBack: () -> Void
    @ViewBuilder let master: () -> Master
    @ViewBuilder let detail: () -> Detail

    var body: some View {
        GeometryReader { proxy in
            let available = proxy.size.width
            if available < Theme.Layout.sessionsCollapseWidth {
                if compactShowsDetail {
                    VStack(alignment: .leading, spacing: 0) {
                        TapButton(action: onBack) {
                            Label("All sessions", systemImage: "chevron.left")
                                .font(Theme.Typography.bodyMedium)
                                .foregroundStyle(Theme.ink)
                                .padding(.horizontal, Theme.gutter)
                                .frame(height: Theme.compactRowHeight)
                        }
                        .accessibilityHint("Return to the session list")
                        Divider()
                        detail()
                    }
                } else {
                    master()
                }
            } else {
                HStack(spacing: 0) {
                    master()
                        .frame(width: listWidth(for: available))
                    Divider()
                    detail()
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        }
        .centeredContentColumn(maxWidth: Theme.Layout.sessionsSplitMaxWidth)
    }

    private func listWidth(for available: CGFloat) -> CGFloat {
        min(
            Theme.Layout.sessionsListMaxWidth,
            max(
                Theme.Layout.sessionsListMinWidth,
                available * Theme.Layout.sessionsListFraction))
    }
}
