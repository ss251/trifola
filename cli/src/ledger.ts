// Combines skills.ts (the user-lane catalog) + transcripts.ts (the corpus
// scan) into the one finding this CLI prints — the TypeScript equivalent of
// wiring AuditReport.skillLedger (Audit.swift) + LessonMiner.deadSkillArchive's
// taxDollars formula (Ledger.swift) + AuditReport.cacheMissLeaders'
// leak/first-touch totals (Audit.swift) together for a single-shot CLI.

import type { Skill } from "./skills.js";
import type { CorpusStats } from "./transcripts.js";
import { resolvedRate, reSentContextDollarsOfUsage, firstTouchDollarsOfUsage } from "./pricing.js";

/**
 * ModelTier.sonnet.rates.inp ($/M input) from Models.swift — the FLAT tier
 * fallback rate, NOT the date-aware PricingCatalog rate for "claude-sonnet-5".
 * Ledger.swift's taxDollars formula deliberately prices the recurring dead-
 * skill tax at cache-READ (input x 0.10) of this flat mid-tier rate, not raw
 * input and not the top tier — see the taxDollars comment this ports
 * (commit 306cc88: "price dead-skill tax at cache-read rate").
 */
const SONNET_TIER_INPUT_RATE = 3;
const CACHE_READ_MULTIPLIER = 0.1;

export interface Finding {
  /** Catalog skills never explicit-fired (Skill tool_use OR slash command). */
  deadCount: number;
  /** Total user-lane catalog skills scanned. */
  catalogCount: number;
  /** Interactive (non-subagent) session transcripts scanned. */
  sessionCount: number;
  /** Recurring per-session prompt-tax cost of the dead skills' descriptions, API-equivalent USD. */
  taxUsd: number;
  /** Re-sent context billed as fresh input above the warm-cache floor, USD (never call this "leak" in output copy). */
  wastedUsd: number;
  /** Unavoidable cache-build cost (5m + 1h write slices), USD — shown separately, never summed with wastedUsd. */
  firstTouchUsd: number;
  /** Fleet-wide cache-hit rate, as a whole percent (0-100). */
  cacheHitRatePct: number;
  /** Total deduped billed-usage entries across the corpus — the "R reads" denominator behind cacheHitRatePct. */
  reads: number;
}

/** Rough token estimate for a description that rides every system prompt
 * (~4 chars/token). Mirrors AuditReport.estimateTokens — labeled "est."
 * everywhere it surfaces. */
function estimateDescriptionTokens(text: string): number {
  return Math.max(1, Math.floor(text.length / 4));
}

export function buildFinding(catalog: readonly Skill[], corpus: CorpusStats): Finding {
  const firedNames = corpus.skillFireCounts;
  const isFired = (sk: Skill): boolean => firedNames.has(sk.id) || firedNames.has(sk.name);

  const dead = catalog.filter((sk) => !isFired(sk));
  const deadCount = dead.length;
  const catalogCount = catalog.length;
  const deadPromptTaxTokens = dead.reduce((sum, sk) => sum + estimateDescriptionTokens(sk.description), 0);

  const sessionCount = corpus.sessionCount;
  const taxUsd =
    (deadPromptTaxTokens / 1_000_000) * (SONNET_TIER_INPUT_RATE * CACHE_READ_MULTIPLIER) * Math.max(sessionCount, 1);

  let wastedUsd = 0;
  let firstTouchUsd = 0;
  for (const [day, byModel] of corpus.usageByDayModel) {
    for (const [model, usage] of byModel) {
      const rate = resolvedRate(model, day);
      wastedUsd += reSentContextDollarsOfUsage(usage, rate);
      firstTouchUsd += firstTouchDollarsOfUsage(usage, rate);
    }
  }

  const totalUsage = corpus.totalUsage;
  const totalInput = totalUsage.inputTokens + totalUsage.cacheCreateTokens + totalUsage.cacheReadTokens;
  const cacheHitRatePct = totalInput > 0 ? Math.round((totalUsage.cacheReadTokens / totalInput) * 100) : 0;

  return {
    deadCount,
    catalogCount,
    sessionCount,
    taxUsd,
    wastedUsd,
    firstTouchUsd,
    cacheHitRatePct,
    reads: corpus.totalDedupedEntries,
  };
}
