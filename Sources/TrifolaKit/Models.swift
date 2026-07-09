import Foundation

// MARK: - Model tiers

public enum ModelTier: String, CaseIterable, Sendable, Hashable, Codable {
    case opus, sonnet, haiku, user, other

    /// An OPTIONAL user-defined tier. Configure it with `configureUserTier(_:)` to
    /// route model ids that contain a lowercased substring (e.g. a third-party or
    /// fine-tuned family) into `.user` with a custom label + fallback rate. Left
    /// unset, `.user` is never matched by `init(raw:)` and stays inert.
    public struct UserTier: Sendable, Hashable {
        public var match: String
        public var label: String
        public var rate: (inp: Double, out: Double)
        public init(match: String, label: String = "Custom", rate: (inp: Double, out: Double) = (5, 25)) {
            self.match = match.lowercased()
            self.label = label
            self.rate = rate
        }
        public static func == (a: UserTier, b: UserTier) -> Bool {
            a.match == b.match && a.label == b.label && a.rate == b.rate
        }
        public func hash(into hasher: inout Hasher) {
            hasher.combine(match); hasher.combine(label)
            hasher.combine(rate.inp); hasher.combine(rate.out)
        }
    }

    private static let userTierBox = Locked<UserTier?>(nil)
    /// Configure (or clear) the optional user-defined tier. Thread-safe.
    public static func configureUserTier(_ tier: UserTier?) { userTierBox.withLock { $0 = tier } }
    /// The currently configured user-defined tier, if any.
    public static var userTier: UserTier? { userTierBox.withLock { $0 } }

    public init(raw: String?) {
        guard let r = raw?.lowercased() else { self = .other; return }
        if r.contains("opus") { self = .opus }
        else if r.contains("sonnet") { self = .sonnet }
        else if r.contains("haiku") { self = .haiku }
        else if let u = Self.userTier, !u.match.isEmpty, r.contains(u.match) { self = .user }
        else { self = .other }
    }

    public var label: String {
        switch self {
        case .opus: return "Opus"
        case .sonnet: return "Sonnet"
        case .haiku: return "Haiku"
        case .user: return ModelTier.userTier?.label ?? "Custom"
        case .other: return "Other"
        }
    }

    /// $/M tokens (in, out) — the FALLBACK rate for models the `PricingCatalog`
    /// doesn't know (bare aliases like "opus", third-party ids, "<synthetic>")
    /// and the display-grouping economics. Real pricing is per MODEL ID via
    /// `PricingCatalog`: Opus 4.8 = $5/$25 but Opus 4.1 = $15/$75, Sonnet 5 is
    /// date-dependent, etc. Cache multipliers for the fallback: read 0.10×,
    /// 5m write 1.25×, 1h write 2× (see `ModelRate(tier:)`).
    public var rates: (inp: Double, out: Double) {
        switch self {
        case .opus:   return (5, 25)    // Opus standard
        case .sonnet: return (3, 15)    // Sonnet
        case .haiku:  return (1, 5)     // Haiku
        case .user:   return ModelTier.userTier?.rate ?? (5, 25)
        case .other:  return (5, 25)
        }
    }
}

// MARK: - Session usage

