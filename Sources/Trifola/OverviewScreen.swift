import SwiftUI
import TrifolaKit

struct OverviewHeroSnapshot {
    let usageValue: String
    let usageReading: String
    let activeCount: Int
    let activeReading: String
    let savingsValue: String
    let savingsReading: String
    let governor: BurnGovernor
    let tierStats: [TierStat]
    let tierTotal: Double
    /// Exact per-model spend rows; tiers aggregating >1 id expand into them.
    var topModelsByID: [ModelSpendStat] = []
    let liveSessions: [SessionSummary]
}

/// The judged launch-frame composition, shared by the live Overview and the
/// permanent full-window render path.
struct OverviewHeroComposition: View {
    let snapshot: OverviewHeroSnapshot
    var onOpenLiveBoard: () -> Void = {}
    var onSelectSession: (SessionSummary) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 28) {
            OverviewReadout(snapshot: snapshot)
            Card(padding: Theme.cardPadding + Theme.micro, fixedHeight: 224) {
                BurnGovernorSection(governor: snapshot.governor, showsDisclaimer: false)
            }
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: Theme.gutter) {
                    tierCard.frame(minWidth: 400)
                    liveCard.frame(minWidth: 400)
                }
                VStack(alignment: .leading, spacing: Theme.sectionGap) {
                    tierCard
                    liveCard
                }
            }
        }
    }

    private var tierCard: some View {
        // The card's height derives from its expansion: tiers holding more
        // than one model id add capped sub-rows, so the fixed frame grows
        // exactly with them instead of clipping (hero cards stay fixed-height
        // by design; this keeps that while making tiers non-opaque).
        let extra = TierSpendSection.extraRowCount(
            stats: snapshot.tierStats, modelsByID: snapshot.topModelsByID)
        return Card(padding: Theme.cardPadding + Theme.micro,
                    fixedHeight: 196 + CGFloat(extra) * TierSpendSection.subRowHeight) {
            TierSpendSection(stats: snapshot.tierStats, total: snapshot.tierTotal,
                             modelsByID: snapshot.topModelsByID)
        }
    }

    private var liveCard: some View {
        Card(padding: Theme.cardPadding + Theme.micro, fixedHeight: 196) {
            LiveNowSection(sessions: snapshot.liveSessions, limit: 3,
                           onOpenBoard: onOpenLiveBoard,
                           onSelect: onSelectSession)
        }
    }
}

/// The first-screen readout is deliberately not a three-up dashboard card. One
/// number owns the frame; the supporting facts sit on a quieter second register,
/// separated by hairlines like a piece of desktop instrumentation.
private struct OverviewReadout: View {
    let snapshot: OverviewHeroSnapshot

    var body: some View {
        HStack(alignment: .center, spacing: Theme.gutter) {
            VStack(alignment: .leading, spacing: Theme.micro) {
                Text("Recorded usage · public API rates")
                    .font(Theme.Typography.metadataMedium)
                    .foregroundStyle(Theme.muted)
                Text(snapshot.usageValue)
                    .font(Theme.Typography.heroNumber)
                    .tracking(-1.35)
                    .monospacedDigit()
                    .foregroundStyle(Theme.ink)
                    .liveNumericTransition(value: snapshot.usageValue)
                Text(snapshot.usageReading)
                    .font(Theme.Typography.metadata)
                    .foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Divider().frame(height: 76)

            StatTile(label: "Active now", value: "\(snapshot.activeCount)",
                     sub: snapshot.activeReading, live: snapshot.activeCount > 0,
                     emphasis: .supporting)
                .frame(maxWidth: 180)

            Divider().frame(height: 76)

            StatTile(label: "Cache savings", value: snapshot.savingsValue,
                     sub: snapshot.savingsReading, emphasis: .supporting)
                .frame(maxWidth: 240)
        }
        .padding(.vertical, Theme.paneInset)
        .overlay(alignment: .top) { Divider() }
        .overlay(alignment: .bottom) { Divider() }
    }
}

/// The hero dashboard: fleet vitals, tier spend split, live sessions,
/// context-weight offenders and the routing audit — one glance, whole story.
struct OverviewScreen: View {
    @EnvironmentObject var services: AppServices
    @EnvironmentObject var navigationSnapshots: NavigationSnapshotStore
    @State private var refreshRequested = false

