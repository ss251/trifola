import SwiftUI
import TrifolaKit

// MARK: - Credit-era burn governor (VISION 2.5) — the Overview surface
// The successor to the dead Jul-7 countdown: today's API-equiv burn, its Opus
// share, the recent-run-rate month projection, and a per-day sparkline whose bars
// carry the model-tier mix in the SAME hues the "spend by tier" bar uses (the
// evidence grammar, per-day). No nags, no red panic — visibility + trend, and an
// always-present "API-equiv, not your real bill" label so a number never lies about
// what it is.

/// The burn tile + sparkline block that lives on Overview (and the render harness).
struct BurnGovernorSection: View {
    let governor: BurnGovernor
    /// COST PROVENANCE (W3): today's receipt (+ the projection-math footnote),
    /// built lazily behind a "show the math" disclosure. nil = no disclosure
    /// (older render harnesses stay unchanged).
    var receipt: (() -> CostReceipt)? = nil
    /// The render harness forces the receipt open so the expanded state can be
    /// judged headlessly.
    var receiptInitiallyExpanded = false
    var showsDisclaimer = true

    private var today: DailyBurn { governor.today }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionGap) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("Daily burn")
                Spacer()
                // The honest limit, permanent and calm — these are API-rate
                // equivalents, not the metered credit bill (which isn't on disk).
                if showsDisclaimer {
                    Text("public API rates — not your bill")
                        .font(.caption2)
                        .foregroundStyle(Theme.faint)
                }
            }

            headline

            BurnSparkline(days: governor.days)

            // The axis: just the two ends — the denominator clause joined the
            // trailing headline cluster (UI_GRIND BRN-2: one claim, one seat).
            HStack(spacing: 8) {
                Text("-\(max(0, governor.days.count - 1))d")
                    .font(.caption2).foregroundStyle(Theme.faint)
                Spacer()
                Text("today")
                    .font(.caption2).foregroundStyle(Theme.faint)
            }

            // "Show the math" (W3): today's per-model receipt + the projection
            // formula — Σ legs is the tile's own number, same code path.
            if let receipt {
                ReceiptDisclosure(storageKey: "provenance.burn",
                                  initiallyExpanded: receiptInitiallyExpanded,
                                  build: receipt)
            }
        }
    }

    // "Today: $X API-equiv · N% Opus · at this pace ≈$Y/mo"
    private var headline: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text("Today")
                .font(.caption).foregroundStyle(Theme.muted)
            Text(fmtUSD(today.cost))
                .font(.title3.weight(.semibold))
                .foregroundStyle(Theme.ink)
                .liveNumericTransition(value: fmtUSD(today.cost))
            Text("API-rate estimate")
                .font(.caption2).foregroundStyle(Theme.faint)
            if today.cost > 0 {
                Text("·").font(.caption).foregroundStyle(Theme.faint)
                HStack(spacing: 4) {
                    Circle().fill(ModelTier.opus.color).frame(width: 6, height: 6)
                    Text("\(fmtPct(today.opusShare)) Opus")
                        .font(.subheadline).foregroundStyle(Theme.muted)
                        .liveNumericTransition(value: fmtPct(today.opusShare))
                }
            }
            Spacer()
            if governor.monthProjection > 0 {
                // The claim and its denominator in ONE sentence (UI_GRIND BRN-2):
                // "at this pace ≈$2.8k/mo · last 7d, $94/day".
                Text("at this pace")
                    .font(.caption).foregroundStyle(Theme.faint)
                Text("≈\(fmtUSD(governor.monthProjection))/mo")
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .liveNumericTransition(value: fmtUSD(governor.monthProjection))
                if governor.runRateDays > 0 {
                    Text("· last \(governor.runRateDays)d, \(fmtUSD(governor.dailyRunRate))/day")
                        .font(.caption).foregroundStyle(Theme.faint)
                        .liveNumericTransition(
                            value: "\(governor.runRateDays)|\(fmtUSD(governor.dailyRunRate))")
                }
            }
        }
    }
}

// MARK: - Per-day burn sparkline (the evidence grammar, vertical)
// One bar per day; bar height ∝ that day's API-equiv cost (normalized to the
// window peak); each bar segmented by the day's model-tier mix in the tier hues —
// so the sparkline reads as "how much, and on which models" at a glance, the same
// language as the spend-split bar. Quiet days keep a faint track tick so the time
// axis never lies by compressing.

struct BurnSparkline: View {
    let days: [DailyBurn]
    var height: CGFloat = 46

    private var peak: Double { max(days.map(\.cost).max() ?? 0, 0.0001) }

    var body: some View {
        // Today gets the spotlight (UI_GRIND BRN-1 / legendary #3): full
        // saturation + a tick under it; every prior day sits back at 70% — so the
        // hero "$39" is findable in its own evidence in one glance.
        HStack(alignment: .bottom, spacing: 2.5) {
            ForEach(Array(days.enumerated()), id: \.element.id) { i, d in
                DayBar(day: d, fraction: d.cost / peak, height: height,
                       isToday: i == days.count - 1)
            }
        }
        .frame(height: height + 3, alignment: .bottom)
    }

    private struct DayBar: View {
        let day: DailyBurn
        let fraction: Double
        let height: CGFloat
        let isToday: Bool

        var body: some View {
            let barH = max(2, height * min(1, fraction))
            VStack(spacing: 1.5) {
                Group {
                    if day.cost > 0 {
                        VStack(spacing: 0.5) {
                            // Stack tier slices top-down, tallest tier at the bottom so
                            // the dominant model reads as the base of the column.
                            ForEach(day.tierSlices, id: \.tier) { seg in
                                Rectangle()
                                    .fill(seg.tier.color)
                                    // 1pt floor: a non-zero segment never vanishes
                                    // (UI_GRIND BRN-3 — the stack stays honest).
                                    .frame(height: max(1, barH * (seg.cost / day.cost)))
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: barH, alignment: .bottom)
                        .clipShape(RoundedRectangle(cornerRadius: Theme.sparkRadius, style: .continuous))
                        .opacity(isToday ? 1 : 0.7)
                    } else {
                        // Quiet day — a faint track tick, not an empty gap.
                        Capsule()
                            .fill(Theme.progressTrack)
                            .frame(maxWidth: .infinity)
                            .frame(height: 2)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .bottom)
                // The single accent now-marker, matching the calendar's now line.
                Rectangle()
                    .fill(isToday ? Theme.accent : .clear)
                    .frame(maxWidth: .infinity)
                    .frame(height: 1.5)
            }
        }
    }
}
