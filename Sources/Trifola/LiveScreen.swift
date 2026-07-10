import SwiftUI
import TrifolaKit

/// The live board: every active session gets a tile with a real-time
/// transcript tail. This is the screen you leave open on the second monitor.
struct LiveScreen: View {
    @EnvironmentObject var services: AppServices

    /// Stable seats (W6 wave 4 — the reshuffle fix): a tile claims its place when
    /// it ENTERS the live pool and keeps it until it leaves. Re-sorting by
    /// recency on every transcript byte made the whole grid of transcript tiles
    /// reshuffle constantly — the jank the user named. Survivors keep their
    /// order; newcomers (freshest first) append; departures drop.
    @State private var seatOrder: [String] = []

    /// The live pool, freshest-first — the ranking for NEWCOMERS only.
    private var pool: [SessionSummary] {
        services.sessions.activeSessions
            .sorted {
                ($0.lastActivity ?? .distantPast, $1.id) > ($1.lastActivity ?? .distantPast, $0.id)
            }
    }

    /// The pool in seat order — what the grid actually shows.
    private var live: [SessionSummary] {
        let byID = Dictionary(pool.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        let order = StableOrder.merge(current: seatOrder, incoming: pool.map(\.id))
        return order.compactMap { byID[$0] }
    }

    var body: some View {
        ScreenScaffold(
            title: "Live Now",
            subtitle: live.isEmpty
                ? "No transcript has moved in the last 15 minutes"
                : "\(live.count) active session\(live.count == 1 ? "" : "s") · transcript tails update in place · dollar values are API-rate estimates, not your bill") {
            if live.isEmpty {
                EmptyState(
                    icon: "moon.stars",
                    title: "The fleet is quiet",
                    detail: "No sessions have been active in the last 15 minutes. Tiles appear here the moment a transcript moves — no refresh needed."
                )
                .frame(minHeight: 460)
            } else {
                board
            }
        }
        // The one app-standard reorder motion — membership changes glide; a
        // surviving tile never moves at all.
        .reorderMotion(value: live.map(\.id))
        .onAppear { seatOrder = StableOrder.merge(current: seatOrder, incoming: pool.map(\.id)) }
        .onChange(of: pool.map(\.id)) { _, ids in
            let merged = StableOrder.merge(current: seatOrder, incoming: ids)
            // Compare-before-assign: an unchanged membership never republishes.
            if merged != seatOrder { seatOrder = merged }
        }
    }

    private var board: some View {
        VStack(alignment: .leading, spacing: Theme.blockGap) {
            AttentionStrip()

            Divider()

            let columns = [GridItem(.adaptive(minimum: 460), spacing: Theme.blockGap)]
            LazyVGrid(columns: columns, spacing: Theme.blockGap) {
                ForEach(live.prefix(8)) { session in
                    LiveTile(session: session)
                }
            }
            if live.count > 8 {
                Text("+ \(live.count - 8) more active — see Sessions")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
            }
        }
    }
}

// MARK: - One live tile

private struct LiveTile: View {
    @EnvironmentObject var services: AppServices
    let session: SessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                SeatMark(state: DoorLightState(attentionState), size: 8)
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text("\(session.project) · \(session.displayTitle)")
                            .font(.headline)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        TierBadge(tier: session.tier)
                    }
                    Text("\(fmtAgo(session.lastActivity)) · \(fmtUSD(session.cost)) at public API rates")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
                SessionActions(session: session, compact: true)
            }
            .padding(.horizontal, Theme.sectionGap)
            .padding(.vertical, Theme.codePadding)

            // CONTEXT-TAX strip (spree #1): every tile on the live board shows
            // what its next message re-sends, warm/cold; the advisor line
            // appears only past the visible 200k threshold (live by definition).
            if session.contextWeight > 0 {
                ContextTaxGaugeView(gauge: ContextTax.gauge(session), compact: true)
                    .padding(.horizontal, Theme.sectionGap)
                    .padding(.bottom, Theme.liveGaugeBottomInset)
            }

            Divider()

            TranscriptView(filePath: session.filePath, tailBytes: 300_000)
                .frame(height: 300)
        }
        .background {
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(Theme.cardFill)
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .contextMenu {
            Button("Inspect session") { services.inspect(session) }
        }
    }

    private var attentionState: AttentionState {
        services.attentionBoard(now: services.now).items
            .first(where: { $0.id == session.id })?.state ?? .running
    }
}
