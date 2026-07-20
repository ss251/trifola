import Foundation
import Testing
@testable import TrifolaKit

@Suite("Session lineage resolver")
struct SessionLineageTests {
    private let instant = Date(timeIntervalSince1970: 1_750_000_000)

    private func session(
        _ id: String,
        provider: Provider = .claude,
        cwd: String = "/Users/dev/Developer/repo",
        filePath: String? = nil,
        invocations: [SubagentInvocation] = [],
        lastOffset: TimeInterval = 600
    ) -> SessionSummary {
        SessionSummary(
            id: id,
            provider: provider,
            project: "repo",
            cwd: cwd,
            model: provider == .codex ? "gpt-5.4" : "claude-sonnet-4-6",
            lastActivity: instant.addingTimeInterval(lastOffset),
            messageCount: 2,
            usage: SessionUsage(inputTokens: 1_000, outputTokens: 100,
                                cacheCreateTokens: 0, cacheReadTokens: 0),
            contextWeight: 1_000,
            filePath: filePath ?? "/Users/dev/.sessions/\(id).jsonl",
            name: id,
            subagentInvocations: invocations)
    }

    private func node(_ id: String, in forest: SessionLineageForest) -> LineageNode? {
        forest.allNodes.first { $0.session.id == id }
    }

    @Test("resolves every deterministic edge kind and keeps metadata-only children")
    func deterministicEdges() throws {
        let claudeParentPath = "/Users/dev/.claude/projects/repo/claude-parent.jsonl"
        let claudeParent = session(
            "claude-parent", filePath: claudeParentPath,
            invocations: [SubagentInvocation(agentID: "worker")])
        let subagent = session(
            "claude-parent/worker",
            filePath: "/Users/dev/.claude/projects/repo/claude-parent/subagents/agent-worker.jsonl")
        let codexParent = session("codex-parent", provider: .codex)
        let codexSpawn = session("codex-spawn", provider: .codex)
        let codexFork = session("codex-fork", provider: .codex)
        let evidence = SessionLineageEvidence(
            codexThreads: [
                CodexThreadMetadata(threadID: "codex-parent", startedAt: instant),
                CodexThreadMetadata(threadID: "codex-spawn",
                                    parentThreadID: "codex-parent",
                                    sourceDepth: 1, agentNickname: "Scout",
                                    startedAt: instant.addingTimeInterval(60)),
                CodexThreadMetadata(threadID: "codex-fork",
                                    forkedFromID: "codex-parent",
                                    startedAt: instant.addingTimeInterval(120)),
            ],
            remoteTasks: [RemoteAgentSidecar(
                parentSessionID: "claude-parent",
                taskID: "remote-task",
                remoteTaskType: "cloud",
                sessionID: "session_remote",
                title: "Remote review",
                spawnedAt: instant.addingTimeInterval(30))],
            importRecords: [CodexImportRecord(
                sourcePath: claudeParentPath,
                contentSHA256: "abc",
                importedThreadID: "imported-thread")])

        let forest = SessionLineage.resolve(
            sessions: [claudeParent, subagent, codexParent, codexSpawn, codexFork],
            evidence: evidence)

        #expect(node("claude-parent/worker", in: forest)?.edgeKind == .subagent)
        #expect(node("session_remote", in: forest)?.edgeKind == .remoteTask)
        #expect(node("session_remote", in: forest)?.session.isMetadataOnly == true)
        #expect(node("session_remote", in: forest)?.session.duration == nil)
        #expect(node("codex-spawn", in: forest)?.edgeKind == .codexSpawn)
        #expect(node("codex-spawn", in: forest)?.edgeDetail == "Scout")
        #expect(node("codex-spawn", in: forest)?.session.duration == 540)
        #expect(node("codex-fork", in: forest)?.edgeKind == .codexFork)
        #expect(node("imported-thread", in: forest)?.edgeKind == .importBridge)
        #expect(node("imported-thread", in: forest)?.session.isMetadataOnly == true)
        #expect(forest.transcriptSessionCount == 5)
        #expect(forest.metadataOnlyCount == 2)
    }

    @Test("the only inferred edge is labeled heuristic and can be hidden")
    func heuristicEdge() throws {
        let parent = session("claude-driver", lastOffset: 120)
        let child = session("codex-exec", provider: .codex, lastOffset: 180)
        let evidence = SessionLineageEvidence(codexThreads: [
            CodexThreadMetadata(
                threadID: "codex-exec",
                originator: "codex_exec",
                entrypoint: "sdk-cli",
                startedAt: instant.addingTimeInterval(60)),
        ])

        let shown = SessionLineage.resolve(
            sessions: [parent, child], evidence: evidence,
            includeHeuristicLinks: true)
        let linked = try #require(node("codex-exec", in: shown))
        #expect(linked.edgeKind == .orchestrated)
        #expect(linked.confidence == .heuristic)
        #expect(linked.edgeDetail == "linked by workspace + timing")
        #expect(shown.roots.count == 1)

        let hidden = SessionLineage.resolve(
            sessions: [parent, child], evidence: evidence,
            includeHeuristicLinks: false)
        #expect(hidden.roots.count == 2)
        #expect(node("codex-exec", in: hidden)?.edgeKind == nil)
    }

