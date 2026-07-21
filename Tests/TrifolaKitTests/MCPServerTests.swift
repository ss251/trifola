import Foundation
import Testing
@testable import TrifolaKit

// Spree #4 — SELF-INTROSPECTION MCP ENDPOINT (rauchg, RESEARCH_top_voices #20).
// These tests pin the protocol layer (initialize handshake, tools/list shape,
// tools/call round-trips on a canned corpus, malformed input → JSON-RPC error
// not a crash), the session-resolution seam (default = most recently active
// main; exact id; unique prefix; path form; ambiguity + not-found errors), and
// the REUSE contract: every number a tool returns must equal what the app's own
// builders (ContextTax.gauge, Reroutes, cost(onDay:), QuotaSnapshot) compute.

// MARK: - canned corpus

private let fixedNow = ISO8601DateFormatter().date(from: "2026-07-07T12:00:00Z")!
private let today = { () -> String in
    let f = DateFormatter()
    f.locale = Locale(identifier: "en_US_POSIX")
    f.dateFormat = "yyyy-MM-dd"
    return f.string(from: fixedNow)
}()

private func sess(_ id: String, project: String = "p", model: String? = "claude-opus-4-8",
                  ctx: Int = 100_000, ageSecs: TimeInterval? = 60,
                  usage: SessionUsage = SessionUsage(inputTokens: 100_000),
                  usageByModelDay: [String: [String: SessionUsage]] = [:],
                  flips: [ModelFlip] = [], turns: [String: Int] = [:],
                  subagent: Bool = false) -> SessionSummary {
    let path = subagent ? "/x/\(project)/s/subagents/agent-\(id).jsonl" : "/x/\(project)/\(id).jsonl"
    return SessionSummary(id: id, project: project, cwd: "/x/\(project)", model: model,
                          lastActivity: ageSecs.map { fixedNow.addingTimeInterval(-$0) },
                          messageCount: 7, usage: usage, contextWeight: ctx, filePath: path,
                          usageByModelDay: usageByModelDay,
                          assistantTurnsByModel: turns, modelFlips: flips)
}

/// A small fleet: "self" is the most recently active main; "older" has today's
/// usage + a silent flip; a subagent must never win default resolution.
private func corpus() -> [SessionSummary] {
    let flip = ModelFlip(fromModel: "claude-sonnet-5", toModel: "claude-opus-4-8",
                         timestamp: fixedNow.addingTimeInterval(-3600), day: today,
                         messageID: "msg_1", userInitiated: false)
    let deliberate = ModelFlip(fromModel: "claude-opus-4-8", toModel: "claude-ghost-5",
                               timestamp: fixedNow.addingTimeInterval(-1800), day: today,
                               messageID: "msg_2", userInitiated: true)
    return [
        sess("aaaa1111-0000-0000-0000-000000000001", model: "claude-ghost-5", ctx: 265_000,
             ageSecs: 30,
             usage: SessionUsage(inputTokens: 50_000, cacheReadTokens: 450_000),
             usageByModelDay: [today: ["claude-ghost-5": SessionUsage(inputTokens: 50_000, outputTokens: 10_000, cacheReadTokens: 450_000)]],
             turns: ["claude-ghost-5": 12]),
        sess("bbbb2222-0000-0000-0000-000000000002", ctx: 40_000, ageSecs: 7200,
             usageByModelDay: [today: ["claude-opus-4-8": SessionUsage(inputTokens: 100_000, outputTokens: 4_000)]],
             flips: [flip, deliberate], turns: ["claude-sonnet-5": 3, "claude-opus-4-8": 5]),
        // Subagent, MOST recent overall — default resolution must skip it.
        sess("bbbb3333-0000-0000-0000-000000000003", ctx: 10_000, ageSecs: 10, subagent: true),
    ]
}

private let registeredSelfID = "aaaa1111-0000-0000-0000-000000000001"

private func server(quota: MCPQuotaOutcome = .unavailable("no credentials found (test)"),
                    codexQuota: MCPQuotaOutcome = .unavailable(
                        MCPIntrospectionServer.codexNoCorpusMessage),
                    grokQuota: MCPQuotaOutcome = .unavailable(
                        MCPIntrospectionServer.quotaConsentRequiredMessage),
                    sessions: [SessionSummary]? = nil,
                    registeredSessionID: String? = registeredSelfID) -> MCPIntrospectionServer {
    MCPIntrospectionServer(sessions: { sessions ?? corpus() }, quota: { quota },
                           codexQuota: { codexQuota },
                           grokQuota: { grokQuota },
                           now: { fixedNow }, registeredSessionID: registeredSessionID)
}

