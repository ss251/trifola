import Foundation

// MARK: - SELF-INTROSPECTION MCP ENDPOINT (spree #4 — rauchg, RESEARCH_top_voices #20)
// "Give your agent the ability to introspect its past runs, spot inefficiencies,
// errors, redundant tool calls" (rauchg, Jul 3 2026 — shipped as `vc agent-runs`).
// This file is Mission Control's answer: a pure MCP protocol layer (JSON-RPC 2.0
// over stdio, protocol 2025-06-18) exposing the app's ALREADY-BUILT forensics —
// session brief, the context-tax gauge, reroute receipts, the day's cost split,
// and the real plan-quota windows — as tools a LIVE Claude Code session can call
// for self-diagnosis mid-run.
//
// DESIGN RULES (inherited house doctrine):
// - REUSE, never a second pricing/parsing path: every number a tool returns is
//   built by the SAME builders the GUI + `--selfcheck` use (`ContextTax.gauge`,
//   `Reroutes.build`, `OrchestratorHog.alert`, `SessionUsage.cost(rate:)` at
//   `PricingCatalog.resolvedRate`, `QuotaSnapshot.decode`). The MCP layer only
//   SERIALIZES; it computes nothing of its own.
// - Tolerant reader, strict writer: any garbage line gets a well-formed JSON-RPC
//   error (never a crash, never a malformed reply); notifications are absorbed
//   silently; unknown params are ignored. Every reply is a single line of
//   deterministic (sorted-keys) JSON.
// - No third-party deps — Foundation JSONSerialization only.
// - Source-safe: the server never mutates ~/.claude or external systems. The
//   shared session scanner does maintain an app-local index in Application Support.

/// Injected outcome of the one quota fetch — lets tests and the selfcheck run
/// the tool without a network (and lets the live path degrade gracefully).
public enum MCPQuotaOutcome: Sendable {
    case snapshot(QuotaSnapshot)
    case unavailable(String)
}

/// The stdio MCP server. NOT Sendable by design: it owns mutable provider
/// caches and is driven from exactly one thread (the `--mcp` read loop, or a
/// test). Handing it across isolation domains would be a bug, and the compiler
/// enforces that.
public final class MCPIntrospectionServer {

    public static let quotaConsentRequiredMessage =
        "Claude quota access is off. Enable it in Trifola Settings → Quota."

    // MARK: identity + protocol

    public static let serverName = "trifola"
    public static let serverVersion = ReleaseIdentity.version
    /// Latest revision this server speaks; also the fallback offer when the
    /// client requests a version we don't know (per the MCP version handshake).
    public static let latestProtocolVersion = "2025-06-18"
    /// Revisions we can answer verbatim — the handshake echoes the client's
    /// request when it is one of these.
    public static let supportedProtocolVersions: Set<String> =
        ["2025-06-18", "2025-03-26", "2024-11-05"]

    // MARK: providers

    private let sessionsProvider: () -> [SessionSummary]
    private let quotaProvider: () -> MCPQuotaOutcome
    private let now: () -> Date
    private let registeredSessionID: String?

    public init(sessions: @escaping () -> [SessionSummary],
                quota: @escaping () -> MCPQuotaOutcome,
                now: @escaping () -> Date = { Date() },
                registeredSessionID: String? = ProcessInfo.processInfo.environment["CLAUDE_SESSION_ID"]) {
        self.sessionsProvider = sessions
        self.quotaProvider = quota
        self.now = now
        let trimmed = registeredSessionID?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        self.registeredSessionID = trimmed?.isEmpty == false ? trimmed : nil
    }

