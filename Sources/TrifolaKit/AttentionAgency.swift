import Foundation

// MARK: - Snooze and project mute

/// Persistent agency choices. Session snoozes expire; project mutes do not.
/// Both keys deliberately match the attention board's transport identifiers.
public struct AttentionSuppressionState: Codable, Equatable, Sendable {
    public var snoozedUntilBySessionID: [String: Date]
    public var mutedProjectKeys: Set<String>

    public init(snoozedUntilBySessionID: [String: Date] = [:],
                mutedProjectKeys: Set<String> = []) {
        self.snoozedUntilBySessionID = snoozedUntilBySessionID
        self.mutedProjectKeys = mutedProjectKeys
    }

    public func isSnoozed(sessionID: String, at now: Date) -> Bool {
        snoozedUntilBySessionID[sessionID].map { $0 > now } ?? false
    }

    public func isMuted(projectKey: String) -> Bool {
        mutedProjectKeys.contains(projectKey)
    }
}

public enum AttentionSuppressionAction: Equatable, Sendable {
    case snooze(sessionID: String, until: Date)
    case unsnooze(sessionID: String)
    case mute(projectKey: String)
    case unmute(projectKey: String)
    case expire
}

public enum AttentionSuppressionReason: Equatable, Sendable {
    case snoozed(until: Date)
    case muted(projectKey: String)
}

/// One original attention row plus the reason it is dimmed, if any. Suppressed
/// rows remain in this list; consumers must use `alertingBoard` only for badges,
/// notifications, and other interrupting surfaces.
public struct AttentionSuppressionRow: Equatable, Sendable, Identifiable {
    public let item: AttentionItem
    public let reason: AttentionSuppressionReason?

    public var id: String { item.id }
    public var isSuppressed: Bool { reason != nil }

    public init(item: AttentionItem, reason: AttentionSuppressionReason?) {
        self.item = item
        self.reason = reason
    }
}

public struct AttentionSuppressionResult: Equatable, Sendable {
    /// State after expired snoozes have been removed.
    public let state: AttentionSuppressionState
    /// Every row from the original board, including suppressed rows.
    public let rows: [AttentionSuppressionRow]
    /// The only board badges, menu-bar counts, and notifications should consume.
    public let alertingBoard: AttentionBoard

    public init(state: AttentionSuppressionState,
                rows: [AttentionSuppressionRow],
                alertingBoard: AttentionBoard) {
        self.state = state
        self.rows = rows
        self.alertingBoard = alertingBoard
    }

    public var suppressedRows: [AttentionSuppressionRow] { rows.filter(\.isSuppressed) }
    public var suppressedCount: Int { suppressedRows.count }
    public var legendSuffix: String {
        suppressedCount > 0 ? " · \(suppressedCount) snoozed" : ""
    }

    public func reason(forSessionID id: String) -> AttentionSuppressionReason? {
        rows.first { $0.id == id }?.reason
    }
}

/// Pure reducer for agency choices and their effect on an already-classified board.
public enum AttentionSuppressionReducer {
    public static func reduce(_ state: AttentionSuppressionState,
                              action: AttentionSuppressionAction,
                              now: Date) -> AttentionSuppressionState {
        var next = pruningExpired(state, now: now)
        switch action {
        case .snooze(let sessionID, let until):
            if until > now { next.snoozedUntilBySessionID[sessionID] = until }
            else { next.snoozedUntilBySessionID.removeValue(forKey: sessionID) }
        case .unsnooze(let sessionID):
            next.snoozedUntilBySessionID.removeValue(forKey: sessionID)
        case .mute(let projectKey):
            next.mutedProjectKeys.insert(projectKey)
        case .unmute(let projectKey):
            next.mutedProjectKeys.remove(projectKey)
        case .expire:
            break
        }
        return next
    }

    public static func pruningExpired(_ state: AttentionSuppressionState,
                                      now: Date) -> AttentionSuppressionState {
        var next = state
        next.snoozedUntilBySessionID = state.snoozedUntilBySessionID.filter { $0.value > now }
        return next
    }

    public static func reason(for item: AttentionItem,
                              state: AttentionSuppressionState,
                              now: Date) -> AttentionSuppressionReason? {
        if let until = state.snoozedUntilBySessionID[item.id],
           state.isSnoozed(sessionID: item.id, at: now) {
            return .snoozed(until: until)
        }
        if state.isMuted(projectKey: item.session.project) {
            return .muted(projectKey: item.session.project)
        }
        return nil
    }

