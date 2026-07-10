import Foundation
import Testing
@testable import TrifolaKit

@Suite("Settings preferences")
struct SettingsPreferencesTests {
    @Test func defaultsAreSafeAndUseful() {
        let preferences = AppPreferences()
        #expect(preferences.quietHours.enabled == false)
        #expect(preferences.quietHours.startMinute == 22 * 60)
        #expect(preferences.quietHours.endMinute == 8 * 60)
        #expect(preferences.defaultSnoozeDurationMinutes == 60)
    }

    @Test func roundTripsThroughAppSupportStyleStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("trifola-settings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppPreferencesStore(url: directory.appendingPathComponent("settings.json"))

        #expect(store.load() == AppPreferences())
        let expected = AppPreferences(
            quietHours: QuietHours(enabled: true, startMinute: 21 * 60 + 30, endMinute: 7 * 60),
            defaultSnoozeDurationMinutes: 120
        )
        #expect(store.save(expected))
        #expect(store.load() == expected)
    }

    @Test func missingNewFieldsDecodeToDefaults() throws {
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: Data("{}".utf8))
        #expect(decoded == AppPreferences())
    }

    @Test func defaultStoreNeverWritesIntoClaudeConfig() {
        let path = AppPreferencesStore.defaultURL.path
        #expect(path.contains("Application Support/Trifola/settings.json"))
        #expect(!path.contains("/.claude"))
    }

    @Test func defaultSnoozeDurationBuildsExpiry() {
        let start = Date(timeIntervalSince1970: 1_000)
        let preferences = AppPreferences(defaultSnoozeDurationMinutes: 90)
        #expect(preferences.defaultSnoozeExpiry(from: start) == start.addingTimeInterval(5_400))
    }
}

@Suite("Quiet hours")
struct QuietHoursTests {
    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(hour: Int, minute: Int = 0) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 7, day: 10,
                                     hour: hour, minute: minute))!
    }

    @Test func disabledByDefaultNeverContainsTime() {
        let quietHours = QuietHours()
        #expect(!quietHours.contains(date(hour: 23), calendar: utc))
    }

    @Test func overnightRangeWrapsAcrossMidnight() {
        let quietHours = QuietHours(enabled: true, startMinute: 22 * 60, endMinute: 8 * 60)
        #expect(quietHours.contains(date(hour: 22), calendar: utc))
        #expect(quietHours.contains(date(hour: 2), calendar: utc))
        #expect(!quietHours.contains(date(hour: 8), calendar: utc))
        #expect(!quietHours.contains(date(hour: 12), calendar: utc))
    }

    @Test func sameDayRangeUsesInclusiveStartExclusiveEnd() {
        let quietHours = QuietHours(enabled: true, startMinute: 9 * 60, endMinute: 17 * 60)
        #expect(!quietHours.contains(date(hour: 8, minute: 59), calendar: utc))
        #expect(quietHours.contains(date(hour: 9), calendar: utc))
        #expect(!quietHours.contains(date(hour: 17), calendar: utc))
    }

    @Test func equalEndpointsDoNotAccidentallySilenceAllDay() {
        let quietHours = QuietHours(enabled: true, startMinute: 0, endMinute: 0)
        #expect(!quietHours.contains(date(hour: 12), calendar: utc))
    }
}

@Suite("Notification quiet-hours policy")
struct NotificationPolicyTests {
    private let notification = BlockedNotification(
        sessionIDs: ["session-a"],
        title: "webapp",
        body: "Blocked on Bash",
        primarySessionID: "session-a"
    )

    private var utc: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(hour: Int) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 7, day: 10, hour: hour))!
    }

    @Test func quietHoursSuppressDeliveryButRetainAlertTracking() {
        let plan = NotifyPlan(notification: notification, newState: ["session-a"])
        let preferences = AppPreferences(
            quietHours: QuietHours(enabled: true, startMinute: 22 * 60, endMinute: 8 * 60)
        )

        let decision = NotificationPolicy.reduce(plan: plan, preferences: preferences,
                                                  at: date(hour: 23), calendar: utc)
        #expect(decision.notification == nil)
        #expect(decision.suppressedByQuietHours)
        // State advances, so ending quiet hours cannot emit a stale rising edge.
        #expect(decision.newState == ["session-a"])
    }

    @Test func stripAndGlyphInputsAreNotPartOfTheSuppressionBoundary() {
        let plan = NotifyPlan(notification: notification, newState: ["session-a"])
        let preferences = AppPreferences(
            quietHours: QuietHours(enabled: true, startMinute: 22 * 60, endMinute: 8 * 60)
        )
        let decision = NotificationPolicy.reduce(plan: plan, preferences: preferences,
                                                  at: date(hour: 23), calendar: utc)

        #expect(decision.newState == plan.newState)
        #expect(plan.notification == notification)
    }

    @Test func outsideQuietHoursDeliversUnchanged() {
        let plan = NotifyPlan(notification: notification, newState: ["session-a"])
        let preferences = AppPreferences(
            quietHours: QuietHours(enabled: true, startMinute: 22 * 60, endMinute: 8 * 60)
        )
        let decision = NotificationPolicy.reduce(plan: plan, preferences: preferences,
                                                  at: date(hour: 12), calendar: utc)
        #expect(decision.notification == notification)
        #expect(!decision.suppressedByQuietHours)
        #expect(decision.newState == plan.newState)
    }

    @Test func noNotificationIsNotReportedAsSuppressed() {
        let plan = NotifyPlan(notification: nil, newState: ["session-a"])
        let preferences = AppPreferences(
            quietHours: QuietHours(enabled: true, startMinute: 22 * 60, endMinute: 8 * 60)
        )
        let decision = NotificationPolicy.reduce(plan: plan, preferences: preferences,
                                                  at: date(hour: 23), calendar: utc)
        #expect(decision.notification == nil)
        #expect(!decision.suppressedByQuietHours)
        #expect(decision.newState == plan.newState)
    }
}

@Suite("Claude config location")
struct ClaudeConfigLocationTests {
    @Test func defaultDelegatesToDotClaude() {
        let home = URL(fileURLWithPath: "/Users/dev/", isDirectory: true)
        let location = ClaudeConfigLocation.resolve(home: home, environment: [:])
        #expect(location.url.path == "/Users/dev/.claude")
        #expect(location.source == .defaultDirectory)
        #expect(location.explainer.contains("~/.claude"))
    }

    @Test func environmentOverrideIsResolvedAndExplained() {
        let home = URL(fileURLWithPath: "/Users/dev/", isDirectory: true)
        let location = ClaudeConfigLocation.resolve(
            home: home,
            environment: ["CLAUDE_CONFIG_DIR": "/tmp/team-claude"]
        )
        #expect(location.url.path == "/tmp/team-claude")
        #expect(location.source == .environmentOverride)
        #expect(location.explainer.contains("CLAUDE_CONFIG_DIR"))
    }
}
