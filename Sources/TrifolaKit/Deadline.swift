import Foundation

// MARK: - THE DEADLINE BOARD (docs/DEADLINE_BOARD.md) — the local, canonical core
//
// The one screen that knows a project is three days from its deadline, untouched
// for five, and $40 in — because only ~/.claude holds all three facts at once. A
// deadline is a fact the human wrote down (MEMORY.md / AGENT_STATE.md); last-touch,
// spend, session count, and live state are facts only this machine computes. The
// board is their JOIN.
//
// Everything in this file is PURE + testable — the parser (fixture text → extracted
// (project, date, sourceLine)), the jeopardy metric (idle ÷ runway), the five-state
// classifier, and the app-owned persistence — with no AppKit/SwiftUI and no network.
// The write boundary is non-negotiable: the app NEVER writes the user's files;
// confirmed/edited deadlines persist ONLY to the app's own Application Support dir.

// MARK: - Kind

public enum DeadlineKind: String, Sendable, Codable, Hashable, CaseIterable {
    case hackathon, bounty, gate, audit, other

    public var label: String {
        switch self {
        case .hackathon: return "hackathon"
        case .bounty: return "bounty"
        case .gate: return "gate"
        case .audit: return "audit"
        case .other: return "deadline"
        }
    }
}

// MARK: - Provenance (a parse is a finding, not a verdict)

/// Where a deadline came from — the third line of every card, rendered mono because
/// it exists verbatim on disk. `confirmed` flips false→true on one click; an
/// override (`.toml`) or an in-app edit lands confirmed by construction.
public struct DeadlineSource: Sendable, Codable, Hashable {
    public var file: String     // absolute path (home-relativized only for display)
    public var line: Int        // 1-based source line, 0 when synthetic (edit/override)
    public var raw: String      // the verbatim matched string ("deadline Jul 13 2026")
    public var confirmed: Bool
    /// Origin: parsed from prose, read from a user `.toml`, entered in-app, or
    /// seeded programmatically from a cited fact (W5's custom-cutoff gate — a
    /// confirmed record the app plants once; never a parse, never a user edit).
    public enum Origin: String, Sendable, Codable, Hashable { case parsed, override, manual, seeded }
    public var origin: Origin

    public init(file: String, line: Int, raw: String, confirmed: Bool, origin: Origin = .parsed) {
        self.file = file
        self.line = line
        self.raw = raw
        self.confirmed = confirmed
        self.origin = origin
    }
}

// MARK: - A parsed deadline (the extractor's output — a finding)

public struct ParsedDeadline: Sendable, Equatable, Hashable {
    /// The project this date maps to (by ~/Developer/<name> path, a project hint, or
    /// the per-file default). nil when the date could not be attributed.
    public var projectKey: String?
    public var date: Date
    public var kind: DeadlineKind
    /// The trigger word immediately before the date ("deadline", "submission",
    /// "finale", "gates", …) — used to pick the OPERATIVE deadline per project and to
    /// avoid attaching "finale Jul 30" to the submission.
    public var label: String
    public var source: DeadlineSource
    /// A human platform label if one was derivable (the markdown link text / bold).
    public var platform: String?

    public init(projectKey: String?, date: Date, kind: DeadlineKind, label: String,
                source: DeadlineSource, platform: String? = nil) {
        self.projectKey = projectKey
        self.date = date
        self.kind = kind
        self.label = label
        self.source = source
        self.platform = platform
    }
}

// MARK: - The deterministic extractor

public enum DeadlineParser {

    private static let months: [String: Int] = [
        "jan": 1, "feb": 2, "mar": 3, "apr": 4, "may": 5, "jun": 6,
        "jul": 7, "aug": 8, "sep": 9, "sept": 9, "oct": 10, "nov": 11, "dec": 12,
    ]

