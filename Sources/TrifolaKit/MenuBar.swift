import Foundation

// MARK: - Menu-bar presence (W4) — the judgment strip
//
// The menu-bar glyph reducer + menu MODEL — pure functions of (attention board,
// deadline cards, today's burn, the hog alert, the quota snapshot, now), so the
// tray surface is unit-tested without AppKit. The SwiftUI layer only renders
// what this emits.
//
// Positioning (docs/RESEARCH_top_voices.md #4, Cat Wu control-plane rule): the
// market already meters usage in the tray (CodexBar / the OAuth quota bars) —
// this strip answers the two questions no credit-bar can: "who needs me right
// now?" and "am I bleeding money right now?". It complements the main window,
// never duplicates a full screen in the menu bar.

/// The three honest states of the tray glyph — mirrors the shipped
/// `MenuBarLabel.markState` mapping (App.swift): needsYou when blocked OR
/// waiting (ball in your court), and the count text is BLOCKED only.
public enum MenuBarGlyphState: Equatable, Sendable {
    case quiet                        // hollow ring — nothing live
    case running                      // dot-in-ring — work streaming, nothing needs you
    case needsYou(blockedCount: Int)  // filled dot; count text = BLOCKED only (0 when waiting-only)
}

/// Everything the dropdown renders, computed once per tick. Equatable so the
/// view layer (and tests) can compare whole frames.
public struct MenuBarModel: Equatable, Sendable {
    /// One session that needs you — carries exactly what SessionActions.swift's
    /// row actions need, so the row's click never has to re-derive anything.
    public struct AttentionRow: Equatable, Sendable, Identifiable {
        public var id: String            // session id (session-transport key)
        public var title: String         // displayTitle — your name for it
        public var project: String
        public var cwd: String
        public var lastUserMessage: String?
        public var age: TimeInterval     // seconds stuck / waiting
        public var tier: ModelTier       // the model wearing the seat
        public var classifierConfidence: AttentionClassification.Confidence
        public var classifierReason: String
        public var tierLabel: String { tier.label }
        public var classifierDiagnostic: String {
            "\(classifierConfidence.rawValue): \(classifierReason)"
        }

        public init(id: String, title: String, project: String, cwd: String,
                    lastUserMessage: String?, age: TimeInterval, tier: ModelTier,
                    classifierConfidence: AttentionClassification.Confidence = .low,
                    classifierReason: String = "state supplied without classifier evidence") {
            self.id = id
            self.title = title
            self.project = project
            self.cwd = cwd
            self.lastUserMessage = lastUserMessage
            self.age = age
            self.tier = tier
            self.classifierConfidence = classifierConfidence
            self.classifierReason = classifierReason
        }
    }

    public struct JeopardyLine: Equatable, Sendable {
        public var projectKey: String
        public var countdown: String     // fmtCountdown(runway)
        public var stateLabel: String    // DeadlineState.label

        public init(projectKey: String, countdown: String, stateLabel: String) {
            self.projectKey = projectKey
            self.countdown = countdown
            self.stateLabel = stateLabel
        }
    }

    /// The tray glyph, derived from the same board as everything below.
    public var glyph: MenuBarGlyphState
    /// The text beside the glyph: the BLOCKED count when any; today's whole-$
    /// when a hog alert is live and nothing is blocked; nil when calm.
    public var title: String?
    /// "2 blocked · 1 waiting · 3 running · $73 today" — non-zero counts only.
    public var fleetLine: String
    /// BLOCKED sessions, stuck-longest FIRST (the board's own sort is
    /// freshest-first, which is the wrong order for triage).
    public var blocked: [AttentionRow]
    /// WAITING sessions, longest-waiting first — the run contract's attention
    /// list covers WAITING too, not just BLOCKED.
    public var waiting: [AttentionRow]
    /// The single worst non-shipped deadline; nil when none exists.
    public var jeopardy: JeopardyLine?
    /// The orchestrator-hog advisor, nil when quiet — same alert the MCP
    /// `cost_today` tool serves (one cost machinery, never a fork).
    public var hogLine: String?
    /// The hottest plan-quota window strictly over the threshold, nil when calm.
    public var quotaLine: String?

    public init(glyph: MenuBarGlyphState, title: String?, fleetLine: String,
                blocked: [AttentionRow], waiting: [AttentionRow],
                jeopardy: JeopardyLine?, hogLine: String? = nil, quotaLine: String? = nil) {
        self.glyph = glyph
        self.title = title
        self.fleetLine = fleetLine
        self.blocked = blocked
        self.waiting = waiting
        self.jeopardy = jeopardy
        self.hogLine = hogLine
        self.quotaLine = quotaLine
    }
}

public enum MenuBarReducer {
    /// A quota window is "hot" strictly ABOVE this percent used — the house
    /// rule (`isContextHeavy`, `OrchestratorHog.shareThreshold`): exactly at
    /// the bar is at the bar, not over it.
    public static let quotaHotPercent = 80.0

    /// The glyph, from the board alone. Matches the shipped mapping: needsYou
    /// when blocked OR waiting, running when work streams, quiet otherwise.
    public static func glyph(board: AttentionBoard) -> MenuBarGlyphState {
        if board.blockedCount > 0 || board.waitingCount > 0 {
            return .needsYou(blockedCount: board.blockedCount)
        }
        if board.runningCount > 0 { return .running }
        return .quiet
    }

