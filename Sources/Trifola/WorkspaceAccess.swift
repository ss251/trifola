import AppKit
import ApplicationServices
import Combine
import Foundation
import TrifolaKit

/// The only user decisions exposed by the at-value Accessibility explainer.
/// The transport adapter owns what happens next; this coordinator only presents
/// the trust boundary and, for `.settingsOpened`, opens the correct System
/// Settings pane without asking macOS to prompt on Trifola's behalf.
enum WorkspaceAccessAction: Sendable, Equatable {
    case retryTargeting
    case settingsOpened
    case settingsOpenFailed
    case notNow
    case deferred
    case cancelled
}

enum WorkspaceAccessStatus: Sendable, Equatable {
    case unknown
    case granted
    case notGranted

    var label: String {
        switch self {
        case .unknown: "Checking…"
        case .granted: "Granted"
        case .notGranted: "Not granted"
        }
    }
}

enum WorkspaceAccessCopy {
    static let title = "Jump to the exact terminal workspace?"
    static let body = "Trifola uses Accessibility only when you choose Open session. It reads window and tab titles in the terminal app that owns this session and selects a workspace only when the match is confident. It does nothing else with Accessibility."
    static let openSettingsButton = "Open Accessibility Settings"
    static let notNowButton = "Not Now"

    static let settingsExplanation = "Optional. Trifola reads window and tab titles only in the terminal app that owns a session, then selects one confident match. It does nothing else with Accessibility."
}

/// Low-frequency, event-driven Accessibility state and one-at-a-time explainer
/// presentation. Construction performs no TCC access. Status is refreshed only
/// when Settings appears / the app returns from Settings, or when a workspace
/// attempt reaches this at-value boundary. There is deliberately no timer and no
/// auto-prompting trust query.
@MainActor
final class WorkspaceAccessCoordinator: ObservableObject {
    struct Prompt: Identifiable, Equatable {
        let id: UUID
        let terminalName: String
    }

    @Published private(set) var status: WorkspaceAccessStatus = .unknown
    @Published private(set) var pendingPrompt: Prompt?

    private let trustCheck: @MainActor () -> Bool
    private let settingsOpener: @MainActor () -> Bool
    private let sessionGate: PermissionFlowSessionGate
    private var continuation: CheckedContinuation<WorkspaceAccessAction, Never>?

    init(
        sessionGate: PermissionFlowSessionGate = PermissionFlowSessionGate(),
        trustCheck: @escaping @MainActor () -> Bool = { AXIsProcessTrusted() },
        settingsOpener: @escaping @MainActor () -> Bool = {
            guard let url = URL(string:
                "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")
            else { return false }
            return NSWorkspace.shared.open(url)
        }
    ) {
        self.sessionGate = sessionGate
        self.trustCheck = trustCheck
        self.settingsOpener = settingsOpener
    }

    /// A cheap, non-prompting snapshot. Callers invoke this on explicit UI or
    /// app-activation events; it never schedules another check.
    func refreshStatus() {
        status = trustCheck() ? .granted : .notGranted
    }

    @discardableResult
    func openAccessibilitySettings() -> Bool {
        settingsOpener()
    }

    /// Called only after the launch ladder has established that generic AX
    /// targeting would add value but macOS access is absent. A prior Not Now is
    /// respected without re-presenting the explainer. The fresh trust check also
    /// closes the small race where access changed between AX discovery and UI.
    func requestExplanation(
        terminalName: String,
        hasSeenExplainer: Bool
    ) async -> WorkspaceAccessAction {
        refreshStatus()
        guard !Task.isCancelled else { return .cancelled }
        if status == .granted { return .retryTargeting }
        if hasSeenExplainer { return .notNow }
        guard sessionGate.claim(.accessibility) else { return .deferred }

        cancelPendingPrompt()
        let requestID = UUID()
        let cleanName = terminalName.trimmingCharacters(in: .whitespacesAndNewlines)
        return await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                guard !Task.isCancelled else {
                    continuation.resume(returning: .cancelled)
                    return
                }
                self.continuation = continuation
                self.pendingPrompt = Prompt(
                    id: requestID,
                    terminalName: cleanName.isEmpty ? "your terminal" : cleanName)
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                self?.cancelPendingPrompt(id: requestID)
            }
        }
    }

    /// Resolves the modal exactly once. Opening System Settings is the user's
    /// explicit primary action, not an AX/TCC prompt and not a permission poll.
    func resolvePrompt(with action: WorkspaceAccessAction) {
        guard continuation != nil else { return }
        let resolvedAction: WorkspaceAccessAction
        if action == .settingsOpened {
            resolvedAction = openAccessibilitySettings()
                ? .settingsOpened : .settingsOpenFailed
        } else {
            resolvedAction = action
        }
        let continuation = self.continuation
        self.continuation = nil
        pendingPrompt = nil
        continuation?.resume(returning: resolvedAction)
    }

    func cancelPendingPrompt() {
        cancelPendingPrompt(id: nil)
    }

    private func cancelPendingPrompt(id: UUID?) {
        if let id, pendingPrompt?.id != id { return }
        let continuation = self.continuation
        self.continuation = nil
        pendingPrompt = nil
        continuation?.resume(returning: .cancelled)
    }
}
