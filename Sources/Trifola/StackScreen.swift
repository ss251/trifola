import SwiftUI
import TrifolaKit

// MARK: - Store

/// Holds the latest probe sweep. Lives on AppServices so results survive
/// section switches — the screen never opens cold after the first sweep.
@MainActor
final class StackStore: ObservableObject {
    @Published private(set) var results: [String: ProbeResult] = [:]
    @Published private(set) var probing = false
    @Published private(set) var lastRun: Date? = nil

    /// Display order == `ToolProbeEngine.defaultProbes` order.
    nonisolated let probes = ToolProbeEngine.defaultProbes

    func refreshNow() async {
        guard !probing else { return }
        probing = true
        let swept = await ToolProbeEngine.run(probes)
        // Compare-before-assign (W6 wave 4): a sweep that read the same still
        // must not republish the grid. Latency jitters every sweep, so compare
        // the INFORMATION (status/detail/metrics), not the stopwatch.
        if !resultsMatch(results, swept) { results = swept }
        lastRun = Date()
        probing = false
    }

    /// Equal up to latency — two sweeps carry the same information when every
    /// probe's status, detail and metric rows match.
    private nonisolated static func stripLatency(_ r: ProbeResult) -> ProbeResult {
        var out = r; out.latencyMs = 0; return out
    }
    private nonisolated func resultsMatch(_ a: [String: ProbeResult], _ b: [String: ProbeResult]) -> Bool {
        a.count == b.count && a.allSatisfy { key, val in
            b[key].map { Self.stripLatency($0) == Self.stripLatency(val) } ?? false
        }
    }

    func refreshIfStale(_ maxAge: TimeInterval = 30) async {
        if let lastRun, Date().timeIntervalSince(lastRun) < maxAge { return }
        await refreshNow()
    }

    func count(_ status: ProbeStatus) -> Int {
        results.values.filter { $0.status == status }.count
    }

    /// Worst status across the stack drives the summary pill.
    var overall: ProbeStatus {
        if results.isEmpty { return .unknown }
        if count(.down) > 0 { return .down }
        if count(.degraded) > 0 { return .degraded }
        if count(.unknown) > 0 { return .unknown }
        return .up
    }

    var slowest: (name: String, ms: Int)? {
        results.max { $0.value.latencyMs < $1.value.latencyMs }
            .flatMap { entry in
                probes.first { $0.id == entry.key }
                    .map { ($0.name, entry.value.latencyMs) }
            }
    }
}

// MARK: - Screen

/// Live health of the Claude Code config surface — the config root, the skills
/// library, MCP servers, hooks, and plugins. Probes run concurrently with a
/// hard timeout, so this screen always renders.
struct StackScreen: View {
    @EnvironmentObject var services: AppServices
    @State private var skillQuery = ""
    @State private var selectedSkillPath: String? = nil

    private var store: StackStore { services.stack }
    private var skillsStore: SkillsStore { services.skills }

    var body: some View {
        ScreenScaffold(
            title: "Stack",
            subtitle: "Every tool the fleet leans on, probed live from this Mac"
        ) {
            HStack(spacing: Theme.sectionGap) {
                summaryPill
                QuietTapButton(action: {
                    Task { await store.refreshNow() }
                }) {
                    Label("Probe again", systemImage: "arrow.clockwise")
                }
                .disabled(store.probing)
            }
        } content: {
            if store.results.isEmpty {
                EmptyState(
                    icon: "server.rack",
                    title: store.probing ? "Probing the stack…" : "No sweep yet",
                    detail: "Each tool gets a concurrent health check with a \(Int(ToolProbeEngine.perProbeTimeout.components.seconds))-second budget. A hung probe comes back as UNKNOWN — it never blocks this screen.")
                    .frame(minHeight: 420)
            } else {
                stats
                Divider()
                grid
                footnote
            }
            Divider()
            skillsSection
        }
        .task {
            while !Task.isCancelled {
                await store.refreshIfStale(30)
                try? await Task.sleep(for: .seconds(30))
            }
        }
        .task { await skillsStore.refreshIfStale() }
    }

