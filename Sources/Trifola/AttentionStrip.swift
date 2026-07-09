import SwiftUI
import TrifolaKit

/// The flagship surface: "which of my N live agents needs me RIGHT NOW."
/// A restrained strip atop Overview + Live Now — BLOCKED then WAITING sessions as
/// clickable chips, a per-state count legend, and a calm "all clear" when nothing
/// needs you (no-nag doctrine). Reuses the existing status-dot vocabulary.
struct AttentionStrip: View {
    @EnvironmentObject var services: AppServices

    var body: some View {
        AttentionStripView(board: services.attentionBoard(now: services.now),
                           signals: services.attention.signals) { session in
            services.inspect(session)
        }
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
    let onSelect: (SessionSummary) -> Void

    var body: some View {
        let needs = board.needsAttention

        return VStack(alignment: .leading, spacing: Theme.rhythm) {
            HStack(spacing: 8) {
                Image(systemName: needs.isEmpty ? "checkmark.circle" : "bell.badge")
                    .font(.footnote.weight(.medium))
                    .foregroundStyle(needs.isEmpty ? Theme.green : Theme.red)
                Text("Attention")
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.ink)
                Spacer()
                AttentionLegend(board: board)
            }

            if needs.isEmpty {
                HStack(spacing: 8) {
                    SeatMark(fill: board.runningCount > 0 ? Theme.green : Theme.faint,
                             size: 7, active: board.runningCount > 0)
                    Text(allClearText(board))
                        .font(.subheadline)
                        .foregroundStyle(Theme.muted)
                }
                .padding(.vertical, 1)
            } else {
                FlowLayout(spacing: 8, lineSpacing: 8) {
                    ForEach(needs) { item in
                        AttentionChip(item: item, signal: signals[item.id]) {
                            onSelect(item.session)
                        }
                    }
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
        .animation(.snappy(duration: 0.25), value: needs.map(\.id))
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
    let item: AttentionItem
    /// The tail signal backing this chip — carries the ask (tool + detail).
    var signal: AttentionSignals? = nil
    let onTap: () -> Void
    @State private var hovering = false

    /// The ask (UI_GRIND ATT-4): what the session wants, before you click — the
    /// dangling/last tool + its detail, faint mono (disk truth), ~24 chars. Only
    /// when the signal exists; absence stays honest silence.
    private var ask: String? {
        guard item.state.needsAttention,
              let sig = signal, let tool = sig.lastToolName else { return nil }
        let detail = sig.lastToolDetail ?? ""
        let s = detail.isEmpty ? tool : "\(tool) \(detail)"
        // Tail-truncate: the head (tool + the gate's name) IS the ask — a
        // mid-ellipsis chews it ("Bash app…· bun run dev").
        return s.count > 24 ? String(s.prefix(23)) + "…" : s
    }

    var body: some View {
        TapButton(action: onTap) {
            HStack(spacing: 7) {
                // The seat token: the state dot wears the tier as its 1pt ring
                // (POLISH C10) — the same object as the Floor + the door light, so
                // the chip's separate tier dot is gone; the tier label stays.
                SeatMark(fill: item.state.color, ring: item.session.tier.color, size: 7)
                VStack(alignment: .leading, spacing: 1) {
                    Text(item.session.project)
                        .font(.subheadline.weight(.medium))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    Text(item.session.shortID)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Theme.faint)
                        .lineLimit(1)
                }
                Text(item.state.label)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(item.state.color)
                Text(fmtAgeShort(item.age))
                    .font(.caption2)
                    .foregroundStyle(Theme.muted)
                if let ask {
                    Text("· \(ask)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Theme.faint)
                        .lineLimit(1)
                }
                Text(item.session.tier.label)
                    .font(.caption2)
                    .foregroundStyle(Theme.faint)
                if item.session.isRemote {
                    MachineChip(machineID: item.session.machineID, compact: true)
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Capsule())
            .background {
                Capsule().fill(hovering
                               ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor).opacity(0.6)
                               : .clear)
                Capsule().strokeBorder(Theme.hairline, lineWidth: 1)
            }
        }
        .onHover { h in withAnimation(.easeOut(duration: 0.12)) { hovering = h } }
        .help("Jump to \(item.session.project) — \(item.session.id) — \(item.state.label.lowercased())")
    }
}

// MARK: - Per-state count legend

private struct AttentionLegend: View {
    let board: AttentionBoard

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
        }
    }
}