public struct SessionUsage: Sendable, Hashable, Codable {
    public var inputTokens: Int
    public var outputTokens: Int
    /// TOTAL cache-creation tokens (5m + 1h slices) — the same field the API's
    /// `cache_creation_input_tokens` carries, so `totalInput`/`billedInput`
    /// keep their pre-W2 meaning.
    public var cacheCreateTokens: Int
    public var cacheReadTokens: Int
    /// The 1-hour slice of `cacheCreateTokens` (from
    /// `usage.cache_creation.ephemeral_1h_input_tokens`), billed at 2× the
    /// input rate — the 5m slice (`cacheCreateTokens − cacheCreate1hTokens`)
    /// bills at 1.25×. 0 when the transcript predates the sub-field.
    public var cacheCreate1hTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0,
                cacheCreateTokens: Int = 0, cacheReadTokens: Int = 0,
                cacheCreate1hTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.outputTokens = outputTokens
        self.cacheCreateTokens = cacheCreateTokens
        self.cacheReadTokens = cacheReadTokens
        self.cacheCreate1hTokens = cacheCreate1hTokens
    }

    // Tolerant decoding: summaries serialized before the 1h split (remote
    // mirrors, fixtures) read back with a zero 1h slice instead of failing.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        inputTokens = try c.decodeIfPresent(Int.self, forKey: .inputTokens) ?? 0
        outputTokens = try c.decodeIfPresent(Int.self, forKey: .outputTokens) ?? 0
        cacheCreateTokens = try c.decodeIfPresent(Int.self, forKey: .cacheCreateTokens) ?? 0
        cacheReadTokens = try c.decodeIfPresent(Int.self, forKey: .cacheReadTokens) ?? 0
        cacheCreate1hTokens = try c.decodeIfPresent(Int.self, forKey: .cacheCreate1hTokens) ?? 0
    }

    public var totalInput: Int { inputTokens + cacheCreateTokens + cacheReadTokens }
    public var total: Int { totalInput + outputTokens }
    /// Tokens you actually pay "fresh" input on (cache reads are ~10x cheaper).
    public var billedInput: Int { inputTokens + cacheCreateTokens }
    /// The 5-minute slice of cache creation (billed 1.25×).
    public var cacheCreate5mTokens: Int { max(0, cacheCreateTokens - cacheCreate1hTokens) }

    public static func + (a: SessionUsage, b: SessionUsage) -> SessionUsage {
        SessionUsage(
            inputTokens: a.inputTokens + b.inputTokens,
            outputTokens: a.outputTokens + b.outputTokens,
            cacheCreateTokens: a.cacheCreateTokens + b.cacheCreateTokens,
            cacheReadTokens: a.cacheReadTokens + b.cacheReadTokens,
            cacheCreate1hTokens: a.cacheCreate1hTokens + b.cacheCreate1hTokens
        )
    }

    /// Estimated USD cost at an explicit per-model rate card (the W2 path) —
    /// fresh input, cache writes split 5m/1h at their own multipliers, cache
    /// reads at the read rate, output at the output rate.
    public func cost(rate r: ModelRate) -> Double {
        let fresh = Double(inputTokens) / 1_000_000 * r.input
        let cw5m = Double(cacheCreate5mTokens) / 1_000_000 * r.cacheWrite5m
        let cw1h = Double(cacheCreate1hTokens) / 1_000_000 * r.cacheWrite1h
        let cacheRead = Double(cacheReadTokens) / 1_000_000 * r.cacheRead
        let out = Double(outputTokens) / 1_000_000 * r.output
        return fresh + cw5m + cw1h + cacheRead + out
    }

    /// Estimated USD cost at a TIER's fallback rate — for summaries without
    /// per-model data (synthetic/tests) and unknown model ids.
    public func cost(_ tier: ModelTier) -> Double { cost(rate: ModelRate(tier: tier)) }

    /// What the cache-read tokens WOULD have cost as fresh input, minus what
    /// they cost as cache reads — dollars prompt-caching saved on this usage.
    public func cacheSavings(rate r: ModelRate) -> Double {
        Double(cacheReadTokens) / 1_000_000 * (r.input - r.cacheRead)
    }

    /// Tier-fallback overload of `cacheSavings(rate:)`.
    public func cacheSavings(_ tier: ModelTier) -> Double {
        cacheSavings(rate: ModelRate(tier: tier))
    }

    /// THE LEAK — dollars billed because context was re-sent as FRESH input
    /// that a warm cache would have served at the ~0.10× read rate: fresh
    /// input × (input − cacheRead). Cache expiry (idle >5 min, `/compact`,
    /// task switches) makes some of this unavoidable, so it is ALWAYS shown
    /// next to `cacheHitRate` — the number names the leak, it does not claim
    /// it was all avoidable. Cache CREATION is deliberately NOT in here: that
    /// is `firstTouchDollars`, the unavoidable cost of building the cache.
    public func cacheLeakDollars(rate r: ModelRate) -> Double {
        Double(inputTokens) / 1_000_000 * (r.input - r.cacheRead)
    }

    /// FIRST-TOUCH — what building the prompt cache actually cost (the 5m
    /// slice at 1.25×, the 1h slice at 2×). Unavoidable when the cache is
    /// genuinely cold; shown separately from the leak, never summed into it.
    public func firstTouchDollars(rate r: ModelRate) -> Double {
        Double(cacheCreate5mTokens) / 1_000_000 * r.cacheWrite5m
            + Double(cacheCreate1hTokens) / 1_000_000 * r.cacheWrite1h
    }

    /// Fraction of input that came from cache (higher = cheaper, the caching lever).
    public var cacheHitRate: Double {
        totalInput > 0 ? Double(cacheReadTokens) / Double(totalInput) : 0
    }
}

// MARK: - Session cost bundle (priced once, read everywhere)

/// Every dollar figure a `SessionSummary` can be asked for, computed in ONE
/// pass over its finest usage slices — at summary-build time, off the main
/// actor, in the parallel scan. Before this existed, `cost`,
/// `perTierCostMap`, the burn governor's per-day buckets, and the audit's
/// leak/first-touch each re-walked `usageByModelDay` and re-resolved catalog
/// rates (string normalization per slice) on EVERY access — and the Overview
/// body alone made five such passes over 5.3k sessions per render, which was
/// measured at hundreds of ms of main-thread stall per heartbeat tick.
///
/// `generation` pins the `PricingCatalog` the bundle was priced under: a
/// catalog swap (models.dev refresh, test injection) bumps the global
/// generation, and a stale bundle silently falls back to the live per-slice
/// math — never a stale dollar.
public struct SessionCostBundle: Sendable, Hashable, Codable {
    public let generation: Int
    public let cost: Double
    /// Whole-session cost grouped by display tier (`perTierCostMap`).
    public let perTierCost: [ModelTier: Double]
    /// Day key → total cost billed that day (`cost(onDay:)`).
    public let costByDay: [String: Double]
    /// Day key → per-tier cost billed that day (`perTierCost(onDay:)`).
    public let tierCostByDay: [String: [ModelTier: Double]]
    public let cacheSavings: Double
    public let cacheLeak: Double
    public let firstTouch: Double

