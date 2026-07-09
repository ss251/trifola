import SwiftUI
import AppKit
import Combine
import TrifolaKit

// MARK: - Fleet store (signals + the persistent arrival ledger)
//
// Reads transcript tails for the in-window pool (mains AND subagents — subagents
// carry now-lines too) into the same `AttentionSignals` the strip uses, and holds
// the `ArrivalLedger` across refreshes so bays keep their seats. Building the
// board happens at render time against a fresh `now` (so RUNNING→BLOCKED flips
// live) using this stored, read-only ledger — the layout never shifts.

@MainActor
final class FleetStore: ObservableObject {
    @Published private(set) var signals: [String: AttentionSignals] = [:]
    private(set) var arrival = ArrivalLedger()

    /// Refresh signals for every in-window session (subagents included) and advance
    /// the arrival ledger so any newly-arrived bay/session claims its permanent seat.
    func refresh(sessions: [SessionSummary], now: Date = Date()) async {
        let window = FleetBoard.window
        let candidates: [(String, String)] = sessions.compactMap { s in
            guard let last = s.lastActivity, !s.filePath.isEmpty else { return nil }
            let age = now.timeIntervalSince(last)
            guard age >= 0, age <= window else { return nil }
            return (s.id, s.filePath)
        }
        let result = await Task.detached(priority: .userInitiated) {
            var out: [String: AttentionSignals] = [:]
            for (id, path) in candidates {
                if let sig = AttentionSignals.extractFromTail(path: path) { out[id] = sig }
            }
            return out
        }.value
        // Compare-before-assign (W6 wave 4): unchanged tails must not republish
        // the Floor — a publish re-renders every bay for zero information.
        if signals != result { signals = result }
        // Advance the ledger (keep the returned copy — this is the real refresh).
        let (_, advanced) = FleetBoard.build(sessions: sessions, signals: result,
                                             now: now, arrival: arrival)
        arrival = advanced
    }
}

// MARK: - Heartbeat driver (the disk-activity LED)
//
// One `FileTailer` per live seat. Every real append fires a coalesced (≤4/s) tick
// on that session's dot — the ONLY moving pixel that isn't a state crossfade.
// BLOCKED seats are marked still and never tick (a stall is the absence of
// motion). The initial tail read on open is history, not a live event, so it is
// skipped — opening a quiet file never produces a phantom heartbeat. View-scoped:
// tailers exist only while the Board is on screen, so a quiet room costs nothing.

@MainActor
final class HeartbeatDriver: ObservableObject {
    struct Watch: Equatable { let id: String; let filePath: String; let isStill: Bool }

    /// Per-session pulse counter — a token's dot animates a luminance blip whenever
    /// its count changes.
    @Published private(set) var pulses: [String: Int] = [:]

    private var coalescer = HeartbeatCoalescer()
    private var tailers: [String: FileTailer] = [:]
    private var still: Set<String> = []

    /// Reconcile the set of watched seats with the live board.
    func sync(_ watches: [Watch]) {
        let want = Dictionary(watches.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        still = Set(watches.filter(\.isStill).map(\.id))
        // Stop tailers for seats that left the floor.
        for (id, tailer) in tailers where want[id] == nil {
            tailer.stop()
            tailers[id] = nil
            pulses[id] = nil
            coalescer.drop(id)
        }
        // Start tailers for new seats.
        for w in watches where tailers[w.id] == nil && !w.filePath.isEmpty {
            let id = w.id
            let tailer = FileTailer(url: URL(fileURLWithPath: w.filePath), tailBytes: 64_000) { [weak self] chunk in
                // The initial reset read is history; only later appends are the
                // disk moving NOW. Empty line-sets (partial writes) don't count.
                guard !chunk.reset, !chunk.lines.isEmpty else { return }
                Task { @MainActor [weak self] in self?.tick(id) }
            }
            tailers[id] = tailer
            tailer.start()
        }
    }

    private func tick(_ id: String) {
        if coalescer.register(session: id, at: Date(), isStill: still.contains(id)) {
            pulses[id, default: 0] += 1
        }
    }

    func stopAll() {
        for (_, t) in tailers { t.stop() }
        tailers = [:]
        pulses = [:]
    }
}

// MARK: - The screen

struct FleetScreen: View {
    @EnvironmentObject var services: AppServices
    @StateObject private var heartbeat = HeartbeatDriver()

    private var board: FleetBoard { services.fleetBoard(now: services.now) }

