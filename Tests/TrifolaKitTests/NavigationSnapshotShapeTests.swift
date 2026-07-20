import Foundation
import Testing

@Suite("Navigation snapshot value-shape contracts")
struct NavigationSnapshotShapeTests {
    private var snapshotSource: String {
        get throws {
            let root = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            return try String(contentsOf: root.appendingPathComponent(
                "Sources/Trifola/NavigationSnapshotStore.swift"),
                encoding: .utf8)
        }
    }

    @Test("Sessions projection carries bounded display values, never summary arrays")
    func sessionsSnapshotHasNoSummaryArray() throws {
        let source = try snapshotSource
        let start = try #require(source.range(of: "struct SessionProjectionSnapshot"))
        let tail = source[start.lowerBound...]
        let end = try #require(tail.range(of: "\n}"))
        let declaration = String(tail[..<end.upperBound])

        #expect(declaration.contains("[SessionLineageDisplayRow]"))
        #expect(!declaration.contains("[SessionSummary]"))
        #expect(source.contains("rows = Array(rows.prefix(400))"))
        #expect(source.contains("Task.detached(priority: .userInitiated)"))
    }

    @Test("Lineage memo follows corpus revisions and shares in-flight work")
    func lineageMemoHasStableOwnership() throws {
        let source = try snapshotSource

        #expect(source.contains("sessionsRevision: inputs.sessionsRevision"))
        #expect(source.contains("evidenceRevision: inputs.lineageEvidenceRevision"))
        #expect(source.contains("SessionLineage.resolveWithIndex"))
        #expect(!source.contains("summaries.map { (SessionLineage.key($0), $0) }"))
    }

    @Test("A snapshot never starves behind lineage: stale forest serves, resolves are never cancelled for a newer source")
    func lineageIsStaleWhileRevalidate() throws {
        let source = try snapshotSource

        // Any in-flight resolve is reused — never keyed to the current source
        // and never cancelled when a scan batch bumps the revision (the
        // cancel-restart pattern starved the first snapshot for a whole scan).
        #expect(source.contains("if let pending = lineageInFlight {"))
        #expect(!source.contains("pending.task.cancel()"))
        // The newest completed forest paints immediately…
        #expect(source.contains("lastLineageResolution"))
        #expect(source.contains("} else if let staleResolution {"))
        // …and a completed resolve re-schedules the silent swap.
        #expect(source.contains("func lineageResolveCompleted"))
    }
}
