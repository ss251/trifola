import Foundation

// MARK: - Per-model pricing catalog (W2)
// Replaces flat per-TIER pricing with per-MODEL-ID rates seeded from Anthropic's
// own pricing docs (platform.claude.com/docs/en/about-claude/pricing, fetched
// 2026-07-06). The seed is AUTHORITATIVE: an optional models.dev refresh may ADD
// models we don't know about, but never overwrites a bundled row (Anthropic's
// docs are the source of truth; models.dev is the completeness net).
//
// Two rules the flat tiers couldn't express:
//  1. DATE-DEPENDENT rates — Sonnet 5 is $2/$10 through 2026-08-31 and $3/$15
//     from 2026-09-01; each message is priced by ITS OWN date (like CodexBar's
//     pricingDate), so a September transcript reprices itself.
//  2. The 5m/1h cache-write split — `usage.cache_creation.ephemeral_1h_input_tokens`
//     bills at 2× the input rate, the 5m slice at 1.25×. Lumping both at 1.25×
//     (the pre-W2 behavior) undercounted 1h-heavy days by ~1.6× on the write slice.

/// One resolved $/M-token rate card: fresh input, output, cache read (0.1×),
/// 5-minute cache write (1.25×) and 1-hour cache write (2×).
public struct ModelRate: Sendable, Hashable, Codable {
    public let input: Double
    public let output: Double
    public let cacheRead: Double
    public let cacheWrite5m: Double
    public let cacheWrite1h: Double

    public init(input: Double, output: Double, cacheRead: Double,
                cacheWrite5m: Double, cacheWrite1h: Double) {
        self.input = input
        self.output = output
        self.cacheRead = cacheRead
        self.cacheWrite5m = cacheWrite5m
        self.cacheWrite1h = cacheWrite1h
    }

    /// The standard Anthropic multipliers derived from a base (input, output)
    /// pair: cache read 0.1×, 5m write 1.25×, 1h write 2× the input rate.
    public init(input: Double, output: Double) {
        self.init(input: input, output: output, cacheRead: input * 0.10,
                  cacheWrite5m: input * 1.25, cacheWrite1h: input * 2)
    }

    /// Tier-fallback rate card for models the catalog doesn't know — the same
    /// numbers `ModelTier.rates` carried, with the standard cache multipliers.
    public init(tier: ModelTier) {
        let r = tier.rates
        self.init(input: r.inp, output: r.out)
    }
}

/// A model's pricing across effective-date eras. Most models have one era;
/// Sonnet 5 has two (intro through Aug 31 2026, standard from Sep 1 2026).
public struct ModelPricing: Sendable, Hashable, Codable {
    public struct Era: Sendable, Hashable, Codable {
        /// First LOCAL calendar day ("yyyy-MM-dd") this era applies to; nil =
        /// since forever. ISO day keys compare correctly as plain strings.
        public let fromDay: String?
        public let rate: ModelRate
        public init(fromDay: String?, rate: ModelRate) {
            self.fromDay = fromDay
            self.rate = rate
        }
    }

    /// Eras ascending by `fromDay`; the first era's `fromDay` is nil.
    public let eras: [Era]

    public init(eras: [Era]) { self.eras = eras }
    public init(rate: ModelRate) { self.eras = [Era(fromDay: nil, rate: rate)] }

    /// The rate in force on a given LOCAL day key ("yyyy-MM-dd"). nil/empty day
    /// (a message that carried no timestamp) resolves against TODAY — the most
    /// recent era is the best guess for undated usage.
    public func rate(onDay day: String?) -> ModelRate {
        let d = (day?.isEmpty == false) ? day! : localDayKey(Date())
        var current = eras.first?.rate ?? ModelRate(tier: .other)
        for era in eras {
            guard let from = era.fromDay else { current = era.rate; continue }
            if from <= d { current = era.rate }
        }
        return current
    }
}

/// The per-model-id pricing catalog: bundled provider-authoritative seed plus an
/// optional models.dev overlay (ADD-only) cached on disk by the refresh action.
public struct PricingCatalog: Sendable {
    /// Normalized model id → pricing (possibly multi-era).
    public let models: [String: ModelPricing]
    /// The seed's provenance date (Anthropic pricing docs fetch date).
    public static let bundledDate = "2026-07-06"
    /// When the optional models.dev refresh last succeeded; nil = seed only.
    public let refreshedAt: Date?
    /// How many models the refresh ADDED beyond the bundled seed.
    public let refreshedAdded: Int

    public init(models: [String: ModelPricing], refreshedAt: Date? = nil,
                refreshedAdded: Int = 0) {
        self.models = models
        self.refreshedAt = refreshedAt
        self.refreshedAdded = refreshedAdded
    }

    // MARK: normalization

