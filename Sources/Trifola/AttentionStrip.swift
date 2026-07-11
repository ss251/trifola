import SwiftUI
import TrifolaKit

/// The flagship surface: "which of my N live agents needs me RIGHT NOW."
/// A restrained strip atop Overview + Live Now — BLOCKED then WAITING sessions as
/// clickable chips, a per-state count legend, and a calm "all clear" when nothing
/// needs you (no-nag doctrine). Reuses the existing status-dot vocabulary.
struct AttentionStrip: View {
    @EnvironmentObject var services: AppServices
    @EnvironmentObject var navigationSnapshots: NavigationSnapshotStore

    var body: some View {
        let now = services.now
        let board = navigationSnapshots.fleet?.attention
            ?? AttentionBoard(items: [], counts: [:])
        AttentionStripView(
            board: board,
            signals: services.attention.signals,
            suppression: services.agency.result(for: board, now: now),
            acknowledgement: services.agency.recoveryState.activeAcknowledgement(at: now),
            now: now,
            defaultSnoozeMinutes: services.preferences.value.defaultSnoozeDurationMinutes,
            onAgencyAction: { services.agency.perform($0, now: now) },
            onSelect: { services.openTerminal($0) })
    }
}

/// The pure, board-driven strip — no store dependency, so it rasterizes headlessly
/// (`--render-attention`) for visual verification of every state, including a
/// BLOCKED case that's rare on live data.
struct AttentionStripView: View {
    let board: AttentionBoard
    /// Per-session tail signals — the chip's ASK (UI_GRIND ATT-4 / legendary #2):
    /// a blocked chip says WHAT it is blocked on (`· Bash approval…`), so the
    /// strip answers "which one is blocked on me *and why*" in one glance.
    var signals: [String: AttentionSignals] = [:]
    var suppression: AttentionSuppressionResult? = nil
    var acknowledgement: UnblockedAcknowledgement? = nil
    var now = Date()
    var defaultSnoozeMinutes = 60
    var onAgencyAction: ((AttentionSuppressionAction) -> Void)? = nil
    let onSelect: (SessionSummary) -> Void
    @State private var showsSuppressed = false

    var body: some View {
        let alertingBoard = suppression?.alertingBoard ?? board
        let rows = suppression?.rows
            ?? board.items.map { AttentionSuppressionRow(item: $0, reason: nil) }
        let needs = rows.filter { $0.item.needsAttention }
        let unsuppressed = needs.filter { !$0.isSuppressed }
        let suppressed = needs.filter(\.isSuppressed)
        let shown = suppressed.count > 1 && !showsSuppressed ? unsuppressed : needs

        return Group {
            if needs.isEmpty {
                // No empty card for the healthy state. This is a status line in an
                // instrument panel: calm, compact, and subordinate to the fleet.
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: Theme.intraCell) {
                        SeatMark(state: board.runningCount > 0 ? .running : .idle, size: 8)
                            .frame(width: Theme.iconGutter)
                        Text("All clear")
                            .font(Theme.Typography.bodyMedium)
                            .foregroundStyle(Theme.ink)
                        Text("· \(allClearDetail(board))")
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.muted)
                        Spacer(minLength: Theme.sectionGap)
                        AttentionLegend(board: alertingBoard,
                                        suppressedCount: suppression?.suppressedCount ?? 0)
                    }
                    .padding(.horizontal, Theme.intraCell)
                    .padding(.vertical, Theme.rowVerticalInset)
                    .motionRowTransition()

                    recoveryLine
                }
            } else {
                VStack(alignment: .leading, spacing: 0) {
                    HStack(spacing: Theme.intraCell) {
                        SeatMark(
                            state: alertingBoard.blockedCount > 0 ? .blocked :
                                (alertingBoard.waitingCount > 0 ? .waiting : .idle),
                            size: 8)
                            .frame(width: Theme.iconGutter)
                        Text(alertingBoard.needsAttention.isEmpty
                             ? "Attention muted"
                             : "Needs attention")
                            .font(Theme.Typography.section)
                            .foregroundStyle(Theme.ink)
                        Spacer(minLength: Theme.sectionGap)
                        AttentionLegend(board: alertingBoard,
                                        suppressedCount: suppression?.suppressedCount ?? 0)
                    }
                    .padding(.horizontal, Theme.sectionGap)
                    .padding(.vertical, Theme.intraCell)

                    Rectangle().fill(Theme.hairline).frame(height: Theme.hairlineWidth)
                    AttentionColumnHeader()
                    Rectangle().fill(Theme.hairline).frame(height: Theme.hairlineWidth)

                    ForEach(Array(shown.enumerated()), id: \.element.id) { index, row in
                        AttentionChip(row: row,
                                      revealIndex: index,
                                      suppressionState: suppression?.state,
                                      signal: signals[row.id],
                                      defaultSnoozeMinutes: defaultSnoozeMinutes,
                                      onAgencyAction: onAgencyAction) {
                            onSelect(row.item.session)
                        }
                        .motionRowTransition()
                        if index < shown.count - 1 {
                            Rectangle().fill(Theme.hairline)
                                .frame(height: Theme.hairlineWidth)
                        }
                    }

                    if suppressed.count > 1 {
                        Rectangle().fill(Theme.hairline).frame(height: Theme.hairlineWidth)
                        MutedDisclosurePill(
                            label: showsSuppressed
                                ? "Hide snoozed sessions"
                                : "+\(suppressed.count) snoozed",
                            isExpanded: showsSuppressed) {
                                showsSuppressed.toggle()
                            }
                            .padding(Theme.intraCell)
                            .id("snoozed-disclosure")
                            .motionRowTransition()
                    }

                    recoveryLine
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .background {
                    RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                        .fill(Theme.cardFill)
                    RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                        .strokeBorder(Theme.cardStroke, lineWidth: Theme.hairlineWidth)
                }
                .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard,
                                            style: .continuous))
                .motionRowTransition()
            }
        }
        .reorderMotion(value: shown.map(\.id)
            + suppressed.map { "snoozed:\($0.id)" }
            + [acknowledgement?.id ?? ""])
    }

    @ViewBuilder private var recoveryLine: some View {
        if let acknowledgement,
           now.timeIntervalSince(acknowledgement.startedAt) < 8 {
            Rectangle().fill(Theme.hairline).frame(height: Theme.hairlineWidth)
            HStack(spacing: Theme.intraCell) {
                SeatMark(state: .running, size: 8)
                    .frame(width: Theme.iconGutter)
                Text("\(acknowledgement.project) moving again — approved \(fmtAgeShort(max(0, now.timeIntervalSince(acknowledgement.startedAt)))) ago")
                    .font(Theme.Typography.body)
                    .foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, Theme.intraCell)
            .padding(.vertical, Theme.rowVerticalInset)
            .motionRowTransition()
        }
    }

    private func allClearDetail(_ b: AttentionBoard) -> String {
        if b.runningCount > 0 {
            return "\(b.runningCount) running, nothing needs you"
        }
        if b.idleCount > 0 { return "the fleet is idle" }
        return "no live sessions right now"
    }
}