    @Test("cycles break safely, orphans remain roots, and visual depth flattens after two")
    func cyclesOrphansAndDepth() throws {
        let ids = ["a", "b", "c", "d", "e", "orphan"]
        let sessions = ids.map { session($0, provider: .codex) }
        let evidence = SessionLineageEvidence(codexThreads: [
            CodexThreadMetadata(threadID: "a", parentThreadID: "b"),
            CodexThreadMetadata(threadID: "b", parentThreadID: "a"),
            CodexThreadMetadata(threadID: "c", parentThreadID: "a"),
            CodexThreadMetadata(threadID: "d", parentThreadID: "c"),
            CodexThreadMetadata(threadID: "e", parentThreadID: "d"),
            CodexThreadMetadata(threadID: "orphan", parentThreadID: "gone"),
        ])

        let forest = SessionLineage.resolve(sessions: sessions, evidence: evidence)
        #expect(Set(forest.allNodes.map(\.session.id)) == Set(ids))
        #expect(forest.allNodes.count == ids.count)
        let cycleRoot = try #require(forest.roots.first {
            $0.session.id == "a" || $0.session.id == "b"
        })
        #expect(cycleRoot.parentMissingNote?.contains("cycle") == true)
        let deep = try #require(node("e", in: forest))
        #expect(deep.spawnDepth > 2)
        #expect(deep.displayDepth == 2)
        let orphan = try #require(node("orphan", in: forest))
        #expect(orphan.spawnDepth == 0)
        #expect(orphan.parentMissingNote == "Parent missing: gone")
    }

    @Test("duplicate transport ids remain distinct files in the forest")
    func duplicateIDsNeverChangeSessionCount() {
        let first = session(
            "resumed-id", filePath: "/Users/dev/.sessions/first.jsonl")
        let second = session(
            "resumed-id", filePath: "/Users/dev/.sessions/second.jsonl")
        let forest = SessionLineage.resolve(sessions: [first, second])

        #expect(forest.transcriptSessionCount == 2)
        #expect(forest.allNodes.count == 2)
        #expect(forest.roots.count == 2)
        #expect(Set(forest.roots.map(\.id)).count == 2)
    }

    @Test("indexed resolution reuses each session's stable key")
    func indexedResolutionCarriesStableKeys() throws {
        let first = session(
            "resumed-id", filePath: "/Users/dev/.sessions/first.jsonl")
        let second = session(
            "resumed-id", filePath: "/Users/dev/.sessions/second.jsonl")
        let resolution = SessionLineage.resolveWithIndex(
            sessions: [first, second])

        #expect(resolution.key(for: first) == SessionLineage.key(first))
        #expect(resolution.key(for: second) == SessionLineage.key(second))
        #expect(resolution.forest.allNodes.count == 2)
        #expect(resolution.forest == SessionLineage.resolve(
            sessions: [first, second]))
    }

    @Test("lineage paths normalize lexically")
    func lineagePathsNormalizeLexically() {
        #expect(SessionLineage.standardizedPath("/repo/work/.") == "/repo/work")
        #expect(SessionLineage.standardizedPath("/repo/work/..") == "/repo")
        #expect(SessionLineage.standardizedPath("/repo//a/../work/") == "/repo/work")
        #expect(SessionLineage.standardizedPath("/../../../../..") == "/")
        #expect(SessionLineage.standardizedPath("~/sessions")
                == NSHomeDirectory() + "/sessions")
    }

    @Test("cancellable indexed resolution stops canceled work")
    func indexedResolutionCooperatesWithCancellation() async {
        let task = Task {
            try SessionLineage.resolveWithIndexCancellable(
                sessions: (0..<1_000).map { session("session-\($0)") })
        }
        task.cancel()

        do {
            _ = try await task.value
            Issue.record("Expected lineage resolution cancellation")
        } catch is CancellationError {
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }

    @Test("a heuristic link is refused when the would-be parent started after the child")
    func heuristicRespectsParentStart() throws {
        let parent = session("late-driver", lastOffset: 2_400)
        let child = session("codex-exec", provider: .codex, lastOffset: 180)
        let evidence = SessionLineageEvidence(
            codexThreads: [CodexThreadMetadata(
                threadID: "codex-exec",
                originator: "codex_exec",
                entrypoint: "sdk-cli",
                startedAt: instant.addingTimeInterval(60))],
            sessionStartedAt: [
                SessionLineage.key(parent): instant.addingTimeInterval(61),
            ])

        let forest = SessionLineage.resolve(
            sessions: [parent, child], evidence: evidence,
            includeHeuristicLinks: true)
        #expect(forest.roots.count == 2)
        #expect(node("codex-exec", in: forest)?.edgeKind == nil)

        // An unknown parent start keeps the previous behavior (window on
        // lastActivity alone), so real corpora without start records still link.
        let unknownStart = SessionLineage.resolve(
            sessions: [parent, child],
            evidence: SessionLineageEvidence(codexThreads: [CodexThreadMetadata(
                threadID: "codex-exec",
                originator: "codex_exec",
                entrypoint: "sdk-cli",
                startedAt: instant.addingTimeInterval(60))]),
            includeHeuristicLinks: true)
        #expect(node("codex-exec", in: unknownStart)?.edgeKind == .orchestrated)
    }

    @Test("a subagent file whose parent has no matching spawn record stays detached but explains itself")
    func unverifiedSubagentExplainsItself() throws {
        let parent = session(
            "claude-parent",
            filePath: "/Users/dev/.claude/projects/repo/claude-parent.jsonl",
            invocations: [SubagentInvocation(agentID: "someone-else")])
        let child = session(
            "claude-parent/agent-inner",
            filePath: "/Users/dev/.claude/projects/repo/claude-parent/subagents/agent-agent-inner.jsonl")

        let forest = SessionLineage.resolve(sessions: [parent, child])
        let detached = try #require(node("claude-parent/agent-inner", in: forest))
        #expect(detached.spawnDepth == 0)
        #expect(detached.parentMissingNote?.contains("no matching spawn record") == true)
        #expect(detached.edgeDetail == nil)

        // The anchored prefix strip derives "agent-inner" (not "inner"), so a
        // matching parent record verifies and attaches the child normally.
        let verifiedParent = session(
            "claude-parent",
            filePath: "/Users/dev/.claude/projects/repo/claude-parent.jsonl",
            invocations: [SubagentInvocation(agentID: "agent-inner")])
        let verified = SessionLineage.resolve(sessions: [verifiedParent, child])
        #expect(node("claude-parent/agent-inner", in: verified)?.edgeKind == .subagent)
        #expect(node("claude-parent/agent-inner", in: verified)?.spawnDepth == 1)
    }

    @Test("roots never carry an edge kind or confidence")
    func rootsCarryNoEdge() throws {
        let orphanEvidence = SessionLineageEvidence(codexThreads: [
            CodexThreadMetadata(threadID: "orphan", parentThreadID: "gone"),
        ])
        let forest = SessionLineage.resolve(
            sessions: [session("orphan", provider: .codex)],
            evidence: orphanEvidence)
        let orphan = try #require(node("orphan", in: forest))
        #expect(orphan.spawnDepth == 0)
        #expect(orphan.edgeKind == nil)
        #expect(orphan.confidence == nil)
        #expect(orphan.parentMissingNote == "Parent missing: gone")
    }
}