    private var store: SessionStore { services.sessions }

    private func subtitle(_ corpus: CorpusProjection?) -> String {
        let progress = store.scanProgress
        if store.scanPresentation.isProvisional {
            return scanProgressSentence
        }
        let refreshing = progress.isInProgress ? " · \(inlineRefreshSentence)" : ""
        if isLocalCorpusMissing && store.sessions.isEmpty {
            return "Local, read-only session intelligence · refreshed \(fmtAgo(store.lastRefresh))\(refreshing)"
        }
        guard let corpus else { return "Preparing local session intelligence…" }
        // Top-level count matches the CLI's denominator; subagent transcripts are
        // disclosed, not blended — two surfaces must never disagree silently.
        let subagentCount = store.sessions.lazy.filter(\.isSubagent).count
        let topLevelCount = store.sessions.count - subagentCount
        let sessionsPart = subagentCount > 0
            ? "\(topLevelCount) sessions (+\(subagentCount) subagent runs)"
            : "\(topLevelCount) sessions"
        let base = "\(sessionsPart) across \(corpus.distinctProjectCount) projects"
        let machineCount = navigationSnapshots.fleet?.machineRollups.count ?? 1
        let fleet = machineCount > 1 ? "\(machineCount) machines · " : ""
        return "\(fleet)\(base) · refreshed \(fmtAgo(store.lastRefresh))\(refreshing) · dollar values are API-rate estimates, not your bill"
    }

    private var scanProgressSentence: String {
        store.scanProgress.readingSentence
    }

    private var inlineRefreshSentence: String {
        let progress = store.scanProgress
        guard progress.totalEstimate > 0 else { return "refreshing" }
        return "refreshing \(fmtGrouped(progress.scanned)) of ~\(fmtGrouped(progress.totalEstimate))"
    }

    private var isLocalCorpusMissing: Bool {
        services.providerCorpusPresence.isEmpty
    }

    /// The refresh control reflects ONLY a user-initiated refresh (input-origin
    /// rule). Background FSEvents scans run constantly on a busy fleet machine;
    /// letting them spin and DISABLE the manual control read as the app doing
    /// things to itself (owner live report). Background activity stays in the
    /// quiet subtitle sentence, never on the button.
    private var isRefreshing: Bool { refreshRequested }

    var body: some View {
        ScreenScaffold(
            title: "Overview",
            subtitle: subtitle(navigationSnapshots.corpus)
        ) {
            QuietTapButton(action: {
                refreshRequested = true
                services.refreshAll(refreshSelectedOpenAction: true)
            }) {
                HStack(spacing: Theme.rhythm) {
                    RefreshActivityGlyph(working: isRefreshing)
                    Text(isRefreshing ? "Refreshing…" : "Refresh")
                }
            }
            .disabled(isRefreshing)
            .accessibilityLabel(isRefreshing ? "Refreshing data" : "Refresh data")
            .accessibilityHint(isRefreshing
                ? "A session scan is in progress"
                : "Rescan sessions, skills, and audit evidence")
            .help(isRefreshing ? "Refreshing data…" : "Refresh data · \(AppCommandMap.refresh.glyph)")
        } content: {
            if store.scanPresentation.isProvisional {
                SessionReadingState(progress: store.scanProgress)
                    .frame(minHeight: 420)
            } else if let corpus = navigationSnapshots.corpus {
                verdictLine(
                    governor: corpus.burnGovernor,
                    board: navigationSnapshots.fleet?.attention)
                // First-run/loading copy is provider-aware even when files are
                // already detectable but their summaries have not hydrated yet.
                // Once any sessions are indexed, the live dashboard replaces
                // onboarding instead of leaving a permanent setup banner.
                if store.sessions.isEmpty {
                    ProviderOnboardingCallout(
                        presence: services.providerCorpusPresence)
                }
                if store.scanPresentation.showsColdScanningPlaceholder {
                    statRow(corpus).opacity(0.52)
                } else {
                    populatedContent(corpus)
                        .opacity(store.scanPresentation.isProvisional ? 0.62 : 1)
                }
            } else {
                HStack(spacing: Theme.rhythm) {
                    ProgressView().controlSize(.small)
                    Text("Building overview snapshot…")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity, minHeight: 260)
            }
        }
        .onChange(of: store.scanProgress.isInProgress) { _, inProgress in
            if !inProgress { refreshRequested = false }
        }
    }

