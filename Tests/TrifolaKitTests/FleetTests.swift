import Foundation
import Testing
@testable import TrifolaKit

// The Fleet Board is the presence instrument — its whole point is SPATIAL
// STABILITY, so test the invariant hard: a state change must NEVER reorder bays.
// Plus subagent nesting, the shared-cwd collision chip, the event-heartbeat
// coalescer (≤4/s, BLOCKED emits none), and the now-line extraction that feeds
// every token row.

private let t0 = Date(timeIntervalSince1970: 1_780_000_000)
private func at(_ o: TimeInterval) -> Date { t0.addingTimeInterval(o) }

private func iso(_ off: TimeInterval) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: t0.addingTimeInterval(off))
}
private func data(_ ls: [String]) -> [Data] { ls.map { Data($0.utf8) } }

// A main session `ageSecs` old, rooted at `cwd`.
private func main(_ id: String, cwd: String, ageSecs: TimeInterval,
                  cost: Double = 1, edits: Int = 0, quote: String? = nil) -> SessionSummary {
    SessionSummary(id: id, project: (cwd as NSString).lastPathComponent, cwd: cwd,
                   model: "claude-opus-4-8", lastActivity: at(-ageSecs), messageCount: 5,
                   usage: SessionUsage(inputTokens: Int(cost / 15 * 1_000_000)),
                   contextWeight: 1000, filePath: "\(cwd)/\(id).jsonl",
                   lastUserMessage: quote, fileEdits: edits)
}

// A subagent under `parent`, sharing its cwd (directory-convention join).
private func subagent(_ stem: String, parent: String, cwd: String, ageSecs: TimeInterval,
                      cost: Double = 0.5, quote: String? = nil) -> SessionSummary {
    SessionSummary(id: "\(parent)/\(stem)", project: (cwd as NSString).lastPathComponent, cwd: cwd,
                   model: "claude-opus-4-8", lastActivity: at(-ageSecs), messageCount: 3,
                   usage: SessionUsage(inputTokens: Int(cost / 15 * 1_000_000)),
                   contextWeight: 500, filePath: "\(cwd)/\(parent)/subagents/agent-\(stem).jsonl",
                   lastUserMessage: quote)
}

private func blockedSig(ageSecs: TimeInterval) -> AttentionSignals {
    AttentionSignals(lastEventAt: at(-ageSecs), lastKind: .toolUse,
                     hasDanglingToolUse: true, danglingToolUseAt: at(-ageSecs),
                     lastToolName: "Bash", lastToolDetail: "approval")
}

// MARK: - Arrival-order stability (the whole point)

@Suite("Fleet arrival order")
struct FleetArrivalTests {

    @Test func bayOrderIsClaimedByArrivalNotState() {
        // Two bays; A is older-active (arrives first), B second.
        let a = main("a", cwd: "/repo/A", ageSecs: 100)
        let b = main("b", cwd: "/repo/B", ageSecs: 10)
        let (board1, ledger1) = FleetBoard.build(sessions: [a, b], signals: [:],
                                                 now: at(0), arrival: ArrivalLedger())
        #expect(board1.bays.map(\.key) == ["/repo/A", "/repo/B"])

        // Now A goes BLOCKED (worst state) AND the input order flips. A sorted table
        // would jump A to the top; the Floor must NOT move it.
        let (board2, _) = FleetBoard.build(sessions: [b, a],
                                           signals: ["a": blockedSig(ageSecs: 100)],
                                           now: at(0), arrival: ledger1)
        #expect(board2.bays.map(\.key) == ["/repo/A", "/repo/B"])
        #expect(board2.blockedCount == 1)   // state DID change…
        #expect(board2.bays.first?.key == "/repo/A")   // …but the seat did not.
    }

    @Test func newBayAppendsAtTheBottomKeepingOldSeats() {
        let a = main("a", cwd: "/repo/A", ageSecs: 100)
        let b = main("b", cwd: "/repo/B", ageSecs: 50)
        let (_, ledger) = FleetBoard.build(sessions: [a, b], signals: [:],
                                           now: at(0), arrival: ArrivalLedger())
        // A brand-new bay C arrives — it takes the next free seat, never inserting
        // ahead of A or B even though it's the freshest.
        let c = main("c", cwd: "/repo/C", ageSecs: 1)
        let (board, _) = FleetBoard.build(sessions: [c, b, a], signals: [:],
                                          now: at(0), arrival: ledger)
        #expect(board.bays.map(\.key) == ["/repo/A", "/repo/B", "/repo/C"])
    }

    @Test func bodyRebuildDiscardsLedgerButOrderStaysDeterministic() {
        // Two body-time rebuilds (fresh ledger each, as `fleetBoard(now:)` does with
        // its read-only stored ledger) must produce identical order.
        let a = main("a", cwd: "/repo/A", ageSecs: 100)
        let b = main("b", cwd: "/repo/B", ageSecs: 10)
        let seed = ArrivalLedger()
        let o1 = FleetBoard.build(sessions: [a, b], signals: [:], now: at(0), arrival: seed).board.bays.map(\.key)
        let o2 = FleetBoard.build(sessions: [b, a], signals: [:], now: at(30), arrival: seed).board.bays.map(\.key)
        #expect(o1 == o2)
    }
}

