import Foundation
import Testing
@testable import TrifolaKit

private let modelPinDay = "2026-07-10"
private let modelPinRoot: URL = {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("trifola-model-pin-contract-\(UUID().uuidString)")
    let agents = root.appendingPathComponent(".claude/agents", isDirectory: true)
    try! FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
    try! "---\nname: Explore\n---\n".write(
        to: agents.appendingPathComponent("Explore.md"),
        atomically: true, encoding: .utf8)
    return root
}()

private func modelPinPolicy(source: DeclaredPolicySource = .claude) -> ClaudeSettings {
    ClaudeSettings(
        model: "opus", effort: .high,
        declaredPolicies: [DeclaredRoutingPolicy(
            source: source, model: "sonnet", selector: "execute",
            filePath: modelPinRoot.appendingPathComponent("CLAUDE.md").path,
            scopePath: modelPinRoot.path,
            targetPath: modelPinRoot.appendingPathComponent(
                ".claude/agents/Explore.md").path)])
}

private func modelPinParent(
    _ invocations: [SubagentInvocation],
    id: String = "P"
) -> SessionSummary {
    SessionSummary(
        id: id, project: "trifola", cwd: modelPinRoot.path, model: "claude-opus-4-8",
        lastActivity: Date(), messageCount: 5, usage: SessionUsage(),
        contextWeight: 0, filePath: modelPinRoot.appendingPathComponent("\(id).jsonl").path,
        agentCalls: invocations.count, subagentInvocations: invocations)
}

private func modelPinChild(
    agentID: String,
    model: String,
    input: Int,
    parentID: String = "P"
) -> SessionSummary {
    let usage = SessionUsage(inputTokens: input)
    let tier = ModelTier(raw: model)
    return SessionSummary(
        id: "\(parentID)/agent-\(agentID)", project: "trifola", cwd: modelPinRoot.path,
        model: model, lastActivity: Date(), messageCount: 3, usage: usage,
        contextWeight: 0,
        filePath: modelPinRoot.appendingPathComponent(
            "\(parentID)/subagents/agent-\(agentID).jsonl").path,
        usageByTier: [tier: usage])
}

@Suite("Ledger L-001 — declared versus resolved")
struct ModelPinDetectorTests {
    @Test func matchingDeclaredAndResolvedModelStaysQuiet() {
        let invocation = SubagentInvocation(
            agentID: "match", agentType: "Explore", resolvedModel: "claude-sonnet-5")
        let sessions = [
            modelPinParent([invocation]),
            modelPinChild(agentID: "match", model: "claude-sonnet-5", input: 1_000_000),
        ]

        let result = LessonMiner.modelPinMismatches(
            sessions: sessions, settings: modelPinPolicy(), fallbackDay: modelPinDay)
        #expect(result.count == 0)
        #expect(result.total == 0)
    }

    @Test func silentInheritanceMismatchFires() throws {
        let invocation = SubagentInvocation(
            agentID: "silent", agentType: "Explore", requestedModel: nil,
            resolvedModel: "claude-opus-4-8")
        let sessions = [
            modelPinParent([invocation]),
            modelPinChild(agentID: "silent", model: "claude-opus-4-8", input: 1_000_000),
        ]

        let result = LessonMiner.modelPinMismatches(
            sessions: sessions, settings: modelPinPolicy(), fallbackDay: modelPinDay)
        let mismatch = try #require(result.top.first)
        #expect(result.count == 1)
        #expect(mismatch.declaredModel == "sonnet")
        #expect(mismatch.resolvedModel == "claude-opus-4-8")
        // Opus 4.8 $5/M − declared Sonnet 5 intro rate $2/M.
        #expect(abs(mismatch.deltaDollars - 3) < 0.0001)
    }

