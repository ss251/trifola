import Foundation
import Testing
@testable import TrifolaKit

// Task #41: slash-command (`<command-name>`) invocations were invisible to the
// dead-skill ledger — a skill fired only via `/name` emits no `Skill` tool_use.
// This suite pins the extractor, both transcript shapes (Context §C of
// plans/01-skill-census-slash-commands.md), and the ledger merge semantics.

// MARK: - extractCommandName (pure)

@Suite("Command name extraction")
struct ExtractCommandNameTests {
    @Test func plainCommandStripsLeadingSlash() {
        let text = "<command-name>/commit</command-name>\n            <command-message>commit</command-message>"
        #expect(SessionAccumulator.extractCommandName(text) == "commit")
    }

    @Test func namespacedPluginCommandKeepsNamespace() {
        let text = "<command-name>/codex:rescue</command-name>\n            <command-message>rescue</command-message>"
        #expect(SessionAccumulator.extractCommandName(text) == "codex:rescue")
    }

    @Test func absentTagReturnsNil() {
        #expect(SessionAccumulator.extractCommandName("just a normal user prompt") == nil)
    }

    @Test func emptyTagReturnsNil() {
        #expect(SessionAccumulator.extractCommandName("<command-name></command-name>") == nil)
    }
}

// MARK: - Accumulator ingest (both transcript shapes)

@Suite("Command census ingest")
struct CommandCensusIngestTests {
    @Test func shapeA_userStringContent_countsCommand() {
        // User line, message.content is a STRING (the dominant shape, 63/85 in
        // the verified sample).
        let line = #"{"type":"user","message":{"role":"user","content":"<command-name>/effort</command-name>\n            <command-message>effort</command-message>\n            <command-args></command-args>"}}"#
        var acc = SessionAccumulator(defaultID: "fb")
        acc.ingest(Data((line + "\n").utf8))
        let s = acc.summary(filePath: "/x.jsonl")
        #expect(s.commandInvocations == ["effort": 1])
    }

    @Test func shapeA_userBlockArrayContent_countsCommand() {
        // User line, message.content is an ARRAY of blocks — the tag rides the
        // first `text` block.
        let line = #"{"type":"user","message":{"role":"user","content":[{"type":"text","text":"<command-name>/graphify</command-name>\n            <command-message>graphify</command-message>\n            <command-args></command-args>"}]}}"#
        var acc = SessionAccumulator(defaultID: "fb")
        acc.ingest(Data((line + "\n").utf8))
        let s = acc.summary(filePath: "/x.jsonl")
        #expect(s.commandInvocations == ["graphify": 1])
    }

    @Test func shapeB_systemTopLevelContent_countsCommand() {
        // System line, TOP-LEVEL `content` string (mostly CLI built-ins).
        let line = #"{"type":"system","content":"<command-name>/login</command-name>\n            <command-message>login</command-message>\n            <command-args></command-args>","isMeta":false}"#
        var acc = SessionAccumulator(defaultID: "fb")
        acc.ingest(Data((line + "\n").utf8))
        let s = acc.summary(filePath: "/x.jsonl")
        #expect(s.commandInvocations == ["login": 1])
    }

    @Test func nonCommandUserLineIncrementsNothing() {
        let line = #"{"type":"user","message":{"role":"user","content":"just a normal typed prompt"}}"#
        var acc = SessionAccumulator(defaultID: "fb")
        acc.ingest(Data((line + "\n").utf8))
        let s = acc.summary(filePath: "/x.jsonl")
        #expect(s.commandInvocations.isEmpty)
    }
}

// MARK: - skillLedger merge (skillInvocations ∪ commandInvocations)

@Suite("Skill ledger — slash-command merge")
struct SkillLedgerCommandMergeTests {
    private func skill(_ id: String, name: String? = nil, desc: String = "a skill") -> Skill {
        Skill(id: id, name: name ?? id, description: desc, version: nil, triggers: [],
              allowedTools: [], hasManifest: true, wordCount: 100, fileCount: 1,
              modified: .distantPast, path: "/skills/\(id)")
    }
    private func session(skillFires: [String: Int] = [:], commandFires: [String: Int] = [:],
                          last: Date? = Date()) -> SessionSummary {
        SessionSummary(id: UUID().uuidString, project: "p", cwd: "/tmp/p", model: "claude-opus-4-8",
                       lastActivity: last, messageCount: 1, usage: SessionUsage(), contextWeight: 0,
                       filePath: "/x/s.jsonl",
                       skillInvocations: skillFires, commandInvocations: commandFires)
    }

