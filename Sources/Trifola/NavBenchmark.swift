import Foundation
import TrifolaKit

/// Reproducible large-corpus projection benchmark for the navigation hot path.
/// It compares the pre-fix repeated-body shape with the one-projection shape now
/// used by Sessions, Deadlines, and Fleet. Run the release binary with
/// `--benchmark-nav`; seven measured passes follow one warm-up.
enum NavBenchmark {
    private struct RecencyKey {
        let index: Int
        let date: Date
        let id: String
    }
    private static let count = 6_000
    private static let runs = 7

    static func run() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sessions = seededSessions(now: now)
        let records = seededDeadlines(now: now)

        let sessionsBefore = median {
            var checksum = 0
            for _ in 0..<4 { checksum += legacySessionProjection(sessions).count }
            return checksum
        }
        let sessionsAfter = median { optimizedSessionProjection(sessions).count }

        func deadlineCards() -> [DeadlineCard] {
            let activity = DeadlineActivity.summarize(sessions, now: now)
            return DeadlineBoard.build(records: records, activity: activity, now: now)
        }
        let deadlinesBefore = median {
            var checksum = 0
            for _ in 0..<5 { checksum += deadlineCards().count }
            return checksum
        }
        let deadlinesAfter = median { deadlineCards().count }

        func fleetBoard() -> FleetBoard {
            FleetBoard.build(sessions: sessions, signals: [:], now: now,
                             arrival: ArrivalLedger()).board
        }
        let fleetBefore = median {
            var checksum = 0
            for _ in 0..<5 { checksum += fleetBoard().tokenCount }
            return checksum
        }
        let fleetAfter = median { fleetBoard().tokenCount }

        print("=== NAV BENCHMARK — \(count) seeded sessions, median of \(runs) ===")
        row("Sessions repeated projection", before: sessionsBefore, after: sessionsAfter)
        row("Deadlines repeated projection", before: deadlinesBefore, after: deadlinesAfter)
        row("Fleet repeated projection", before: fleetBefore, after: fleetAfter)
        print("Acceptance floor: Sessions/Deadlines/Fleet optimized projections each <= 100ms")
    }

    private static func row(_ label: String, before: Double, after: Double) {
        print(String(format: "%-32s before %8.2fms  after %8.2fms",
                     (label as NSString).utf8String!, before, after))
    }

    private static func median(_ body: () -> Int) -> Double {
        _ = body()
        var times: [Double] = []
        var checksum = 0
        for _ in 0..<runs {
            let measured = Perf.time { body() }
            checksum &+= measured.value
            times.append(measured.ms)
        }
        // Keep the result observable in optimized builds without polluting the
        // timing interval with I/O.
        if checksum == Int.min { print(checksum) }
        return times.sorted()[times.count / 2]
    }

    /// Mirrors the old body shape: Top-level filter plus a whole-struct sort,
    /// called four times by count/list/truncation branches.
    private static func legacySessionProjection(_ sessions: [SessionSummary]) -> [SessionSummary] {
        var result = sessions.filter { !$0.isSubagent }
        result.sort {
            let a = $0.lastActivity ?? .distantPast
            let b = $1.lastActivity ?? .distantPast
            return a == b ? $0.id < $1.id : a > b
        }
        return result
    }

    /// Mirrors the fixed projection: filter once, sort light index keys, reorder
    /// the rich summaries once.
    private static func optimizedSessionProjection(_ sessions: [SessionSummary]) -> [SessionSummary] {
        let result = sessions.filter { !$0.isSubagent }
        let keys: [RecencyKey] = result.enumerated().map { pair in
            RecencyKey(index: pair.offset,
                       date: pair.element.lastActivity ?? .distantPast,
                       id: pair.element.id)
        }.sorted {
            $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date
        }
        return keys.map { result[$0.index] }
    }

    private static func seededSessions(now: Date) -> [SessionSummary] {
        (0..<count).map { index in
            let parent = index / 5
            let isChild = index % 5 == 4
            let id = isChild ? "session-\(parent)/agent-\(index)" : "session-\(index)"
            let path = isChild
                ? "/fixture/session-\(parent)/subagents/agent-\(index).jsonl"
                : "/fixture/session-\(index).jsonl"
            let project = "project-\(index % 120)"
            let usage = SessionUsage(
                inputTokens: 8_000 + index,
                outputTokens: 900 + index % 400,
                cacheCreateTokens: 1_200,
                cacheReadTokens: 18_000 + index % 3_000)
            return SessionSummary(
                id: id,
                project: project,
                cwd: "/fixture/\(project)",
                model: index % 3 == 0 ? "claude-opus-4-8" : "claude-sonnet-4-6",
                lastActivity: now.addingTimeInterval(-Double(index % 3_600)),
                messageCount: 12 + index % 80,
                usage: usage,
                contextWeight: 40_000 + index % 240_000,
                filePath: path,
                lastUserMessage: "Seeded navigation benchmark row \(index)")
        }
    }

    private static func seededDeadlines(now: Date) -> [String: DeadlineRecord] {
        Dictionary(uniqueKeysWithValues: (0..<120).map { index in
            let key = "project-\(index)"
            let record = DeadlineRecord(
                projectKey: key,
                deadline: now.addingTimeInterval(Double(index + 1) * 21_600),
                kind: index % 4 == 0 ? .audit : .gate,
                source: DeadlineSource(file: "fixture.md", line: index + 1,
                                       raw: "seeded deadline", confirmed: true))
            return (key, record)
        })
    }
}
