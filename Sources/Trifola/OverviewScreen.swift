import SwiftUI
import TrifolaKit

/// The hero dashboard: fleet vitals, tier spend split, live sessions,
/// context-weight offenders and the routing audit — one glance, whole story.
struct OverviewScreen: View {
    @EnvironmentObject var services: AppServices

    private var store: SessionStore { services.sessions }

    private var subtitle: String {
        let progress = store.scanProgress
        if progress.isInProgress {
            if progress.totalEstimate > 0 {
                return "Scanning — \(fmtGrouped(progress.scanned)) of ~\(fmtGrouped(progress.totalEstimate)) transcripts…"
            }
            return "Scanning transcripts…"
        }
        if isLocalCorpusMissing && store.sessions.isEmpty {
            return "Local, read-only session intelligence · refreshed \(fmtAgo(store.lastRefresh))"
        }
        // Distinct-project COUNT only — `projectSpend` also prices every
        // session (a full cost rollup per body pass) just to be counted here.
        let projects = Set(store.sessions.map(\.project)).count
        let base = "\(store.sessions.count) sessions across \(projects) projects"
        let fleet = services.isCrossMachine && store.machineCount > 1
            ? "\(store.machineCount) machines · " : ""
        return "\(fleet)\(base) · refreshed \(fmtAgo(store.lastRefresh)) · dollar values are API-rate estimates, not your bill"
    }

    private var isLocalCorpusMissing: Bool {
        !services.hasLocalClaudeCorpus
    }

