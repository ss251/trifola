import Combine
import Foundation
import TrifolaKit

/// App-side owner for persistent snooze/mute choices and the transient recovery
/// acknowledgement. All policy remains in TrifolaKit reducers.
@MainActor
final class AgencyController: ObservableObject {
    @Published private(set) var suppressionState: AttentionSuppressionState
    @Published private(set) var recoveryState = AttentionRecoveryState()
    @Published private(set) var persistenceError: String?

    private let store: AttentionSuppressionStore
    private var pendingSuppressionState: AttentionSuppressionState?

    var persistenceLocation: URL { store.url.deletingLastPathComponent() }

    init(store: AttentionSuppressionStore = AttentionSuppressionStore()) {
        self.store = store
        self.suppressionState = store.load()
    }

    func result(for board: AttentionBoard, now: Date) -> AttentionSuppressionResult {
        AttentionSuppressionReducer.apply(to: board, state: suppressionState, now: now)
    }

    /// Called on the existing attention evaluation cadence. Expiry and recovery
    /// therefore require no extra timer or observation path.
    func observe(board: AttentionBoard, now: Date) {
        let applied = result(for: board, now: now)
        if applied.state != suppressionState {
            persist(applied.state, operation: "Update expired attention choices")
        }
        let nextRecovery = AttentionRecoveryReducer.reduce(recoveryState,
                                                           board: board,
                                                           now: now)
        if nextRecovery != recoveryState { recoveryState = nextRecovery }
    }

    func perform(_ action: AttentionSuppressionAction, now: Date = Date()) {
        let next = AttentionSuppressionReducer.reduce(suppressionState,
                                                      action: action,
                                                      now: now)
        guard next != suppressionState else { return }
        persist(next, operation: "Save attention choice")
    }

    func reason(for session: SessionSummary, now: Date) -> AttentionSuppressionReason? {
        if let until = suppressionState.snoozedUntilBySessionID[session.id], until > now {
            return .snoozed(until: until)
        }
        if suppressionState.mutedProjectKeys.contains(session.project) {
            return .muted(projectKey: session.project)
        }
        return nil
    }

    func snooze(_ session: SessionSummary, until: Date, now: Date = Date()) {
        perform(.snooze(sessionID: session.id, until: until), now: now)
    }

    func snoozeOneHour(_ session: SessionSummary, now: Date = Date()) {
        snooze(session, until: now.addingTimeInterval(60 * 60), now: now)
    }

    func retryPersistence() {
        guard let pendingSuppressionState else { return }
        persist(pendingSuppressionState, operation: "Retry attention choice")
    }

    private func persist(_ state: AttentionSuppressionState, operation: String) {
        guard store.save(state) else {
            pendingSuppressionState = state
            persistenceError = "\(operation) failed at \(store.url.path). The previous choice remains active."
            return
        }
        suppressionState = state
        pendingSuppressionState = nil
        persistenceError = nil
    }
}