    @Test func explicitAgentModelOverrideIsExcluded() {
        let invocation = SubagentInvocation(
            agentID: "override", agentType: "Explore", requestedModel: "opus",
            resolvedModel: "claude-opus-4-8")
        let sessions = [
            modelPinParent([invocation]),
            modelPinChild(agentID: "override", model: "claude-opus-4-8", input: 1_000_000),
        ]

        let result = LessonMiner.modelPinMismatches(
            sessions: sessions, settings: modelPinPolicy(), fallbackDay: modelPinDay)
        #expect(result.count == 0)
    }

    @Test func inheritKeywordRemainsASilentInheritance() {
        let invocation = SubagentInvocation(
            agentID: "inherit", agentType: "Explore", requestedModel: "inherit",
            resolvedModel: "claude-opus-4-8")
        let sessions = [
            modelPinParent([invocation]),
            modelPinChild(agentID: "inherit", model: "claude-opus-4-8", input: 1_000_000),
        ]
        let result = LessonMiner.modelPinMismatches(
            sessions: sessions, settings: modelPinPolicy(), fallbackDay: modelPinDay)
        #expect(result.count == 1)
    }

    @Test func dollarRankingUsesDeclaredCatalogReprice() throws {
        let invocations = [
            SubagentInvocation(agentID: "small", agentType: "Explore",
                               resolvedModel: "claude-opus-4-8"),
            SubagentInvocation(agentID: "large", agentType: "Explore",
                               resolvedModel: "claude-opus-4-8"),
        ]
        let sessions = [
            modelPinParent(invocations),
            modelPinChild(agentID: "small", model: "claude-opus-4-8", input: 1_000_000),
            modelPinChild(agentID: "large", model: "claude-opus-4-8", input: 2_000_000),
        ]

        let result = LessonMiner.modelPinMismatches(
            sessions: sessions, settings: modelPinPolicy(), fallbackDay: modelPinDay)
        #expect(result.top.map(\.sessionID) == ["P/agent-large", "P/agent-small"])
        #expect(abs(result.top[0].deltaDollars - 6) < 0.0001)
        #expect(abs(result.total - 9) < 0.0001)
    }

    @Test func providerTagFlowsFromDeclaredPolicy() throws {
        let invocation = SubagentInvocation(
            agentID: "provider", agentType: "Explore",
            resolvedModel: "claude-opus-4-8")
        let sessions = [
            modelPinParent([invocation]),
            modelPinChild(agentID: "provider", model: "claude-opus-4-8", input: 1_000_000),
        ]
        let result = LessonMiner.modelPinMismatches(
            sessions: sessions, settings: modelPinPolicy(source: .codex),
            fallbackDay: modelPinDay)
        #expect(try #require(result.top.first).provider == .codex)
    }

    @Test func auditReportCarriesLegsIntoExistingMintCall() {
        let invocation = SubagentInvocation(
            agentID: "report", agentType: "Explore",
            resolvedModel: "claude-opus-4-8")
        let sessions = [
            modelPinParent([invocation]),
            modelPinChild(agentID: "report", model: "claude-opus-4-8", input: 1_000_000),
        ]
        let report = AuditReport.build(sessions: sessions, skills: [])

        let lessons = LessonMiner.mint(
            report: report, catalog: [], settings: modelPinPolicy())
        #expect(lessons.first?.kind == .modelPin)
    }
}

@Suite("Ledger L-001 — copy edit and priority")
struct ModelPinLessonContractTests {
    private func firingSessions() -> [SessionSummary] {
        let invocation = SubagentInvocation(
            agentID: "copy", agentType: "Explore", resolvedModel: "claude-opus-4-8")
        return [
            modelPinParent([invocation]),
            modelPinChild(agentID: "copy", model: "claude-opus-4-8", input: 1_000_000),
        ]
    }

