import SwiftUI
import TrifolaKit

/// Where the money goes: tier split, project leaderboard, the cache story and
/// the full routing audit.
struct SpendScreen: View {
    @EnvironmentObject var services: AppServices

    /// Pricing-catalog provenance + the OPTIONAL models.dev refresh state.
    /// Bundled seed (Anthropic docs) is authoritative; the refresh only ADDS
    /// models we don't know. Offline, nothing here is required or breaks.
    @State private var pricingSource = PricingCatalog.current.sourceLabel
    @State private var pricingRefreshing = false
    @State private var pricingError: String?

    private var store: SessionStore { services.sessions }

    var body: some View {
        ScreenScaffold(
            title: "Spend & Routing",
            subtitle: "API-rate equivalents estimated from real token counts — the number a metered key would have billed"
        ) {
            headline
            // "Show the math" (W3): the whole-corpus receipt behind the
            // headline spend — same slices, same rates, same Σ.
            ReceiptDisclosure(storageKey: "provenance.spend-total") {
                CostProvenance.corpusReceipt(sessions: store.sessions)
            }
            Divider()
            HStack(alignment: .top, spacing: Theme.gutter) {
                tierTable.frame(maxWidth: .infinity)
                Divider()
                VStack(alignment: .leading, spacing: 16) {
                    cacheSection
                    Divider()
                    auditSection
                }
                .frame(maxWidth: .infinity)
            }
            Divider()
            // RECONCILE (W3): our per-day totals vs CodexBar's independently
            // computed cache — the second opinion, read strictly read-only.
            ReconcilePanel(sessions: store.sessions)
            Divider()
            projectBoard
        }
    }

    // MARK: headline strip

    private var headline: some View {
        StatRow {
            StatTile(label: "Est. total spend", value: fmtUSD(store.totalCost),
                     sub: "\(fmtTokens(store.totalUsage.total)) tokens all time")
            Divider()
            StatTile(label: "Cache savings", value: fmtUSD(store.totalCacheSavings),
                     sub: "cache reads billed at 10% of input")
            Divider()
            StatTile(label: "Cache hit rate", value: fmtPct(store.totalUsage.cacheHitRate),
                     sub: "of input tokens served from cache")
        }
    }

    // MARK: tier table

    private var tierTable: some View {
        VStack(alignment: .leading, spacing: Theme.sectionGap) {
            SectionLabel("Tier economics")
            TierSplitBar(stats: store.tierStats)
            VStack(spacing: 0) {
                header
                ForEach(store.tierStats) { st in
                    tierRow(st)
                }
            }
            pricingFooter
        }
    }

    /// Provenance for every $ on this screen (per-MODEL catalog, W2) and the
    /// opt-in models.dev refresh. Never required; bundled rates work offline.
    private var pricingFooter: some View {
        HStack(spacing: 8) {
            Text("pricing: \(pricingSource) · grouped by tier, priced per model")
                .font(.caption2)
                .foregroundStyle(Theme.faint)
            if let pricingError {
                Text(pricingError)
                    .font(.caption2)
                    .foregroundStyle(Theme.amber)
            }
            Spacer()
            Button(pricingRefreshing ? "Refreshing…" : "Refresh from models.dev") {
                pricingRefreshing = true
                pricingError = nil
                Task {
                    do {
                        let merged = try await PricingCatalog.refreshFromModelsDev()
                        pricingSource = merged.sourceLabel
                    } catch {
                        pricingError = "refresh failed (bundled rates still in force)"
                    }
                    pricingRefreshing = false
                }
            }
            .buttonStyle(.link)
            .font(.caption2)
            .disabled(pricingRefreshing)
        }
        .padding(.top, 4)
    }

    private var header: some View {
        HStack {
            Text("Tier").frame(width: 110, alignment: .leading)
            Text("Sessions").frame(width: 70, alignment: .trailing)
            Text("Tokens").frame(width: 76, alignment: .trailing)
            Spacer()
            Text("Est. cost").frame(width: 84, alignment: .trailing)
        }
        .font(.caption)
        .foregroundStyle(Theme.muted)
        .padding(.vertical, Theme.rhythm)
    }

    private func tierRow(_ st: TierStat) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                HStack(spacing: 7) {
                    Circle().fill(st.tier.color).frame(width: 6, height: 6)
                    Text(st.tier.label)
                        .font(.subheadline)
                        .foregroundStyle(Theme.ink)
                }
                .frame(width: 110, alignment: .leading)
                Text("\(st.sessions)")
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
                    .frame(width: 70, alignment: .trailing)
                Text(fmtTokens(st.tokens))
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
                    .frame(width: 76, alignment: .trailing)
                Spacer()
                Text(fmtUSD(st.cost))
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .frame(width: 84, alignment: .trailing)
            }
            .padding(.vertical, 8)
            // "Show the math" (W3): this tier row's receipt — the tier is only
            // the display grouping; the legs are the per-model truth.
            ReceiptDisclosure(storageKey: "provenance.spend-tier-\(st.tier.rawValue)") {
                CostProvenance.tierReceipt(sessions: store.sessions, tier: st.tier)
            }
            .padding(.bottom, 6)
        }
        .overlay(alignment: .top) { Divider() }
    }

    // MARK: cache story

    private var cacheSection: some View {
        VStack(alignment: .leading, spacing: Theme.sectionGap) {
            SectionLabel("The cache story")
            let u = store.totalUsage
            gauge("Cache reads", u.cacheReadTokens, u.totalInput)
            gauge("Cache writes", u.cacheCreateTokens, u.totalInput)
            gauge("Fresh input", u.inputTokens, u.totalInput)
            Text("Reads are billed at one-tenth the fresh-input rate — that discount is worth \(fmtUSD(store.totalCacheSavings)) so far.")
                .font(.footnote)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func gauge(_ label: String, _ part: Int, _ whole: Int) -> some View {
        let f = whole > 0 ? Double(part) / Double(whole) : 0
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(label)
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink)
                Spacer()
                Text("\(fmtTokens(part)) · \(fmtPct(f))")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
            }
            CapsuleBar(fraction: f)
        }
    }

    // MARK: audit

    private var auditSection: some View {
        VStack(alignment: .leading, spacing: Theme.sectionGap) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("Routing audit")
                Spacer()
                Text(services.audit.defaultModel)
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
            }
            if services.audit.flags.isEmpty {
                Text("No findings.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
            } else {
                VStack(alignment: .leading, spacing: Theme.sectionGap) {
                    ForEach(services.audit.flags) { FlagRow(flag: $0) }
                }
            }
        }
    }

    // MARK: project leaderboard

    private var projectBoard: some View {
        VStack(alignment: .leading, spacing: Theme.sectionGap) {
            SectionLabel("Spend by project")
            let rows = Array(store.projectSpend.prefix(12))
            let top = max(rows.first?.cost ?? 1, 0.0001)
            VStack(spacing: Theme.rhythm) {
                ForEach(rows, id: \.project) { row in
                    HStack(spacing: Theme.sectionGap) {
                        Text(row.project)
                            .font(.subheadline)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                            .frame(width: 210, alignment: .leading)
                        CapsuleBar(fraction: row.cost / top)
                        Text("\(row.sessions)")
                            .font(.footnote)
                            .foregroundStyle(Theme.faint)
                            .frame(width: 40, alignment: .trailing)
                        Text(fmtUSD(row.cost))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.ink)
                            .frame(width: 80, alignment: .trailing)
                    }
                }
            }
        }
    }
}
