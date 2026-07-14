import Foundation
import Darwin
import TrifolaKit

enum SearchBenchmark {
    struct Configuration {
        let root: URL
        let count: Int
        let fixtureBytes: UInt64
        let churnSeconds: Int
        let appendInterval: Int
        let jsonOutput: URL?

        init(arguments: [String]) throws {
            root = URL(fileURLWithPath: try Self.string(
                "--benchmark-search-root", arguments,
                default: "/tmp/trifola-search-benchmark"), isDirectory: true)
            count = try Self.integer(
                "--benchmark-search-count", arguments, default: 7_000,
                range: 1...100_000)
            fixtureBytes = UInt64(try Self.integer(
                "--benchmark-search-bytes", arguments,
                default: 3_221_225_472, range: 1...Int.max))
            churnSeconds = try Self.integer(
                "--benchmark-search-churn-seconds", arguments, default: 60,
                range: 1...3_600)
            appendInterval = try Self.integer(
                "--benchmark-search-append-interval", arguments, default: 2,
                range: 1...60)
            if arguments.contains("--benchmark-search-json") {
                jsonOutput = URL(fileURLWithPath: try Self.string(
                    "--benchmark-search-json", arguments, default: ""))
            } else {
                jsonOutput = nil
            }
        }

        private static func integer(_ flag: String, _ arguments: [String],
                                    default value: Int,
                                    range: ClosedRange<Int>) throws -> Int {
            guard let index = arguments.firstIndex(of: flag) else { return value }
            let next = arguments.index(after: index)
            guard next < arguments.endIndex, let parsed = Int(arguments[next]),
                  range.contains(parsed) else { throw BenchmarkError.invalid(flag) }
            return parsed
        }

        private static func string(_ flag: String, _ arguments: [String],
                                   default value: String) throws -> String {
            guard let index = arguments.firstIndex(of: flag) else { return value }
            let next = arguments.index(after: index)
            guard next < arguments.endIndex, !arguments[next].hasPrefix("--"),
                  !arguments[next].isEmpty else { throw BenchmarkError.invalid(flag) }
            return arguments[next]
        }
    }

    private enum BenchmarkError: Error, CustomStringConvertible {
        case invalid(String)
        case update(String)
        case contract(String)

        var description: String {
            switch self {
            case .invalid(let flag): return "invalid value for \(flag)"
            case .update(let reason): return "index update failed: \(reason)"
            case .contract(let reason): return "contract failed: \(reason)"
            }
        }
    }

    private struct Report: Codable {
        let fixtureFiles: Int
        let fixtureBytes: UInt64
        let firstPartialMs: Double
        let firstRunSeconds: Double
        let churnCPUPercent: Double
        let maximumUpdateWriteBytes: UInt64
        let querySamples: Int
        let queryP95Ms: Double
        let partialQueryResults: Int
        let progressLabel: String
        let updateWriteBytes: [UInt64]

        enum CodingKeys: String, CodingKey {
            case fixtureFiles = "fixture_files"
            case fixtureBytes = "fixture_bytes"
            case firstPartialMs = "first_partial_ms"
            case firstRunSeconds = "first_run_seconds"
            case churnCPUPercent = "churn_cpu_percent"
            case maximumUpdateWriteBytes = "maximum_update_write_bytes"
            case querySamples = "query_samples"
            case queryP95Ms = "query_p95_ms"
            case partialQueryResults = "partial_query_results"
            case progressLabel = "progress_label"
            case updateWriteBytes = "update_write_bytes"
        }
    }

    private final class ProgressCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var value: (milliseconds: Double, results: Int, label: String)?

        func record(milliseconds: Double, results: Int, label: String) {
            lock.lock()
            defer { lock.unlock() }
            if value == nil { value = (milliseconds, results, label) }
        }

