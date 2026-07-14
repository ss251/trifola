import SwiftUI
import AppKit
import Combine
import TrifolaKit

// MARK: - Fleet store (signals + the persistent arrival ledger)
//
// Reads transcript tails for the in-window pool (mains AND subagents — subagents
// carry now-lines too) into the same `AttentionSignals` the strip uses, and holds
// the `ArrivalLedger` across refreshes so bays keep their seats. Building the
// board happens at render time against a fresh `now` (so RUNNING→BLOCKED flips
// live) using this stored, read-only ledger — the layout never shifts.

@MainActor
final class FleetStore: ObservableObject {
    @Published private(set) var signals: [String: AttentionSignals] = [:]
    private(set) var arrival = ArrivalLedger()

    /// Refresh signals for every in-window session (subagents included) and advance
    /// the arrival ledger so any newly-arrived bay/session claims its permanent seat.
    func refresh(sessions: [SessionSummary], now: Date = Date()) async {
        let window = FleetBoard.window
        let candidates: [(String, String)] = sessions.compactMap { s in
            guard let last = s.lastActivity, !s.filePath.isEmpty else { return nil }
            let age = now.timeIntervalSince(last)
            guard age >= 0, age <= window else { return nil }
            return (s.id, s.filePath)
        }
        let result = await Task.detached(priority: .userInitiated) {
            var out: [String: AttentionSignals] = [:]
            for (id, path) in candidates {
                if let sig = AttentionSignals.extractFromTail(path: path) { out[id] = sig }
            }
            return out
        }.value
        // Compare-before-assign (W6 wave 4): unchanged tails must not republish
        // the Floor — a publish re-renders every bay for zero information.
        if signals != result { signals = result }
        // Advance the ledger (keep the returned copy — this is the real refresh).
        let (_, advanced) = FleetBoard.build(sessions: sessions, signals: result,
                                             now: now, arrival: arrival)
        arrival = advanced
    }
}

// MARK: - Heartbeat driver (the disk-activity LED)
//
// One `FileTailer` per live seat. Every real append fires a coalesced (≤4/s) tick
// on that session's dot — the ONLY moving pixel that isn't a state crossfade.
// BLOCKED seats are marked still and never tick (a stall is the absence of
// motion). The initial tail read on open is history, not a live event, so it is
// skipped — opening a quiet file never produces a phantom heartbeat. View-scoped:
// tailers exist only while the Board is on screen, so a quiet room costs nothing.

@MainActor
final class HeartbeatDriver: ObservableObject {
    struct Watch: Equatable { let id: String; let filePath: String; let isStill: Bool }

    /// Per-session pulse counter — a token's dot animates a luminance blip whenever
    /// its count changes.
    @Published private(set) var pulses: [String: Int] = [:]

    private var coalescer = HeartbeatCoalescer()
    private var tailers: [String: FileTailer] = [:]
    private var still: Set<String> = []

    /// Reconcile the set of watched seats with the live board.
    func sync(_ watches: [Watch]) {
        let want = Dictionary(watches.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        still = Set(watches.filter(\.isStill).map(\.id))
        // Stop tailers for seats that left the floor.
        for (id, tailer) in tailers where want[id] == nil {
            tailer.stop()
            tailers[id] = nil
            pulses[id] = nil
            coalescer.drop(id)
        }
        // Start tailers for new seats.
        for w in watches where tailers[w.id] == nil && !w.filePath.isEmpty {
            let id = w.id
            let tailer = FileTailer(url: URL(fileURLWithPath: w.filePath), tailBytes: 64_000) { [weak self] chunk in
                // The initial reset read is history; only later appends are the
                // disk moving NOW. Empty line-sets (partial writes) don't count.
                guard !chunk.reset, !chunk.lines.isEmpty else { return }
                Task { @MainActor [weak self] in self?.tick(id) }
            }
            tailers[id] = tailer
            tailer.start()
        }
    }

    private func tick(_ id: String) {
        if coalescer.register(session: id, at: Date(), isStill: still.contains(id)) {
            pulses[id, default: 0] += 1
        }
    }

    func stopAll() {
        for (_, t) in tailers { t.stop() }
        tailers = [:]
        pulses = [:]
    }
}

// MARK: - The screen

struct FleetScreen: View {
    @EnvironmentObject var services: AppServices
    @EnvironmentObject var navigationSnapshots: NavigationSnapshotStore
    @EnvironmentObject var navigation: AppNavigation
    @StateObject private var heartbeat = HeartbeatDriver()