    var body: some View {
        Group {
            if board.bays.isEmpty {
                EmptyState(
                    icon: "square.grid.3x3",
                    title: "The floor is empty",
                    detail: "Bays appear here as your agents arrive — one stable seat per repo, in arrival order. A seat never moves; only its dot, its now-line, and its cost change in place."
                )
            } else {
                ScrollView {
                    FleetFloor(
                        board: board,
                        attention: services.attentionBoard(now: services.now),
                        signals: services.attention.signals,
                        pulses: heartbeat.pulses,
                        onSelect: { services.inspect($0) }
                    )
                    .screenScaffoldFrame()
                }
                .scrollIndicators(.never)
            }
        }
        .onChange(of: watches) { _, w in heartbeat.sync(w) }
        .onAppear { heartbeat.sync(watches) }
        .onDisappear { heartbeat.stopAll() }
    }

    /// The seats the heartbeat watches — every non-idle live token (mains +
    /// subagents), with blocked ones flagged still.
    private var watches: [HeartbeatDriver.Watch] {
        board.bays.flatMap(\.allTokens)
            .filter { $0.state != .idle && !$0.session.filePath.isEmpty }
            .map { .init(id: $0.id, filePath: $0.session.filePath, isStill: $0.isStill) }
    }
}

// MARK: - The Floor (pure — rasterizes headlessly via `--render-fleet`)

struct FleetFloor: View {
    let board: FleetBoard
    let attention: AttentionBoard
    /// Tail signals — the strip chips carry the ask (`· Bash approval…`).
    var signals: [String: AttentionSignals] = [:]
    var pulses: [String: Int] = [:]
    var onSelect: (SessionSummary) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            // The strip rides on top: "who needs me NOW" survives even while the
            // room below holds still. Sorted (triage) over stable (presence).
            AttentionStripView(board: attention, signals: signals) { onSelect($0) }
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                ForEach(board.bays) { bay in
                    FleetBayView(bay: bay,
                                 chipForced: duplicatedProjects.contains(bay.project),
                                 pulses: pulses, onSelect: onSelect)
                }
            }
            // Seats never re-sort (the ArrivalLedger owns order) — this animates
            // only ARRIVALS and DEPARTURES with the one app-standard motion
            // (W6 wave 4), so a bay appearing never snaps the room.
            .reorderMotion(
                value: board.bays.flatMap { [$0.id] + $0.allTokens.map(\.id) })
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Project names present on MORE than one machine right now (UI_GRIND CRM-1):
    /// a local bay may omit its machine chip — until the same repo shows up on a
    /// second machine, at which point EVERY bay of that name wears its chip
    /// (the unlabeled one was ambiguous exactly where disambiguation is the job).
    private var duplicatedProjects: Set<String> {
        var machines: [String: Set<String>] = [:]
        for bay in board.bays { machines[bay.project, default: []].insert(bay.machineID) }
        return Set(machines.filter { $0.value.count > 1 }.keys)
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 8) {
                    Text("Fleet Board")
                        .font(.title2.weight(.semibold))
                        .foregroundStyle(Theme.ink)
                    Text("the floor")
                        .font(.caption)
                        .foregroundStyle(Theme.faint)
                }
                Text(subtitle)
                    .font(.subheadline)
                    .foregroundStyle(Theme.muted)
            }
            Spacer()
            // No per-state legend here — the strip below already carries one; a
            // second (subagent-inclusive) count adjacent to it reads as a
            // contradiction rather than a census. The subtitle holds the totals.
        }
        .padding(.top, 4)
    }

    private var subtitle: String {
        let bays = board.bays.count
        let mains = board.mainCount
        let subs = board.subagentCount
        let who = subs > 0
            ? "\(mains) agent\(mains == 1 ? "" : "s") · \(subs) subagent\(subs == 1 ? "" : "s")"
            : "\(mains) agent\(mains == 1 ? "" : "s")"
        // Cross-Machine Fleet: name the machine span when the floor covers more than
        // this Mac — the whole differentiator in one calm phrase.
        let machineN = Set(board.bays.map(\.machineID)).count
        let across = machineN > 1
            ? "across \(machineN) machines · \(bays) bay\(bays == 1 ? "" : "s")"
            : "across \(bays) bay\(bays == 1 ? "" : "s")"
        return "\(who) \(across) · stable seats, live presence · \(fmtUSD(board.totalCost)) today"
    }
}

// MARK: - One bay (a repo's stable place)