    // "Jul 13 2026", "Jul 13", "July 13, 2026" — group1 month, group2 day, group3? year.
    private static let monthDate = try! NSRegularExpression(
        pattern: #"\b(jan|feb|mar|apr|may|jun|jul|aug|sep|sept|oct|nov|dec)[a-z]*\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s+(\d{4}))?"#,
        options: [.caseInsensitive])
    // ISO: 2026-07-13 or 2026-07-13T23:59:00-07:00 (the zone is part of the match so
    // `raw` carries it and `isoInstant` can honor the offset).
    private static let isoDate = try! NSRegularExpression(
        pattern: #"\b(\d{4})-(\d{2})-(\d{2})(?:[T ](\d{2}):(\d{2})(?::(\d{2}))?(?:Z|[+-]\d{2}:?\d{2})?)?"#)
    // A clock time, optionally with a zone token: "23:59 UTC".
    private static let clock = try! NSRegularExpression(
        pattern: #"(\d{1,2}):(\d{2})\s*(UTC|GMT|Z|IST|ET|EST|PT|PST)?"#, options: [.caseInsensitive])
    // ~/Developer/<name>/ — the reliable project anchor in MEMORY.md's index lines.
    private static let devPath = try! NSRegularExpression(
        pattern: #"Developer/([A-Za-z0-9][A-Za-z0-9._-]*)"#)
    // A leading markdown link `[Label]` or bold `**Label**` → platform label.
    private static let leadLabel = try! NSRegularExpression(
        pattern: #"(?:\[([^\]]{2,60})\]|\*\*([^*]{2,60})\*\*)"#)

    private static let authoritativeLabels: Set<String> = ["deadline", "submission", "submit", "due", "close", "closes", "ends", "end"]

    /// Parse a document into deadline findings. Deterministic: `now`/`calendar` fix
    /// the clock (year inference + the parser's default time-of-day), and no field is
    /// invented — each finding carries its verbatim `raw` string and 1-based line.
    ///
    /// - Parameters:
    ///   - defaultProject: the owning repo for a per-project file (AGENT_STATE.md).
    ///   - projectHints: known project keys (session projects) matched on the line.
    public static func parse(text: String, file: String, defaultProject: String? = nil,
                             projectHints: [String] = [], now: Date,
                             calendar: Calendar = Self.utc) -> [ParsedDeadline] {
        var out: [ParsedDeadline] = []
        let lines = text.components(separatedBy: "\n")
        let refYear = calendar.component(.year, from: now)
        // Drop the empty-project sentinel ("—") and too-short tokens so a stray em-dash
        // or one-letter cwd basename can't claim a deadline; longest-first (most specific).
        let hintSorted = projectHints
            .filter { $0.count >= 3 && $0.contains(where: \.isLetter) }
            .sorted { $0.count > $1.count }

        for (i, line) in lines.enumerated() {
            let lineNo = i + 1
            let lower = line.lowercased()
            // TIGHT extractor: only a line that carries a DEADLINE context signal yields
            // a finding. This keeps changelog timestamps, epochs, "updated 2026-07-06"
            // and other ambient dates in prose from ever becoming deadlines — the
            // difference between a tracker that reads your notes and one that hallucinates.
            guard hasDeadlineContext(lower) else { continue }
            let ns = line as NSString
            let full = NSRange(location: 0, length: ns.length)

            // A per-project file's deadline is about THAT project — a `~/Developer/tool/`
            // mention in its changelog is a reference, not a re-attribution. Only the
            // global index (no defaultProject) maps by path/hint.
            let project = defaultProject ?? projectKey(in: line, ns: ns, hints: hintSorted)
            let platform = platformLabel(in: line, ns: ns)

            // ISO dates first (unambiguous), then the month-name shape.
            for m in isoDate.matches(in: line, range: full) {
                guard let y = intAt(m, 1, ns), let mo = intAt(m, 2, ns), let d = intAt(m, 3, ns),
                      (1...12).contains(mo), (1...31).contains(d) else { continue }
                let hh = intAt(m, 4, ns) ?? 23, mm = intAt(m, 5, ns) ?? 59, ss = intAt(m, 6, ns) ?? 0
                let raw = ns.substring(with: m.range)
                // Honor an explicit offset/Z when the string carries one (accurate
                // instant); otherwise build the day in the parser's calendar tz.
                let date = isoInstant(raw) ?? makeDate(y, mo, d, hh, mm, ss, calendar)
                guard let date else { continue }
                let label = triggerLabel(before: m.range.location, in: ns)
                out.append(ParsedDeadline(projectKey: project, date: date,
                                          kind: inferKind(lower, label: label), label: label,
                                          source: DeadlineSource(file: file, line: lineNo, raw: raw, confirmed: false),
                                          platform: platform))
            }

            for m in monthDate.matches(in: line, range: full) {
                let monRange = m.range(at: 1)
                guard monRange.location != NSNotFound else { continue }
                let monKey = ns.substring(with: monRange).lowercased()
                guard let mo = months[monKey], let d = intAt(m, 2, ns), (1...31).contains(d) else { continue }
                var year = intAt(m, 3, ns) ?? refYear
                // No explicit year → infer the NEXT occurrence (roll forward if the
                // month/day already passed this reference year).
                if intAt(m, 3, ns) == nil {
                    if let probe = makeDate(refYear, mo, d, 23, 59, 0, calendar),
                       probe.timeIntervalSince(now) < -12 * 3600 {   // >~half a day past → next year
                        year = refYear + 1
                    }
                }
                // A clock time later on the same line attaches to the date.
                let (hh, mm, tz) = clockAfter(m.range.location + m.range.length, in: ns)
                let cal = tz.map { z -> Calendar in var c = calendar; c.timeZone = z; return c } ?? calendar
                guard let date = makeDate(year, mo, d, hh ?? 23, mm ?? 59, 0, cal) else { continue }
                let raw = ns.substring(with: m.range)
                let label = triggerLabel(before: m.range.location, in: ns)
                out.append(ParsedDeadline(projectKey: project, date: date,
                                          kind: inferKind(lower, label: label), label: label,
                                          source: DeadlineSource(file: file, line: lineNo, raw: raw, confirmed: false),
                                          platform: platform))
            }
        }
        return out
    }

    /// Collapse many findings into one OPERATIVE deadline per project — the crux of
    /// §3.2's "finale Jul 30 attached to the submission" trap. Prefers an
    /// authoritative label (deadline/submission/submit/due) over "finale", drops
    /// "finale" when any non-finale sibling exists, then picks the earliest date that
    /// is still ahead of `now` (the next gate), falling back to the earliest overall.
    public static func operativeDeadlines(_ parsed: [ParsedDeadline], now: Date) -> [String: ParsedDeadline] {
        var byProject: [String: [ParsedDeadline]] = [:]
        for p in parsed { guard let key = p.projectKey else { continue }; byProject[key, default: []].append(p) }

        var out: [String: ParsedDeadline] = [:]
        for (key, group) in byProject {
            var candidates = group
            // Drop "finale" when a non-finale sibling exists.
            if candidates.contains(where: { $0.label != "finale" }) {
                candidates = candidates.filter { $0.label != "finale" }
            }
            // Prefer authoritative-label candidates if any.
            let authoritative = candidates.filter { authoritativeLabels.contains($0.label) }
            if !authoritative.isEmpty { candidates = authoritative }
            // Earliest future date, else earliest overall — deterministic tie-break by
            // (date, source line).
            let future = candidates.filter { $0.date >= now }
            let pool = future.isEmpty ? candidates : future
            if let pick = pool.min(by: { lhs, rhs in
                lhs.date != rhs.date ? lhs.date < rhs.date : lhs.source.line < rhs.source.line
            }) {
                out[key] = pick
            }
        }
        return out
    }

    // MARK: helpers

    public static let utc: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()

    /// Parse a full RFC-3339 instant (with Z / ±hh:mm offset) accurately; nil for a
    /// date-only or offset-less string, so the caller falls back to a calendar build.
    private static func isoInstant(_ raw: String) -> Date? {
        guard raw.contains("T") || raw.contains(" "), raw.contains(":") else { return nil }
        guard raw.hasSuffix("Z") || raw.range(of: #"[+-]\d{2}:?\d{2}$"#, options: .regularExpression) != nil
        else { return nil }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: raw) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return iso.date(from: raw)
    }

    private static func makeDate(_ y: Int, _ mo: Int, _ d: Int, _ hh: Int, _ mm: Int, _ ss: Int,
                                 _ calendar: Calendar) -> Date? {
        var comp = DateComponents()
        comp.year = y; comp.month = mo; comp.day = d; comp.hour = hh; comp.minute = mm; comp.second = ss
        return calendar.date(from: comp)
    }

    private static func intAt(_ m: NSTextCheckingResult, _ g: Int, _ ns: NSString) -> Int? {
        guard g < m.numberOfRanges else { return nil }
        let r = m.range(at: g)
        guard r.location != NSNotFound else { return nil }
        return Int(ns.substring(with: r))
    }

    private static func projectKey(in line: String, ns: NSString, hints: [String]) -> String? {
        let full = NSRange(location: 0, length: ns.length)
        if let m = devPath.firstMatch(in: line, range: full), m.range(at: 1).location != NSNotFound {
            return ns.substring(with: m.range(at: 1))
        }
        let lower = line.lowercased()
        for h in hints where !h.isEmpty {
            if containsToken(lower, h.lowercased()) { return h }
        }
        return nil
    }

    /// True iff `needle` occurs in `haystack` on TOKEN boundaries — a letter/digit
    /// may not touch either end of the match. Kills the substring class of false
    /// positives ("scripts" ⊄ "transcripts" — the parse that put a phantom project
    /// at the top of the jeopardy sort) while `_`/`-`/`/` still count as boundaries
    /// ("project_multihopper_bounty.md" keeps matching "multihopper").
    static func containsToken(_ haystack: String, _ needle: String) -> Bool {
        guard !needle.isEmpty else { return false }
        var search = haystack.startIndex..<haystack.endIndex
        while let r = haystack.range(of: needle, range: search) {
            let beforeOK = r.lowerBound == haystack.startIndex
                || !isWordChar(haystack[haystack.index(before: r.lowerBound)])
            let afterOK = r.upperBound == haystack.endIndex
                || !isWordChar(haystack[r.upperBound])
            if beforeOK && afterOK { return true }
            guard r.upperBound < haystack.endIndex else { break }
            search = haystack.index(after: r.lowerBound)..<haystack.endIndex
        }
        return false
    }

    private static func platformLabel(in line: String, ns: NSString) -> String? {
        let full = NSRange(location: 0, length: ns.length)
        guard let m = leadLabel.firstMatch(in: line, range: full) else { return nil }
        for g in 1...2 where g < m.numberOfRanges {
            let r = m.range(at: g)
            if r.location != NSNotFound {
                let s = ns.substring(with: r).trimmingCharacters(in: .whitespaces)
                if !s.isEmpty { return s }
            }
        }
        return nil
    }

    /// The word immediately before a date match ("deadline Jul 13" → "deadline").
    private static func triggerLabel(before loc: Int, in ns: NSString) -> String {
        guard loc > 0 else { return "" }
        let head = ns.substring(to: loc).lowercased()
        // last alphabetic token
        var token = ""
        for ch in head.reversed() {
            if ch.isLetter { token.insert(ch, at: token.startIndex) }
            else if token.isEmpty { continue }   // skip trailing spaces/punct
            else { break }
        }
        let known: Set<String> = ["deadline", "submission", "submit", "finale", "due", "gates",
                                   "gate", "close", "closes", "ends", "end", "by"]
        return known.contains(token) ? token : ""
    }

    /// The first clock time after a date on the same line, with an optional zone.
    private static func clockAfter(_ loc: Int, in ns: NSString) -> (Int?, Int?, TimeZone?) {
        guard loc <= ns.length else { return (nil, nil, nil) }
        let rest = NSRange(location: loc, length: ns.length - loc)
        guard let m = clock.firstMatch(in: ns as String, range: rest) else { return (nil, nil, nil) }
        let hh = intAt(m, 1, ns), mm = intAt(m, 2, ns)
        var tz: TimeZone? = nil
        if m.numberOfRanges > 3, m.range(at: 3).location != NSNotFound {
            let z = ns.substring(with: m.range(at: 3)).uppercased()
            if z == "UTC" || z == "GMT" || z == "Z" { tz = TimeZone(identifier: "UTC") }
        }
        return (hh, mm, tz)
    }

    // A zoned wall-clock ("23:59 UTC") — itself a deadline shape.
    private static let zonedClock = try! NSRegularExpression(
        pattern: #"\d{1,2}:\d{2}\s*(utc|gmt|z\b|est|pst)"#, options: [.caseInsensitive])

    /// True iff a line carries a deadline signal — a trigger word, a hackathon/bounty
    /// platform, or a zoned clock time. The gate that makes the extractor tight.
    static func hasDeadlineContext(_ lower: String) -> Bool {
        let words = ["deadline", "submission", "submit", "finale", "due ", "due,", "due.",
                     "cutoff", "closes", "close ", " ends", "ending", " gate", "gates",
                     "hackathon", "bounty", "devpost", "devfolio", "dorahacks", "superteam",
                     "target date", "targetdate", "submissions"]
        if words.contains(where: { lower.contains($0) }) { return true }
        return zonedClock.firstMatch(in: lower, range: NSRange(location: 0, length: (lower as NSString).length)) != nil
    }

    fileprivate static func isWordChar(_ c: Character) -> Bool { c.isLetter || c.isNumber }

    private static func inferKind(_ lower: String, label: String) -> DeadlineKind {
        if label == "gates" || label == "gate" { return .gate }
        if lower.contains("bounty") { return .bounty }
        if lower.contains("audit") || lower.contains("contest") { return .audit }
        if lower.contains("gate") { return .gate }
        if lower.contains("hackathon") || lower.contains("submission") || lower.contains("submit")
            || lower.contains("finale") || lower.contains("devpost") || lower.contains("devfolio")
            || lower.contains("dorahacks") || lower.contains("superteam") { return .hackathon }
        return .other
    }
}

// MARK: - The metric: jeopardy = idle ÷ runway

public enum DeadlineMetric {
    /// Guards a divide-by-zero as the deadline crosses `now`.
    public static let epsilon: TimeInterval = 60

    /// Time you have left. Negative once the deadline has passed.
    public static func runway(deadline: Date, now: Date) -> TimeInterval { deadline.timeIntervalSince(now) }

    /// Time spent not-working the project. A never-touched project reads as idle for
    /// at least its whole remaining runway (so a near, untouched project is stalled),
    /// which the classifier then judges against the near-window.
    public static func idle(lastActivity: Date?, now: Date, runway: TimeInterval) -> TimeInterval {
        guard let last = lastActivity else { return max(runway, 0) }
        return max(0, now.timeIntervalSince(last))
    }

    /// The fraction of your remaining runway you've idled away.
    public static func jeopardy(idle: TimeInterval, runway: TimeInterval) -> Double {
        idle / max(runway, epsilon)
    }
}

// MARK: - The five states

public enum DeadlineState: String, Sendable, Codable, CaseIterable, Hashable {
    case onTrack, atRisk, stalled, shipped, overdue

    /// Sort primary: STALLED pins to the very top (the alarm), SHIPPED sinks below the
    /// fold. Overdue is stated once between them; jeopardy breaks ties within a rank.
    public var sortRank: Int {
        switch self {
        case .stalled: return 0
        case .overdue: return 1
        case .atRisk:  return 2
        case .onTrack: return 3
        case .shipped: return 4
        }
    }

    public var label: String {
        switch self {
        case .onTrack: return "ON-TRACK"
        case .atRisk:  return "AT-RISK"
        case .stalled: return "STALLED"
        case .shipped: return "SHIPPED"
        case .overdue: return "OVERDUE"
        }
    }
}

/// Tunable-but-sensible horizons (§5). The near-window is the only place "urgent"
/// begins to mean anything; the redden window colors the countdown statically.
public struct DeadlineConfig: Sendable, Equatable {
    public var nearWindow: TimeInterval
    public var reddenWindow: TimeInterval
    public var stalledJeopardy: Double
    public var atRiskJeopardy: Double

    public init(nearWindow: TimeInterval = 7 * 86400, reddenWindow: TimeInterval = 72 * 3600,
                stalledJeopardy: Double = 0.5, atRiskJeopardy: Double = 0.2) {
        self.nearWindow = nearWindow
        self.reddenWindow = reddenWindow
        self.stalledJeopardy = stalledJeopardy
        self.atRiskJeopardy = atRiskJeopardy
    }
}

public enum DeadlineClassifier {
    /// The pure classifier — a strong heuristic over `lastActivity`, never a verdict.
    /// shipped is CONFIRMED (never inferred from prose); overdue is a fact, not a nag.
    public static func classify(runway: TimeInterval, jeopardy: Double,
                                shipped: Bool, blocked: Bool,
                                config: DeadlineConfig = .init()) -> DeadlineState {
        if shipped { return .shipped }
        if runway < 0 { return .overdue }
        let near = runway <= config.nearWindow
        if near && jeopardy >= config.stalledJeopardy { return .stalled }
        if (near && jeopardy >= config.atRiskJeopardy) || (blocked && near) { return .atRisk }
        return .onTrack
    }
}

// MARK: - Per-project activity (the JOIN's right-hand side)
// Reuses SessionSummary — last-touch, $ cost, session count, machine, live — grouped
// by project. Not a rebuild of SessionStore; a pure roll-up over its output.

public struct ProjectActivity: Sendable, Equatable, Hashable {
    public var project: String
    public var lastActivity: Date?
    public var cost: Double
    public var sessionCount: Int
    public var machineID: String
    public var isLive: Bool
    public var blocked: Bool

    public init(project: String, lastActivity: Date?, cost: Double, sessionCount: Int,
                machineID: String, isLive: Bool, blocked: Bool) {
        self.project = project
        self.lastActivity = lastActivity
        self.cost = cost
        self.sessionCount = sessionCount
        self.machineID = machineID
        self.isLive = isLive
        self.blocked = blocked
    }
}

public enum DeadlineActivity {
    /// Group sessions by project. Cost sums every session (subagents included — their
    /// spend is real); last-touch/session-count/live come from interactive sessions
    /// (a project is "live" if any main is active <15m). `blockedProjects` lets the
    /// caller fold in the Attention classifier's BLOCKED set for the state.
    public static func summarize(_ sessions: [SessionSummary], now: Date,
                                 blockedProjects: Set<String> = []) -> [String: ProjectActivity] {
        var cost: [String: Double] = [:]
        var last: [String: Date] = [:]
        var count: [String: Int] = [:]
        var live: [String: Bool] = [:]
        var machineOf: [String: (Date, String)] = [:]

        for s in sessions {
            let p = s.project
            cost[p, default: 0] += s.cost
            if !s.isSubagent {
                count[p, default: 0] += 1
                if let d = s.lastActivity {
                    if last[p] == nil || d > last[p]! { last[p] = d }
                    if machineOf[p] == nil || d > machineOf[p]!.0 { machineOf[p] = (d, s.machineID) }
                    // Liveness against the SHARED `now` (the heartbeat), not the wall
                    // clock — so the board is deterministic and matches its own tick.
                    let age = now.timeIntervalSince(d)
                    if age >= 0, age < 15 * 60 { live[p] = true }
                }
            }
        }

        var out: [String: ProjectActivity] = [:]
        for p in Set(cost.keys).union(count.keys) {
            out[p] = ProjectActivity(project: p, lastActivity: last[p], cost: cost[p] ?? 0,
                                     sessionCount: count[p] ?? 0,
                                     machineID: machineOf[p]?.1 ?? Machine.localID,
                                     isLive: live[p] ?? false,
                                     blocked: blockedProjects.contains(p))
        }
        return out
    }
}

// MARK: - The stored record (app-owned canonical model)

public struct DeadlineRecord: Sendable, Codable, Hashable {
    public var projectKey: String
    public var deadline: Date
    public var kind: DeadlineKind
    public var source: DeadlineSource
    public var shipped: Bool
    public var platform: String?
    /// Populated by the LinearExporter (§8) once this project maps to a Linear Project.
    public var linearProjectId: String?

    public init(projectKey: String, deadline: Date, kind: DeadlineKind, source: DeadlineSource,
                shipped: Bool = false, platform: String? = nil, linearProjectId: String? = nil) {
        self.projectKey = projectKey
        self.deadline = deadline
        self.kind = kind
        self.source = source
        self.shipped = shipped
        self.platform = platform
        self.linearProjectId = linearProjectId
    }

    public init(_ parsed: ParsedDeadline) {
        self.init(projectKey: parsed.projectKey ?? "—", deadline: parsed.date, kind: parsed.kind,
                  source: parsed.source, shipped: false, platform: parsed.platform)
    }
}

// MARK: - The card — the JOIN, rendered (and the exporter's payload)
// Self-contained: the derived metrics are captured at build time so both the UI and
// the LinearExporter read one honest value without recomputing against a drifting now.

public struct DeadlineCard: Identifiable, Sendable, Equatable, Hashable {
    public var projectKey: String
    public var id: String { projectKey }
    public var deadline: Date
    public var kind: DeadlineKind
    public var platform: String?
    public var source: DeadlineSource
    public var shipped: Bool
    public var linearProjectId: String?

    // activity side of the JOIN
    public var lastActivity: Date?
    public var cost: Double
    public var sessionCount: Int
    public var machineID: String
    public var isLive: Bool
    public var blocked: Bool

    // derived, captured against `now`
    public var now: Date
    public var runway: TimeInterval
    public var idle: TimeInterval
    public var jeopardy: Double
    public var state: DeadlineState

    /// True while the countdown should redden (inside the last window).
    public func isReddening(_ config: DeadlineConfig = .init()) -> Bool {
        runway >= 0 && runway <= config.reddenWindow
    }

    public init(record: DeadlineRecord, activity: ProjectActivity?, now: Date,
                config: DeadlineConfig = .init()) {
        projectKey = record.projectKey
        deadline = record.deadline
        kind = record.kind
        platform = record.platform
        source = record.source
        shipped = record.shipped
        linearProjectId = record.linearProjectId

        lastActivity = activity?.lastActivity
        cost = activity?.cost ?? 0
        sessionCount = activity?.sessionCount ?? 0
        machineID = activity?.machineID ?? Machine.localID
        isLive = activity?.isLive ?? false
        blocked = activity?.blocked ?? false

        self.now = now
        let rw = DeadlineMetric.runway(deadline: record.deadline, now: now)
        let id = DeadlineMetric.idle(lastActivity: activity?.lastActivity, now: now, runway: rw)
        runway = rw
        idle = id
        jeopardy = DeadlineMetric.jeopardy(idle: id, runway: rw)
        state = DeadlineClassifier.classify(runway: rw, jeopardy: DeadlineMetric.jeopardy(idle: id, runway: rw),
                                            shipped: record.shipped, blocked: activity?.blocked ?? false,
                                            config: config)
    }
}

// MARK: - The board — jeopardy-sorted, STALLED pinned top, SHIPPED sunk

public enum DeadlineBoard {
    /// Build the sorted board: one card per record, joined to its activity, classified,
    /// and sorted by (state rank, jeopardy desc, nearest deadline). The rotting-near-
    /// deadline project floats to the top on its own.
    public static func build(records: [String: DeadlineRecord],
                             activity: [String: ProjectActivity],
                             now: Date, config: DeadlineConfig = .init()) -> [DeadlineCard] {
        let cards = records.values.map {
            DeadlineCard(record: $0, activity: activity[$0.projectKey], now: now, config: config)
        }
        return cards.sorted { a, b in
            if a.state.sortRank != b.state.sortRank { return a.state.sortRank < b.state.sortRank }
            // Within a rank, worst jeopardy first; then the nearest deadline; then key.
            let ja = a.jeopardy.isFinite ? a.jeopardy : Double.greatestFiniteMagnitude
            let jb = b.jeopardy.isFinite ? b.jeopardy : Double.greatestFiniteMagnitude
            if ja != jb { return ja > jb }
            if a.deadline != b.deadline { return a.deadline < b.deadline }
            return a.projectKey < b.projectKey
        }
    }

    /// The single worst card (the strip's headline / the menu-bar mirror), nil when the
    /// board is empty or only shipped cards remain.
    public static func worst(_ cards: [DeadlineCard]) -> DeadlineCard? {
        cards.first { $0.state != .shipped }
    }
}

// MARK: - Countdown formatting (coarsens with distance — no odometer, §7)

/// "13d" / "18h" / "52m" / "overdue 2d" — coarsened by distance, updated on refresh,
/// NEVER per-second (the money-odometer sin). "—" when there is no runway.
public func fmtCountdown(_ runway: TimeInterval) -> String {
    if runway < 0 {
        let ago = -runway
        if ago < 3600 { return "overdue \(Int(ago / 60))m" }
        if ago < 86400 { return "overdue \(Int(ago / 3600))h" }
        return "overdue \(Int(ago / 86400))d"
    }
    if runway < 3600 { return "\(Int(runway / 60))m" }
    if runway < 86400 { return "\(Int(runway / 3600))h" }
    return "\(Int(runway / 86400))d"
}

// MARK: - The .toml override (opt-in, user-owned, READ-only to the app, §3.3)
// A tiny TOML subset the user maintains: `[project-key]` sections (or top-level keys
// for a single project) with `deadline`, `kind`, `shipped`, `platform`. Override
// beats parse beats nothing. Deterministic + tested; the app never writes it.

public struct DeadlineOverride: Sendable, Equatable {
    public var projectKey: String
    public var deadline: Date?
    public var kind: DeadlineKind?
    public var shipped: Bool?
    public var platform: String?

    public init(projectKey: String, deadline: Date? = nil, kind: DeadlineKind? = nil,
                shipped: Bool? = nil, platform: String? = nil) {
        self.projectKey = projectKey
        self.deadline = deadline
        self.kind = kind
        self.shipped = shipped
        self.platform = platform
    }
}

public enum DeadlineTOML {
    /// Parse the override file. `defaultProject` names the implicit section for a
    /// per-project, section-less file. Unknown keys are ignored; malformed dates drop
    /// the field, never the section.
    public static func parse(_ text: String, defaultProject: String? = nil) -> [DeadlineOverride] {
        var sections: [String: DeadlineOverride] = [:]
        var current = defaultProject
        for rawLine in text.components(separatedBy: "\n") {
            var line = rawLine
            if let hash = line.firstIndex(of: "#") { line = String(line[..<hash]) }   // strip comments
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }
            if trimmed.hasPrefix("["), trimmed.hasSuffix("]") {
                current = String(trimmed.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
                if let c = current, sections[c] == nil { sections[c] = DeadlineOverride(projectKey: c) }
                continue
            }
            guard let eq = trimmed.firstIndex(of: "="), let key = current else { continue }
            let field = String(trimmed[..<eq]).trimmingCharacters(in: .whitespaces).lowercased()
            var value = String(trimmed[trimmed.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            if (value.hasPrefix("\"") && value.hasSuffix("\"")) || (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            var ov = sections[key] ?? DeadlineOverride(projectKey: key)
            switch field {
            case "deadline": if let d = parseTomlDate(value) { ov.deadline = d }
            case "kind": ov.kind = DeadlineKind(raw: value)
            case "shipped": ov.shipped = (value.lowercased() == "true")
            case "platform": ov.platform = value
            default: break
            }
            sections[key] = ov
        }
        return Array(sections.values)
    }

    /// TOML dates are unquoted RFC-3339-ish. Accept `2026-07-13`, a full offset
    /// datetime, or a space-separated one.
    static func parseTomlDate(_ s: String) -> Date? {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        if let d = iso.date(from: s) { return d }
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = iso.date(from: s) { return d }
        // date-only → 23:59:00 UTC (deadline = end of day)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        if let day = f.date(from: String(s.prefix(10))) {
            return DeadlineParser.utc.date(bySettingHour: 23, minute: 59, second: 0, of: day)
        }
        return nil
    }
}

extension DeadlineKind {
    init(raw: String) {
        let r = raw.lowercased()
        if r.contains("bounty") { self = .bounty }
        else if r.contains("audit") { self = .audit }
        else if r.contains("gate") { self = .gate }
        else if r.contains("hack") || r.contains("submission") { self = .hackathon }
        else { self = .other }
    }
}

// MARK: - The write boundary — persistence to the app's OWN dir, never ~/.claude

/// Reads/writes `~/Library/Application Support/Trifola/deadlines.json`
/// — the same app-owned directory recipes and the notify toggle live in. The project's
/// notes are a SOURCE, never a sink (§3.4). Pure `Codable` file I/O, mirroring
/// `NotifyPreferencesStore`; overridable for tests.
public struct DeadlineRecordStore: Sendable {
    public let url: URL

    public static var defaultURL: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask, appropriateFor: nil, create: false))
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Trifola/deadlines.json")
    }

    public init(url: URL = DeadlineRecordStore.defaultURL) { self.url = url }

    public func load() -> [String: DeadlineRecord] {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let recs = try? dec.decode([String: DeadlineRecord].self, from: data)
        else { return [:] }
        return recs
    }

    @discardableResult
    public func save(_ records: [String: DeadlineRecord]) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            enc.dateEncodingStrategy = .iso8601   // symmetric with load()'s decoder
            try enc.encode(records).write(to: url, options: .atomic)
            return true
        } catch { return false }
    }
}

// MARK: - Merge (parse → persisted → override), pure

public enum DeadlineMerge {
    /// Resolve the canonical record set: start from `persisted`, fill in parsed
    /// findings for projects not yet stored (unconfirmed), keep a CONFIRMED persisted
    /// record over a fresh parse, then let a user `.toml` override win outright
    /// (authoritative → confirmed). The app persists the result to its OWN store.
    public static func resolve(parsed operative: [String: ParsedDeadline],
                               persisted: [String: DeadlineRecord],
                               overrides: [DeadlineOverride]) -> [String: DeadlineRecord] {
        var out = persisted

        // A parse is a finding, and findings can RETRACT: an UNCONFIRMED persisted
        // record that the fresh parse no longer produces (and no override names, and
        // the user never marked shipped) was only ever a parse echo — drop it. This
        // is how a fixed parser false-positive actually leaves the board instead of
        // haunting it from deadlines.json. Confirmed/shipped records are the user's
        // word and never expire this way.
        let overridden = Set(overrides.map(\.projectKey))
        out = out.filter { key, rec in
            rec.source.confirmed || rec.shipped || operative[key] != nil || overridden.contains(key)
        }

        for (key, p) in operative {
            if let existing = out[key] {
                // A confirmed record is the user's word — never clobber it with a parse.
                if existing.source.confirmed { continue }
                // Unconfirmed → refresh from the latest parse (keeps provenance live).
                out[key] = DeadlineRecord(projectKey: key, deadline: p.date, kind: p.kind,
                                          source: p.source, shipped: existing.shipped,
                                          platform: p.platform ?? existing.platform,
                                          linearProjectId: existing.linearProjectId)
            } else {
                out[key] = DeadlineRecord(p)
            }
        }

        for ov in overrides {
            let key = ov.projectKey
            var rec = out[key] ?? DeadlineRecord(projectKey: key, deadline: ov.deadline ?? Date(),
                                                 kind: ov.kind ?? .other,
                                                 source: DeadlineSource(file: "", line: 0, raw: "", confirmed: true, origin: .override))
            if let d = ov.deadline { rec.deadline = d }
            if let k = ov.kind { rec.kind = k }
            if let s = ov.shipped { rec.shipped = s }
            if let pl = ov.platform { rec.platform = pl }
            // An override is authoritative — its date is confirmed by construction.
            rec.source = DeadlineSource(file: rec.source.file.isEmpty ? "deadlines.toml" : rec.source.file,
                                        line: rec.source.line, raw: rec.source.raw, confirmed: true, origin: .override)
            out[key] = rec
        }

        return out
    }
}