    var body: some View {
        Group {
            if services.sessions.scanPresentation.isProvisional {
                ScreenScaffold(
                    title: "Fleet Board",
                    subtitle: services.sessions.scanProgress.readingSentence) {
                    SessionReadingState(progress: services.sessions.scanProgress)
                        .frame(minHeight: 460)
                }
            } else if let snapshot = navigationSnapshots.fleet {
                fleetContent(snapshot)
            } else {
                ScreenScaffold(
                    title: "Fleet Board",
                    subtitle: "Preparing the current floor without blocking navigation") {
                    HStack(spacing: Theme.rhythm) {
                        ProgressView().controlSize(.small)
                        Text("Building fleet seats…")
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.muted)
                    }
                    .frame(maxWidth: .infinity, minHeight: 460)
                }
            }
        }
    }

    private func fleetContent(_ snapshot: FleetProjectionSnapshot) -> some View {
        let board = snapshot.board
        let watches = makeWatches(board: board)
        return Group {
            if board.bays.isEmpty {
                ScreenScaffold(
                    title: "Fleet Board",
                    subtitle: "No active agents · dollar estimates use public API rates, not your bill") {
                    EmptyState(
                        icon: "square.grid.3x3",
                        title: "The floor is empty",
                        detail: "Bays appear as agents arrive: one stable seat per repository. A seat stays put while its status, current work, and API-rate estimate update in place."
                    )
                    .frame(minHeight: 460)
                }
                .motionRowTransition()
            } else {
                ScrollView {
                    FleetFloor(
                        board: board,
                        attention: snapshot.attention,
                        signals: services.attention.signals,
                        pulses: heartbeat.pulses,
                        suppression: services.agency.result(
                            for: snapshot.attention, now: services.now),
                        acknowledgement: services.agency.recoveryState.activeAcknowledgement(at: services.now),
                        suppressionState: services.agency.suppressionState,
                        defaultSnoozeMinutes: services.preferences.value.defaultSnoozeDurationMinutes,
                        onAgencyAction: { services.agency.perform($0, now: services.now) },
                        onOpenTerminal: { services.openTerminal($0) },
                        onSelect: { services.inspect($0) }
                    )
                    .screenScaffoldFrame()
                }
                .scrollIndicators(.never)
                .motionRowTransition()
            }
        }
        .reorderMotion(value: board.bays.isEmpty)
        .onChange(of: watches) { _, w in heartbeat.sync(w) }
        .onAppear {
            if navigation.section == .fleet { heartbeat.sync(watches) }
        }
        .onChange(of: navigation.section) { _, section in
            if section == .fleet {
                heartbeat.sync(watches)
            } else {
                heartbeat.stopAll()
            }
        }
        .onDisappear { heartbeat.stopAll() }
    }

    /// The seats the heartbeat watches — every non-idle live token (mains +
    /// subagents), with blocked ones flagged still.
    private func makeWatches(board: FleetBoard) -> [HeartbeatDriver.Watch] {
        board.bays.flatMap(\.allTokens)
            .filter { $0.state != .idle && !$0.session.filePath.isEmpty }
            .map { .init(id: $0.id, filePath: $0.session.filePath, isStill: $0.isStill) }
    }
}

// MARK: - The Floor (pure — rasterizes headlessly via `--render-fleet`)

