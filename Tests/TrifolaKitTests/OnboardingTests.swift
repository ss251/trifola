import Foundation
import Testing
@testable import TrifolaKit

@Suite("First-run onboarding")
struct FirstRunOnboardingTests {
    @Test("corpus-present welcome persists once and never becomes a recurring gate")
    func welcomeOncePersistence() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("trifola-onboarding-\(UUID().uuidString)",
                                  isDirectory: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = AppPreferencesStore(
            url: directory.appendingPathComponent("settings.json"))
        let corpus = ProviderCorpusPresence(providers: [.claude])

        #expect(FirstLaunchOnboardingPolicy.shouldPresentWelcome(
            corpusPresence: corpus,
            hasCompletedWelcome: store.load().hasCompletedFirstLaunchWelcome))

        var completed = store.load()
        completed.hasCompletedFirstLaunchWelcome = true
        #expect(store.save(completed))
        #expect(!FirstLaunchOnboardingPolicy.shouldPresentWelcome(
            corpusPresence: corpus,
            hasCompletedWelcome: store.load().hasCompletedFirstLaunchWelcome))
        #expect(!FirstLaunchOnboardingPolicy.shouldPresentWelcome(
            corpusPresence: ProviderCorpusPresence(providers: []),
            hasCompletedWelcome: false))
    }

    @Test("welcome and Automation copy name exact local access and honest denial fallback")
    func honestCopy() {
        let welcome = FirstLaunchWelcomeCopy(
            corpusPresence: ProviderCorpusPresence(providers: [.claude, .codex]))
        #expect(welcome.reads.contains("~/.claude and ~/.codex"))
        #expect(FirstLaunchWelcomeCopy.never.contains("no cloud"))
        #expect(FirstLaunchWelcomeCopy.never.contains("no telemetry"))
        #expect(FirstLaunchWelcomeCopy.never.contains("never edits"))

        let automation = TerminalAutomationPrimerCopy(terminalName: "Terminal")
        #expect(automation.reason.contains("Apple Event"))
        #expect(automation.reason.contains("TTY"))
        #expect(automation.denialFallback.contains("Don’t Allow"))
        #expect(automation.denialFallback.contains("without selecting the exact tab"))
    }
}

@Suite("Permission-flow spacing")
@MainActor
struct PermissionFlowSpacingTests {
    @Test("only one permission explanation can claim an app session")
    func oneAskPerSession() {
        let accessibilityFirst = PermissionFlowSessionGate()
        #expect(accessibilityFirst.claim(.accessibility))
        #expect(!accessibilityFirst.claim(.automation))
        #expect(accessibilityFirst.claimedBy == .accessibility)

        let automationFirst = PermissionFlowSessionGate()
        #expect(automationFirst.claim(.automation))
        #expect(!automationFirst.claim(.accessibility))
        #expect(automationFirst.claimedBy == .automation)
    }
}

@Suite("Accessibility settings refresh")
struct AccessibilitySettingsRefreshTests {
    @Test("pane appearance and app focus both re-poll live trust")
    func repollsOnFocus() {
        #expect(PermissionStatusRefreshPolicy.shouldRefresh(on: .paneAppeared))
        #expect(PermissionStatusRefreshPolicy.shouldRefresh(on: .appBecameActive))
    }
}

@Suite("No automatic startup")
struct LoginItemRegressionTests {
    @Test("the app source does not register a login item")
    func noLoginItemRegistration() throws {
        let sources = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
        let enumerator = try #require(
            FileManager.default.enumerator(
                at: sources,
                includingPropertiesForKeys: nil,
                options: [.skipsHiddenFiles]))
        let swiftFiles = enumerator.compactMap { $0 as? URL }
            .filter { $0.pathExtension == "swift" }
        let source = try swiftFiles
            .map { try String(contentsOf: $0, encoding: .utf8) }
            .joined(separator: "\n")

        #expect(!source.contains("SMAppService"))
        #expect(!source.contains("ServiceManagement"))
    }
}
