import Foundation

// MARK: - CONTEXT-TAX GAUGE + fresh-session advisor (spree #1 — the "$20 hey" killer)
// docs/RESEARCH_spree_synthesis.md re-ranked build queue, item 1: the loudest
// credit-era pain is one word ("hey") re-sending the whole context — 847k tokens
// on a single trivial message in the field report. The data is already parsed
// (`SessionSummary.contextWeight` = tokens resent on the most recent message);
// this file prices what the NEXT message will re-send, per LIVE session, at the
// session's OWN model rates:
//
//   • WARM — the context rides a live prompt cache and bills at the cache-read
//     rate (~0.10× input). The floor; a warm session is cheap to keep talking to.
//   • COLD — the cache expired (>5 min idle, /compact, task switch) and the whole
//     context re-bills as FRESH input on the next turn. The "$20 hey" case.
//
// Both use the same `PricingCatalog.resolvedRate(model:)` path as the receipt
// machinery (`costPerMessage` / `costPerMessageColdCache`), asserted equal in
// tests and in `--selfcheck` — the gauge can never disagree with the receipts.
//
// The ADVISOR is evidence, never a nag (Audit doctrine): it fires only for a
// LIVE session over an honest, VISIBLE threshold, names the threshold in its own
// copy, and shows both prices — it advises a fresh session, it does not demand one.

/// One session's context tax: what its next message re-sends, priced warm vs cold.
public struct ContextTaxGauge: Identifiable, Sendable, Hashable {
    public let id: String
    public let project: String
    public let shortID: String
    public let filePath: String
    public let tier: ModelTier
    /// Normalized model id the pricing resolved against (mono in the UI — disk
    /// truth); "" when the transcript carried no model (tier-fallback priced).
    public let modelID: String
    /// The session's working directory — carried through so the composition
    /// reader (plan 12) can locate a project CLAUDE.md without the UI needing
    /// the original `SessionSummary`. "" when the transcript carried none.
    public let cwd: String
    /// Tokens re-sent on the most recent message — the tax base.
    public let contextWeight: Int
    /// Next message ≈ this, if the prompt cache is WARM (cache-read rate).
    public let warmPerMessage: Double
    /// Next message ≈ this, if the cache went COLD (fresh-input rate) — the "$20 hey".
    public let coldPerMessage: Double
    /// Warm/cold weighted by this session's observed cache-hit rate — must equal
    /// `SessionSummary.costPerMessage` (the receipt-consistent blend).
    public let blendedPerMessage: Double
    /// The honest denominator shown beside the prices (how warm this session
    /// has actually been running).
    public let cacheHitRate: Double
    /// Active inside the live window at build time — the advisor speaks ONLY
    /// about live sessions (advising a dead session is a nag with no verb).
    public let isLive: Bool

    public init(id: String, project: String, shortID: String, filePath: String,
                tier: ModelTier, modelID: String, cwd: String = "", contextWeight: Int,
                warmPerMessage: Double, coldPerMessage: Double,
                blendedPerMessage: Double, cacheHitRate: Double, isLive: Bool) {
        self.id = id; self.project = project; self.shortID = shortID
        self.filePath = filePath; self.tier = tier; self.modelID = modelID
        self.cwd = cwd
        self.contextWeight = contextWeight
        self.warmPerMessage = warmPerMessage; self.coldPerMessage = coldPerMessage
        self.blendedPerMessage = blendedPerMessage
        self.cacheHitRate = cacheHitRate; self.isLive = isLive
    }

    /// The verdict, at the honest visible threshold: true when this context is
    /// past `ContextTax.advisoryTokens` — the same bar `isContextHeavy` uses
    /// everywhere else, so the app never has two opinions about "heavy".
    public var advisory: Bool { contextWeight > ContextTax.advisoryTokens }

    /// Gauge fill, normalized to the same full scale `ContextBar` has always
    /// used (400k) — one scale for "context weight" across the app.
    public var gaugeFraction: Double {
        min(1, Double(contextWeight) / Double(ContextTax.gaugeFullScale))
    }

    /// The one-line tax statement (shared by UI + selfcheck so the copy can't fork).
    public var taxLine: String {
        "next message ≈ \(fmtUSD(warmPerMessage)) warm / \(fmtUSD(coldPerMessage)) cold"
    }

