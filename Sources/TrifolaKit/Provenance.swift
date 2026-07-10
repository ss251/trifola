import Foundation

// MARK: - COST PROVENANCE (W3) — "show the math" on every dollar
// A pure receipt builder over the SAME slices and the SAME rate resolution every
// headline dollar is computed from (`SessionSummary.reduceSlices` / `cost(onDay:)`
// / `perTierCostMap` / the audit's leak + overspend). A receipt only GROUPS the
// (model, day) slices into per-model legs — grouping reorders a sum, it never
// changes it — and each leg's dollars come from the SAME `SessionUsage` cost
// functions the headline calls. So an expanded receipt can never disagree with
// the number it explains. Rounding happens ONLY at the final Σ; leg lines print
// sub-cent precision so the arithmetic is checkable by hand.
//
// Pure value types + static builders — unit-testable without a store or the GUI.
// Evidence grammar: the receipt renders MONO everywhere (it is what the disk +
// the pricing catalog said), calm, no color drama (docs/POLISH.md II.C).

/// Which displayed number a receipt explains. Each metric prices the SAME
/// deduped slices with the same rates — only the formula differs, and each
/// formula is the exact one the headline uses.
public enum ReceiptMetric: String, Sendable, Equatable {
    case cost          // API-equiv cost (in + cache read + cw5m + cw1h + out)
    case cacheLeak     // fresh input × (input − cacheRead) — the avoidable leak
    case firstTouch    // cache creation (5m × 1.25, 1h × 2) — never a leak
    case mismatch      // frontier legs repriced at date-aware Sonnet 5

    public var label: String {
        switch self {
        case .cost: return "API-rate cost estimate"
        case .cacheLeak: return "fresh-vs-warm context price difference"
        case .firstTouch: return "cache setup (5m ×1.25 · 1h ×2 — necessary build work)"
        case .mismatch: return "cheaper-model price difference — frontier legs repriced at date-aware Sonnet 5"
        }
    }
}

/// One arithmetic line inside a leg: "input  2,194,627 × $5.00/M = $10.973135".
public struct ReceiptLine: Sendable, Equatable {
    public let label: String
    public let math: String
    public let dollars: Double
    public init(label: String, math: String, dollars: Double) {
        self.label = label
        self.math = math
        self.dollars = dollars
    }
}

/// One per-model leg: normalized model id · deduped message count · the deduped
/// token split × the exact rate (with its effective-date rule when the rate is
/// date-dependent) · the leg's dollars.
public struct ReceiptLeg: Identifiable, Sendable, Equatable {
    public var id: String { "\(model)|\(ruleNote ?? "")" }
    /// Display model id ("claude-opus-4-8"; "(unknown model)" for empty ids;
    /// "(Opus 4.8 tier fallback)" for pre-W2 summaries without per-model data).
    public let model: String
    /// The rate's rule when it isn't the plain catalog row: an effective-date
    /// era ("$2/$10 through 2026-08-31"), a tier fallback, or an unknown id.
    public let ruleNote: String?
    /// Deduped billed messages in this leg (0 = unknown, e.g. tier fallback).
    public let messages: Int
    /// LOCAL day keys this leg covers, sorted; "" (undated lines) sorts last
    /// and renders "undated".
    public let days: [String]
    public let usage: SessionUsage
    public let rate: ModelRate
    public let lines: [ReceiptLine]
    public let dollars: Double

    public init(model: String, ruleNote: String?, messages: Int, days: [String],
                usage: SessionUsage, rate: ModelRate, lines: [ReceiptLine], dollars: Double) {
        self.model = model
        self.ruleNote = ruleNote
        self.messages = messages
        self.days = days
        self.usage = usage
        self.rate = rate
        self.lines = lines
        self.dollars = dollars
    }

    /// "2026-07-05" · "2026-07-05, 2026-07-06" · "2026-06-08…2026-07-07 · 27 days".
    public var daysLabel: String {
        let named = days.map { $0.isEmpty ? "undated" : $0 }
        guard named.count > 3 else { return named.joined(separator: ", ") }
        return "\(named.first!)…\(named.last!) · \(named.count) days"
    }
}