    // MARK: Skill hierarchy (VISION 3.3)

    private var hierarchy: SkillHierarchy { skillsStore.hierarchy }
    private var ledger: SkillLedger { services.auditReport.report.skillLedger }

    /// Join key → ledger entry, from both fired + dead entries.
    private var ledgerIndex: [String: SkillLedgerEntry] {
        var m: [String: SkillLedgerEntry] = [:]
        for e in ledger.fired { m[e.name] = e }
        for e in ledger.dead where m[e.name] == nil { m[e.name] = e }
        return m
    }
    private func entry(for s: Skill) -> SkillLedgerEntry? {
        ledgerIndex[s.qualifiedID] ?? ledgerIndex[s.id] ?? ledgerIndex[s.name]
    }

    private var filteredSkills: [Skill] {
        SkillsStore.filter(skillsStore.allSkills, query: skillQuery)
            .sorted { $0.id < $1.id }
    }

    private var selectedSkill: Skill? {
        skillsStore.allSkills.first { $0.path == selectedSkillPath }
    }

    private func seedBuilder(_ skill: Skill) { services.seedLaunch(skill: skill.qualifiedID) }

    @ViewBuilder
    private var skillsSection: some View {
        VStack(alignment: .leading, spacing: Theme.sectionGap) {
            HStack(spacing: 8) {
                SectionLabel("Skill hierarchy")
                Text("\(hierarchy.totalSkills) skills · 3 source lanes")
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                Spacer()
                if let last = skillsStore.lastScan {
                    Text("scanned \(fmtAgo(last))")
                        .font(.caption2)
                        .foregroundStyle(Theme.faint)
                }
                QuietTapButton(action: {
                    Task { await skillsStore.refreshNow() }
                }) {
                    Label("Rescan", systemImage: "arrow.clockwise")
                }
                .disabled(skillsStore.loading)
            }

            if skillsStore.allSkills.isEmpty {
                EmptyState(
                    icon: "puzzlepiece.extension",
                    title: skillsStore.loading ? "Parsing manifests…" : "No skills found",
                    detail: "Every SKILL.md under ~/.claude/skills, the plugin caches (~/.claude/plugins/cache) and project .claude/skills dirs is parsed off the main thread.")
                    .frame(minHeight: 200)
            } else {
                SkillLaneStats(hierarchy: hierarchy, deadCount: ledger.deadCount, catalog: ledger.catalogCount)

                if !hierarchy.collisions.isEmpty {
                    TriggerCollisionsPanel(collisions: hierarchy.collisions)
                }

                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass")
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(Theme.muted)
                    TextField("Search \(hierarchy.totalSkills) skills by name, trigger or description…",
                              text: $skillQuery)
                        .textFieldStyle(.plain)
                        .font(.subheadline)
                        .foregroundStyle(Theme.ink)
                    if !skillQuery.isEmpty {
                        Text("\(filteredSkills.count) match\(filteredSkills.count == 1 ? "" : "es")")
                            .font(.caption2)
                            .foregroundStyle(Theme.faint)
                    }
                }
                .padding(.horizontal, Theme.intraCell)
                .padding(.vertical, Theme.rhythm)
                .background {
                    RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous).fill(Theme.codeFill)
                    RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
                        .strokeBorder(Theme.cardStroke, lineWidth: 1)
                }

                HStack(alignment: .top, spacing: Theme.sectionGap) {
                    (skillQuery.isEmpty ? AnyView(hierarchyTree) : AnyView(flatList))
                        .frame(width: 360)
                    if let skill = selectedSkill {
                        SkillDetail(skill: skill, entry: entry(for: skill)) { seedBuilder(skill) }
                    } else {
                        EmptyState(icon: "puzzlepiece.extension",
                                   title: skillQuery.isEmpty ? "Pick a skill" : "No match",
                                   detail: skillQuery.isEmpty
                                    ? "Browse by source lane and namespace. Each node carries its Skill-Ledger usage and a Launch button that seeds the builder."
                                    : "No skill matches “\(skillQuery)”.")
                            .frame(maxWidth: .infinity, minHeight: 300)
                    }
                }
                SkillUsageLegend()
            }
        }
        .padding(.top, Theme.micro)
    }

    private var hierarchyTree: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 8) {
                ForEach(hierarchy.lanes) { lane in
                    SkillLaneView(lane: lane,
                                  selectedPath: selectedSkillPath,
                                  entryFor: { entry(for: $0) },
                                  onSelect: { selectedSkillPath = $0.path },
                                  onLaunch: { seedBuilder($0) })
                }
            }
            .padding(Theme.intraCell)
        }
        .frame(height: 520)
        .background {
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).fill(Theme.cardFill)
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 1)
        }
    }

    private var flatList: some View {
        ScrollView {
            LazyVStack(spacing: 2) {
                ForEach(filteredSkills) { skill in
                    HierarchySkillRow(skill: skill,
                                      entry: entry(for: skill),
                                      isSelected: skill.path == selectedSkillPath,
                                      showLane: true,
                                      onSelect: { selectedSkillPath = skill.path },
                                      onLaunch: { seedBuilder(skill) })
                }
            }
            .padding(Theme.rhythm)
        }
        .frame(height: 520)
        .background {
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).fill(Theme.cardFill)
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 1)
        }
    }

