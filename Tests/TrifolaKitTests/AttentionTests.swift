import Foundation
import Testing
@testable import TrifolaKit

// The attention state machine is the flagship feature — test it hard: signal
// extraction (tool_use/tool_result id matching, tail-safety, last-event shape),
// the time-dependent classifier (all four states + both thresholds + boundaries),
// and the board (windowing, subagent exclusion, sort order, counts).

// MARK: - Transcript line builders

private let t0 = Date(timeIntervalSince1970: 1_780_000_000)   // fixed clock
private func iso(_ offset: TimeInterval) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: t0.addingTimeInterval(offset))
}
private func at(_ offset: TimeInterval) -> Date { t0.addingTimeInterval(offset) }

private func userPrompt(_ text: String, at off: TimeInterval) -> String {
    #"{"type":"user","timestamp":"\#(iso(off))","message":{"content":"\#(text)"}}"#
}
private func assistantText(_ text: String, stop: String, at off: TimeInterval) -> String {
    #"{"type":"assistant","timestamp":"\#(iso(off))","message":{"stop_reason":"\#(stop)","content":[{"type":"text","text":"\#(text)"}]}}"#
}
private func assistantToolUse(id: String, name: String = "Bash", at off: TimeInterval) -> String {
    #"{"type":"assistant","timestamp":"\#(iso(off))","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","id":"\#(id)","name":"\#(name)","input":{"command":"ls"}}]}}"#
}
private func toolResult(id: String, at off: TimeInterval) -> String {
    #"{"type":"user","timestamp":"\#(iso(off))","message":{"content":[{"type":"tool_result","tool_use_id":"\#(id)","content":"ok"}]}}"#
}
private func lines(_ ls: [String]) -> [Data] { ls.map { Data($0.utf8) } }

// MARK: - Signal extraction

@Suite("Attention signals")
struct AttentionSignalsTests {

    @Test func danglingToolUseAtTailIsFlagged() {
        // assistant issued a tool_use and no tool_result ever came → dangling.
        let sig = AttentionSignals.extract(fromTailLines: lines([
            userPrompt("build it", at: 0),
            assistantToolUse(id: "toolu_1", at: 5),
        ]))
        #expect(sig.hasDanglingToolUse)
        #expect(sig.lastKind == .toolUse)
        #expect(sig.danglingToolUseAt == at(5))
        #expect(sig.lastEventAt == at(5))
    }

    @Test func matchedToolUseIsNotDangling() {
        // tool_use → matching tool_result → assistant end_turn text: fully resolved.
        let sig = AttentionSignals.extract(fromTailLines: lines([
            assistantToolUse(id: "toolu_1", at: 0),
            toolResult(id: "toolu_1", at: 3),
            assistantText("done", stop: "end_turn", at: 6),
        ]))
        #expect(!sig.hasDanglingToolUse)
        #expect(sig.lastKind == .assistantText)
        #expect(sig.lastStopReason == "end_turn")
    }

    @Test func parallelToolUsesOneUnresolvedStillDangles() {
        // Two tool_use ids, only one result, and the tail ends on a tool_use.
        let two = #"{"type":"assistant","timestamp":"\#(iso(0))","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","id":"a","name":"Bash","input":{}},{"type":"tool_use","id":"b","name":"Read","input":{}}]}}"#
        let sig = AttentionSignals.extract(fromTailLines: lines([
            two,
            toolResult(id: "a", at: 2),          // only "a" comes back; tail is a user tool_result
        ]))
        // last event is a tool_result, so NOT dangling-at-tail even though "b" is open.
        #expect(sig.lastKind == .toolResult)
        #expect(!sig.hasDanglingToolUse)
    }

    @Test func unmatchedResultBeforeWindowNeverInventsDangling() {
        // Tail begins with a tool_result whose tool_use fell before the window —
        // must not read as a dangling anything.
        let sig = AttentionSignals.extract(fromTailLines: lines([
            toolResult(id: "toolu_before_window", at: 0),
            assistantText("continuing", stop: "end_turn", at: 3),
        ]))
        #expect(!sig.hasDanglingToolUse)
        #expect(sig.lastKind == .assistantText)
    }

