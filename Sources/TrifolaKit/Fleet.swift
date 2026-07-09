import Foundation

// MARK: - The Fleet Board ("the Floor")
//
// The presence instrument. Same state machine as the Attention Strip
// (`AttentionState`/`AttentionSignals`), OPPOSITE ordering physics: the strip
// SORTS (worst-first triage); the board STAYS PUT (stable seats for peripheral-
// vision change detection). Sessions live in *bays* (one per repo/cwd) laid out
// in **arrival order** that never re-sorts intraday; agents render as *tokens* at
// stable positions, with subagents nested under their parent. Everything here is
// pure value types over the already-parsed data — no AppKit, no filesystem — so
// the whole layout engine is exercised in unit tests. See docs/FLEET_BOARD.md.

// MARK: - Arrival ledger (the thing that makes it a room, not a table)
//
// "First activity today claims the next seat, like people arriving at a studio in
// the morning. Nothing re-sorts intraday." A monotonically-growing map from a key
// (a bay's cwd, or a session id) to the order it was first seen. Claiming is
// idempotent: a key already seated keeps its seat forever, so a session going
// RUNNING→BLOCKED can never move a bay. Held by the store across refreshes;
// rebuilt fresh each morning (a new process = an empty room).

public struct ArrivalLedger: Sendable, Equatable {
    private var order: [String: Int]
    private var next: Int

    public init() { order = [:]; next = 0 }
    public init(order: [String: Int], next: Int) { self.order = order; self.next = next }

    /// The seat for `key`, claiming the next free one on first sight. Idempotent.
    public mutating func claim(_ key: String) -> Int {
        if let i = order[key] { return i }
        let i = next
        next += 1
        order[key] = i
        return i
    }

    /// The seat already claimed for `key`, or nil if it has never been seen.
    public func rank(_ key: String) -> Int? { order[key] }

    public var count: Int { order.count }
}

// MARK: - Token (one agent's seat)

public struct FleetToken: Identifiable, Sendable, Equatable {
    /// The "now-line": the real current tool + path from the freshest tool_use in
    /// the transcript tail (Edit/Write file_path, Bash command, …). The agent↔file
    /// edge of the relationship graph, rendered as typography instead of a node.
    public struct NowLine: Sendable, Equatable {
        public let tool: String
        public let detail: String
        public init(tool: String, detail: String) { self.tool = tool; self.detail = detail }
    }

    public let session: SessionSummary
    public let state: AttentionState
    /// Seconds since this session's last activity (drives the age label + ember fade).
    public let age: TimeInterval
    public let nowLine: NowLine?
    /// The task quote: the last user message (mains) / the Agent description a
    /// subagent was spawned with (its own first user turn). nil when none is found.
    public let taskQuote: String?
    /// Subagents spawned by this token, nested in arrival (spawn) order.
    public let children: [FleetToken]

    public init(session: SessionSummary, state: AttentionState, age: TimeInterval,
                nowLine: NowLine?, taskQuote: String?, children: [FleetToken] = []) {
        self.session = session
        self.state = state
        self.age = age
        self.nowLine = nowLine
        self.taskQuote = taskQuote
        self.children = children
    }

    public var id: String { session.id }
    public var tier: ModelTier { session.tier }
    public var isSubagent: Bool { session.isSubagent }
    /// This token's own cost plus every nested subagent's — what the seat is
    /// burning right now, rolled up.
    public var rolledCost: Double { session.cost + children.reduce(0) { $0 + $1.rolledCost } }
    /// BLOCKED is STILL: the heartbeat must never tick a blocked seat (motion is
    /// evidence of work; a stall is the ABSENCE of motion). The driver keys off this.
    public var isStill: Bool { state == .blocked }
}

// MARK: - Collision (two agents in one repo)

public struct FleetCollision: Sendable, Equatable {
    /// How many non-subagent sessions in the bay are actively editing.
    public let count: Int
    public init(count: Int) { self.count = count }
    /// The quiet one-line warning on the bay header (VISION 4.3 — awareness, not a
    /// lock: it can't prevent anything and must not pretend to).
    public var message: String { "\(count) sessions editing this repo — overlap possible" }
}

// MARK: - Bay (one repo's stable place on the floor)

public struct FleetBay: Identifiable, Sendable, Equatable {
    /// Stable identity — the cwd (or a project-name fallback when cwd is empty).
    public let key: String
    /// Display name — the repo/project basename.
    public let project: String
    /// The seat this bay claimed on first sight; bays render in ascending rank and
    /// NEVER re-sort.
    public let arrivalRank: Int
    /// Top-level tokens (mains + any orphan subagents), in arrival order.
    public let tokens: [FleetToken]
    public let collision: FleetCollision?

    public init(key: String, project: String, arrivalRank: Int,
                tokens: [FleetToken], collision: FleetCollision?) {
        self.key = key
        self.project = project
        self.arrivalRank = arrivalRank
        self.tokens = tokens
        self.collision = collision
    }

    public var id: String { key }

