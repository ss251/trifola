import Foundation
import Testing
@testable import TrifolaKit

private let agencyNow = Date(timeIntervalSince1970: 1_800_000_000)

private func agencyItem(_ id: String, project: String,
                        state: AttentionState, age: TimeInterval = 10) -> AttentionItem {
    let session = SessionSummary(
        id: id, project: project, cwd: "/tmp/\(project)", model: "sonnet",
        lastActivity: agencyNow.addingTimeInterval(-age), messageCount: 1,
        usage: SessionUsage(inputTokens: 1), contextWeight: 1,
        filePath: "/tmp/\(project)/\(id).jsonl")
    return AttentionItem(session: session, state: state, age: age)
}

private func agencyBoard(_ items: [AttentionItem]) -> AttentionBoard {
    var counts: [AttentionState: Int] = [:]
    for item in items { counts[item.state, default: 0] += 1 }
    return AttentionBoard(items: items, counts: counts)
}

@Suite("Attention snooze and mute reducer")
struct AttentionSuppressionTests {
    @Test func snoozedBlockedSessionLeavesAlertingCountsButNotLegend() {
        let blocked = agencyItem("blocked", project: "webapp", state: .blocked)
        let running = agencyItem("running", project: "api", state: .running)
        let state = AttentionSuppressionState(
            snoozedUntilBySessionID: ["blocked": agencyNow.addingTimeInterval(3600)])

        let result = AttentionSuppressionReducer.apply(
            to: agencyBoard([blocked, running]), state: state, now: agencyNow)

        #expect(result.rows.count == 2)                 // never hidden
        #expect(result.suppressedRows.map(\.id) == ["blocked"])
        #expect(result.suppressedCount == 1)
        #expect(result.legendSuffix == " · 1 snoozed")
        #expect(result.alertingBoard.blockedCount == 0)
        #expect(result.alertingBoard.runningCount == 1)
        #expect(MenuBarReducer.glyph(board: result.alertingBoard) == .running)
        guard case .snoozed = result.reason(forSessionID: "blocked") else {
            Issue.record("Expected the blocked row to carry its snooze reason")
            return
        }
    }

    @Test func expiryRestoresBlockedSessionAndClearsState() {
        let blocked = agencyItem("blocked", project: "webapp", state: .blocked)
        let state = AttentionSuppressionState(
            snoozedUntilBySessionID: ["blocked": agencyNow.addingTimeInterval(60)])

        let result = AttentionSuppressionReducer.apply(
            to: agencyBoard([blocked]), state: state,
            now: agencyNow.addingTimeInterval(60))

        #expect(result.state.snoozedUntilBySessionID.isEmpty)
        #expect(result.suppressedCount == 0)
        #expect(result.legendSuffix.isEmpty)
        #expect(result.alertingBoard.blockedCount == 1)
        #expect(MenuBarReducer.glyph(board: result.alertingBoard) == .needsYou(blockedCount: 1))
    }

    @Test func projectMuteSuppressesEveryProjectRowAndCanBeUndone() {
        let board = agencyBoard([
            agencyItem("one", project: "webapp", state: .blocked),
            agencyItem("two", project: "webapp", state: .waiting),
            agencyItem("three", project: "api", state: .running),
        ])
        var state = AttentionSuppressionReducer.reduce(
            AttentionSuppressionState(), action: .mute(projectKey: "webapp"), now: agencyNow)
        let muted = AttentionSuppressionReducer.apply(to: board, state: state, now: agencyNow)
        #expect(muted.suppressedCount == 2)
        #expect(muted.alertingBoard.blockedCount == 0)
        #expect(muted.alertingBoard.waitingCount == 0)
        #expect(muted.alertingBoard.runningCount == 1)

        state = AttentionSuppressionReducer.reduce(
            state, action: .unmute(projectKey: "webapp"), now: agencyNow)
        let restored = AttentionSuppressionReducer.apply(to: board, state: state, now: agencyNow)
        #expect(restored.suppressedCount == 0)
        #expect(restored.alertingBoard.blockedCount == 1)
        #expect(restored.alertingBoard.waitingCount == 1)
    }

    @Test func reducerSupportsSnoozeAndUnsnooze() {
        var state = AttentionSuppressionReducer.reduce(
            AttentionSuppressionState(),
            action: .snooze(sessionID: "s", until: agencyNow.addingTimeInterval(3600)),
            now: agencyNow)
        #expect(state.snoozedUntilBySessionID["s"] == agencyNow.addingTimeInterval(3600))
        state = AttentionSuppressionReducer.reduce(
            state, action: .unsnooze(sessionID: "s"), now: agencyNow)
        #expect(state.snoozedUntilBySessionID.isEmpty)
    }