/// The receipt: legs → Σ → provenance footers (pricing source · dedup ·
/// bucketing). `plainText` is the canonical mono rendering — the UI shows it
/// verbatim and "Copy" copies it, so what you see is exactly what you paste.
public struct CostReceipt: Sendable, Equatable {
    public let scope: String
    public let metric: ReceiptMetric
    public let legs: [ReceiptLeg]
    /// Σ legs — computed by the same cost functions as the headline, so it can
    /// never disagree with the displayed number (asserted in tests + selfcheck).
    public let total: Double
    public let pricingSource: String
    public let dedupNote: String
    public let bucketingNote: String
    public let footnotes: [String]

    public init(scope: String, metric: ReceiptMetric, legs: [ReceiptLeg], total: Double,
                pricingSource: String, dedupNote: String, bucketingNote: String,
                footnotes: [String] = []) {
        self.scope = scope
        self.metric = metric
        self.legs = legs
        self.total = total
        self.pricingSource = pricingSource
        self.dedupNote = dedupNote
        self.bucketingNote = bucketingNote
        self.footnotes = footnotes
    }

    /// The mono receipt, exactly as rendered + copied.
    public var plainText: String {
        var out: [String] = []
        out.append("RECEIPT — \(scope)")
        out.append("metric: \(metric.label)")
        out.append("")
        if legs.isEmpty {
            out.append("(no priced usage in this scope)")
        }
        for leg in legs {
            var head = leg.model
            if leg.messages > 0 { head += " · \(fmtGrouped(leg.messages)) msgs" }
            if !leg.days.isEmpty { head += " · \(leg.daysLabel)" }
            if let note = leg.ruleNote { head += " · \(note)" }
            out.append(head)
            for line in leg.lines {
                out.append("  \(pad(line.label, 15)) \(pad(line.math, 30)) = \(String(format: "$%.6f", line.dollars))")
            }
            out.append("  \(pad("= leg", 15)) \(pad("", 30)) = \(String(format: "$%.4f", leg.dollars))")
        }
        out.append("")
        out.append("Σ legs = \(String(format: "$%.2f", total))   (the displayed number — same code path, rounded only here)")
        out.append("pricing: \(pricingSource)")
        out.append("dedup:   \(dedupNote)")
        out.append("buckets: \(bucketingNote)")
        out.append(contentsOf: footnotes)
        return out.joined(separator: "\n")
    }

    private func pad(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
    }
}

// MARK: - The builder

public enum CostProvenance {

    // MARK: slices — the exact iteration the headline prices

    /// One (model, day) usage slice — or a per-tier fallback slice for
    /// summaries without per-message data. `slices(for:)` mirrors
    /// `SessionSummary.reduceSlices` exactly: same buckets, same fallback.
    public struct Slice: Sendable {
        public let model: String
        public let day: String
        public let usage: SessionUsage
        public let messages: Int
        public let fallbackTier: ModelTier?
        public init(model: String, day: String, usage: SessionUsage,
                    messages: Int = 0, fallbackTier: ModelTier? = nil) {
            self.model = model
            self.day = day
            self.usage = usage
            self.messages = messages
            self.fallbackTier = fallbackTier
        }
    }

    /// The finest slices a summary carries — EXACTLY what `reduceSlices`
    /// iterates, so a receipt built from these sums to the same dollars as
    /// `SessionSummary.cost` / `cacheLeakDollars` / `firstTouchDollars`.
    public static func slices(for s: SessionSummary) -> [Slice] {
        if !s.usageByModelDay.isEmpty {
            var out: [Slice] = []
            for (day, byModel) in s.usageByModelDay {
                for (model, u) in byModel {
                    out.append(Slice(model: model, day: day, usage: u,
                                     messages: s.messagesByModelDay[day]?[model] ?? 0))
                }
            }
            return out
        }
        // Pre-W2 / synthetic summaries: one tier-priced slice per tier — the
        // same fallback `reduceSlices` takes.
        return s.perTierUsage.map {
            Slice(model: "", day: "", usage: $0.value, messages: 0, fallbackTier: $0.key)
        }
    }

    /// The rate a slice is priced at — the SAME resolution the headline uses:
    /// tier fallback for pre-W2 slices, else the catalog's date-aware rate
    /// (an empty day resolves against today, matching `ModelPricing.rate`).
    public static func rate(for slice: Slice, catalog: PricingCatalog) -> ModelRate {
        if let t = slice.fallbackTier { return ModelRate(tier: t) }
        return catalog.resolvedRate(model: slice.model, onDay: slice.day)
    }

    // MARK: the core receipt

