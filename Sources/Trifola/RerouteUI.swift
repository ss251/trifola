import SwiftUI
import TrifolaKit

// MARK: - REROUTE RECEIPTS (spree #2 — fallback/reroute-trend forensics)
// Three pure views, evidence grammar throughout (POLISH II.B/II.C): model ids
// and message refs render mono (disk truth), counts are tabular, every claim
// carries its denominator, and the semantics sentence — what a "silent
// reroute" can and cannot know — is `RerouteReport.semantics`, shared with
// the selfcheck so the copy can't fork. Nothing here nags: a clean session
// renders nothing at all.

/// The session-inspector block: this session's flip receipts.
struct RerouteReceiptView: View {
    let receipt: RerouteReceipt
    /// Rows shown before the "+N more" fold (the inspector is a column, not a page).
    private static let maxRows = 6

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Eyebrow("Reroute receipts")
                Spacer(minLength: 8)
                Text(receipt.headline)
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
            }
            Text("runs that landed on a different model than you configured")
                .font(.caption2)
                .foregroundStyle(Theme.faint)
            ForEach(receipt.silentFlips.prefix(Self.maxRows)) { flip in
                flipRow(flip)
            }
            if receipt.silentFlips.count > Self.maxRows {
                Text("+\(receipt.silentFlips.count - Self.maxRows) more")
                    .font(.caption2)
                    .foregroundStyle(Theme.faint)
            }
            if let note = receipt.switchNote {
                Text(note)
                    .font(.caption2)
                    .foregroundStyle(Theme.faint)
            }
            if !receipt.silentFlips.isEmpty {
                Text(RerouteReport.semantics)
                    .font(.caption2)
                    .foregroundStyle(Theme.faint)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func flipRow(_ flip: ModelFlip) -> some View {
        HStack(spacing: 6) {
            Image(systemName: flip.direction == .upshift
                  ? "arrow.up.right" : (flip.direction == .downshift ? "arrow.down.right" : "arrow.right"))
                .font(.caption2)
                .foregroundStyle(Theme.muted)
            // Disk truth: the pair and the message ref are mono.
            Text("\(flip.fromModel) → \(flip.toModel)")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Theme.ink)
            Spacer(minLength: 8)
            if let mid = flip.messageID {
                Text(String(mid.prefix(12)))
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Theme.faint)
            }
            Text(flip.timestamp.map { fmtAgo($0) } ?? (flip.day.isEmpty ? "undated" : flip.day))
                .font(.caption2)
                .monospacedDigit()
                .foregroundStyle(Theme.faint)
        }
    }
}

/// The fleet trend row (rides under the burn sparkline): reroutes/day over
/// the last 14 days + the dominant pair. Quiet when the corpus is clean.
struct RerouteTrendRow: View {
    let report: RerouteReport
    var now: Date = Date()

    var body: some View {
        if report.totalSilent > 0 {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Eyebrow("Reroutes")
                Text("runs that landed on a different model than you configured")
                    .font(.caption2)
                    .foregroundStyle(Theme.faint)
                Text(sparkline)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Theme.muted)
                Text("\(report.totalSilent) silent · \(report.receipts.count) session\(report.receipts.count == 1 ? "" : "s")")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(Theme.muted)
                if let top = report.pairs.first {
                    Text("top \(top.pair) ×\(top.count)")
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Theme.faint)
                        .lineLimit(1)
                }
                Spacer(minLength: 0)
                Text("14d · /model switches excluded (\(report.totalUserSwitches))")
                    .font(.caption2)
                    .foregroundStyle(Theme.faint)
            }
        }
    }

    /// The same block ramp the selfcheck burn spark uses — one dialect.
    private var sparkline: String {
        let series = report.trend(window: 14, now: now)
        let peak = max(series.map(\.count).max() ?? 0, 1)
        let blocks = ["·", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
        return series.map { _, c in
            c == 0 ? "·" : blocks[min(blocks.count - 1, 1 + (c * (blocks.count - 2)) / peak)]
        }.joined()
    }
}

/// The orchestrator-hog alert — surfaced exactly like the fresh-session
/// advisor (amber glyph, muted prose, threshold in the copy): evidence with
/// a structural verb ("delegate"), never a nag.
struct OrchestratorHogRow: View {
    let alert: OrchestratorHogAlert

    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(Theme.amber)
            Text("One session billed \(fmtPct(alert.share)) of today's \(fmtUSD(alert.dayTotal)). Orchestrator hog: \(alert.project) (\(alert.shortID)) billed \(fmtUSD(alert.sessionCost)); delegate more to cheaper subagents.")
                .font(.caption)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