    public static func apply(to board: AttentionBoard,
                             state: AttentionSuppressionState,
                             now: Date) -> AttentionSuppressionResult {
        let activeState = pruningExpired(state, now: now)
        let rows = board.items.map {
            AttentionSuppressionRow(item: $0,
                                    reason: reason(for: $0, state: activeState, now: now))
        }
        let alertingItems = rows.filter { !$0.isSuppressed }.map(\.item)
        var counts: [AttentionState: Int] = [:]
        for item in alertingItems { counts[item.state, default: 0] += 1 }
        return AttentionSuppressionResult(
            state: activeState,
            rows: rows,
            alertingBoard: AttentionBoard(items: alertingItems, counts: counts))
    }

    /// Calendar-correct start of tomorrow (DST-safe) for the context-menu action.
    public static func startOfTomorrow(after now: Date,
                                       calendar: Calendar = .current) -> Date {
        let start = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: 1, to: start)
            ?? now.addingTimeInterval(24 * 60 * 60)
    }
}

/// Codable persistence in the app's own Application Support directory.
public struct AttentionSuppressionStore: Sendable {
    public let url: URL

    public static var defaultURL: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask,
                                                 appropriateFor: nil,
                                                 create: false))
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Trifola/attention-suppression.json")
    }

    public init(url: URL = AttentionSuppressionStore.defaultURL) { self.url = url }

    /// Expired snoozes self-clear on load and are removed from disk opportunistically.
    public func load(now: Date = Date()) -> AttentionSuppressionState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let decoded = try? decoder.decode(AttentionSuppressionState.self, from: data)
        else { return AttentionSuppressionState() }
        let active = AttentionSuppressionReducer.pruningExpired(decoded, now: now)
        if active != decoded { _ = save(active) }
        return active
    }

    @discardableResult
    public func save(_ state: AttentionSuppressionState) -> Bool {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: url, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

// MARK: - The unblocked moment

public struct UnblockedAcknowledgement: Equatable, Sendable, Identifiable {
    public let sessionID: String
    public let project: String
    public let startedAt: Date
    public let expiresAt: Date

    public var id: String { sessionID }
    public var message: String { "\(project) is moving again" }

    public init(sessionID: String, project: String,
                startedAt: Date, expiresAt: Date) {
        self.sessionID = sessionID
        self.project = project
        self.startedAt = startedAt
        self.expiresAt = expiresAt
    }

    public func isActive(at now: Date) -> Bool { now < expiresAt }
}

public struct AttentionRecoveryState: Equatable, Sendable {
    public var previousStatesBySessionID: [String: AttentionState]
    public var acknowledgement: UnblockedAcknowledgement?

    public init(previousStatesBySessionID: [String: AttentionState] = [:],
                acknowledgement: UnblockedAcknowledgement? = nil) {
        self.previousStatesBySessionID = previousStatesBySessionID
        self.acknowledgement = acknowledgement
    }

    public func activeAcknowledgement(at now: Date) -> UnblockedAcknowledgement? {
        acknowledgement?.isActive(at: now) == true ? acknowledgement : nil
    }
}

/// Stateful-as-data transition reducer. Call once per attention-board refresh.
/// A blocked→running edge replaces the current acknowledgment; no queue exists.
public enum AttentionRecoveryReducer {
    public static let defaultDuration: TimeInterval = 10

    public static func reduce(_ state: AttentionRecoveryState,
                              board: AttentionBoard,
                              now: Date,
                              duration: TimeInterval = defaultDuration) -> AttentionRecoveryState {
        let current = Dictionary(uniqueKeysWithValues: board.items.map { ($0.id, $0.state) })
        var acknowledgement = state.activeAcknowledgement(at: now)

        // The board already sorts equal-state rows freshest first. If more than
        // one edge lands in a single refresh, the freshest transition wins.
        if let recovered = board.items.first(where: {
            $0.state == .running && state.previousStatesBySessionID[$0.id] == .blocked
        }) {
            let lifetime = max(0, duration)
            acknowledgement = UnblockedAcknowledgement(
                sessionID: recovered.id,
                project: recovered.session.project,
                startedAt: now,
                expiresAt: now.addingTimeInterval(lifetime))
        }

        return AttentionRecoveryState(previousStatesBySessionID: current,
                                      acknowledgement: acknowledgement)
    }
}