        func snapshot() -> (milliseconds: Double, results: Int, label: String)? {
            lock.lock()
            defer { lock.unlock() }
            return value
        }
    }

    private final class QueryCapture: @unchecked Sendable {
        private let lock = NSLock()
        private var durations: [Double] = []
        private var stopped = false

        func append(_ value: Double) {
            lock.lock(); durations.append(value); lock.unlock()
        }

        func stop() { lock.lock(); stopped = true; lock.unlock() }
        func shouldStop() -> Bool { lock.lock(); defer { lock.unlock() }; return stopped }
        func values() -> [Double] { lock.lock(); defer { lock.unlock() }; return durations }
    }

    static func run(configuration: Configuration) throws {
        let manager = FileManager.default
        try? manager.removeItem(at: configuration.root)
        let fixture = configuration.root.appendingPathComponent(
            "fixture", isDirectory: true)
        try manager.createDirectory(at: fixture, withIntermediateDirectories: true)
        let sessions = try makeFixture(configuration: configuration, at: fixture)
        let actualBytes = directoryBytes(sessions)
        let databaseURL = configuration.root.appendingPathComponent("search-index.sqlite3")
        let index = try SearchIndex(storageURL: databaseURL)

        let buildStart = DispatchTime.now().uptimeNanoseconds
        let partial = ProgressCapture()
        let firstUpdate = SearchIndex.update(
            index, sessions: sessions, batchSize: 200) { progress in
                guard progress.indexed > 0, progress.indexed < progress.total else { return }
                let results = index.query(
                    SearchQuery("clean"), scope: .conversationText, limit: 20).count
                let elapsed = milliseconds(since: buildStart)
                partial.record(
                    milliseconds: elapsed, results: results,
                    label: "Partial — indexing \(progress.indexed) of \(progress.total)…")
            }
        guard firstUpdate.succeeded else {
            throw BenchmarkError.update(firstUpdate.failureReason ?? "unknown")
        }
        let firstRunSeconds = Double(
            DispatchTime.now().uptimeNanoseconds - buildStart) / 1_000_000_000
        guard let partialResult = partial.snapshot(), partialResult.results > 0 else {
            throw BenchmarkError.contract("no queryable nonterminal batch")
        }

        firstUpdate.index.truncateWAL()
        let readerLease = firstUpdate.index.keepReaderOpen()
        defer { withExtendedLifetime(readerLease) {} }
        let queryCapture = QueryCapture()
        let queryDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            while !queryCapture.shouldStop() {
                let start = DispatchTime.now().uptimeNanoseconds
                _ = firstUpdate.index.query(
                    SearchQuery("clean"), scope: .conversationText, limit: 20)
                queryCapture.append(milliseconds(since: start))
                Thread.sleep(forTimeInterval: 1)
            }
            queryDone.signal()
        }

        let cpuBefore = cpuSeconds()
        let churnStart = Date()
        var writes: [UInt64] = []
        var liveSessions = sessions
        let updateCount = max(
            1, configuration.churnSeconds / configuration.appendInterval)
        for iteration in 0..<updateCount {
            let deadline = churnStart.addingTimeInterval(
                Double(iteration * configuration.appendInterval))
            if Date() < deadline { Thread.sleep(until: deadline) }
            let target = URL(fileURLWithPath: liveSessions[0].filePath)
            let handle = try FileHandle(forWritingTo: target)
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(
                "\n{\"type\":\"user\",\"message\":{\"content\":\"clean churn append \(iteration)\"}}".utf8))
            try handle.close()
            liveSessions[0] = summary(index: 0, file: target)

            let before = storageBytes(firstUpdate.index)
            let update = SearchIndex.update(
                firstUpdate.index, sessions: liveSessions,
                automaticCheckpointPages: 0)
            guard update.succeeded else {
                throw BenchmarkError.update(update.failureReason ?? "unknown")
            }
            guard update.appendedDocuments == 1,
                  update.reusedDocuments == liveSessions.count - 1,
                  update.rebuiltDocuments == 0 else {
                throw BenchmarkError.contract(
                    "append classification appended=\(update.appendedDocuments) reused=\(update.reusedDocuments) rebuilt=\(update.rebuiltDocuments)")
            }
            let after = storageBytes(firstUpdate.index)
            writes.append(after >= before ? after - before : 0)
        }
        let churnDeadline = churnStart.addingTimeInterval(
            Double(configuration.churnSeconds))
        if Date() < churnDeadline { Thread.sleep(until: churnDeadline) }
        let churnWall = Date().timeIntervalSince(churnStart)
        let cpuPercent = 100 * max(0, cpuSeconds() - cpuBefore) / churnWall
        queryCapture.stop()
        _ = queryDone.wait(timeout: .now() + 5)
        let durations = queryCapture.values().sorted()
        let p95Index = min(durations.count - 1,
                           max(0, Int(ceil(Double(durations.count) * 0.95)) - 1))
        let p95 = durations.isEmpty ? .infinity : durations[p95Index]
        let maximumWrite = writes.max() ?? 0

        let report = Report(
            fixtureFiles: sessions.count, fixtureBytes: actualBytes,
            firstPartialMs: partialResult.milliseconds,
            firstRunSeconds: firstRunSeconds, churnCPUPercent: cpuPercent,
            maximumUpdateWriteBytes: maximumWrite,
            querySamples: durations.count, queryP95Ms: p95,
            partialQueryResults: partialResult.results,
            progressLabel: partialResult.label, updateWriteBytes: writes)
        printReport(report)
        if let output = configuration.jsonOutput { try write(report, to: output) }

        guard cpuPercent < 10 else {
            throw BenchmarkError.contract("churn CPU \(cpuPercent)% is not below 10%")
        }
        guard maximumWrite < 1_048_576 else {
            throw BenchmarkError.contract("update wrote \(maximumWrite) bytes")
        }
        guard p95 < 100 else {
            throw BenchmarkError.contract("query p95 \(p95)ms is not below 100ms")
        }
    }

    private static func makeFixture(configuration: Configuration,
                                    at root: URL) throws -> [SessionSummary] {
        var sessions: [SessionSummary] = []
        sessions.reserveCapacity(configuration.count)
        let base = configuration.fixtureBytes / UInt64(configuration.count)
        let remainder = configuration.fixtureBytes % UInt64(configuration.count)
        for index in 0..<configuration.count {
            let target = Int(base + (UInt64(index) < remainder ? 1 : 0))
            let file = root.appendingPathComponent("session-\(index).jsonl")
            let searchable = Data(
                "{\"type\":\"user\",\"message\":{\"content\":\"clean generated search contract \(index)\"}}\n".utf8)
            let toolPrefix = Data(
                "{\"type\":\"user\",\"message\":{\"content\":[{\"type\":\"tool_result\",\"content\":\"".utf8)
            let suffix = Data("\"}]}}".utf8)
            let padding = max(0, target - searchable.count - toolPrefix.count - suffix.count)
            var data = searchable
            data.append(toolPrefix)
            data.append(Data(repeating: 0x78, count: padding))
            data.append(suffix)
            try data.write(to: file)
            sessions.append(summary(index: index, file: file))
        }
        return sessions
    }

    private static func summary(index: Int, file: URL) -> SessionSummary {
        SessionSummary(
            id: "perf-\(index)", provider: .claude, project: "search-perf",
            cwd: "/fixture/search-perf", model: nil,
            lastActivity: Date(timeIntervalSince1970: 1_800_000_000 - Double(index)),
            messageCount: 2, usage: SessionUsage(), contextWeight: 0,
            filePath: file.path, lastUserMessage: "clean generated search contract",
            name: "Synthetic \(index)")
    }

    private static func milliseconds(since start: UInt64) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start) / 1_000_000
    }

    private static func directoryBytes(_ sessions: [SessionSummary]) -> UInt64 {
        sessions.reduce(0) { total, session in
            let attributes = try? FileManager.default.attributesOfItem(
                atPath: session.filePath)
            return total + ((attributes?[.size] as? NSNumber)?.uint64Value ?? 0)
        }
    }

    private static func storageBytes(_ index: SearchIndex) -> UInt64 {
        [index.databaseURL.path, index.walURL.path].reduce(0) { total, path in
            let attributes = try? FileManager.default.attributesOfItem(atPath: path)
            return total + ((attributes?[.size] as? NSNumber)?.uint64Value ?? 0)
        }
    }

    private static func cpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        func seconds(_ value: timeval) -> Double {
            Double(value.tv_sec) + Double(value.tv_usec) / 1_000_000
        }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    private static func printReport(_ report: Report) {
        print(String(
            format: "SEARCH_PERF fixture_files=%d fixture_bytes=%llu first_partial_ms=%.2f first_run_s=%.3f churn_cpu_pct=%.3f max_update_write_bytes=%llu query_samples=%d query_p95_ms=%.3f partial_query_results=%d",
            report.fixtureFiles, report.fixtureBytes, report.firstPartialMs,
            report.firstRunSeconds, report.churnCPUPercent,
            report.maximumUpdateWriteBytes, report.querySamples,
            report.queryP95Ms, report.partialQueryResults))
        print("SEARCH_PROGRESS \(report.progressLabel)")
        print("SEARCH_WRITE_DELTAS \(report.updateWriteBytes.map(String.init).joined(separator: ","))")
    }

    private static func write(_ report: Report, to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        var data = try encoder.encode(report)
        data.append(0x0A)
        try data.write(to: url, options: .atomic)
    }
}