    @ViewBuilder
    private func populatedContent(_ corpus: CorpusProjection) -> some View {
        // The launch-frame composition: verdict above, then one measured vertical
        // sequence. Fixed heights prevent surplus viewport space from entering a
        // card; any remainder settles below the final pair.
        OverviewHeroComposition(
            snapshot: OverviewHeroSnapshot(
                usageValue: fmtUSD(corpus.totalCost),
                usageReading: store.scanPresentation.isProvisional
                    ? "still counting" : "estimate from recorded usage — not your bill",
                activeCount: corpus.activeSessions.count,
                activeReading: store.scanPresentation.isProvisional
                    ? "still counting"
                    : (corpus.activeSessions.isEmpty ? "fleet is quiet" : "sessions in the last 15m"),
                savingsValue: fmtUSD(corpus.totalCacheSavings),
                savingsReading: store.scanPresentation.isProvisional
                    ? "still counting" : "vs. uncached input at API rates",
                governor: corpus.burnGovernor,
                tierStats: corpus.tierStats,
                tierTotal: corpus.totalCost,
                topModelsByID: corpus.topModelsByID,
                liveSessions: corpus.activeSessions),
            onOpenLiveBoard: { services.select(.live, origin: .programmatic) },
            onSelectSession: { services.inspect($0) })
        // ScreenScaffold contributes the first 20pt; this completes the required
        // 32pt verdict→KPI gap without inventing a second screen rhythm.
        .padding(.top, 12)

        // Secondary evidence remains available below the launch frame. It is open
        // content, never allowed to stretch the hero instruments above.
        let machineRollups = navigationSnapshots.fleet?.machineRollups ?? []
        if machineRollups.count > 1 || !services.machines.config.remotes.isEmpty {
            FleetMachinesSection(rollups: machineRollups)
            Divider()
        }
        // "Show the math" (W3): the hero's whole-corpus receipt — per-model
        // legs → Σ = the tile's number, same code path (built on expand).
        ReceiptDisclosure(storageKey: "provenance.overview-hero") {
            CostProvenance.corpusReceipt(sessions: store.sessions)
        }
        // PLAN QUOTA (W7): the REAL rate-limit windows next to the estimate
        // above — "what we think you burned" vs "what Anthropic says you
        // have left". Makes the 'resets 10am' wall predictable in advance.
        QuotaSection(snapshots: services.quota.snapshots,
                     statuses: services.quota.statuses,
                     source: services.quota.source,
                     consent: QuotaConsent(preferences: services.preferences.value),
                     now: services.now,
                     onRetry: {
                         Task {
                             await services.quota.refresh(
                                 consent: QuotaConsent(
                                     preferences: services.preferences.value),
                                 minInterval: 0)
                         }
                     })
        Divider()
        // REROUTE RECEIPTS (spree #2): fleet trend row + orchestrator-hog
        // alert. Both are evidence-gated — clean fleets render nothing.
        let rerouteReport = corpus.rerouteReport
        if !rerouteReport.days.isEmpty {
            RerouteTrendRow(report: rerouteReport, now: services.now)
            Divider()
        }
        if let hog = corpus.orchestratorHog {
            OrchestratorHogRow(alert: hog)
            Divider()
        }
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: Theme.gutter) {
                ActivitySection(counts: corpus.activityHistogram24h)
                    .frame(minWidth: 380, maxWidth: .infinity)
                Divider()
                ContextOffendersSection(
                    sessions: corpus.topContextRows,
                    onInspect: services.inspect)
                    .frame(minWidth: 380, maxWidth: .infinity)
            }
            VStack(alignment: .leading, spacing: Theme.sectionGap) {
                ActivitySection(counts: corpus.activityHistogram24h)
                Divider()
                ContextOffendersSection(
                    sessions: corpus.topContextRows,
                    onInspect: services.inspect)
            }
        }
        Divider()
        RoutingSection(audit: services.audit)
    }

    private func verdictLine(governor: BurnGovernor,
                             board: AttentionBoard?) -> some View {
        let sentence: String
        sentence = VerdictSentenceBuilder.sentence(
            board: board ?? AttentionBoard(items: [], counts: [:]),
            todayCost: governor.today.cost,
            sevenCompleteDayMean: governor.dailyRunRate)
        let parts = sentence.components(separatedBy: " · ")
        let first = parts.first ?? sentence
        let rest = parts.dropFirst().joined(separator: " · ")
        return VStack(alignment: .leading, spacing: Theme.intraCell) {
            HStack(alignment: .firstTextBaseline, spacing: 0) {
                Text(first)
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Theme.ink)
                    .liveNumericTransition(value: first)
                if !rest.isEmpty {
                    Text(" · \(rest)")
                        .font(Theme.Typography.body)
                        .foregroundStyle(Theme.muted)
                        .liveNumericTransition(value: rest)
                }
            }
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.intraCell) {
                ArtifactPill(icon: "square.grid.3x3", name: "Fleet Board") {
                    services.select(.fleet, origin: .programmatic)
                }
                ArtifactPill(icon: "doc.text.magnifyingglass", name: "Audit evidence") {
                    services.select(.audit, origin: .programmatic)
                }
            }
        }
        .frame(maxWidth: ScreenScaffoldMetrics.proseMaxWidth, alignment: .leading)
    }

    private func statRow(_ corpus: CorpusProjection) -> some View {
        StatRow {
            StatTile(label: "Usage at API rates",
                     value: fmtUSD(corpus.totalCost),
                     sub: store.scanPresentation.isProvisional ? "still counting" : "estimate from recorded usage — not your bill")
            Divider()
            StatTile(label: "Active now",
                     value: "\(corpus.activeSessions.count)",
                     sub: store.scanPresentation.isProvisional
                        ? "still counting"
                        : (corpus.activeSessions.isEmpty ? "fleet is quiet" : "sessions in the last 15m"),
                     live: !corpus.activeSessions.isEmpty)
            Divider()
            StatTile(label: "Cache savings — net of write premiums",
                     value: fmtUSD(corpus.totalCacheSavings),
                     sub: store.scanPresentation.isProvisional ? "still counting" : "vs. uncached input at API rates")
        }
    }
}