    /// The live server the `--mcp` flag runs: corpus via the SAME cache-backed
    /// scan the GUI warm-starts from (re-scanned at most every `rescanInterval`
    /// so a chatty agent doesn't stat thousands of files per tool call), quota
    /// via the read-only credential + one GET (`ClaudeQuotaFetcher`).
    public static func live(
        paths: ClaudePaths = .process,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        registeredSessionID: String? = nil,
        rescanInterval: TimeInterval = 15
    ) -> MCPIntrospectionServer {
        let configRoot = paths.root
        let dir = paths.projects
        let injectedID = registeredSessionID
            ?? environment["CLAUDE_SESSION_ID"]
            ?? environment["TRIFOLA_SESSION_ID"]
        var cache: [SessionSummary] = []
        var scannedAt = Date.distantPast
        return MCPIntrospectionServer(
            sessions: {
                let t = Date()
                if cache.isEmpty || t.timeIntervalSince(scannedAt) >= rescanInterval {
                    cache = SessionStore.cachedScan(
                        dir, cacheURL: paths.sessionIndexCacheURL)
                    scannedAt = t
                }
                return cache
            },
            quota: { blockingQuotaFetch(configDirectory: configRoot) },
            registeredSessionID: injectedID)
    }

    /// How long the MCP path waits for the credential-file-or-keychain read.
    /// Bounded more tightly than the GUI-side candidate read because
    /// `security find-generic-password` runs on the server's
    /// one thread — a cross-app ACL prompt on that subprocess would otherwise
    /// wedge the whole stdio loop forever (plan 09).
    static let credentialReadTimeout: TimeInterval = 3
    /// How long the MCP path waits for the network fetch once credentials are
    /// in hand — past the fetcher's own ~30s network timeout, so a healthy
    /// slow network still succeeds, but a wedged fetch can't hang the server.
    static let quotaFetchTimeout: TimeInterval = 35

    /// The wait cap `blockingQuotaFetch` applies to its semaphore bridge,
    /// pulled out as a small pure/testable seam (plan 09 §4): `true` if the
    /// semaphore signaled before `timeout`, `false` on expiry. Not reachable
    /// through the tool's closure-injection seam (that seam replaces the
    /// whole quota provider, bypassing this wait entirely), so tests exercise
    /// it directly instead of driving the real semaphore bridge end-to-end.
    static func waitBounded(_ sem: DispatchSemaphore, timeout: TimeInterval) -> Bool {
        sem.wait(timeout: .now() + timeout) != .timedOut
    }

    /// Credential read + the one usage GET, bridged synchronously for the
    /// stdio loop. Reasons, never payloads (ClaudeQuota SECURITY doctrine);
    /// no credentials → a graceful `.unavailable`, never an error reply.
    /// Every blocking wait on this path is capped — see `credentialReadTimeout`
    /// / `quotaFetchTimeout` — so one hung fetch can never freeze the server.
    public static func blockingQuotaFetch(configDirectory: URL? = nil,
                                          consent: Bool? = nil) -> MCPQuotaOutcome {
        // Reading Trifola's own preference is safe; credential-file, Keychain,
        // and network work remain strictly beyond this explicit gate.
        let allowed = consent
            ?? AppPreferencesStore().load().claudeQuotaAccessEnabled
        guard allowed else { return .unavailable(quotaConsentRequiredMessage) }
        let candidates = ClaudeCredentialReader.loadCandidates(
            configDirectory: configDirectory,
            keychainTimeout: credentialReadTimeout)
        final class Box: @unchecked Sendable { var value: Result<ResolvedQuota, ClaudeQuotaError>? }
        let box = Box()
        let sem = DispatchSemaphore(value: 0)
        Task.detached {
            box.value = await ClaudeQuotaResolver.resolve(candidates: candidates)
            sem.signal()
        }
        guard waitBounded(sem, timeout: quotaFetchTimeout) else {
            return .unavailable("quota fetch timed out")
        }
        switch box.value {
        case .success(let resolved): return .snapshot(resolved.snapshot)
        case .failure(let err): return .unavailable(QuotaStore.describe(err))
        case nil: return .unavailable("fetch did not complete")
        }
    }

    // MARK: - the line loop (tolerant reader, strict writer)

    /// One line of the stdio transport in → zero or one single-line JSON reply
    /// out. nil = nothing to send (blank line, notification, or a client
    /// response echo). NEVER throws, NEVER crashes on malformed input.
    public func handleLine(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard let obj = (try? JSONSerialization.jsonObject(with: Data(trimmed.utf8))) as? [String: Any] else {
            return Self.encode(Self.errorReply(id: NSNull(), code: -32700, message: "Parse error: input is not a JSON object"))
        }
        guard let reply = handle(obj) else { return nil }
        return Self.encode(reply)
    }