    /// The machine this bay lives on — every token in a bay shares a machine (the
    /// bay key is machine-namespaced for remotes). Drives the bay's machine chip.
    public var machineID: String { tokens.first?.session.machineID ?? Machine.localID }
    public var isRemote: Bool { machineID != Machine.localID }

    /// Every token in the bay, subagents flattened in — for counts and subtotals.
    public var allTokens: [FleetToken] {
        tokens.flatMap { [$0] + $0.children }
    }
    /// Bay cost subtotal (mains + nested subagents).
    public var costSubtotal: Double { tokens.reduce(0) { $0 + $1.rolledCost } }
    /// Freshest activity in the bay — drives the ember fade + the header age.
    public var lastActivity: Date? { allTokens.compactMap { $0.session.lastActivity }.max() }
    /// Seconds since the bay last did anything (min age across its tokens).
    public var age: TimeInterval { allTokens.map(\.age).min() ?? .greatestFiniteMagnitude }
    public var blockedCount: Int { allTokens.filter { $0.state == .blocked }.count }
    public var liveCount: Int { allTokens.filter { $0.session.isActive }.count }
    /// A bay whose every token has gone quiet — compresses to a dimmed line and
    /// sinks visually via the ember fade, NOT by reordering.
    public var isIdle: Bool { allTokens.allSatisfy { $0.state == .idle } }
}

// MARK: - The board

public struct FleetBoard: Sendable, Equatable {
    public let bays: [FleetBay]
    /// Per-state token counts across the whole floor (for the header + selfcheck).
    public let stateCounts: [AttentionState: Int]

    public init(bays: [FleetBay], stateCounts: [AttentionState: Int]) {
        self.bays = bays
        self.stateCounts = stateCounts
    }

    /// The window a session stays on the floor after its last activity (a bit
    /// beyond the 15m live threshold so a cooling bay shows as embers for a while).
    public static let window: TimeInterval = AttentionBoard.defaultWindow

    public func count(_ s: AttentionState) -> Int { stateCounts[s] ?? 0 }
    public var blockedCount: Int { count(.blocked) }
    public var runningCount: Int { count(.running) }
    public var waitingCount: Int { count(.waiting) }
    public var idleCount: Int { count(.idle) }

    /// Total tokens on the floor (mains + nested subagents).
    public var tokenCount: Int { bays.reduce(0) { $0 + $1.allTokens.count } }
    /// Main (top-level, non-subagent) tokens.
    public var mainCount: Int {
        bays.reduce(0) { $0 + $1.tokens.filter { !$0.isSubagent }.count }
    }
    public var subagentCount: Int { tokenCount - mainCount }
    public var totalCost: Double { bays.reduce(0) { $0 + $1.costSubtotal } }
    public var collisions: [FleetBay] { bays.filter { $0.collision != nil } }

    /// The bay a session belongs to — its cwd, or a project-name fallback. In the
    /// Cross-Machine Fleet a remote's bay is namespaced by its machine id so a repo
    /// open on BOTH machines (e.g. `~/Developer/webapp` on this Mac and on workstation)
    /// gets two distinct bays, each tagged with its machine — never one merged pile.
    /// Local bays keep the bare cwd key (so existing single-machine layout is
    /// unchanged); only remote bays carry the machine prefix.
    public static func bayKey(_ s: SessionSummary) -> String {
        let base = s.cwd.isEmpty ? "proj:\(s.project)" : s.cwd
        return s.machineID == Machine.localID ? base : "\(s.machineID)\u{1}\(base)"
    }