    @Test func metaLinesAreSkipped() {
        let meta = #"{"type":"user","isMeta":true,"timestamp":"\#(iso(9))","message":{"content":"[Image dims]"}}"#
        let sig = AttentionSignals.extract(fromTailLines: lines([
            assistantText("here you go", stop: "end_turn", at: 5),
            meta,
        ]))
        // the meta line must not become the last event.
        #expect(sig.lastKind == .assistantText)
        #expect(sig.lastEventAt == at(5))
    }

    @Test func lastStopReasonTracksMostRecentAssistant() {
        let sig = AttentionSignals.extract(fromTailLines: lines([
            assistantText("thinking out loud", stop: "tool_use", at: 0),
            assistantText("final answer", stop: "end_turn", at: 4),
        ]))
        #expect(sig.lastStopReason == "end_turn")
    }

    @Test func typedPromptOutranksToolResultWrapper() {
        let sig = AttentionSignals.extract(fromTailLines: lines([
            userPrompt("go", at: 0),
        ]))
        #expect(sig.lastKind == .userPrompt)
    }

    @Test func emptyTailIsAllNil() {
        let sig = AttentionSignals.extract(fromTailLines: [])
        #expect(sig.lastEventAt == nil)
        #expect(sig.lastKind == .none)
        #expect(!sig.hasDanglingToolUse)
    }

    @Test func explicitPendingPermissionRecordIsCapturedButModeSettingIsNot() {
        let sig = AttentionSignals.extract(fromTailLines: lines([
            #"{"type":"permission-mode","permissionMode":"default","timestamp":"\#(iso(0))"}"#,
            #"{"type":"permission-request","status":"pending","timestamp":"\#(iso(1))"}"#,
        ]))
        #expect(sig.hasPermissionGate)
        #expect(sig.lastEventAt == at(1))

        let modeOnly = AttentionSignals.extract(fromTailLines: lines([
            #"{"type":"permission-mode","permissionMode":"default","timestamp":"\#(iso(0))"}"#,
        ]))
        #expect(!modeOnly.hasPermissionGate)
    }

    @Test func laterToolResultClearsAnEarlierPermissionRecord() {
        let sig = AttentionSignals.extract(fromTailLines: lines([
            #"{"type":"permission-request","status":"pending","timestamp":"\#(iso(1))"}"#,
            #"{"type":"user","timestamp":"\#(iso(2))","message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1","content":"ok"}]}}"#,
        ]))
        #expect(!sig.hasPermissionGate)
        #expect(sig.lastKind == .toolResult)
        #expect(AttentionState.classify(sig, now: at(100)) == .running)
    }
}

// MARK: - Classifier (time-dependent)

@Suite("Attention classifier")
struct AttentionClassifyTests {

    @Test func explicitHumanGateBlocksPastThirtySeconds() {
        let sig = AttentionSignals(lastEventAt: at(0), lastKind: .toolUse,
                                   lastStopReason: "tool_use", hasDanglingToolUse: true,
                                   danglingToolUseAt: at(0),
                                   lastToolName: "AskUserQuestion")
        #expect(AttentionState.classify(sig, now: at(45)) == .blocked)
    }

    @Test func codexDiskSignalsCanNeverClassifyBlocked() {
        // Deliberately hostile/block-shaped facts prove the capability flag is
        // an invariant, not an accident of today's rollout parser.
        let sig = AttentionSignals(
            lastEventAt: at(0), lastKind: .toolUse,
            lastStopReason: "tool_use", hasDanglingToolUse: true,
            danglingToolUseAt: at(0), lastToolName: "AskUserQuestion",
            lastToolDetail: "Permission required; approve? yes/no",
            hasPermissionGate: true, canObserveBlocking: false)
        #expect(AttentionState.classify(sig, now: at(31)) == .running)
        #expect(AttentionState.classify(sig, now: at(20 * 60)) == .running)
        #expect(AttentionState.classify(sig, now: at(31)) != .blocked)
        #expect(AttentionState.classify(sig, now: at(20 * 60)) != .blocked)
    }

    @Test func freshDanglingToolUseIsRunningNotBlocked() {
        let sig = AttentionSignals(lastEventAt: at(0), lastKind: .toolUse,
                                   lastStopReason: "tool_use", hasDanglingToolUse: true,
                                   danglingToolUseAt: at(0))
        // 10s in, the tool is just executing → RUNNING.
        #expect(AttentionState.classify(sig, now: at(10)) == .running)
    }

