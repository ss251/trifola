import Foundation

/// The two optional macOS trust flows Trifola can explain. A single app-session
/// gate spaces them so one user action can never cascade into stacked asks.
public enum PermissionFlowKind: Sendable, Equatable {
    case automation
    case accessibility
}

@MainActor
public final class PermissionFlowSessionGate {
    public private(set) var claimedBy: PermissionFlowKind?

    public init() {}

    /// Returns true only for the first permission explanation in this process.
    /// The claim intentionally lasts for the app session; a relaunch creates a
    /// fresh gate and makes a deferred explanation eligible again.
    @discardableResult
    public func claim(_ kind: PermissionFlowKind) -> Bool {
        guard claimedBy == nil else { return false }
        claimedBy = kind
        return true
    }
}

/// The app-side primer resolves into one of these launch-safe actions before
/// TerminalLaunchFlow is allowed to execute AppleScript.
public enum TerminalAutomationPreparation: Sendable, Equatable {
    case proceed
    case deferToActivation
    case cancelled
}

public enum FirstLaunchOnboardingPolicy {
    public static func shouldPresentWelcome(
        corpusPresence: ProviderCorpusPresence,
        hasCompletedWelcome: Bool
    ) -> Bool {
        !corpusPresence.isEmpty && !hasCompletedWelcome
    }
}

public struct FirstLaunchWelcomeCopy: Sendable, Equatable {
    public let localPaths: String

    public init(corpusPresence: ProviderCorpusPresence) {
        let providers = corpusPresence.providers.isEmpty
            ? Set(Provider.allCases) : corpusPresence.providers
        let paths = Provider.allCases.compactMap { provider -> String? in
            guard providers.contains(provider) else { return nil }
            switch provider {
            case .claude: return "~/.claude"
            case .codex: return "~/.codex"
            case .grok: return "~/.grok"
            }
        }
        localPaths = paths.count == 1
            ? paths[0]
            : paths.dropLast().joined(separator: ", ") + ", and " + paths.last!
    }

    public var reads: String {
        "Reads session files already stored under \(localPaths)."
    }

    public static let never =
        "No account, no cloud, no telemetry. Trifola never edits provider files."
}

public struct TerminalAutomationPrimerCopy: Sendable, Equatable {
    public let terminalName: String

    public init(terminalName: String) {
        let clean = terminalName.trimmingCharacters(in: .whitespacesAndNewlines)
        self.terminalName = clean.isEmpty ? "your terminal" : clean
    }

    public var reason: String {
        "Trifola sends an Apple Event to \(terminalName) only when you choose Open session, so it can select the tab whose TTY matches that session."
    }

    public var denialFallback: String {
        "If you choose Don’t Allow in the macOS prompt, Trifola will bring \(terminalName) forward without selecting the exact tab."
    }
}

/// Explicit events that may refresh the non-prompting Accessibility snapshot.
/// Settings owns the event wiring; this pure policy is the regression seam.
public enum PermissionStatusRefreshEvent: Sendable, Equatable {
    case paneAppeared
    case appBecameActive
}

public enum PermissionStatusRefreshPolicy {
    public static func shouldRefresh(on event: PermissionStatusRefreshEvent) -> Bool {
        switch event {
        case .paneAppeared, .appBecameActive: true
        }
    }
}