    /// The advisor line — nil below the threshold. The threshold is IN the copy
    /// (an invisible threshold is a nag; a visible one is a measurement).
    public var advisorLine: String? {
        guard advisory else { return nil }
        return "fresh-session advised — \(fmtTokens(contextWeight)) tokens ride every message "
            + "(threshold \(fmtTokens(ContextTax.advisoryTokens))); "
            + "next ≈ \(fmtUSD(warmPerMessage)) warm, \(fmtUSD(coldPerMessage)) if the cache went cold"
    }
}

/// The live-pool rollup: every LIVE main session gauged, heaviest first by the
/// cold (worst-case) price, with the fleet's next-round totals.
public struct ContextTaxReport: Sendable, Equatable {
    /// Live mains with any context, sorted by cold per-message price desc
    /// (deterministic id tiebreak — equal rows must not flap between builds).
    public let live: [ContextTaxGauge]
    /// The subset over the advisory threshold — the sessions the advisor line
    /// actually appears on.
    public let advisories: [ContextTaxGauge]
    /// Σ warm next-message price across the live pool ("one more message to
    /// every live session costs ≈ this, warm").
    public let liveWarmTotal: Double
    /// Σ cold next-message price — the same round if every cache expired.
    public let liveColdTotal: Double

    public static let empty = ContextTaxReport(live: [], advisories: [],
                                               liveWarmTotal: 0, liveColdTotal: 0)

    public init(live: [ContextTaxGauge], advisories: [ContextTaxGauge],
                liveWarmTotal: Double, liveColdTotal: Double) {
        self.live = live; self.advisories = advisories
        self.liveWarmTotal = liveWarmTotal; self.liveColdTotal = liveColdTotal
    }

    /// The single heaviest live context (by tokens) — the headline session.
    public var heaviest: ContextTaxGauge? { live.max { $0.contextWeight < $1.contextWeight } }
}

public enum ContextTax {
    /// The advisory threshold — deliberately the SAME 200k bar as
    /// `SessionSummary.isContextHeavy` (one definition of "heavy", visible in
    /// the advisor copy). Strictly greater-than, matching `isContextHeavy`.
    public static let advisoryTokens = 200_000
    /// Gauge full scale — matches `ContextBar`'s long-standing 400k normalization.
    public static let gaugeFullScale = 400_000
    /// The live window — the same 15 minutes `SessionSummary.isActive` uses.
    public static let liveWindow: TimeInterval = 15 * 60

    /// Gauge ONE session — pure; prices `contextWeight` at the session's own
    /// model rates via the SAME `resolvedRate(model:)` call the receipt
    /// accessors use (undated → today's era, exactly like `costPerMessage`).
    public static func gauge(_ s: SessionSummary, now: Date = Date(),
                             catalog: PricingCatalog = .current) -> ContextTaxGauge {
        let r = catalog.resolvedRate(model: s.model)
        let weight = Double(s.contextWeight) / 1_000_000
        let hit = s.usage.cacheHitRate
        // The blend mirrors `costPerMessage` byte-for-byte: weight × the
        // hit-rate-weighted effective rate (NOT warm/cold recombined, so the
        // two paths cannot drift by floating-point association).
        let blended = weight * (r.input * (1 - hit) + r.cacheRead * hit)
        let live = s.lastActivity.map { now.timeIntervalSince($0) < liveWindow } ?? false
        return ContextTaxGauge(
            id: s.id, project: s.project, shortID: s.shortID, filePath: s.filePath,
            tier: s.tier, modelID: PricingCatalog.normalize(s.model), cwd: s.cwd,
            contextWeight: s.contextWeight,
            warmPerMessage: weight * r.cacheRead,
            coldPerMessage: weight * r.input,
            blendedPerMessage: blended,
            cacheHitRate: hit, isLive: live)
    }

