// Port of Sources/TrifolaKit/Pricing.swift — the per-model, date-aware pricing
// catalog. Bundled seed is AUTHORITATIVE (Anthropic pricing docs, 2026-07-06);
// there is no models.dev overlay in the CLI (the Swift app's optional refresh
// path is out of scope for this MVP finding generator).
//
// Two rules a flat per-tier table can't express (same as the Swift source):
//  1. DATE-DEPENDENT rates — Sonnet 5 is $2/$10 through 2026-08-31 and $3/$15
//     from 2026-09-01; each message is priced by ITS OWN local calendar day.
//  2. The 5m/1h cache-write split — the 1h slice bills at 2x the input rate,
//     the 5m slice at 1.25x.

export interface ModelRate {
  readonly input: number;
  readonly output: number;
  readonly cacheRead: number;
  readonly cacheWrite5m: number;
  readonly cacheWrite1h: number;
}

/** The standard Anthropic multipliers derived from a base (input, output) pair. */
export function rateFromInputOutput(input: number, output: number): ModelRate {
  return {
    input,
    output,
    cacheRead: input * 0.1,
    cacheWrite5m: input * 1.25,
    cacheWrite1h: input * 2,
  };
}

interface Era {
  /** First LOCAL calendar day ("yyyy-MM-dd") this era applies to; null = since forever. */
  readonly fromDay: string | null;
  readonly rate: ModelRate;
}

interface ModelPricing {
  /** Eras ascending by fromDay; the first era's fromDay is null. */
  readonly eras: Era[];
}

function singleEra(rate: ModelRate): ModelPricing {
  return { eras: [{ fromDay: null, rate }] };
}

// MARK: - Bundled seed (Anthropic pricing docs, 2026-07-06 — AUTHORITATIVE)

const BUNDLED: Record<string, ModelPricing> = {};

function put(ids: string[], input: number, output: number): void {
  const pricing = singleEra(rateFromInputOutput(input, output));
  for (const id of ids) BUNDLED[id] = pricing;
}

// Opus 4.8 / 4.7 / 4.6 / 4.5 — in 5, out 25, cr 0.50, cw5m 6.25, cw1h 10.
put(["claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6", "claude-opus-4-5"], 5, 25);
// Opus 4.1 / 4 (deprecated) — in 15, out 75, cr 1.50, cw5m 18.75, cw1h 30.
put(["claude-opus-4-1", "claude-opus-4-0", "claude-opus-4"], 15, 75);
// Sonnet 5 — DATE-DEPENDENT: $2/$10 through 2026-08-31, $3/$15 from 2026-09-01.
BUNDLED["claude-sonnet-5"] = {
  eras: [
    { fromDay: null, rate: rateFromInputOutput(2, 10) },
    { fromDay: "2026-09-01", rate: rateFromInputOutput(3, 15) },
  ],
};
// Sonnet 4.6 / 4.5 / 4 — in 3, out 15.
put(["claude-sonnet-4-6", "claude-sonnet-4-5", "claude-sonnet-4-0", "claude-sonnet-4"], 3, 15);
// Haiku 4.5 — in 1, out 5.
put(["claude-haiku-4-5"], 1, 5);
// Legacy generation, for completeness — date-stamped ids normalize onto these.
put(["claude-3-7-sonnet", "claude-3-5-sonnet", "claude-3-sonnet"], 3, 15);
put(["claude-3-opus"], 15, 75);
put(["claude-3-haiku"], 0.25, 1.25);

// MARK: - Normalization

/**
 * Canonical model id: lowercase, provider prefixes gone
 * ("us.anthropic.claude-opus-4-8" -> "claude-opus-4-8"), "@..." variant and
 * "[1m]" context suffixes gone, trailing "-YYYYMMDD" date stamps gone.
 * Mirrors PricingCatalog.normalize so the CLI prices the same rows the
 * Swift app does.
 */
export function normalizeModel(raw: string | null | undefined): string {
  if (!raw) return "";
  let m = raw.toLowerCase().trim();
  const at = m.indexOf("@");
  if (at !== -1) m = m.slice(0, at);
  const br = m.indexOf("[");
  if (br !== -1) m = m.slice(0, br);
  const claudeIdx = m.indexOf("claude-");
  if (claudeIdx !== -1) m = m.slice(claudeIdx);
  if (m.length >= 9) {
    const tail = m.slice(-9);
    if (tail[0] === "-" && /^[0-9]{8}$/.test(tail.slice(1))) {
      m = m.slice(0, -9);
    }
  }
  return m;
}

function localDayKeyOf(d: Date): string {
  const y = d.getFullYear();
  const mo = String(d.getMonth() + 1).padStart(2, "0");
  const da = String(d.getDate()).padStart(2, "0");
  return `${y}-${mo}-${da}`;
}

/**
 * The rate in force on a given LOCAL day key ("yyyy-MM-dd"). A missing/empty
 * day (a message that carried no timestamp) resolves against TODAY — the
 * most recent era is the best guess for undated usage (matches
 * ModelPricing.rate(onDay:)).
 */
function rateOnDay(pricing: ModelPricing, day: string | null | undefined): ModelRate {
  const d = day && day.length > 0 ? day : localDayKeyOf(new Date());
  let current = pricing.eras[0]?.rate ?? tierFallbackRate("other");
  for (const era of pricing.eras) {
    if (era.fromDay === null) {
      current = era.rate;
      continue;
    }
    if (era.fromDay <= d) current = era.rate;
  }
  return current;
}

