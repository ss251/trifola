import Testing
import Foundation
@testable import TrifolaKit

// MARK: - Menu-bar presence (W4) — the pure reducer behind the tray

@Suite("Menu-bar glyph reducer")
struct MenuBarGlyphTests {

    private func session(_ id: String, cwd: String = "", last: String? = nil) -> SessionSummary {
        SessionSummary(id: id, project: "proj-\(id)", cwd: cwd.isEmpty ? "/tmp/\(id)" : cwd,
                       model: "claude-opus-4-8", lastActivity: Date(), messageCount: 3,
                       usage: SessionUsage(inputTokens: 100), contextWeight: 1000,
                       filePath: "/tmp/\(id)/s.jsonl", lastUserMessage: last)
    }

    private func board(blocked: Int = 0, waiting: Int = 0, running: Int = 0,
                       idle: Int = 0, ages: [AttentionState: [TimeInterval]] = [:]) -> AttentionBoard {
        var items: [AttentionItem] = []
        var counts: [AttentionState: Int] = [:]
        var n = 0
        for (state, count) in [(AttentionState.blocked, blocked), (.waiting, waiting),
                               (.running, running), (.idle, idle)] where count > 0 {
            counts[state] = count
            for i in 0..<count {
                let age = ages[state]?[safe: i] ?? TimeInterval(10 + n)
                items.append(AttentionItem(session: session("s\(n)"), state: state, age: age))
                n += 1
            }
        }
        return AttentionBoard(items: items, counts: counts)
    }

    @Test func emptyBoardIsQuiet() {
        let b = board()
        #expect(MenuBarReducer.glyph(board: b) == .quiet)
        let m = MenuBarReducer.model(board: b, cards: [], todayCost: 0, now: Date())
        #expect(m.fleetLine == "fleet is quiet · $0 today")
        #expect(m.title == nil)
        #expect(m.glyph == .quiet)
    }

    @Test func runningOnlyIsRunning() {
        #expect(MenuBarReducer.glyph(board: board(running: 2)) == .running)
    }

    @Test func waitingOnlyNeedsYouWithZeroCount() {
        // Shipped semantics: needsYou when blocked OR waiting; count = BLOCKED only.
        #expect(MenuBarReducer.glyph(board: board(waiting: 1, running: 1))
                == .needsYou(blockedCount: 0))
    }

    @Test func blockedNeedsYouWithCount() {
        #expect(MenuBarReducer.glyph(board: board(blocked: 2, running: 3))
                == .needsYou(blockedCount: 2))
    }

    @Test func countLabelCapsAtNinePlus() {
        #expect(MenuBarReducer.countLabel(3) == "3")
        #expect(MenuBarReducer.countLabel(9) == "9")
        #expect(MenuBarReducer.countLabel(12) == "9+")
    }

    @Test func blockedRowsSortStuckLongestFirst() {
        // The board sorts freshest-first — triage wants the opposite.
        let b = board(blocked: 2, ages: [.blocked: [40, 400]])
        let m = MenuBarReducer.model(board: b, cards: [], todayCost: 0, now: Date())
        #expect(m.blocked.count == 2)
        #expect(m.blocked.first?.age == 400)
        #expect(m.blocked.last?.age == 40)
    }

    @Test func waitingRowsSortLongestWaitingFirst() {
        let b = board(waiting: 3, ages: [.waiting: [30, 900, 90]])
        let m = MenuBarReducer.model(board: b, cards: [], todayCost: 0, now: Date())
        #expect(m.waiting.map(\.age) == [900, 90, 30])
    }

    @Test func fleetLineOmitsZeroCountsAndAlwaysEndsWithToday() {
        let m = MenuBarReducer.model(board: board(blocked: 1, running: 3),
                                     cards: [], todayCost: 73.4, now: Date())
        #expect(m.fleetLine == "1 blocked · 3 running · $73 today")
        #expect(!m.fleetLine.contains("waiting"))
        #expect(!m.fleetLine.contains("idle"))
    }

    @Test func rowsCarryWhatSessionActionsNeed() {
        let b = board(blocked: 1, ages: [.blocked: [55]])
        let m = MenuBarReducer.model(board: b, cards: [], todayCost: 0, now: Date())
        let row = try! #require(m.blocked.first)
        #expect(row.id == "s0")
        #expect(row.cwd == "/tmp/s0")
        #expect(row.age == 55)
        #expect(row.tierLabel == "Opus")   // ModelTier.label for claude-opus-4-8
        #expect(row.classifierDiagnostic == "low: state supplied without classifier evidence")
    }
}

@Suite("Menu-bar jeopardy + judgment strip")
struct MenuBarJudgmentTests {

    private func card(_ key: String, daysOut: Double, shipped: Bool = false,
                      now: Date = Date()) -> DeadlineCard {
        let rec = DeadlineRecord(projectKey: key,
                                 deadline: now.addingTimeInterval(daysOut * 86400),
                                 kind: .hackathon,
                                 source: DeadlineSource(file: "m", line: 1, raw: key, confirmed: true),
                                 shipped: shipped)
        return DeadlineCard(record: rec, activity: nil, now: now)
    }

    private var emptyBoard: AttentionBoard { AttentionBoard(items: [], counts: [:]) }