/// The header and rows share these exact cells. Fixed utility columns stop age,
/// tier, and host metadata from drifting as project names and asks change.
private struct AttentionColumnHeader: View {
    var body: some View {
        HStack(spacing: Theme.intraCell) {
            Color.clear.frame(width: Theme.iconGutter)
            Eyebrow("State")
                .frame(width: Theme.valueColWidth, alignment: .leading)
            Eyebrow("Project")
                .frame(width: Theme.rankBarWidth * 2,
                       alignment: .leading)
            Eyebrow("Needs")
                .frame(maxWidth: .infinity, alignment: .leading)
            Eyebrow("Age")
                .frame(width: Theme.microColWidth, alignment: .trailing)
            Eyebrow("Tier")
                .frame(width: Theme.subValueColWidth, alignment: .trailing)
            Eyebrow("Host")
                .frame(width: Theme.microColWidth, alignment: .trailing)
        }
        .padding(.horizontal, Theme.sectionGap)
        .padding(.vertical, Theme.micro)
    }
}

// MARK: - One attention chip

private struct AttentionChip: View {
    let row: AttentionSuppressionRow
    let revealIndex: Int
    var suppressionState: AttentionSuppressionState? = nil
    /// The tail signal backing this chip — carries the ask (tool + detail).
    var signal: AttentionSignals? = nil
    var defaultSnoozeMinutes = 60
    var onAgencyAction: ((AttentionSuppressionAction) -> Void)? = nil
    let onTap: () -> Void

    /// The ask (UI_GRIND ATT-4): what the session wants, before you click — the
    /// dangling/last tool + its detail, quiet narration, ~42 chars. Only
    /// when the signal exists; absence stays honest silence.
    private var ask: String? {
        let item = row.item
        guard item.state.needsAttention,
              let sig = signal, let tool = sig.lastToolName else { return nil }
        let detail = sig.lastToolDetail ?? ""
        let s = detail.isEmpty ? tool : "\(tool) \(detail)"
        // Tail-truncate: the head (tool + the gate's name) IS the ask — a
        // mid-ellipsis chews it ("Bash app…· bun run dev").
        return s.count > 42 ? String(s.prefix(41)) + "…" : s
    }

