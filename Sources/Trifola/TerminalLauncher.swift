import AppKit
import Foundation
import TrifolaKit

/// AppKit adapters for the tested, typed launch flow in TrifolaKit. Nothing in
/// this layer collapses AppleScript errors to Bool or chooses an arbitrary window.
@MainActor
enum TerminalLauncher {
    static func open(
        session: SessionSummary,
        resolver: any TerminalLinkResolving = TerminalLinkResolver(),
        openMainWindow: @escaping @MainActor () -> Void,
        selectSession: @escaping @MainActor (String) -> Void,
        revealTranscript: @escaping @MainActor (String, TerminalLaunchOutcome) -> Void
    ) {
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
        Task {
            await flow.open(
                sessionID: session.id,
                cwd: session.cwd,
                machineID: session.machineID
            )
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
    func activate(processID: Int32) -> Bool {
        guard let app = NSRunningApplication(processIdentifier: pid_t(processID)) else {
            return false
        }
        return app.activate(options: [.activateAllWindows])
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