    @Test func catalogSkillFiredOnlyViaSlashIsNoLongerDead() {
        let catalog = [skill("graphify")]
        let sessions = [session(commandFires: ["graphify": 2])]
        let led = AuditReport.skillLedger(sessions: sessions, catalog: catalog)
        #expect(led.deadCount == 0)
        #expect(led.distinctFired == 1)
        let entry = led.fired.first { $0.name == "graphify" }
        #expect(entry?.invocations == 2)
        #expect(entry?.inCatalog == true)
    }

    @Test func builtInSlashCommandSurfacesOutOfCatalogWithoutTouchingDeadList() {
        // Catalog has NO "model" skill — `/model` is a CLI built-in.
        let catalog = [skill("api-client"), skill("unused")]
        let sessions = [session(commandFires: ["model": 3])]
        let led = AuditReport.skillLedger(sessions: sessions, catalog: catalog)
        let entry = led.fired.first { $0.name == "model" }
        #expect(entry?.inCatalog == false)
        #expect(entry?.invocations == 3)
        #expect(led.deadCount == 2)   // both catalog skills still dead — untouched
    }

    @Test func skillToolAndSlashCommandLanesSumIntoOneFiredEntry() {
        let catalog = [skill("api-client")]
        let sessions = [session(skillFires: ["api-client": 1], commandFires: ["api-client": 2])]
        let led = AuditReport.skillLedger(sessions: sessions, catalog: catalog)
        #expect(led.distinctFired == 1)
        let entry = led.fired.first { $0.name == "api-client" }
        #expect(entry?.invocations == 3)   // 1 (Skill tool) + 2 (slash) merged
        #expect(led.deadCount == 0)
    }
}

// MARK: - Session names (title = name-or-id, subtitle = directory)

@Suite("Session names")
struct SessionNameTests {
    @Test func aiTitleRecordBecomesBaseName() {
        var acc = SessionAccumulator(defaultID: "fb")
        let line = #"{"type":"ai-title","aiTitle":"Build project with Ghost","sessionId":"abc"}"#
        acc.ingest(Data((line + "\n").utf8))
        #expect(acc.summary(filePath: "").name == "Build project with Ghost")
    }

    @Test func liveRegistryParsesNamePerSession() {
        let file = #"{"pid":40029,"sessionId":"0ed7bc81-x","name":"ghost-salvage","status":"busy"}"#
        let noName = #"{"pid":41,"sessionId":"dead-x","status":"idle"}"#
        let names = SessionNames.parseLiveRegistry([Data(file.utf8), Data(noName.utf8)])
        #expect(names["0ed7bc81-x"] == "ghost-salvage")
        #expect(names["dead-x"] == nil)
    }

    @Test func historyRenamesLastWins() {
        let history = """
        {"display":"ls","sessionId":"s1"}
        {"display":"/rename first-name","sessionId":"s1"}
        {"display":"/rename mc-work","sessionId":"s1"}
        {"display":"/rename other","sessionId":"s2"}
        """
        let names = SessionNames.parseRenames(Data(history.utf8))
        #expect(names["s1"] == "mc-work")
        #expect(names["s2"] == "other")
    }

    @Test func displayTitleIsNameElseShortID() {
        let named = SessionSummary(id: "0ed7bc81-ab9b-4260-8079-f37099fa9944", project: "dev",
                                   cwd: "/Users/dev/home", model: nil, lastActivity: nil, messageCount: 0,
                                   usage: SessionUsage(), contextWeight: 0, name: "ghost-salvage")
        #expect(named.displayTitle == "ghost-salvage")
        let unnamed = SessionSummary(id: "0ed7bc81-ab9b-4260-8079-f37099fa9944", project: "dev",
                                     cwd: "/Users/dev/home", model: nil, lastActivity: nil, messageCount: 0,
                                     usage: SessionUsage(), contextWeight: 0)
        #expect(unnamed.displayTitle == "0ed7bc81")
    }

    @Test func overlayPrefersResolverOverAiTitle() {
        let base = SessionSummary(id: "s1", project: "p", cwd: "/x", model: nil, lastActivity: nil,
                                  messageCount: 0, usage: SessionUsage(), contextWeight: 0,
                                  name: "auto title")
        let out = SessionStore.applyNames([base], names: ["s1": "user-name"])
        #expect(out.first?.name == "user-name")
        let untouched = SessionStore.applyNames([base], names: [:])
        #expect(untouched.first?.name == "auto title")
    }
}
