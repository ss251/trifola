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
        #expect(preferences.claudeQuotaAccessEnabled == false)
        #expect(preferences.codexQuotaAccessEnabled == false)
        #expect(preferences.grokQuotaAccessEnabled == false)
        #expect(preferences.hasSeenAccessibilityWorkspaceExplainer == false)
        #expect(preferences.hasCompletedFirstLaunchWelcome == false)
        #expect(preferences.hasSeenTerminalAutomationPrimer == false)
        #expect(preferences.hasOpenedAccessibilitySettings == false)
        #expect(preferences.showHeuristicLineageLinks == true)
    }

    @Test func roundTripsThroughAppSupportStyleStore() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("trifola-settings-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppPreferencesStore(url: directory.appendingPathComponent("settings.json"))

        #expect(store.load() == AppPreferences())
        let expected = AppPreferences(
            quietHours: QuietHours(enabled: true, startMinute: 21 * 60 + 30, endMinute: 7 * 60),
            defaultSnoozeDurationMinutes: 120,
            claudeQuotaAccessEnabled: true,
            codexQuotaAccessEnabled: true,
            grokQuotaAccessEnabled: true,
            hasSeenAccessibilityWorkspaceExplainer: true,
            hasCompletedFirstLaunchWelcome: true,
            hasSeenTerminalAutomationPrimer: true,
            hasOpenedAccessibilitySettings: true
        )
        #expect(store.save(expected))
        #expect(store.load() == expected)
    }

    @Test func missingNewFieldsDecodeToDefaults() throws {
        let decoded = try JSONDecoder().decode(AppPreferences.self, from: Data("{}".utf8))
        #expect(decoded == AppPreferences())
        #expect(!decoded.hasSeenAccessibilityWorkspaceExplainer)
        #expect(!decoded.hasCompletedFirstLaunchWelcome)
        #expect(!decoded.hasSeenTerminalAutomationPrimer)
        #expect(!decoded.hasOpenedAccessibilitySettings)
        #expect(decoded.showHeuristicLineageLinks)
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

    @Test func saveReportsFailureInsteadOfPretendingSettingsPersisted() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("trifola-settings-failure-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let blocker = directory.appendingPathComponent("not-a-directory")
        try Data("x".utf8).write(to: blocker)
        let store = AppPreferencesStore(url: blocker.appendingPathComponent("settings.json"))
        #expect(!store.save(AppPreferences(defaultSnoozeDurationMinutes: 30)))
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

    @Test func oneResolvedRootDerivesEveryClaudeSurface() {
        let home = URL(fileURLWithPath: "/Users/dev/", isDirectory: true)
        let paths = ClaudePaths.resolve(
            home: home,
            environment: [
                "CLAUDE_CONFIG_DIR": "/tmp/team-claude",
                "TRIFOLA_SESSION_INDEX_CACHE": "/tmp/team-index.json",
            ])
        #expect(paths.root.path == "/tmp/team-claude")
        #expect(paths.projects.path == "/tmp/team-claude/projects")
        #expect(paths.sessions.path == "/tmp/team-claude/sessions")
        #expect(paths.settingsJSON.path == "/tmp/team-claude/settings.json")
        #expect(paths.globalClaudeMD.path == "/tmp/team-claude/CLAUDE.md")
        #expect(paths.agents.path == "/tmp/team-claude/agents")
        #expect(paths.skills.path == "/tmp/team-claude/skills")
        #expect(paths.pluginCache.path == "/tmp/team-claude/plugins/cache")
        #expect(paths.sessionIndexCacheURL.path == "/tmp/team-index.sqlite3")
        #expect(paths.legacySessionIndexCacheURL.path == "/tmp/team-index.json")
        #expect(paths.searchIndexCacheURL.path == "/tmp/search-index.sqlite3")
        #expect(paths.legacySearchIndexCacheURL.path == "/tmp/search-index.json")
    }

    // Launches the real .build/debug/Trifola executable, which `swift test` does
    // not build on CI (the test target depends on TrifolaKit, not the app product),
    // and which links AppKit and can block headless. This is a developer-machine
    // integration check, not a CI gate — it disables itself where CI is set.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CI"] == nil))
    func cliProcessReadsOnlyTheOverriddenCorpus() throws {
        let fixture = FileManager.default.temporaryDirectory
            .appendingPathComponent("trifola-path-process-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: fixture) }
        let projects = fixture.appendingPathComponent("projects/project", isDirectory: true)
        try FileManager.default.createDirectory(at: projects,
                                                withIntermediateDirectories: true)
        let transcript = #"{"type":"assistant","sessionId":"override-only","cwd":"/fixture/override-only","requestId":"override-request","timestamp":"2026-01-01T10:00:00.000Z","message":{"id":"override-message","model":"claude-opus-4-8","usage":{"input_tokens":1000000,"output_tokens":0,"cache_creation_input_tokens":0,"cache_read_input_tokens":0}}}"#
        try (transcript + "\n").write(
            to: projects.appendingPathComponent("override-only.jsonl"),
            atomically: true, encoding: .utf8)

        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let executable = repository.appendingPathComponent(".build/debug/Trifola")
        #expect(FileManager.default.isExecutableFile(atPath: executable.path))
        // The session index migrated to SQLite: the requested cache path's
        // extension is rewritten to .sqlite3 (SessionIndexStorage).
        let cache = fixture.appendingPathComponent("override-index.sqlite3")
        let process = Process()
        process.executableURL = executable
        process.arguments = ["--spend-by-model", "2026-01-01"]
        var environment = ProcessInfo.processInfo.environment
        environment["CLAUDE_CONFIG_DIR"] = fixture.path
        environment["TRIFOLA_SESSION_INDEX_CACHE"] = cache.path
        process.environment = environment
        let stdout = Pipe()
        let stderr = Pipe()
        process.standardOutput = stdout
        process.standardError = stderr
        try process.run()
        // Watchdog: a headless spend query must exit in well under a second. If it
        // ever regresses into the GUI runloop, terminate rather than hang the suite.
        // 60s, not 15: this spawns the real debug binary and flaked twice under
        // parallel release-build load. Generous beats flaky for a hang-guard.
        let deadline = Date().addingTimeInterval(60)
        while process.isRunning && Date() < deadline { usleep(20_000) }
        if process.isRunning { process.terminate() }
        process.waitUntilExit()
        let output = String(
            data: stdout.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8) ?? ""
        let errors = String(
            data: stderr.fileHandleForReading.readDataToEndOfFile(),
            encoding: .utf8) ?? ""
        #expect(process.terminationStatus == 0, "\(errors)")
        #expect(output.contains("claude-opus-4-8"))
        #expect(output.contains("in=    1000000"))
        #expect(output.contains("TOTAL $5.00"))
        #expect(FileManager.default.fileExists(atPath: cache.path))
    }
}
