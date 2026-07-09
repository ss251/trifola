import Foundation

// MARK: - Walk-Away Notify (frontier #2)
// The ONE allowed notification exception (VISION "What it should NOT be" → "Not a
// nag": the sole exception is BLOCKED, "because that badge asks for attention you
// already owe"). When a live session ENTERS the BLOCKED state — a dangling tool_use
// past 30s, a human gate — the fleet posts a single macOS user notification so an
// operator running multi-hour walk-away loops (`/loop`, `/goal`, 4–5h) knows a
// session needs them WITHOUT watching the window (docs/RESEARCH_frontier.md Angle 2).
//
// Everything in this file is PURE and testable: the rising-edge diff and the
// coalesced notification content are computed with no AppKit / UNUserNotification /
// filesystem / clock — so the whole notify POLICY is exercised in unit tests against
// hand-built boards. The UNUserNotificationCenter plumbing, the click→activate
// handoff and the opt-in toggle's UI live in the App layer over this core.

// MARK: - The coalesced notification (content only, no side effects)

/// One BLOCKED notification, ready for the App layer to post. Coalesced: a burst of
/// simultaneous flips becomes a single "N sessions need you" rather than N banners.
public struct BlockedNotification: Sendable, Equatable {
    /// The session ids that just ENTERED blocked this cycle, in board order
    /// (BLOCKED-first, freshest-first) — the rising edges only.
    public let sessionIDs: [String]
    /// Title: the project name for a single flip; "N sessions need you" when several
    /// flip at once.
    public let title: String
    /// Body: the blocking action (tool · now-line detail) for a single session; the
    /// affected project names when coalesced.
    public let body: String
    /// The session to focus when the notification is clicked (the freshest blocked
    /// rising edge) — the activate / deep-link target.
    public let primarySessionID: String

    public init(sessionIDs: [String], title: String, body: String, primarySessionID: String) {
        self.sessionIDs = sessionIDs
        self.title = title
        self.body = body
        self.primarySessionID = primarySessionID
    }

    /// How many sessions this one notification speaks for.
    public var count: Int { sessionIDs.count }
}

/// The result of one notify evaluation: the notification to post (nil when no
/// session newly entered blocked) and the new tracked set to carry into the next
/// cycle. Adopting `newState` is what makes an unblock CLEAR and a later reblock
/// RE-NOTIFY.
public struct NotifyPlan: Sendable, Equatable {
    public let notification: BlockedNotification?
    public let newState: Set<String>

    public init(notification: BlockedNotification?, newState: Set<String>) {
        self.notification = notification
        self.newState = newState
    }
}

// MARK: - The pure notifier

public enum BlockedNotifier {

    /// THE load-bearing rising-edge diff — a pure function of two sets.
    /// `(previouslyBlocked, currentBlocked) → (ids that just entered blocked, the new
    /// tracked set)`. `newState` is exactly `currentBlocked`, which gives every
    /// required transition for free:
    ///   • quiet → blocked    ⇒ id in `toNotify` (rising edge — notify)
    ///   • blocked → blocked  ⇒ id NOT in `toNotify` (already tracked — silent)
    ///   • blocked → unblock  ⇒ id dropped from `newState` (cleared)
    ///   • unblock → reblock  ⇒ id in `toNotify` again (it left the set on unblock)
    ///   • several at once    ⇒ every fresh id in `toNotify` (caller coalesces)
    public static func risingEdges(previouslyBlocked: Set<String>,
                                   currentBlocked: Set<String>)
        -> (toNotify: Set<String>, newState: Set<String>) {
        (currentBlocked.subtracting(previouslyBlocked), currentBlocked)
    }