    public init(generation: Int, cost: Double, perTierCost: [ModelTier: Double],
                costByDay: [String: Double], tierCostByDay: [String: [ModelTier: Double]],
                cacheSavings: Double, cacheLeak: Double, firstTouch: Double) {
        self.generation = generation
        self.cost = cost
        self.perTierCost = perTierCost
        self.costByDay = costByDay
        self.tierCostByDay = tierCostByDay
        self.cacheSavings = cacheSavings
        self.cacheLeak = cacheLeak
        self.firstTouch = firstTouch
    }
}

// MARK: - Session summary (one .jsonl file)

public struct SessionSummary: Identifiable, Sendable, Hashable, Codable {
    public let id: String
    public let project: String
    public let cwd: String
    public let model: String?
    public let lastActivity: Date?
    public let messageCount: Int
    public let usage: SessionUsage
    /// Tokens resent on the most recent message — "what each new message costs you".
    public let contextWeight: Int
    /// Absolute path of the backing .jsonl transcript (empty for synthetic summaries).
    public let filePath: String
    /// The most recent human-typed prompt in this session (tool-result/meta lines
    /// excluded), or nil if none was found — the context line shown across the UI
    /// (palette, fleet board, session list).
    public let lastUserMessage: String?
    /// The session's NAME — the user's /rename value (live registry or history
    /// overlay) or the transcript's ai-title, nil when none exists. Rows lead
    /// with it; the project directory becomes the subtitle.
    public let name: String?
    /// Row title per the display contract: session name, else the short id.
    public var displayTitle: String { name ?? String(id.prefix(8)) }
    /// Usage attributed to the model that actually billed it, per message —
    /// NOT the whole session lumped onto whichever model happened to answer
    /// last. A long-running session that starts on Custom and gets bumped to
    /// Opus mid-way must not have its entire token pile priced at one rate.
    /// Empty for summaries built without per-message data (e.g. tests/synthetic
    /// sessions and pre-upgrade cache entries) — `tier`/`cost` fall back to the
    /// old whole-session behavior in that case.
    public let usageByTier: [ModelTier: SessionUsage]
    /// Deduped billed usage bucketed by the LOCAL calendar day each message
    /// landed on, then by the tier that billed it — so the burn governor can
    /// bucket each message by ITS OWN timestamp day instead of smearing a
    /// multi-day session's whole cost onto its `lastActivity` day. Empty for
    /// summaries built without per-message data (synthetic/pre-upgrade), which
    /// fall back to `lastActivity` bucketing.
    public let usageByDay: [String: [ModelTier: SessionUsage]]
    /// Deduped usage bucketed by NORMALIZED model id (W2) — the per-model view
    /// the `PricingCatalog` prices exactly (opus-4-8 ≠ opus-4-1 ≠ sonnet-5).
    /// Empty for summaries without per-message data → tier fallback pricing.
    public let usageByModel: [String: SessionUsage]
    /// Day key ("yyyy-MM-dd", "" = undated) → normalized model id → usage.
    /// The finest slice the cost paths price: each message's own model AND its
    /// own date (Sonnet 5's rate changes 2026-09-01, so the DATE matters).
    public let usageByModelDay: [String: [String: SessionUsage]]
    /// Day key → normalized model id → DEDUPED billed-message count — the
    /// receipt's "N msgs" per leg (W3 provenance). Parallel to
    /// `usageByModelDay`; empty for summaries built without per-message data.
    public let messagesByModelDay: [String: [String: Int]]
    /// How many RAW assistant usage blocks the transcript carried BEFORE the
    /// messageId:requestId dedup collapsed streaming chunks — the "N raw" side
    /// of the receipt's dedup note ("N raw → M unique, last-chunk-wins").
    /// 0 for synthetic/pre-W3 summaries.
    public let rawUsageBlocks: Int
    /// Explicit `Skill` tool invocations in this session, keyed by the `skill`
    /// argument → count. Feeds the dead-skill ledger (VISION 2.2). Labeled
    /// "explicit invocations" everywhere it surfaces: skills auto-loaded as
    /// context (no Skill tool call) are NOT counted, so this undercounts by
    /// design and stays honest about it.
    public let skillInvocations: [String: Int]
    /// Slash-command invocations (`<command-name>` transcript tags) in this
    /// session, keyed by name (no leading "/"; namespaced plugin names like
    /// "codex:rescue" kept intact) → count. A skill fired ONLY via a slash
    /// command emits no `Skill` tool_use, so the dead-skill ledger merges this
    /// with `skillInvocations` (task #41) rather than treating it as never-fired.
    /// CLI built-ins (`/model`, `/login`…) are counted too — the catalog join
    /// keeps them out of the dead-list math, not a hardcoded filter here.
    public let commandInvocations: [String: Int]
    /// Count of `Agent`/`Task` tool calls — the orchestration/fan-out signal.
    /// A heavy frontier session with zero Agent calls is shape-evidence of a
    /// single-thread task that a cheaper model could have done (VISION 2.3).
    public let agentCalls: Int
    /// Count of `Edit`/`Write`/`NotebookEdit`/`MultiEdit` tool calls — the
    /// "how much did this session actually touch" signal for model-mismatch.
    public let fileEdits: Int
    /// Model tiers ANY assistant message ran under (usage-independent) — the
    /// subagent-doctrine "did this run touch Custom?" signal. Empty for synthetic
    /// summaries, which fall back to per-tier usage / the model string.
    public let tiersSeen: Set<ModelTier>
    /// Assistant TURNS per NORMALIZED model id (W5) — every assistant message
    /// counted once (streaming chunks collapse), billed or not. The
    /// Opus-fallback detector's denominator: a session where BOTH custom-5 and
    /// opus-4-8 answered shows "N of M assistant turns ran on Opus". Empty for
    /// synthetic/pre-W5 summaries — the detector stays quiet without evidence.
    public let assistantTurnsByModel: [String: Int]
    /// TOTAL tool_use blocks in this session (any tool) — the shape signal the
    /// Custom-vs-Opus readout bands on (W5). 0 for synthetic/pre-W5 summaries.
    public let toolCalls: Int
    /// Mid-session model changes at assistant-turn boundaries (spree #2 —
    /// REROUTE RECEIPTS), captured positionally by the accumulator with the
    /// deliberate-/model-switch flag decided inline (a flip that followed a
    /// `/model` command line is `userInitiated` and never counted as a silent
    /// reroute). Empty for synthetic/pre-v13 summaries — the receipts stay
    /// honestly quiet without positional evidence.
    public let modelFlips: [ModelFlip]
    /// File paths this session's Write/Edit/NotebookEdit/MultiEdit calls
    /// touched, keyed by the NORMALIZED model id that made the call — deduped,
    /// first-write order, capped at 200/session (W5, the Custom Ledger's raw
    /// material). Empty for synthetic/pre-W5 summaries.
    public let filesTouchedByModel: [String: [String]]
    /// The machine this session ran on — "local" (this Mac) or a remote's config
    /// name ("workstation"). The Cross-Machine Fleet differentiator: a session always
    /// knows which machine it belongs to, so the Fleet Board, Attention, Overview,
    /// and every roll-up cover the WHOLE fleet, not half of it. Set at merge time
    /// (`FleetMerge`) from which source dir produced the summary; defaults to
    /// "local" so every existing call site (tests, local scans) is unchanged.
    public let machineID: String
    /// Precomputed dollar figures (one pricing pass at build time, off-main).
    /// nil for synthetic/memberwise-built summaries — every cost accessor then
    /// falls back to the live per-slice math, so tests and pre-bundle data are
    /// numerically unchanged. Stamped with the pricing-catalog generation.
    public let costBundle: SessionCostBundle?

