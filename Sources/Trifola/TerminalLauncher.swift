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
        workspacePermissionHandler: @escaping @MainActor @Sendable (String) async -> WorkspaceAccessAction,
        openMainWindow: @escaping @MainActor () -> Void,
        selectSession: @escaping @MainActor (String) -> Void,
        revealTranscript: @escaping @MainActor (String, TerminalLaunchOutcome) -> Void,
        confirmLaunch: @escaping @MainActor (String) -> Void,
        onFinished: @escaping @MainActor () -> Void = {}
    ) -> Task<Void, Never> {
        let flow = TerminalLaunchFlow(
            resolver: resolver,
            scriptTargeter: AppleScriptTerminalTargeter(),
            axTargeter: AccessibilityWorkspaceTargeter(
                permissionHandler: workspacePermissionHandler),
            ownerActivator: RunningApplicationActivator(),
            windows: ClosureTerminalWindowAdapter(
                openMainWindow: openMainWindow,
                selectSession: selectSession,
                revealTranscript: revealTranscript
            )
        )
        return Task {
            let cwd = session.cwd
            let gitBranch = await Task.detached(priority: .utility) {
                WorkspaceGitBranchReader.branch(at: cwd)
            }.value
            // The outcome was previously discarded, so a successful Tier-1/2 open
            // gave no in-app signal — invisible when the terminal was already
            // frontmost. Surface a confirmation on success; failures already
            // route through revealTranscript.
            let outcome = await flow.open(
                sessionID: session.id,
                cwd: session.cwd,
                project: session.project,
                sessionName: session.name ?? session.handle,
                gitBranch: gitBranch,
                machineID: session.machineID
            )
            // Busy state must clear on EVERY exit — success, fallback, or
            // cancellation — or the button sticks in "Opening…" forever.
            defer { onFinished() }
            guard !Task.isCancelled else {
                Self.diagnostic("result=cancelled-after-flow")
                return
            }
            if let message = outcome.successMessage {
                Self.diagnostic("result=confirmation message=\(message)")
                confirmLaunch(message)
            } else {
                Self.diagnostic("result=no-confirmation")
            }
        }
    }

    private static func diagnostic(_ message: String) {
        guard ProcessInfo.processInfo.environment[
            "TRIFOLA_AX_DIAGNOSTICS"] == "1" else { return }
        FileHandle.standardError.write(
            Data("[terminal-launch] \(message)\n".utf8))
    }
}

private enum WorkspaceGitBranchReader {
    nonisolated static func branch(at cwd: String) -> String? {
        guard !cwd.isEmpty else { return nil }
        var directory = URL(fileURLWithPath: cwd, isDirectory: true)
            .standardizedFileURL
        let fileManager = FileManager.default
        for _ in 0..<32 {
            let marker = directory.appendingPathComponent(".git")
            var isDirectory = ObjCBool(false)
            if fileManager.fileExists(
                atPath: marker.path, isDirectory: &isDirectory) {
                let head: URL?
                if isDirectory.boolValue {
                    head = marker.appendingPathComponent("HEAD")
                } else if let markerText = try? String(
                    contentsOf: marker, encoding: .utf8),
                          markerText.hasPrefix("gitdir:") {
                    let path = markerText
                        .dropFirst("gitdir:".count)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    let gitDirectory = URL(
                        fileURLWithPath: path,
                        relativeTo: directory).standardizedFileURL
                    head = gitDirectory.appendingPathComponent("HEAD")
                } else {
                    head = nil
                }
                guard let head,
                      let contents = try? String(
                          contentsOf: head, encoding: .utf8) else { return nil }
                let value = contents.trimmingCharacters(
                    in: .whitespacesAndNewlines)
                let prefix = "ref: refs/heads/"
                guard value.hasPrefix(prefix) else { return nil }
                let branch = String(value.dropFirst(prefix.count))
                return branch.isEmpty ? nil : branch
            }
            let parent = directory.deletingLastPathComponent()
            if parent.path == directory.path { break }
            directory = parent
        }
        return nil
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
        if app.activate(options: [.activateAllWindows]),
           await Self.waitUntilActive(app) {
            return true
        }

        // `NSRunningApplication.activate` can be accepted without crossing to
        // a window on another macOS Space. LaunchServices owns that transition;
        // ask it to reopen the exact running bundle without creating a second
        // instance, then verify the returned PID and actual active state.
        guard !Task.isCancelled,
              !app.isTerminated,
              let bundleURL = app.bundleURL else { return false }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        configuration.createsNewApplicationInstance = false
        configuration.promptsUserIfNeeded = false
        do {
            let activated = try await NSWorkspace.shared.openApplication(
                at: bundleURL, configuration: configuration)
            guard activated.processIdentifier == app.processIdentifier,
                  !activated.isTerminated else { return false }
            return await Self.waitUntilActive(activated)
        } catch {
            return false
        }
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
private final class AppleScriptTerminalTargeter: WorkspaceTargeting {
    func target(_ request: WorkspaceTargetRequest) async -> WorkspaceTargetResult {
        guard let tty = request.target.tty,
              let application = request.target.ownerApplication else {
            return .notFound
        }
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
            return .failed(.automation(TerminalAutomationError(
                number: nil,
                message: "AppleScript could not be compiled",
                dictionary: ["stage": "compile"]
            )))
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
                return .permissionDenied(.automation(error))
            }
            return .failed(.automation(error))
        }
        return result.booleanValue
            ? .targeted(matchedTitle: nil) : .notFound
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
