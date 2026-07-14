/// A small stale-while-revalidate state machine for query-backed snapshots.
/// Beginning a request never clears the displayed value; only the newest
/// generation may replace it. The UI can therefore keep painting useful rows
/// while a coalesced search runs off the main actor.
public struct SearchSnapshotRequest: Sendable, Equatable {
    public let query: String
    public let generation: Int

    fileprivate init(query: String, generation: Int) {
        self.query = query
        self.generation = generation
    }
}

public struct SearchSnapshotState<Snapshot: Sendable & Equatable>:
    Sendable, Equatable {
    public private(set) var displayed: Snapshot?
    public private(set) var displayedQuery: String?
    public private(set) var requestedQuery: String
    public private(set) var generation: Int
    public private(set) var isPending: Bool

    public init(
        displayed: Snapshot? = nil,
        displayedQuery: String? = nil
    ) {
        self.displayed = displayed
        self.displayedQuery = displayedQuery
        requestedQuery = displayedQuery ?? ""
        generation = 0
        isPending = false
    }

    @discardableResult
    public mutating func begin(query: String) -> SearchSnapshotRequest {
        generation += 1
        requestedQuery = query
        isPending = true
        return SearchSnapshotRequest(query: query, generation: generation)
    }

    /// Returns `false` without changing visible state when a superseded request
    /// completes after the current one.
    @discardableResult
    public mutating func publish(
        _ snapshot: Snapshot,
        for request: SearchSnapshotRequest
    ) -> Bool {
        guard isPending,
              request.generation == generation,
              request.query == requestedQuery else { return false }
        displayed = snapshot
        displayedQuery = request.query
        isPending = false
        return true
    }
}
