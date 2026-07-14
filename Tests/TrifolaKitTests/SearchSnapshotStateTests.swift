import Testing
@testable import TrifolaKit

@Suite("Search snapshot stale-while-revalidate state")
struct SearchSnapshotStateTests {
    @Test("pending search preserves the previous displayed results")
    func pendingPreservesPreviousResults() {
        var state = SearchSnapshotState<[String]>()
        let first = state.begin(query: "key")
        let didPublishFirst = state.publish(
            ["session-a", "session-b"], for: first)
        #expect(didPublishFirst)

        _ = state.begin(query: "keychain")

        #expect(state.isPending)
        #expect(state.requestedQuery == "keychain")
        #expect(state.displayedQuery == "key")
        #expect(state.displayed == ["session-a", "session-b"])
    }

    @Test("a stale query can never replace the displayed snapshot")
    func staleQueryNeverPublishes() {
        var state = SearchSnapshotState<[String]>()
        let seed = state.begin(query: "key")
        let didPublishSeed = state.publish(["seed-result"], for: seed)
        #expect(didPublishSeed)

        let stale = state.begin(query: "keych")
        let current = state.begin(query: "keychain")

        let didPublishStale = state.publish(["stale-result"], for: stale)
        #expect(!didPublishStale)
        #expect(state.isPending)
        #expect(state.displayed == ["seed-result"])
        let didPublishCurrent = state.publish(["current-result"], for: current)
        #expect(didPublishCurrent)
        #expect(!state.isPending)
        #expect(state.displayedQuery == "keychain")
        #expect(state.displayed == ["current-result"])
    }
}