private actor MCPQuotaProbeProvider: QuotaProvider {
    nonisolated let provider: Provider = .codex
    private let result: Result<QuotaSnapshot, QuotaProviderFailure>
    private var callCount = 0

    init(result: Result<QuotaSnapshot, QuotaProviderFailure>) {
        self.result = result
    }

    func snapshot() async -> Result<QuotaSnapshot, QuotaProviderFailure> {
        callCount += 1
        return result
    }

    func calls() -> Int { callCount }
}

private struct MCPDelayedQuotaProvider: QuotaProvider {
    let provider: Provider = .codex
    func snapshot() async -> Result<QuotaSnapshot, QuotaProviderFailure> {
        try? await Task.sleep(for: .milliseconds(100))
        return .failure(.noRateLimits)
    }
}

private struct MCPConsentRevokingQuotaProvider: QuotaProvider {
    let provider: Provider = .codex
    let revoke: @Sendable () -> Void

    func snapshot() async -> Result<QuotaSnapshot, QuotaProviderFailure> {
        revoke()
        return .success(QuotaSnapshot(
            fiveHour: QuotaWindow(title: "Session (5h)", usedPercent: 42,
                                  resetsAt: nil),
            weekly: nil, scoped: [], fetchedAt: fixedNow))
    }
}

// MARK: - decode helpers

private func rpc(_ srv: MCPIntrospectionServer, _ line: String) -> [String: Any]? {
    guard let out = srv.handleLine(line) else { return nil }
    #expect(!out.contains("\n"))                       // strict writer: single line
    return (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any]
}

private func result(_ obj: [String: Any]?) -> [String: Any]? { obj?["result"] as? [String: Any] }

