import Foundation

// MARK: - Shared fleet summary language

/// The shared sentence fragments behind the menu-bar fleet line and the Overview
/// verdict. Keeping the count ordering here prevents those two high-signal
/// surfaces from quietly developing different definitions of "the fleet".
public enum FleetSummaryReducer {
    /// Non-zero counts in the menu-bar's canonical priority order.
    public static func countParts(board: AttentionBoard) -> [String] {
        var parts: [String] = []
        if board.blockedCount > 0 { parts.append("\(board.blockedCount) blocked") }
        if board.waitingCount > 0 { parts.append("\(board.waitingCount) waiting") }
        if board.runningCount > 0 { parts.append("\(board.runningCount) running") }
        if board.idleCount > 0 { parts.append("\(board.idleCount) idle") }
        return parts
    }

    /// "2 blocked · 1 waiting · 3 running · $73 today". This is the existing
    /// menu-bar contract, extracted so verdict copy cannot duplicate its reducer.
    public static func fleetLine(board: AttentionBoard, todayCost: Double) -> String {
        let parts = countParts(board: board)
        let counts = parts.isEmpty ? "fleet is quiet" : parts.joined(separator: " · ")
        return counts + String(format: " · $%.0f today", todayCost)
    }
}

/// Today's burn relative to the mean of the seven complete days before today.
public enum VerdictPace: Equatable, Sendable {
    case normal
    case higher(percent: Int)
    case lower(percent: Int)
    /// A non-zero current day cannot be compared honestly with a zero/missing
    /// baseline. Zero today against zero history is simply calm/normal.
    case unavailable

    public var phrase: String {
        switch self {
        case .normal: return "pace normal"
        case .higher(let percent): return "pace ↑ \(percent)% vs 7-day"
        case .lower(let percent): return "pace ↓ \(percent)% vs 7-day"
        case .unavailable: return "pace has no baseline"
        }
    }
}

/// The Overview's one-sentence answer to "am I OK?". Inputs are outputs of the
/// existing attention and burn reducers: `AttentionBoard`, `BurnGovernor.today.cost`,
/// and `BurnGovernor.dailyRunRate` (the seven-complete-day mean by default).
public enum VerdictSentenceBuilder {
    public static let normalTolerance = 0.25

    public static func pace(todayCost: Double,
                            sevenCompleteDayMean: Double) -> VerdictPace {
        let today = max(0, todayCost)
        guard sevenCompleteDayMean > 0 else {
            return today == 0 ? .normal : .unavailable
        }

        let delta = (today - sevenCompleteDayMean) / sevenCompleteDayMean
        if abs(delta) <= normalTolerance { return .normal }
        let percent = Int((abs(delta) * 100).rounded())
        return delta > 0 ? .higher(percent: percent) : .lower(percent: percent)
    }

    public static func sentence(board: AttentionBoard,
                                todayCost: Double,
                                sevenCompleteDayMean: Double) -> String {
        var parts = [needsYouClause(board: board)]

        // When somebody needs the human, the verdict leads with that one action.
        // When nobody does, preserve the menu-bar's running/quiet distinction.
        if board.needsAttention.isEmpty {
            if board.runningCount > 0 {
                parts.append("\(board.runningCount) running calmly")
            } else {
                parts.append("fleet is quiet")
            }
        }

        parts.append(String(format: "$%.0f today", max(0, todayCost)))
        return parts.joined(separator: " · ")
            + " — " + pace(todayCost: todayCost,
                            sevenCompleteDayMean: sevenCompleteDayMean).phrase
    }

    private static func needsYouClause(board: AttentionBoard) -> String {
        guard let first = board.needsAttention.first else { return "Nothing needs you" }
        let state = first.state.label.lowercased()
        let age = fmtAgeShort(max(0, first.age))
        let extra = board.needsAttention.count - 1
        if extra == 0 {
            return "\(first.session.project) needs you (\(state) \(age))"
        }
        return "\(first.session.project) + \(extra) more need you (\(state) \(age))"
    }
}