    @Test func jeopardyNilWhenAllCardsShipped() {
        let now = Date()
        let m = MenuBarReducer.model(board: emptyBoard,
                                     cards: [card("a", daysOut: 3, shipped: true, now: now)],
                                     todayCost: 0, now: now)
        #expect(m.jeopardy == nil)
    }

    @Test func jeopardyPopulatedFromWorstNonShippedCard() {
        let now = Date()
        let m = MenuBarReducer.model(board: emptyBoard,
                                     cards: [card("shipped-one", daysOut: 1, shipped: true, now: now),
                                             card("alpha-hackathon", daysOut: 6, now: now)],
                                     todayCost: 0, now: now)
        let j = try! #require(m.jeopardy)
        #expect(j.projectKey == "alpha-hackathon")
        #expect(j.countdown == "5d" || j.countdown == "6d")   // fmtCountdown truncates
        #expect(!j.stateLabel.isEmpty)
    }

    @Test func hogLineQuietWithoutAlertAndFormattedWithOne() {
        let now = Date()
        let calm = MenuBarReducer.model(board: emptyBoard, cards: [], todayCost: 5, now: now)
        #expect(calm.hogLine == nil)
        #expect(calm.title == nil)   // no blocked, no hog → glyph only

        let hog = OrchestratorHogAlert(day: "2026-07-07", sessionID: "abcdef1234",
                                       project: "webapp", shortID: "abcdef12",
                                       sessionCost: 34, dayTotal: 40)
        let hot = MenuBarReducer.model(board: emptyBoard, cards: [], todayCost: 40,
                                       hog: hog, now: now)
        let line = try! #require(hot.hogLine)
        #expect(line.contains("webapp"))
        #expect(line.contains("85%"))
        #expect(line.contains("delegate"))
        // Hog live + nothing blocked → today's whole-$ beside the glyph.
        #expect(hot.title == "$40")
    }

    @Test func blockedCountBeatsHogDollarsInTheTitle() {
        let s = SessionSummary(id: "x", project: "p", cwd: "/tmp/p", model: "claude-opus-4-8",
                               lastActivity: Date(), messageCount: 1,
                               usage: SessionUsage(inputTokens: 1), contextWeight: 1,
                               filePath: "/tmp/p/s.jsonl")
        let board = AttentionBoard(items: [AttentionItem(session: s, state: .blocked, age: 10)],
                                   counts: [.blocked: 1])
        let hog = OrchestratorHogAlert(day: "2026-07-07", sessionID: "x", project: "p",
                                       shortID: "x", sessionCost: 30, dayTotal: 35)
        #expect(MenuBarReducer.titleText(board: board, hogFiring: hog != nil, todayCost: 35) == "1")
    }

    @Test func quotaLinePicksTheHottestWindowStrictlyOverThreshold() {
        let now = Date()
        let snap = QuotaSnapshot(
            fiveHour: QuotaWindow(title: "Session (5h)", usedPercent: 91,
                                  resetsAt: now.addingTimeInterval(2 * 3600)),
            weekly: QuotaWindow(title: "Weekly (all models)", usedPercent: 84, resetsAt: nil),
            scoped: [], fetchedAt: now)
        let line = try! #require(MenuBarReducer.hotQuotaLine(snap, now: now))
        #expect(line == "Session (5h) 91% used · resets 2h")
    }

    @Test func quotaExactlyAtThresholdStaysQuiet() {
        // House rule: strictly greater-than — exactly 80% is at the bar, not over it.
        let now = Date()
        let snap = QuotaSnapshot(
            fiveHour: QuotaWindow(title: "Session (5h)", usedPercent: 80, resetsAt: nil),
            weekly: nil, scoped: [], fetchedAt: now)
        #expect(MenuBarReducer.hotQuotaLine(snap, now: now) == nil)
        #expect(MenuBarReducer.hotQuotaLine(nil, now: now) == nil)
    }

    @Test func quotaFractionAboveThresholdAlertsAndRoundsForDisplay() {
        let now = Date()
        let window = QuotaWindow(title: "Session (5h)", usedPercent: 80.9, resetsAt: nil)
        let snap = QuotaSnapshot(fiveHour: window, weekly: nil, scoped: [], fetchedAt: now)
        #expect(window.roundedUsedPercent == 81)
        #expect(MenuBarReducer.hotQuotaLine(snap, now: now) == "Session (5h) 81% used")
    }
}

@Suite("Menu-bar presence preference store")
struct MenuBarPreferencesTests {

    @Test func defaultsToEnabledWhenFileAbsent() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mb-\(UUID().uuidString)/menubar.json")
        let store = MenuBarPreferencesStore(url: url)
        #expect(store.load().enabled == true)   // presence is the product — default ON
    }

    @Test func roundTripsTheToggle() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mb-\(UUID().uuidString)/menubar.json")
        let store = MenuBarPreferencesStore(url: url)
        #expect(store.save(MenuBarPreferences(enabled: false)))
        #expect(store.load().enabled == false)
        #expect(store.save(MenuBarPreferences(enabled: true)))
        #expect(store.load().enabled == true)
        try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
    }
}

// Bounds-safe subscript for the fixture builder.
private extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
