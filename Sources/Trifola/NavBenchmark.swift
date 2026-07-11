import Foundation
import AppKit
import SwiftUI
import TrifolaKit

/// Reproducible large-corpus projection benchmark for the navigation hot path.
/// It retains the legacy repeated-body comparisons while emitting full
/// distributions for the current one-projection shapes. This remains a
/// microbenchmark; `NavigationMetrics` owns the real click/draw instrumentation.
enum NavBenchmark {
    @MainActor private static var liveServices: AppServices?
    @MainActor private static var liveWindow: NSWindow?

    struct Configuration {
        static let defaultCount = 6_600
        static let defaultRuns = 7

        let count: Int
        let runs: Int
        let jsonOutputPath: String?

        init(arguments: [String]) throws {
            count = try Self.integerValue(
                after: "--benchmark-nav-count",
                in: arguments,
                default: Self.defaultCount,
                allowed: 1...100_000
            )
            runs = try Self.integerValue(
                after: "--benchmark-nav-runs",
                in: arguments,
                default: Self.defaultRuns,
                allowed: 1...1_000
            )
            jsonOutputPath = try Self.stringValue(
                after: "--benchmark-nav-json",
                in: arguments
            )
        }

        private static func integerValue(
            after flag: String,
            in arguments: [String],
            default defaultValue: Int,
            allowed: ClosedRange<Int>
        ) throws -> Int {
            guard let index = arguments.firstIndex(of: flag) else { return defaultValue }
            let valueIndex = arguments.index(after: index)
            guard valueIndex < arguments.endIndex,
                  !arguments[valueIndex].hasPrefix("--"),
                  let value = Int(arguments[valueIndex]),
                  allowed.contains(value) else {
                throw ConfigurationError.invalidInteger(
                    flag: flag,
                    allowed: allowed
                )
            }
            return value
        }

        private static func stringValue(
            after flag: String,
            in arguments: [String]
        ) throws -> String? {
            guard let index = arguments.firstIndex(of: flag) else { return nil }
            let valueIndex = arguments.index(after: index)
            guard valueIndex < arguments.endIndex,
                  !arguments[valueIndex].hasPrefix("--"),
                  !arguments[valueIndex].isEmpty else {
                throw ConfigurationError.missingValue(flag: flag)
            }
            return arguments[valueIndex]
        }
    }

    enum ConfigurationError: Error, CustomStringConvertible {
        case invalidInteger(flag: String, allowed: ClosedRange<Int>)
        case missingValue(flag: String)

        var description: String {
            switch self {
            case .invalidInteger(let flag, let allowed):
                return "\(flag) requires an integer in \(allowed.lowerBound)...\(allowed.upperBound)"
            case .missingValue(let flag):
                return "\(flag) requires a value"
            }
        }
    }

    private struct RecencyKey {
        let index: Int
        let date: Date
        let id: String
    }

    private struct Distribution: Codable {
        let medianMs: Double
        let p95Ms: Double
        let maxMs: Double
        let samplesMs: [Double]

        enum CodingKeys: String, CodingKey {
            case medianMs = "median_ms"
            case p95Ms = "p95_ms"
            case maxMs = "max_ms"
            case samplesMs = "samples_ms"
        }
    }

    private struct Comparison: Codable {
        let id: String
        let label: String
        let before: Distribution
        let after: Distribution
    }