    /// The parsed dispatch — public so tests and the selfcheck can drive the
    /// exact `--mcp` code path in-process.
    public func handle(_ obj: [String: Any]) -> [String: Any]? {
        let id = obj["id"]
        let hasID = id != nil && !(id is NSNull)
        guard let method = obj["method"] as? String else {
            // A response from the client (result/error) is absorbed; anything
            // else with an id is an invalid request.
            if obj["result"] != nil || obj["error"] != nil { return nil }
            return hasID ? Self.errorReply(id: id!, code: -32600, message: "Invalid Request: missing method") : nil
        }
        let params = obj["params"] as? [String: Any] ?? [:]
        guard hasID else { return nil }   // notification — absorbed, tolerant of any name

        switch method {
        case "initialize":
            return Self.reply(id: id!, result: initializeResult(params: params))
        case "ping":
            return Self.reply(id: id!, result: [:])
        case "tools/list":
            return Self.reply(id: id!, result: ["tools": Self.toolDescriptors()])
        case "tools/call":
            return toolsCall(id: id!, params: params)
        default:
            return Self.errorReply(id: id!, code: -32601, message: "Method not found: \(method)")
        }
    }

    private func initializeResult(params: [String: Any]) -> [String: Any] {
        let requested = params["protocolVersion"] as? String
        let version = requested.flatMap { Self.supportedProtocolVersions.contains($0) ? $0 : nil }
            ?? Self.latestProtocolVersion
        return [
            "protocolVersion": version,
            "capabilities": ["tools": [String: Any]()],
            "serverInfo": [
                "name": Self.serverName,
                "title": "trifola — session self-introspection",
                "version": Self.serverVersion,
            ],
            "instructions": "Forensics over this machine's Claude Code corpus, for agent self-diagnosis mid-run: "
                + "session_brief, context_tax (next-message warm/cold price + fresh-session advisor), reroutes "
                + "(silent model flips), cost_today (day spend by model + orchestrator-hog check), quota_windows "
                + "(real 5h/weekly plan limits). All costs are API-equivalent estimates at catalog rates, not your "
                + "plan bill. This server never mutates the Claude config root or external systems; it maintains an app-local "
                + "session index.",
        ]
    }

    // MARK: - tools/call

    private func toolsCall(id: Any, params: [String: Any]) -> [String: Any] {
        guard let name = params["name"] as? String else {
            return Self.errorReply(id: id, code: -32602, message: "tools/call requires params.name")
        }
        // Tolerant: arguments may be absent, or (some clients) flattened into params.
        let args = params["arguments"] as? [String: Any] ?? params

        func withSession(_ build: (SessionSummary, [SessionSummary]) -> [String: Any]) -> [String: Any] {
            let sessions = sessionsProvider()
            switch resolveSession(args, sessions: sessions) {
            case .error(let message): return Self.toolErrorReply(id: id, message: message)
            case .found(let s, let source):
                var payload = build(s, sessions)
                payload["resolved_session_id"] = s.id
                payload["session_resolution"] = source.rawValue
                return Self.toolReply(id: id, json: payload)
            }
        }

        switch name {
        case "session_brief": return withSession { s, _ in sessionBrief(s) }
        case "context_tax": return withSession { s, _ in contextTax(s) }
        case "reroutes": return withSession { s, all in reroutes(s, sessions: all) }
        case "cost_today": return Self.toolReply(id: id, json: costToday(sessionsProvider()))
        case "quota_windows": return Self.toolReply(id: id, json: quotaWindows())
        default:
            return Self.errorReply(id: id, code: -32602, message: "Unknown tool: \(name)")
        }
    }

    // MARK: session resolution (the "introspect YOURSELF" seam)

    enum SessionResolution {
        case found(SessionSummary, SessionResolutionSource)
        case error(String)
    }

    enum SessionResolutionSource: String {
        case argument
        case registered
        case newestOptIn = "newest_opt_in"
    }