    /// Build the live-pool report. Subagents are excluded — their spend is
    /// real, but nobody types a "$20 hey" into one (`isSubagent` doctrine);
    /// zero-context sessions carry no tax and are excluded too.
    public static func build(sessions: [SessionSummary], now: Date = Date(),
                             catalog: PricingCatalog = .current) -> ContextTaxReport {
        var live: [ContextTaxGauge] = []
        for s in sessions where !s.isSubagent && s.contextWeight > 0 {
            let g = gauge(s, now: now, catalog: catalog)
            if g.isLive { live.append(g) }
        }
        live.sort {
            $0.coldPerMessage != $1.coldPerMessage
                ? $0.coldPerMessage > $1.coldPerMessage : $0.id < $1.id
        }
        return ContextTaxReport(
            live: live,
            advisories: live.filter(\.advisory),
            liveWarmTotal: live.reduce(0) { $0 + $1.warmPerMessage },
            liveColdTotal: live.reduce(0) { $0 + $1.coldPerMessage })
    }
}

// MARK: - CONTEXT COMPOSITION — where the resent tokens come from (plan 12)
// docs/RESEARCH_hn_spree.md action 3: the tax gauge above prices contextWeight
// as one undifferentiated blob. A large, controllable chunk of it is IDLE
// OVERHEAD the user can actually act on — a bloated CLAUDE.md reloaded every
// turn, and connected-but-unused MCP servers whose whole tool schema rides
// every turn. This section attributes contextWeight to those two named
// sources; everything left over is history (the irreducible transcript
// remainder). Every number here is a labeled "≈" ESTIMATE, never a measured
// token count — see `ContextFootprint`'s doc comments for the exact
// methodology behind each one.

/// A pure attribution of one `contextWeight` to its sources. Inputs are
/// injected (no I/O here — see `ContextFootprint` for the disk reads); all
/// three counts are clamped non-negative and `historyTokens` can never go
/// negative even when the CLAUDE.md + MCP estimate overshoots the real total
/// (an overshoot means the estimate is too coarse for this session, not that
/// history is negative tokens).
public struct ContextComposition: Sendable, Equatable {
    public let contextWeight: Int
    /// ≈ tokens from CLAUDE.md (global + project, byte-size heuristic).
    public let claudeMdTokens: Int
    /// ≈ tokens from connected-MCP tool schemas (server count × static estimate).
    public let mcpTokens: Int
    /// How many connected MCP servers fed `mcpTokens` — shown alongside it so
    /// the estimate reads as "N servers", not a bare, unexplained number.
    public let mcpServerCount: Int
    /// contextWeight − (claudeMd + mcp), floored at 0 — the transcript/history
    /// remainder; the one number in this struct that is NOT an estimate of a
    /// named source, it's whatever the estimate didn't claim.
    public let historyTokens: Int
    /// claudeMdTokens / contextWeight, clamped to [0, 1] (an estimate that
    /// overshoots the total reads as "100%", never ">100%" — the share is a
    /// bar-fill fraction, not a raw ratio).
    public let claudeMdShare: Double
    /// mcpTokens / contextWeight, clamped to [0, 1] — same doctrine as above.
    public let mcpShare: Double

    public init(contextWeight: Int, claudeMdTokens: Int, mcpTokens: Int, mcpServerCount: Int) {
        let cw = max(0, contextWeight)
        let claude = max(0, claudeMdTokens)
        let mcp = max(0, mcpTokens)
        self.contextWeight = cw
        self.claudeMdTokens = claude
        self.mcpTokens = mcp
        self.mcpServerCount = max(0, mcpServerCount)
        self.historyTokens = max(0, cw - claude - mcp)
        self.claudeMdShare = cw > 0 ? min(1, Double(claude) / Double(cw)) : 0
        self.mcpShare = cw > 0 ? min(1, Double(mcp) / Double(cw)) : 0
    }

    /// The evidence-grammar composition line, shared by UI + selfcheck + render
    /// so the copy can't fork between surfaces. Every number carries "≈" — this
    /// is an attribution over an estimate, never a measured breakdown.
    /// e.g. "≈4k CLAUDE.md · ≈26k in 4 idle MCP tools · ≈282k history"
    public var line: String {
        let mcpWord = mcpServerCount == 1 ? "idle MCP tool" : "idle MCP tools"
        return "≈\(fmtTokens(claudeMdTokens)) CLAUDE.md · "
            + "≈\(fmtTokens(mcpTokens)) in \(mcpServerCount) \(mcpWord) · "
            + "≈\(fmtTokens(historyTokens)) history"
    }
}