@Suite("Lineage evidence parsing")
struct SessionLineageParsingTests {
    @Test("Codex first session_meta surfaces thread_spawn, fork, and execution fields")
    func codexMetadata() throws {
        let json = #"{"timestamp":"2026-07-20T10:00:00Z","type":"session_meta","payload":{"id":"child","cwd":"/Users/dev/Developer/repo","forked_from_id":"fork-parent","originator":"codex_exec","entrypoint":"sdk-cli","source":{"subagent":{"thread_spawn":{"parent_thread_id":"spawn-parent","depth":3,"agent_nickname":"Scout"}}}}}"#
        var accumulator = CodexRolloutAccumulator(defaultID: "fallback")
        accumulator.ingest(Data((json + "\n").utf8))
        let metadata = accumulator.threadMetadata

        #expect(metadata.threadID == "child")
        #expect(metadata.parentThreadID == "spawn-parent")
        #expect(metadata.forkedFromID == "fork-parent")
        #expect(metadata.sourceDepth == 3)
        #expect(metadata.agentNickname == "Scout")
        #expect(metadata.originator == "codex_exec")
        #expect(metadata.entrypoint == "sdk-cli")
        #expect(metadata.startedAt != nil)
        #expect(metadata.isNonInteractive)
    }

    @Test("remote sidecar reader rejects noise and parses metadata")
    func remoteSidecars() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("trifola-lineage-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let directory = root.appendingPathComponent(
            "project/parent-id/remote-agents", isDirectory: true)
        try FileManager.default.createDirectory(
            at: directory, withIntermediateDirectories: true)
        let valid = directory.appendingPathComponent("remote-agent-task.meta.json")
        try #"{"taskId":"task-1","remoteTaskType":"cloud","sessionId":"session_1","title":"Ship it","spawnedAt":"2026-07-20T10:00:00Z","isUltraplan":true}"#
            .write(to: valid, atomically: true, encoding: .utf8)
        try #"{"taskId":"ignored"}"#.write(
            to: directory.appendingPathComponent("other.json"),
            atomically: true, encoding: .utf8)

        let records = SessionLineageEvidenceReader.remoteAgentSidecars(beneath: root)
        let record = try #require(records.only)
        #expect(record.parentSessionID == "parent-id")
        #expect(record.taskID == "task-1")
        #expect(record.sessionID == "session_1")
        #expect(record.title == "Ship it")
        #expect(record.isUltraplan)
        #expect(record.spawnedAt != nil)
    }
}

private extension Array {
    var only: Element? { count == 1 ? first : nil }
}