struct FleetFloor: View {
    let board: FleetBoard
    let attention: AttentionBoard
    /// Tail signals — the strip chips carry the ask (`· Bash approval…`).
    var signals: [String: AttentionSignals] = [:]
    var pulses: [String: Int] = [:]
    var suppression: AttentionSuppressionResult? = nil
    var acknowledgement: UnblockedAcknowledgement? = nil
    var suppressionState: AttentionSuppressionState? = nil
    var defaultSnoozeMinutes = 60
    var onAgencyAction: ((AttentionSuppressionAction) -> Void)? = nil
    var onOpenTerminal: ((SessionSummary) -> Void)? = nil
    var onSelect: (SessionSummary) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .launchReveal(.header)
            Divider()
                .launchReveal(.header)
            // The strip rides on top: "who needs me NOW" survives even while the
            // room below holds still. Sorted (triage) over stable (presence).
            AttentionStripView(board: attention,
                               signals: signals,
                               suppression: suppression,
                               acknowledgement: acknowledgement,
                               defaultSnoozeMinutes: defaultSnoozeMinutes,
                               onAgencyAction: onAgencyAction) {
                (onOpenTerminal ?? onSelect)($0)
            }
            .padding(.vertical, Theme.sectionGap)
            .launchReveal(.content)
            Divider()

            VStack(alignment: .leading, spacing: 0) {
                FleetColumnHeader()
                Rectangle().fill(Theme.hairline).frame(height: Theme.hairlineWidth)
                LazyVStack(alignment: .leading, spacing: Theme.sectionGap) {
                    ForEach(Array(board.bays.enumerated()), id: \.element.id) { bayIndex, bay in
                        FleetBayView(bay: bay,
                                     revealIndex: bayIndex,
                                     chipForced: duplicatedProjects.contains(bay.project),
                                     pulses: pulses,
                                     suppressionState: suppressionState,
                                     defaultSnoozeMinutes: defaultSnoozeMinutes,
                                     onAgencyAction: onAgencyAction,
                                     onOpenTerminal: onOpenTerminal,
                                     onSelect: onSelect)
                            .motionRowTransition()
                    }
                }
                .padding(.top, Theme.intraCell)
            }
            .padding(.top, Theme.micro)
            // Seats never re-sort (the ArrivalLedger owns order) — this animates
            // only ARRIVALS and DEPARTURES with the one app-standard motion
            // (W6 wave 4), so a bay appearing never snaps the room.
            .reorderMotion(
                value: board.bays.flatMap { [$0.id] + $0.allTokens.map(\.id) })
            .launchReveal(.content)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Project names present on MORE than one machine right now (UI_GRIND CRM-1):
    /// a local bay may omit its machine chip — until the same repo shows up on a
    /// second machine, at which point EVERY bay of that name wears its chip
    /// (the unlabeled one was ambiguous exactly where disambiguation is the job).
    private var duplicatedProjects: Set<String> {
        var machines: [String: Set<String>] = [:]
        for bay in board.bays { machines[bay.project, default: []].insert(bay.machineID) }
        return Set(machines.filter { $0.value.count > 1 }.keys)
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Theme.gutter) {
            VStack(alignment: .leading, spacing: Theme.micro) {
                Text("Fleet Board")
                    .font(Theme.Typography.screenTitle)
                    .tracking(-0.55)
                    .foregroundStyle(Theme.ink)
                Text(subtitle)
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.muted)
                    .frame(maxWidth: ScreenScaffoldMetrics.proseMaxWidth,
                           alignment: .leading)
            }
            Spacer()
            FleetCostMeter(board: board)
        }
        .frame(minHeight: ScreenScaffoldMetrics.headerHeight, alignment: .top)
    }

    private var subtitle: String {
        let bays = board.bays.count
        let mains = board.mainCount
        let subs = board.subagentCount
        let who = subs > 0
            ? "\(mains) agent\(mains == 1 ? "" : "s") · \(subs) subagent\(subs == 1 ? "" : "s")"
            : "\(mains) agent\(mains == 1 ? "" : "s")"
        // Cross-Machine Fleet: name the machine span when the floor covers more than
        // this Mac — the whole differentiator in one calm phrase.
        let machineN = Set(board.bays.map(\.machineID)).count
        let across = machineN > 1
            ? "across \(machineN) machines · \(bays) bay\(bays == 1 ? "" : "s")"
            : "across \(bays) bay\(bays == 1 ? "" : "s")"
        return "\(who) \(across) · stable seats · \(fmtUSD(board.totalCost)) today at public API rates — not your bill"
    }
}

