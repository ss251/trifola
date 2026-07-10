import Foundation
import Testing
@testable import TrifolaKit

@Suite("Overview verdict sentence")
struct VerdictSentenceTests {
    private func item(_ id: String, project: String,
                      state: AttentionState, age: TimeInterval = 10) -> AttentionItem {
        let session = SessionSummary(
            id: id, project: project, cwd: "/tmp/\(project)", model: "sonnet",
            lastActivity: Date(timeIntervalSince1970: 1_800_000_000 - age),
            messageCount: 1, usage: SessionUsage(inputTokens: 1), contextWeight: 1,
            filePath: "/tmp/\(project)/\(id).jsonl")
        return AttentionItem(session: session, state: state, age: age)
    }

    private func board(_ items: [AttentionItem]) -> AttentionBoard {
        var counts: [AttentionState: Int] = [:]
        for item in items { counts[item.state, default: 0] += 1 }
        return AttentionBoard(items: items, counts: counts)
    }

    @Test func runningFleetAnswersCalmly() {
        let b = board([
            item("1", project: "one", state: .running),
            item("2", project: "two", state: .running),
            item("3", project: "three", state: .running),
        ])
        #expect(VerdictSentenceBuilder.sentence(
            board: b, todayCost: 285, sevenCompleteDayMean: 250)
            == "Nothing needs you · 3 running calmly · $285 today — pace normal")
    }

    @Test func quietFleetIsDistinctFromRunning() {
        let b = board([])
        #expect(VerdictSentenceBuilder.sentence(
            board: b, todayCost: 0, sevenCompleteDayMean: 0)
            == "Nothing needs you · fleet is quiet · $0 today — pace normal")
    }

    @Test func idleOnlyFleetIsAlsoQuiet() {
        let b = board([item("old", project: "archive", state: .idle, age: 20 * 60)])
        #expect(VerdictSentenceBuilder.sentence(
            board: b, todayCost: 4, sevenCompleteDayMean: 4)
            == "Nothing needs you · fleet is quiet · $4 today — pace normal")
    }

    @Test func needsYouLeadsWithWorstAttentionItem() {
        let b = board([
            item("blocked", project: "webapp", state: .blocked, age: 14 * 60),
            item("running", project: "worker", state: .running),
        ])
        #expect(VerdictSentenceBuilder.sentence(
            board: b, todayCost: 126, sevenCompleteDayMean: 100)
            == "webapp needs you (blocked 14m) · $126 today — pace ↑ 26% vs 7-day")
    }

    @Test func multipleNeedsYouRowsAreCountedWithoutHidingTheLead() {
        let b = board([
            item("blocked", project: "webapp", state: .blocked, age: 90),
            item("waiting", project: "api", state: .waiting, age: 30),
        ])
        #expect(VerdictSentenceBuilder.sentence(
            board: b, todayCost: 74, sevenCompleteDayMean: 100)
            == "webapp + 1 more need you (blocked 1m) · $74 today — pace ↓ 26% vs 7-day")
    }

    @Test func paceToleranceIncludesExactlyTwentyFivePercent() {
        #expect(VerdictSentenceBuilder.pace(todayCost: 125,
                                            sevenCompleteDayMean: 100) == .normal)
        #expect(VerdictSentenceBuilder.pace(todayCost: 75,
                                            sevenCompleteDayMean: 100) == .normal)
        #expect(VerdictSentenceBuilder.pace(todayCost: 126,
                                            sevenCompleteDayMean: 100) == .higher(percent: 26))
        #expect(VerdictSentenceBuilder.pace(todayCost: 74,
                                            sevenCompleteDayMean: 100) == .lower(percent: 26))
    }

    @Test func nonzeroTodayWithNoHistoryDoesNotInventAPercentage() {
        #expect(VerdictSentenceBuilder.pace(todayCost: 10,
                                            sevenCompleteDayMean: 0) == .unavailable)
    }

    @Test func menuBarUsesTheExtractedFleetLine() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let b = board([
            item("b", project: "web", state: .blocked),
            item("r", project: "api", state: .running),
        ])
        let model = MenuBarReducer.model(board: b, cards: [], todayCost: 73, now: now)
        #expect(model.fleetLine == FleetSummaryReducer.fleetLine(board: b, todayCost: 73))
        #expect(model.fleetLine == "1 blocked · 1 running · $73 today")
    }
}