    @Test func copyEditIsTheExactModelLineAndFileTarget() throws {
        let lesson = try #require(LessonMiner.modelPin(
            sessions: firingSessions(), settings: modelPinPolicy(),
            fallbackDay: modelPinDay))

        #expect(lesson.kind == .modelPin)
        #expect(lesson.candidate.action == .copyEdit)
        #expect(lesson.candidate.copyText == "model: sonnet")
        #expect(lesson.candidate.afterText == "model: sonnet")
        #expect(lesson.candidate.revealTargets.map(\.path)
                == [modelPinRoot.appendingPathComponent(
                    ".claude/agents/Explore.md").path])
    }

    @Test func missingDefinitionEmitsPolicyUnresolvedInsteadOfCopyEdit() throws {
        let missing = modelPinRoot.appendingPathComponent("missing/Explore.md").path
        let settings = ClaudeSettings(declaredPolicies: [DeclaredRoutingPolicy(
            source: .claude, model: "sonnet", selector: "Explore",
            filePath: modelPinRoot.appendingPathComponent("CLAUDE.md").path,
            scopePath: modelPinRoot.path, targetPath: missing)])
        let lesson = try #require(LessonMiner.modelPin(
            sessions: firingSessions(), settings: settings,
            fallbackDay: modelPinDay))
        #expect(lesson.candidate.action == .copyReview)
        #expect(lesson.candidate.summary.contains("policy unresolved"))
        #expect(lesson.candidate.copyText.contains("policy unresolved"))
        #expect(lesson.candidate.revealTargets.isEmpty)
    }

    @Test func sessionDefaultAloneIsNotInventedAsSubagentPolicy() throws {
        let lesson = try #require(LessonMiner.modelPin(
            sessions: firingSessions(),
            settings: ClaudeSettings(model: "sonnet"),
            fallbackDay: modelPinDay))
        #expect(lesson.candidate.action == .copyReview)
        #expect(lesson.candidate.summary.contains("policy unresolved"))
        #expect(lesson.candidate.copyText.contains("declared sonnet") == false)
    }

    @Test func semanticPriorityOrderingIsRestored() {
        #expect(LessonKind.modelPin.priority < LessonKind.cacheMissDiscipline.priority)
        #expect(LessonKind.cacheMissDiscipline.priority < LessonKind.rightSizing.priority)
        #expect(LessonKind.rightSizing.priority < LessonKind.deadSkillArchive.priority)
        #expect(LessonKind.deadSkillArchive.priority < LessonKind.effortFurnace.priority)
    }
}

@Suite("Ledger L-001 — declared-policy parsing")
struct DeclaredPolicyParsingTests {
    @Test func nearestAncestorClaudeMDAndExistingAgentDefinitionResolve() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-pin-ancestor-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config", isDirectory: true)
        let project = root.appendingPathComponent("workspace/project", isDirectory: true)
        let nested = project.appendingPathComponent("Sources/Feature", isDirectory: true)
        let agents = project.appendingPathComponent(".claude/agents", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: nested, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try "subagent Explore model: sonnet\n".write(
            to: project.appendingPathComponent("CLAUDE.md"),
            atomically: true, encoding: .utf8)
        let target = agents.appendingPathComponent("Explore.md")
        try "---\nname: Explore\n---\n".write(to: target, atomically: true, encoding: .utf8)
        let paths = ClaudePaths(root: config, source: .environmentOverride)
        let settings = ClaudeSettings.load(paths: paths)
        let leg = SubagentModelLeg(
            sessionID: "P/agent-x", project: "project", cwd: nested.path,
            filePath: nested.appendingPathComponent("agent-x.jsonl").path,
            agentType: "Explore", requestedModel: nil,
            resolvedModel: "claude-opus-4-8",
            usage: SessionUsage(inputTokens: 1_000_000),
            usageByModelDay: [:], actualCost: 5)

        guard case .resolved(let policy, let resolvedTarget) =
                settings.policyResolution(for: leg) else {
            Issue.record("Expected the ancestor policy to resolve")
            return
        }
        #expect(policy.model == "sonnet")
        #expect(policy.filePath == project.appendingPathComponent("CLAUDE.md").path)
        #expect(resolvedTarget == target.path)
    }

