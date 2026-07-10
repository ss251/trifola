import Foundation

// MARK: - Attention settings

/// A wall-clock interval during which notification delivery is quiet. This is
/// intentionally only a delivery preference: attention boards and menu-bar
/// models continue to render from the unfiltered fleet.
public struct QuietHours: Codable, Sendable, Equatable {
    /// Quiet hours are opt-in. The default interval is merely a useful starting
    /// point for the controls when the user enables them.
    public var enabled: Bool
    /// Local wall-clock minute in `0 ... 1439` at which quiet hours begin.
    public var startMinute: Int
    /// Local wall-clock minute in `0 ... 1439` at which quiet hours end.
    public var endMinute: Int

    public init(enabled: Bool = false, startMinute: Int = 22 * 60, endMinute: Int = 8 * 60) {
        self.enabled = enabled
        self.startMinute = Self.normalized(startMinute)
        self.endMinute = Self.normalized(endMinute)
    }

    /// Whether `date` falls inside the configured interval in `calendar`'s time
    /// zone. Overnight intervals wrap across midnight. Equal endpoints are an
    /// empty interval, avoiding an accidental all-day silence.
    public func contains(_ date: Date, calendar: Calendar = .current) -> Bool {
        guard enabled, startMinute != endMinute else { return false }
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        guard let hour = parts.hour, let minute = parts.minute else { return false }
        let current = hour * 60 + minute
        if startMinute < endMinute {
            return current >= startMinute && current < endMinute
        }
        return current >= startMinute || current < endMinute
    }

    private enum CodingKeys: String, CodingKey { case enabled, startMinute, endMinute }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        enabled = try values.decodeIfPresent(Bool.self, forKey: .enabled) ?? false
        startMinute = Self.normalized(try values.decodeIfPresent(Int.self, forKey: .startMinute) ?? 22 * 60)
        endMinute = Self.normalized(try values.decodeIfPresent(Int.self, forKey: .endMinute) ?? 8 * 60)
    }

    private static func normalized(_ minute: Int) -> Int {
        ((minute % (24 * 60)) + (24 * 60)) % (24 * 60)
    }
}

/// Preferences owned by the Settings window. Existing menu-bar-presence and
/// notification opt-in stores remain the source of truth for their toggles.
public struct AppPreferences: Codable, Sendable, Equatable {
    public var quietHours: QuietHours
    /// Default duration offered by generic Snooze actions. Stored as whole
    /// minutes so the value is stable across UI and persistence boundaries.
    public var defaultSnoozeDurationMinutes: Int

    public init(quietHours: QuietHours = QuietHours(),
                defaultSnoozeDurationMinutes: Int = 60) {
        self.quietHours = quietHours
        self.defaultSnoozeDurationMinutes = max(1, defaultSnoozeDurationMinutes)
    }

    /// Convenience for computing an expiry without duplicating minute-to-second
    /// conversion at each Snooze action site.
    public func defaultSnoozeExpiry(from date: Date) -> Date {
        date.addingTimeInterval(TimeInterval(defaultSnoozeDurationMinutes * 60))
    }

    private enum CodingKeys: String, CodingKey { case quietHours, defaultSnoozeDurationMinutes }

    public init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        quietHours = try values.decodeIfPresent(QuietHours.self, forKey: .quietHours) ?? QuietHours()
        defaultSnoozeDurationMinutes = max(
            1,
            try values.decodeIfPresent(Int.self, forKey: .defaultSnoozeDurationMinutes) ?? 60
        )
    }
}

/// Codable persistence in Trifola's own Application Support directory. It never
/// writes to Claude Code's configuration root.
public struct AppPreferencesStore: Sendable {
    public let url: URL

    public static var defaultURL: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil,
                                                 create: false))
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Trifola/settings.json")
    }

    public init(url: URL = AppPreferencesStore.defaultURL) { self.url = url }

    /// Missing, unreadable, and invalid files degrade to safe defaults: quiet
    /// hours off and a one-hour default snooze.
    public func load() -> AppPreferences {
        guard let data = try? Data(contentsOf: url),
              let preferences = try? JSONDecoder().decode(AppPreferences.self, from: data)
        else { return AppPreferences() }
        return preferences
    }

    @discardableResult
    public func save(_ preferences: AppPreferences) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(preferences).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - Notification delivery policy

/// The delivery-only result of applying settings to a notifier plan. `newState`
/// always comes directly from the notifier, including while quiet, so a blocked
/// session does not produce a stale banner when quiet hours end.
public struct NotificationDecision: Sendable, Equatable {
    public let notification: BlockedNotification?
    public let newState: Set<String>
    public let suppressedByQuietHours: Bool

    public init(notification: BlockedNotification?,
                newState: Set<String>,
                suppressedByQuietHours: Bool) {
        self.notification = notification
        self.newState = newState
        self.suppressedByQuietHours = suppressedByQuietHours
    }
}

public enum NotificationPolicy {
    /// Suppress only notification delivery during quiet hours. The input board is
    /// untouched, and the notifier state advances exactly as it would otherwise;
    /// strip and menu-bar alert semantics therefore remain honest and unchanged.
    public static func reduce(plan: NotifyPlan,
                              preferences: AppPreferences,
                              at date: Date,
                              calendar: Calendar = .current) -> NotificationDecision {
        let isQuiet = preferences.quietHours.contains(date, calendar: calendar)
        let suppressed = isQuiet && plan.notification != nil
        return NotificationDecision(notification: suppressed ? nil : plan.notification,
                                    newState: plan.newState,
                                    suppressedByQuietHours: suppressed)
    }
}

// MARK: - Read-only Claude config location

public enum ClaudeConfigLocationSource: Sendable, Equatable {
    case defaultDirectory
    case environmentOverride
}

/// The resolved, read-only Claude Code config location shown in General settings.
public struct ClaudeConfigLocation: Sendable, Equatable {
    public let url: URL
    public let source: ClaudeConfigLocationSource

    public init(url: URL, source: ClaudeConfigLocationSource) {
        self.url = url
        self.source = source
    }

    public var explainer: String {
        switch source {
        case .defaultDirectory: return "Claude Code's default ~/.claude directory"
        case .environmentOverride: return "Resolved from CLAUDE_CONFIG_DIR"
        }
    }

    /// Delegates path resolution to the credential reader so Settings cannot
    /// drift from the rest of Trifola's config-root behavior.
    public static func resolve(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> ClaudeConfigLocation {
        let override = environment["CLAUDE_CONFIG_DIR"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ClaudeConfigLocation(
            url: ClaudeCredentialReader.configDirectory(home: home, environment: environment),
            source: override?.isEmpty == false ? .environmentOverride : .defaultDirectory
        )
    }
}
