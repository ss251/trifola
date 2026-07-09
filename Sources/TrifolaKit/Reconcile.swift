import Foundation

// MARK: - RECONCILE vs CodexBar (W3) — a second, independent computation of the
// same per-model-day spend, read STRICTLY read-only.
//
// CodexBar persists its computed usage cache at
//   ~/Library/Caches/CodexBar/cost-usage/claude-v4.json   (~20MB)
// Shape decoded from ~/Developer/CodexBar
// Sources/CodexBarCore/Vendored/CostUsage/CostUsageScanner+Claude.swift `add()`
// (verified 2026-07-07 by the coordinator):
//   root = { version, lastScanUnixMs, scanSinceKey, scanUntilKey, days, files }
//   days["YYYY-MM-DD"]["<normalized-model-id>"] = packed [Int; 8]:
//     [0] input          [1] cacheRead
//     [2] cacheCreate    (total, INCLUDING the 1h slice)
//     [3] output         [4] costNanos  (÷ 1e9 = dollars)
//     [5] rowCount       [6] costPricedCount
//     [7] cacheCreate1h
// This file belongs to CodexBar — we NEVER write it, and the app works
// normally when it's absent (graceful `.missing` state).

/// One (day, model) row of CodexBar's computed cache — the packed [Int; 8]
/// unpacked into named fields.
public struct CodexBarModelDay: Sendable, Equatable {
    public let input: Int
    public let cacheRead: Int
    /// Total cache-creation tokens, INCLUDING the 1h slice (same convention as
    /// our `SessionUsage.cacheCreateTokens`).
    public let cacheCreate: Int
    public let output: Int
    /// CodexBar's computed cost in nano-dollars; ÷1e9 = dollars.
    public let costNanos: Int
    public let rowCount: Int
    public let costPricedCount: Int
    public let cacheCreate1h: Int

    public var dollars: Double { Double(costNanos) / 1_000_000_000 }

    public init(input: Int, cacheRead: Int, cacheCreate: Int, output: Int,
                costNanos: Int, rowCount: Int, costPricedCount: Int, cacheCreate1h: Int) {
        self.input = input
        self.cacheRead = cacheRead
        self.cacheCreate = cacheCreate
        self.output = output
        self.costNanos = costNanos
        self.rowCount = rowCount
        self.costPricedCount = costPricedCount
        self.cacheCreate1h = cacheCreate1h
    }

    /// From the packed on-disk array; nil unless all 8 slots are present.
    public init?(packed: [Int]) {
        guard packed.count >= 8 else { return nil }
        self.init(input: packed[0], cacheRead: packed[1], cacheCreate: packed[2],
                  output: packed[3], costNanos: packed[4], rowCount: packed[5],
                  costPricedCount: packed[6], cacheCreate1h: packed[7])
    }
}

/// CodexBar's parsed cost-usage cache (the `files` map is deliberately skipped —
/// only the per-day per-model rollup matters for reconcile).
public struct CodexBarCache: Sendable {
    public let version: Int
    /// When CodexBar last scanned — the honest "it lags live sessions" input.
    public let lastScan: Date?
    public let scanSinceKey: String?
    public let scanUntilKey: String?
    /// Day key → normalized model id → unpacked row.
    public let days: [String: [String: CodexBarModelDay]]

    public init(version: Int, lastScan: Date?, scanSinceKey: String?,
                scanUntilKey: String?, days: [String: [String: CodexBarModelDay]]) {
        self.version = version
        self.lastScan = lastScan
        self.scanSinceKey = scanSinceKey
        self.scanUntilKey = scanUntilKey
        self.days = days
    }

    /// CodexBar's total dollars for a day (Σ its per-model costNanos).
    public func dayTotal(_ day: String) -> Double {
        (days[day] ?? [:]).values.reduce(0) { $0 + $1.dollars }
    }
}

/// The three honest states of the read-only cache read.
public enum CodexBarCacheState: Sendable {
    case loaded(CodexBarCache)
    /// No cache file — CodexBar not installed / never scanned. The app works
    /// normally; the panel says so calmly.
    case missing
    case unreadable(String)
}

/// One day's reconciliation: our per-model-day dollars vs CodexBar's.
public struct ReconcileDay: Identifiable, Sendable, Equatable {
    public var id: String { day }
    public let day: String
    public let ours: Double
    public let theirs: Double
    /// Per-model drill-in (normalized model id → dollars).
    public let ourModels: [String: Double]
    public let theirModels: [String: Double]

    public init(day: String, ours: Double, theirs: Double,
                ourModels: [String: Double], theirModels: [String: Double]) {
        self.day = day
        self.ours = ours
        self.theirs = theirs
        self.ourModels = ourModels
        self.theirModels = theirModels
    }

    public var delta: Double { ours - theirs }

    /// The green rule: |Δ| ≤ max($0.01, 0.5% of the larger figure).
    public var matches: Bool { CodexBarReconcile.withinTolerance(ours: ours, theirs: theirs) }