// MARK: - Subagent nesting

@Suite("Fleet subagent nesting")
struct FleetNestingTests {

    @Test func subagentNestsUnderItsParentMain() {
        let m = main("m1", cwd: "/repo/A", ageSecs: 5)
        let s1 = subagent("x", parent: "m1", cwd: "/repo/A", ageSecs: 8, quote: "build it")
        let s2 = subagent("y", parent: "m1", cwd: "/repo/A", ageSecs: 3, quote: "test it")
        let (board, _) = FleetBoard.build(sessions: [m, s1, s2], signals: [:],
                                          now: at(10), arrival: ArrivalLedger())
        #expect(board.bays.count == 1)
        let bay = board.bays[0]
        #expect(bay.tokens.count == 1)                 // one top-level seat (the main)
        #expect(bay.tokens[0].id == "m1")
        #expect(bay.tokens[0].children.count == 2)     // both subagents nested under it
        let allSubs = bay.tokens[0].children.allSatisfy(\.isSubagent)
        #expect(allSubs)
        #expect(bay.allTokens.count == 3)              // flattened: main + 2 subs
        #expect(board.mainCount == 1)
        #expect(board.subagentCount == 2)
    }

    @Test func subagentSharesTheParentsBayNotItsOwn() {
        let m = main("m1", cwd: "/repo/A", ageSecs: 5)
        let s = subagent("x", parent: "m1", cwd: "/repo/A", ageSecs: 4)
        let (board, _) = FleetBoard.build(sessions: [m, s], signals: [:],
                                          now: at(10), arrival: ArrivalLedger())
        #expect(board.bays.count == 1)                 // NOT two bays
    }

    @Test func orphanSubagentWhoseParentIsGoneShowsAtTopLevel() {
        // Parent main isn't in the pool (idle/gone) — the subagent is still real
        // work, so it surfaces as a top-level seat in its cwd's bay rather than
        // vanishing.
        let s = subagent("x", parent: "ghost", cwd: "/repo/A", ageSecs: 4)
        let (board, _) = FleetBoard.build(sessions: [s], signals: [:],
                                          now: at(10), arrival: ArrivalLedger())
        #expect(board.bays.count == 1)
        #expect(board.bays[0].tokens.count == 1)
        #expect(board.bays[0].tokens[0].isSubagent)
    }
}

// MARK: - Collision detection

@Suite("Fleet collision")
struct FleetCollisionTests {

    @Test func twoMainsEditingOneRepoRaiseTheCollisionChip() {
        let a = main("a", cwd: "/repo/A", ageSecs: 5, edits: 3)
        let b = main("b", cwd: "/repo/A", ageSecs: 8, edits: 1)
        let (board, _) = FleetBoard.build(sessions: [a, b], signals: [:],
                                          now: at(10), arrival: ArrivalLedger())
        #expect(board.bays.count == 1)
        #expect(board.bays[0].collision != nil)
        #expect(board.bays[0].collision?.count == 2)
        #expect(board.collisions.count == 1)
    }

    @Test func oneEditorIsNoCollision() {
        let a = main("a", cwd: "/repo/A", ageSecs: 5, edits: 3)
        let b = main("b", cwd: "/repo/A", ageSecs: 8, edits: 0)   // hasn't touched files
        let (board, _) = FleetBoard.build(sessions: [a, b], signals: [:],
                                          now: at(10), arrival: ArrivalLedger())
        #expect(board.bays[0].collision == nil)
    }

    @Test func subagentsDoNotCountAsCollidingEditors() {
        // A parent main editing + its own subagent editing is NOT a collision —
        // the subagent is the parent's own fan-out, not a second human's session.
        let m = main("m1", cwd: "/repo/A", ageSecs: 5, edits: 4)
        let s = subagent("x", parent: "m1", cwd: "/repo/A", ageSecs: 4)
        let (board, _) = FleetBoard.build(sessions: [m, s], signals: [:],
                                          now: at(10), arrival: ArrivalLedger())
        #expect(board.bays[0].collision == nil)
    }

    @Test func idleEditorsDoNotCollide() {
        // Two sessions that edited the repo but have both gone quiet — no live
        // overlap risk, so no chip.
        let a = main("a", cwd: "/repo/A", ageSecs: 20 * 60, edits: 3)
        let b = main("b", cwd: "/repo/A", ageSecs: 21 * 60, edits: 2)
        let (board, _) = FleetBoard.build(sessions: [a, b], signals: [:],
                                          now: at(0), arrival: ArrivalLedger())
        #expect(board.bays[0].collision == nil)
        #expect(board.bays[0].isIdle)
    }
}

// MARK: - Board aggregates + windowing

@Suite("Fleet board aggregates")
struct FleetAggregateTests {