private struct FleetBayView: View {
    let bay: FleetBay
    /// Forced when this project name exists on >1 machine (CRM-1).
    var chipForced = false
    var pulses: [String: Int]
    var onSelect: (SessionSummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            BayHeader(bay: bay, chipForced: chipForced)
            if bay.isIdle {
                // Compressed dimmed line — the bay sinks via the ember fade, not by
                // reordering. Its cost stays legible.
                ForEach(bay.tokens) { t in
                    HStack(spacing: 10) {
                        SeatMark(fill: Theme.faint, size: 6, active: false)
                        Text(t.session.tier.label).font(.caption).foregroundStyle(Theme.faint)
                        if let q = t.taskQuote {
                            Text("last: \(q)").font(.caption).foregroundStyle(Theme.faint).lineLimit(1)
                        }
                        Spacer(minLength: 8)
                        Text(fmtUSD(t.session.cost)).font(.caption).foregroundStyle(Theme.muted)
                    }
                    .padding(.leading, 2)
                    .opacity(0.85)
                }
            } else {
                if let c = bay.collision {
                    HStack(spacing: 6) {
                        Image(systemName: "exclamationmark.triangle")
                            .font(.caption2).foregroundStyle(Theme.amber)
                        Text(c.message).font(.caption2).foregroundStyle(Theme.amber)
                    }
                    .padding(.leading, 2)
                }
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(bay.tokens) { token in
                        FleetTokenView(token: token, depth: 0, pulses: pulses,
                                       onSelect: onSelect)
                    }
                }
            }
        }
    }
}

private struct BayHeader: View {
    let bay: FleetBay
    var chipForced = false

    var body: some View {
        HStack(spacing: 10) {
            Text(bay.project)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(bay.isIdle ? Theme.muted : Theme.ink)
                .lineLimit(1)
            // The bay carries its machine tag — a remote bay ("workstation") reads
            // distinctly from a local one even when the repo name matches. A
            // LOCAL bay also chips up when its name exists on another machine
            // (CRM-1: the unlabeled twin was the ambiguous one).
            if bay.isRemote || chipForced {
                MachineChip(machineID: bay.machineID)
            }
            // The stretching hairline — dotted when the bay has cooled to embers.
            HRule()
                .stroke(Theme.hairline, style: StrokeStyle(lineWidth: 1, dash: bay.isIdle ? [2, 3] : []))
                .frame(height: 1)
                .frame(maxWidth: .infinity)
            trailing
        }
    }

    @ViewBuilder private var trailing: some View {
        HStack(spacing: 6) {
            if bay.isIdle {
                Text("idle \(fmtAgeShort(bay.age))").font(.caption).foregroundStyle(Theme.faint)
            } else if bay.blockedCount > 0 {
                SeatMark(fill: Theme.red, size: 6)
                Text("\(bay.blockedCount) blocked").font(.caption.weight(.medium)).foregroundStyle(Theme.ink)
                Text("· \(fmtUSD(bay.costSubtotal)) today").font(.caption).foregroundStyle(Theme.muted)
            } else {
                Text("\(bay.liveCount) live").font(.caption.weight(.medium)).foregroundStyle(Theme.ink)
                Text("· \(fmtUSD(bay.costSubtotal)) today").font(.caption).foregroundStyle(Theme.muted)
            }
        }
        .fixedSize()
    }
}

/// A single horizontal rule that the bay header stretches between name and status.
private struct HRule: Shape {
    func path(in rect: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: rect.minX, y: rect.midY))
        p.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return p
    }
}

// MARK: - One token row (a seat) + nested subagents

