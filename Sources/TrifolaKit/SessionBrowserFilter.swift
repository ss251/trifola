import Foundation

/// The two structural filters in the Sessions browser. They live in the data
/// layer so defaults and composition stay testable while the app persists each
/// toggle with `@AppStorage`.
public struct SessionBrowserFilter: Sendable, Equatable, Codable {
    public static let defaultTopLevelOnly = true
    public static let defaultLiveInTerminalOnly = false

    public var topLevelOnly: Bool
    public var liveInTerminalOnly: Bool

    public init(
        topLevelOnly: Bool = Self.defaultTopLevelOnly,
        liveInTerminalOnly: Bool = Self.defaultLiveInTerminalOnly
    ) {
        self.topLevelOnly = topLevelOnly
        self.liveInTerminalOnly = liveInTerminalOnly
    }

    public func apply(
        to sessions: [SessionSummary],
        liveTerminalSessionIDs: Set<String>
    ) -> [SessionSummary] {
        sessions.filter { session in
            (!topLevelOnly || !session.isSubagent)
                && (!liveInTerminalOnly || liveTerminalSessionIDs.contains(session.id))
        }
    }
}