    @Test func perStateCountsAndCostSubtotalRollUp() {
        let a = main("a", cwd: "/repo/A", ageSecs: 5, cost: 10)     // running
        let b = main("b", cwd: "/repo/A", ageSecs: 50, cost: 4)     // blocked (via sig)
        let sub = subagent("x", parent: "a", cwd: "/repo/A", ageSecs: 6, cost: 2)
        let (board, _) = FleetBoard.build(
            sessions: [a, b, sub],
            signals: ["b": blockedSig(ageSecs: 50)],
            now: at(0), arrival: ArrivalLedger())
        #expect(board.blockedCount == 1)
        #expect(board.runningCount == 2)   // a + its subagent
        // Bay subtotal rolls the main + nested subagent + the other main. The helper
        // mints tokens from the `cost:` nominal at the OLD opus $15/M, so at the new
        // $5/M each re-prices to 1/3: (10+4+2)/3 ≈ 5.33 (Int-token truncation → 5.333325).
        #expect(abs(board.bays[0].costSubtotal - 5.333325) < 0.01)
        #expect(abs(board.totalCost - 5.333325) < 0.01)
    }

    @Test func excludesSessionsBeyondTheWindow() {
        let fresh = main("a", cwd: "/repo/A", ageSecs: 30)
        let old = main("b", cwd: "/repo/B", ageSecs: FleetBoard.window + 60)
        let (board, _) = FleetBoard.build(sessions: [fresh, old], signals: [:],
                                          now: at(0), arrival: ArrivalLedger())
        #expect(board.bays.map(\.key) == ["/repo/A"])
    }
}

// MARK: - The now-line (feeds every token row)

@Suite("Fleet now-line")
struct FleetNowLineTests {

    @Test func tailWalkCapturesTheFreshestToolAndPath() {
        let lines = data([
            #"{"type":"assistant","timestamp":"\#(iso(0))","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","id":"t1","name":"Read","input":{"file_path":"/tmp/x/old.swift"}}]}}"#,
            #"{"type":"user","timestamp":"\#(iso(2))","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"ok"}]}}"#,
            #"{"type":"assistant","timestamp":"\#(iso(4))","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","id":"t2","name":"Write","input":{"file_path":"/tmp/x/FleetBoard.swift"}}]}}"#,
        ])
        let sig = AttentionSignals.extract(fromTailLines: lines)
        #expect(sig.lastToolName == "Write")                       // freshest wins
        #expect(sig.lastToolDetail?.contains("FleetBoard.swift") == true)
    }

    @Test func nowLineFlowsIntoTheToken() {
        let m = main("m1", cwd: "/repo/A", ageSecs: 3)
        let sig = AttentionSignals(lastEventAt: at(-3), lastKind: .toolUse,
                                   lastToolName: "Edit", lastToolDetail: "Sources/Fleet.swift")
        let (board, _) = FleetBoard.build(sessions: [m], signals: ["m1": sig],
                                          now: at(0), arrival: ArrivalLedger())
        let tok = board.bays[0].tokens[0]
        #expect(tok.nowLine?.tool == "Edit")
        #expect(tok.nowLine?.detail == "Sources/Fleet.swift")
    }
}

// MARK: - The event heartbeat (the ambient signal)

@Suite("Fleet heartbeat")
struct FleetHeartbeatTests {

    @Test func aRealEventEmitsExactlyOneTick() {
        var h = HeartbeatCoalescer()
        let first = h.register(session: "s", at: at(0), isStill: false)
        #expect(first)
    }

    @Test func eventsCloserThanTheRateCoalesceAway() {
        var h = HeartbeatCoalescer()
        let e0 = h.register(session: "s", at: at(0), isStill: false)     // tick
        let e1 = h.register(session: "s", at: at(0.1), isStill: false)   // <0.25 → dropped
        let e2 = h.register(session: "s", at: at(0.3), isStill: false)   // 0.3 > 0.25 → tick
        #expect(e0)
        #expect(!e1)
        #expect(e2)
    }

    @Test func aBurstHoldsAtFourPerSecond() {
        var h = HeartbeatCoalescer()
        var ticks = 0
        for i in 0..<12 {                                   // 12 events over 1.1s at 0.1s
            if h.register(session: "s", at: at(Double(i) * 0.1), isStill: false) { ticks += 1 }
        }
        #expect(ticks == 4)                                 // ≤4/s — a busy agent, not a strobe
    }

    @Test func blockedSeatsAreStillAndNeverTick() {
        var h = HeartbeatCoalescer()
        var ticks = 0
        for i in 0..<12 {
            if h.register(session: "blocked", at: at(Double(i) * 0.1), isStill: true) { ticks += 1 }
        }
        #expect(ticks == 0)     // a stall is the ABSENCE of motion
    }

    @Test func distinctSessionsCoalesceIndependently() {
        var h = HeartbeatCoalescer()
        let a0 = h.register(session: "a", at: at(0), isStill: false)
        let b0 = h.register(session: "b", at: at(0), isStill: false)   // different id, own budget
        let a1 = h.register(session: "a", at: at(0.05), isStill: false)
        #expect(a0)
        #expect(b0)
        #expect(!a1)
    }
}