/// Pure provider-state view so parity renders can exercise none / Claude-only /
/// Codex-only / both without constructing a live `AppServices` graph.
struct ProviderOnboardingCallout: View {
    let presence: ProviderCorpusPresence

    var body: some View {
        let copy = presence.onboardingCopy
        CalloutPanel(tone: Theme.graphite) {
            VStack(alignment: .leading, spacing: 3) {
                Text(copy.headline)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.ink)
                Text(copy.detail)
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// DQ-24: the refresh control remains in place while work runs. Motion-capable
/// users get a deterministic rotation driven by time (no stateful repeat loop);
/// Reduce Motion gets a static hourglass swap.
struct RefreshActivityGlyph: View {
    let working: Bool
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        if working && !reduceMotion {
            TimelineView(AnimationTimelineSchedule(minimumInterval: 1 / 30)) { context in
                let phase = context.date.timeIntervalSinceReferenceDate
                    .truncatingRemainder(dividingBy: 0.8) / 0.8
                Image(systemName: "arrow.clockwise")
                    .rotationEffect(.degrees(phase * 360))
            }
        } else {
            Image(systemName: working ? "hourglass" : "arrow.clockwise")
        }
    }
}

// MARK: - Tier spend

struct TierSpendSection: View {
    let stats: [TierStat]
    let total: Double
    /// Exact per-model rows (already aggregated in the corpus snapshot). When
    /// present, each tier expands into the model ids composing it — so "Codex"
    /// names sol/terra/luna and "Other" names exactly what it holds, instead
    /// of tiers being opaque buckets (owner: "not until we figure out exactly
    /// what Other is").
    var modelsByID: [ModelSpendStat] = []

    /// At most this many named sub-rows per tier; the tail folds into one
    /// "+N more" line so a many-model tier can't swallow the card.
    static let subRowCap = 4
    /// Sub-row line height for the card's derived fixed height.
    static let subRowHeight: CGFloat = 19

    static func members(of tier: ModelTier,
                        in modelsByID: [ModelSpendStat]) -> [ModelSpendStat] {
        modelsByID.filter { ModelTier(raw: $0.model) == tier }
    }

    /// Total extra rows (named + fold line) the section renders below the tier
    /// rows — the card uses this to derive its fixed height.
    static func extraRowCount(stats: [TierStat],
                              modelsByID: [ModelSpendStat]) -> Int {
        stats.reduce(0) { count, st in
            let n = members(of: st.tier, in: modelsByID).count
            guard n > 1 else { return count }
            return count + min(n, subRowCap) + (n > subRowCap ? 1 : 0)
        }
    }

    private func members(of tier: ModelTier) -> [ModelSpendStat] {
        Self.members(of: tier, in: modelsByID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionGap) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("API-rate estimate by model tier")
                Spacer()
                Text(fmtUSD(total))
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
                    .liveNumericTransition(value: fmtUSD(total))
            }
            TierSplitBar(stats: stats)
            VStack(spacing: Theme.rhythm) {
                ForEach(stats) { st in
                    tierRow(st)
                    // Sub-rows appear when a tier aggregates MORE THAN ONE
                    // model id — a single-model tier's row already names it
                    // implicitly, and Opus/Sonnet/Haiku stay single-line.
                    let ids = members(of: st.tier)
                    if ids.count > 1 {
                        ForEach(ids.prefix(Self.subRowCap)) { row in
                            modelSubRow(row)
                        }
                        if ids.count > Self.subRowCap {
                            let tail = ids.dropFirst(Self.subRowCap)
                            let tailCost = tail.reduce(0) { $0 + $1.cost }
                            HStack(spacing: 8) {
                                Text("+\(tail.count) more")
                                    .font(Theme.Typography.metadata)
                                    .foregroundStyle(Theme.faint)
                                    .padding(.leading, 14)
                                Spacer()
                                Text(fmtUSD(tailCost))
                                    .font(Theme.Typography.metadata)
                                    .foregroundStyle(Theme.faint)
                                Color.clear.frame(width: 42, height: 1)
                            }
                        }
                    }
                }
            }
        }
    }