    /// Build the floor. Returns the board AND the advanced arrival ledger — the
    /// caller keeps the ledger on a real refresh (to persist new seats) and
    /// discards it on a body-time rebuild (so `now`-driven state changes reclassify
    /// tokens WITHOUT the layout ever shifting).
    ///
    /// Stability guarantee: bay and token order come SOLELY from the arrival
    /// ledger — never from state, cost, or recency — so no classification change
    /// can reorder the floor.
    public static func build(sessions: [SessionSummary],
                             signals: [String: AttentionSignals],
                             now: Date,
                             arrival: ArrivalLedger,
                             window: TimeInterval = window) -> (board: FleetBoard, arrival: ArrivalLedger) {
        var arrival = arrival

        // 1. Everything in-window (mains + subagents — subagents nest, so they
        //    ride the same window as their parent).
        let inWindow = sessions.filter { s in
            guard let last = s.lastActivity else { return false }
            let age = now.timeIntervalSince(last)
            return age >= 0 && age <= window
        }

        // 2. Claim seats in a deterministic "first activity claims the seat" order:
        //    oldest-active first, id as tiebreak. Idempotent, so existing seats are
        //    untouched and only genuinely-new bays/sessions advance the ledger.
        let claimOrder = inWindow.sorted {
            let a = $0.lastActivity ?? .distantPast, b = $1.lastActivity ?? .distantPast
            return a != b ? a < b : $0.id < $1.id
        }
        for s in claimOrder {
            _ = arrival.claim(bayKey(s))
            _ = arrival.claim(s.id)
        }

        // 3. One token per session (state classified against `now`).
        func makeToken(_ s: SessionSummary, children: [FleetToken] = []) -> FleetToken {
            let age = now.timeIntervalSince(s.lastActivity ?? now)
            var sig = signals[s.id] ?? AttentionSignals(lastEventAt: s.lastActivity)
            if sig.lastEventAt == nil { sig.lastEventAt = s.lastActivity }
            let state = AttentionState.classify(sig, now: now)
            let nowLine: FleetToken.NowLine? = sig.lastToolName.map {
                FleetToken.NowLine(tool: $0, detail: sig.lastToolDetail ?? "")
            }
            let quote = s.lastUserMessage.flatMap { q -> String? in
                let t = q.trimmingCharacters(in: .whitespacesAndNewlines)
                return t.isEmpty ? nil : t
            }
            return FleetToken(session: s, state: state, age: age,
                              nowLine: nowLine, taskQuote: quote, children: children)
        }

        // 4. Nest subagents under their parent main (directory-convention join).
        let mains = inWindow.filter { !$0.isSubagent }
        let mainIDs = Set(mains.map(\.id))
        var childrenByParent: [String: [SessionSummary]] = [:]
        var orphanSubagents: [SessionSummary] = []
        for sub in inWindow where sub.isSubagent {
            if let parent = sub.parentSessionID, mainIDs.contains(parent) {
                childrenByParent[parent, default: []].append(sub)
            } else {
                orphanSubagents.append(sub)   // parent gone/idle — still real work
            }
        }
        func rank(_ key: String) -> Int { arrival.rank(key) ?? Int.max }

        // 5. Top-level tokens: mains (with nested children) + orphan subagents.
        var topLevel: [FleetToken] = mains.map { m in
            let kids = (childrenByParent[m.id] ?? [])
                .sorted { rank($0.id) < rank($1.id) }
                .map { makeToken($0) }
            return makeToken(m, children: kids)
        }
        topLevel.append(contentsOf: orphanSubagents.map { makeToken($0) })

        // 6. Group into bays; order tokens within a bay + bays themselves purely by
        //    arrival rank (the stability guarantee).
        var byBay: [String: [FleetToken]] = [:]
        for t in topLevel { byBay[bayKey(t.session), default: []].append(t) }

        var bays: [FleetBay] = byBay.map { (key, toks) in
            let ordered = toks.sorted { rank($0.id) < rank($1.id) }
            let project = ordered.first?.session.project ?? "—"
            // Collision: 2+ non-subagent, non-idle sessions in the repo that have
            // touched files (recent edit overlap possible). Subagents don't count —
            // their parent orchestration owns them.
            let editors = ordered.filter {
                !$0.isSubagent && $0.state != .idle && $0.session.fileEdits > 0
            }
            let collision = editors.count >= 2 ? FleetCollision(count: editors.count) : nil
            return FleetBay(key: key, project: project, arrivalRank: rank(key),
                            tokens: ordered, collision: collision)
        }
        bays.sort { $0.arrivalRank < $1.arrivalRank }

        // 7. Whole-floor per-state counts (every token, subagents included).
        var counts: [AttentionState: Int] = [:]
        for bay in bays { for t in bay.allTokens { counts[t.state, default: 0] += 1 } }

        return (FleetBoard(bays: bays, stateCounts: counts), arrival)
    }
}

// MARK: - The event heartbeat (the ambient signal Custom is proudest of)
//
// "Motion is evidence. Nothing moves unless the disk did." The RUNNING dot does
// not pulse on a timer — it ticks ONCE PER transcript event streamed by
// `FileTailer`, coalesced to ≤4/s. The reference is the hard-disk activity LED,
// the most honest ambient indicator computing ever shipped. This is the pure
// coalescer; the driver (app side) wires it to real FileTailer appends.

public struct HeartbeatCoalescer: Sendable {
    /// Ceiling on visible ticks — a busy agent reads as fast work, not a strobe.
    public static let maxRate: Double = 4                      // ticks / second
    public static let minInterval: TimeInterval = 1.0 / maxRate // 0.25s

    private var lastTick: [String: Date] = [:]
    public init() {}

    /// Register a real disk event for session `id` at `time`. Returns true iff it
    /// should emit a visible tick. Two rules:
    ///  • `isStill` (BLOCKED) sessions NEVER tick — a stall is the absence of
    ///    motion, so a blocked seat holds perfectly still (that stillness IS the
    ///    alarm, alongside the strip + dock badge).
    ///  • events closer than `minInterval` to the last emitted tick coalesce away,
    ///    holding the rate at ≤4/s no matter how fast the file grows.
    public mutating func register(session id: String, at time: Date, isStill: Bool) -> Bool {
        guard !isStill else { return false }
        if let last = lastTick[id], time.timeIntervalSince(last) < Self.minInterval {
            return false
        }
        lastTick[id] = time
        return true
    }

    /// Forget a session that has left the floor (frees its coalescing state).
    public mutating func drop(_ id: String) { lastTick[id] = nil }
}
