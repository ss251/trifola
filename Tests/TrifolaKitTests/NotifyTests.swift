import Foundation
import Testing
@testable import TrifolaKit

// WALK-AWAY NOTIFY (frontier #2) — the rising-edge BLOCKED notifier. The whole
// policy is a pure function, so it is tested hard here: the core set-diff (all five
// required transitions), the board-driven plan (content + coalescing over the SAME
// AttentionBoard the dock badge uses), and the opt-in preference's on-disk round-trip.

// MARK: - The pure rising-edge diff (set → set)

@Suite("Notify rising-edge diff")
struct NotifyRisingEdgeTests {

    @Test func quietToBlockedNotifies() {
        // Nothing tracked, one session now blocked → it's a rising edge.
        let (toNotify, newState) = BlockedNotifier.risingEdges(
            previouslyBlocked: [], currentBlocked: ["a"])
        #expect(toNotify == ["a"])
        #expect(newState == ["a"])
    }

    @Test func blockedToBlockedDoesNotRenotify() {
        // Already notified last cycle, still blocked → NO new notification.
        let (toNotify, newState) = BlockedNotifier.risingEdges(
            previouslyBlocked: ["a"], currentBlocked: ["a"])
        #expect(toNotify.isEmpty)
        #expect(newState == ["a"])
    }

    @Test func blockedToUnblockedClears() {
        // It unblocked → nothing to notify, and it's dropped from the tracked set so
        // a future reblock counts as fresh.
        let (toNotify, newState) = BlockedNotifier.risingEdges(
            previouslyBlocked: ["a"], currentBlocked: [])
        #expect(toNotify.isEmpty)
        #expect(newState.isEmpty)
    }

    @Test func multipleSimultaneousFlipsAllRise() {
        // Three flip at once, none tracked → all three are rising edges (the caller
        // coalesces them into one banner).
        let (toNotify, newState) = BlockedNotifier.risingEdges(
            previouslyBlocked: [], currentBlocked: ["a", "b", "c"])
        #expect(toNotify == ["a", "b", "c"])
        #expect(newState == ["a", "b", "c"])
    }

    @Test func unblockThenReblockReNotifies() {
        // Full cycle across three ticks: blocked → cleared → blocked again re-fires.
        var tracked: Set<String> = []
        // tick 1: enters blocked
        var r = BlockedNotifier.risingEdges(previouslyBlocked: tracked, currentBlocked: ["a"])
        #expect(r.toNotify == ["a"])
        tracked = r.newState
        // tick 2: unblocks
        r = BlockedNotifier.risingEdges(previouslyBlocked: tracked, currentBlocked: [])
        #expect(r.toNotify.isEmpty)
        tracked = r.newState
        // tick 3: blocks AGAIN → re-notify (it left the set on the unblock)
        r = BlockedNotifier.risingEdges(previouslyBlocked: tracked, currentBlocked: ["a"])
        #expect(r.toNotify == ["a"])
    }

    @Test func onlyTheNewOneAmongAlreadyBlockedRises() {
        // "a" was already blocked+notified; "b" newly blocks → only "b" rises.
        let (toNotify, newState) = BlockedNotifier.risingEdges(
            previouslyBlocked: ["a"], currentBlocked: ["a", "b"])
        #expect(toNotify == ["b"])
        #expect(newState == ["a", "b"])
    }

    @Test func partialUnblockKeepsTheStillBlockedSilent() {
        // "a","b" tracked; "a" unblocks, "b" stays, "c" newly blocks → only "c" rises,
        // "a" is cleared, "b" stays tracked (silent).
        let (toNotify, newState) = BlockedNotifier.risingEdges(
            previouslyBlocked: ["a", "b"], currentBlocked: ["b", "c"])
        #expect(toNotify == ["c"])
        #expect(newState == ["b", "c"])
    }
}

// MARK: - The board-driven plan (content + coalescing)

@Suite("Notify plan over the board")
struct NotifyPlanTests {
    private let t0 = Date(timeIntervalSince1970: 1_780_000_000)