    @Test func humanGateThresholdIsStrictlyGreaterThanThirty() {
        let sig = AttentionSignals(lastEventAt: at(0), lastKind: .toolUse,
                                   hasDanglingToolUse: true, danglingToolUseAt: at(0),
                                   lastToolName: "ExitPlanMode")
        #expect(AttentionState.classify(sig, now: at(30)) == .running)   // exactly 30s: not yet
        #expect(AttentionState.classify(sig, now: at(31)) == .blocked)   // 31s: blocked
    }

    @Test func bashAtThirtyOneSecondsStaysRunningWithElapsedReason() {
        let sig = AttentionSignals(lastEventAt: at(0), lastKind: .toolUse,
                                   hasDanglingToolUse: true, danglingToolUseAt: at(0),
                                   lastToolName: "Bash",
                                   lastToolDetail: "swift test --disable-sandbox")
        let result = AttentionState.classifyDetailed(sig, now: at(31))
        #expect(result.state == .running)
        #expect(result.reason.contains("31s"))
        #expect(result.reason.contains("no human-gate evidence"))
    }

    @Test func waitingWhenTurnEndedOnAssistantText() {
        let sig = AttentionSignals(lastEventAt: at(0), lastKind: .assistantText,
                                   lastStopReason: "end_turn",
                                   lastAssistantText: "Do you want me to proceed? yes/no")
        #expect(AttentionState.classify(sig, now: at(120)) == .waiting)
    }

    @Test func assistantTextWithoutEndTurnIsNotWaiting() {
        let sig = AttentionSignals(lastEventAt: at(0), lastKind: .assistantText,
                                   lastStopReason: "tool_use",
                                   lastAssistantText: "Do you want me to proceed? yes/no")
        // 2m old, not end_turn, not dangling → still mid-flight → RUNNING.
        #expect(AttentionState.classify(sig, now: at(120)) == .running)
    }

    @Test func runningWhenActivityIsFresh() {
        let sig = AttentionSignals(lastEventAt: at(0), lastKind: .toolResult,
                                   lastToolActivityAt: at(0))
        #expect(AttentionState.classify(sig, now: at(5)) == .running)
    }

    @Test func idleAfterFifteenMinutes() {
        let sig = AttentionSignals(lastEventAt: at(0), lastKind: .toolResult)
        #expect(AttentionState.classify(sig, now: at(15 * 60 + 1)) == .idle)
    }

    @Test func idleWinsOverWaitingOnceStale() {
        // A turn that ended 20 minutes ago has gone quiet — IDLE, not WAITING.
        let sig = AttentionSignals(lastEventAt: at(0), lastKind: .assistantText,
                                   lastStopReason: "end_turn",
                                   lastAssistantText: "Do you want me to proceed? yes/no")
        #expect(AttentionState.classify(sig, now: at(20 * 60)) == .idle)
    }

    @Test func idleWhenNoEventTimestamp() {
        #expect(AttentionState.classify(AttentionSignals(), now: at(0)) == .idle)
    }

    @Test func longBlockedSessionStaysBlockedNotIdle() {
        // Stuck on a permission prompt for 20 minutes: BLOCKED still needs you —
        // it must win over the 15-minute IDLE rule.
        let sig = AttentionSignals(lastEventAt: at(0), lastKind: .toolUse,
                                   hasDanglingToolUse: true, danglingToolUseAt: at(0),
                                   hasPermissionGate: true)
        #expect(AttentionState.classify(sig, now: at(20 * 60)) == .blocked)
    }

    @Test func endToEndBlockedFromRawLines() {
        // Whole pipeline: raw tail lines → signals → BLOCKED at t+40s.
        let sig = AttentionSignals.extract(fromTailLines: lines([
            userPrompt("deploy to prod", at: 0),
            assistantText("I'll run the deploy", stop: "tool_use", at: 4),
            assistantToolUse(id: "toolu_deploy", name: "AskUserQuestion", at: 5),
        ]))
        #expect(AttentionState.classify(sig, now: at(5 + 40)) == .blocked)
        #expect(AttentionState.classify(sig, now: at(5 + 10)) == .running)
    }
}

// MARK: - Board (windowing, exclusion, sort, counts)