/// A literal, denominator-visible cost meter for the floor. It reports
/// concentration within the API-rate estimate rather than implying a budget or
/// invoice: the largest bay is divided by the visible floor total.
private struct FleetCostMeter: View {
    let board: FleetBoard

    private var largestBay: FleetBay? {
        board.bays.max { $0.costSubtotal < $1.costSubtotal }
    }

    private var fraction: Double {
        guard board.totalCost > 0, let largestBay else { return 0 }
        return largestBay.costSubtotal / board.totalCost
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.micro) {
            HStack(alignment: .firstTextBaseline, spacing: Theme.intraCell) {
                Eyebrow("Largest bay share")
                Spacer(minLength: 0)
                Text(fmtUSD(board.totalCost))
                    .font(Theme.Typography.bodyMedium)
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
            }
            CapsuleBar(fraction: fraction,
                       tint: board.blockedCount > 0 ? Theme.amber : Theme.graphite)
            Text(largestBay.map {
                "\($0.project) · \(fmtPct(fraction)) of visible API-rate estimate"
            } ?? "No recorded cost on the floor")
                .font(Theme.Typography.metadata)
                .foregroundStyle(Theme.faint)
                .lineLimit(1)
        }
        .frame(width: 230)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Largest bay cost share")
        .accessibilityValue(largestBay.map {
            "\($0.project), \(fmtPct(fraction)) of \(fmtUSD(board.totalCost)) API-rate estimate"
        } ?? "No recorded cost")
    }
}

/// One table grammar for every bay. The project headers group stable seats; these
/// columns make the changing facts scan vertically without moving the seats.
private struct FleetColumnHeader: View {
    var body: some View {
        HStack(spacing: Theme.intraCell) {
            Color.clear.frame(width: Theme.subValueColWidth)
            Eyebrow("Model")
                .frame(width: Theme.valueColWidth, alignment: .leading)
            Eyebrow("Session")
                .frame(width: Theme.rankBarWidth * 2,
                       alignment: .leading)
            Eyebrow("Current work")
                .frame(maxWidth: .infinity, alignment: .leading)
            Eyebrow("State")
                .frame(width: Theme.valueColWidth, alignment: .leading)
            Eyebrow("Today")
                .frame(width: Theme.valueColWidth, alignment: .trailing)
        }
        .padding(Theme.rowInsets)
    }
}

// MARK: - One bay (a repo's stable place)

private struct FleetBayView: View {
    let bay: FleetBay
    let revealIndex: Int
    /// Forced when this project name exists on >1 machine (CRM-1).
    var chipForced = false
    var pulses: [String: Int]
    var suppressionState: AttentionSuppressionState? = nil
    var defaultSnoozeMinutes = 60
    var onAgencyAction: ((AttentionSuppressionAction) -> Void)? = nil
    var onOpenTerminal: ((SessionSummary) -> Void)? = nil
    var onSelect: (SessionSummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            BayHeader(bay: bay, chipForced: chipForced,
                      revealIndex: revealIndex)
            if let c = bay.collision {
                HStack(spacing: Theme.rhythm) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(Theme.Typography.metadataMedium)
                        .foregroundStyle(Theme.amber)
                    Text(c.message)
                        .font(Theme.Typography.metadata)
                        .foregroundStyle(Theme.muted)
                }
                .padding(.leading, Theme.subValueColWidth + Theme.intraCell)
                .padding(.horizontal, Theme.intraCell)
                .padding(.vertical, Theme.micro)
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(bay.tokens.enumerated()), id: \.element.id) { tokenIndex, token in
                    FleetTokenView(token: token, depth: 0, pulses: pulses,
                                   revealIndex: revealIndex + tokenIndex + 1,
                                   suppressionState: suppressionState,
                                   defaultSnoozeMinutes: defaultSnoozeMinutes,
                                   onAgencyAction: onAgencyAction,
                                   onOpenTerminal: onOpenTerminal,
                                   onSelect: onSelect)
                        .motionRowTransition()
                }
            }
        }
    }
}