    public init(id: String, project: String, cwd: String, model: String?,
                lastActivity: Date?, messageCount: Int, usage: SessionUsage,
                contextWeight: Int, filePath: String = "", lastUserMessage: String? = nil,
                name: String? = nil,
                usageByTier: [ModelTier: SessionUsage] = [:],
                usageByDay: [String: [ModelTier: SessionUsage]] = [:],
                usageByModel: [String: SessionUsage] = [:],
                usageByModelDay: [String: [String: SessionUsage]] = [:],
                messagesByModelDay: [String: [String: Int]] = [:],
                rawUsageBlocks: Int = 0,
                skillInvocations: [String: Int] = [:], commandInvocations: [String: Int] = [:],
                agentCalls: Int = 0, fileEdits: Int = 0,
                tiersSeen: Set<ModelTier> = [],
                assistantTurnsByModel: [String: Int] = [:], toolCalls: Int = 0,
                filesTouchedByModel: [String: [String]] = [:],
                modelFlips: [ModelFlip] = [],
                machineID: String = Machine.localID,
                costBundle: SessionCostBundle? = nil) {
        self.id = id
        self.project = project
        self.cwd = cwd
        self.model = model
        self.lastActivity = lastActivity
        self.messageCount = messageCount
        self.usage = usage
        self.contextWeight = contextWeight
        self.filePath = filePath
        self.lastUserMessage = lastUserMessage
        self.name = name
        self.usageByTier = usageByTier
        self.usageByDay = usageByDay
        self.usageByModel = usageByModel
        self.usageByModelDay = usageByModelDay
        self.messagesByModelDay = messagesByModelDay
        self.rawUsageBlocks = rawUsageBlocks
        self.skillInvocations = skillInvocations
        self.commandInvocations = commandInvocations
        self.agentCalls = agentCalls
        self.fileEdits = fileEdits
        self.tiersSeen = tiersSeen
        self.assistantTurnsByModel = assistantTurnsByModel
        self.toolCalls = toolCalls
        self.filesTouchedByModel = filesTouchedByModel
        self.modelFlips = modelFlips
        self.machineID = machineID
        self.costBundle = costBundle
    }

