import Foundation

// MARK: - Stable ordering with hysteresis (W6 wave 4 — the interaction grind)
//
// Live-updating lists that re-sort on every refresh tick read as jank: a tile
// jumps to the top on every transcript byte ("the transition when the windows
// reshuffle is janky"). The Fleet Board solved this with the ArrivalLedger —
// stable seats, live presence. `StableOrder` is the same doctrine as a pure
// function for view-local pools (Live Now tiles): survivors keep their seats,
// newcomers append in incoming order, departures drop. The ORDER only changes
// when membership changes — never because an existing member ticked.

public enum StableOrder {
    /// Merge a freshly computed pool into the currently displayed order.
    ///
    /// - `current`: the id order the user is looking at right now.
    /// - `incoming`: the newly computed pool (its order ranks NEWCOMERS only).
    ///
    /// Returns `current` filtered to survivors, then newcomers appended in
    /// `incoming` order. When membership is unchanged the result equals
    /// `current` exactly — callers compare-before-assign so SwiftUI sees no
    /// change and nothing moves.
    public static func merge(current: [String], incoming: [String]) -> [String] {
        let incomingSet = Set(incoming)
        var out = current.filter { incomingSet.contains($0) }
        let surviving = Set(out)
        for id in incoming where !surviving.contains(id) {
            out.append(id)
        }
        return out
    }
}