    var body: some View {
        ScreenScaffold(
            title: "Overview",
            subtitle: subtitle
        ) {
            QuietTapButton(shortcut: KeyboardShortcut("r", modifiers: .command), action: {
                services.refreshAll()
            }) {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
        } content: {
            let governor = store.burnGovernor(now: services.now)
            verdictLine(governor: governor)
            if isLocalCorpusMissing {
                CalloutPanel(tone: Theme.graphite) {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Waiting on your first Claude Code session")
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.ink)
                        Text("Trifola reads ~/.claude/projects — it appears after your first claude run. Nothing to configure; nothing leaves this machine.")
                            .font(.footnote)
                            .foregroundStyle(Theme.muted)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if store.scanProgress.isInProgress {
                statRow.opacity(0.52)
                HStack(spacing: Theme.intraCell) {
                    ProgressView().controlSize(.small)
                    Text("Still counting. Aggregate tables appear only after the scan settles, so a partial total never presents as final.")
                        .font(.footnote)
                        .foregroundStyle(Theme.muted)
                }
            } else {
                AttentionStrip()
                if services.isCrossMachine {
                    FleetMachinesSection()
                    Divider()
                }
                statRow
            // "Show the math" (W3): the hero's whole-corpus receipt — per-model
            // legs → Σ = the tile's number, same code path (built on expand).
            ReceiptDisclosure(storageKey: "provenance.overview-hero") {
                CostProvenance.corpusReceipt(sessions: store.sessions)
            }
            Divider()
            BurnGovernorSection(governor: governor, receipt: {
                CostProvenance.dayReceipt(
                    sessions: store.sessions,
                    dayKey: CostProvenance.dayKey(for: services.now),
                    footnotes: [CostProvenance.projectionFootnote(governor)])
            }, showsDisclaimer: false)
            Divider()
            // PLAN QUOTA (W7): the REAL rate-limit windows next to the estimate
            // above — "what we think you burned" vs "what Anthropic says you
            // have left". Makes the 'resets 10am' wall predictable in advance.
            QuotaSection(snapshot: services.quota.snapshot,
                         status: services.quota.status,
                         source: services.quota.source,
                         now: services.now,
                         onRetry: {
                             Task { await services.quota.refresh(minInterval: 0) }
                         })
            Divider()
            // REROUTE RECEIPTS (spree #2): fleet trend row + orchestrator-hog
            // alert. Both are evidence-gated — clean fleets render nothing.
            let rerouteReport = Reroutes.build(sessions: store.sessions)
            if !rerouteReport.days.isEmpty {
                RerouteTrendRow(report: rerouteReport, now: services.now)
                Divider()
            }
            if let hog = OrchestratorHog.alert(
                sessions: store.sessions,
                day: CostProvenance.dayKey(for: services.now)) {
                OrchestratorHogRow(alert: hog)
                Divider()
            }
            HStack(alignment: .top, spacing: Theme.gutter) {
                VStack(alignment: .leading, spacing: 16) {
                    TierSpendSection(stats: store.tierStats, total: store.totalCost)
                    Divider()
                    ActivitySection(sessions: store.sessions, now: services.now)
                }
                .frame(maxWidth: .infinity)
                Divider()
                VStack(alignment: .leading, spacing: 16) {
                    LiveNowSection()
                    Divider()
                    ContextOffendersSection()
                }
                .frame(maxWidth: .infinity)
            }
            Divider()
                RoutingSection(audit: services.audit)
            }
        }
    }

    private func verdictLine(governor: BurnGovernor) -> some View {
        let board = services.alertingAttentionBoard(now: services.now)
        let progress = store.scanProgress
        let sentence: String
        if progress.isInProgress {
            sentence = progress.totalEstimate > 0
                ? "Scanning — \(fmtGrouped(progress.scanned)) of ~\(fmtGrouped(progress.totalEstimate)) transcripts…"
                : "Scanning transcripts…"
        } else {
            sentence = VerdictSentenceBuilder.sentence(
                board: board,
                todayCost: governor.today.cost,
                sevenCompleteDayMean: governor.dailyRunRate)
        }
        let parts = sentence.components(separatedBy: " · ")
        let first = parts.first ?? sentence
        let rest = parts.dropFirst().joined(separator: " · ")
        return VStack(alignment: .leading, spacing: Theme.intraCell) {
            HStack(spacing: 0) {
                Text(first)
                    .foregroundStyle(Theme.ink)
                if !rest.isEmpty {
                    Text(" · \(rest)").foregroundStyle(Theme.muted)
                }
            }
            .font(.title3)
            .fixedSize(horizontal: false, vertical: true)
            HStack(spacing: Theme.intraCell) {
                ArtifactPill(icon: "square.grid.3x3", name: "Fleet Board") {
                    services.section = .fleet
                }
                ArtifactPill(icon: "doc.text.magnifyingglass", name: "Audit evidence") {
                    services.section = .audit
                }
            }
        }
        .frame(maxWidth: ScreenScaffoldMetrics.proseMaxWidth, alignment: .leading)
    }

    private var statRow: some View {
        StatRow {
            StatTile(label: "Usage at API rates",
                     value: fmtUSD(store.totalCost),
                     sub: store.scanProgress.isInProgress ? "still counting" : "estimate from recorded usage — not your bill")
            Divider()
            StatTile(label: "Active now",
                     value: "\(store.activeSessions.count)",
                     sub: store.scanProgress.isInProgress
                        ? "still counting"
                        : (store.activeSessions.isEmpty ? "fleet is quiet" : "sessions in the last 15m"),
                     live: !store.activeSessions.isEmpty)
            Divider()
            StatTile(label: "Cache savings — net of write premiums",
                     value: fmtUSD(store.totalCacheSavings),
                     sub: store.scanProgress.isInProgress ? "still counting" : "vs. uncached input at API rates")
        }
    }
}

// MARK: - Tier spend

private struct TierSpendSection: View {
    let stats: [TierStat]
    let total: Double

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionGap) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("API-rate estimate by model tier")
                Spacer()
                Text(fmtUSD(total))
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
            }
            TierSplitBar(stats: stats)
            VStack(spacing: Theme.rhythm) {
                ForEach(stats) { st in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Circle().fill(st.tier.color).frame(width: 6, height: 6)
                        Text(st.tier.label)
                            .font(.subheadline)
                            .foregroundStyle(Theme.ink)
                        Text("\(st.sessions) sessions · \(fmtTokens(st.tokens)) tokens excluding cache reads")
                            .font(.footnote)
                            .foregroundStyle(Theme.faint)
                        Spacer()
                        Text(fmtUSD(st.cost))
                            .font(.subheadline.weight(.medium))
                            .foregroundStyle(Theme.ink)
                        Text(total > 0 ? fmtPct(st.cost / total) : "—")
                            .font(.footnote)
                            .foregroundStyle(Theme.muted)
                            .frame(width: 42, alignment: .trailing)
                    }
                }
            }
        }
    }
}