    // Tolerant decoding: summaries serialized before W2 (remote-mirror caches,
    // fixtures) read back with empty per-model maps → tier fallback pricing.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        project = try c.decode(String.self, forKey: .project)
        cwd = try c.decode(String.self, forKey: .cwd)
        model = try c.decodeIfPresent(String.self, forKey: .model)
        lastActivity = try c.decodeIfPresent(Date.self, forKey: .lastActivity)
        messageCount = try c.decode(Int.self, forKey: .messageCount)
        usage = try c.decode(SessionUsage.self, forKey: .usage)
        contextWeight = try c.decode(Int.self, forKey: .contextWeight)
        filePath = try c.decodeIfPresent(String.self, forKey: .filePath) ?? ""
        lastUserMessage = try c.decodeIfPresent(String.self, forKey: .lastUserMessage)
        name = try c.decodeIfPresent(String.self, forKey: .name)
        usageByTier = try c.decodeIfPresent([ModelTier: SessionUsage].self, forKey: .usageByTier) ?? [:]
        usageByDay = try c.decodeIfPresent([String: [ModelTier: SessionUsage]].self, forKey: .usageByDay) ?? [:]
        usageByModel = try c.decodeIfPresent([String: SessionUsage].self, forKey: .usageByModel) ?? [:]
        usageByModelDay = try c.decodeIfPresent([String: [String: SessionUsage]].self, forKey: .usageByModelDay) ?? [:]
        messagesByModelDay = try c.decodeIfPresent([String: [String: Int]].self, forKey: .messagesByModelDay) ?? [:]
        rawUsageBlocks = try c.decodeIfPresent(Int.self, forKey: .rawUsageBlocks) ?? 0
        skillInvocations = try c.decodeIfPresent([String: Int].self, forKey: .skillInvocations) ?? [:]
        commandInvocations = try c.decodeIfPresent([String: Int].self, forKey: .commandInvocations) ?? [:]
        agentCalls = try c.decodeIfPresent(Int.self, forKey: .agentCalls) ?? 0
        fileEdits = try c.decodeIfPresent(Int.self, forKey: .fileEdits) ?? 0
        tiersSeen = try c.decodeIfPresent(Set<ModelTier>.self, forKey: .tiersSeen) ?? []
        assistantTurnsByModel = try c.decodeIfPresent([String: Int].self, forKey: .assistantTurnsByModel) ?? [:]
        toolCalls = try c.decodeIfPresent(Int.self, forKey: .toolCalls) ?? 0
        filesTouchedByModel = try c.decodeIfPresent([String: [String]].self, forKey: .filesTouchedByModel) ?? [:]
        modelFlips = try c.decodeIfPresent([ModelFlip].self, forKey: .modelFlips) ?? []
        machineID = try c.decodeIfPresent(String.self, forKey: .machineID) ?? Machine.localID
        costBundle = try c.decodeIfPresent(SessionCostBundle.self, forKey: .costBundle)
    }

    /// This session tagged to a machine — the pure re-tag `FleetMerge` uses to stamp
    /// a remote mirror's sessions with their machine id. Everything else is copied
    /// verbatim; only the machine tag changes (a re-tag never changes what the
    /// session cost, so the bundle rides along).
    public func taggedWith(_ machineID: String) -> SessionSummary {
        SessionSummary(id: id, project: project, cwd: cwd, model: model,
                       lastActivity: lastActivity, messageCount: messageCount, usage: usage,
                       contextWeight: contextWeight, filePath: filePath,
                       lastUserMessage: lastUserMessage, name: name, usageByTier: usageByTier,
                       usageByDay: usageByDay,
                       usageByModel: usageByModel, usageByModelDay: usageByModelDay,
                       messagesByModelDay: messagesByModelDay, rawUsageBlocks: rawUsageBlocks,
                       skillInvocations: skillInvocations, commandInvocations: commandInvocations,
                       agentCalls: agentCalls,
                       fileEdits: fileEdits, tiersSeen: tiersSeen,
                       assistantTurnsByModel: assistantTurnsByModel, toolCalls: toolCalls,
                       filesTouchedByModel: filesTouchedByModel, modelFlips: modelFlips,
                       machineID: machineID,
                       costBundle: costBundle)
    }

    /// A copy of this summary with its `SessionCostBundle` computed — ONE pass
    /// over the finest usage slices producing every dollar figure the UI reads.
    /// Called at summary-build time (parallel scan / cache load, off-main); the
    /// per-slice math is byte-for-byte the same the live accessors run, so the
    /// bundle can never disagree with the fallback path.
    public func computingCostBundle() -> SessionSummary {
        var total = 0.0, savings = 0.0, leak = 0.0, firstTouch = 0.0
        var perTier: [ModelTier: Double] = [:]
        var costByDay: [String: Double] = [:]
        var tierByDay: [String: [ModelTier: Double]] = [:]
        if !usageByModelDay.isEmpty {
            let catalog = PricingCatalog.current
            for (day, byModel) in usageByModelDay {
                for (model, u) in byModel {
                    let r = catalog.resolvedRate(model: model, onDay: day)
                    let c = u.cost(rate: r)
                    total += c
                    savings += u.cacheSavings(rate: r)
                    leak += u.cacheLeakDollars(rate: r)
                    firstTouch += u.firstTouchDollars(rate: r)
                    costByDay[day, default: 0] += c
                    if c != 0 {
                        perTier[ModelTier(raw: model), default: 0] += c
                        tierByDay[day, default: [:]][ModelTier(raw: model), default: 0] += c
                    }
                }
            }
        } else {
            for (tier, u) in perTierUsage {
                let r = ModelRate(tier: tier)
                let c = u.cost(rate: r)
                total += c
                savings += u.cacheSavings(rate: r)
                leak += u.cacheLeakDollars(rate: r)
                firstTouch += u.firstTouchDollars(rate: r)
                if c != 0 { perTier[tier, default: 0] += c }
            }
            // Pre-W2 summaries carry only the tier-keyed day map — mirror the
            // `cost(onDay:)` / `perTierCost(onDay:)` fallback branches exactly.
            for (day, byTier) in usageByDay {
                for (tier, u) in byTier {
                    let c = u.cost(tier)
                    costByDay[day, default: 0] += c
                    if c != 0 { tierByDay[day, default: [:]][tier, default: 0] += c }
                }
            }
        }
        let bundle = SessionCostBundle(
            generation: PricingCatalog.generation, cost: total, perTierCost: perTier,
            costByDay: costByDay, tierCostByDay: tierByDay,
            cacheSavings: savings, cacheLeak: leak, firstTouch: firstTouch)
        return SessionSummary(id: id, project: project, cwd: cwd, model: model,
                              lastActivity: lastActivity, messageCount: messageCount, usage: usage,
                              contextWeight: contextWeight, filePath: filePath,
                              lastUserMessage: lastUserMessage, name: name, usageByTier: usageByTier,
                              usageByDay: usageByDay,
                              usageByModel: usageByModel, usageByModelDay: usageByModelDay,
                              messagesByModelDay: messagesByModelDay, rawUsageBlocks: rawUsageBlocks,
                              skillInvocations: skillInvocations, commandInvocations: commandInvocations,
                              agentCalls: agentCalls,
                              fileEdits: fileEdits, tiersSeen: tiersSeen,
                              assistantTurnsByModel: assistantTurnsByModel, toolCalls: toolCalls,
                              filesTouchedByModel: filesTouchedByModel, modelFlips: modelFlips,
                              machineID: machineID,
                              costBundle: bundle)
    }

    /// The precomputed bundle, iff it was priced under the CURRENT catalog.
    private var validBundle: SessionCostBundle? {
        guard let b = costBundle, b.generation == PricingCatalog.generation else { return nil }
        return b
    }

    /// True for a session mirrored from another machine (not this Mac).
    public var isRemote: Bool { machineID != Machine.localID }

    /// DEDUPED billed-usage block count (Σ over `messagesByModelDay`) — the
    /// "M unique messageId:requestId" side of the receipt's dedup note.
    public var dedupedUsageBlocks: Int {
        messagesByModelDay.values.reduce(0) { $0 + $1.values.reduce(0, +) }
    }

    /// The model that billed the most tokens in this session (billed input +
    /// output) — the honest "which tier is this session" answer for mixed-model
    /// sessions, where "last model to respond" silently mislabels the whole pile.
    /// Falls back to the last-seen `model` string when no per-tier data exists.
    public var tier: ModelTier {
        guard !usageByTier.isEmpty else { return ModelTier(raw: model) }
        return usageByTier.max { a, b in
            (a.value.billedInput + a.value.outputTokens) < (b.value.billedInput + b.value.outputTokens)
        }?.key ?? ModelTier(raw: model)
    }

    /// `usageByTier`, or (when empty) the whole-session usage attributed to
    /// `tier` — a single-key fallback map so callers can always iterate
    /// "usage per tier" without special-casing summaries that predate
    /// per-message attribution.
    public var perTierUsage: [ModelTier: SessionUsage] {
        usageByTier.isEmpty ? [tier: usage] : usageByTier
    }

    /// Reduce a metric over the FINEST usage slices this summary carries, each
    /// priced at its exact catalog rate: (model, day) slices when per-message
    /// data exists, otherwise one tier-priced slice per tier (the pre-W2
    /// fallback used by synthetic/test summaries). Every dollar figure on this
    /// type flows through here so they can never disagree about the rate.
    func reduceSlices(_ metric: (SessionUsage, ModelRate) -> Double) -> Double {
        if !usageByModelDay.isEmpty {
            let catalog = PricingCatalog.current
            var total = 0.0
            for (day, byModel) in usageByModelDay {
                for (model, u) in byModel {
                    total += metric(u, catalog.resolvedRate(model: model, onDay: day))
                }
            }
            return total
        }
        return perTierUsage.reduce(0) { $0 + metric($1.value, ModelRate(tier: $1.key)) }
    }

    /// Each (model, day) slice priced at ITS OWN catalog rate and summed — a
    /// mixed-model session never prices its whole token pile at one rate, and
    /// a Sonnet-5 message is priced by its own date ($2/$10 → $3/$15 on
    /// 2026-09-01). Falls back to per-tier rates without per-message data.
    /// Served from the build-time `costBundle` when it is current (the hot
    /// path); the live per-slice math below is the fallback + the reference.
    public var cost: Double {
        if let b = validBundle { return b.cost }
        return reduceSlices { $0.cost(rate: $1) }
    }

    /// API-equiv cost billed on a given LOCAL calendar day, each model slice
    /// priced at its own date-aware catalog rate. Zero if the session had no
    /// usage that day. Drives the burn governor's per-message-day bucketing.
    /// Falls back to the tier-keyed `usageByDay` for pre-W2 summaries.
    public func cost(onDay dayKey: String) -> Double {
        if let b = validBundle { return b.costByDay[dayKey] ?? 0 }
        if !usageByModelDay.isEmpty {
            let catalog = PricingCatalog.current
            return (usageByModelDay[dayKey] ?? [:]).reduce(0) {
                $0 + $1.value.cost(rate: catalog.resolvedRate(model: $1.key, onDay: dayKey))
            }
        }
        if !usageByDay.isEmpty {
            return (usageByDay[dayKey] ?? [:]).reduce(0) { $0 + $1.value.cost($1.key) }
        }
        // Synthetic / pre-W2 summary: no per-day breakdown at all — attribute
        // the whole session cost to lastActivity's LOCAL day (matches
        // BurnGovernor's inline fallback so every surface agrees on "today").
        if let la = lastActivity, localDayKey(la) == dayKey { return cost }
        return 0
    }

    /// Per-tier API-equiv cost billed on a given day — the day's model mix for
    /// one session, summed across sessions into the burn governor's day bucket.
    /// Cost is per-model catalog-priced; the TIER is only the display grouping.
    public func perTierCost(onDay dayKey: String) -> [ModelTier: Double] {
        if let b = validBundle { return b.tierCostByDay[dayKey] ?? [:] }
        var out: [ModelTier: Double] = [:]
        if !usageByModelDay.isEmpty {
            let catalog = PricingCatalog.current
            for (model, u) in usageByModelDay[dayKey] ?? [:] {
                let c = u.cost(rate: catalog.resolvedRate(model: model, onDay: dayKey))
                if c != 0 { out[ModelTier(raw: model), default: 0] += c }
            }
            return out
        }
        for (tier, u) in usageByDay[dayKey] ?? [:] {
            let c = u.cost(tier)
            if c != 0 { out[tier, default: 0] += c }
        }
        return out
    }

    /// Whole-session cost grouped by display tier, each model slice priced at
    /// its own catalog rate — what the spend-split bar and the routing audit
    /// sum ("Opus share" must not re-price Sonnet-5 tokens at a tier rate).
    public var perTierCostMap: [ModelTier: Double] {
        if let b = validBundle { return b.perTierCost }
        var out: [ModelTier: Double] = [:]
        if !usageByModelDay.isEmpty {
            let catalog = PricingCatalog.current
            for (day, byModel) in usageByModelDay {
                for (model, u) in byModel {
                    let c = u.cost(rate: catalog.resolvedRate(model: model, onDay: day))
                    if c != 0 { out[ModelTier(raw: model), default: 0] += c }
                }
            }
            return out
        }
        for (tier, u) in perTierUsage {
            let c = u.cost(tier)
            if c != 0 { out[tier, default: 0] += c }
        }
        return out
    }

    /// THE LEAK — dollars this session billed re-sending context as FRESH
    /// input above the warm-cache-read floor (VISION 2.1, the flagship AUDIT
    /// finding). First-touch cache creation is NOT in here — that is
    /// `firstTouchDollars`. Each slice priced at its exact catalog rate.
    public var cacheLeakDollars: Double {
        if let b = validBundle { return b.cacheLeak }
        return reduceSlices { $0.cacheLeakDollars(rate: $1) }
    }

    /// FIRST-TOUCH — what building this session's prompt caches actually cost
    /// (5m slice 1.25×, 1h slice 2×). Unavoidable cost of caching, shown
    /// beside the leak, never summed into it.
    public var firstTouchDollars: Double {
        if let b = validBundle { return b.firstTouch }
        return reduceSlices { $0.firstTouchDollars(rate: $1) }
    }

    /// Dollars prompt-caching saved this session (reads billed at the read
    /// rate instead of fresh input), per-model priced.
    public var cacheSavingsDollars: Double {
        if let b = validBundle { return b.cacheSavings }
        return reduceSlices { $0.cacheSavings(rate: $1) }
    }

    /// This session's cache-hit rate — the honest denominator shown beside the
    /// cache-miss dollars so the number never implies the whole leak was waste.
    public var cacheHitRate: Double { usage.cacheHitRate }

    public var isActive: Bool {
        guard let d = lastActivity else { return false }
        return Date().timeIntervalSince(d) < 15 * 60
    }

    /// The "$20 hey" risk: a heavy context means every trivial message is expensive.
    public var isContextHeavy: Bool { contextWeight > 200_000 }

    /// Estimated $ cost of the NEXT trivial message, given the context being resent.
    ///
    /// The context IS re-sent every turn, but on a warm prompt cache most of it
    /// bills at the ~0.1× cache-read rate, not the fresh-input rate. Pretending
    /// every token is a cache miss (the old flat-input math) overstated warm-
    /// session costs by up to 10×. Weight the two rates by this session's
    /// observed cache-hit rate instead — its own history is the best predictor
    /// of how the next turn will bill.
    public var costPerMessage: Double {
        let hit = usage.cacheHitRate
        let r = PricingCatalog.current.resolvedRate(model: model)
        let effectiveRate = r.input * (1 - hit) + r.cacheRead * hit
        return Double(contextWeight) / 1_000_000 * effectiveRate
    }

    /// Worst case: the prompt cache expired (≈5 min idle) and the entire
    /// context re-bills as fresh input on the next turn. This is the number the
    /// old `costPerMessage` reported for every turn.
    public var costPerMessageColdCache: Double {
        Double(contextWeight) / 1_000_000 * PricingCatalog.current.resolvedRate(model: model).input
    }

    /// Short display id (first hunk of the UUID).
    public var shortID: String { String(id.prefix(8)) }

    /// True for subagent transcripts (`<session>/subagents/agent-*.jsonl`).
    /// Their token spend is real, but they are not interactive sessions —
    /// nobody types a "$20 hey" into one — so context-weight surfaces skip them.
    /// Derived from the path so persisted caches decode unchanged.
    public var isSubagent: Bool { filePath.contains("/subagents/") }

    /// For a subagent, the id of its parent MAIN session — the join the Fleet
    /// Board uses to nest a subagent token under its parent. Subagent ids are
    /// minted as `"<parentSessionId>/<agent-stem>"` (see `SessionAccumulator`),
    /// so the parent id is everything before the first slash. nil for mains.
    /// A directory convention, not an authoritative process tree (VISION §5).
    public var parentSessionID: String? {
        guard isSubagent, let slash = id.firstIndex(of: "/") else { return nil }
        return String(id[..<slash])
    }
}

