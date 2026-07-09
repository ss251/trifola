import Foundation
import Testing
@testable import TrifolaKit

// MARK: - CONFIG-SURFACE HEALTH (VISION 2.4)
// The three config→result mappings are PURE: JSON → parse → classify (with an
// injected resolver) → statuses. These tests pin each mapping over fixtures that
// include the failure modes that matter (a missing MCP binary, a missing hook
// script, a stale plugin) and the honest degrade-to-empty on garbage.

// A resolver where a fixed set of commands "resolve"; everything else is missing.
private func resolver(_ present: Set<String>) -> (String) -> Bool {
    { present.contains(($0 as NSString).lastPathComponent) }
}

// MARK: MCP servers

@Suite("MCPConfig")
struct MCPConfigTests {

    private let json = Data(#"""
    {"mcpServers":{
      "cleanshot":{"type":"stdio","command":"npx","args":["-y","cleanshot-mcp"]},
      "headroom":{"type":"stdio","command":"headroom","args":["mcp","serve"]},
      "circle":{"type":"http","url":"https://api.circle.com/v1/codegen/mcp"},
      "ghost":{"type":"stdio","command":"ghost-mcp-bin"},
      "junk":42}}
    """#.utf8)

    @Test func parseSortsAndSkipsNonObjectEntries() {
        let servers = MCPConfig.parse(json)
        #expect(servers.map(\.name) == ["circle", "cleanshot", "ghost", "headroom"])
        let circle = servers.first { $0.name == "circle" }
        #expect(circle?.transport == "http")
        #expect(circle?.command == nil)
        #expect(circle?.url == "https://api.circle.com/v1/codegen/mcp")
        #expect(servers.first { $0.name == "cleanshot" }?.command == "npx")
    }

    @Test func classifyPresentMissingAndRemote() {
        let health = MCPConfig.classify(MCPConfig.parse(json),
                                        resolves: resolver(["npx", "headroom"]))
        func status(_ n: String) -> MCPServerHealthStatus? { health.first { $0.name == n }?.status }
        #expect(status("cleanshot") == .present)   // npx resolves
        #expect(status("headroom") == .present)    // headroom resolves
        #expect(status("circle") == .remote)       // http URL, nothing to check
        #expect(status("ghost") == .missing)       // ghost-mcp-bin does not resolve
    }

    @Test func summaryCounts() {
        let health = MCPConfig.classify(MCPConfig.parse(json), resolves: resolver(["npx", "headroom"]))
        let (present, missing, remote) = MCPConfig.summary(health)
        #expect(present == 2)
        #expect(missing == 1)
        #expect(remote == 1)
    }

    @Test func probeResultDegradedWhenABinaryIsMissing() {
        let health = MCPConfig.classify(MCPConfig.parse(json), resolves: resolver(["npx", "headroom"]))
        #expect(MCPConfig.probeResult(health).status == .degraded)
    }

    @Test func probeResultUpWhenEveryBinaryPresent() {
        // Drop the ghost server → all stdio commands resolve, circle stays remote.
        let clean = Data(#"""
        {"mcpServers":{
          "cleanshot":{"type":"stdio","command":"npx"},
          "circle":{"type":"http","url":"https://example.com/mcp"}}}
        """#.utf8)
        let health = MCPConfig.classify(MCPConfig.parse(clean), resolves: resolver(["npx"]))
        let result = MCPConfig.probeResult(health)
        #expect(result.status == .up)
        #expect(result.detail.contains("not a live handshake"))   // the honest limit label
        #expect(result.metrics.first { $0.label == "cleanshot" }?.value.contains("present") == true)
        #expect(result.metrics.first { $0.label == "circle" }?.value.contains("remote") == true)
    }

    @Test func garbageAndMissingKeyDegradeToEmpty() {
        #expect(MCPConfig.parse(Data("not json".utf8)).isEmpty)
        #expect(MCPConfig.parse(Data(#"{"other":1}"#.utf8)).isEmpty)
        #expect(MCPConfig.probeResult([]).status == .degraded)   // "no MCP servers configured"
    }
}

// MARK: Hooks

@Suite("HooksConfig")
struct HooksConfigTests {

    private let json = Data(#"""
    {"hooks":{
      "SessionStart":[
        {"matcher":"","hooks":[{"type":"command","command":"precommit-check","timeout":10}]},
        {"matcher":"","hooks":[{"type":"command","command":"echo 'MODEL SELF-CHECK'"}]},
        {"matcher":"compact","hooks":[{"type":"command","command":"echo 'RESUMED'"}]}],
      "PreToolUse":[{"matcher":"Bash","hooks":[{"type":"command","command":"guard-hook.sh --strict"}]}]}}
    """#.utf8)

    @Test func firstTokenExtractsExecutableAndSkipsEnvPrefix() {
        #expect(HooksConfig.firstToken("echo 'hi'") == "echo")
        #expect(HooksConfig.firstToken("precommit-check") == "precommit-check")
        #expect(HooksConfig.firstToken("/usr/local/bin/foo --x") == "/usr/local/bin/foo")
        #expect(HooksConfig.firstToken("FOO=bar baz --q") == "baz")
        #expect(HooksConfig.firstToken("") == "")
    }

    @Test func parseFlattensEventsMatchersAndEntries() {
        let hooks = HooksConfig.parse(json)
        #expect(hooks.count == 4)
        #expect(Set(hooks.map(\.event)) == ["SessionStart", "PreToolUse"])
        #expect(hooks.contains { $0.binary == "precommit-check" })
        #expect(hooks.contains { $0.binary == "guard-hook.sh" && $0.matcher == "Bash" })
    }

    @Test func classifyPresentBuiltinAndMissing() {
        // precommit-check resolves; guard-hook.sh does not; echoes are builtins.
        let health = HooksConfig.classify(HooksConfig.parse(json), resolves: resolver(["precommit-check"]))
        #expect(health.first { $0.binary == "precommit-check" }?.status == .present)
        #expect(health.first { $0.binary == "guard-hook.sh" }?.status == .missing)
        #expect(health.filter { $0.status == .builtin }.count == 2)   // the two echo reminders
    }

    @Test func summaryCounts() {
        let health = HooksConfig.classify(HooksConfig.parse(json), resolves: resolver(["precommit-check"]))
        let (present, builtin, missing, events) = HooksConfig.summary(health)
        #expect(present == 1)
        #expect(builtin == 2)
        #expect(missing == 1)
        #expect(events == 2)
    }

    @Test func probeResultDegradedWhenAScriptIsMissing() {
        let health = HooksConfig.classify(HooksConfig.parse(json), resolves: resolver(["precommit-check"]))
        let result = HooksConfig.probeResult(health)
        #expect(result.status == .degraded)
        // Distinct real binaries surface as unique metric labels + a reminders roll-up.
        #expect(result.metrics.first { $0.label == "precommit-check" }?.value.contains("present") == true)
        #expect(result.metrics.first { $0.label == "guard-hook.sh" }?.value.contains("missing") == true)
        #expect(result.metrics.first { $0.label == "reminders" }?.value.contains("2 echo") == true)
    }

    @Test func probeResultUpWhenOnlyRealToolsPresentAndReminders() {
        // Same fixture but guard-hook.sh now resolves → nothing missing → up.
        let health = HooksConfig.classify(HooksConfig.parse(json),
                                          resolves: resolver(["precommit-check", "guard-hook.sh"]))
        #expect(HooksConfig.probeResult(health).status == .up)
    }

    @Test func noHooksIsUpAndGarbageEmpty() {
        #expect(HooksConfig.parse(Data("not json".utf8)).isEmpty)
        #expect(HooksConfig.parse(Data(#"{"other":1}"#.utf8)).isEmpty)
        #expect(HooksConfig.probeResult([]).status == .up)   // no hooks configured is healthy
    }
}

// MARK: Plugins

@Suite("PluginsConfig")
struct PluginsConfigTests {

    // now = 2026-07-06; code-simplifier last updated 2026-01-09 → ~178d → stale.
    private let now = ISO8601DateFormatter().date(from: "2026-07-06T12:00:00Z")!

    private let json = Data(#"""
    {"version":2,"plugins":{
      "code-simplifier@claude-plugins-official":[{"scope":"user","version":"1.0.0","installedAt":"2026-01-09T14:51:03.980Z","lastUpdated":"2026-01-09T14:51:03.980Z"}],
      "code-review@claude-plugins-official":[{"scope":"user","version":"unknown","lastUpdated":"2026-07-06T08:38:35.768Z"}],
      "codex@openai-codex":[{"scope":"user","version":"1.0.4","lastUpdated":"2026-06-17T13:47:05.084Z"}],
      "no-date@x":[{"scope":"user","version":"9.9.9"}]}}
    """#.utf8)

    @Test func parseReadsNameMarketplaceVersionAndAge() {
        let plugins = PluginsConfig.parse(json, now: now)
        #expect(plugins.count == 4)
        let cs = plugins.first { $0.name == "code-simplifier" }
        #expect(cs?.marketplace == "claude-plugins-official")
        #expect(cs?.version == "1.0.0")
        #expect((cs?.ageDays ?? 0) > 170 && (cs?.ageDays ?? 0) < 185)
    }

    @Test func staleFlagFiresOnlyBeyondThreshold() {
        let plugins = PluginsConfig.parse(json, now: now)
        #expect(plugins.first { $0.name == "code-simplifier" }?.isStale == true)
        #expect(plugins.first { $0.name == "code-review" }?.isStale == false)
        #expect(plugins.first { $0.name == "codex" }?.isStale == false)
    }

    @Test func fallsBackToInstalledAtAndSortsStalestFirst() {
        let plugins = PluginsConfig.parse(json, now: now)
        // code-simplifier has the oldest date → stalest → sorted first.
        #expect(plugins.first?.name == "code-simplifier")
    }

    @Test func missingDateHasNilAgeAndIsNotStale() {
        let plugins = PluginsConfig.parse(json, now: now)
        let nd = plugins.first { $0.name == "no-date" }
        #expect(nd?.ageDays == nil)
        #expect(nd?.isStale == false)   // unknown age is never asserted as stale
    }

    @Test func summaryCountsInstalledAndStale() {
        let (installed, stale) = PluginsConfig.summary(PluginsConfig.parse(json, now: now))
        #expect(installed == 4)
        #expect(stale == 1)
    }

    @Test func probeResultDegradedWithAStalePlugin() {
        let result = PluginsConfig.probeResult(PluginsConfig.parse(json, now: now))
        #expect(result.status == .degraded)
        #expect(result.detail.contains("stale"))
        #expect(result.metrics.first { $0.label == "installed" }?.value == "4")
        #expect(result.metrics.first { $0.label == "code-simplifier" }?.value.contains("stale") == true)
    }

    @Test func probeResultUpWhenAllFresh() {
        let fresh = Data(#"""
        {"version":2,"plugins":{
          "codex@openai-codex":[{"scope":"user","version":"1.0.4","lastUpdated":"2026-06-17T13:47:05.084Z"}],
          "imessage@claude-plugins-official":[{"scope":"user","version":"0.1.0","lastUpdated":"2026-07-02T13:35:09.765Z"}]}}
        """#.utf8)
        let result = PluginsConfig.probeResult(PluginsConfig.parse(fresh, now: now))
        #expect(result.status == .up)
        #expect(result.detail.contains("all fresh"))
    }

    @Test func garbageAndEmpty() {
        #expect(PluginsConfig.parse(Data("not json".utf8), now: now).isEmpty)
        #expect(PluginsConfig.parse(Data(#"{"version":2}"#.utf8), now: now).isEmpty)
        #expect(PluginsConfig.probeResult([]).status == .up)   // no plugins is healthy
    }
}

// MARK: commandResolves primitive

@Suite("ProbePrimitives.commandResolves")
struct CommandResolvesTests {

    @Test func resolvesAbsolutePathToARealBinary() {
        #expect(ProbePrimitives.commandResolves("/bin/ls"))
        #expect(!ProbePrimitives.commandResolves("/nope/definitely-not-here"))
    }

    @Test func resolvesABareSystemCommandOnPath() {
        // `ls` lives in /bin, which is always in the curated fallback dirs.
        #expect(ProbePrimitives.commandResolves("ls"))
    }

    @Test func doesNotResolveAMadeUpName() {
        #expect(!ProbePrimitives.commandResolves("totally-not-a-real-binary-xyz-123"))
        #expect(!ProbePrimitives.commandResolves(""))
    }
}

// MARK: Live probes over fixture files (end-to-end, no live machine dependency)

@Suite("Config probes over fixture files")
struct ConfigProbeFileTests {

    private func write(_ text: String) throws -> String {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("cfg-\(UUID().uuidString).json")
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    @Test func mcpProbeReadsFixtureAndReportsDegradedOnMissingBinary() async throws {
        let path = try write(#"""
        {"mcpServers":{
          "cleanshot":{"type":"stdio","command":"ls"},
          "ghost":{"type":"stdio","command":"totally-not-real-xyz-123"}}}
        """#)
        defer { try? FileManager.default.removeItem(atPath: path) }
        let result = await MCPServersProbe(configFile: path).check()
        #expect(result.status == .degraded)   // ghost binary missing
    }

    @Test func mcpProbeMissingFileIsDown() async {
        let result = await MCPServersProbe(configFile: "/nope/claude-\(UUID().uuidString).json").check()
        #expect(result.status == .down)
    }

    @Test func hooksProbeReadsFixtureAndDegradesOnMissingScript() async throws {
        let path = try write(#"""
        {"hooks":{"SessionStart":[
          {"matcher":"","hooks":[{"type":"command","command":"echo hi"}]},
          {"matcher":"","hooks":[{"type":"command","command":"totally-not-real-xyz-123"}]}]}}
        """#)
        defer { try? FileManager.default.removeItem(atPath: path) }
        #expect(await HooksProbe(settingsFile: path).check().status == .degraded)
    }

    @Test func pluginsProbeMissingFileIsDown() async {
        let result = await PluginsProbe(pluginsFile: "/nope/plugins-\(UUID().uuidString).json").check()
        #expect(result.status == .down)
    }

    @Test func defaultProbesIncludesTheThreeConfigProbes() {
        let ids = ToolProbeEngine.defaultProbes.map(\.id)
        #expect(ids.contains("mcp-servers"))
        #expect(ids.contains("hooks"))
        #expect(ids.contains("plugins"))
    }
}