    struct LegKey: Hashable {
        let model: String
        let fallback: ModelTier?
        let rate: ModelRate
    }

    /// Build a receipt from slices: group by (model, rate) — a date-dependent
    /// model whose slices straddle a rate era splits into one leg PER ERA — and
    /// price each leg with the same `SessionUsage` formulas the headline calls.
    public static func receipt(scope: String, slices: [Slice],
                               metric: ReceiptMetric = .cost,
                               catalog: PricingCatalog = .current,
                               rawUsageBlocks: Int = 0, dedupedBlocks: Int = 0,
                               footnotes: [String] = []) -> CostReceipt {
        var grouped: [LegKey: (usage: SessionUsage, messages: Int, days: Set<String>)] = [:]
        for s in slices where s.usage.total > 0 {
            let r = rate(for: s, catalog: catalog)
            let key = LegKey(model: s.model, fallback: s.fallbackTier, rate: r)
            var g = grouped[key] ?? (SessionUsage(), 0, [])
            g.usage = g.usage + s.usage
            g.messages += s.messages
            g.days.insert(s.day)
            grouped[key] = g
        }
        var legs: [ReceiptLeg] = []
        for (key, g) in grouped {
            let (lines, dollars) = legLines(metric: metric, usage: g.usage, rate: key.rate)
            // Zero-dollar legs are noise on the leak/first-touch metrics (a leg
            // with only cache reads leaks nothing); on .cost every priced token
            // pile stays visible. Dropping a $0 leg never changes Σ.
            if metric != .cost && dollars == 0 { continue }
            legs.append(ReceiptLeg(
                model: displayModel(key),
                ruleNote: ruleNote(key: key, days: g.days, catalog: catalog),
                messages: g.messages,
                days: sortDays(g.days),
                usage: g.usage, rate: key.rate, lines: lines, dollars: dollars))
        }
        legs.sort { $0.dollars != $1.dollars ? $0.dollars > $1.dollars : $0.model < $1.model }
        let total = legs.reduce(0) { $0 + $1.dollars }
        return CostReceipt(
            scope: scope, metric: metric, legs: legs, total: total,
            pricingSource: pricingSource(catalog),
            dedupNote: dedupNote(raw: rawUsageBlocks, unique: dedupedBlocks),
            bucketingNote: bucketingNote(),
            footnotes: footnotes)
    }

    // MARK: convenience scopes (each mirrors its headline's exact aggregation)

    /// The whole corpus — the Overview hero / Spend "Est. total spend" number
    /// (Σ `SessionSummary.cost` over every session).
    public static func corpusReceipt(sessions: [SessionSummary],
                                     metric: ReceiptMetric = .cost,
                                     catalog: PricingCatalog = .current) -> CostReceipt {
        receipt(scope: "whole corpus — \(sessions.count) sessions",
                slices: sessions.flatMap(slices(for:)), metric: metric, catalog: catalog,
                rawUsageBlocks: sessions.reduce(0) { $0 + $1.rawUsageBlocks },
                dedupedBlocks: sessions.reduce(0) { $0 + $1.dedupedUsageBlocks })
    }

    /// One LOCAL calendar day — the Burn tile's "Today" number. Mirrors the
    /// burn governor's bucketing exactly: per-message-day slices when a summary
    /// carries them, else the whole session on its `lastActivity` day.
    public static func dayReceipt(sessions: [SessionSummary], dayKey day: String,
                                  catalog: PricingCatalog = .current,
                                  calendar: Calendar = .current,
                                  footnotes: [String] = []) -> CostReceipt {
        var sl: [Slice] = []
        for s in sessions {
            if s.usageByDay.isEmpty {
                // The governor's fallback: no per-message days → the whole
                // session buckets onto its lastActivity day (BurnGovernor.init).
                guard let la = s.lastActivity,
                      dayKey(for: la, calendar: calendar) == day else { continue }
                sl += slices(for: s)
            } else {
                for (model, u) in s.usageByModelDay[day] ?? [:] {
                    sl.append(Slice(model: model, day: day, usage: u,
                                    messages: s.messagesByModelDay[day]?[model] ?? 0))
                }
            }
        }
        return receipt(scope: "\(day) (local day)", slices: sl, catalog: catalog,
                       rawUsageBlocks: sessions.reduce(0) { $0 + $1.rawUsageBlocks },
                       dedupedBlocks: sessions.reduce(0) { $0 + $1.dedupedUsageBlocks },
                       footnotes: footnotes)
    }