    private func session(_ id: String, project: String, ageSecs: TimeInterval) -> SessionSummary {
        SessionSummary(id: id, project: project, cwd: "/tmp/\(id)", model: "claude-opus-4-8",
                       lastActivity: t0.addingTimeInterval(-ageSecs), messageCount: 3,
                       usage: SessionUsage(inputTokens: 100), contextWeight: 1000,
                       filePath: "/p/\(id).jsonl")
    }
    /// A signal that classifies as BLOCKED at `t0` (dangling tool_use >30s old).
    private func blockedSig(ageSecs: TimeInterval, tool: String? = nil, detail: String? = nil) -> AttentionSignals {
        AttentionSignals(lastEventAt: t0.addingTimeInterval(-ageSecs), lastKind: .toolUse,
                         lastStopReason: "tool_use", hasDanglingToolUse: true,
                         danglingToolUseAt: t0.addingTimeInterval(-ageSecs),
                         lastToolName: tool, lastToolDetail: detail)
    }
    private func waitingSig(ageSecs: TimeInterval) -> AttentionSignals {
        AttentionSignals(lastEventAt: t0.addingTimeInterval(-ageSecs), lastKind: .assistantText,
                         lastStopReason: "end_turn",
                         lastAssistantText: "Do you want me to proceed? yes/no")
    }

    @Test func singleBlockedNamesProjectAndBlockingAction() {
        let s = session("a", project: "webapp", ageSecs: 45)
        let sig = blockedSig(ageSecs: 45, tool: "Bash", detail: "git push origin main")
        let board = AttentionBoard.build(sessions: [s], signals: ["a": sig], now: t0)
        let plan = BlockedNotifier.plan(board: board, signals: ["a": sig], previouslyBlocked: [])
        let note = try! #require(plan.notification)
        #expect(note.count == 1)
        #expect(note.title == "webapp")
        #expect(note.body == "Bash · git push origin main")
        #expect(note.primarySessionID == "a")
        #expect(plan.newState == ["a"])
    }

    @Test func blockedWithNoToolNameFallsBackGracefully() {
        let s = session("a", project: "webapp", ageSecs: 45)
        let sig = blockedSig(ageSecs: 45)                     // no tool name
        let board = AttentionBoard.build(sessions: [s], signals: ["a": sig], now: t0)
        let plan = BlockedNotifier.plan(board: board, signals: ["a": sig], previouslyBlocked: [])
        #expect(plan.notification?.body == "Blocked — needs you")
    }

    @Test func blockedWithToolButNoDetail() {
        let s = session("a", project: "webapp", ageSecs: 45)
        let sig = blockedSig(ageSecs: 45, tool: "AskUserQuestion")
        let board = AttentionBoard.build(sessions: [s], signals: ["a": sig], now: t0)
        let plan = BlockedNotifier.plan(board: board, signals: ["a": sig], previouslyBlocked: [])
        #expect(plan.notification?.body == "Blocked on AskUserQuestion")
    }

    @Test func simultaneousFlipsCoalesceIntoOneBanner() {
        let sessions = [
            session("a", project: "webapp", ageSecs: 40),
            session("b", project: "api-gateway", ageSecs: 50),
            session("c", project: "knowledge-base", ageSecs: 60),
        ]
        let sigs: [String: AttentionSignals] = [
            "a": blockedSig(ageSecs: 40, tool: "Bash"),
            "b": blockedSig(ageSecs: 50, tool: "Edit"),
            "c": blockedSig(ageSecs: 60, tool: "Write"),
        ]
        let board = AttentionBoard.build(sessions: sessions, signals: sigs, now: t0)
        let plan = BlockedNotifier.plan(board: board, signals: sigs, previouslyBlocked: [])
        let note = try! #require(plan.notification)
        #expect(note.count == 3)
        #expect(note.title == "3 sessions need you")
        // Board order is freshest-first among blocked → webapp (40s) leads.
        #expect(note.sessionIDs == ["a", "b", "c"])
        #expect(note.body.contains("webapp"))
        #expect(note.primarySessionID == "a")
        #expect(plan.newState == ["a", "b", "c"])
    }

    @Test func coalescedBodyCapsAtThreeWithOverflow() {
        let names = ["webapp", "api-gateway", "knowledge-base", "contest", "audit-tool"]
        #expect(BlockedNotifier.coalescedBody(names) == "webapp, api-gateway, knowledge-base & 2 more")
        #expect(BlockedNotifier.coalescedBody(["webapp", "api-gateway"]) == "webapp, api-gateway")
    }

