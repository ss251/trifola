import Foundation
import Testing
@testable import TrifolaKit

// Synthetic fixtures preserve the real Claude JSONL envelope and tool schemas
// observed locally on 2026-07-10. No transcript content is copied from disk.
@Suite("Attention classifier regressions — cmux failure classes")
struct AttentionRegressionTests {
    private let base = Date(timeIntervalSince1970: 1_780_000_000)

    private func timestamp(_ offset: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: base.addingTimeInterval(offset))
    }

    private func signals(_ jsonl: [String]) -> AttentionSignals {
        AttentionSignals.extract(fromTailLines: jsonl.map { Data($0.utf8) })
    }

    @Test func parentWaitingOnForegroundAgentCallIsRunning() {
        let fixture = [
            #"{"type":"user","timestamp":"\#(timestamp(0))","message":{"content":"Investigate the failure"}}"#,
            #"{"type":"assistant","timestamp":"\#(timestamp(5))","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","id":"toolu_agent","name":"Agent","input":{"description":"Inspect tests","prompt":"Find the cause","subagent_type":"Explore","model":"sonnet"}}]}}"#,
        ]
        let extracted = signals(fixture)

        #expect(extracted.hasDanglingToolUse)
        #expect(extracted.lastToolName == "Agent")
        let classification = AttentionState.classifyDetailed(
            extracted, now: base.addingTimeInterval(5 + 90))
        #expect(classification.state == .running)
        #expect(classification.confidence == .high)
        #expect(classification.reason.contains("subagent"))
    }

    @Test func parentWaitingOnBackgroundTaskOutputIsRunning() {
        let fixture = [
            #"{"type":"assistant","timestamp":"\#(timestamp(5))","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","id":"toolu_output","name":"TaskOutput","input":{"task_id":"agent-123","block":true,"timeout":30000}}]}}"#,
        ]
        let extracted = signals(fixture)

        #expect(extracted.hasDanglingToolUse)
        #expect(AttentionState.classify(
            extracted, now: base.addingTimeInterval(5 + 90)) == .running)
    }

    @Test func ordinaryCompletedTurnIsIdleNotNeedsInput() {
        let fixture = [
            #"{"type":"assistant","timestamp":"\#(timestamp(5))","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"Implementation and tests are complete."}]}}"#,
        ]
        let extracted = signals(fixture)

        #expect(AttentionState.classify(
            extracted, now: base.addingTimeInterval(10)) == .idle)
    }

    @Test(arguments: [
        "Permission is required to continue. Allow this command? (y/N)",
        "Do you want me to proceed? yes/no",
        "Please approve the plan so I can continue.",
    ])
    func explicitHumanAnswerShapeIsWaiting(text: String) {
        let fixture = [
            #"{"type":"assistant","timestamp":"\#(timestamp(5))","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"\#(text)"}]}}"#,
        ]
        let extracted = signals(fixture)

        #expect(AttentionState.classify(
            extracted, now: base.addingTimeInterval(10)) == .waiting)
    }

    @Test func danglingAskUserQuestionBecomesBlocked() {
        let fixture = [
            #"{"type":"assistant","timestamp":"\#(timestamp(5))","message":{"stop_reason":"tool_use","content":[{"type":"tool_use","id":"toolu_question","name":"AskUserQuestion","input":{"questions":[{"question":"Choose a release mode","header":"Mode","options":[],"multiSelect":false}]}}]}}"#,
        ]
        let extracted = signals(fixture)

        #expect(AttentionState.classify(
            extracted, now: base.addingTimeInterval(5 + 31)) == .blocked)
    }

    @Test func attentionBoardRowCarriesClassifierConfidenceAndReason() {
        let fixture = [
            #"{"type":"assistant","timestamp":"\#(timestamp(5))","message":{"stop_reason":"end_turn","content":[{"type":"text","text":"Please approve the plan so I can continue."}]}}"#,
        ]
        let session = SessionSummary(
            id: "row", project: "trifola", cwd: "/repo/trifola",
            model: "claude-sonnet-4-6", lastActivity: base.addingTimeInterval(5),
            messageCount: 2, usage: SessionUsage(), contextWeight: 100,
            filePath: "/repo/trifola/row.jsonl")
        let board = AttentionBoard.build(
            sessions: [session], signals: ["row": signals(fixture)],
            now: base.addingTimeInterval(10))
        let row = try! #require(board.items.first)

        #expect(row.state == .waiting)
        #expect(row.classifierConfidence == .high)
        #expect(row.classifierReason == "assistant requested plan approval")
        #expect(row.classifierDiagnostic == "high: assistant requested plan approval")
    }
}
