import Foundation
import Testing
@testable import TrifolaKit

@Suite("Sessions browser structural filters")
struct SessionBrowserFilterTests {
    private func session(_ id: String, subagentOf parent: String? = nil) -> SessionSummary {
        let path = parent.map { "/fixture/\($0)/subagents/agent-\(id).jsonl" }
            ?? "/fixture/\(id).jsonl"
        return SessionSummary(
            id: parent.map { "\($0)/\(id)" } ?? id,
            project: "project",
            cwd: "/fixture/project",
            model: "claude-sonnet-4-5",
            lastActivity: Date(timeIntervalSince1970: 1_700_000_000),
            messageCount: 1,
            usage: SessionUsage(),
            contextWeight: 0,
            filePath: path
        )
    }

    @Test("defaults hide children and leave live-terminal filtering off")
    func defaults() throws {
        let filter = SessionBrowserFilter()
        #expect(filter.topLevelOnly)
        #expect(!filter.liveInTerminalOnly)

        let main = session("main")
        let child = session("child", subagentOf: "main")
        #expect(filter.apply(to: [main, child], liveTerminalSessionIDs: []).map(\.id)
            == ["main"])

        let persisted = try JSONDecoder().decode(
            SessionBrowserFilter.self,
            from: JSONEncoder().encode(filter))
        #expect(persisted == filter)
    }

    @Test("top-level and live filters compose without inflating the count")
    func composition() {
        let main = session("main")
        let other = session("other")
        let child = session("child", subagentOf: "main")
        let live = Set([main.id, child.id])

        #expect(SessionBrowserFilter(topLevelOnly: false, liveInTerminalOnly: true)
            .apply(to: [main, other, child], liveTerminalSessionIDs: live).map(\.id)
            == [main.id, child.id])
        #expect(SessionBrowserFilter(topLevelOnly: true, liveInTerminalOnly: true)
            .apply(to: [main, other, child], liveTerminalSessionIDs: live).map(\.id)
            == [main.id])
    }

    @Test("7k title/path projection stays hitch-free")
    func titlePathPerformance() {
        let sessions = (0..<7_000).map { index in
            SessionSummary(
                id: "session-\(index)",
                project: index == 6_999 ? "needle-project" : "project-\(index)",
                cwd: "/fixture/project-\(index)",
                model: "claude-sonnet-4-5",
                lastActivity: Date(timeIntervalSince1970: 1_700_000_000),
                messageCount: 1,
                usage: SessionUsage(),
                contextWeight: 0,
                filePath: "/fixture/session-\(index).jsonl",
                name: "Synthetic session \(index)")
        }

        _ = SessionBrowserSearch.titlePathMatches(sessions, query: "needle")
        var durations: [Double] = []
        durations.reserveCapacity(50)
        for _ in 0..<50 {
            let start = Date()
            let matches = SessionBrowserSearch.titlePathMatches(
                sessions, query: "needle")
            durations.append(Date().timeIntervalSince(start))
            #expect(matches.map(\.id) == ["session-6999"])
        }
        durations.sort()
        let median = durations[durations.count / 2]
        let p95 = durations[Int(Double(durations.count - 1) * 0.95)]
        print(String(format:
            "SEARCH_TYPING_PERF sessions=7000 title_filter_p50=%.3fms title_filter_p95=%.3fms",
            median * 1_000, p95 * 1_000))

        #if DEBUG
        #expect(median < 0.075)
        #else
        #expect(median < 0.05)
        #endif
    }
}
