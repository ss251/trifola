// Combines skills.ts (the user-lane catalog) + transcripts.ts (the corpus
// scan) into the one finding this CLI prints — the TypeScript equivalent of
// wiring AuditReport.skillLedger (Audit.swift) + LessonMiner.deadSkillArchive's
// taxDollars formula (Ledger.swift) + AuditReport.cacheMissLeaders'
// leak/first-touch totals (Audit.swift) together for a single-shot CLI.

import type { Skill } from "./skills.js";
import type { CorpusStats, ProviderNumbers } from "./transcripts.js";
import { costOfUsage, resolvedRate, reSentContextDollarsOfUsage, firstTouchDollarsOfUsage } from "./pricing.js";

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
  /** Claude sessions are the denominator for skill-catalog findings. */
  claudeSessionCount: number;
  /** Subagent transcript files scanned — disclosed next to the denominator, never blended. */
  subagentRunCount: number;
  /** Cumulative prompt-tax cost across the scanned interactive sessions. */
  taxUsd: number;
  /** Prompt-tax cost for one scanned session. */
  taxUsdPerSession: number;
  /** Total API-equivalent usage value across all deduped entries. */
  usageValueUsd: number;
  usageValueByProvider: ProviderNumbers<number>;
  totalInputTokensByProvider: ProviderNumbers<number>;
  usageEntriesByProvider: ProviderNumbers<number>;
  sessionsByProvider: ProviderNumbers<number>;
  subagentRunsByProvider: ProviderNumbers<number>;
  /** Fresh-input premium above an all-cache-read floor, USD. */
  freshInputPremiumUsd: number;
  /** Unavoidable cache-build cost (5m + 1h write slices), USD — shown separately, never summed with the premium. */
  firstTouchUsd: number;
  /** Fleet-wide cache-hit rate, as a whole percent (0-100). */
  cacheHitRatePct: number;
  /** Total input tokens behind cacheHitRatePct. */
  totalInputTokens: number;
  /** Total deduped billed-usage entries across the corpus. */
  usageEntries: number;
  /** Entries explicitly marked fast/batch (or another non-standard mode). */
  unsupportedPricingModeEntries: number;
  skippedCompressed: number;
  /** Sorted ids of the never-fired skills. LOCAL-ONLY detail: surfaced solely
   * behind `--list-dead` — never in the anonymized share card or default JSON. */
  deadNames: string[];
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
  const claudeSessionCount = corpus.sessionsByProvider.claude;
  const subagentRunCount = corpus.fileCount - corpus.sessionCount;
  const taxUsdPerSession = (deadPromptTaxTokens / 1_000_000) * (SONNET_TIER_INPUT_RATE * CACHE_READ_MULTIPLIER);
  const taxUsd = taxUsdPerSession * claudeSessionCount;

  let usageValueUsd = 0;
  let freshInputPremiumUsd = 0;
  let firstTouchUsd = 0;
  for (const [day, byModel] of corpus.usageByDayModel) {
    for (const [model, usage] of byModel) {
      const rate = resolvedRate(model, day);
      usageValueUsd += costOfUsage(usage, rate);
      freshInputPremiumUsd += reSentContextDollarsOfUsage(usage, rate);
      firstTouchUsd += firstTouchDollarsOfUsage(usage, rate);
    }
  }
  const usageValueByProvider: ProviderNumbers<number> = { claude: 0, codex: 0 };
  for (const provider of ["claude", "codex"] as const) {
    for (const [day, byModel] of corpus.usageByProviderDayModel[provider]) {
      for (const [model, usage] of byModel) {
        usageValueByProvider[provider] += costOfUsage(usage, resolvedRate(model, day));
      }
    }
  }

  const totalUsage = corpus.totalUsage;
  const totalInput = totalUsage.inputTokens + totalUsage.cacheCreateTokens + totalUsage.cacheReadTokens;
  const totalInputTokensByProvider: ProviderNumbers<number> = { claude: 0, codex: 0 };
  for (const provider of ["claude", "codex"] as const) {
    const usage = corpus.totalUsageByProvider[provider];
    totalInputTokensByProvider[provider] = usage.inputTokens + usage.cacheCreateTokens + usage.cacheReadTokens;
  }
  const cacheHitRatePct = totalInput > 0 ? Math.round((totalUsage.cacheReadTokens / totalInput) * 100) : 0;

  return {
    deadCount,
    catalogCount,
    sessionCount,
    claudeSessionCount,
    subagentRunCount,
    sessionsByProvider: { ...corpus.sessionsByProvider },
    subagentRunsByProvider: {
      claude: corpus.filesByProvider.claude - corpus.sessionsByProvider.claude,
      codex: corpus.filesByProvider.codex - corpus.sessionsByProvider.codex,
    },
    taxUsd,
    taxUsdPerSession,
    usageValueUsd,
    usageValueByProvider,
    totalInputTokensByProvider,
    usageEntriesByProvider: { ...corpus.usageEntriesByProvider },
    freshInputPremiumUsd,
    firstTouchUsd,
    cacheHitRatePct,
    totalInputTokens: totalInput,
    usageEntries: corpus.totalDedupedEntries,
    unsupportedPricingModeEntries: corpus.unsupportedPricingModeEntries,
    skippedCompressed: corpus.skippedCompressed,
    deadNames: dead.map((sk) => sk.id).sort(),
  };
}
