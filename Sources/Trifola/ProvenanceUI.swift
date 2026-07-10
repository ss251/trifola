import SwiftUI
import AppKit
import TrifolaKit

// MARK: - "Show the math" (W3) — the receipt disclosure + the mono receipt
// Every hero dollar earns a calm disclosure that expands into the receipt: the
// per-model legs, the arithmetic, Σ, and the provenance footers. The receipt
// renders MONO (it is what the disk + the pricing catalog said — POLISH II.C),
// no color drama, and "Copy" copies the exact same plain text. Collapsed by
// default; hero/tile disclosures remember their expansion per screen (the
// app's own UserDefaults — never ~/.claude); per-row disclosures are ephemeral.

struct ReceiptDisclosure: View {
    /// UserDefaults key for remembered expansion (nil = ephemeral, e.g. table
    /// rows — an unbounded per-row key space would just be litter).
    let storageKey: String?
    var initiallyExpanded = false
    /// Built lazily on expansion and re-evaluated live while open, so the
    /// receipt always agrees with the (possibly refreshed) headline.
    let build: () -> CostReceipt

    @State private var expanded: Bool

    init(storageKey: String?, initiallyExpanded: Bool = false,
         build: @escaping () -> CostReceipt) {
        self.storageKey = storageKey
        self.initiallyExpanded = initiallyExpanded
        self.build = build
        let persisted = storageKey.map { UserDefaults.standard.bool(forKey: $0) } ?? false
        _expanded = State(initialValue: initiallyExpanded || persisted)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            TapButton(action: {
                expanded.toggle()
                if let storageKey { UserDefaults.standard.set(expanded, forKey: storageKey) }
            }) {
                HStack(spacing: 4) {
                    Image(systemName: "chevron.right")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Theme.faint)
                        .disclosureChevron(isExpanded: expanded)
                    Text(expanded ? "hide the math" : "show the math")
                        .font(.caption)
                }
                .foregroundStyle(Theme.muted)
            }
            if expanded {
                ReceiptView(receipt: build())
                    .motionRowTransition()
            }
        }
        .reorderMotion(value: expanded)
    }
}

/// The receipt: the `plainText` verbatim (what you see is exactly what
/// "Copy" puts on the pasteboard), in a hairline container. Calm — the ink is
/// the only color; the math is the drama.
struct ReceiptView: View {
    let receipt: CostReceipt
    @State private var copied = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("receipt")
                    .font(.caption2)
                    .foregroundStyle(Theme.faint)
                Spacer()
                TapButton(action: {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(receipt.plainText, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.6))
                        copied = false
                    }
                }) {
                    Label(copied ? "Copied" : "Copy as text",
                          systemImage: copied ? "checkmark" : "doc.on.doc")
                        .font(.caption2)
                        .foregroundStyle(copied ? Theme.green : Theme.muted)
                }
            }
            Text(receipt.plainText)
                .font(.caption)
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(Theme.codePadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
                .fill(Theme.codeFill)
        }
    }
}

// MARK: - Reconcile vs CodexBar (W3) — the Spend panel
// Our per-day total vs CodexBar's independently computed one, for the recent
// days. Green check when |Δ| ≤ max($0.01, 0.5%); a visible Δ states its LIKELY
// cause calmly (lastScan lag / scan window / a named per-model gap) with a
// per-model drill-in. Graceful when the cache is absent — the app works
// normally without CodexBar.

struct ReconcilePanel: View {
    let sessions: [SessionSummary]
    var dayCount: Int = 7

    @State private var state: CodexBarCacheState?
    @State private var expandedDay: String?