// MARK: - Skill detail

struct SkillDetail: View {
    let skill: Skill
    var entry: SkillLedgerEntry? = nil
    var onLaunch: () -> Void = {}

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.sectionGap) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(skill.name)
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                    if let v = skill.version {
                        Text("v\(v)")
                            .font(.footnote)
                            .foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    ProminentTapButton(size: .small, action: onLaunch) {
                        Label("Launch", systemImage: "paperplane.fill")
                    }
                    .help("Seed the Session Builder with /\(skill.qualifiedID)")
                    QuietTapButton(action: {
                        NSWorkspace.shared.selectFile(
                            skill.path, inFileViewerRootedAtPath: "")
                    }) {
                        Label("Reveal", systemImage: "folder")
                    }
                }

                HStack(spacing: 8) {
                    SkillSourceBadge(source: skill.source)
                    Text("/\(skill.qualifiedID)")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Theme.muted)
                    if !skill.hasManifest {
                        Text("no manifest").font(.caption2).foregroundStyle(Theme.faint)
                    }
                }

                SkillLedgerBadge(entry: entry, source: skill.source)

                Text(skill.description)
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)

                HStack(spacing: 14) {
                    fact("body", "\(skill.wordCount) words")
                    fact("files", "\(skill.fileCount)")
                    fact("touched", fmtAgo(skill.modified))
                }

                if !skill.triggers.isEmpty {
                    chipGroup("Triggers", skill.triggers)
                }
                if !skill.allowedTools.isEmpty {
                    chipGroup("Allowed tools", skill.allowedTools)
                }

                Text(skill.path)
                    .font(.caption2)
                    .foregroundStyle(Theme.faint)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
            }
            .padding(Theme.cardPadding)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(maxWidth: .infinity)
        .frame(height: 520)
        .background {
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).fill(Theme.cardFill)
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 1)
        }
    }

    private func fact(_ label: String, _ value: String) -> some View {
        HStack(spacing: 5) {
            Text(label)
                .font(.caption2)
                .foregroundStyle(Theme.faint)
            Text(value)
                .font(.caption)
                .foregroundStyle(Theme.muted)
        }
    }

    private func chipGroup(_ label: String, _ items: [String]) -> some View {
        VStack(alignment: .leading, spacing: Theme.rhythm) {
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.muted)
            FlowChips(items: items)
        }
    }
}

/// Simple wrapping chip layout for triggers / tools.
private struct FlowChips: View {
    let items: [String]

