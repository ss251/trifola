import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { buildFinding } from "../ledger.js";
import type { Skill } from "../skills.js";
import type { CorpusStats } from "../transcripts.js";
import { emptyUsage } from "../pricing.js";

// Pure formula-level tests: CorpusStats is constructed directly (no file
// I/O), the same way Tests/TrifolaKitTests/AuditTests.swift's
// SkillLedgerTests and LedgerTests construct a SkillLedger/AuditReport by
// hand rather than scanning real transcripts. The end-to-end file-scanning
// path is covered separately by fixture.test.ts.

function skill(id: string, opts: { name?: string; description?: string } = {}): Skill {
  return {
    id,
    name: opts.name ?? id,
    description: opts.description ?? "a skill",
    version: undefined,
    triggers: [],
    allowedTools: [],
    hasManifest: true,
    wordCount: 10,
    fileCount: 1,
    path: `/skills/${id}`,
  };
}

function corpusWith(opts: { fired?: Record<string, number>; sessionCount?: number }): CorpusStats {
  return {
    sessionCount: opts.sessionCount ?? 1,
    fileCount: opts.sessionCount ?? 1,
    skillFireCounts: new Map(Object.entries(opts.fired ?? {})),
    totalDedupedEntries: 0,
    totalUsage: emptyUsage(),
    usageByDayModel: new Map(),
  };
}

describe("buildFinding — dead-skill count (catalog minus fired, matched by id OR name)", () => {
  test("a catalog skill counts as fired if either its folder id or its frontmatter name was invoked", () => {
    // Catalog of 5. Fired: "code-review" (NOT in catalog -> external, doesn't
    // shrink the dead list), "api-client" (matches folder id), "diagram"
    // (matches frontmatter name, folder id is "dia").
    const catalog: Skill[] = [
      skill("api-client"),
      skill("dia", { name: "diagram" }),
      skill("unused-one"),
      skill("unused-two"),
      skill("unused-three"),
    ];
    const corpus = corpusWith({ fired: { "code-review": 20, "api-client": 11, diagram: 2 }, sessionCount: 2 });

    const finding = buildFinding(catalog, corpus);
    assert.equal(finding.catalogCount, 5);
    assert.equal(finding.deadCount, 3); // unused-one/two/three
  });

  test("a skill fired ONLY via a slash command still counts as fired (task #41 parity)", () => {
    const catalog: Skill[] = [skill("released-by-command"), skill("truly-dead")];
    // transcripts.ts merges Skill-tool-call counts and slash-command counts
    // into the same skillFireCounts map before buildFinding ever sees it —
    // from buildFinding's point of view the two lanes are indistinguishable,
    // which is exactly the point.
    const corpus = corpusWith({ fired: { "released-by-command": 1 } });
    const finding = buildFinding(catalog, corpus);
    assert.equal(finding.deadCount, 1);
    assert.equal(finding.catalogCount, 2);
  });

  test("an empty catalog and an empty corpus yield an honest all-zero finding, never a crash", () => {
    const finding = buildFinding([], corpusWith({}));
    assert.equal(finding.deadCount, 0);
    assert.equal(finding.catalogCount, 0);
    assert.equal(finding.taxUsd, 0);
    assert.equal(finding.wastedUsd, 0);
    assert.equal(finding.firstTouchUsd, 0);
    assert.equal(finding.cacheHitRatePct, 0);
    assert.equal(finding.reads, 0);
  });
});

describe("buildFinding — prompt-tax pricing (dead-skill descriptions, cache-read rate)", () => {
  test("tax tokens sum ONLY the dead skills' descriptions (~4 chars/token, min 1)", () => {
    const d40 = "x".repeat(40); // ~10 tok
    const d80 = "y".repeat(80); // ~20 tok
    const catalog: Skill[] = [
      skill("fired-one", { description: "short" }),
      skill("dead-a", { description: d40 }),
      skill("dead-b", { description: d80 }),
    ];
    const corpus = corpusWith({ fired: { "fired-one": 1 }, sessionCount: 1 });
    const finding = buildFinding(catalog, corpus);
    assert.equal(finding.deadCount, 2);
    // taxUsd = (10+20)/1e6 * (3 * 0.10) * max(sessionCount,1) = 30e-6 * 0.3 * 1
    assert.ok(Math.abs(finding.taxUsd - 30e-6 * 0.3 * 1) < 1e-12);
  });

  test("cross-check against the Swift Ledger fixture's own numbers (catalogCount 110-scale, deadPromptTaxTokens 41800, sessionCount 2691 -> ~$33.75)", () => {
    // Mirrors Tests/TrifolaKitTests/LedgerTests.swift's AuditReport.withFindings()
    // fixture (catalogCount: 110, deadCount: 95, deadPromptTaxTokens: 41_800,
    // sessionCount: 2691). A single dead skill with a description sized to
    // hit exactly 41_800 estimated tokens isolates the FORMULA for a direct
    // numeric cross-check against that fixture, without needing to construct
    // 110 separate Skill objects.
    const dead = skill("huge-dead-one", { description: "x".repeat(41_800 * 4) });
    const catalog: Skill[] = [skill("fired-one"), dead];
    const corpus = corpusWith({ fired: { "fired-one": 1 }, sessionCount: 2691 });
    const finding = buildFinding(catalog, corpus);
    assert.equal(finding.deadCount, 1);
    // taxUsd = 41_800/1e6 * (3*0.10) * 2691 = 0.0418 * 0.3 * 2691 = 33.74514
    assert.ok(Math.abs(finding.taxUsd - 33.74514) < 0.001);
  });

  test("zero sessions still floors the tax multiplier at 1 (max(sessionCount,1)), never zeroing out the catalog signal", () => {
    const catalog: Skill[] = [skill("dead-only", { description: "x".repeat(40) })];
    const corpus = corpusWith({ sessionCount: 0 });
    const finding = buildFinding(catalog, corpus);
    assert.ok(finding.taxUsd > 0);
  });
});