    /// `session_id` accepts the transcript UUID, a unique prefix, or a
    /// transcript path (the basename is the id). Omission is safe only when the
    /// server has an explicitly registered session id. Falling back to the newest
    /// main session requires `use_newest: true` and is labeled in the response.
    func resolveSession(_ args: [String: Any], sessions: [SessionSummary]) -> SessionResolution {
        let raw = (args["session_id"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !raw.isEmpty else {
            if let registeredSessionID {
                return resolveSessionID(registeredSessionID, sessions: sessions,
                                        source: .registered)
            }
            guard args["use_newest"] as? Bool == true else {
                return .error("session_id is required unless the server was registered with a session identity; pass use_newest=true only when newest-session fallback is intentional")
            }
            let candidate = sessions.filter { !$0.isSubagent }
                .max { a, b in
                    let (la, lb) = (a.lastActivity ?? .distantPast, b.lastActivity ?? .distantPast)
                    return la != lb ? la < lb : a.id > b.id   // deterministic tiebreak
                }
            guard let s = candidate else {
                return .error("no main sessions found in the configured Claude projects directory")
            }
            return .found(s, .newestOptIn)
        }
        return resolveSessionID(raw, sessions: sessions, source: .argument)
    }

    private func resolveSessionID(
        _ raw: String,
        sessions: [SessionSummary],
        source: SessionResolutionSource
    ) -> SessionResolution {
        // A path form (contains "/") resolves by its basename minus ".jsonl".
        var key = raw
        if key.contains("/") { key = (key as NSString).lastPathComponent }
        if key.hasSuffix(".jsonl") { key = String(key.dropLast(".jsonl".count)) }

        if let exact = sessions.first(where: { $0.id == key }) {
            return .found(exact, source)
        }
        let prefixed = sessions.filter { $0.id.hasPrefix(key) }.sorted { $0.id < $1.id }
        if prefixed.count == 1 { return .found(prefixed[0], source) }
        if prefixed.count > 1 {
            let shown = prefixed.prefix(5).map(\.shortID).joined(separator: ", ")
            return .error("ambiguous session_id prefix \"\(key)\" — \(prefixed.count) matches (\(shown)\(prefixed.count > 5 ? ", …" : "")); pass more characters")
        }
        if let byPath = sessions.first(where: { $0.filePath == raw }) {
            return .found(byPath, source)
        }
        return .error("session \"\(raw)\" not found — pass the transcript UUID, a unique prefix, or its transcript path")
    }

    // MARK: - tool payloads (serialization ONLY — the builders are the app's own)

    func sessionBrief(_ s: SessionSummary) -> [String: Any] {
        let today = localDayKey(now())
        let model = PricingCatalog.normalize(s.model)
        return [
            "session_id": s.id,
            "short_id": s.shortID,
            "name": s.name.map { $0 as Any } ?? NSNull(),
            "handle": s.displayTitle,
            "project": s.project,
            "cwd": s.cwd,
            "transcript_path": s.filePath,
            "model": model.isEmpty ? "(unknown)" : model,
            "tier": s.tier.label,
            "live": isLive(s),
            "is_subagent": s.isSubagent,
            "last_activity": iso(s.lastActivity),
            "last_activity_ago_seconds": s.lastActivity.map { max(0, Int(now().timeIntervalSince($0))) as Any } ?? NSNull(),
            "message_count": s.messageCount,
            "assistant_turns": s.assistantTurnsByModel.values.reduce(0, +),
            "tool_calls": s.toolCalls,
            "file_edits": s.fileEdits,
            "context_weight_tokens": s.contextWeight,
            "context_heavy": s.isContextHeavy,
            "cache_hit_rate": frac(s.cacheHitRate),
            "cost_total_usd": usd(s.cost),
            "cost_today_usd": usd(s.cost(onDay: today)),
            "cost_per_message_usd": usd(s.costPerMessage),
            "note": "costs are API-equivalent estimates at catalog rates (\(PricingCatalog.current.sourceLabel)), not your plan bill",
        ]
    }

    func contextTax(_ s: SessionSummary) -> [String: Any] {
        let g = ContextTax.gauge(s, now: now())
        return [
            "session_id": g.id,
            "project": g.project,
            "model": g.modelID.isEmpty ? g.tier.label : g.modelID,
            "live": g.isLive,
            "context_weight_tokens": g.contextWeight,
            "cache_hit_rate": frac(g.cacheHitRate),
            "warm_next_message_usd": usd(g.warmPerMessage),
            "cold_next_message_usd": usd(g.coldPerMessage),
            "blended_next_message_usd": usd(g.blendedPerMessage),
            "tax_line": g.taxLine,
            "advisory": g.advisory,
            "advisor_line": g.advisorLine.map { $0 as Any } ?? NSNull(),
            "advisory_threshold_tokens": ContextTax.advisoryTokens,
            "semantics": "warm = the context rides a live prompt cache (cache-read rate); cold = the cache expired (>5 min idle, /compact, task switch) and the whole context re-bills as fresh input on the next turn",
        ]
    }

    func reroutes(_ s: SessionSummary, sessions: [SessionSummary]) -> [String: Any] {
        let report = Reroutes.build(sessions: sessions)
        let receipt = Reroutes.receipt(for: s)
        let silent = receipt?.silentFlips ?? []
        let today = localDayKey(now())
        let todayDay = report.days.first { $0.day == today }
        func directionLabel(_ f: ModelFlip) -> String {
            switch f.direction {
            case .downshift: return "downshift"
            case .upshift: return "upshift"
            case .lateral: return "lateral"
            }
        }
        return [
            "session_id": s.id,
            "project": s.project,
            "headline": receipt?.headline ?? "clean — no model flips recorded in this session",
            "silent_reroutes": silent.map { f -> [String: Any] in
                [
                    "from": f.fromModel,
                    "to": f.toModel,
                    "direction": directionLabel(f),
                    "day": f.day.isEmpty ? NSNull() : f.day,
                    "message_id": f.messageID.map { $0 as Any } ?? NSNull(),
                ]
            },
            "user_model_switches_excluded": receipt?.userSwitches ?? 0,
            "assistant_turns": receipt?.totalTurns ?? s.assistantTurnsByModel.values.reduce(0, +),
            "fleet_today": [
                "day": today,
                "silent_reroutes": todayDay?.count ?? 0,
                "pairs": todayDay?.byPair ?? [:],
            ],
            "fleet_trend_14d": report.trend(now: now()).map { ["day": $0.day, "count": $0.count] },
            "semantics": RerouteReport.semantics,
        ]
    }

    func costToday(_ sessions: [SessionSummary]) -> [String: Any] {
        let day = localDayKey(now())
        let catalog = PricingCatalog.current
        // The SAME per-(model, day) slice sum `--spend-by-model` prints and
        // `cost(onDay:)` folds — one pricing path, serialized.
        var byModel: [String: SessionUsage] = [:]
        // Synthetic / pre-W2 summaries carry NEITHER per-model-day NOR
        // per-tier-day breakdowns — they bypass this loop entirely, so
        // `cost_today` would silently under-report them (same drift
        // `cost(onDay:)` had to fix). Fold their whole session cost into
        // today's total when their lastActivity falls on this LOCAL day,
        // matching both `cost(onDay:)`'s fallback and BurnGovernor. A
        // session with usageByDay (tier-only) data is NOT synthetic — it is
        // priced correctly elsewhere via its own day, so it must not be
        // swept in here.
        var syntheticCost = 0.0
        for s in sessions {
            if s.usageByModelDay.isEmpty {
                if s.usageByDay.isEmpty, let la = s.lastActivity, localDayKey(la) == day {
                    syntheticCost += s.cost
                }
                continue
            }
            for (model, u) in s.usageByModelDay[day] ?? [:] {
                byModel[model] = (byModel[model] ?? SessionUsage()) + u
            }
        }
        var total = syntheticCost
        var rows: [(model: String, cost: Double, u: SessionUsage)] = []
        for (model, u) in byModel where u.total > 0 {
            let cost = u.cost(rate: catalog.resolvedRate(model: model, onDay: day))
            total += cost
            rows.append((model, cost, u))
        }
        if syntheticCost > 0 {
            // A single transparent row rather than silently folding it into
            // an existing model's total — a synthetic session has no model
            // split to attribute it to.
            rows.append((model: "(pre-upgrade)", cost: syntheticCost, u: SessionUsage()))
        }
        rows.sort { $0.cost != $1.cost ? $0.cost > $1.cost : $0.model < $1.model }
        let hog = OrchestratorHog.alert(sessions: sessions, day: day)
        return [
            "day": day,
            "total_usd": usd(total),
            "by_model": rows.map { r -> [String: Any] in
                [
                    "model": r.model.isEmpty ? "(unknown)" : r.model,
                    "usd": usd(r.cost),
                    "input_tokens": r.u.inputTokens,
                    "cache_read_tokens": r.u.cacheReadTokens,
                    "cache_create_tokens": r.u.cacheCreateTokens,
                    "output_tokens": r.u.outputTokens,
                ]
            },
            "orchestrator_hog_alert": hog.map { h -> Any in
                [
                    "session_id": h.sessionID,
                    "project": h.project,
                    "session_usd": usd(h.sessionCost),
                    "day_usd": usd(h.dayTotal),
                    "share": frac(h.share),
                    "advice": h.line,
                ]
            } ?? NSNull(),
            "pricing": catalog.sourceLabel,
            "note": "API-equivalent cost at catalog rates — an estimate, not your plan bill",
        ]
    }

    func quotaWindows() -> [String: Any] {
        switch quotaProvider() {
        case .unavailable(let reason):
            return [
                "available": false,
                "reason": reason,
                "note": "plan windows come from Claude Code's OAuth usage endpoint; the credential is read strictly read-only and this tool degrades gracefully without it",
            ]
        case .snapshot(let snap):
            let t = now()
            return [
                "available": true,
                "fetched_at": iso(snap.fetchedAt),
                "windows": snap.windows.map { w -> [String: Any] in
                    var d: [String: Any] = [
                        "title": w.title,
                        "used_percent": frac(w.usedPercent),
                    ]
                    if let r = w.resetsAt {
                        let runway = max(0, r.timeIntervalSince(t))
                        d["resets_at"] = iso(r)
                        d["reset_in_seconds"] = Int(runway)
                        d["reset_runway"] = fmtAgeShort(runway)
                    } else {
                        d["resets_at"] = NSNull()
                    }
                    return d
                },
                "note": "used_percent is the plan window actually enforced by Anthropic — the one real number in an app of API-equivalent estimates",
            ]
        }
    }

    // MARK: - tool descriptors

    static let sessionIDDescription =
        "Session id — the transcript UUID. Also accepts a unique id prefix or a transcript path. "
            + "TO INTROSPECT YOURSELF from a live Claude Code session: your session id is the UUID filename of your own transcript "
            + "under the configured projects directory; hooks receive it as `session_id`, and some harnesses export it as $CLAUDE_SESSION_ID. "
            + "Required unless the server registered an explicit session identity. Newest-session fallback is available only with use_newest=true and is disclosed in the result."

    public static func toolDescriptors() -> [[String: Any]] {
        func sessionSchema() -> [String: Any] {
            [
                "type": "object",
                "properties": [
                    "session_id": ["type": "string", "description": sessionIDDescription],
                    "use_newest": [
                        "type": "boolean",
                        "description": "Opt in to the newest main session only when no explicit or registered session id is available. The response identifies the resolved session.",
                    ],
                ],
                "required": [String](),
            ]
        }
        let emptySchema: [String: Any] = ["type": "object", "properties": [String: Any](), "required": [String]()]
        return [
            [
                "name": "session_brief",
                "title": "Session brief",
                "description": "One session's vitals: model, context weight, cost so far (total + today), message/turn/tool-call counts, live/idle state. "
                    + sessionIDDescription,
                "inputSchema": sessionSchema(),
            ],
            [
                "name": "context_tax",
                "title": "Context-tax gauge",
                "description": "What this session's NEXT message will re-send, priced warm (live prompt cache, cache-read rate) vs cold (cache expired, fresh-input rate) at the session's own model rates, plus the fresh-session advisor verdict (fires over 200k resent tokens/message). Use it mid-run to decide whether to keep going or start a fresh session. "
                    + sessionIDDescription,
                "inputSchema": sessionSchema(),
            ],
            [
                "name": "reroutes",
                "title": "Reroute receipts",
                "description": "Silent model flips for one session (mid-conversation model changes with no /model command between turns — the safety-classifier / fallback shape) plus today's fleet reroute count and the 14-day trend. Deliberate /model switches are listed but never counted. "
                    + sessionIDDescription,
                "inputSchema": sessionSchema(),
            ],
            [
                "name": "cost_today",
                "title": "Today's cost",
                "description": "Today's API-equivalent spend across the whole machine, split by model id (tokens + dollars at catalog rates), with the orchestrator-hog check (fires when one top-level session exceeds 80% of a ≥$20 day — the 'delegate to cheaper subagents' signal). Takes no arguments.",
                "inputSchema": emptySchema,
            ],
            [
                "name": "quota_windows",
                "title": "Plan quota windows",
                "description": "The REAL plan rate-limit windows (5-hour session window, weekly all-models, model-scoped weeklies) with percent used and reset runways, read from Claude Code's OAuth usage endpoint (credential read-only). Degrades gracefully to {available:false, reason} when no credentials are present. Takes no arguments.",
                "inputSchema": emptySchema,
            ],
        ]
    }

    // MARK: - JSON-RPC plumbing (strict writer)

    static func reply(id: Any, result: [String: Any]) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "result": result]
    }