private struct FleetTokenView: View {
    let token: FleetToken
    let depth: Int
    var isLast: Bool = true
    var pulses: [String: Int]
    var onSelect: (SessionSummary) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            row
            ForEach(Array(token.children.enumerated()), id: \.element.id) { i, child in
                FleetTokenView(token: child, depth: depth + 1,
                               isLast: i == token.children.count - 1, pulses: pulses,
                               onSelect: onSelect)
            }
        }
    }

    private var row: some View {
        HoverRow(action: { onSelect(token.session) }) {
            HStack(spacing: 9) {
                if depth > 0 {
                    Text(isLast ? "└" : "├")
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(Theme.faint)
                        .frame(width: 10)
                }
                HeartbeatDot(state: token.state, ring: token.tier.color,
                             pulse: pulses[token.id] ?? 0, still: token.isStill)
                Text(token.tier.label)
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
                    .frame(width: 58, alignment: .leading)
                Text("\(token.session.displayTitle) · \(fmtAgeShort(token.age))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Theme.faint)
                    .lineLimit(1)
                    .frame(width: 116, alignment: .leading)
                middle
                Spacer(minLength: 8)
                Text(fmtUSD(token.session.cost))
                    .font(.subheadline)
                    .foregroundStyle(Theme.ink)
                    .frame(minWidth: 52, alignment: .trailing)
                    .monospacedDigit()
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 5)
            .padding(.leading, CGFloat(depth) * 16)
        }
        .opacity(emberOpacity)
        .contextMenu {
            Button("Focus transcript") { onSelect(token.session) }
        }
        .help(hoverEvidence)
    }

    /// now-line (the current tool + path) when present, else the task quote. For
    /// a BLOCKED/WAITING seat with a distinct task quote, a dim second line carries
    /// the quote — matching the spec's blocked row (tool on top, quote below).
    @ViewBuilder private var middle: some View {
        VStack(alignment: .leading, spacing: 1) {
            if let n = token.nowLine {
                (Text(n.tool).font(.system(.caption, design: .monospaced).weight(.semibold))
                    .foregroundStyle(token.state == .blocked ? Theme.red : Theme.ink)
                 + Text(n.detail.isEmpty ? "" : "  \(midTruncate(n.detail, 44))")
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(Theme.muted))
                    .lineLimit(1)
                if token.state.needsAttention, let q = token.taskQuote {
                    Text("“\(q)”").font(.caption2).foregroundStyle(Theme.faint).lineLimit(1)
                }
            } else if let q = token.taskQuote {
                Text("“\(q)”").font(.caption).foregroundStyle(Theme.muted).lineLimit(1)
            } else {
                Text(token.state.label.lowercased()).font(.caption).foregroundStyle(Theme.faint)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Findings-as-evidence hover (VISION §5): the classification's basis, not a
    /// verdict.
    private var hoverEvidence: String {
        switch token.state {
        case .blocked:
            return "\(token.nowLine?.tool ?? "tool") · no result for \(fmtAgeShort(token.age)) → likely a permission prompt / human gate"
        case .waiting: return "Turn ended — the ball is in your court"
        case .running: return "Work streaming — \(token.nowLine.map { "\($0.tool) \($0.detail)" } ?? "tool activity")"
        case .idle:    return "No activity for \(fmtAgeShort(token.age))"
        }
    }

    /// The ember fade: a static rendering of `age` — fresh seats read full, cooled
    /// ones dim toward the background. Recomputed on refresh, never animated.
    private var emberOpacity: Double {
        guard token.state == .idle else { return 1 }
        let frac = min(1, token.age / FleetBoard.window)   // 0 fresh … 1 window-old
        return 1 - 0.45 * frac
    }
}

// MARK: - The heartbeat dot
//
// A plain filled status dot (CodexBar discipline — no glow, no timer pulse) that
// blips its luminance once, ~200ms ease-out, each time its pulse count changes:
// one honest tick per disk event. A BLOCKED (still) seat's count never changes,
// so it holds perfectly still.

private struct HeartbeatDot: View {
    let state: AttentionState
    let ring: Color
    let pulse: Int
    let still: Bool

    @State private var flash: Double = 0

    var body: some View {
        // The seat token = the app's mark at live density (POLISH II.A): a filled
        // state dot with a 1pt tier ring, plus the heartbeat blip. Same `SeatMark`
        // the sidebar lockup wears — one object at every distance.
        SeatMark(fill: state.color, ring: ring.opacity(0.9), size: 7,
                 ringWidth: state == .idle ? 0 : 1)
            // The blip: a brief lighter overlay that fades out. Absent for blocked.
            .overlay(Circle().fill(.white).opacity(flash * 0.7).frame(width: 7, height: 7))
            .onChange(of: pulse) { _, _ in
                guard !still else { return }
                flash = 1
                withAnimation(.easeOut(duration: 0.2)) { flash = 0 }
            }
    }
}

// MARK: - Path mid-truncation

/// Keep the head and (more importantly) the tail of a path — the filename that
/// carries the meaning — collapsing the middle. "…/LiveScreen.swift".
func midTruncate(_ s: String, _ max: Int) -> String {
    guard s.count > max, max > 3 else { return s }
    let keepTail = (max - 1) * 2 / 3
    let keepHead = max - 1 - keepTail
    let head = s.prefix(keepHead)
    let tail = s.suffix(keepTail)
    return "\(head)…\(tail)"
}
