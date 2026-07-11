import SwiftUI
import TrifolaKit

// MARK: - PLAN QUOTA (W7, plan 04) — the REAL rate-limit windows
// Sits directly below the burn governor: the honest pairing is "what we
// estimate you burned" (API-equiv dollars) next to "what Anthropic says you
// have left" (the plan's own 5h / weekly / model-scoped windows). This is the
// surface that makes today's 'resets 10am' moment predictable IN ADVANCE:
// every row carries its reset runway, so the wall is visible before it hits.

struct QuotaSection: View {
    let snapshots: [Provider: QuotaSnapshot]
    let statuses: [Provider: String]
    let source: ClaudeCredentialSource?
    let consent: QuotaConsent
    var now: Date = Date()
    var onRetry: () -> Void = {}

    init(snapshots: [Provider: QuotaSnapshot],
         statuses: [Provider: String],
         source: ClaudeCredentialSource?,
         consent: QuotaConsent,
         now: Date = Date(),
         onRetry: @escaping () -> Void = {}) {
        self.snapshots = snapshots
        self.statuses = statuses
        self.source = source
        self.consent = consent
        self.now = now
        self.onRetry = onRetry
    }

    /// Headless evidence fixtures written before provider parity can keep using
    /// the compact Claude-only initializer.
    init(snapshot: QuotaSnapshot?, status: String,
         source: ClaudeCredentialSource?, now: Date = Date(),
         onRetry: @escaping () -> Void = {}) {
        self.init(snapshots: snapshot.map { [.claude: $0] } ?? [:],
                  statuses: [.claude: status], source: source,
                  consent: QuotaConsent(claude: true), now: now,
                  onRetry: onRetry)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.rhythm) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("Plan quota")
                Spacer()
                if consent.claude || consent.codex {
                    QuietTapButton("Retry", action: onRetry)
                }
            }

            providerBlock(.claude, enabled: consent.claude)
            providerBlock(.codex, enabled: consent.codex)

            if !consent.claude && !consent.codex {
                Text("Quota access is off by default. Enable either provider in Settings → Quota; costs and attention remain fully available.")
                    .font(.callout)
                    .foregroundStyle(Theme.muted)
            }
        }
    }

    @ViewBuilder
    private func providerBlock(_ provider: Provider, enabled: Bool) -> some View {
        VStack(alignment: .leading, spacing: Theme.rhythm) {
            HStack(alignment: .firstTextBaseline) {
                Text(provider.label)
                    .font(.callout.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                Spacer()
                if provider == .claude,
                   let source,
                   let snapshot = snapshots[provider], !snapshot.isEmpty {
                    Text("ok · ").font(.caption).foregroundStyle(Theme.muted)
                        + Text(source.rawValue).font(.caption.monospaced())
                            .foregroundStyle(Theme.faint)
                } else if enabled {
                    Text(statuses[provider] ?? "not fetched yet")
                        .font(.caption)
                        .foregroundStyle(Theme.faint)
                }
            }

            if !enabled {
                Text("Access off")
                    .font(.callout)
                    .foregroundStyle(Theme.muted)
            } else if let snapshot = snapshots[provider],
                      !snapshot.isEmpty || snapshot.credits != nil {
                VStack(alignment: .leading, spacing: Theme.rhythm) {
                    ForEach(Array(snapshot.windows.enumerated()), id: \.element.title) { index, window in
                        QuotaWindowRow(window: window, now: now, drawIndex: index)
                    }
                    if let credits = snapshot.credits {
                        QuotaCreditsRow(credits: credits)
                    }
                }
                Text(provider == .claude
                     ? "OAuth usage endpoint · read-only — not dollars"
                     : "local rollout rate-limit events · no network")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            } else {
                Text(unavailableCopy(provider: provider))
                    .font(.callout)
                    .foregroundStyle(Theme.muted)
            }
        }
        .padding(.top, Theme.micro)
    }

    private func unavailableCopy(provider: Provider) -> String {
        let status = statuses[provider] ?? "not fetched yet"
        if provider == .codex {
            if status == "no Codex rollouts found" {
                return "No Codex rollouts were found. Trifola works fully without quota data."
            }
            if status == "no rate limits in local rollouts" {
                return "Local Codex rollouts do not carry rate limits yet. Trifola works fully without them."
            }
            return status
        }
        if status == "Signed out — run claude once to sign in, then Retry."
            || status == "Plan quota unavailable — the usage endpoint didn't answer. Costs and attention don't need it." {
            return status
        }
        if status.lowercased().hasPrefix("unauthorized") {
            return "Signed out — run claude once to sign in, then Retry."
        }
        return "Plan quota unavailable — the usage endpoint didn't answer. Costs and attention don't need it."
    }
}

private struct QuotaCreditsRow: View {
    let credits: QuotaCredits

    private var value: String {
        if credits.unlimited { return "Unlimited" }
        if let balance = credits.balance, !balance.isEmpty { return balance }
        return credits.hasCredits ? "Available" : "None"
    }

    var body: some View {
        HStack(spacing: Theme.sectionGap) {
            Text("Credits")
                .font(.callout)
                .foregroundStyle(Theme.ink)
                .frame(width: 150, alignment: .leading)
            Text(value)
                .font(.callout.monospacedDigit())
                .foregroundStyle(Theme.ink)
            Spacer()
        }
    }
}

/// One window: title · 6pt capsule · NN% (mono) · reset runway. The fill is the
/// accent until the window is actually tight — amber ≥75, red ≥90 (state colors
/// on state, never decoration).
private struct QuotaWindowRow: View {
    let window: QuotaWindow
    let now: Date
    let drawIndex: Int

    private var fill: Color {
        if window.usedPercent >= 90 { return Theme.red }
        if window.usedPercent >= 75 { return Theme.amber }
        return Theme.graphite
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
                    Reveal.Progress(itemIndex: drawIndex) { progress in
                        Capsule().fill(fill)
                            .frame(width: geo.size.width
                                * min(max(window.usedPercent, 0), 100) / 100
                                * progress)
                    }
                }
            }
            .frame(height: Theme.barHeight)
            Text("\(Int(window.usedPercent.rounded()))%")
                .font(.callout.monospacedDigit())
                .foregroundStyle(Theme.ink)
                .frame(width: Theme.microColWidth, alignment: .trailing)
            Text(resetLabel)
                .font(.callout)
                .foregroundStyle(Theme.muted)
                .frame(width: 90, alignment: .trailing)
        }
    }
}