    var body: some View {
        FlowLayout(spacing: 6) {
            ForEach(items, id: \.self) { item in
                Text(item)
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .padding(.horizontal, Theme.intraCell)
                    .padding(.vertical, Theme.rhythm / 2)
                    .background {
                        Capsule().fill(Theme.cardFill)
                        Capsule().strokeBorder(Theme.cardStroke, lineWidth: 1)
                    }
                    .lineLimit(1)
            }
        }
    }
}

/// Minimal wrapping layout (macOS 13+ `Layout`).
private struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let placement = arrange(proposal: proposal, subviews: subviews)
        for (subview, point) in zip(subviews, placement.points) {
            subview.place(at: CGPoint(x: bounds.minX + point.x, y: bounds.minY + point.y),
                          proposal: .unspecified)
        }
    }

    private func arrange(proposal: ProposedViewSize, subviews: Subviews)
        -> (size: CGSize, points: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var points: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0; y += rowHeight + spacing; rowHeight = 0
            }
            points.append(CGPoint(x: x, y: y))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return (CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight),
                points)
    }
}

    private var summaryPill: some View {
        let color = statusColor(store.overall)
        let label: String = {
            if store.probing { return "Probing…" }
            switch store.overall {
            case .up: return "All systems up"
            case .degraded: return "\(store.count(.degraded)) degraded"
            case .down: return "\(store.count(.down)) down"
            case .unknown: return "Unknown"
            }
        }()
        return HStack(spacing: 6) {
            SeatMark(fill: store.probing ? Theme.amber : color, size: 6)
            Text(label)
                .font(.caption)
                .foregroundStyle(Theme.muted)
        }
    }

    private var stats: some View {
        StatRow {
            StatTile(label: "Up", value: "\(store.count(.up))/\(store.probes.count)",
                     sub: "tools fully operational")
            Divider()
            StatTile(label: "Degraded", value: "\(store.count(.degraded))",
                     sub: "reachable, partially configured")
            Divider()
            StatTile(label: "Down", value: "\(store.count(.down))",
                     sub: "installed but not answering")
            if let slowest = store.slowest {
                Divider()
                StatTile(label: "Slowest probe", value: "\(slowest.ms) ms",
                         sub: slowest.name, live: store.probing)
            }
        }
    }

    private var grid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: Theme.sectionGap), GridItem(.flexible())],
                  spacing: Theme.sectionGap) {
            ForEach(store.probes, id: \.id) { probe in
                ProbeCard(name: probe.name,
                          subtitle: probe.subtitle,
                          symbol: probe.symbolName,
                          result: store.results[probe.id],
                          probing: store.probing)
            }
        }
    }

    private var footnote: some View {
        HStack(spacing: 5) {
            Image(systemName: "arrow.triangle.2.circlepath")
                .font(.caption2.weight(.medium))
            if let lastRun = store.lastRun {
                Text("last sweep \(fmtAgo(lastRun)) · re-probes every 30 s while you watch")
            } else {
                Text("re-probes every 30 s while you watch")
            }
        }
        .font(.caption)
        .foregroundStyle(Theme.faint)
    }
}

// MARK: - Card
// A quiet hairline tile: neutral chrome, the status dot is the only color.
// File-scope (not private) so the headless --render-config path can reuse the
// exact card the live Stack grid draws.

struct ProbeCard: View {
    let name: String
    let subtitle: String
    let symbol: String
    let result: ProbeResult?
    let probing: Bool

