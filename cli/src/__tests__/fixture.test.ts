import { test, describe } from "node:test";
import assert from "node:assert/strict";
import * as path from "node:path";
import { scanUserSkills } from "../skills.js";
import { scanProjects } from "../transcripts.js";
import { buildFinding } from "../ledger.js";
import { renderCard, renderJSON } from "../card.js";
import { withTempDir, buildSyntheticClaudeTree } from "./testutil.js";

// THE end-to-end test: a tiny, fully synthetic fake ~/.claude tree (never
// real user data) with hand-computed KNOWN expected N-of-M and dollar
// figures, wiring scanUserSkills -> scanProjects -> buildFinding -> the
// printed card exactly the way cli/src/trifola.ts does.
//
// Fixture design (see testutil.ts's buildSyntheticClaudeTree for the exact
// JSONL/SKILL.md contents; numbers chosen so the arithmetic is checkable by
// hand):
//
//   skills/ (4 catalog skills):
//     used-skill          — fired via an explicit Skill tool_use
//     used-via-command    — fired ONLY via a slash command (task #41 merge)
//     dead-one            — description "x"*40  -> ~10 tok, never fired
//     dead-two            — description "y"*80  -> ~20 tok, never fired
//   -> catalogCount=4, deadCount=2, deadPromptTaxTokens=30
//
//   projects/demo-project/session1.jsonl (opus-4-8, 2026-07-01):
//     two streaming lines sharing message m1/requestId r1 — the SECOND
//     (larger) cumulative usage wins, the first is NOT summed in:
//       final usage: input=1,200,000 output=150,000 cacheRead=600,000
//     plus a slash-command line firing "used-via-command".
//     wasted     = 1.2M * (5 - 0.5) = $5.40
//     firstTouch = 0 (no cache creation)
//
//   projects/demo-project/session2.jsonl (sonnet-5, 2026-07-01, intro era):
//     input=2,000,000 output=200,000 cacheCreate=400,000 (300k is the 1h
//     slice, 100k is 5m) cacheRead=1,000,000
//     wasted     = 2.0M * (2 - 0.2)     = $3.60
//     firstTouch = 0.1M*2.5 + 0.3M*4    = $1.45
//
//   projects/demo-project/PARENT123/subagents/agent-1.jsonl (haiku-4-5):
//     input=500,000 output=50,000 cacheRead=100,000 — EXCLUDED from
//     sessionCount, INCLUDED in the dollar totals.
//     wasted = 0.5M * (1 - 0.1) = $0.45
//
//   sessionCount = 2 (subagent file excluded)
//   totals: freshInputPremiumUsd = 5.40+3.60+0.45 = $9.45
//           firstTouchUsd = 0+1.45+0       = $1.45
//   reads (deduped usage entries) = 1 (session1, collapsed) + 1 (session2) + 1 (subagent) = 3
//   totalInput (fleet) = 1,800,000 + 3,400,000 + 600,000 = 5,800,000
//   totalCacheRead      =   600,000 + 1,000,000 + 100,000 = 1,700,000
//   cacheHitRatePct = round(1,700,000 / 5,800,000 * 100) = 29
//   taxUsd = 30/1e6 * (3*0.10) * max(2,1) = 0.000018

describe("end-to-end: synthetic fake ~/.claude tree -> exact known finding", () => {
  test("scanUserSkills + scanProjects + buildFinding produce the hand-computed N-of-M and dollar figures", async () => {
    await withTempDir("trifola-fixture-", async (root) => {
      buildSyntheticClaudeTree(root);

      const skills = scanUserSkills(path.join(root, "skills"));
      const corpus = scanProjects(path.join(root, "projects"));
      const finding = buildFinding(skills, corpus);

      assert.equal(finding.catalogCount, 4);
      assert.equal(finding.deadCount, 2);
      assert.equal(finding.sessionCount, 2); // subagent excluded
      assert.equal(finding.usageEntries, 3);
      assert.equal(finding.totalInputTokens, 5_800_000);
      assert.equal(finding.unsupportedPricingModeEntries, 1);
      assert.equal(finding.cacheHitRatePct, 29);

      assert.ok(Math.abs(finding.taxUsd - 0.000018) < 1e-9, `taxUsd was ${finding.taxUsd}`);
      assert.ok(Math.abs(finding.taxUsdPerSession - 0.000009) < 1e-9);
      assert.ok(Math.abs(finding.usageValueUsd - 18.46) < 0.0001, `usageValueUsd was ${finding.usageValueUsd}`);
      assert.ok(Math.abs(finding.freshInputPremiumUsd - 9.45) < 0.0001);
      assert.ok(Math.abs(finding.firstTouchUsd - 1.45) < 0.0001, `firstTouchUsd was ${finding.firstTouchUsd}`);
    });
  });

  test("the printed card and JSON never leak skill names, project names, or file paths", async () => {
    await withTempDir("trifola-fixture-safe-", async (root) => {
      buildSyntheticClaudeTree(root);
      const skills = scanUserSkills(path.join(root, "skills"));
      const corpus = scanProjects(path.join(root, "projects"));
      const finding = buildFinding(skills, corpus);

      const card = renderCard(finding);
      const json = JSON.stringify(renderJSON(finding));
      const banned = ["used-skill", "used-via-command", "dead-one", "dead-two", "demo-project", root];
      for (const needle of banned) {
        assert.ok(!card.includes(needle), `card leaked "${needle}"`);
        assert.ok(!json.includes(needle), `json leaked "${needle}"`);
      }
      // Denominators always: no bare "NN%" without an adjoining "of <count>".
      assert.match(card, /29% of 5\.8M input tokens served from cache/);
      assert.match(card, /\d+ of \d+ catalog skills/);
      assert.match(card, /\$0\.000009\/session · \$0\.000018 across 2 scanned sessions/);
      assert.match(card, /fresh-input premium above an all-cache-read floor/);
      assert.match(card, /avoidable share is unknowable from logs/);
      assert.match(card, /1 entries used fast\/batch pricing modes trifola does not yet price/);
      assert.ok(!card.includes("wasted re-sending"));
      // The word "leak" must never appear in printed output copy.
      assert.ok(!card.toLowerCase().includes("leak"));
      assert.ok(!json.toLowerCase().includes("leak"));
    });
  });
});