    /// One display tier's all-time spend — the Spend-by-tier row. Mirrors
    /// `perTierCostMap` grouping: model slices land on `ModelTier(raw:)`,
    /// fallback slices on their own tier.
    public static func tierReceipt(sessions: [SessionSummary], tier: ModelTier,
                                   catalog: PricingCatalog = .current) -> CostReceipt {
        let sl = sessions.flatMap(slices(for:))
            .filter { ($0.fallbackTier ?? ModelTier(raw: $0.model)) == tier }
        return receipt(scope: "\(tier.label) tier — all time", slices: sl, catalog: catalog,
                       rawUsageBlocks: sessions.reduce(0) { $0 + $1.rawUsageBlocks },
                       dedupedBlocks: sessions.reduce(0) { $0 + $1.dedupedUsageBlocks })
    }

    /// One session, any metric — the Audit leak/first-touch receipts.
    public static func sessionReceipt(_ s: SessionSummary,
                                      metric: ReceiptMetric = .cost,
                                      catalog: PricingCatalog = .current) -> CostReceipt {
        receipt(scope: "\(s.project) — \(s.displayTitle)",
                slices: slices(for: s), metric: metric, catalog: catalog,
                rawUsageBlocks: s.rawUsageBlocks, dedupedBlocks: s.dedupedUsageBlocks)
    }

    /// The model-mismatch receipt: FRONTIER (opus/custom) legs at their own rate
    /// vs repriced at the date-aware Sonnet-5 rate. Leg dollars are the
    /// Σ-per-slice `max(0, actual − repriced)` — the EXACT loop
    /// `AuditReport.frontierOverspend` runs, including its tier fallback.
    public static func mismatchReceipt(_ s: SessionSummary,
                                       catalog: PricingCatalog = .current,
                                       fallbackDay: String? = nil) -> CostReceipt {
        struct Key: Hashable { let model: String; let own: ModelRate; let sonnet: ModelRate; let fallback: ModelTier? }
        var grouped: [Key: (usage: SessionUsage, messages: Int, days: Set<String>,
                            actual: Double, repriced: Double, over: Double)] = [:]
        func fold(_ key: Key, _ u: SessionUsage, _ messages: Int, _ day: String, a: Double, b: Double) {
            var g = grouped[key] ?? (SessionUsage(), 0, [], 0, 0, 0)
            g.usage = g.usage + u
            g.messages += messages
            g.days.insert(day)
            g.actual += a
            g.repriced += b
            g.over += max(0, a - b)      // per-slice clamp — matches frontierOverspend
            grouped[key] = g
        }
        if !s.usageByModelDay.isEmpty {
            for (day, byModel) in s.usageByModelDay {
                for (model, u) in byModel {
                    let t = ModelTier(raw: model)
                    guard t == .opus else { continue }
                    let own = catalog.resolvedRate(model: model, onDay: day)
                    let son = catalog.resolvedRate(model: "claude-sonnet-5", onDay: day)
                    fold(Key(model: model, own: own, sonnet: son, fallback: nil), u,
                         s.messagesByModelDay[day]?[model] ?? 0, day,
                         a: u.cost(rate: own), b: u.cost(rate: son))
                }
            }
        } else {
            for (t, u) in s.perTierUsage where t == .opus {
                let own = ModelRate(tier: t)
                let son = catalog.resolvedRate(model: "claude-sonnet-5", onDay: fallbackDay)
                fold(Key(model: "", own: own, sonnet: son, fallback: t), u, 0, "",
                     a: u.cost(t), b: u.cost(rate: son))
            }
        }
        var legs: [ReceiptLeg] = []
        for (key, g) in grouped where g.over > 0 {
            let model = key.fallback.map { "(\($0.label) tier fallback)" }
                ?? (key.model.isEmpty ? "(unknown model)" : key.model)
            let sonnetRule = "claude-sonnet-5 \(fmtInOut(key.sonnet))"
            let lines = [
                ReceiptLine(label: "actual", math: "\(padLeft(fmtGrouped(g.usage.total), 13)) tokens @ own rates", dollars: g.actual),
                ReceiptLine(label: "repriced", math: "\(padLeft("", 13)) @ \(sonnetRule)", dollars: g.repriced),
            ]
            legs.append(ReceiptLeg(model: model,
                                   ruleNote: "overspend = Σ max(0, actual − repriced) per day slice",
                                   messages: g.messages, days: sortDays(g.days),
                                   usage: g.usage, rate: key.own, lines: lines, dollars: g.over))
        }
        legs.sort { $0.dollars != $1.dollars ? $0.dollars > $1.dollars : $0.model < $1.model }
        return CostReceipt(
            scope: "\(s.project) — \(s.displayTitle)", metric: .mismatch,
            legs: legs, total: legs.reduce(0) { $0 + $1.dollars },
            pricingSource: pricingSource(catalog),
            dedupNote: dedupNote(raw: s.rawUsageBlocks, unique: s.dedupedUsageBlocks),
            bucketingNote: bucketingNote(),
            footnotes: ["heuristic, not a verdict — legs already at or below Sonnet are never counted"])
    }