    private var dayKeys: [String] {
        let cal = Calendar.current
        return (0..<max(1, dayCount)).compactMap { i in
            cal.date(byAdding: .day, value: -i, to: Date())
                .map { CostProvenance.dayKey(for: $0, calendar: cal) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionGap) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("Reconcile vs CodexBar")
                Spacer()
                if case .loaded(let cache) = state, let scan = cache.lastScan {
                    Text("CodexBar last scanned \(fmtAgo(scan))")
                        .font(.caption2)
                        .foregroundStyle(Theme.muted)
                }
            }
            Text("CodexBar computes the same per-model-day API-rate estimate independently from the same transcripts. Green = |Δ| ≤ max($0.01, 0.5%). Today accrues on both sides until each next scan.")
                .font(.caption2)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            ArtifactPill(icon: "externaldrive", name: "CodexBar cache", help: "Read-only comparison file") {
                let path = ("~/Library/Caches/CodexBar/cost-usage/claude-v4.json" as NSString).expandingTildeInPath
                NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
            }

            switch state {
            case nil:
                Text("Reading CodexBar cache…")
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
            case .missing:
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.faint)
                    Text("CodexBar cache not found — is CodexBar installed? Everything here works without it; there is just no second opinion to reconcile against.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .unreadable(let why):
                HStack(spacing: 8) {
                    Image(systemName: "info.circle")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.faint)
                    Text("CodexBar cache present but unreadable (\(why)) — skipping the reconcile; the app's own numbers are unaffected.")
                        .font(.subheadline)
                        .foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            case .loaded(let cache):
                rows(cache: cache)
            }
        }
        .task {
            state = await Task.detached(priority: .userInitiated) {
                CodexBarReconcile.load()
            }.value
        }
    }

    @ViewBuilder
    private func rows(cache: CodexBarCache) -> some View {
        let days = CodexBarReconcile.compare(sessions: sessions, cache: cache, days: dayKeys)
        let today = CostProvenance.dayKey(for: Date())
        EvidenceColumns(leading: "Day", columns: [
            ("ours", Theme.valueColWidth, .trailing),
            ("CodexBar", Theme.valueColWidth, .trailing),
            ("Δ", Theme.subValueColWidth, .trailing),
            ("", 20, .center),
        ])
        VStack(spacing: 0) {
            ForEach(days) { row in
                dayRow(row, cache: cache, isToday: row.day == today)
            }
        }
    }

    @ViewBuilder
    private func dayRow(_ row: ReconcileDay, cache: CodexBarCache, isToday: Bool) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: Theme.sectionGap) {
                HStack(spacing: 6) {
                    Text(row.day)
                        .font(.caption)
                        .foregroundStyle(Theme.ink)
                    if isToday {
                        Text("today · accruing")
                            .font(.caption2)
                            .foregroundStyle(Theme.muted)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Text(String(format: "$%.2f", row.ours))
                    .font(.caption).foregroundStyle(Theme.ink).monospacedDigit()
                    .frame(width: Theme.valueColWidth, alignment: .trailing)
                Text(String(format: "$%.2f", row.theirs))
                    .font(.caption).foregroundStyle(Theme.muted).monospacedDigit()
                    .frame(width: Theme.valueColWidth, alignment: .trailing)
                Text(String(format: "%+.2f", row.delta))
                    .font(.caption).foregroundStyle(row.matches ? Theme.faint : Theme.ink)
                    .monospacedDigit()
                    .frame(width: Theme.subValueColWidth, alignment: .trailing)
                Group {
                    if row.matches {
                        Image(systemName: "checkmark.circle")
                            .font(.caption.weight(.medium))
                            .foregroundStyle(Theme.green)
                    } else {
                        TapButton(action: {
                            expandedDay = expandedDay == row.day ? nil : row.day
                        }) {
                            Image(systemName: expandedDay == row.day ? "chevron.down.circle" : "chevron.right.circle")
                                .font(.caption.weight(.medium))
                                .foregroundStyle(Theme.muted)
                        }
                        .accessibilityLabel(expandedDay == row.day
                            ? "Hide per-model reconciliation for \(row.day)"
                            : "Show per-model reconciliation for \(row.day)")
                        .accessibilityHint("Review the model-level difference for this day")
                        .help("Per-model drill-in")
                    }
                }
                .frame(width: 20)
            }
            .padding(Theme.rowInsets)
            .overlay(alignment: .top) { Divider() }
            if !row.matches, let cause = row.likelyCause(lastScan: cache.lastScan) {
                Text(cause)
                    .font(.caption2)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.leading, Theme.intraCell)
                    .padding(.bottom, Theme.micro)
            }
            if expandedDay == row.day {
                modelDrillIn(row)
                    .padding(.leading, Theme.intraCell)
                    .padding(.bottom, Theme.rhythm)
            }
        }
    }

    private func modelDrillIn(_ row: ReconcileDay) -> some View {
        // Deterministic ties (W6 wave 4): equal-cost models keep a stable name
        // order across recomputes — Swift's sort is not stable.
        let models = Set(row.ourModels.keys).union(row.theirModels.keys).sorted {
            (row.ourModels[$0] ?? 0, $1) > (row.ourModels[$1] ?? 0, $0)
        }
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(models, id: \.self) { m in
                let o = row.ourModels[m] ?? 0
                let t = row.theirModels[m] ?? 0
                HStack(spacing: Theme.sectionGap) {
                    Text(m.isEmpty ? "(unknown model)" : m)
                        .font(.system(.caption2, design: .monospaced))
                        .foregroundStyle(Theme.muted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(String(format: "$%.2f", o))
                        .font(.caption2).foregroundStyle(Theme.ink).monospacedDigit()
                        .frame(width: Theme.valueColWidth, alignment: .trailing)
                    Text(String(format: "$%.2f", t))
                        .font(.caption2).foregroundStyle(Theme.muted).monospacedDigit()
                        .frame(width: Theme.valueColWidth, alignment: .trailing)
                    Text(String(format: "%+.2f", o - t))
                        .font(.caption2)
                        .foregroundStyle(CodexBarReconcile.withinTolerance(ours: o, theirs: t) ? Theme.faint : Theme.ink)
                        .monospacedDigit()
                        .frame(width: Theme.subValueColWidth, alignment: .trailing)
                    Color.clear.frame(width: 20)
                }
            }
        }
    }
}
