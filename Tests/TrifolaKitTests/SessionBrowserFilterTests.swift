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
}
