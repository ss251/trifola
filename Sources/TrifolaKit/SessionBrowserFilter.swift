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

/// Title/path matching for the Sessions browser. Kept in the data layer so the
/// coalesced off-main projection and its 7k-session performance budget share
/// one implementation.
public enum SessionBrowserSearch {
    public static func titlePathMatches(
        _ sessions: [SessionSummary],
        query: String
    ) -> [SessionSummary] {
        guard !query.isEmpty else { return sessions }
        let needle = query.lowercased()
        return sessions.filter {
            $0.project.lowercased().contains(needle)
                || $0.displayTitle.lowercased().contains(needle)
                || $0.cwd.lowercased().contains(needle)
                || $0.id.lowercased().hasPrefix(needle)
        }
    }
}