    /// Build a full plan from the live board: diff the board's BLOCKED set against
    /// the previously-notified set on the rising edge, and — only when there ARE
    /// rising edges — compose one coalesced notification. Pure: no posting, no clock,
    /// no I/O. The board is already sorted BLOCKED-first / freshest-first, so the
    /// notification content is deterministic.
    public static func plan(board: AttentionBoard,
                            signals: [String: AttentionSignals],
                            previouslyBlocked: Set<String>) -> NotifyPlan {
        let blockedItems = board.items.filter { $0.state == .blocked }
        let currentBlocked = Set(blockedItems.map(\.id))
        let (toNotify, newState) = risingEdges(previouslyBlocked: previouslyBlocked,
                                               currentBlocked: currentBlocked)
        guard !toNotify.isEmpty else {
            return NotifyPlan(notification: nil, newState: newState)
        }
        // Rising-edge items, kept in board order (stable, deterministic content).
        let rising = blockedItems.filter { toNotify.contains($0.id) }
        return NotifyPlan(notification: compose(rising: rising, signals: signals),
                          newState: newState)
    }

    /// Compose the coalesced notification content from the rising-edge items.
    static func compose(rising: [AttentionItem],
                        signals: [String: AttentionSignals]) -> BlockedNotification {
        let ids = rising.map(\.id)
        let primary = ids.first ?? ""
        if rising.count == 1, let item = rising.first {
            // A single flip: name the project, and say what it's stuck on.
            return BlockedNotification(sessionIDs: ids,
                                       title: item.session.project,
                                       body: blockingAction(for: item, signals: signals),
                                       primarySessionID: primary)
        }
        // A burst: one banner for all of them (no alert storm).
        return BlockedNotification(sessionIDs: ids,
                                   title: "\(rising.count) sessions need you",
                                   body: coalescedBody(rising.map { $0.session.project }),
                                   primarySessionID: primary)
    }

    /// The blocking action for a single session, from the now-line — the dangling
    /// `tool_use` it is stuck on: "Bash · git push origin main", "Edit · App.swift".
    /// Falls back to a bare "Blocked — needs you" when the tail carried no tool name.
    static func blockingAction(for item: AttentionItem,
                               signals: [String: AttentionSignals]) -> String {
        guard let sig = signals[item.id], let tool = sig.lastToolName else {
            return "Blocked — needs you"
        }
        if let detail = sig.lastToolDetail, !detail.isEmpty {
            return "\(tool) · \(detail)"
        }
        return "Blocked on \(tool)"
    }

    /// "webapp, api-gateway, contest & 2 more" — the affected projects, capped so the body
    /// stays glanceable in a banner.
    static func coalescedBody(_ projects: [String]) -> String {
        guard !projects.isEmpty else { return "Sessions need you" }
        let shown = projects.prefix(3)
        let rest = projects.count - shown.count
        var s = shown.joined(separator: ", ")
        if rest > 0 { s += " & \(rest) more" }
        return s
    }
}

// MARK: - Opt-in preference (persisted to the app's OWN dir, never ~/.claude)

/// The walk-away-notify opt-in, mirrored to the app's own Application Support dir.
/// This is PRESENCE, not steering: default OFF (opt-in), and the only thing it ever
/// gates is the single BLOCKED banner.
public struct NotifyPreferences: Codable, Sendable, Equatable {
    /// OFF until the user turns it on — opt-in by design.
    public var enabled: Bool

    public init(enabled: Bool = false) { self.enabled = enabled }
}

/// Reads/writes the notify toggle in ~/Library/Application Support/
/// Trifola/notify.json (overridable for tests). Explicitly NOT
/// ~/.claude — the app never writes there (the user's own rule). Pure file I/O over
/// `Codable`, mirroring `RecipeRepository`.
public struct NotifyPreferencesStore: Sendable {
    public let url: URL

    /// The default app-support preferences file.
    public static var defaultURL: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask, appropriateFor: nil, create: false))
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Trifola/notify.json")
    }

    public init(url: URL = NotifyPreferencesStore.defaultURL) { self.url = url }

    /// Load the toggle, defaulting to OFF (opt-in) when the file is absent/unreadable.
    public func load() -> NotifyPreferences {
        guard let data = try? Data(contentsOf: url),
              let prefs = try? JSONDecoder().decode(NotifyPreferences.self, from: data)
        else { return NotifyPreferences() }
        return prefs
    }

    /// Persist the toggle atomically. Returns false on any I/O error (the caller
    /// degrades silently — a failed write just leaves the last value on disk).
    @discardableResult
    public func save(_ prefs: NotifyPreferences) -> Bool {
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