    private var color: Color {
        guard let result else { return Theme.faint }
        return statusColor(result.status)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.rhythm + 2) {
            HStack(spacing: 10) {
                Image(systemName: symbol)
                    .font(.body.weight(.medium))
                    .foregroundStyle(Theme.muted)
                    .frame(width: 24)

                VStack(alignment: .leading, spacing: 1) {
                    Text(name)
                        .font(.headline)
                        .foregroundStyle(Theme.ink)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(Theme.muted)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                badge
            }

            Text(result?.detail ?? "waiting for first sweep…")
                .font(.footnote)
                .foregroundStyle(result == nil ? Theme.faint : Theme.muted)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)

            if let result, !result.metrics.isEmpty {
                VStack(alignment: .leading, spacing: 3) {
                    ForEach(result.metrics, id: \.label) { metric in
                        HStack(spacing: 8) {
                            Text(metric.label)
                                .font(.caption2)
                                .foregroundStyle(Theme.faint)
                            // State color reaches the failing token (UI_GRIND
                            // CFG-1/§2.6): the row that bit wears the amber + a
                            // small glyph — you see WHICH row from across the
                            // room, not just the card-level dot.
                            if metricFails(metric.value) {
                                Image(systemName: "exclamationmark.triangle.fill")
                                    .font(.system(size: 9, weight: .medium))
                                    .foregroundStyle(Theme.amber)
                            }
                            Text(metric.value)
                                .font(.caption)
                                .foregroundStyle(metricFails(metric.value) ? Theme.amber : Theme.muted)
                                .lineLimit(1)
                        }
                    }
                }
            }

            Spacer(minLength: 0)

            if let result {
                // Format floor (UI_GRIND CFG-2): "answered in 0 ms" reads as
                // "didn't actually probe" — precisely the suspicion this card
                // exists to dispel.
                Text("answered in \(result.latencyMs < 1 ? "<1" : "\(result.latencyMs)") ms")
                    .font(.caption2)
                    .foregroundStyle(Theme.faint)
            }
        }
        .padding(Theme.cardPadding)
        .frame(maxWidth: .infinity, minHeight: 124, alignment: .topLeading)
        .background {
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous).fill(Theme.cardFill)
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 1)
        }
    }

    private var badge: some View {
        let text = result.map { $0.status.rawValue.capitalized } ?? (probing ? "Probing…" : "—")
        return HStack(spacing: 5) {
            SeatMark(fill: color, size: 6)
            Text(text)
                .font(.caption)
                .foregroundStyle(Theme.muted)
        }
    }

    /// The classified failing suffixes the config probeResults emit ("· binary
    /// missing", "SessionStart · missing", "v1.0.0 · 177d · stale"). A UI-side
    /// read of the value string — the data layer stays untouched.
    private func metricFails(_ value: String) -> Bool {
        value.hasSuffix("missing") || value.hasSuffix("stale")
    }
}

// MARK: - Shared

private func statusColor(_ status: ProbeStatus) -> Color {
    switch status {
    case .up: return Theme.green
    case .degraded: return Theme.amber
    case .down: return Theme.red
    case .unknown: return Theme.faint
    }
}

// MARK: - Skill hierarchy components (file-scope so --render-skills can reuse)

/// The lane / trigger / dead-skill header strip.
struct SkillLaneStats: View {
    let hierarchy: SkillHierarchy
    let deadCount: Int
    let catalog: Int

    var body: some View {
        StatRow {
            StatTile(label: "User", value: "\(hierarchy.laneCount(.user))", sub: "~/.claude/skills")
            Divider()
            StatTile(label: "Plugins", value: "\(hierarchy.laneCount(.plugin))", sub: "cache — was invisible")
            Divider()
            StatTile(label: "Project", value: "\(hierarchy.laneCount(.project))", sub: ".claude/skills")
            Divider()
            StatTile(label: "Triggers", value: "\(hierarchy.distinctTriggers)",
                     sub: "\(hierarchy.collisions.count) collision\(hierarchy.collisions.count == 1 ? "" : "s")",
                     valueColor: hierarchy.collisions.isEmpty ? Theme.ink : Theme.amber)
            Divider()
            StatTile(label: "Unused", value: "\(deadCount)/\(catalog)", sub: "never explicitly invoked")
        }
    }
}

/// Trigger-collision index: phrases two+ skills both claim (a real routing failure).
struct TriggerCollisionsPanel: View {
    let collisions: [TriggerCollision]