    @Test func steadyStateBlockedProducesNoNotification() {
        // Already tracked, still blocked → plan has no notification but keeps tracking.
        let s = session("a", project: "webapp", ageSecs: 45)
        let sig = blockedSig(ageSecs: 45, tool: "Bash")
        let board = AttentionBoard.build(sessions: [s], signals: ["a": sig], now: t0)
        let plan = BlockedNotifier.plan(board: board, signals: ["a": sig], previouslyBlocked: ["a"])
        #expect(plan.notification == nil)
        #expect(plan.newState == ["a"])
    }

    @Test func onlyBlockedTriggers_waitingAndRunningDoNot() {
        // A WAITING and a RUNNING session are NOT notifications (no-nag doctrine):
        // only BLOCKED ever fires.
        let sessions = [
            session("wait", project: "waiter", ageSecs: 120),
            session("run", project: "runner", ageSecs: 5),
        ]
        let sigs: [String: AttentionSignals] = [
            "wait": waitingSig(ageSecs: 120),
            "run": AttentionSignals(lastEventAt: t0.addingTimeInterval(-5), lastKind: .toolResult,
                                    lastToolActivityAt: t0.addingTimeInterval(-5)),
        ]
        let board = AttentionBoard.build(sessions: sessions, signals: sigs, now: t0)
        // sanity: the board really does classify these as waiting/running, not blocked
        #expect(board.blockedCount == 0)
        let plan = BlockedNotifier.plan(board: board, signals: sigs, previouslyBlocked: [])
        #expect(plan.notification == nil)
        #expect(plan.newState.isEmpty)
    }

    @Test func unblockAcrossPlansClearsThenReblockReNotifies() {
        // End-to-end over the board: blocked (fires) → resolves to waiting (clears) →
        // blocks again (re-fires). Proves the tracked set threads correctly.
        let sBlocked = session("a", project: "webapp", ageSecs: 45)
        let blocked = AttentionBoard.build(sessions: [sBlocked],
                                           signals: ["a": blockedSig(ageSecs: 45, tool: "Bash")], now: t0)
        var plan = BlockedNotifier.plan(board: blocked, signals: ["a": blockedSig(ageSecs: 45, tool: "Bash")],
                                        previouslyBlocked: [])
        #expect(plan.notification != nil)
        var tracked = plan.newState

        // now it resolved to a WAITING turn — no longer blocked → cleared.
        let sWaiting = session("a", project: "webapp", ageSecs: 120)
        let waiting = AttentionBoard.build(sessions: [sWaiting], signals: ["a": waitingSig(ageSecs: 120)], now: t0)
        plan = BlockedNotifier.plan(board: waiting, signals: ["a": waitingSig(ageSecs: 120)],
                                    previouslyBlocked: tracked)
        #expect(plan.notification == nil)
        #expect(plan.newState.isEmpty)
        tracked = plan.newState

        // it blocks AGAIN → re-notify.
        plan = BlockedNotifier.plan(board: blocked, signals: ["a": blockedSig(ageSecs: 45, tool: "Bash")],
                                    previouslyBlocked: tracked)
        #expect(plan.notification != nil)
    }

    @Test func emptyBoardNotifiesNothing() {
        let board = AttentionBoard.build(sessions: [], signals: [:], now: t0)
        let plan = BlockedNotifier.plan(board: board, signals: [:], previouslyBlocked: [])
        #expect(plan.notification == nil)
        #expect(plan.newState.isEmpty)
    }
}

// MARK: - Opt-in preference persistence (app's OWN dir, never ~/.claude)

@Suite("Notify preferences")
struct NotifyPreferencesTests {

    @Test func defaultsToOptInOff() {
        #expect(NotifyPreferences().enabled == false)
    }

    @Test func roundTripsThroughDisk() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("mc-notify-\(UUID().uuidString)", isDirectory: true)
        let url = dir.appendingPathComponent("notify.json")
        defer { try? FileManager.default.removeItem(at: dir) }
        let store = NotifyPreferencesStore(url: url)

        // absent file → default OFF
        #expect(store.load().enabled == false)

        // save ON → reload reads ON
        #expect(store.save(NotifyPreferences(enabled: true)))
        #expect(store.load().enabled == true)

        // back OFF
        #expect(store.save(NotifyPreferences(enabled: false)))
        #expect(store.load().enabled == false)
    }

    @Test func defaultURLLivesInAppOwnDirNotDotClaude() {
        let path = NotifyPreferencesStore.defaultURL.path
        #expect(path.contains("Application Support/Trifola"))
        #expect(!path.contains("/.claude"))
    }
}