/// Unwrap a tools/call reply → the parsed JSON payload of its one text block.
private func toolJSON(_ obj: [String: Any]?) -> [String: Any]? {
    guard let r = result(obj),
          r["isError"] as? Bool == false,
          let text = (r["content"] as? [[String: Any]])?.first?["text"] as? String else { return nil }
    return (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
}

private func call(_ srv: MCPIntrospectionServer, _ tool: String, args: String = "{}") -> [String: Any]? {
    rpc(srv, #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"\#(tool)","arguments":\#(args)}}"#)
}

// MARK: - protocol fixtures

@Suite("MCP — protocol handshake + shape")
struct MCPProtocolTests {

    @Test func initializeHandshakeEchoesSupportedVersion() {
        let obj = rpc(server(), #"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"t","version":"1"}}}"#)
        let r = result(obj)
        #expect(obj?["jsonrpc"] as? String == "2.0")
        #expect(obj?["id"] as? Int == 0)
        #expect(r?["protocolVersion"] as? String == "2025-06-18")
        #expect((r?["capabilities"] as? [String: Any])?["tools"] != nil)
        let info = r?["serverInfo"] as? [String: Any]
        #expect(info?["name"] as? String == "trifola")
        #expect((r?["instructions"] as? String)?.isEmpty == false)
    }

    @Test func initializeFallsBackOnUnknownVersionAndStringIDsEcho() {
        // Unknown requested version → we offer our latest (per MCP handshake).
        let obj = rpc(server(), #"{"jsonrpc":"2.0","id":"init-1","method":"initialize","params":{"protocolVersion":"2099-01-01"}}"#)
        #expect(result(obj)?["protocolVersion"] as? String == "2025-06-18")
        #expect(obj?["id"] as? String == "init-1")     // ids echo verbatim, string or int
    }

    @Test func toolsListShape() {
        let tools = result(rpc(server(), #"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#))?["tools"] as? [[String: Any]]
        #expect(tools?.count == 5)
        #expect(tools?.compactMap { $0["name"] as? String } ==
                ["session_brief", "context_tax", "reroutes", "cost_today", "quota_windows"])
        for t in tools ?? [] {
            #expect((t["description"] as? String)?.isEmpty == false)
            let schema = t["inputSchema"] as? [String: Any]
            #expect(schema?["type"] as? String == "object")
        }
        // The self-introspection calling convention is documented ON the tools.
        let brief = tools?.first { $0["name"] as? String == "session_brief" }
        #expect((brief?["description"] as? String)?.contains("UUID filename of your own transcript") == true)
        let properties = (brief?["inputSchema"] as? [String: Any])?["properties"] as? [String: Any]
        #expect(properties?["use_newest"] != nil)
        #expect((brief?["description"] as? String)?.contains("usually you") == false)
        let quota = tools?.first { $0["name"] as? String == "quota_windows" }
        #expect((quota?["description"] as? String)?.contains("Triple-provider") == true)
        #expect((quota?["description"] as? String)?.contains("Grok") == true)
        #expect((quota?["description"] as? String)?.contains("consent-gated independently") == true)
        #expect((quota?["description"] as? String)?.contains("every provider block is always present") == true)
    }

    @Test func pingAndNotificationsAndClientResponses() {
        let srv = server()
        #expect(result(rpc(srv, #"{"jsonrpc":"2.0","id":3,"method":"ping"}"#))?.isEmpty == true)
        // Notifications (no id) are absorbed — ANY method name, tolerant reader.
        #expect(srv.handleLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil)
        #expect(srv.handleLine(#"{"jsonrpc":"2.0","method":"notifications/cancelled","params":{"requestId":1}}"#) == nil)
        // A client RESPONSE echo is absorbed, not answered.
        #expect(srv.handleLine(#"{"jsonrpc":"2.0","id":7,"result":{}}"#) == nil)
        // Blank lines are transport noise.
        #expect(srv.handleLine("   ") == nil)
    }

    @Test func malformedAndUnknownInputsAreErrorsNeverCrashes() {
        let srv = server()
        let parseErr = rpc(srv, "{this is not json")?["error"] as? [String: Any]
        #expect(parseErr?["code"] as? Int == -32700)
        let arrayErr = rpc(srv, "[1,2,3]")?["error"] as? [String: Any]
        #expect(arrayErr?["code"] as? Int == -32700)   // not a JSON object
        let noMethod = rpc(srv, #"{"jsonrpc":"2.0","id":4}"#)?["error"] as? [String: Any]
        #expect(noMethod?["code"] as? Int == -32600)
        let unknown = rpc(srv, #"{"jsonrpc":"2.0","id":5,"method":"resources/list"}"#)?["error"] as? [String: Any]
        #expect(unknown?["code"] as? Int == -32601)
        let badTool = rpc(srv, #"{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"nope"}}"#)?["error"] as? [String: Any]
        #expect(badTool?["code"] as? Int == -32602)
        let noName = rpc(srv, #"{"jsonrpc":"2.0","id":6,"method":"tools/call"}"#)?["error"] as? [String: Any]
        #expect(noName?["code"] as? Int == -32602)
    }
}

// MARK: - session resolution

@Suite("MCP — session resolution (the introspect-YOURSELF seam)")
struct MCPResolutionTests {

    @Test func registeredIdentityResolvesWithoutAnArgument() {
        let json = toolJSON(call(server(), "session_brief"))
        #expect(json?["session_id"] as? String == "aaaa1111-0000-0000-0000-000000000001")
        #expect(json?["resolved_session_id"] as? String == registeredSelfID)
        #expect(json?["session_resolution"] as? String == "registered")
        #expect(json?["is_subagent"] as? Bool == false)
    }

    @Test func omissionWithoutRegistrationIsAnErrorAndNewestRequiresOptIn() {
        let unregistered = server(registeredSessionID: nil)
        let missing = result(call(unregistered, "session_brief"))
        #expect(missing?["isError"] as? Bool == true)
        let missingText = (missing?["content"] as? [[String: Any]])?.first?["text"] as? String
        #expect(missingText?.contains("session_id is required") == true)

        let newest = toolJSON(call(unregistered, "session_brief",
                                   args: #"{"use_newest":true}"#))
        #expect(newest?["resolved_session_id"] as? String == registeredSelfID)
        #expect(newest?["session_resolution"] as? String == "newest_opt_in")
        #expect(newest?["is_subagent"] as? Bool == false)
    }

    @Test func exactIDPrefixAndPathFormsResolve() {
        let srv = server()
        let byID = toolJSON(call(srv, "session_brief", args: #"{"session_id":"bbbb2222-0000-0000-0000-000000000002"}"#))
        #expect(byID?["project"] as? String == "p")
        #expect(byID?["resolved_session_id"] as? String == "bbbb2222-0000-0000-0000-000000000002")
        #expect(byID?["session_resolution"] as? String == "argument")
        let byPrefix = toolJSON(call(srv, "session_brief", args: #"{"session_id":"aaaa1111"}"#))
        #expect(byPrefix?["session_id"] as? String == "aaaa1111-0000-0000-0000-000000000001")
        let byPath = toolJSON(call(srv, "session_brief", args: #"{"session_id":"/x/p/bbbb2222-0000-0000-0000-000000000002.jsonl"}"#))
        #expect(byPath?["session_id"] as? String == "bbbb2222-0000-0000-0000-000000000002")
    }

    @Test func ambiguousAndUnknownIDsAreToolErrorsNotProtocolErrors() {
        let srv = server()
        // "bbbb" prefixes two sessions → isError result naming the collision.
        let amb = result(call(srv, "session_brief", args: #"{"session_id":"bbbb"}"#))
        #expect(amb?["isError"] as? Bool == true)
        let ambText = (amb?["content"] as? [[String: Any]])?.first?["text"] as? String
        #expect(ambText?.contains("ambiguous") == true)
        let missing = result(call(srv, "context_tax", args: #"{"session_id":"zzzz"}"#))
        #expect(missing?["isError"] as? Bool == true)
        let text = (missing?["content"] as? [[String: Any]])?.first?["text"] as? String
        #expect(text?.contains("not found") == true)
        // An empty corpus degrades with a reason, not a crash.
        let empty = result(call(server(sessions: []), "session_brief"))
        #expect(empty?["isError"] as? Bool == true)
    }
}

// MARK: - tool round-trips (the REUSE contract)

@Suite("MCP — tool payloads equal the app's own builders")
struct MCPToolTests {

    @Test func sessionBriefCarriesTheVitals() {
        let s = corpus()[0]
        let json = toolJSON(call(server(), "session_brief"))
        #expect(json?["model"] as? String == "claude-ghost-5")
        #expect(json?["tier"] as? String == s.tier.label)
        #expect(json?["context_weight_tokens"] as? Int == 265_000)
        #expect(json?["context_heavy"] as? Bool == true)
        #expect(json?["live"] as? Bool == true)
        #expect(json?["message_count"] as? Int == 7)
        #expect(json?["assistant_turns"] as? Int == 12)
        #expect(json?["handle"] as? String == s.displayTitle)
        let total = json?["cost_total_usd"] as? Double ?? -1
        #expect(abs(total - s.cost) < 0.001)           // same cost machinery
        #expect((json?["transcript_path"] as? String)?.hasSuffix(".jsonl") == true)
    }

    @Test func contextTaxEqualsTheGauge() {
        let s = corpus()[0]
        let g = ContextTax.gauge(s, now: fixedNow)
        let json = toolJSON(call(server(), "context_tax"))
        #expect(abs((json?["warm_next_message_usd"] as? Double ?? -1) - g.warmPerMessage) < 0.0001)
        #expect(abs((json?["cold_next_message_usd"] as? Double ?? -1) - g.coldPerMessage) < 0.0001)
        #expect(abs((json?["blended_next_message_usd"] as? Double ?? -1) - g.blendedPerMessage) < 0.0001)
        #expect(json?["advisory"] as? Bool == g.advisory)      // 265k > 200k → true
        #expect(json?["advisory_threshold_tokens"] as? Int == 200_000)
        #expect(json?["tax_line"] as? String == g.taxLine)
        #expect((json?["advisor_line"] as? String) == g.advisorLine)
    }

    @Test func reroutesCarrySilentFlipsAndExcludeDeliberateSwitches() {
        let json = toolJSON(call(server(), "reroutes",
                                 args: #"{"session_id":"bbbb2222-0000-0000-0000-000000000002"}"#))
        let flips = json?["silent_reroutes"] as? [[String: Any]]
        #expect(flips?.count == 1)                     // the deliberate one is excluded
        #expect(flips?.first?["from"] as? String == "claude-sonnet-5")
        #expect(flips?.first?["to"] as? String == "claude-opus-4-8")
        #expect(flips?.first?["direction"] as? String == "upshift")
        #expect(json?["user_model_switches_excluded"] as? Int == 1)
        #expect(json?["assistant_turns"] as? Int == 8)
        let fleetToday = json?["fleet_today"] as? [String: Any]
        #expect(fleetToday?["silent_reroutes"] as? Int == 1)
        #expect((json?["fleet_trend_14d"] as? [[String: Any]])?.count == 14)
        #expect(json?["semantics"] as? String == RerouteReport.semantics)
        // A clean session says so instead of inventing chrome.
        let clean = toolJSON(call(server(), "reroutes", args: #"{"session_id":"aaaa1111"}"#))
        #expect((clean?["headline"] as? String)?.contains("clean") == true)
        #expect((clean?["silent_reroutes"] as? [[String: Any]])?.isEmpty == true)
    }

    @Test func costTodayMatchesCostOnDayAndFindsTheHog() {
        // Make one main session dominate a ≥$20 day so the hog fires.
        let big = SessionUsage(inputTokens: 4_000_000, outputTokens: 200_000)   // opus: $20 + $5
        let hogged = [
            sess("cccc0000-0000-0000-0000-000000000001", ctx: 1,
                 usageByModelDay: [today: ["claude-opus-4-8": big]]),
            sess("dddd0000-0000-0000-0000-000000000002", ctx: 1,
                 usageByModelDay: [today: ["claude-haiku-4-5": SessionUsage(inputTokens: 100_000)]]),
        ]
        let srv = server(sessions: hogged)
        let json = toolJSON(call(srv, "cost_today"))
        #expect(json?["day"] as? String == today)
        // REUSE contract: total == Σ cost(onDay:) over the same corpus.
        let expected = hogged.reduce(0.0) { $0 + $1.cost(onDay: today) }
        #expect(abs((json?["total_usd"] as? Double ?? -1) - expected) < 0.001)
        let rows = json?["by_model"] as? [[String: Any]]
        #expect(rows?.count == 2)
        #expect(rows?.first?["model"] as? String == "claude-opus-4-8")   // cost-desc
        let hog = json?["orchestrator_hog_alert"] as? [String: Any]
        #expect(hog?["session_id"] as? String == "cccc0000-0000-0000-0000-000000000001")
        #expect((hog?["advice"] as? String)?.contains("delegate more to cheaper subagents") == true)
        // The canned base corpus is a quiet day → alert is null, key still present.
        let quiet = toolJSON(call(server(), "cost_today"))
        #expect(quiet?["orchestrator_hog_alert"] is NSNull)
    }

    @Test func quotaWindowsReturnsBothProviderBlocksFromSharedSnapshots() async throws {
        // Claude fixture through the REAL OAuth decoder seam.
        let payload = #"{"five_hour":{"utilization":91.0,"resets_at":"2026-07-07T12:35:00Z"},"seven_day":{"utilization":40.5,"resets_at":"2026-07-10T00:00:00Z"},"limits":[{"kind":"weekly_scoped","group":"weekly","percent":12.0,"resets_at":"2026-07-10T00:00:00Z","is_active":false,"scope":{"model":{"id":"ghost","display_name":"Ghost"}}}]}"#
        let claudeSnapshot = try #require(QuotaSnapshot.decode(Data(payload.utf8), now: fixedNow))

        // Codex fixture goes through the exact CodexQuotaProvider used by the
        // Quota screen. MCP receives its shared QuotaSnapshot; it never parses
        // the rollout independently.
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("trifola-mcp-quota-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let rollout = root.appendingPathComponent("2026/07/10/rollout-quota.jsonl")
        try FileManager.default.createDirectory(
            at: rollout.deletingLastPathComponent(), withIntermediateDirectories: true)
        let rateLine = #"{"timestamp":"2026-07-07T12:01:00Z","type":"event_msg","payload":{"type":"token_count","rate_limits":{"primary":{"used_percent":37.5,"window_minutes":300,"resets_at":1783427700},"secondary":{"used_percent":62.25,"window_minutes":10080,"resets_at":1784310593}}}}"#
        try Data((rateLine + "\n").utf8).write(to: rollout)
        let codexResult = await CodexQuotaProvider(
            sessionsRoot: root, now: { fixedNow }).snapshot()
        let codexSnapshot: QuotaSnapshot
        switch codexResult {
        case .success(let snapshot): codexSnapshot = snapshot
        case .failure(let failure):
            Issue.record("unexpected Codex fixture failure: \(failure)")
            return
        }

        let grokSnapshot = QuotaSnapshot(
            fiveHour: nil,
            weekly: QuotaWindow(title: "SuperGrok", usedPercent: 42.5,
                                resetsAt: fixedNow.addingTimeInterval(2 * 86_400)),
            scoped: [],
            fetchedAt: fixedNow)
        let json = try #require(toolJSON(call(server(
            quota: .snapshot(claudeSnapshot),
            codexQuota: .snapshot(codexSnapshot),
            grokQuota: .snapshot(grokSnapshot)), "quota_windows")))
        let providers = try #require(json["providers"] as? [String: Any])
        #expect(Set(providers.keys) == Set(["claude", "codex", "grok"]))
        let claude = try #require(providers["claude"] as? [String: Any])
        let codex = try #require(providers["codex"] as? [String: Any])
        let grok = try #require(providers["grok"] as? [String: Any])
        #expect(claude["provider"] as? String == "claude")
        #expect(claude["available"] as? Bool == true)
        #expect(claude["status"] as? String == "ok")
        let claudeWindows = try #require(claude["windows"] as? [[String: Any]])
        #expect(claudeWindows.count == claudeSnapshot.windows.count)
        #expect(claudeWindows.first?["used_fraction"] as? Double == 0.91)
        #expect(claudeWindows.first?["reset_in_seconds"] as? Int == 35 * 60)
        #expect(claudeWindows.first?["reset_runway"] as? String == "35m")
        #expect(claudeWindows.last?["title"] as? String == "Ghost only")

        #expect(codex["provider"] as? String == "codex")
        #expect(codex["available"] as? Bool == true)
        #expect(codex["status"] as? String == "ok")
        let codexWindows = try #require(codex["windows"] as? [[String: Any]])
        #expect(codexWindows.count == codexSnapshot.windows.count)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        for (serialized, shared) in zip(codexWindows, codexSnapshot.windows) {
            #expect(serialized["title"] as? String == shared.title)
            #expect(serialized["used_percent"] as? Double == shared.usedPercent)
            #expect(serialized["used_fraction"] as? Double == shared.usedPercent / 100)
            if let resetsAt = shared.resetsAt {
                #expect(serialized["resets_at"] as? String == formatter.string(from: resetsAt))
            } else {
                #expect(serialized["resets_at"] is NSNull)
            }
        }

        #expect(grok["provider"] as? String == "grok")
        #expect(grok["available"] as? Bool == true)
        #expect(grok["status"] as? String == "ok")
        let grokWindows = try #require(grok["windows"] as? [[String: Any]])
        #expect(grokWindows.count == 1)
        #expect(grokWindows.first?["title"] as? String == "SuperGrok")
        #expect(grokWindows.first?["used_percent"] as? Double == 42.5)
    }

    @Test func quotaWindowsKeepsUnavailableProvidersVisible() throws {
        let claudeSnapshot = QuotaSnapshot(
            fiveHour: QuotaWindow(title: "Session (5h)", usedPercent: 20,
                                  resetsAt: nil),
            weekly: nil, scoped: [], fetchedAt: fixedNow)
        let json = try #require(toolJSON(call(server(
            quota: .snapshot(claudeSnapshot),
            codexQuota: .unavailable(MCPIntrospectionServer.codexNoCorpusMessage),
            grokQuota: .unavailable(MCPIntrospectionServer.quotaConsentRequiredMessage)),
            "quota_windows")))
        let providers = try #require(json["providers"] as? [String: Any])
        #expect(Set(providers.keys) == Set(["claude", "codex", "grok"]))
        let claude = try #require(providers["claude"] as? [String: Any])
        let codex = try #require(providers["codex"] as? [String: Any])
        let grok = try #require(providers["grok"] as? [String: Any])
        #expect(claude["available"] as? Bool == true)
        #expect(codex["available"] as? Bool == false)
        #expect(codex["status"] as? String == MCPIntrospectionServer.codexNoCorpusMessage)
        #expect((codex["windows"] as? [[String: Any]])?.isEmpty == true)
        #expect(grok["available"] as? Bool == false)
        #expect(grok["status"] as? String ==
                MCPIntrospectionServer.quotaConsentRequiredMessage)
        #expect((grok["windows"] as? [[String: Any]])?.isEmpty == true)
    }

    @Test func quotaWindowsUsesProviderSpecificEmptySnapshotStatuses() throws {
        let empty = QuotaSnapshot(
            fiveHour: nil, weekly: nil, scoped: [], fetchedAt: fixedNow)
        let json = try #require(toolJSON(call(server(
            quota: .snapshot(empty), codexQuota: .snapshot(empty),
            grokQuota: .snapshot(empty)),
            "quota_windows")))
        let providers = try #require(json["providers"] as? [String: Any])
        let claude = try #require(providers["claude"] as? [String: Any])
        let codex = try #require(providers["codex"] as? [String: Any])
        let grok = try #require(providers["grok"] as? [String: Any])
        #expect(claude["available"] as? Bool == false)
        #expect(claude["status"] as? String ==
                MCPIntrospectionServer.claudeEmptySnapshotMessage)
        #expect(codex["available"] as? Bool == false)
        #expect(codex["status"] as? String ==
                MCPIntrospectionServer.codexEmptySnapshotMessage)
        #expect(grok["available"] as? Bool == false)
        #expect(grok["status"] as? String ==
                MCPIntrospectionServer.grokEmptySnapshotMessage)
    }

    @Test func repeatedCallsAreDeterministic() {
        // Strict writer: sorted keys → byte-identical replies for identical state.
        let srv = server()
        let line = #"{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"context_tax","arguments":{}}}"#
        #expect(srv.handleLine(line) == srv.handleLine(line))
    }
}

// MARK: - blocking quota fetch: bounded waits (plan 09)

@Suite("MCP — quota fetch can't hang the server")
struct MCPQuotaTimeoutTests {

    @Test func waitBoundedReturnsTrueWhenSignaledBeforeTheDeadline() {
        let sem = DispatchSemaphore(value: 0)
        sem.signal()
        #expect(MCPIntrospectionServer.waitBounded(sem, timeout: 5) == true)
    }

    @Test func waitBoundedReturnsFalseOnExpiryWithoutBlockingPastTheCap() {
        // A semaphore that never signals — the cap must still return promptly,
        // never wait anywhere near a "hung" duration.
        let sem = DispatchSemaphore(value: 0)
        let clock = ContinuousClock.now
        #expect(MCPIntrospectionServer.waitBounded(sem, timeout: 0.2) == false)
        #expect(clock.duration(to: .now) < .seconds(2))
    }

    @Test func threeProviderLiveTimeoutBudgetStaysBounded() {
        #expect(MCPIntrospectionServer.credentialReadTimeout
                + MCPIntrospectionServer.quotaFetchTimeout
                + MCPIntrospectionServer.codexQuotaReadTimeout
                + MCPIntrospectionServer.grokQuotaFetchTimeout <= 90)
    }

    // Reads the real Keychain and issues a real network fetch through the
    // semaphore bridge — OS integration a locked-down CI runner cannot provide,
    // and which leaves a detached credential/network task running past the test
    // body. The pure cap arithmetic is covered by the waitBounded* tests above;
    // this end-to-end smoke runs on a developer machine only (CI-gated like the
    // other real-socket/subprocess/CLI integration tests).
    @Test(.enabled(if: ProcessInfo.processInfo.environment["CI"] == nil))
    func blockingQuotaFetchNeverHangsTheCallingThread() {
        // End-to-end smoke of the REAL static path `.live(...)` wires up
        // (blockingQuotaFetch → loadCredentialsBounded → runCommand/parse →
        // the semaphore bridge). Whatever credentials happen to exist on the
        // machine running this test, the call must return a terminal outcome
        // well inside the bounded caps (credentialReadTimeout + quotaFetchTimeout)
        // — never hang indefinitely the way the old unbounded `sem.wait()` could.
        let clock = ContinuousClock.now
        _ = MCPIntrospectionServer.blockingQuotaFetch()   // either outcome is fine; hanging is the failure
        let elapsed = clock.duration(to: .now)
        #expect(elapsed < .seconds(40))        // < credentialReadTimeout + quotaFetchTimeout + slack
    }

    @Test func blockingQuotaFetchHonorsConsentBeforeCredentialReads() {
        let outcome = MCPIntrospectionServer.blockingQuotaFetch(
            configDirectory: URL(fileURLWithPath: "/definitely-not-readable"),
            consent: false)
        switch outcome {
        case .snapshot:
            Issue.record("quota must not fetch without consent")
        case .unavailable(let message):
            #expect(message == MCPIntrospectionServer.quotaConsentRequiredMessage)
        }
    }

    @Test func blockingCodexQuotaFetchHonorsConsentBeforeRolloutReads() async throws {
        let provider = MCPQuotaProbeProvider(result: .failure(.noRateLimits))
        let outcome = MCPIntrospectionServer.blockingCodexQuotaFetch(
            provider: provider, consent: false)
        #expect(await provider.calls() == 0)
        let json = try #require(toolJSON(call(server(
            codexQuota: outcome), "quota_windows")))
        let providers = try #require(json["providers"] as? [String: Any])
        let codex = try #require(providers["codex"] as? [String: Any])
        #expect(codex["available"] as? Bool == false)
        #expect(codex["status"] as? String == "consent not granted in trifola Settings")
        #expect((codex["windows"] as? [[String: Any]])?.isEmpty == true)
    }

    @Test func blockingCodexQuotaFetchReportsMissingRateLimitEvents() async {
        let provider = MCPQuotaProbeProvider(result: .failure(.noRateLimits))
        // Generous explicit timeout: this test pins the missing-rate-limits
        // path, not the deadline. CI runners lost the 2s default race.
        let outcome = MCPIntrospectionServer.blockingCodexQuotaFetch(
            provider: provider, consent: true,
            consentProvider: { true }, timeout: 30)
        #expect(await provider.calls() == 1)
        switch outcome {
        case .snapshot:
            Issue.record("a missing rate-limit event must not produce a snapshot")
        case .unavailable(let status):
            #expect(status == MCPIntrospectionServer.codexNoRecentRateLimitsMessage)
        }
    }

    @Test func blockingCodexQuotaFetchDiscardsAResultAfterConsentRevocation() {
        let consent = Locked(true)
        let provider = MCPConsentRevokingQuotaProvider {
            consent.withLock { $0 = false }
        }
        let outcome = MCPIntrospectionServer.blockingCodexQuotaFetch(
            provider: provider,
            consent: nil,
            consentProvider: { consent.withLock { $0 } },
            timeout: 30)
        switch outcome {
        case .snapshot:
            Issue.record("revoked consent must discard the late Codex snapshot")
        case .unavailable(let status):
            #expect(status == MCPIntrospectionServer.quotaConsentRequiredMessage)
        }
    }

    @Test func blockingGrokQuotaFetchHonorsConsentBeforeAuthRead() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("trifola-mcp-grok-consent-\(UUID().uuidString)",
                                    isDirectory: true)
        // No auth.json — but consent-off must not even try to read it for a
        // "no credentials" status; it returns the consent message.
        let transport = GrokMCPStubTransport { _ in
            Issue.record("transport must not be called without consent")
            return (Data(), HTTPURLResponse(
                url: GrokQuotaFetcher.endpoint, statusCode: 200,
                httpVersion: nil, headerFields: nil)!)
        }
        let outcome = MCPIntrospectionServer.blockingGrokQuotaFetch(
            configDirectory: root,
            transport: transport,
            consent: false)
        switch outcome {
        case .snapshot:
            Issue.record("grok must not fetch without consent")
        case .unavailable(let message):
            #expect(message == MCPIntrospectionServer.quotaConsentRequiredMessage)
        }
        let json = toolJSON(call(server(grokQuota: outcome), "quota_windows"))
        let providers = json?["providers"] as? [String: Any]
        let grok = providers?["grok"] as? [String: Any]
        #expect(grok?["available"] as? Bool == false)
        #expect(grok?["status"] as? String ==
                MCPIntrospectionServer.quotaConsentRequiredMessage)
    }

    @Test func blockingGrokQuotaFetchReturnsSuperGrokWindowViaStub() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("trifola-mcp-grok-ok-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let auth: [String: Any] = [
            "https://auth.x.ai::client": [
                "key": "xai-test-mcp-token",
                "expires_at": "2030-01-01T00:00:00Z",
            ],
        ]
        try JSONSerialization.data(withJSONObject: auth)
            .write(to: root.appendingPathComponent("auth.json"))

        let reset: UInt64 = 1_800_000_000
        var payload = Data()
        payload.append(0x0D)
        var bits = Float(42.5).bitPattern.littleEndian
        withUnsafeBytes(of: &bits) { payload.append(contentsOf: $0) }
        payload.append(0x10)
        var remaining = reset
        repeat {
            var byte = UInt8(remaining & 0x7F)
            remaining >>= 7
            if remaining != 0 { byte |= 0x80 }
            payload.append(byte)
        } while remaining != 0
        var frame = Data([0x00])
        let length = UInt32(payload.count).bigEndian
        withUnsafeBytes(of: length) { frame.append(contentsOf: $0) }
        frame.append(payload)
        let responseBody = frame

        let transport = GrokMCPStubTransport { _ in
            (responseBody, HTTPURLResponse(
                url: GrokQuotaFetcher.endpoint, statusCode: 200,
                httpVersion: nil, headerFields: nil)!)
        }
        let outcome = MCPIntrospectionServer.blockingGrokQuotaFetch(
            configDirectory: root,
            transport: transport,
            consent: true,
            consentProvider: { true },
            timeout: 30)
        switch outcome {
        case .snapshot(let snap):
            #expect(snap.weekly?.title == "SuperGrok")
            #expect(snap.weekly?.usedPercent == 42.5)
        case .unavailable(let status):
            Issue.record("expected snapshot, got \(status)")
        }

        let json = try #require(toolJSON(call(server(
            grokQuota: outcome), "quota_windows")))
        let providers = try #require(json["providers"] as? [String: Any])
        let grok = try #require(providers["grok"] as? [String: Any])
        #expect(grok["available"] as? Bool == true)
        #expect(grok["status"] as? String == "ok")
        let windows = try #require(grok["windows"] as? [[String: Any]])
        #expect(windows.first?["title"] as? String == "SuperGrok")
    }

    @Test func blockingGrokQuotaFetchDiscardsAResultAfterConsentRevocation() {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("trifola-mcp-grok-revoke-\(UUID().uuidString)",
                                    isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let auth: [String: Any] = [
            "https://auth.x.ai::client": [
                "key": "xai-test-revoke",
                "expires_at": "2030-01-01T00:00:00Z",
            ],
        ]
        try? JSONSerialization.data(withJSONObject: auth)
            .write(to: root.appendingPathComponent("auth.json"))

        let consent = Locked(true)
        let transport = GrokMCPStubTransport { _ in
            consent.withLock { $0 = false }
            var payload = Data()
            payload.append(0x0D)
            var bits = Float(10).bitPattern.littleEndian
            withUnsafeBytes(of: &bits) { payload.append(contentsOf: $0) }
            var frame = Data([0x00])
            let length = UInt32(payload.count).bigEndian
            withUnsafeBytes(of: length) { frame.append(contentsOf: $0) }
            frame.append(payload)
            return (frame, HTTPURLResponse(
                url: GrokQuotaFetcher.endpoint, statusCode: 200,
                httpVersion: nil, headerFields: nil)!)
        }
        let outcome = MCPIntrospectionServer.blockingGrokQuotaFetch(
            configDirectory: root,
            transport: transport,
            consent: nil,
            consentProvider: { consent.withLock { $0 } },
            timeout: 30)
        switch outcome {
        case .snapshot:
            Issue.record("revoked consent must discard the late Grok snapshot")
        case .unavailable(let status):
            #expect(status == MCPIntrospectionServer.quotaConsentRequiredMessage)
        }
    }

    @Test func revokedConsentTakesPrecedenceOverACodexReadTimeout() {
        let consentReads = Locked(0)
        let outcome = MCPIntrospectionServer.blockingCodexQuotaFetch(
            provider: MCPDelayedQuotaProvider(),
            consent: nil,
            consentProvider: {
                consentReads.withLock { count in
                    count += 1
                    return count == 1
                }
            },
            timeout: 0.01)
        switch outcome {
        case .snapshot:
            Issue.record("revoked consent must win over a timed-out Codex read")
        case .unavailable(let status):
            #expect(status == MCPIntrospectionServer.quotaConsentRequiredMessage)
        }
    }
}

/// Injectable Grok transport for MCP blocking-fetch tests. Never hits the network.
private struct GrokMCPStubTransport: GrokQuotaHTTPTransport {
    let handler: @Sendable (URLRequest) async throws -> (Data, URLResponse)
    func data(for request: URLRequest) async throws -> (Data, URLResponse) {
        try await handler(request)
    }
}