    /// The Burn tile's month-projection math, as a receipt footnote. The $
    /// figure IS `governor.monthProjection` (same code path); the mean formula
    /// is printed so the arithmetic is checkable.
    public static func projectionFootnote(_ g: BurnGovernor) -> String {
        guard g.runRateDays > 0 else {
            return "projection: no complete days yet — nothing to project"
        }
        let recent = g.days.dropLast().suffix(g.runRateDays)
            .map { String(format: "$%.2f", $0.cost) }
        return "projection: mean(last \(g.runRateDays) complete days: \(recent.joined(separator: ", "))) × 30 = \(String(format: "$%.2f", g.monthProjection))/mo"
    }

    // MARK: leg arithmetic (the same formulas the headline calls)

    /// The per-component lines + the leg total for a metric. The total is the
    /// SAME `SessionUsage` function the headline sums (`cost(rate:)` /
    /// `cacheLeakDollars(rate:)` / `firstTouchDollars(rate:)`) — never a
    /// re-derivation.
    static func legLines(metric: ReceiptMetric, usage u: SessionUsage,
                         rate r: ModelRate) -> ([ReceiptLine], Double) {
        func mtok(_ t: Int) -> Double { Double(t) / 1_000_000 }
        func line(_ label: String, _ tokens: Int, _ rateStr: String, _ dollars: Double) -> ReceiptLine {
            ReceiptLine(label: label, math: "\(padLeft(fmtGrouped(tokens), 13)) × \(rateStr)", dollars: dollars)
        }
        switch metric {
        case .cost:
            var lines: [ReceiptLine] = []
            if u.inputTokens > 0 {
                lines.append(line("input", u.inputTokens, fmtPerM(r.input), mtok(u.inputTokens) * r.input))
            }
            if u.cacheReadTokens > 0 {
                lines.append(line("cache read", u.cacheReadTokens, fmtPerM(r.cacheRead), mtok(u.cacheReadTokens) * r.cacheRead))
            }
            if u.cacheCreate5mTokens > 0 {
                lines.append(line("cache write 5m", u.cacheCreate5mTokens, fmtPerM(r.cacheWrite5m), mtok(u.cacheCreate5mTokens) * r.cacheWrite5m))
            }
            if u.cacheCreate1hTokens > 0 {
                lines.append(line("cache write 1h", u.cacheCreate1hTokens, fmtPerM(r.cacheWrite1h), mtok(u.cacheCreate1hTokens) * r.cacheWrite1h))
            }
            if u.outputTokens > 0 {
                lines.append(line("output", u.outputTokens, fmtPerM(r.output), mtok(u.outputTokens) * r.output))
            }
            return (lines, u.cost(rate: r))
        case .cacheLeak:
            let d = u.cacheLeakDollars(rate: r)
            return ([ReceiptLine(label: "fresh input",
                                 math: "\(padLeft(fmtGrouped(u.inputTokens), 13)) × (\(fmtPerM(r.input)) − \(fmtPerM(r.cacheRead)))",
                                 dollars: d)], d)
        case .firstTouch:
            var lines: [ReceiptLine] = []
            if u.cacheCreate5mTokens > 0 {
                lines.append(line("cache write 5m", u.cacheCreate5mTokens, fmtPerM(r.cacheWrite5m), mtok(u.cacheCreate5mTokens) * r.cacheWrite5m))
            }
            if u.cacheCreate1hTokens > 0 {
                lines.append(line("cache write 1h", u.cacheCreate1hTokens, fmtPerM(r.cacheWrite1h), mtok(u.cacheCreate1hTokens) * r.cacheWrite1h))
            }
            return (lines, u.firstTouchDollars(rate: r))
        case .mismatch:
            return ([], 0)   // built by mismatchReceipt (needs per-slice clamping)
        }
    }