    private func tierRow(_ st: TierStat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Circle().fill(st.tier.color).frame(width: 6, height: 6)
            Text(st.tier.label)
                .font(.subheadline)
                .foregroundStyle(Theme.ink)
            Text("\(st.sessions) sessions · \(fmtTokens(st.tokens)) tokens excluding cache reads")
                .font(.footnote)
                .foregroundStyle(Theme.muted)
                .liveNumericTransition(
                    value: "\(st.sessions)|\(fmtTokens(st.tokens))")
            Spacer()
            Text(fmtUSD(st.cost))
                .font(.subheadline.weight(.medium))
                .foregroundStyle(Theme.ink)
                .liveNumericTransition(value: fmtUSD(st.cost))
            Text(total > 0 ? fmtPct(st.cost / total) : "—")
                .font(.footnote)
                .foregroundStyle(Theme.muted)
                .frame(width: 42, alignment: .trailing)
                .liveNumericTransition(
                    value: total > 0 ? fmtPct(st.cost / total) : "—")
        }
    }

    private func modelSubRow(_ row: ModelSpendStat) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(row.model)
                .font(Theme.Typography.metadata.monospaced())
                .foregroundStyle(Theme.muted)
                .padding(.leading, 14)   // optically under the tier dot
            Text(row.pricedByExactRate
                 ? "\(row.sessions) sessions"
                 : "\(row.sessions) sessions · est. rate")
                .font(Theme.Typography.metadata)
                .foregroundStyle(Theme.faint)
            Spacer()
            Text(fmtUSD(row.cost))
                .font(Theme.Typography.metadata)
                .foregroundStyle(Theme.muted)
                .liveNumericTransition(value: fmtUSD(row.cost))
            Text(total > 0 ? fmtPct(row.cost / total) : "—")
                .font(Theme.Typography.metadata)
                .foregroundStyle(Theme.faint)
                .frame(width: 42, alignment: .trailing)
        }
    }
}

