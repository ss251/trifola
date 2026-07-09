import Foundation

// MARK: - Lightweight refresh-path timing
// The runtime-cost instrument: wall-clock ms around each store refresh + the
// heaviest view-body aggregates, so "the app feels janky" can be convicted by
// numbers instead of vibes. Two consumers:
//  • the GUI: `MC_PERF=1` makes `Perf.span` print `[perf] label 12.3ms` to
//    stderr live while the app runs (zero cost when the flag is off beyond a
//    couple of clock reads),
//  • `--selfcheck`: the PERF block calls `Perf.time` directly and prints a
//    table on every run, so before/after regressions are visible in CI-ish runs.

public enum Perf {
    /// Live GUI printing is opt-in: `MC_PERF=1 swift run …`.
    public static let enabled = ProcessInfo.processInfo.environment["MC_PERF"] == "1"

    /// Run `body`, returning its value and the elapsed wall-clock milliseconds.
    @discardableResult
    public static func time<T>(_ body: () throws -> T) rethrows -> (value: T, ms: Double) {
        let t0 = DispatchTime.now().uptimeNanoseconds
        let value = try body()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
        return (value, ms)
    }

    /// Run `body`; when `MC_PERF=1`, print `[perf] label 12.3ms` to stderr.
    /// The label should name the actor context ("main:" prefixes work done ON
    /// the main actor — the spans that can stall the UI).
    @discardableResult
    public static func span<T>(_ label: String, _ body: () throws -> T) rethrows -> T {
        guard enabled else { return try body() }
        let (value, ms) = try time(body)
        FileHandle.standardError.write(Data("[perf] \(label) \(String(format: "%.1f", ms))ms\n".utf8))
        return value
    }

    /// Async variant — measures the full await span (wall time, not main-actor
    /// busy time; use the sync `span` for anything that blocks the main actor).
    /// Inherits the caller's isolation so a main-actor closure passes cleanly.
    @discardableResult
    public static func span<T>(_ label: String, isolation: isolated (any Actor)? = #isolation,
                               _ body: () async throws -> T) async rethrows -> T {
        guard enabled else { return try await body() }
        let t0 = DispatchTime.now().uptimeNanoseconds
        let value = try await body()
        let ms = Double(DispatchTime.now().uptimeNanoseconds - t0) / 1_000_000
        FileHandle.standardError.write(Data("[perf] \(label) \(String(format: "%.1f", ms))ms\n".utf8))
        return value
    }
}