/// Read-only, injectable reader for the two on-disk footprints the composition
/// attributes tokens to. NEVER writes — every call below is a `FileManager`
/// read (`attributesOfItem` / `contents`). Paths are parameters (defaulted to
/// the real locations) so tests exercise fixtures instead of the user's own
/// `~/.claude`.
public enum ContextFootprint {
    /// Coarse text→token heuristic used app-wide for byte-only estimates:
    /// ≈4 bytes/token (rough English-prose average; Claude's real tokenizer is
    /// not run here — this is a size estimate, not a tokenization). Always
    /// surfaced with "≈"; this comment IS the whole methodology.
    public static let bytesPerToken = 4.0

    /// Field-observed static per-server estimate for a connected MCP server's
    /// tool-schema footprint (tool names + JSON-schema params + descriptions,
    /// resent whole on every turn once connected — the "idle overhead" HN
    /// spree action 3 surfaced). NOT a measurement: getting the exact number
    /// requires either the live handshake's tool list or Claude Code exposing
    /// a real per-session tool-schema token count (see plan's Maintenance
    /// notes — swap this constant out the day that ships, and drop the "≈").
    public static let tokensPerMCPServer = 6_500

    /// The real global CLAUDE.md path, injectable for tests.
    public static let defaultClaudeMdPath =
        ("~/.claude/CLAUDE.md" as NSString).expandingTildeInPath
    /// The real Claude Code config path — same file `MCPServersProbe` reads,
    /// one source of truth for "how many MCP servers are connected."
    public static let defaultMCPConfigPath =
        ("~/.claude.json" as NSString).expandingTildeInPath

    /// Sum on-disk byte sizes of the given CLAUDE.md paths → ≈token estimate.
    /// Missing/unreadable paths count as 0 bytes (no CLAUDE.md really is zero
    /// doctrine tax, not an error). Read-only: `attributesOfItem` only, and it
    /// is a `try?` — a permissions failure degrades to 0, it never throws or
    /// writes. Paths are de-duped after tilde-expansion first — a project
    /// whose cwd IS `~/.claude` would otherwise double-count the global file
    /// against itself (observed on the real corpus: a session with `cwd ==
    /// ~/.claude` supplies the same physical CLAUDE.md as both "global" and
    /// "project").
    public nonisolated static func claudeMdTokens(paths: [String],
                                                  fs: FileManager = .default) -> Int {
        let expanded = Set(paths.map { ($0 as NSString).expandingTildeInPath })
        let bytes = expanded.reduce(0) { total, path in
            guard let attrs = try? fs.attributesOfItem(atPath: path),
                  let size = attrs[.size] as? Int else { return total }
            return total + size
        }
        return Int(Double(bytes) / bytesPerToken)
    }

    /// Connected-MCP server count, parsed from `~/.claude.json` → `mcpServers`
    /// via the SAME `MCPConfig.parse` the shipped health probe uses — one
    /// parser, so the composition's server count can never disagree with the
    /// MCP-servers probe card. Read-only: `FileManager.contents` only.
    public nonisolated static func connectedMCPCount(configPath: String,
                                                      fs: FileManager = .default) -> Int {
        guard let data = fs.contents(atPath: (configPath as NSString).expandingTildeInPath)
        else { return 0 }
        return MCPConfig.parse(data).count
    }

    /// The composition's MCP inputs in one read: (server count, ≈tokens).
    public nonisolated static func mcpFootprint(configPath: String,
                                                fs: FileManager = .default)
        -> (count: Int, tokens: Int) {
        let n = connectedMCPCount(configPath: configPath, fs: fs)
        return (n, n * tokensPerMCPServer)
    }

    /// Build a full `ContextComposition` for one `contextWeight`: sums the
    /// given CLAUDE.md paths (caller supplies global + optional project path)
    /// and the connected-MCP estimate off `mcpConfigPath`. All I/O injectable.
    public nonisolated static func composition(contextWeight: Int,
                                                claudeMdPaths: [String],
                                                mcpConfigPath: String = defaultMCPConfigPath,
                                                fs: FileManager = .default) -> ContextComposition {
        let claude = claudeMdTokens(paths: claudeMdPaths, fs: fs)
        let mcp = mcpFootprint(configPath: mcpConfigPath, fs: fs)
        return ContextComposition(contextWeight: contextWeight, claudeMdTokens: claude,
                                  mcpTokens: mcp.tokens, mcpServerCount: mcp.count)
    }
}
