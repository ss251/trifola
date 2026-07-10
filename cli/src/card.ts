// The share card — the whole point of `npx trifola`. Honesty rules (hard):
//  - Denominators ALWAYS: never a bare percentage; cache hit uses input tokens.
//  - Counts + dollars only: no skill names, no file paths, no project names —
//    safe to screenshot.
//  - Re-sent context and first-touch are NEVER summed; first-touch is always
//    labeled unavoidable and shown separately.
//  - Estimates are labeled "API-equivalent" — never implied to be the actual bill.
//  - The word "leak" never appears in printed/JSON output copy.

import type { Finding } from "./ledger.js";
import { fmtUSD, fmtTinyUSD, fmtPct, fmtCount, fmtTokens } from "./format.js";

const RULE = "─".repeat(58);

export function renderCard(finding: Finding): string {
  const lines: string[] = [];
  lines.push("trifola — claude code corpus finding");
  lines.push(RULE);
  if (finding.catalogCount === 0 && finding.sessionCount === 0) {
    lines.push("");
    lines.push("No Claude Code skills or session transcripts found under this config");
    lines.push("directory — the figures below are honestly zero, not an error.");
  }
  lines.push("");
  lines.push("DEAD SKILLS");
  lines.push(
    `  ${fmtCount(finding.deadCount)} of ${fmtCount(finding.catalogCount)} catalog skills never fired, ` +
      `across ${fmtCount(finding.sessionCount)} sessions.`
  );
  lines.push(
    "  (explicit Skill-tool + slash-command invocations only — skills auto-"
  );
  lines.push('  loaded as context aren\'t tracked, so this likely OVERSTATES "dead".)');
  lines.push("");
  lines.push("EST. USAGE VALUE");
  lines.push(`  ${fmtUSD(finding.usageValueUsd)} API-equivalent across the scanned corpus`);
  lines.push("");
  lines.push("PROMPT TAX");
  lines.push(
    `  ~${fmtTinyUSD(finding.taxUsdPerSession)}/session · ${fmtTinyUSD(finding.taxUsd)} across ` +
      `${fmtCount(finding.sessionCount)} scanned sessions`
  );
  lines.push("  the dead skills' descriptions still ride every session's prompt —");
  lines.push("  priced at the cache-read rate (input × 0.10 of a mid-tier model),");
  lines.push("  not your raw input bill.");
  lines.push("");
  lines.push("RE-SENT CONTEXT");
  lines.push(`  ~${fmtUSD(finding.freshInputPremiumUsd)} fresh-input premium above an all-cache-read floor`);
  lines.push("  the avoidable share is unknowable from logs (API-equivalent, not your bill)");
  lines.push(
    `  first-touch (unavoidable cache build, shown separately, never summed): ${fmtUSD(finding.firstTouchUsd)}`
  );
  lines.push(
    `  ${fmtPct(finding.cacheHitRatePct / 100)} of ${fmtTokens(finding.totalInputTokens)} input tokens served from cache`
  );
  if (finding.unsupportedPricingModeEntries > 0) {
    lines.push(
      `  ${fmtCount(finding.unsupportedPricingModeEntries)} entries used fast/batch pricing modes ` +
        "trifola does not yet price — totals may be off for those entries"
    );
  }
  lines.push("");
  lines.push(RULE);
  lines.push(
    `one power user's corpus — ${fmtCount(finding.catalogCount)} skills, ${fmtCount(finding.sessionCount)} sessions — run it on yours:`
  );
  lines.push("  npx trifola");
  lines.push("reads local disk only, uploads nothing.");
  return lines.join("\n");
}

export interface FindingJSON {
  deadSkills: { dead: number; catalog: number; sessions: number; note: string };
  usageValue: { usd: number; label: "API-equivalent" };
  promptTax: { perSessionUsd: number; totalUsd: number; sessions: number; label: "API-equivalent"; note: string };
  freshInput: {
    premiumUsd: number;
    firstTouchUsd: number;
    note: string;
    cacheHitRatePct: number;
    totalInputTokens: number;
    usageEntries: number;
    unsupportedPricingModeEntries: number;
  };
  footer: { corpus: string; privacy: string };
  generatedAt: string;
}

/** Round a dollar figure to 6 decimal places — enough precision even for tiny
 * synthetic/edge values, without printing raw floating-point representation
 * noise (e.g. 0.0000033000000000000006) in machine-readable output. */
function round6(v: number): number {
  return Math.round(v * 1_000_000) / 1_000_000;
}

export function renderJSON(finding: Finding): FindingJSON {
  return {
    deadSkills: {
      dead: finding.deadCount,
      catalog: finding.catalogCount,
      sessions: finding.sessionCount,
      note:
        "counts explicit Skill-tool + slash-command invocations only; skills auto-loaded as context aren't tracked, so this likely overstates \"dead\"",
    },
    usageValue: { usd: round6(finding.usageValueUsd), label: "API-equivalent" },
    promptTax: {
      perSessionUsd: round6(finding.taxUsdPerSession),
      totalUsd: round6(finding.taxUsd),
      sessions: finding.sessionCount,
      label: "API-equivalent",
      note: "priced at the cache-read rate (input x 0.10 of a mid-tier model), not raw input",
    },
    freshInput: {
      premiumUsd: round6(finding.freshInputPremiumUsd),
      firstTouchUsd: round6(finding.firstTouchUsd),
      note:
        "premiumUsd is the fresh-input premium above an all-cache-read floor; the avoidable share is unknowable from logs; firstTouchUsd is unavoidable cache-build cost — never sum the two",
      cacheHitRatePct: finding.cacheHitRatePct,
      totalInputTokens: finding.totalInputTokens,
      usageEntries: finding.usageEntries,
      unsupportedPricingModeEntries: finding.unsupportedPricingModeEntries,
    },
    footer: {
      corpus: `${finding.catalogCount} skills, ${finding.sessionCount} sessions`,
      privacy: "reads local disk only, uploads nothing",
    },
    generatedAt: new Date().toISOString(),
  };
}

export const HELP_TEXT = `trifola — finding generator for your Claude Code corpus

Reads your local ~/.claude (or $CLAUDE_CONFIG_DIR) and prints a one-screen
finding: dead skills, prompt tax, and re-sent context — priced at
API-equivalent rates, never your actual bill. Reads local disk only.
Uploads nothing.

Usage:
  npx trifola [options]

Options:
  --json       Print machine-readable JSON instead of the text card.
  --list-dead  Print the never-fired skill ids, one per line (local prune
               list — real names, deliberately excluded from the share card).
  --help, -h   Show this help and exit.

Environment:
  CLAUDE_CONFIG_DIR   Override the Claude Code config directory (default: ~/.claude).`;
