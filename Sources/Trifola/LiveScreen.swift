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
        Group {
            if live.isEmpty {
                EmptyState(
                    icon: "moon.stars",
                    title: "The fleet is quiet",
                    detail: "No sessions have been active in the last 15 minutes. Tiles appear here the moment a transcript moves — no refresh needed."
                )
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
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text("Live Now")
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(Theme.ink)
                            SeatMark(fill: Theme.green, size: 7)
                        }
                        Text("\(live.count) active session\(live.count == 1 ? "" : "s") · tailing transcripts in real time")
                            .font(.subheadline)
                            .foregroundStyle(Theme.muted)
                    }
                    Spacer()
                }
                .padding(.top, 4)

                AttentionStrip()

                Divider()

                let columns = [GridItem(.adaptive(minimum: 460), spacing: 16)]
                LazyVGrid(columns: columns, spacing: 16) {
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
            .screenScaffoldFrame()
        }
        .scrollIndicators(.never)
    }
}

// MARK: - One live tile

private struct LiveTile: View {
    @EnvironmentObject var services: AppServices
    let session: SessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 8) {
                        Text(session.displayTitle)
                            .font(.headline)
                            .foregroundStyle(Theme.ink)
                            .lineLimit(1)
                        TierBadge(tier: session.tier)
                    }
                    Text("\(session.project) · \(fmtAgo(session.lastActivity)) · \(fmtUSD(session.cost)) session-to-date")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                }
                Spacer()
                SessionActions(session: session, compact: true)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)

            // CONTEXT-TAX strip (spree #1): every tile on the live board shows
            // what its next message re-sends, warm/cold; the advisor line
            // appears only past the visible 200k threshold (live by definition).
            if session.contextWeight > 0 {
                ContextTaxGaugeView(gauge: ContextTax.gauge(session), compact: true)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 9)
            }

            Divider()

            TranscriptView(filePath: session.filePath, tailBytes: 300_000)
                .frame(height: 300)
        }
        .background {
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .contextMenu {
            Button("Inspect session") { services.inspect(session) }
        }
    }
}