    @Test func agentDefinitionFrontmatterOutranksAncestorProse() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-pin-agent-definition-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let config = root.appendingPathComponent("config", isDirectory: true)
        let project = root.appendingPathComponent("project", isDirectory: true)
        let agents = project.appendingPathComponent(".claude/agents", isDirectory: true)
        try FileManager.default.createDirectory(at: config, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: agents, withIntermediateDirectories: true)
        try "subagent Explore model: sonnet\n".write(
            to: project.appendingPathComponent("CLAUDE.md"), atomically: true,
            encoding: .utf8)
        let target = agents.appendingPathComponent("Explore.md")
        try "---\nmodel: haiku\n---\n".write(to: target, atomically: true,
                                                encoding: .utf8)
        let settings = ClaudeSettings.load(paths: ClaudePaths(
            root: config, source: .environmentOverride))
        let leg = SubagentModelLeg(
            sessionID: "P/agent-x", project: "project", cwd: project.path,
            filePath: target.path, agentType: "Explore", requestedModel: nil,
            resolvedModel: "claude-opus-4-8", usage: SessionUsage(),
            usageByModelDay: [:], actualCost: 0)
        guard case .resolved(let policy, _) = settings.policyResolution(for: leg)
        else { Issue.record("Expected agent definition policy"); return }
        #expect(policy.model == "haiku")
        #expect(policy.filePath == target.path)
    }

    @Test func settingsAndParseableClaudeMDPinsAreProviderTagged() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("model-pin-policy-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let settingsURL = dir.appendingPathComponent("settings.json")
        let claudeURL = dir.appendingPathComponent("CLAUDE.md")
        try #"{"model":"opus","effortLevel":"high"}"#
            .write(to: settingsURL, atomically: true, encoding: .utf8)
        try """
        # Routing
        subagent Explore model: sonnet
        Default pins: sonnet (execute), opus (reason/review)
        A generic example below must not be parsed:
        model: haiku
        """.write(to: claudeURL, atomically: true, encoding: .utf8)

        let settings = ClaudeSettings.load(settingsURL, claudeMDURLs: [claudeURL])

        #expect(settings.declaredPolicies.count == 5)
        #expect(settings.declaredPolicies.allSatisfy { $0.source == .claude })
        #expect(settings.policy(forSubagentType: "Explore")?.model == "sonnet")
        #expect(settings.policy(forSubagentType: "code-review")?.model == "opus")
    }

    @Test func accumulatorPreservesAgentRequestedAndResolvedModelJoin() throws {
        let lines = [
            #"{"type":"assistant","timestamp":"2026-07-10T00:00:00.000Z","sessionId":"P","cwd":"/repo","message":{"id":"msg_1","model":"claude-opus-4-8","content":[{"type":"tool_use","id":"toolu_1","name":"Agent","input":{"description":"Explore","prompt":"Inspect","subagent_type":"Explore"}}]}}"#,
            #"{"type":"user","timestamp":"2026-07-10T00:00:01.000Z","sessionId":"P","cwd":"/repo","toolUseResult":{"agentId":"abc123","agentType":"Explore","resolvedModel":"claude-sonnet-5","status":"completed"},"message":{"content":[{"type":"tool_result","tool_use_id":"toolu_1","content":[]}]}}"#,
        ]
        var accumulator = SessionAccumulator(defaultID: "P")
        accumulator.ingest(Data((lines.joined(separator: "\n") + "\n").utf8))
        let summary = accumulator.summary(filePath: "/repo/P.jsonl")
        let invocation = try #require(summary.subagentInvocations.first)

        #expect(invocation.agentID == "abc123")
        #expect(invocation.agentType == "Explore")
        #expect(invocation.requestedModel == nil)
        #expect(invocation.resolvedModel == "claude-sonnet-5")
    }
}