    @Test func tomorrowMeansNextCalendarDayStart() {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "America/New_York")!
        let start = calendar.date(from: DateComponents(
            year: 2026, month: 3, day: 7, hour: 20))!
        let tomorrow = AttentionSuppressionReducer.startOfTomorrow(
            after: start, calendar: calendar)
        let components = calendar.dateComponents([.year, .month, .day, .hour], from: tomorrow)
        #expect(components.year == 2026)
        #expect(components.month == 3)
        #expect(components.day == 8)
        #expect(components.hour == 0)
    }
}

@Suite("Attention suppression store")
struct AttentionSuppressionStoreTests {
    @Test func codableStoreRoundTripsAndPrunesExpiredSnoozes() {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("attention-agency-\(UUID().uuidString)")
        let url = directory.appendingPathComponent("suppression.json")
        let store = AttentionSuppressionStore(url: url)
        let state = AttentionSuppressionState(
            snoozedUntilBySessionID: [
                "expired": agencyNow.addingTimeInterval(-1),
                "active": agencyNow.addingTimeInterval(3600),
            ],
            mutedProjectKeys: ["webapp"])

        #expect(store.save(state))
        let loaded = store.load(now: agencyNow)
        #expect(Set(loaded.snoozedUntilBySessionID.keys) == ["active"])
        #expect(loaded.mutedProjectKeys == ["webapp"])
        #expect(store.load(now: agencyNow) == loaded) // pruned form was persisted
        try? FileManager.default.removeItem(at: directory)
    }

    @Test func defaultPathIsAppOwned() {
        #expect(AttentionSuppressionStore.defaultURL.path
            .contains("Application Support/Trifola/attention-suppression.json"))
    }
}

@Suite("Blocked to running acknowledgment")
struct AttentionRecoveryTests {
    @Test func blockedToRunningFiresOnceAndRunningToRunningDoesNotRestartIt() {
        let blocked = agencyBoard([agencyItem("s", project: "webapp", state: .blocked)])
        let running = agencyBoard([agencyItem("s", project: "webapp", state: .running)])
        var state = AttentionRecoveryReducer.reduce(
            AttentionRecoveryState(), board: blocked, now: agencyNow)
        #expect(state.acknowledgement == nil) // first frame only primes the detector

        state = AttentionRecoveryReducer.reduce(
            state, board: running, now: agencyNow.addingTimeInterval(1))
        let first = try! #require(state.acknowledgement)
        #expect(first.message == "webapp is moving again")
        #expect(first.expiresAt == agencyNow.addingTimeInterval(9))

        state = AttentionRecoveryReducer.reduce(
            state, board: running, now: agencyNow.addingTimeInterval(2))
        #expect(state.acknowledgement == first) // running→running did not fire again
    }

    @Test func acknowledgmentExpiresAtEightSeconds() {
        let existing = UnblockedAcknowledgement(
            sessionID: "s", project: "webapp", startedAt: agencyNow,
            expiresAt: agencyNow.addingTimeInterval(8))
        let state = AttentionRecoveryState(
            previousStatesBySessionID: ["s": .running], acknowledgement: existing)
        let running = agencyBoard([agencyItem("s", project: "webapp", state: .running)])

        #expect(state.activeAcknowledgement(at: agencyNow.addingTimeInterval(7.999)) != nil)
        let expired = AttentionRecoveryReducer.reduce(
            state, board: running, now: agencyNow.addingTimeInterval(8))
        #expect(expired.acknowledgement == nil)
    }

    @Test func latestRecoveryReplacesCurrentAcknowledgment() {
        var state = AttentionRecoveryState(previousStatesBySessionID: [
            "old": .blocked, "new": .blocked,
        ])
        state = AttentionRecoveryReducer.reduce(
            state,
            board: agencyBoard([
                agencyItem("new", project: "api", state: .running, age: 1),
                agencyItem("old", project: "webapp", state: .blocked, age: 20),
            ]),
            now: agencyNow)
        #expect(state.acknowledgement?.sessionID == "new")

        state.previousStatesBySessionID["old"] = .blocked
        state = AttentionRecoveryReducer.reduce(
            state,
            board: agencyBoard([
                agencyItem("old", project: "webapp", state: .running, age: 1),
                agencyItem("new", project: "api", state: .running, age: 2),
            ]),
            now: agencyNow.addingTimeInterval(1))
        #expect(state.acknowledgement?.sessionID == "old")
        #expect(state.acknowledgement?.message == "webapp is moving again")
    }
}
