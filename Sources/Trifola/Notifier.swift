import Foundation
import AppKit
import UserNotifications
import TrifolaKit

/// The honest bridge to Anthropic's first-party Remote Control (RESEARCH_frontier
/// Angle 2: "do NOT rebuild mobile — Anthropic owns it and it's free"; bridge to it
/// instead). No `claude` Remote-Control URL scheme is publicly discoverable as of
/// this build, so this returns nil and the click handler falls back to activating
/// the app. This is the SINGLE wiring point to light the deep-link up the day a
/// scheme is confirmed — we never fake mobile/phone reach.
enum RemoteControlDeepLink {
    static func url(forSession id: String) -> URL? { nil }
}

/// Walk-Away Notify (frontier #2): the ONE allowed notification (VISION "Not a
/// nag"). Each refresh cycle AND heartbeat tick it diffs the live board's BLOCKED
/// set against what it last notified (the pure `BlockedNotifier.plan`) and, on a
/// RISING edge, posts a single macOS user notification so an operator running
/// multi-hour walk-away loops knows a session needs them without watching the window.
///
/// All the policy is in the pure Kit core; this class owns only the side effects:
/// authorization (requested once, silent on denial), posting, the click→activate
/// handoff, and the opt-in toggle persisted to the app's own dir.
@MainActor
final class BlockedNotifierService: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    /// The opt-in toggle, mirrored to disk. Published so a SwiftUI Toggle binds to it.
    @Published var enabled: Bool {
        didSet {
            guard enabled != oldValue else { return }
            prefsStore.save(NotifyPreferences(enabled: enabled))
            if enabled { requestAuthorizationIfNeeded() }
        }
    }

    /// The rising-edge tracker — the blocked ids seen last cycle. Adopted from every
    /// plan (even while disabled) so toggling on mid-block never fires for sessions
    /// that were already blocked, and so an unblock clears / a reblock re-notifies.
    private var previouslyBlocked: Set<String> = []
    private let prefsStore: NotifyPreferencesStore
    private var authRequested = false
    /// Whether we can safely touch UNUserNotificationCenter: it requires a real app
    /// bundle. Run via `swift run` / `--selfcheck` there is no bundle identifier, so
    /// every UN call is skipped (degrade silently — the dock badge carries the signal).
    private let bundled: Bool

    /// Focus a session when its notification is clicked (wired to `AppServices.inspect`).
    var onActivateSession: ((String) -> Void)?

    init(prefsStore: NotifyPreferencesStore = NotifyPreferencesStore()) {
        self.prefsStore = prefsStore
        self.bundled = Bundle.main.bundleIdentifier != nil
        self.enabled = prefsStore.load().enabled
        super.init()
        if bundled {
            UNUserNotificationCenter.current().delegate = self
            if enabled { requestAuthorizationIfNeeded() }
        }
    }

    /// One evaluation against the live board. Called from the refresh cycle AND the
    /// heartbeat ticker: a session flips RUNNING→BLOCKED at the 30s threshold on a
    /// `now` tick with NO file change, so only the ticker can catch that edge.
    func evaluate(board: AttentionBoard, signals: [String: AttentionSignals]) {
        let plan = BlockedNotifier.plan(board: board, signals: signals,
                                        previouslyBlocked: previouslyBlocked)
        // Always adopt the new tracked set — even when disabled — so the rising-edge
        // math stays honest across enable/disable and so no burst re-fires.
        previouslyBlocked = plan.newState
        guard enabled, bundled, let note = plan.notification else { return }
        post(note)
    }

    // MARK: Authorization (requested once; silent on denial/undetermined)

    private func requestAuthorizationIfNeeded() {
        guard bundled, !authRequested else { return }
        authRequested = true
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in
            // Degrade silently: the dock badge already carries the signal. Never error.
        }
    }

    // MARK: Posting

    private func post(_ note: BlockedNotification) {
        let content = UNMutableNotificationContent()
        content.title = note.title
        content.body = note.body
        content.sound = .default
        content.userInfo = ["sessionID": note.primarySessionID]
        // Group under one thread so a walk-away backlog collapses in Notification
        // Center instead of stacking N separate rows.
        content.threadIdentifier = "blocked"
        let id = "blocked-\(note.primarySessionID)-\(Int(Date().timeIntervalSince1970))"
        let req = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req) { _ in }   // ignore errors — silent
    }

    // MARK: Click → activate the app (honest bridge)

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            didReceive response: UNNotificationResponse,
                                            withCompletionHandler completionHandler: @escaping () -> Void) {
        let id = response.notification.request.content.userInfo["sessionID"] as? String
        Task { @MainActor in
            // Deep-link into a discoverable `claude` Remote Control scheme if one
            // exists; otherwise just bring the app forward. We never fake phone reach.
            if let id, let url = RemoteControlDeepLink.url(forSession: id) {
                NSWorkspace.shared.open(url)
            } else {
                NSApp.activate(ignoringOtherApps: true)
            }
            if let id { self.onActivateSession?(id) }
        }
        completionHandler()   // handled; the activation hop runs independently
    }

    /// Show the banner even while the app is frontmost — on a walk-away you may be
    /// looking at another app on top of this one.
    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
                                            willPresent notification: UNNotification,
                                            withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}

/// Headless-safe authorization probe for `--selfcheck`. Touching
/// UNUserNotificationCenter without a real app bundle throws, so this reports "n/a"
/// unless run inside the packaged .app; there it reads the live grant status.
enum NotifyAuthProbe {
    /// A one-shot box so the settings callback (delivered on UN's own queue) can hand
    /// its result back across the semaphore without a captured-var data race.
    private final class Box: @unchecked Sendable { var value = "unknown" }

    static func describe() -> String {
        guard Bundle.main.bundleIdentifier != nil else {
            return "n/a (headless — granted status is checked live in the app bundle)"
        }
        let sem = DispatchSemaphore(value: 0)
        let box = Box()
        UNUserNotificationCenter.current().getNotificationSettings { s in
            switch s.authorizationStatus {
            case .authorized:    box.value = "granted"
            case .denied:        box.value = "denied"
            case .notDetermined: box.value = "not yet requested"
            case .provisional:   box.value = "provisional"
            case .ephemeral:     box.value = "ephemeral"
            @unknown default:    box.value = "unknown"
            }
            sem.signal()
        }
        _ = sem.wait(timeout: .now() + 2)
        return box.value
    }
}