    var body: some View {
        // A real warning with evidence → the amber CalloutPanel (POLISH C5), the
        // one other licensed tint. Header is a ColumnLabel (POLISH C3).
        CalloutPanel(tone: Theme.amber) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill").font(.caption.weight(.medium)).foregroundStyle(Theme.amber)
                    ColumnLabel("Trigger collisions")
                    Text("\(collisions.count)").font(.caption.weight(.medium)).foregroundStyle(Theme.amber)
                        .monospacedDigit()
                    Spacer()
                }
                Text("Two or more skills declare the same trigger phrase — the router can't tell which you meant. Disambiguate the manifests.")
                    .font(.caption2).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                ForEach(collisions.prefix(6)) { c in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text("“\(c.phrase)”")
                            .font(.footnote).foregroundStyle(Theme.muted)
                            .lineLimit(1)
                        Spacer(minLength: 8)
                        Text(c.skillNames.joined(separator: " · "))
                            .font(.caption2).foregroundStyle(Theme.muted)
                            .lineLimit(1).truncationMode(.middle)
                    }
                }
                if collisions.count > 6 {
                    Text("+\(collisions.count - 6) more collisions").font(.caption2).foregroundStyle(Theme.faint)
                }
            }
        }
    }
}

/// One source lane, its namespaces, and their skill nodes.
struct SkillLaneView: View {
    let lane: SkillLaneGroup
    var selectedPath: String? = nil
    let entryFor: (Skill) -> SkillLedgerEntry?
    var onSelect: (Skill) -> Void = { _ in }
    var onLaunch: (Skill) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: lane.lane.icon).font(.footnote.weight(.medium)).foregroundStyle(Theme.muted).frame(width: 16)
                Text(lane.lane.title).font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
                Text("\(lane.count)").font(.caption).foregroundStyle(Theme.muted)
                Spacer()
                Text(lane.lane.subtitle).font(.caption2).foregroundStyle(Theme.faint)
            }
            ForEach(lane.namespaces) { ns in
                if ns.count > 1 || ns.key == "gstack" || !ns.key.isEmpty {
                    HStack(spacing: 5) {
                        Image(systemName: "chevron.right").font(.caption2.weight(.medium)).foregroundStyle(Theme.faint)
                        Text(ns.displayName).font(.caption.weight(.medium)).foregroundStyle(Theme.muted)
                        Text("\(ns.count)").font(.caption2).foregroundStyle(Theme.faint)
                    }
                    .padding(.leading, Theme.micro).padding(.top, Theme.rhythm / 2)
                }
                ForEach(ns.skills) { s in
                    HierarchySkillRow(skill: s, entry: entryFor(s),
                                      isSelected: s.path == selectedPath,
                                      onSelect: { onSelect(s) }, onLaunch: { onLaunch(s) })
                        .padding(.leading, Theme.codePadding)
                }
            }
        }
    }
}

/// A skill node: usage dot + name + ledger badge + a Launch button that seeds
/// the builder. The dot IS the ledger signal (green fired · amber dead · faint
/// untracked) — CodexBar status-dot discipline.
struct HierarchySkillRow: View {
    let skill: Skill
    let entry: SkillLedgerEntry?
    let isSelected: Bool
    var showLane = false
    var onSelect: () -> Void = {}
    var onLaunch: () -> Void = {}
    @State private var hovering = false

    private var fired: Bool { (entry?.invocations ?? 0) > 0 }
    private var isDead: Bool { entry != nil && (entry?.invocations ?? 0) == 0 }
    private var dotColor: Color { fired ? Theme.green : (isDead ? Theme.amber.opacity(0.55) : Theme.faint) }
    private var primary: Color { isSelected ? Theme.selectionText : Theme.ink }
    private var secondary: Color { isSelected ? Theme.selectionText.opacity(0.8) : Theme.muted }