private struct BayHeader: View {
    let bay: FleetBay
    var chipForced = false
    let revealIndex: Int

    var body: some View {
        HStack(spacing: Theme.intraCell) {
            SeatMark(state: bayDoorState, size: 8,
                     revealIndex: revealIndex)
                .frame(width: Theme.subValueColWidth, alignment: .leading)
            Text(bay.project)
                .font(Theme.Typography.section)
                .foregroundStyle(bay.isIdle ? Theme.muted : Theme.ink)
                .lineLimit(1)
            // The bay carries its machine tag — a remote bay ("workstation") reads
            // distinctly from a local one even when the repo name matches. A
            // LOCAL bay also chips up when its name exists on another machine
            // (CRM-1: the unlabeled twin was the ambiguous one).
            if bay.isRemote || chipForced {
                MachineChip(machineID: bay.machineID)
            }
            Spacer(minLength: Theme.sectionGap)
            trailing
        }
        .padding(Theme.rowInsets)
        .background {
            Rectangle().fill(Theme.cardFill)
        }
        .overlay(alignment: .bottom) {
            Rectangle().fill(Theme.hairline).frame(height: Theme.hairlineWidth)
        }
    }

    @ViewBuilder private var trailing: some View {
        HStack(spacing: Theme.intraCell) {
            Text(bayStateSummary)
                .font(Theme.Typography.metadataMedium)
                .foregroundStyle(bay.blockedCount > 0 ? Theme.blockedText : Theme.muted)
                .frame(width: Theme.valueColWidth, alignment: .trailing)
            Text(fmtUSD(bay.costSubtotal))
                .font(Theme.Typography.monoMedium)
                .foregroundStyle(bay.isIdle ? Theme.muted : Theme.ink)
                .frame(width: Theme.valueColWidth, alignment: .trailing)
        }
        .fixedSize()
    }

    private var bayStateSummary: String {
        if bay.isIdle { return "idle \(fmtAgeShort(bay.age))" }
        if bay.blockedCount > 0 { return "\(bay.blockedCount) blocked" }
        return "\(bay.liveCount) live"
    }

    private var bayDoorState: DoorLightState {
        guard let worst = bay.allTokens.map(\.state).min(by: { stateRank($0) < stateRank($1) }) else {
            return .idle
        }
        return DoorLightState(worst)
    }

    private func stateRank(_ state: AttentionState) -> Int {
        switch state {
        case .blocked: return 0
        case .waiting: return 1
        case .running: return 2
        case .idle: return 3
        }
    }
}

// MARK: - One token row (a seat) + nested subagents

