import AppKit
import Foundation
import TrifolaKit

/// AppKit adapters for the tested, typed launch flow in TrifolaKit. Nothing in
/// this layer collapses AppleScript errors to Bool or chooses an arbitrary window.
@MainActor
enum TerminalLauncher {
    @discardableResult
    static func open(
        session: SessionSummary,
        resolver: any TerminalLinkResolving = TerminalLinkResolver(),
        openMainWindow: @escaping @MainActor () -> Void,
        selectSession: @escaping @MainActor (String) -> Void,
        revealTranscript: @escaping @MainActor (String, TerminalLaunchOutcome) -> Void,
        confirmLaunch: @escaping @MainActor (String) -> Void
    ) -> Task<Void, Never> {
        let flow = TerminalLaunchFlow(
            resolver: resolver,
            exactTargeter: AppleScriptTerminalTargeter(),
            ownerActivator: RunningApplicationActivator(),
            windows: ClosureTerminalWindowAdapter(
                openMainWindow: openMainWindow,
                selectSession: selectSession,
                revealTranscript: revealTranscript
            )
        )
        return Task {
            // The outcome was previously discarded, so a successful Tier-1/2 open
            // gave no in-app signal — invisible when the terminal was already
            // frontmost. Surface a confirmation on success; failures already
            // route through revealTranscript.
            let outcome = await flow.open(
                sessionID: session.id,
                cwd: session.cwd,
                machineID: session.machineID
            )
            guard !Task.isCancelled else { return }
            if let message = outcome.successMessage {
                confirmLaunch(message)
            }
        }
    }
}

@MainActor
private final class ClosureTerminalWindowAdapter: TerminalWindowAdapting {
    private let openMainWindowAction: @MainActor () -> Void
    private let selectSessionAction: @MainActor (String) -> Void
    private let revealTranscriptAction: @MainActor (String, TerminalLaunchOutcome) -> Void

    init(openMainWindow: @escaping @MainActor () -> Void,
         selectSession: @escaping @MainActor (String) -> Void,
         revealTranscript: @escaping @MainActor (String, TerminalLaunchOutcome) -> Void) {
        self.openMainWindowAction = openMainWindow
        self.selectSessionAction = selectSession
        self.revealTranscriptAction = revealTranscript
    }

    func openMainWindow() {
        NSApp.activate(ignoringOtherApps: true)
        openMainWindowAction()
    }

    func selectSession(id: String) {
        selectSessionAction(id)
    }

    func revealTranscript(sessionID: String, outcome: TerminalLaunchOutcome) {
        revealTranscriptAction(sessionID, outcome)
    }
}

@MainActor
private final class RunningApplicationActivator: TerminalOwnerActivating {
    func activate(processID: Int32, application: TerminalApplication?) async -> Bool {
        guard !Task.isCancelled else { return false }
        let exact = NSRunningApplication(processIdentifier: pid_t(processID))
        let app = exact ?? NSWorkspace.shared.runningApplications.first {
            Self.matches($0, application: application)
        }
        guard let app else { return false }

        if app.isActive { return true }

        // AppKit only promises that these Bool results mean the activation
        // request was accepted/sent; it explicitly does not promise the target
        // became active. Verify `isActive` before telling the user it worked.
        NSApp.yieldActivation(to: app)
        if app.activate(from: NSRunningApplication.current,
                        options: [.activateAllWindows]),
           await Self.waitUntilActive(app) {
            return true
        }

        // Some terminal owners accept the cooperative request without taking
        // focus. The direct request is the bounded compatibility fallback.
        guard !Task.isCancelled else { return false }
        guard app.activate(options: [.activateAllWindows]) else { return false }
        return await Self.waitUntilActive(app)
    }

    private static func waitUntilActive(_ app: NSRunningApplication) async -> Bool {
        for _ in 0..<8 {
            guard !Task.isCancelled else { return false }
            if app.isActive { return true }
            do {
                try await Task.sleep(for: .milliseconds(50))
            } catch {
                return false
            }
        }
        return !Task.isCancelled && app.isActive
    }

    private static func matches(_ running: NSRunningApplication,
                                application: TerminalApplication?) -> Bool {
        let bundleID = running.bundleIdentifier?.lowercased()
        let appName = running.bundleURL?.deletingPathExtension()
            .lastPathComponent.lowercased()
            ?? running.localizedName?.lowercased()
        switch application {
        case .terminal?:
            return bundleID == "com.apple.terminal" || appName == "terminal"
        case .iTerm2?:
            return bundleID == "com.googlecode.iterm2" || appName == "iterm"
                || appName == "iterm2"
        case .ghostty?:
            return bundleID == "com.mitchellh.ghostty" || appName == "ghostty"
        case .other(let name)?:
            return appName == name.lowercased()
        case nil:
            return false
        }
    }
}

@MainActor
private final class AppleScriptTerminalTargeter: TerminalExactTargeting {
    func target(tty: String,
                application: TerminalApplication) -> TerminalExactTargetResult {
        let quotedTTY = Self.appleScriptQuoted(tty)
        let source: String
        switch application {
        case .terminal:
            source = """
            tell application "Terminal"
                repeat with targetWindow in windows
                    repeat with targetTab in tabs of targetWindow
                        if tty of targetTab is \(quotedTTY) then
                            set selected tab of targetWindow to targetTab
                            set index of targetWindow to 1
                            activate
                            return true
                        end if
                    end repeat
                end repeat
            end tell
            return false
            """
        case .iTerm2:
            source = """
            tell application "iTerm2"
                repeat with targetWindow in windows
                    repeat with targetTab in tabs of targetWindow
                        repeat with targetSession in sessions of targetTab
                            if tty of targetSession is \(quotedTTY) then
                                select targetTab
                                select targetSession
                                activate
                                return true
                            end if
                        end repeat
                    end repeat
                end repeat
            end tell
            return false
            """
        case .ghostty, .other:
            return .notFound
        }

        guard let script = NSAppleScript(source: source) else {
            return .failed(TerminalAutomationError(
                number: nil,
                message: "AppleScript could not be compiled",
                dictionary: ["stage": "compile"]
            ))
        }

        var dictionary: NSDictionary?
        let result = script.executeAndReturnError(&dictionary)
        if let dictionary {
            let error = Self.preservedError(dictionary)
            let lowered = error.message.lowercased()
            if error.number == -1743
                || lowered.contains("not authorized")
                || lowered.contains("not permitted")
                || lowered.contains("privilege violation") {
                return .permissionDenied(error)
            }
            return .failed(error)
        }
        return result.booleanValue ? .targeted : .notFound
    }

    private static func preservedError(_ error: NSDictionary) -> TerminalAutomationError {
        var details: [String: String] = [:]
        for (key, value) in error {
            details[String(describing: key)] = String(describing: value)
        }
        let number = (error["NSAppleScriptErrorNumber"] as? NSNumber)?.intValue
        let message = (error["NSAppleScriptErrorMessage"] as? String)
            ?? details["NSAppleScriptErrorMessage"]
            ?? "AppleScript failed"
        return TerminalAutomationError(number: number, message: message, dictionary: details)
    }

    private static func appleScriptQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
