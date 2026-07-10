import SwiftUI
import TrifolaKit

/// The fleet browser: search + tier/state filters + sortable session list on
/// the left, live inspector on the right.
struct SessionsScreen: View {
    @EnvironmentObject var services: AppServices

    enum SortKey: String, CaseIterable, Identifiable {
        case recent = "Recent", cost = "Cost", context = "Context", tokens = "Tokens"
        var id: String { rawValue }
    }

    @State private var query = ""
    @State private var tierFilter: ModelTier? = nil
    @State private var machineFilter: String? = nil
    @State private var activeOnly = false
    @State private var heavyOnly = false
    @State private var sort: SortKey = .recent

    private var filtered: [SessionSummary] {
        var out = services.sessions.sessions
        if let tierFilter { out = out.filter { $0.tier == tierFilter } }
        if let machineFilter { out = out.filter { $0.machineID == machineFilter } }
        if activeOnly { out = out.filter(\.isActive) }
        if heavyOnly { out = out.filter(\.isContextHeavy) }
        if !query.isEmpty {
            let q = query.lowercased()
            out = out.filter {
                $0.project.lowercased().contains(q)
                    || $0.cwd.lowercased().contains(q)
                    || $0.id.lowercased().hasPrefix(q)
            }
        }
        // Deterministic ties (W6 wave 4): Swift's sort is not stable — without a
        // tiebreaker, equal-valued rows can swap places on every recompute (each
        // heartbeat tick), which reads as rows flapping for no reason.
        switch sort {
        case .recent: out.sort { ($0.lastActivity ?? .distantPast, $1.id) > ($1.lastActivity ?? .distantPast, $0.id) }
        case .cost:
            // Decorate-sort-undecorate over INDICES: the comparator must not
            // recompute `cost` O(n log n) times (measured ~290ms of main-thread
            // stall per body pass over 5.3k sessions), and it must not move the
            // heavy SessionSummary structs through every swap either — sort the
            // (cost, id, index) keys, then reorder once.
            let keys = out.enumerated()
                .map { (i: $0.offset, c: $0.element.cost, id: $0.element.id) }
                .sorted { ($0.c, $1.id) > ($1.c, $0.id) }
            out = keys.map { out[$0.i] }
        case .context: out.sort { ($0.contextWeight, $1.id) > ($1.contextWeight, $0.id) }
        case .tokens: out.sort { ($0.usage.total, $1.id) > ($1.usage.total, $0.id) }
        }
        return out
    }

    var body: some View {
        HStack(spacing: 0) {
            listColumn
                .frame(width: 430)
            Divider()
            inspector
                .frame(maxWidth: .infinity)
        }
    }

    // MARK: List column