// MARK: - 24h activity histogram

private struct ActivitySection: View {
    let sessions: [SessionSummary]
    let now: Date

    private var buckets: [Double] {
        var b = [Double](repeating: 0, count: 24)
        for s in sessions {
            guard let t = s.lastActivity else { continue }
            let hours = now.timeIntervalSince(t) / 3600
            guard hours >= 0, hours < 24 else { continue }
            b[23 - Int(hours)] += 1
        }
        let peak = max(b.max() ?? 1, 1)
        return b.map { $0 / peak }
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

private struct LiveNowSection: View {
    @EnvironmentObject var services: AppServices

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.rhythm) {
            HStack(spacing: 8) {
                SectionLabel("Live now")
                if !services.sessions.activeSessions.isEmpty { SeatMark(size: 6) }
                Spacer()
                ArtifactPill(icon: "dot.radiowaves.left.and.right", name: "Live board") {
                    services.section = .live
                }
            }
            // Deterministic tiebreaker + the one reorder motion (W6 wave 4).
            let live = Array(services.sessions.activeSessions
                .sorted { ($0.lastActivity ?? .distantPast, $1.id) > ($1.lastActivity ?? .distantPast, $0.id) }
                .prefix(5))
            if live.isEmpty {
                Text("No sessions active in the last 15 minutes.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
                    .padding(.vertical, Theme.rhythm)
            } else {
                VStack(spacing: 0) {
                    ForEach(live) { s in
                        HoverRow {
                            services.inspect(s)
                        } content: {
                            HStack(spacing: 8) {
                                SeatMark(fill: Theme.green, size: 6)
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
                                    Text("API-rate estimate")
                                        .font(.caption2)
                                        .foregroundStyle(Theme.faint)
                                }
                            }
                            .padding(.horizontal, Theme.rhythm)
                            .padding(.vertical, Theme.rowVerticalInset)
                        }
                    }
                }
                .reorderMotion(value: live.map(\.id))
            }
        }
    }
}

// MARK: - Context weight offenders

private struct ContextOffendersSection: View {
    @EnvironmentObject var services: AppServices

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.rhythm) {
            HStack(alignment: .firstTextBaseline) {
                SectionLabel("Heaviest context")
                Spacer()
                Text("tokens re-sent per message")
                    .font(.caption2)
                    .foregroundStyle(Theme.faint)
            }
            // contextHeavy already excludes subagent transcripts and sorts by
            // weight; fall back to the heaviest real sessions when nothing
            // crosses the 200k "heavy" threshold so the card never sits empty.
            let pool = services.sessions.contextHeavy.isEmpty
                ? services.sessions.sessions
                    .filter { !$0.isSubagent }
                    .sorted { $0.contextWeight > $1.contextWeight }
                : services.sessions.contextHeavy
            let heavy = Array(pool.prefix(5))
            if heavy.isEmpty {
                Text("Nothing parsed yet.")
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
            } else {
                VStack(spacing: 0) {
                    ForEach(heavy) { s in
                        HoverRow {
                            services.inspect(s)
                        } content: {
                            HStack(spacing: 8) {
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

    private var rollups: [MachineRollup] { services.sessions.machineRollups }

    private var totalSessions: Int { rollups.reduce(0) { $0 + $1.sessionCount } }
    private var totalCost: Double { rollups.reduce(0) { $0 + $1.cost } }
    private var machineCount: Int { services.sessions.machineCount }

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
                    .foregroundStyle(Theme.faint)
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
                            SeatMark(fill: Theme.green, size: 6)
                            Text("\(r.activeCount) active")
                                .font(.caption)
                                .foregroundStyle(Theme.muted)
                        }
                        Spacer()
                        Text("\(r.sessionCount) sessions · \(fmtTokens(r.tokens)) tokens")
                            .font(.caption)
                            .foregroundStyle(Theme.faint)
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