    /// Canonical model id: lowercase, provider prefixes gone
    /// ("us.anthropic.claude-opus-4-8" → "claude-opus-4-8"), "@…" variant and
    /// "[1m]" context suffixes gone, trailing "-YYYYMMDD" date stamps gone
    /// ("claude-haiku-4-5-20251001" → "claude-haiku-4-5"). Mirrors CodexBar's
    /// normalizeClaudeModel so the two tools price the same rows identically.
    public static func normalize(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        var m = raw.lowercased().trimmingCharacters(in: .whitespaces)
        if let at = m.firstIndex(of: "@") { m = String(m[..<at]) }      // @default / @20250805
        if let br = m.firstIndex(of: "[") { m = String(m[..<br]) }      // [1m] long-context tag
        if let r = m.range(of: "claude-") { m = String(m[r.lowerBound...]) } // strips us.anthropic. etc.
        if m.hasPrefix("openai/") { m.removeFirst("openai/".count) }
        let tail = m.suffix(9)                                           // trailing -YYYYMMDD stamp
        if tail.count == 9, tail.first == "-", tail.dropFirst().allSatisfy(\.isNumber) {
            m = String(m.dropLast(9))
        }
        return m
    }

    // MARK: resolution

    /// The catalog rate for a model on a LOCAL day key, or nil if unknown.
    public func rate(model raw: String?, onDay day: String? = nil) -> ModelRate? {
        models[Self.normalize(raw)]?.rate(onDay: day)
    }

    /// The catalog rate, falling back to the model's TIER rate when the catalog
    /// doesn't know the id — unknown/alias models ("opus", "glm-4.7",
    /// "<synthetic>") keep pricing exactly as before W2.
    public func resolvedRate(model raw: String?, onDay day: String? = nil) -> ModelRate {
        rate(model: raw, onDay: day) ?? ModelRate(tier: ModelTier(raw: raw))
    }

    /// Human-readable provenance for every surface that shows a price.
    public var sourceLabel: String {
        guard let refreshedAt else { return "bundled \(Self.bundledDate)" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        return "bundled \(Self.bundledDate) + refreshed \(f.string(from: refreshedAt)) (+\(refreshedAdded) models)"
    }

    // MARK: bundled seed (Anthropic pricing docs, 2026-07-06 — AUTHORITATIVE)

    public static let bundled: PricingCatalog = {
        var m: [String: ModelPricing] = [:]
        func put(_ ids: [String], _ input: Double, _ output: Double) {
            let p = ModelPricing(rate: ModelRate(input: input, output: output))
            for id in ids { m[id] = p }
        }
        // Opus 4.8 / 4.7 / 4.6 / 4.5 — in 5, out 25, cr 0.50, cw5m 6.25, cw1h 10.
        put(["claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6", "claude-opus-4-5"], 5, 25)
        // Opus 4.1 / 4 (deprecated) — in 15, out 75, cr 1.50, cw5m 18.75, cw1h 30.
        put(["claude-opus-4-1", "claude-opus-4-0", "claude-opus-4"], 15, 75)
        // Sonnet 5 — DATE-DEPENDENT: $2/$10 through 2026-08-31, $3/$15 from 2026-09-01.
        m["claude-sonnet-5"] = ModelPricing(eras: [
            .init(fromDay: nil, rate: ModelRate(input: 2, output: 10)),
            .init(fromDay: "2026-09-01", rate: ModelRate(input: 3, output: 15)),
        ])
        // Sonnet 4.6 / 4.5 / 4 — in 3, out 15.
        put(["claude-sonnet-4-6", "claude-sonnet-4-5", "claude-sonnet-4-0", "claude-sonnet-4"], 3, 15)
        // Haiku 4.5 — in 1, out 5.
        put(["claude-haiku-4-5"], 1, 5)
        // Fable 5 — in 10, out 50, cr 1, cw5m 12.50, cw1h 20.
        put(["claude-fable-5"], 10, 50)
        // Haiku 3.5 — in 0.80, out 4, cr 0.08, cw5m 1, cw1h 1.60.
        put(["claude-3-5-haiku"], 0.80, 4)
        // Legacy generation (from the models.dev catalog CodexBar caches, for
        // completeness — date-stamped ids normalize onto these keys).
        put(["claude-3-7-sonnet", "claude-3-5-sonnet", "claude-3-sonnet"], 3, 15)
        put(["claude-3-opus"], 15, 75)
        put(["claude-3-haiku"], 0.25, 1.25)
        // OpenAI GPT-5 family. Cached input is 10% of fresh input, which the
        // two-argument ModelRate initializer derives. Codex rollout parsing
        // converts inclusive input into fresh + cache-read slices before cost.
        put(["gpt-5.6-sol"], 5, 30)
        put(["gpt-5.6-terra"], 2.5, 15)
        put(["gpt-5.6-luna"], 1, 6)
        put(["gpt-5.5"], 5, 30)
        put(["gpt-5.5-pro"], 30, 180)
        put(["gpt-5.4"], 2.5, 15)
        put(["gpt-5.4-mini"], 0.75, 4.5)
        put(["gpt-5.4-nano"], 0.20, 1.25)
        put(["gpt-5.4-pro"], 30, 180)
        put(["gpt-5.3-codex"], 1.75, 14)
        return PricingCatalog(models: m)
    }()

    // MARK: shared instance (bundled seed + on-disk models.dev overlay)

    /// The catalog every cost path prices against. Loaded lazily (bundled seed
    /// merged with the cached models.dev overlay if one exists); swapped by the
    /// optional refresh action. Reads are lock-protected snapshots.
    public static var current: PricingCatalog {
        currentBox.withLock { box in
            if box == nil { box = PricingCatalog.load() }
            return box!
        }
    }

    /// Swap the shared catalog (used by the refresh action; tests may inject).
    /// Bumps `generation`, which invalidates every precomputed
    /// `SessionCostBundle` — a stale bundle silently falls back to live
    /// per-slice pricing, so a catalog swap can never show stale dollars.
    public static func setCurrent(_ catalog: PricingCatalog) {
        currentBox.withLock { $0 = catalog }
        generationBox.withLock { $0 += 1 }
    }

    /// Monotonic catalog generation. Summaries stamp their precomputed cost
    /// bundle with the generation it was priced under; a mismatch means the
    /// catalog changed since, and the bundle must not be trusted.
    public static var generation: Int { generationBox.withLock { $0 } }

    private static let currentBox = Locked<PricingCatalog?>(nil)
    private static let generationBox = Locked<Int>(1)

    // MARK: on-disk overlay (the OPTIONAL models.dev refresh)

    /// Where the refresh caches its parsed models.dev rates. The app's OWN
    /// Application Support dir — never ~/.claude.
    public static var overlayURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Trifola/pricing.json")
    }

