import Testing
import Foundation
@testable import TrifolaKit

// W6 wave 4 — the interaction grind: ordering hysteresis for live-updating
// pools. The displayed order changes ONLY when membership changes; a member
// that merely ticked (new transcript byte → fresher lastActivity) never moves.

@Suite("StableOrder — reshuffle hysteresis")
struct StableOrderTests {

    @Test func unchangedMembershipReturnsCurrentExactly() {
        // The compare-before-assign contract: same members (any incoming rank
        // order) → the exact current order, so callers publish nothing.
        let current = ["b", "a", "c"]
        #expect(StableOrder.merge(current: current, incoming: ["a", "b", "c"]) == current)
        #expect(StableOrder.merge(current: current, incoming: ["c", "b", "a"]) == current)
    }

    @Test func aTickNeverMovesASurvivor() {
        // "b" just got a byte and ranks first in the fresh pool — its seat holds.
        let current = ["a", "b"]
        let incoming = ["b", "a"]   // recency-sorted fresh pool
        #expect(StableOrder.merge(current: current, incoming: incoming) == ["a", "b"])
    }

    @Test func newcomersAppendInIncomingOrder() {
        let current = ["a", "b"]
        let incoming = ["d", "a", "c", "b"]   // d and c are new, d ranks first
        #expect(StableOrder.merge(current: current, incoming: incoming) == ["a", "b", "d", "c"])
    }

    @Test func departuresDropWithoutDisturbingSurvivors() {
        let current = ["a", "b", "c"]
        let incoming = ["c", "a"]             // b left the pool
        #expect(StableOrder.merge(current: current, incoming: incoming) == ["a", "c"])
    }

    @Test func emptyCurrentAdoptsIncomingOrder() {
        // First paint: the pool's own ranking (freshest first) seats everyone.
        #expect(StableOrder.merge(current: [], incoming: ["b", "a"]) == ["b", "a"])
    }

    @Test func emptyIncomingEmptiesTheOrder() {
        #expect(StableOrder.merge(current: ["a", "b"], incoming: []) == [])
    }

    @Test func routingFlagIdentityIsContentDerived() {
        // Wave 4 stable identity: a recomputed-but-unchanged flag must be the
        // SAME row to SwiftUI (UUID identity churned the whole list per refresh).
        let a = RoutingFlag(level: .warn, title: "t", detail: "d")
        let b = RoutingFlag(level: .warn, title: "t", detail: "d")
        #expect(a.id == b.id)
        #expect(a == b)
    }
}