    static func errorReply(id: Any, code: Int, message: String) -> [String: Any] {
        ["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]]
    }

    /// A successful tools/call carrying one compact-JSON text content block.
    static func toolReply(id: Any, json: [String: Any]) -> [String: Any] {
        reply(id: id, result: [
            "content": [["type": "text", "text": encode(json)]],
            "isError": false,
        ])
    }

    /// A tool-level failure (bad session id, …): per MCP this is a RESULT with
    /// isError so the model can read the message and retry — protocol errors
    /// (-32601/-32602) stay reserved for malformed requests.
    static func toolErrorReply(id: Any, message: String) -> [String: Any] {
        reply(id: id, result: [
            "content": [["type": "text", "text": message]],
            "isError": true,
        ])
    }

    /// Strict writer: deterministic single-line JSON (sorted keys, no escaped
    /// slashes). An unencodable object (impossible for our payloads, but never
    /// crash) degrades to "{}".
    static func encode(_ obj: [String: Any]) -> String {
        guard JSONSerialization.isValidJSONObject(obj),
              let data = try? JSONSerialization.data(withJSONObject: obj, options: [.sortedKeys, .withoutEscapingSlashes]),
              let s = String(data: data, encoding: .utf8) else { return "{}" }
        return s
    }

    // MARK: - small formatters (serialization detail only)

    private func isLive(_ s: SessionSummary) -> Bool {
        s.lastActivity.map { now().timeIntervalSince($0) < ContextTax.liveWindow } ?? false
    }

    private func iso(_ d: Date?) -> Any {
        guard let d else { return NSNull() }
        return isoFormatter.string(from: d)
    }

    private let isoFormatter: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    /// Dollars, rounded to 4 decimals — enough for a $0.0004 haiku message.
    /// NSDecimalNumber via the formatted string so the strict writer emits
    /// "0.2593", never the binary-double noise "0.25929999999999997".
    private func usd(_ v: Double) -> Any { decimal4(v) }
    /// Rates/shares, rounded to 4 decimals — same decimal-exact encoding.
    private func frac(_ v: Double) -> Any { decimal4(v) }

    private func decimal4(_ v: Double) -> Any {
        guard v.isFinite else { return 0 }
        return NSDecimalNumber(string: String(format: "%.4f", v),
                               locale: Locale(identifier: "en_US_POSIX"))
    }
}