    private var listColumn: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: Theme.sectionGap) {
                Text("Sessions")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(Theme.ink)
                    .padding(.top, ScreenScaffoldMetrics.topInset)

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                    TextField("Search project, path or id…", text: $query)
                        .textFieldStyle(.plain)
                        .font(.subheadline)
                        .foregroundStyle(Theme.ink)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 6)
                .background {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Theme.hairline, lineWidth: 1)
                }

                ScrollView(.horizontal) {
                    HStack(spacing: 6) {
                        FilterChip(label: "Active", isOn: activeOnly) {
                            activeOnly.toggle()
                        }
                        FilterChip(label: "Heavy ctx", isOn: heavyOnly) {
                            heavyOnly.toggle()
                        }
                        // Machine filter — only when the fleet spans more than one
                        // machine, so single-machine users see zero cross-machine chrome.
                        if services.isCrossMachine {
                            ForEach(services.sessions.fleetMachines) { m in
                                FilterChip(label: m.chipLabel, isOn: machineFilter == m.id) {
                                    machineFilter = machineFilter == m.id ? nil : m.id
                                }
                            }
                        }
                        ForEach(ModelTier.allCases.filter { $0 != .other }, id: \.self) { tier in
                            FilterChip(label: tier.label, isOn: tierFilter == tier) {
                                tierFilter = tierFilter == tier ? nil : tier
                            }
                        }
                    }
                }
                .scrollIndicators(.never)

                HStack {
                    Text("\(filtered.count) shown")
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                    Spacer()
                    Picker("", selection: $sort) {
                        ForEach(SortKey.allCases) { Text($0.rawValue).tag($0) }
                    }
                    .pickerStyle(.menu)
                    .controlSize(.small)
                    .fixedSize()
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 8)

            Divider()

            ScrollViewReader { proxy in
                let shown = Array(filtered.prefix(400))
                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(shown) { s in
                            SessionRow(session: s, isSelected: services.selectedSessionID == s.id)
                                .id(s.id)
                        }
                        if filtered.count > 400 {
                            Text("Showing first 400 — refine the search to narrow down.")
                                .font(.caption)
                                .foregroundStyle(Theme.faint)
                                .padding(.vertical, 10)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.top, 8)
                    .padding(.bottom, 20)
                    // The one app-standard reorder motion (W6 wave 4): when a rank
                    // genuinely changes, the row glides — never teleports. Keyed on
                    // the id order so in-place value updates animate nothing.
                    .reorderMotion(value: shown.map(\.id))
                }
                .scrollIndicators(.never)
                .onAppear {
                    if let id = services.selectedSessionID {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    // MARK: Inspector

    @ViewBuilder
    private var inspector: some View {
        if let session = services.selectedSession {
            SessionInspector(session: session)
                .id(session.id)
        } else {
            EmptyState(
                icon: "square.stack.3d.up",
                title: "Pick a session",
                detail: "Select any session on the left to see its live transcript, token economics and hand-off controls.")
        }
    }
}

// MARK: - Row
// Selection uses the system selection background and the text flips to the
// selection text color — the exact CodexBar highlight cascade.

private struct SessionRow: View {
    @EnvironmentObject var services: AppServices
    let session: SessionSummary
    let isSelected: Bool

    private var primary: Color { isSelected ? Theme.selectionText : Theme.ink }
    private var secondary: Color { isSelected ? Theme.selectionText.opacity(0.8) : Theme.muted }

    var body: some View {
        HoverRow {
            services.selectedSessionID = session.id
        } content: {
            HStack(spacing: 8) {
                // The door light (UI_GRIND §2.1): state fill + 1pt tier ring —
                // never a tier-colored disc (which read as an alarm in the app's
                // own dot language). Stays lit through selection, like the palette.
                SeatMark(fill: session.isActive ? Theme.green : Theme.faint,
                         ring: session.tier.color, size: 7)
                VStack(alignment: .leading, spacing: 1) {
                    HStack(spacing: 6) {
                        Text(session.displayTitle)
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(primary)
                            .lineLimit(1)
                        if services.isCrossMachine {
                            MachineChip(machineID: session.machineID)
                        }
                    }
                    Text("\(session.project) · \(session.tier.label) · \(session.messageCount) msgs · \(fmtAgo(session.lastActivity))")
                        .font(.caption)
                        .foregroundStyle(secondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                VStack(alignment: .trailing, spacing: 1) {
                    Text(fmtUSD(session.cost))
                        .font(.subheadline)
                        .foregroundStyle(primary)
                    if session.isContextHeavy {
                        Text("\(fmtTokens(session.contextWeight)) ctx")
                            .font(.caption2)
                            .foregroundStyle(isSelected ? Theme.selectionText.opacity(0.8) : Theme.red)
                    }
                }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
        }
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(Theme.selectionBG)
            }
        }
    }
}

// MARK: - Inspector detail

private struct SessionInspector: View {
    let session: SessionSummary

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            // header
            VStack(alignment: .leading, spacing: Theme.rhythm) {
                HStack(spacing: 8) {
                    // The door light has an idle rendering (faint fill) — absence
                    // was a third, unsanctioned state (UI_GRIND CLB-3).
                    SeatMark(fill: session.isActive ? Theme.green : Theme.faint,
                             ring: session.tier.color, size: 7)
                    Text(session.displayTitle)
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                        .lineLimit(1)
                    TierBadge(tier: session.tier)
                    if session.isRemote {
                        MachineChip(machineID: session.machineID)
                    }
                    Spacer()
                }
                Text(session.cwd.isEmpty ? "no working directory recorded" : session.cwd)
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                    .lineLimit(1)
                    .truncationMode(.head)
                    .textSelection(.enabled)
                SessionActions(session: session)
            }
            .padding(.top, ScreenScaffoldMetrics.topInset)

            Divider()

            // economics strip
            StatRow {
                InspectorStat(label: "Est. cost", value: fmtUSD(session.cost))
                Divider()
                InspectorStat(label: "Messages", value: "\(session.messageCount)")
                Divider()
                InspectorStat(label: "Total tokens", value: fmtTokens(session.usage.total))
                Divider()
                InspectorStat(label: "Cache hit", value: fmtPct(session.usage.cacheHitRate))
                Divider()
                InspectorStat(label: "Ctx / msg", value: fmtTokens(session.contextWeight))
            }

            // CONTEXT-TAX GAUGE (spree #1): what the next message re-sends,
            // priced warm/cold at this session's own model rates. The advisor
            // line rides inside the gauge — live + over-threshold only.
            if session.contextWeight > 0 {
                ContextTaxGaugeView(gauge: ContextTax.gauge(session))
            }

            // REROUTE RECEIPTS (spree #2): mid-session model flips with the
            // /model switches honestly excluded. Clean sessions render nothing.
            if let rerouteReceipt = Reroutes.receipt(for: session) {
                RerouteReceiptView(receipt: rerouteReceipt)
            }

            Divider()

            SectionLabel("Live transcript")
            TranscriptView(filePath: session.filePath)
                .frame(maxHeight: .infinity)
        }
        .padding(.horizontal, Theme.gutter)
        .padding(.bottom, 16)
    }
}

private struct InspectorStat: View {
    let label: String
    let value: String

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.muted)
            Text(value)
                .font(.headline)
                .foregroundStyle(Theme.ink)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
