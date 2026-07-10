// Combines skills.ts (the user-lane catalog) + transcripts.ts (the corpus
// scan) into the one finding this CLI prints — the TypeScript equivalent of
// wiring AuditReport.skillLedger (Audit.swift) + LessonMiner.deadSkillArchive's
// taxDollars formula (Ledger.swift) + AuditReport.cacheMissLeaders'
// leak/first-touch totals (Audit.swift) together for a single-shot CLI.
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
/** Rough token estimate for a description that rides every system prompt
 * (~4 chars/token). Mirrors AuditReport.estimateTokens — labeled "est."
 * everywhere it surfaces. */
function estimateDescriptionTokens(text) {
    return Math.max(1, Math.floor(text.length / 4));
}
export function buildFinding(catalog, corpus) {
    const firedNames = corpus.skillFireCounts;
    const isFired = (sk) => firedNames.has(sk.id) || firedNames.has(sk.name);
    const dead = catalog.filter((sk) => !isFired(sk));
    const deadCount = dead.length;
    const catalogCount = catalog.length;
    const deadPromptTaxTokens = dead.reduce((sum, sk) => sum + estimateDescriptionTokens(sk.description), 0);
    const sessionCount = corpus.sessionCount;
    const taxUsdPerSession = (deadPromptTaxTokens / 1_000_000) * (SONNET_TIER_INPUT_RATE * CACHE_READ_MULTIPLIER);
    const taxUsd = taxUsdPerSession * sessionCount;
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
    const totalUsage = corpus.totalUsage;
    const totalInput = totalUsage.inputTokens + totalUsage.cacheCreateTokens + totalUsage.cacheReadTokens;
    const cacheHitRatePct = totalInput > 0 ? Math.round((totalUsage.cacheReadTokens / totalInput) * 100) : 0;
    return {
        deadCount,
        catalogCount,
        sessionCount,
        taxUsd,
        taxUsdPerSession,
        usageValueUsd,
        freshInputPremiumUsd,
        firstTouchUsd,
        cacheHitRatePct,
        totalInputTokens: totalInput,
        usageEntries: corpus.totalDedupedEntries,
        unsupportedPricingModeEntries: corpus.unsupportedPricingModeEntries,
        deadNames: dead.map((sk) => sk.id).sort(),
    };
}