// MARK: - Session resume

/// Shell one-liner to resume a session in a terminal —
/// `cd '<cwd>' && claude --resume <id>` (cwd omitted when empty).
public enum SessionResume {
    public nonisolated static func command(sessionID: String, cwd: String) -> String {
        let resume = "claude --resume \(sessionID)"
        guard !cwd.isEmpty else { return resume }
        let escaped = cwd.replacingOccurrences(of: "'", with: "'\\''")
        return "cd '\(escaped)' && \(resume)"
    }
}

// MARK: - Per-tier rollup (for the spend-split bar)

public struct TierStat: Identifiable, Sendable {
    public var id: ModelTier { tier }
    public let tier: ModelTier
    public var tokens: Int
    public var cost: Double
    public var sessions: Int

    public init(tier: ModelTier, tokens: Int, cost: Double, sessions: Int) {
        self.tier = tier
        self.tokens = tokens
        self.cost = cost
        self.sessions = sessions
    }
}

// MARK: - Routing flag (the live fleet-audit surface)

public struct RoutingFlag: Identifiable, Sendable, Equatable {
    /// Stable identity (W6 wave 4): derived from content, never a fresh UUID — a
    /// recomputed-but-unchanged flag must not read as a brand-new row to SwiftUI
    /// (UUID identity made every refresh tear down and rebuild the flag list).
    public var id: String { title }
    public enum Level: Sendable, Equatable { case ok, info, warn }
    public let level: Level
    public let title: String
    public let detail: String

