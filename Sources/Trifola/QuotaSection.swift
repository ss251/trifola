import SwiftUI
import TrifolaKit

// MARK: - PLAN QUOTA (W7, plan 04) — the REAL rate-limit windows
// Sits directly below the burn governor: the honest pairing is "what we
// estimate you burned" (API-equiv dollars) next to "what Anthropic says you
// have left" (the plan's own 5h / weekly / model-scoped windows). This is the
// surface that makes today's 'resets 10am' moment predictable IN ADVANCE:
// every row carries its reset runway, so the wall is visible before it hits.

struct QuotaSection: View {
    let snapshot: QuotaSnapshot?
    let status: String
    let source: ClaudeCredentialSource?
    var now: Date = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.rhythm) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("Plan quota")
                Spacer()
                // Status caption: the source token (`file`/`keychain`) reads
                // mono — it is an identifier, not prose.
                if let source, snapshot != nil {
                    (Text("ok · ").font(.caption)
                        + Text(source.rawValue).font(.caption.monospaced()))
                        .foregroundStyle(Theme.faint)
                } else {
                    Text(status).font(.caption).foregroundStyle(Theme.faint)
                }
            }

            if let snapshot, !snapshot.isEmpty {
                VStack(alignment: .leading, spacing: Theme.rhythm) {
                    ForEach(snapshot.windows, id: \.title) { window in
                        QuotaWindowRow(window: window, now: now)
                    }
                }
                Text("plan rate-limit windows · OAuth usage endpoint · read-only — not dollars")
                    .font(.caption)
                    .foregroundStyle(Theme.faint)
            } else {
                // Graceful degradation: ONE calm explanatory line. No spinner,
                // no alert — the app is fully functional without this surface.
                Text("Quota \(status). The app works fully without it.")
                    .font(.callout)
                    .foregroundStyle(Theme.muted)
            }
        }
    }
}

/// One window: title · 6pt capsule · NN% (mono) · reset runway. The fill is the
/// accent until the window is actually tight — amber ≥75, red ≥90 (state colors
/// on state, never decoration).
private struct QuotaWindowRow: View {
    let window: QuotaWindow
    let now: Date

    private var fill: Color {
        if window.usedPercent >= 90 { return Theme.red }
        if window.usedPercent >= 75 { return Theme.amber }
        return Theme.accent
    }

    private var resetLabel: String {
        guard let resetsAt = window.resetsAt else { return "—" }
        return "resets \(fmtCountdown(resetsAt.timeIntervalSince(now)))"
    }

    var body: some View {
        HStack(spacing: Theme.sectionGap) {
            Text(window.title)
                .font(.callout)
                .foregroundStyle(Theme.ink)
                .frame(width: 150, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.progressTrack)
                    Capsule().fill(fill)
                        .frame(width: geo.size.width * min(max(window.usedPercent, 0), 100) / 100)
                }
            }
            .frame(height: Theme.barHeight)
            Text("\(Int(window.usedPercent.rounded()))%")
                .font(.callout.monospacedDigit())
                .foregroundStyle(Theme.ink)
                .frame(width: Theme.microColWidth, alignment: .trailing)
            Text(resetLabel)
                .font(.callout)
                .foregroundStyle(Theme.faint)
                .frame(width: 90, alignment: .trailing)
        }
    }
}