    var body: some View {
        HStack(spacing: 8) {
            TapButton(focusVisual: .row, action: onSelect) {
                HStack(spacing: 8) {
                    Circle().fill(dotColor).frame(width: 6, height: 6)
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(skill.name).font(.subheadline.weight(.medium)).foregroundStyle(primary).lineLimit(1)
                            if let v = skill.version { Text("v\(v)").font(.caption2).foregroundStyle(secondary) }
                            if showLane { Text(skill.source.lane.title).font(.caption2).foregroundStyle(secondary.opacity(0.8)) }
                        }
                        Text(skill.description).font(.caption).foregroundStyle(secondary).lineLimit(1)
                    }
                    Spacer(minLength: 4)
                    // Every row states its evidence: ×N (fired), unused (catalog
                    // entry with no explicit invocation), or a faint em dash.
                    if fired {
                        Text("×\(entry!.invocations)").font(.caption2.weight(.medium))
                            .foregroundStyle(isSelected ? Theme.selectionText : Theme.green)
                            .monospacedDigit()
                    } else if isDead {
                        Text("unused").font(.caption2).foregroundStyle(isSelected ? Theme.selectionText : Theme.muted)
                    } else {
                        Text("—").font(.caption2)
                            .foregroundStyle(isSelected ? Theme.selectionText.opacity(0.6) : Theme.faint)
                            .help("Never seen in a transcript — no explicit Skill-tool call recorded")
                    }
                }
            }
            // Launch appears on hover/selection only (UI_GRIND SKL-2): at rest the
            // tree is pure evidence, not fourteen paperplanes of verb wallpaper.
            TapButton(action: onLaunch) { Image(systemName: "paperplane") }
                .font(.caption.weight(.medium))
                .foregroundStyle(isSelected ? Theme.selectionText : Theme.muted)
                .opacity(hovering || isSelected ? 1 : 0)
                .help("Seed the Session Builder with /\(skill.qualifiedID)")
        }
        .padding(.horizontal, Theme.intraCell).padding(.vertical, Theme.rowVerticalInset)
        .contentShape(Rectangle())
        .background(RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
            .fill(isSelected ? Theme.selectionBG : .clear))
        .onHover { hovering = $0 }
    }
}

/// The usage column's honest legend (UI_GRIND SKL-1): every row states its
/// evidence — the caption names all three readings so a dash is never a mystery.
/// Shared by the live tree + `--render-skills`.
struct SkillUsageLegend: View {
    var body: some View {
        Text("×N = explicit Skill-tool calls counted from transcripts · unused = in the catalog, never explicitly invoked · — = never seen in a transcript")
            .font(.caption2).foregroundStyle(Theme.faint)
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Source-lane capsule for the detail header.
struct SkillSourceBadge: View {
    let source: SkillSource
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: source.lane.icon).font(.system(size: 9, weight: .medium))
            Text(source.pluginName.map { "\(source.lane.title) · \($0)" } ?? source.lane.title)
                .font(.caption2)
        }
        .foregroundStyle(Theme.muted)
        .padding(.horizontal, Theme.rhythm).padding(.vertical, Theme.micro / 2)
        .background {
            Capsule().fill(Theme.cardFill)
            Capsule().strokeBorder(Theme.cardStroke, lineWidth: 1)
        }
    }
}

/// The Skill-Ledger usage line for the detail pane (honest "explicit invocations").
struct SkillLedgerBadge: View {
    let entry: SkillLedgerEntry?
    let source: SkillSource

    var body: some View {
        HStack(spacing: 6) {
            if let e = entry, e.invocations > 0 {
                SeatMark(fill: Theme.green, size: 6)
                Text("fired ×\(e.invocations)").font(.caption.weight(.medium)).foregroundStyle(Theme.ink)
                Text("· \(e.sessionsTouched) session\(e.sessionsTouched == 1 ? "" : "s") · last \(fmtAgo(e.lastFired))")
                    .font(.caption2).foregroundStyle(Theme.muted)
            } else if entry != nil {
                SeatMark(fill: Theme.amber.opacity(0.6), size: 6)
                Text("unused — never explicitly invoked").font(.caption).foregroundStyle(Theme.muted)
            } else if source.lane == .user {
                SeatMark(fill: Theme.faint, size: 6)
                Text("no explicit invocations recorded").font(.caption).foregroundStyle(Theme.muted)
            } else {
                SeatMark(fill: Theme.faint, size: 6)
                Text("not tracked in the ledger (plugin/project skill)").font(.caption).foregroundStyle(Theme.muted)
            }
        }
    }
}
