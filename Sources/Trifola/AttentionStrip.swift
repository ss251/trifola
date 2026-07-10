import SwiftUI
import TrifolaKit

/// The flagship surface: "which of my N live agents needs me RIGHT NOW."
/// A restrained strip atop Overview + Live Now — BLOCKED then WAITING sessions as
/// clickable chips, a per-state count legend, and a calm "all clear" when nothing
/// needs you (no-nag doctrine). Reuses the existing status-dot vocabulary.
struct AttentionStrip: View {
    @EnvironmentObject var services: AppServices

    var body: some View {
        let now = services.now
        let board = services.attentionBoard(now: now)
        AttentionStripView(
            board: board,
            signals: services.attention.signals,
            suppression: services.attentionSuppression(now: now),
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

        return VStack(alignment: .leading, spacing: Theme.rhythm) {
            HStack(spacing: 8) {
                Image(systemName: alertingBoard.needsAttention.isEmpty
                      ? (needs.isEmpty ? "checkmark.circle" : "bell.slash")
                      : "bell.badge")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(alertingBoard.needsAttention.isEmpty ? Theme.green : Theme.red)
                Text("Attention")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.ink)
                Spacer()
                AttentionLegend(board: alertingBoard,
                                suppressedCount: suppression?.suppressedCount ?? 0)
            }

            if needs.isEmpty {
                HStack(spacing: 8) {
                    SeatMark(fill: board.runningCount > 0 ? Theme.green : Theme.faint,
                             size: 7, active: board.runningCount > 0)
                    Text(allClearText(board))
                        .font(.subheadline)
                        .foregroundStyle(Theme.muted)
                }
                .padding(.vertical, Theme.hairlineWidth)
            } else {
                FlowLayout(spacing: Theme.intraCell, lineSpacing: Theme.intraCell) {
                    ForEach(shown) { row in
                        AttentionChip(row: row,
                                      suppressionState: suppression?.state,
                                      signal: signals[row.id],
                                      defaultSnoozeMinutes: defaultSnoozeMinutes,
                                      onAgencyAction: onAgencyAction) {
                            onSelect(row.item.session)
                        }
                    }
                }
                if suppressed.count > 1 {
                    MutedDisclosurePill(
                        label: showsSuppressed
                            ? "Hide snoozed sessions"
                            : "+\(suppressed.count) snoozed",
                        isExpanded: showsSuppressed) {
                            showsSuppressed.toggle()
                        }
                }
            }

            if let acknowledgement,
               now.timeIntervalSince(acknowledgement.startedAt) < 8 {
                HStack(spacing: 8) {
                    SeatMark(fill: Theme.green, size: 7)
                    Text("\(acknowledgement.project) moving again — approved \(fmtAgeShort(max(0, now.timeIntervalSince(acknowledgement.startedAt)))) ago")
                        .font(.subheadline)
                        .foregroundStyle(Theme.muted)
                }
                .motionTransition(edge: .top)
            }
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .fill(Theme.cardFill)
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 1)
        }
        .reorderMotion(value: shown.map(\.id) + [acknowledgement?.id ?? ""])
    }

    private func allClearText(_ b: AttentionBoard) -> String {
        if b.runningCount > 0 {
            return "All clear — \(b.runningCount) running, nothing needs you"
        }
        if b.idleCount > 0 { return "All clear — the fleet is idle" }
        return "No live sessions right now"
    }
}

// MARK: - One attention chip

private struct AttentionChip: View {
    let row: AttentionSuppressionRow
    var suppressionState: AttentionSuppressionState? = nil
    /// The tail signal backing this chip — carries the ask (tool + detail).
    var signal: AttentionSignals? = nil
    var defaultSnoozeMinutes = 60
    var onAgencyAction: ((AttentionSuppressionAction) -> Void)? = nil
    let onTap: () -> Void
    @State private var hovering = false

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
        TapButton(focusVisual: .card, action: onTap) {
            VStack(alignment: .leading, spacing: Theme.micro) {
                HStack(spacing: Theme.intraCell) {
                    Text(item.session.project)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                        .layoutPriority(1)
                    AttentionStatusPill(state: item.state)
                    if row.isSuppressed { SuppressionMark() }
                    Text(fmtAgeShort(item.age))
                        .font(.caption2)
                        .foregroundStyle(Theme.muted)
                    Spacer(minLength: 0)
                    Text(item.session.tier.label)
                        .font(.caption2)
                        .foregroundStyle(Theme.faint)
                    if item.session.isRemote {
                        MachineChip(machineID: item.session.machineID, compact: true)
                    }
                }
                HStack(spacing: Theme.rhythm) {
                    Text(item.session.displayTitle)
                        .font(.caption2)
                        .foregroundStyle(Theme.faint)
                        .lineLimit(1)
                        .layoutPriority(1)
                    if let ask {
                        Text("· \(ask)")
                            .font(.caption2)
                            .foregroundStyle(Theme.faint)
                            .lineLimit(1)
                    }
                }
            }
            .frame(minWidth: 300, idealWidth: 400, maxWidth: 410, alignment: .leading)
            .padding(.horizontal, Theme.sectionGap)
            .padding(.vertical, Theme.intraCell)
            .contentShape(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
            .background {
                RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                    .fill(hovering ? Theme.cardStroke : Theme.cardFill)
                RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                    .strokeBorder(Theme.cardStroke, lineWidth: 1)
            }
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
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .help("\(item.session.id) · opens your terminal — macOS asks permission the first time")
    }
}

// MARK: - Per-state count legend

private struct AttentionLegend: View {
    let board: AttentionBoard
    var suppressedCount = 0

    var body: some View {
        HStack(spacing: 12) {
            ForEach(AttentionState.allCases, id: \.self) { state in
                let n = board.count(state)
                if n > 0 {
                    HStack(spacing: 4) {
                        SeatMark(fill: state.color, size: 6)
                        Text("\(n)")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.ink)
                        Text(state.label.lowercased())
                            .font(.caption2)
                            .foregroundStyle(Theme.faint)
                    }
                }
            }
            if suppressedCount > 0 {
                Text("· \(suppressedCount) snoozed")
                    .font(.caption2)
                    .foregroundStyle(Theme.faint)
            }
        }
    }
}