// MARK: - 24h activity histogram

private struct ActivitySection: View {
    let counts: [Int]

    private var buckets: [Double] {
        let values = counts.map(Double.init)
        let peak = max(values.max() ?? 1, 1)
        return values.map { $0 / peak }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionGap) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("Session activity")
                Spacer()
                Text("last 24h, by last touch")
                    .font(.caption2)
                    .foregroundStyle(Theme.faint)
            }
            BarStrip(values: buckets, color: Theme.graphite, height: 40, currentIndex: 23)
            HStack {
                Text("-24h").font(.caption2).foregroundStyle(Theme.faint)
                Spacer()
                Text("now").font(.caption2).foregroundStyle(Theme.faint)
            }
        }
    }
}

// MARK: - Live now

struct LiveNowSection: View {
    let sessions: [SessionSummary]
    var limit = 5
    var onOpenBoard: () -> Void = {}
    var onSelect: (SessionSummary) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.rhythm) {
            HStack(spacing: 8) {
                SectionLabel("Live now")
                Spacer()
                ArtifactPill(icon: "dot.radiowaves.left.and.right", name: "Live board") {
                    onOpenBoard()
                }
            }
            // Deterministic tiebreaker + the one reorder motion (W6 wave 4).
            let live = Array(sessions
                .sorted { ($0.lastActivity ?? .distantPast, $1.id) > ($1.lastActivity ?? .distantPast, $0.id) }
                .prefix(limit))
            if live.isEmpty {
                Text("No sessions active in the last 15 minutes.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
                    .padding(.vertical, Theme.rhythm)
            } else {
                VStack(spacing: 0) {
                    ForEach(live) { s in
                        HoverRow {
                            onSelect(s)
                        } content: {
                            HStack(spacing: 8) {
                                SeatMark(state: .running, size: 8)
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 6) {
                                        Text("\(s.project) · \(s.displayTitle)")
                                            .font(.subheadline.weight(.medium))
                                            .foregroundStyle(Theme.ink)
                                            .lineLimit(1)
                                        if s.isRemote {
                                            MachineChip(machineID: s.machineID, compact: true)
                                        }
                                    }
                                    Text("\(s.tier.label) · \(fmtAgo(s.lastActivity))")
                                        .font(.caption)
                                        .foregroundStyle(Theme.muted)
                                }
                                Spacer()
                                VStack(alignment: .trailing, spacing: 1) {
                                    Text(fmtUSD(s.cost))
                                        .font(.subheadline)
                                        .foregroundStyle(Theme.muted)
                                        .liveNumericTransition(value: fmtUSD(s.cost))
                                    Text("API-rate estimate")
                                        .font(.caption2)
                                        .foregroundStyle(Theme.muted)
                                }
                            }
                            .padding(.horizontal, Theme.rhythm)
                            .padding(.vertical, Theme.rowVerticalInset)
                        }
                        .motionRowTransition()
                    }
                }
                .reorderMotion(value: live.map(\.id))
            }
        }
    }
}

// MARK: - Context weight offenders