    public init(level: Level, title: String, detail: String) {
        self.level = level
        self.title = title
        self.detail = detail
    }
}

// MARK: - Formatting

public func fmtTokens(_ n: Int) -> String {
    if n >= 1_000_000_000 { return String(format: "%.1fB", Double(n) / 1_000_000_000) }
    if n >= 1_000_000 { return String(format: "%.1fM", Double(n) / 1_000_000) }
    if n >= 1_000 { return String(format: "%.1fk", Double(n) / 1_000) }
    return "\(n)"
}

// Shared: NumberFormatter construction is expensive and receipts call this per
// leg — read-only `string(from:)` on a configured formatter is thread-safe.
nonisolated(unsafe) private let groupedFormatter: NumberFormatter = {
    let f = NumberFormatter()
    f.numberStyle = .decimal
    f.locale = Locale(identifier: "en_US_POSIX")   // stable "," / "." everywhere
    f.usesGroupingSeparator = true                 // POSIX disables it by default
    f.groupingSeparator = ","
    f.groupingSize = 3
    return f
}()

/// Full integer with thousands separators ("2,194,627") — receipts print exact
/// token counts, never the compact "2.2M" (mono = what the disk said).
public func fmtGrouped(_ n: Int) -> String {
    groupedFormatter.string(from: NSNumber(value: n)) ?? "\(n)"
}