    /// "9+" display cap for the count next to the glyph.
    public static func countLabel(_ n: Int) -> String { n > 9 ? "9+" : "\(n)" }

    /// The text beside the glyph. BLOCKED count first (shipped semantics —
    /// count text is BLOCKED only); when nothing is blocked but the hog alert
    /// fires, today's whole-$ so the "bleeding money" state is visible without
    /// opening anything; nil when neither.
    public static func titleText(board: AttentionBoard, hogFiring: Bool,
                                 todayCost: Double) -> String? {
        if board.blockedCount > 0 { return countLabel(board.blockedCount) }
        if hogFiring { return String(format: "$%.0f", todayCost) }
        return nil
    }

    /// The hottest window strictly over `quotaHotPercent`, formatted; nil when
    /// every window is calm (or there is no snapshot). "Session (5h) 91% used
    /// · resets 2h" — reset countdown via the deadline board's `fmtCountdown`.
    public static func hotQuotaLine(_ snapshot: QuotaSnapshot?, now: Date) -> String? {
        guard let snapshot else { return nil }
        let hot = snapshot.windows
            .filter { $0.usedPercent > quotaHotPercent }
            .max { $0.usedPercent < $1.usedPercent }
        guard let hot else { return nil }
        var line = "\(hot.title) \(hot.roundedUsedPercent)% used"
        if let resets = hot.resetsAt {
            line += " · resets \(fmtCountdown(resets.timeIntervalSince(now)))"
        }
        return line
    }

    /// The whole dropdown, one pure call. `fmtUSD` (Kit) renders cents under
    /// $10 — the fleet line wants whole dollars ("$0 today"), so it formats
    /// inline with "%.0f" instead.
    public static func model(board: AttentionBoard, cards: [DeadlineCard],
                             todayCost: Double,
                             hog: OrchestratorHogAlert? = nil,
                             quota: QuotaSnapshot? = nil,
                             now: Date) -> MenuBarModel {
        let fleetLine = FleetSummaryReducer.fleetLine(board: board, todayCost: todayCost)

        func row(_ item: AttentionItem) -> MenuBarModel.AttentionRow {
            MenuBarModel.AttentionRow(id: item.session.id,
                                      title: item.session.displayTitle,
                                      project: item.session.project,
                                      cwd: item.session.cwd,
                                      lastUserMessage: item.session.lastUserMessage,
                                      age: item.age,
                                      tier: item.session.tier,
                                      classifierConfidence: item.classifierConfidence,
                                      classifierReason: item.classifierReason)
        }
        // Triage order: stuck longest first (the board sorts freshest-first).
        let blocked = board.items.filter { $0.state == .blocked }
            .sorted { $0.age > $1.age }.map(row)
        let waiting = board.items.filter { $0.state == .waiting }
            .sorted { $0.age > $1.age }.map(row)

        let jeopardy = DeadlineBoard.worst(cards).map {
            MenuBarModel.JeopardyLine(projectKey: $0.projectKey,
                                      countdown: fmtCountdown($0.runway),
                                      stateLabel: $0.state.label)
        }

        // The hog flag reuses the alert's own numbers (same cost machinery as
        // cost_today) — evidence with the share in the copy, never a bare nag.
        let hogLine = hog.map {
            "\($0.project) · \($0.handle) is \(fmtPct($0.share)) of \(fmtUSD($0.dayTotal)) today — delegate to cheaper subagents"
        }

        return MenuBarModel(glyph: glyph(board: board),
                            title: titleText(board: board, hogFiring: hog != nil,
                                             todayCost: todayCost),
                            fleetLine: fleetLine,
                            blocked: blocked,
                            waiting: waiting,
                            jeopardy: jeopardy,
                            hogLine: hogLine,
                            quotaLine: hotQuotaLine(quota, now: now))
    }
}

// MARK: - Presence preference (persisted to the app's OWN dir, never ~/.claude)

/// The menu-bar presence toggle. Default ON — presence is the product (unlike
/// walk-away notify, which is steering-adjacent and stays opt-in OFF).
public struct MenuBarPreferences: Codable, Sendable, Equatable {
    public var enabled: Bool

    public init(enabled: Bool = true) { self.enabled = enabled }
}

/// Reads/writes the presence toggle in ~/Library/Application Support/
/// Trifola/menubar.json (overridable for tests). Explicitly NOT
/// ~/.claude — the app never writes there (the user's own rule). Mirrors
/// `NotifyPreferencesStore` exactly.
public struct MenuBarPreferencesStore: Sendable {
    public let url: URL

    /// The default app-support preferences file.
    public static var defaultURL: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask, appropriateFor: nil, create: false))
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Trifola/menubar.json")
    }

    public init(url: URL = MenuBarPreferencesStore.defaultURL) { self.url = url }

    /// Load the toggle, defaulting to ON (presence is the product) when the
    /// file is absent/unreadable.
    public func load() -> MenuBarPreferences {
        guard let data = try? Data(contentsOf: url),
              let prefs = try? JSONDecoder().decode(MenuBarPreferences.self, from: data)
        else { return MenuBarPreferences() }
        return prefs
    }

    /// Persist the toggle atomically. Returns false on any I/O error (the
    /// caller degrades silently — a failed write just leaves the last value on disk).
    @discardableResult
    public func save(_ prefs: MenuBarPreferences) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let enc = JSONEncoder()
            enc.outputFormatting = [.prettyPrinted, .sortedKeys]
            try enc.encode(prefs).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}