private struct ContextOffendersSection: View {
    let sessions: [SessionSummary]
    var onInspect: (SessionSummary) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.rhythm) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("Heaviest context")
                Spacer()
                Text("tokens re-sent per message")
                    .font(.caption2)
                    .foregroundStyle(Theme.muted)
            }
            if sessions.isEmpty {
                Text("Nothing parsed yet.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
            } else {
                VStack(spacing: 0) {
                    ForEach(sessions) { s in
                        HoverRow {
                            onInspect(s)
                        } content: {
                            HStack(spacing: 8) {
                                SeatMark(state: s.isActive ? .running : .idle, size: 8)
                                VStack(alignment: .leading, spacing: 1) {
                                    Text("\(s.project) · \(s.displayTitle) · \(fmtAgo(s.lastActivity))")
                                        .font(.subheadline)
                                        .foregroundStyle(Theme.ink)
                                        .lineLimit(1)
                                    // Warm-cache estimate weighted by the session's observed
                                    // hit rate — NOT the flat fresh-input worst case, which
                                    // overstated warm sessions by up to 10×.
                                    Text("≈\(fmtUSD(s.costPerMessage))/message at API rates · \(fmtPct(s.usage.cacheHitRate)) cached")
                                        .font(.caption)
                                        .foregroundStyle(Theme.muted)
                                }
                                Spacer()
                                ContextBar(weight: s.contextWeight)
                            }
                            .padding(.horizontal, Theme.rhythm)
                            .padding(.vertical, Theme.rowVerticalInset)
                        }
                    }
                }
            }
        }
    }
}

// MARK: - Cross-Machine Fleet (fleet-wide totals + calm offline indicator)

/// The differentiator, one glance: fleet-wide totals across every machine ("2
/// machines · N sessions · $X today"), a per-machine roll-up row, and — calm, never
/// a nag — an offline line for any configured remote that isn't contributing.
struct FleetMachinesSection: View {
    @EnvironmentObject var services: AppServices
    let rollups: [MachineRollup]

    private var totalSessions: Int { rollups.reduce(0) { $0 + $1.sessionCount } }
    private var totalCost: Double { rollups.reduce(0) { $0 + $1.cost } }
    private var machineCount: Int { rollups.count }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionGap) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                SectionLabel("Fleet")
                Text("\(machineCount) machine\(machineCount == 1 ? "" : "s") · \(totalSessions) sessions · \(fmtUSD(totalCost)) API-rate estimate today")
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                Spacer()
                Text("one pane over every machine, read-only over Tailscale")
                    .font(.caption2)
                    .foregroundStyle(Theme.muted)
            }
            // Per-machine roll-up — each contributing machine's slice of the fleet.
            VStack(spacing: Theme.rhythm) {
                ForEach(rollups) { r in
                    HStack(spacing: 8) {
                        MachineChip(machineID: r.machine.id)
                        Text(r.machine.name)
                            .font(.subheadline)
                            .foregroundStyle(Theme.ink)
                        if r.activeCount > 0 {
                            Text("\(r.activeCount) active")
                                .font(.caption)
                                .foregroundStyle(Theme.green)
                        }
                        Spacer()
                        Text("\(r.sessionCount) sessions · \(fmtTokens(r.tokens)) tokens")
                            .font(.caption)
                            .foregroundStyle(Theme.muted)
                        Text(fmtUSD(r.cost))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.ink)
                            .frame(minWidth: 56, alignment: .trailing)
                    }
                }
            }
            // Calm offline indicators for configured-but-absent remotes.
            let offline = services.machines.offlineIndicators
            if !offline.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(offline) { RemoteStatusLine(status: $0) }
                }
                .padding(.top, Theme.micro / 2)
            }
        }
    }
}

// MARK: - Routing audit

private struct RoutingSection: View {
    @ObservedObject var audit: RoutingAudit

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionGap) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("Routing audit")
                Spacer()
                Text("default model: \(audit.defaultModel)")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
            }
            if audit.flags.isEmpty {
                Text("No findings.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
            } else {
                VStack(alignment: .leading, spacing: Theme.sectionGap) {
                    ForEach(audit.flags) { FlagRow(flag: $0) }
                }
            }
        }
    }
}