    struct OverlayFile: Codable {
        var fetchedAt: Date
        var models: [String: ModelRate]
    }

    /// Bundled seed + overlay merge. ADD-only: a bundled (Anthropic-authoritative)
    /// row is never overwritten by the overlay; unknown models are added. Missing
    /// or unreadable overlay ⇒ the bundled seed alone (offline is fully supported).
    public static func load(overlay url: URL = overlayURL) -> PricingCatalog {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(OverlayFile.self, from: data),
              !file.models.isEmpty else { return bundled }
        var models = bundled.models
        var added = 0
        for (id, rate) in file.models where models[id] == nil {
            models[id] = ModelPricing(rate: rate)
            added += 1
        }
        return PricingCatalog(models: models, refreshedAt: file.fetchedAt, refreshedAdded: added)
    }

    /// Parse models.dev's Anthropic and OpenAI blocks out of an api.json payload.
    /// Handles both the live shape (root[provider]["models"]) and CodexBar's
    /// cached wrapper (root["catalog"]["providers"][provider]["models"]). Rates
    /// the payload doesn't carry (the 1h write) derive from standard multipliers.
    public static func parseModelsDev(_ data: Data) -> [String: ModelRate] {
        guard let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return [:] }
        let providers = ((root["catalog"] as? [String: Any])?["providers"] as? [String: Any]) ?? root
        var out: [String: ModelRate] = [:]
        for providerID in ["anthropic", "openai"] {
            guard let provider = providers[providerID] as? [String: Any],
                  let models = provider["models"] as? [String: Any] else { continue }
            for (id, value) in models {
                guard let model = value as? [String: Any],
                      let cost = model["cost"] as? [String: Any],
                      let input = (cost["input"] as? NSNumber)?.doubleValue,
                      let output = (cost["output"] as? NSNumber)?.doubleValue else { continue }
                let cacheRead = (cost["cache_read"] as? NSNumber)?.doubleValue ?? input * 0.10
                let cw5m = (cost["cache_write"] as? NSNumber)?.doubleValue ?? input * 1.25
                let key = normalize(id)
                out[key] = ModelRate(input: input, output: output, cacheRead: cacheRead,
                                     cacheWrite5m: cw5m, cacheWrite1h: input * 2)
            }
        }
        return out
    }

    /// The OPTIONAL refresh: fetch models.dev, cache the parsed provider rates
    /// to `overlayURL`, and swap `current` to the merged catalog. Never required —
    /// offline/unfetched, the bundled seed is authoritative and nothing breaks.
    @discardableResult
    public static func refreshFromModelsDev() async throws -> PricingCatalog {
        let url = URL(string: "https://models.dev/api.json")!
        let (data, _) = try await URLSession.shared.data(from: url)
        let rates = parseModelsDev(data)
        guard !rates.isEmpty else {
            throw NSError(domain: "PricingCatalog", code: 1, userInfo: [
                NSLocalizedDescriptionKey: "models.dev payload had no supported provider rates"])
        }
        let file = OverlayFile(fetchedAt: Date(), models: rates)
        let out = try JSONEncoder().encode(file)
        try FileManager.default.createDirectory(at: overlayURL.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try out.write(to: overlayURL, options: .atomic)
        let merged = load()
        setCurrent(merged)
        return merged
    }
}