    /// A CALM likely cause for a visible Δ — never panic language, always the
    /// most probable mechanical explanation first:
    ///  1. CodexBar simply has no rows for the day (outside its scan window).
    ///  2. CodexBar last scanned before this day closed → it lags live
    ///     sessions and the day is still accruing on its side.
    ///  3. Otherwise, name the model with the largest per-model gap (a rate or
    ///     dedup difference to look at).
    public func likelyCause(lastScan: Date?, now: Date = Date()) -> String? {
        guard !matches else { return nil }
        if theirs == 0 && ours > 0 {
            return "CodexBar has no rows for \(day) — outside its scan window, or not scanned yet"
        }
        if let lastScan, CostProvenance.dayKey(for: lastScan) <= day {
            let age = fmtAgeShort(max(0, now.timeIntervalSince(lastScan)))
            return "CodexBar last scanned \(age) ago — it lags live sessions; this day is still accruing on its side"
        }
        let models = Set(ourModels.keys).union(theirModels.keys)
        if let worst = models.max(by: {
            abs((ourModels[$0] ?? 0) - (theirModels[$0] ?? 0))
                < abs((ourModels[$1] ?? 0) - (theirModels[$1] ?? 0))
        }) {
            let o = ourModels[worst] ?? 0, t = theirModels[worst] ?? 0
            let name = worst.isEmpty ? "(unknown model)" : worst
            return "largest gap on \(name): ours \(String(format: "$%.2f", o)) vs CodexBar \(String(format: "$%.2f", t)) — likely a rate or dedup difference on that model"
        }
        return nil
    }
}

public enum CodexBarReconcile {

    /// Where CodexBar keeps its computed cache. READ-ONLY — never written.
    public static var defaultCacheURL: URL {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CodexBar/cost-usage/claude-v4.json")
    }

    /// Read + parse the cache, honestly: absent → `.missing` (the app works
    /// normally), malformed → `.unreadable` with the reason, never a throw.
    public static func load(url: URL = defaultCacheURL) -> CodexBarCacheState {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        guard let data = try? Data(contentsOf: url) else {
            return .unreadable("file exists but could not be read")
        }
        guard let cache = parse(data) else {
            return .unreadable("unexpected JSON shape (not the claude-v4 packed format)")
        }
        return .loaded(cache)
    }

    /// Pure parser over the exact packed shape — fixture-testable.
    public static func parse(_ data: Data) -> CodexBarCache? {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rawDays = root["days"] as? [String: Any] else { return nil }
        var days: [String: [String: CodexBarModelDay]] = [:]
        for (day, value) in rawDays {
            guard let models = value as? [String: Any] else { continue }
            var m: [String: CodexBarModelDay] = [:]
            for (model, packedAny) in models {
                guard let packed = packedAny as? [Any] else { continue }
                let ints = packed.map { ($0 as? NSNumber)?.intValue ?? 0 }
                if let row = CodexBarModelDay(packed: ints) { m[model] = row }
            }
            if !m.isEmpty { days[day] = m }
        }
        let ms = (root["lastScanUnixMs"] as? NSNumber)?.doubleValue
        return CodexBarCache(
            version: (root["version"] as? NSNumber)?.intValue ?? 0,
            lastScan: ms.map { Date(timeIntervalSince1970: $0 / 1000) },
            scanSinceKey: root["scanSinceKey"] as? String,
            scanUntilKey: root["scanUntilKey"] as? String,
            days: days)
    }

    // MARK: our side of the ledger

    /// OUR per-model dollars for one LOCAL day — the exact `--spend-by-model`
    /// aggregation: Σ every session's (model, day) slice, priced at the
    /// catalog's date-aware rate. The same code path as every headline dollar.
    public static func ourModelDollars(sessions: [SessionSummary], day: String,
                                       catalog: PricingCatalog = .current) -> [String: Double] {
        var byModel: [String: SessionUsage] = [:]
        for s in sessions {
            for (model, u) in s.usageByModelDay[day] ?? [:] {
                byModel[model] = (byModel[model] ?? SessionUsage()) + u
            }
        }
        var out: [String: Double] = [:]
        for (model, u) in byModel where u.total > 0 {
            out[model] = u.cost(rate: catalog.resolvedRate(model: model, onDay: day))
        }
        return out
    }

    /// Reconcile a list of day keys: ours vs CodexBar's, with per-model
    /// drill-in maps for the mismatch view.
    public static func compare(sessions: [SessionSummary], cache: CodexBarCache,
                               days: [String],
                               catalog: PricingCatalog = .current) -> [ReconcileDay] {
        days.map { day in
            let ours = ourModelDollars(sessions: sessions, day: day, catalog: catalog)
            let theirs = (cache.days[day] ?? [:]).mapValues(\.dollars)
            return ReconcileDay(day: day,
                                ours: ours.values.reduce(0, +),
                                theirs: theirs.values.reduce(0, +),
                                ourModels: ours, theirModels: theirs)
        }
    }

    /// The last `n` CLOSED local days (yesterday backwards — today is still
    /// accruing on both sides and belongs to the panel, not the selfcheck).
    public static func lastClosedDays(_ n: Int, now: Date = Date(),
                                      calendar: Calendar = .current) -> [String] {
        (1...max(1, n)).compactMap { i in
            calendar.date(byAdding: .day, value: -i, to: now)
                .map { CostProvenance.dayKey(for: $0, calendar: calendar) }
        }
    }

    /// The green rule, both arms: an absolute cent floor for tiny days and a
    /// 0.5% band for big ones — |Δ| ≤ max($0.01, 0.5% of the larger figure).
    public static func withinTolerance(ours: Double, theirs: Double) -> Bool {
        abs(ours - theirs) <= max(0.01, 0.005 * max(abs(ours), abs(theirs)))
    }
}
