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
        #expect(source.contains("pending.source == lineageSource"))
        #expect(source.contains("SessionLineage.resolveWithIndex"))
        #expect(!source.contains("summaries.map { (SessionLineage.key($0), $0) }"))
    }
}