    var body: some View {
        let item = row.item
        HoverRow(radius: Theme.radiusRow, action: onTap) {
            HStack(alignment: .center, spacing: Theme.intraCell) {
                SeatMark(state: DoorLightState(item.state), size: 8,
                         revealIndex: revealIndex)
                    .frame(width: Theme.iconGutter)

                HStack(spacing: Theme.micro) {
                    Text(item.state == .blocked ? "Blocked" : "Waiting")
                        .font(Theme.Typography.bodyMedium)
                        .foregroundStyle(item.state == .blocked
                                         ? Theme.blockedText : Theme.waitingText)
                    if row.isSuppressed { SuppressionMark() }
                }
                .frame(width: Theme.valueColWidth, alignment: .leading)

                VStack(alignment: .leading, spacing: Theme.micro / 2) {
                    Text(item.session.project)
                        .font(Theme.Typography.bodyMedium)
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text(item.session.displayTitle)
                        .font(Theme.Typography.metadata)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
                .frame(width: Theme.rankBarWidth * 2,
                       alignment: .leading)

                Group {
                    if let ask {
                        Text(ask)
                            .font(Theme.Typography.bodyMedium)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                    } else {
                        Text("—")
                            .font(Theme.Typography.body)
                            .foregroundStyle(Theme.faint)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Text(fmtAgeShort(item.age))
                    .font(Theme.Typography.mono)
                    .foregroundStyle(Theme.muted)
                    .frame(width: Theme.microColWidth, alignment: .trailing)

                Text(item.session.tier.label)
                    .font(Theme.Typography.metadata)
                    .foregroundStyle(Theme.muted)
                    .frame(width: Theme.subValueColWidth, alignment: .trailing)

                Group {
                    if item.session.isRemote {
                        MachineChip(machineID: item.session.machineID, compact: true)
                    } else {
                        Color.clear
                    }
                }
                .frame(width: Theme.microColWidth, alignment: .trailing)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, Theme.sectionGap)
            .padding(.vertical, Theme.rowVerticalInset)
            .background {
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: Theme.radiusInline,
                                     style: .continuous)
                        .fill(stateWash)
                    Rectangle()
                        .fill(item.state.color)
                        .frame(width: Theme.Layout.semanticRailWidth)
                }
            }
            .contentShape(Rectangle())
        }
        .opacity(row.isSuppressed ? 0.45 : 1)
        .contextMenu {
            if let onAgencyAction {
                let now = Date()
                if suppressionState?.isSnoozed(sessionID: item.id, at: now) == true {
                    Button("Un-snooze") { onAgencyAction(.unsnooze(sessionID: item.id)) }
                } else {
                    Button("Snooze 1h") {
                        onAgencyAction(.snooze(sessionID: item.id,
                                              until: now.addingTimeInterval(60 * 60)))
                    }
                    if defaultSnoozeMinutes != 60 {
                        Button("Snooze default (\(formatSnoozeDuration(defaultSnoozeMinutes)))") {
                            onAgencyAction(.snooze(
                                sessionID: item.id,
                                until: now.addingTimeInterval(
                                    TimeInterval(defaultSnoozeMinutes * 60))))
                        }
                    }
                    Button("Snooze until tomorrow") {
                        onAgencyAction(.snooze(
                            sessionID: item.id,
                            until: AttentionSuppressionReducer.startOfTomorrow(after: now)))
                    }
                }
                if suppressionState?.isMuted(projectKey: item.session.project) == true {
                    Button("Unmute project") {
                        onAgencyAction(.unmute(projectKey: item.session.project))
                    }
                } else {
                    Button("Mute project") {
                        onAgencyAction(.mute(projectKey: item.session.project))
                    }
                }
            }
        }
        .help("\(item.session.id) · opens your terminal — macOS asks permission the first time")
    }

    private var stateWash: Color {
        row.item.state == .blocked ? Theme.blockedRowFill : Theme.waitingRowFill
    }
}

// MARK: - Per-state count legend

private struct AttentionLegend: View {
    let board: AttentionBoard
    var suppressedCount = 0

    var body: some View {
        HStack(spacing: Theme.sectionGap) {
            ForEach(AttentionState.allCases, id: \.self) { state in
                let n = board.count(state)
                if n > 0 {
                    HStack(spacing: Theme.micro) {
                        Text("\(n)")
                            .font(Theme.Typography.metadataMedium)
                            .foregroundStyle(state.needsAttention ? state.color : Theme.muted)
                            .monospacedDigit()
                            .liveNumericTransition(value: "\(n)")
                        Text(state.label.lowercased())
                            .font(Theme.Typography.metadata)
                            .foregroundStyle(Theme.muted)
                    }
                }
            }
            if suppressedCount > 0 {
                Text("\(suppressedCount) snoozed")
                    .font(Theme.Typography.metadata)
                    .foregroundStyle(Theme.muted)
                    .monospacedDigit()
                    .liveNumericTransition(value: "\(suppressedCount)")
            }
        }
    }
}
