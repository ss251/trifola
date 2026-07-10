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

private func server(quota: MCPQuotaOutcome = .unavailable("no credentials found (test)"),
                    sessions: [SessionSummary]? = nil) -> MCPIntrospectionServer {
    MCPIntrospectionServer(sessions: { sessions ?? corpus() }, quota: { quota }, now: { fixedNow })
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

    @Test func defaultResolvesMostRecentlyActiveMainNeverASubagent() {
        // The subagent is the most recent overall — the default must skip it.
        let json = toolJSON(call(server(), "session_brief"))
        #expect(json?["session_id"] as? String == "aaaa1111-0000-0000-0000-000000000001")
        #expect(json?["is_subagent"] as? Bool == false)
    }

    @Test func exactIDPrefixAndPathFormsResolve() {
        let srv = server()
        let byID = toolJSON(call(srv, "session_brief", args: #"{"session_id":"bbbb2222-0000-0000-0000-000000000002"}"#))
        #expect(byID?["project"] as? String == "p")
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

    @Test func quotaWindowsRoundTripAndDegradeGracefully() {
        // Canned snapshot through the REAL decoder seam (QuotaSnapshot.decode).
        let payload = #"{"five_hour":{"utilization":91.0,"resets_at":"2026-07-07T12:35:00Z"},"seven_day":{"utilization":40.5,"resets_at":"2026-07-10T00:00:00Z"},"limits":[{"kind":"weekly_scoped","group":"weekly","percent":12.0,"resets_at":"2026-07-10T00:00:00Z","is_active":false,"scope":{"model":{"id":"ghost","display_name":"Ghost"}}}]}"#
        let snap = QuotaSnapshot.decode(Data(payload.utf8), now: fixedNow)
        #expect(snap != nil)
        let json = toolJSON(call(server(quota: .snapshot(snap!)), "quota_windows"))
        #expect(json?["available"] as? Bool == true)
        let windows = json?["windows"] as? [[String: Any]]
        #expect(windows?.count == 3)
        #expect(windows?.first?["title"] as? String == "Session (5h)")
        #expect(windows?.first?["used_percent"] as? Double == 91.0)
        #expect(windows?.first?["reset_in_seconds"] as? Int == 35 * 60)
        #expect(windows?.first?["reset_runway"] as? String == "35m")
        #expect(windows?.last?["title"] as? String == "Ghost only")
        // No credentials → graceful {available:false, reason}, never an error.
        let degraded = toolJSON(call(server(), "quota_windows"))
        #expect(degraded?["available"] as? Bool == false)
        #expect((degraded?["reason"] as? String)?.contains("no credentials") == true)
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

    @Test func blockingQuotaFetchNeverHangsTheCallingThread() {
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
}