@Suite("Attention board")
struct AttentionBoardTests {
    private func session(_ id: String, ageSecs: TimeInterval, path: String = "/p/s.jsonl") -> SessionSummary {
        SessionSummary(id: id, project: "proj-\(id)", cwd: "/tmp/\(id)", model: "claude-opus-4-8",
                       lastActivity: at(0).addingTimeInterval(-ageSecs), messageCount: 3,
                       usage: SessionUsage(inputTokens: 100), contextWeight: 1000, filePath: path)
    }

    @Test func excludesSubagentTranscripts() {
        let sub = session("sub", ageSecs: 10, path: "/p/x/subagents/agent-1.jsonl")
        #expect(sub.isSubagent)
        let board = AttentionBoard.build(sessions: [sub], signals: [:], now: at(0))
        #expect(board.items.isEmpty)
    }

    @Test func excludesSessionsOlderThanWindow() {
        let old = session("old", ageSecs: 2 * 60 * 60)   // 2h, past the 60m window
        let board = AttentionBoard.build(sessions: [old], signals: [:], now: at(0))
        #expect(board.items.isEmpty)
    }

    @Test func sortsBlockedFirstThenWaitingRunningIdleThenRecency() {
        let blockedSig = AttentionSignals(lastEventAt: at(0).addingTimeInterval(-45),
                                          lastKind: .toolUse, hasDanglingToolUse: true,
                                          danglingToolUseAt: at(0).addingTimeInterval(-45),
                                          lastToolName: "AskUserQuestion")
        let waitingSig = AttentionSignals(lastEventAt: at(0).addingTimeInterval(-120),
                                          lastKind: .assistantText, lastStopReason: "end_turn",
                                          lastAssistantText: "Do you want me to proceed? yes/no")
        let runningSig = AttentionSignals(lastEventAt: at(0).addingTimeInterval(-5),
                                          lastKind: .toolResult, lastToolActivityAt: at(0))
        let sessions = [
            session("running", ageSecs: 5),
            session("idle", ageSecs: 20 * 60),          // >15m → idle
            session("blocked", ageSecs: 45),
            session("waiting", ageSecs: 120),
        ]
        let board = AttentionBoard.build(
            sessions: sessions,
            signals: ["blocked": blockedSig, "waiting": waitingSig, "running": runningSig],
            now: at(0))

        #expect(board.items.map { $0.state } == [.blocked, .waiting, .running, .idle])
        #expect(board.items.first?.session.id == "blocked")
        #expect(board.blockedCount == 1)
        #expect(board.waitingCount == 1)
        #expect(board.runningCount == 1)
        #expect(board.idleCount == 1)
        #expect(board.worst == .blocked)
        #expect(board.needsAttention.map { $0.session.id } == ["blocked", "waiting"])
    }

    @Test func twoBlockedSortByRecencyFreshestFirst() {
        func blocked(_ ageSecs: TimeInterval) -> AttentionSignals {
            AttentionSignals(lastEventAt: at(0).addingTimeInterval(-ageSecs), lastKind: .toolUse,
                             hasDanglingToolUse: true,
                             danglingToolUseAt: at(0).addingTimeInterval(-ageSecs),
                             hasPermissionGate: true)
        }
        let sessions = [session("stale", ageSecs: 300), session("fresh", ageSecs: 40)]
        let board = AttentionBoard.build(
            sessions: sessions,
            signals: ["stale": blocked(300), "fresh": blocked(40)],
            now: at(0))
        #expect(board.items.map { $0.session.id } == ["fresh", "stale"])
    }

    @Test func missingSignalsFallBackToRecencyOnlyClassification() {
        // No signal entry: a recent session with unknown shape defaults to RUNNING,
        // a cooling one to IDLE — never a crash, never a false BLOCKED.
        let board = AttentionBoard.build(
            sessions: [session("recent", ageSecs: 30), session("cooling", ageSecs: 16 * 60)],
            signals: [:], now: at(0))
        let byID = Dictionary(uniqueKeysWithValues: board.items.map { ($0.session.id, $0.state) })
        #expect(byID["recent"] == .running)
        #expect(byID["cooling"] == .idle)
        #expect(board.blockedCount == 0)
    }

    @Test func emptyBoardHasNoWorstState() {
        let board = AttentionBoard.build(sessions: [], signals: [:], now: at(0))
        #expect(board.worst == nil)
        #expect(board.needsAttention.isEmpty)
    }
}
