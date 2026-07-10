import AppKit
import Foundation
import TrifolaKit

/// Performs the side-effecting half of the tiered terminal deep-link. Process
/// discovery is the tested Kit resolver; this app-side layer only targets a known
/// tty, activates a known owner, or invokes the transcript fallback.
@MainActor
enum TerminalLauncher {
    static func open(session: SessionSummary, fallback: @escaping @MainActor () -> Void) {
        Task {
            let target = await Task.detached(priority: .userInitiated) {
                TerminalLinkResolver().resolve(sessionCWD: session.cwd)
            }.value

            guard let target else { fallback(); return }
            if target.supportsExactTargeting,
               let tty = target.tty,
               exactTarget(tty: tty, application: target.ownerApplication) {
                return
            }
            if let ownerPID = target.ownerProcessID,
               let app = NSRunningApplication(processIdentifier: pid_t(ownerPID)),
               app.activate(options: [.activateAllWindows]) {
                return
            }
            fallback()
        }
    }

    private static func exactTarget(tty: String,
                                    application: TerminalApplication?) -> Bool {
        let quotedTTY = appleScriptQuoted(tty)
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
        default:
            return false
        }

        var error: NSDictionary?
        guard let script = NSAppleScript(source: source) else { return false }
        let result = script.executeAndReturnError(&error)
        return error == nil && result.booleanValue
    }

    private static func appleScriptQuoted(_ value: String) -> String {
        let escaped = value
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
        return "\"\(escaped)\""
    }
}