private struct FleetTokenView: View {
    let token: FleetToken
    let depth: Int
    var isLast: Bool = true
    var pulses: [String: Int]
    var revealIndex: Int
    var suppressionState: AttentionSuppressionState? = nil
    var defaultSnoozeMinutes = 60
    var onAgencyAction: ((AttentionSuppressionAction) -> Void)? = nil
    var onOpenTerminal: ((SessionSummary) -> Void)? = nil
    var onSelect: (SessionSummary) -> Void
    @State private var showsChildren = false

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.micro / 2) {
            row
            if !token.children.isEmpty {
                MutedDisclosureRow(
                    label: "\(token.children.count) subagent\(token.children.count == 1 ? "" : "s") · \(fmtUSD(token.children.reduce(0) { $0 + $1.session.cost }))",
                    isExpanded: showsChildren) {
                        showsChildren.toggle()
                    }
                    .padding(.leading, Theme.subValueColWidth * 2 + Theme.intraCell * 2)
                if showsChildren {
                    ForEach(Array(token.children.enumerated()), id: \.element.id) { i, child in
                        FleetTokenView(token: child, depth: depth + 1,
                                       isLast: i == token.children.count - 1, pulses: pulses,
                                       revealIndex: revealIndex + i + 1,
                                       suppressionState: suppressionState,
                                       defaultSnoozeMinutes: defaultSnoozeMinutes,
                                       onAgencyAction: onAgencyAction,
                                       onOpenTerminal: onOpenTerminal,
                                       onSelect: onSelect)
                            .motionRowTransition()
                    }
                }
            }
        }
        .reorderMotion(value: showsChildren)
    }

    private var row: some View {
        let now = Date()
        let snoozed = suppressionState?.isSnoozed(sessionID: token.id, at: now) == true
        let muted = suppressionState?.isMuted(projectKey: token.session.project) == true
        let suppressed = snoozed || muted
        return HoverRow(radius: Theme.radiusRow, action: { onSelect(token.session) }) {
            HStack(spacing: Theme.intraCell) {
                HStack(spacing: Theme.micro) {
                    if depth > 0 {
                        Image(systemName: isLast ? "arrow.turn.down.right" : "arrow.turn.right.down")
                            .font(Theme.Typography.metadataMedium)
                            .foregroundStyle(Theme.faint)
                    }
                    HeartbeatDot(state: token.state, ring: token.tier.color,
                                 pulse: pulses[token.id] ?? 0, still: token.isStill,
                                 revealIndex: revealIndex)
                    if suppressed { SuppressionMark() }
                }
                .padding(.leading, CGFloat(max(0, depth - 1)) * Theme.intraCell)
                .frame(width: Theme.subValueColWidth, alignment: .leading)

                HStack(spacing: Theme.micro) {
                    ProviderBadge(provider: token.session.provider, compact: true)
                    Text(token.tier.label)
                        .font(Theme.Typography.metadata)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
                .frame(width: Theme.valueColWidth, alignment: .leading)

                VStack(alignment: .leading, spacing: Theme.micro / 2) {
                    Text(token.session.displayTitle)
                        .font(Theme.Typography.bodyMedium)
                        .foregroundStyle(token.state == .idle ? Theme.muted : Theme.ink)
                        .lineLimit(1)
                    Text(fmtAgeShort(token.age))
                        .font(Theme.Typography.mono)
                        .foregroundStyle(Theme.muted)
                }
                .frame(width: Theme.rankBarWidth * 2,
                       alignment: .leading)

                middle

                Text(token.state.label.capitalized)
                    .font(token.state.needsAttention
                          ? Theme.Typography.bodyMedium : Theme.Typography.body)
                    .foregroundStyle(stateTone)
                    .frame(width: Theme.valueColWidth, alignment: .leading)

                Text(fmtUSD(token.session.cost))
                    .font(Theme.Typography.bodyMedium)
                    .foregroundStyle(token.state == .idle ? Theme.muted : Theme.ink)
                    .frame(width: Theme.valueColWidth, alignment: .trailing)
                    .monospacedDigit()
            }
            .padding(Theme.rowInsets)
            .background {
                if token.state.needsAttention {
                    ZStack(alignment: .leading) {
                        RoundedRectangle(cornerRadius: Theme.radiusInline,
                                         style: .continuous)
                            .fill(attentionWash)
                        Rectangle()
                            .fill(token.state.color)
                            .frame(width: Theme.Layout.semanticRailWidth)
                    }
                }
            }
        }
        .opacity(suppressed ? 0.45 : emberOpacity)
        .contextMenu {
            Button("Focus transcript") { onSelect(token.session) }
            if let onOpenTerminal {
                Button("Open terminal") { onOpenTerminal(token.session) }
            }
            if let onAgencyAction {
                Divider()
                if snoozed {
                    Button("Un-snooze") { onAgencyAction(.unsnooze(sessionID: token.id)) }
                } else {
                    Button("Snooze 1h") {
                        onAgencyAction(.snooze(sessionID: token.id,
                                              until: now.addingTimeInterval(60 * 60)))
                    }
                    if defaultSnoozeMinutes != 60 {
                        Button("Snooze default (\(formatSnoozeDuration(defaultSnoozeMinutes)))") {
                            onAgencyAction(.snooze(
                                sessionID: token.id,
                                until: now.addingTimeInterval(
                                    TimeInterval(defaultSnoozeMinutes * 60))))
                        }
                    }
                    Button("Snooze until tomorrow") {
                        onAgencyAction(.snooze(
                            sessionID: token.id,
                            until: AttentionSuppressionReducer.startOfTomorrow(after: now)))
                    }
                }
                if muted {
                    Button("Unmute project") {
                        onAgencyAction(.unmute(projectKey: token.session.project))
                    }
                } else {
                    Button("Mute project") {
                        onAgencyAction(.mute(projectKey: token.session.project))
                    }
                }
            }
        }
        .help(hoverEvidence)
    }

    /// Current tool + path when present; otherwise the state. The session column
    /// already owns the human handle, so this cell never repeats it as filler.
    @ViewBuilder private var middle: some View {
        VStack(alignment: .leading, spacing: Theme.micro / 2) {
            if let n = token.nowLine {
                (Text(n.tool).font(Theme.Typography.bodyMedium)
                    .foregroundStyle(Theme.ink)
                 + Text(n.detail.isEmpty ? "" : "  \(midTruncate(n.detail, 44))")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.muted))
                    .lineLimit(1)
            } else {
                Text(token.state.label.lowercased())
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.muted)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var stateTone: Color {
        switch token.state {
        case .blocked: return Theme.blockedText
        case .waiting: return Theme.waitingText
        case .running, .idle: return Theme.muted
        }
    }

    private var attentionWash: Color {
        token.state == .blocked ? Theme.blockedRowFill : Theme.waitingRowFill
    }

    /// Findings-as-evidence hover (VISION §5): the classification's basis, not a
    /// verdict.
    private var hoverEvidence: String {
        switch token.state {
        case .blocked:
            return "\(token.nowLine?.tool ?? "tool") · no result for \(fmtAgeShort(token.age)) → likely a permission prompt / human gate"
        case .waiting: return "Turn ended — the ball is in your court"
        case .running: return "Work streaming — \(token.nowLine.map { "\($0.tool) \($0.detail)" } ?? "tool activity")"
        case .idle:    return "No activity for \(fmtAgeShort(token.age))"
        }
    }

    /// The ember fade: a static rendering of `age` — fresh seats read full, cooled
    /// ones dim toward the background. Recomputed on refresh, never animated.
    private var emberOpacity: Double {
        guard token.state == .idle else { return 1 }
        let frac = min(1, token.age / FleetBoard.window)   // 0 fresh … 1 window-old
        return 1 - 0.45 * frac
    }
}

// MARK: - The heartbeat dot
//
// A plain filled status dot (CodexBar discipline — no glow, no timer pulse) that
// blips its luminance once, ~200ms ease-out, each time its pulse count changes:
// one honest tick per disk event. A BLOCKED (still) seat's count never changes,
// so it holds perfectly still.

private struct HeartbeatDot: View {
    let state: AttentionState
    let ring: Color
    let pulse: Int
    let still: Bool
    let revealIndex: Int

    var body: some View {
        SeatMark(state: DoorLightState(state), size: 8,
                 revealIndex: revealIndex)
    }
}

// MARK: - Path mid-truncation

/// Keep the head and (more importantly) the tail of a path — the filename that
/// carries the meaning — collapsing the middle. "…/LiveScreen.swift".
func midTruncate(_ s: String, _ max: Int) -> String {
    guard s.count > max, max > 3 else { return s }
    let keepTail = (max - 1) * 2 / 3
    let keepHead = max - 1 - keepTail
    let head = s.prefix(keepHead)
    let tail = s.suffix(keepTail)
    return "\(head)…\(tail)"
}