public func fmtUSD(_ v: Double) -> String {
    if v >= 1000 { return String(format: "$%.1fk", v / 1000) }
    if v >= 10 { return String(format: "$%.0f", v) }
    return String(format: "$%.2f", v)
}

public func fmtAgo(_ date: Date?) -> String {
    guard let date else { return "—" }
    let s = Int(Date().timeIntervalSince(date))
    if s < 60 { return "\(s)s ago" }
    if s < 3600 { return "\(s / 60)m ago" }
    if s < 86400 { return "\(s / 3600)h ago" }
    return "\(s / 86400)d ago"
}

public func fmtPct(_ v: Double) -> String {
    String(format: "%.0f%%", v * 100)
}

/// Compact age from a duration in seconds: "8s" / "3m" / "2h" — for dense chips
/// where "ago" would be noise.
public func fmtAgeShort(_ seconds: TimeInterval) -> String {
    let n = max(0, Int(seconds))
    if n < 60 { return "\(n)s" }
    if n < 3600 { return "\(n / 60)m" }
    if n < 86400 { return "\(n / 3600)h" }
    return "\(n / 86400)d"
}

/// Human duration from milliseconds: "13.7s" / "820ms".
public func fmtDuration(ms: Int) -> String {
    if ms >= 1000 { return String(format: "%.1fs", Double(ms) / 1000) }
    return "\(ms)ms"
}