    private struct Report: Codable {
        let schemaVersion = 1
        let corpusCount: Int
        let measuredRuns: Int
        let warmupRuns = 1
        let metrics: [Comparison]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case corpusCount = "corpus_count"
            case measuredRuns = "measured_runs"
            case warmupRuns = "warmup_runs"
            case metrics
        }
    }

    static func run(configuration: Configuration) throws {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let sessions = seededSessions(count: configuration.count, now: now)
        let records = seededDeadlines(now: now)

        let sessionsBefore = measure(runs: configuration.runs) {
            var checksum = 0
            for _ in 0..<4 { checksum += legacySessionProjection(sessions).count }
            return checksum
        }
        let sessionsAfter = measure(runs: configuration.runs) {
            optimizedSessionProjection(sessions).count
        }

        func deadlineCards() -> [DeadlineCard] {
            let activity = DeadlineActivity.summarize(sessions, now: now)
            return DeadlineBoard.build(records: records, activity: activity, now: now)
        }
        let deadlinesBefore = measure(runs: configuration.runs) {
            var checksum = 0
            for _ in 0..<5 { checksum += deadlineCards().count }
            return checksum
        }
        let deadlinesAfter = measure(runs: configuration.runs) {
            deadlineCards().count
        }

        func fleetBoard() -> FleetBoard {
            FleetBoard.build(
                sessions: sessions,
                signals: [:],
                now: now,
                arrival: ArrivalLedger()
            ).board
        }
        let fleetBefore = measure(runs: configuration.runs) {
            var checksum = 0
            for _ in 0..<5 { checksum += fleetBoard().tokenCount }
            return checksum
        }
        let fleetAfter = measure(runs: configuration.runs) {
            fleetBoard().tokenCount
        }

        let report = Report(
            corpusCount: configuration.count,
            measuredRuns: configuration.runs,
            metrics: [
                Comparison(
                    id: "sessions",
                    label: "Sessions repeated projection",
                    before: sessionsBefore,
                    after: sessionsAfter
                ),
                Comparison(
                    id: "deadlines",
                    label: "Deadlines repeated projection",
                    before: deadlinesBefore,
                    after: deadlinesAfter
                ),
                Comparison(
                    id: "fleet",
                    label: "Fleet repeated projection",
                    before: fleetBefore,
                    after: fleetAfter
                ),
            ]
        )

        printText(report)
        if let path = configuration.jsonOutputPath {
            try writeJSON(report, to: path)
        }
    }

    private static func printText(_ report: Report) {
        print("=== NAV BENCHMARK — \(report.corpusCount) seeded sessions, \(report.measuredRuns) measured runs ===")
        for metric in report.metrics {
            row(
                metric.label,
                before: metric.before.medianMs,
                after: metric.after.medianMs
            )
            print(String(
                format: "  distribution: before p95 %8.2fms max %8.2fms | after p95 %8.2fms max %8.2fms",
                metric.before.p95Ms,
                metric.before.maxMs,
                metric.after.p95Ms,
                metric.after.maxMs
            ))
        }
        print("Legacy projection floor: optimized projections <= 100ms (not end-to-end navigation acceptance)")
    }

    private static func writeJSON(_ report: Report, to path: String) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(report)
        data.append(0x0A)

        if path == "-" {
            print("--- NAV BENCHMARK JSON ---")
            FileHandle.standardOutput.write(data)
            return
        }

        let url = URL(fileURLWithPath: path)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
        print("JSON: \(url.path)")
    }

    private static func row(_ label: String, before: Double, after: Double) {
        print(String(
            format: "%-32s before %8.2fms  after %8.2fms",
            (label as NSString).utf8String!,
            before,
            after
        ))
    }

    private static func measure(runs: Int, _ body: () -> Int) -> Distribution {
        _ = body()
        var times: [Double] = []
        times.reserveCapacity(runs)
        var checksum = 0
        for _ in 0..<runs {
            let measured = Perf.time { body() }
            checksum &+= measured.value
            times.append(measured.ms)
        }
        // Keep the result observable in optimized builds without polluting the
        // timing interval with I/O.
        if checksum == Int.min { print(checksum) }

        let sorted = times.sorted()
        let middle = sorted.count / 2
        let median = sorted.count.isMultiple(of: 2)
            ? (sorted[middle - 1] + sorted[middle]) / 2
            : sorted[middle]
        let p95Index = min(
            sorted.count - 1,
            max(0, Int(ceil(Double(sorted.count) * 0.95)) - 1)
        )
        return Distribution(
            medianMs: median,
            p95Ms: sorted[p95Index],
            maxMs: sorted[sorted.count - 1],
            samplesMs: times
        )
    }

    /// Mirrors the old body shape: Top-level filter plus a whole-struct sort,
    /// called four times by count/list/truncation branches.
    private static func legacySessionProjection(
        _ sessions: [SessionSummary]
    ) -> [SessionSummary] {
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
    private static func optimizedSessionProjection(
        _ sessions: [SessionSummary]
    ) -> [SessionSummary] {
        let result = sessions.filter { !$0.isSubagent }
        let keys: [RecencyKey] = result.enumerated().map { pair in
            RecencyKey(
                index: pair.offset,
                date: pair.element.lastActivity ?? .distantPast,
                id: pair.element.id
            )
        }.sorted {
            $0.date == $1.date ? $0.id < $1.id : $0.date > $1.date
        }
        return keys.map { result[$0.index] }
    }

    private static func seededSessions(
        count: Int,
        now: Date
    ) -> [SessionSummary] {
        (0..<count).map { index in
            let parent = index / 5
            let isChild = index % 5 == 4
            let id = isChild
                ? "session-\(parent)/agent-\(index)"
                : "session-\(index)"
            let path = isChild
                ? "/fixture/session-\(parent)/subagents/agent-\(index).jsonl"
                : "/fixture/session-\(index).jsonl"
            let project = "project-\(index % 120)"
            let usage = SessionUsage(
                inputTokens: 8_000 + index,
                outputTokens: 900 + index % 400,
                cacheCreateTokens: 1_200,
                cacheReadTokens: 18_000 + index % 3_000
            )
            return SessionSummary(
                id: id,
                project: project,
                cwd: "/fixture/\(project)",
                model: index % 3 == 0
                    ? "claude-opus-4-8"
                    : "claude-sonnet-4-6",
                lastActivity: now.addingTimeInterval(-Double(index % 3_600)),
                messageCount: 12 + index % 80,
                usage: usage,
                contextWeight: 40_000 + index % 240_000,
                filePath: path,
                lastUserMessage: "Seeded navigation benchmark row \(index)"
            )
        }
    }

    private static func seededDeadlines(now: Date) -> [String: DeadlineRecord] {
        Dictionary(uniqueKeysWithValues: (0..<120).map { index in
            let key = "project-\(index)"
            let record = DeadlineRecord(
                projectKey: key,
                deadline: now.addingTimeInterval(Double(index + 1) * 21_600),
                kind: index % 4 == 0 ? .audit : .gate,
                source: DeadlineSource(
                    file: "fixture.md",
                    line: index + 1,
                    raw: "seeded deadline",
                    confirmed: true
                )
            )
            return (key, record)
        })
    }

    /// A deterministic application host for the live benchmark. Launching the
    /// bare SwiftPM executable through SwiftUI's scene restoration can leave a
    /// headless process when the prior benchmark was force-terminated (or make
    /// Instruments resolve another app with the same bundle identity). Hosting
    /// the exact production RootView and the exact AppServices graph in one
    /// explicit 1440×900 window makes the terminal harness reproducible.
    @MainActor
    static func runLiveApplication() -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.regular)

        let services = AppServices()
        let root = RootView()
            .environmentObject(services)
            .environmentObject(services.navigation)
            .environmentObject(services.navigationSnapshots)
            .environmentObject(services.workspaceAccess)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 1440, height: 900),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false)
        window.title = "Trifola"
        window.contentView = host
        window.setContentSize(NSSize(width: 1440, height: 900))
        window.center()
        window.ignoresMouseEvents = true
        window.collectionBehavior.insert(.canJoinAllSpaces)
        if ProcessInfo.processInfo.environment["TRIFOLA_PRESENT"] != nil
            || ProcessInfo.processInfo.environment["CMC_PRESENT"] != nil {
            window.level = .statusBar
        }

        liveServices = services
        liveWindow = window
        app.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        window.orderFrontRegardless()
        app.run()
        exit(0)
    }

    /// Launch-only end-to-end benchmark. Unlike the seeded projection harness,
    /// this drives `AppServices.select` (the exact sidebar action) and waits for
    /// AppKit draw probes in the production 1440×900 tree. NavigationMetrics
    /// emits the cold/warm first-frame and hydrated intervals. The cold pass is
    /// followed by seven warm samples per destination by default so terminal
    /// evidence supports median/p95/max reporting rather than a favorable draw.
    /// `--benchmark-nav-runs N` shortens diagnostic iterations; final evidence
    /// uses the default seven.
    @MainActor
    static func driveRealClickPath(using services: AppServices) async {
        // A benchmark process must never outlive its evidence window. This hard
        // watchdog is intentionally outside the main actor so an accidental UI
        // stall still returns a non-zero terminal result instead of hanging CI.
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + 130) {
            FileHandle.standardError.write(Data(
                "[nav-benchmark-live] watchdog timeout\n".utf8))
            exit(70)
        }
        let deadline = Date().addingTimeInterval(50)
        repeat {
            try? await Task.sleep(for: .milliseconds(100))
        } while (services.isRefreshCascadeRunning
                 || services.sessions.isRefreshing
                 || services.sessions.sessions.isEmpty)
            && Date() < deadline

        NavigationMetrics.resetLiveSamples()
        FileHandle.standardError.write(Data(
            "[nav-benchmark-live] begin corpus=\(services.sessions.sessions.count) window=1440x900\n".utf8))
        let warmRuns = (try? Configuration(
            arguments: Array(CommandLine.arguments.dropFirst())).runs)
            ?? Configuration.defaultRuns
        let initialSection = services.section
        let coldSections = AppSection.allCases.filter { $0 != initialSection }
        for section in coldSections {
            FileHandle.standardError.write(Data(
                "[nav-benchmark-live] drive pass=cold screen=\(section.rawValue)\n".utf8))
            services.select(section, origin: .pointer)
            // Cold acceptance is 250ms. A 750ms boundary leaves ample room
            // for a slow baseline draw while preventing journey overlap.
            try? await Task.sleep(for: .milliseconds(750))
        }
        for run in 1...warmRuns {
            for section in AppSection.allCases {
                FileHandle.standardError.write(Data(
                    "[nav-benchmark-live] drive pass=warm-\(run) screen=\(section.rawValue)\n".utf8))
                services.select(section, origin: .pointer)
                try? await Task.sleep(for: .milliseconds(750))
            }
        }
        try? await Task.sleep(for: .seconds(1))
        NavigationMetrics.printLiveSummary()
        FileHandle.standardError.write(Data("[nav-benchmark-live] complete\n".utf8))
        exit(0)
    }
}