// MARK: - Tier fallback (models the bundled catalog doesn't know)

type Tier = "opus" | "sonnet" | "haiku" | "other";

function tierOf(raw: string | null | undefined): Tier {
  const r = (raw ?? "").toLowerCase();
  if (r.includes("opus")) return "opus";
  if (r.includes("sonnet")) return "sonnet";
  if (r.includes("haiku")) return "haiku";
  return "other";
}

// $/M tokens (in, out) — mirrors ModelTier.rates, the fallback for models the
// PricingCatalog doesn't know (bare aliases, third-party ids, "<synthetic>").
const TIER_RATES: Record<Tier, readonly [number, number]> = {
  opus: [5, 25],
  sonnet: [3, 15],
  haiku: [1, 5],
  other: [5, 25],
};

function tierFallbackRate(tier: Tier): ModelRate {
  const [input, output] = TIER_RATES[tier];
  return rateFromInputOutput(input, output);
}

/**
 * The catalog rate, falling back to the model's TIER rate when the catalog
 * doesn't know the id. `model` may be raw OR already-normalized (normalize
 * is idempotent); `day` is a "yyyy-MM-dd" local day key or nil/empty for
 * "today". Mirrors PricingCatalog.resolvedRate(model:onDay:).
 */
export function resolvedRate(model: string | null | undefined, day?: string | null): ModelRate {
  const normalized = normalizeModel(model);
  const pricing = BUNDLED[normalized];
  if (pricing) return rateOnDay(pricing, day);
  return tierFallbackRate(tierOf(model));
}

/** True when the bundled catalog recognizes this (already-normalized) model id. */
export function isKnownModel(normalizedModel: string): boolean {
  return normalizedModel in BUNDLED;
}

// MARK: - Usage math (mirrors SessionUsage's cost/cacheLeakDollars/firstTouchDollars)

export interface UsageTotals {
  inputTokens: number;
  outputTokens: number;
  /** TOTAL cache-creation tokens (5m + 1h slices). */
  cacheCreateTokens: number;
  cacheReadTokens: number;
  /** The 1-hour slice of cacheCreateTokens (billed 2x); the 5m slice is the remainder (1.25x). */
  cacheCreate1hTokens: number;
}

export function emptyUsage(): UsageTotals {
  return { inputTokens: 0, outputTokens: 0, cacheCreateTokens: 0, cacheReadTokens: 0, cacheCreate1hTokens: 0 };
}

export function addUsageInPlace(a: UsageTotals, b: UsageTotals): void {
  a.inputTokens += b.inputTokens;
  a.outputTokens += b.outputTokens;
  a.cacheCreateTokens += b.cacheCreateTokens;
  a.cacheReadTokens += b.cacheReadTokens;
  a.cacheCreate1hTokens += b.cacheCreate1hTokens;
}

function cache5mTokens(u: UsageTotals): number {
  return Math.max(0, u.cacheCreateTokens - u.cacheCreate1hTokens);
}

/** Total cost at an explicit rate card — fresh input, cache writes split 5m/1h, cache reads, output. */
export function costOfUsage(u: UsageTotals, rate: ModelRate): number {
  const fresh = (u.inputTokens / 1_000_000) * rate.input;
  const cw5m = (cache5mTokens(u) / 1_000_000) * rate.cacheWrite5m;
  const cw1h = (u.cacheCreate1hTokens / 1_000_000) * rate.cacheWrite1h;
  const cacheRead = (u.cacheReadTokens / 1_000_000) * rate.cacheRead;
  const out = (u.outputTokens / 1_000_000) * rate.output;
  return fresh + cw5m + cw1h + cacheRead + out;
}

/**
 * THE RE-SENT-CONTEXT FINDING (never call it "leak" in output copy) —
 * dollars billed because context was re-sent as FRESH input that a warm
 * cache would have served at the ~0.10x read rate. Cache creation is
 * deliberately NOT in here — that is firstTouchDollarsOfUsage, the
 * unavoidable cost of building the cache. Mirrors
 * SessionUsage.cacheLeakDollars(rate:).
 */
export function reSentContextDollarsOfUsage(u: UsageTotals, rate: ModelRate): number {
  return (u.inputTokens / 1_000_000) * (rate.input - rate.cacheRead);
}

/**
 * FIRST-TOUCH — what building the prompt cache actually cost (5m slice at
 * 1.25x, 1h slice at 2x). Unavoidable when the cache is genuinely cold;
 * shown separately, never summed into the re-sent-context figure. Mirrors
 * SessionUsage.firstTouchDollars(rate:).
 */
export function firstTouchDollarsOfUsage(u: UsageTotals, rate: ModelRate): number {
  const cw5m = cache5mTokens(u);
  return (cw5m / 1_000_000) * rate.cacheWrite5m + (u.cacheCreate1hTokens / 1_000_000) * rate.cacheWrite1h;
}

/** Fraction of input that came from cache (higher = cheaper). Mirrors SessionUsage.cacheHitRate. */
export function cacheHitRateOfUsage(u: UsageTotals): number {
  const totalInput = u.inputTokens + u.cacheCreateTokens + u.cacheReadTokens;
  return totalInput > 0 ? u.cacheReadTokens / totalInput : 0;
}