    // MARK: labels + notes

    static func displayModel(_ key: LegKey) -> String {
        if let t = key.fallback { return "(\(t.label) tier fallback)" }
        return key.model.isEmpty ? "(unknown model)" : key.model
    }

    /// The rate's rule, when it has one: an effective-date era, a tier
    /// fallback, or an unknown-id fallback.
    static func ruleNote(key: LegKey, days: Set<String>, catalog: PricingCatalog) -> String? {
        if key.fallback != nil {
            return "flat tier rates — summary predates per-model data"
        }
        guard let pricing = catalog.models[PricingCatalog.normalize(key.model)] else {
            return "not in catalog — \(ModelTier(raw: key.model).label) tier fallback rates"
        }
        guard pricing.eras.count > 1 else { return nil }
        // All days in a leg share one rate (the group key); label that era.
        let day = days.sorted().last(where: { !$0.isEmpty }) ?? ""
        return eraLabel(pricing: pricing, onDay: day)
    }

    /// "$2/$10 through 2026-08-31" / "$3/$15 from 2026-09-01" — the effective-
    /// date rule for a date-dependent model (Sonnet 5). Mirrors
    /// `ModelPricing.rate(onDay:)`: an empty day resolves against today.
    static func eraLabel(pricing: ModelPricing, onDay day: String) -> String? {
        guard pricing.eras.count > 1 else { return nil }
        let d = day.isEmpty ? dayKey(for: Date()) : day
        var idx = 0
        for (i, era) in pricing.eras.enumerated() {
            guard let from = era.fromDay else { idx = i; continue }
            if from <= d { idx = i }
        }
        let era = pricing.eras[idx]
        let rates = fmtInOut(era.rate)
        if idx + 1 < pricing.eras.count, let next = pricing.eras[idx + 1].fromDay {
            return "\(rates) through \(dayBefore(next) ?? "…\(next)")"
        }
        if let from = era.fromDay { return "\(rates) from \(from)" }
        return nil
    }

    static func pricingSource(_ catalog: PricingCatalog) -> String {
        "Anthropic pricing — \(catalog.sourceLabel) · \(catalog.models.count) models"
    }

    static func dedupNote(raw: Int, unique: Int) -> String {
        guard raw > 0 || unique > 0 else {
            return "no per-message dedup data (synthetic summary)"
        }
        return "\(fmtGrouped(raw)) raw usage blocks → \(fmtGrouped(unique)) unique messageId:requestId (last-chunk-wins)"
    }

    static func bucketingNote() -> String {
        "per-message LOCAL calendar day (\(TimeZone.current.identifier)) · undated lines priced at today's rates"
    }

    // MARK: small helpers

    /// LOCAL "yyyy-MM-dd" day key for a date, in the given calendar's time
    /// zone — the inverse of `BurnGovernor.date(fromDayKey:)`.
    public static func dayKey(for date: Date, calendar: Calendar = .current) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    /// "2026-09-01" → "2026-08-31" (calendar-day arithmetic in UTC — day keys
    /// are timezone-less labels, so any fixed zone is correct here).
    static func dayBefore(_ day: String) -> String? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        guard let d = f.date(from: day) else { return nil }
        return f.string(from: d.addingTimeInterval(-86400))
    }

    /// Sorted day keys with "" (undated) last, not first.
    static func sortDays(_ days: Set<String>) -> [String] {
        days.sorted { a, b in
            if a.isEmpty { return false }
            if b.isEmpty { return true }
            return a < b
        }
    }

    /// "$5.00/M" — a rate leg's $/MTok label.
    static func fmtPerM(_ v: Double) -> String { String(format: "$%.2f/M", v) }

    /// "$2/$10" — an (input/output) rate pair with trailing zeros trimmed.
    static func fmtInOut(_ r: ModelRate) -> String {
        func trim(_ v: Double) -> String {
            v == v.rounded() ? String(format: "$%.0f", v) : String(format: "$%.2f", v)
        }
        return "\(trim(r.input))/\(trim(r.output))"
    }

    static func padLeft(_ s: String, _ n: Int) -> String {
        s.count >= n ? s : String(repeating: " ", count: n - s.count) + s
    }
}
