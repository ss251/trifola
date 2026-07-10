import { test, describe } from "node:test";
import assert from "node:assert/strict";
import {
  normalizeModel,
  resolvedRate,
  costOfUsage,
  reSentContextDollarsOfUsage,
  firstTouchDollarsOfUsage,
  cacheHitRateOfUsage,
  type UsageTotals,
} from "../pricing.js";

// These mirror Tests/TrifolaKitTests/PricingTests.swift and AuditTests.swift's
// CacheLeakTests numbers exactly, so a pass here is direct cross-validation
// against the Swift source's own pinned fixtures.

function usage(partial: Partial<UsageTotals>): UsageTotals {
  return {
    inputTokens: 0,
    outputTokens: 0,
    cacheCreateTokens: 0,
    cacheReadTokens: 0,
    cacheCreate1hTokens: 0,
    ...partial,
  };
}

describe("normalizeModel", () => {
  test("strips prefixes and suffixes", () => {
    assert.equal(normalizeModel("us.anthropic.claude-opus-4-8"), "claude-opus-4-8");
    assert.equal(normalizeModel("claude-opus-4-8@default"), "claude-opus-4-8");
    assert.equal(normalizeModel("anthropic/claude-sonnet-5"), "claude-sonnet-5");
    assert.equal(normalizeModel("claude-haiku-4-5-20251001"), "claude-haiku-4-5");
    assert.equal(normalizeModel("claude-opus-4-8[1m]"), "claude-opus-4-8");
    assert.equal(normalizeModel("CLAUDE-OPUS-4-8"), "claude-opus-4-8");
    assert.equal(normalizeModel("claude-sonnet-5"), "claude-sonnet-5"); // idempotent
    assert.equal(normalizeModel(null), "");
    assert.equal(normalizeModel(undefined), "");
  });
});

describe("resolvedRate — catalog + date-dependent Sonnet 5", () => {
  test("sonnet 5 is date dependent", () => {
    // Intro era (through 2026-08-31): $2 in / $10 out — NOT $3/$15.
    const intro = resolvedRate("claude-sonnet-5", "2026-07-06");
    assert.equal(intro.input, 2);
    assert.equal(intro.output, 10);
    assert.ok(Math.abs(intro.cacheRead - 0.2) < 1e-9);
    assert.ok(Math.abs(intro.cacheWrite5m - 2.5) < 1e-9);
    assert.ok(Math.abs(intro.cacheWrite1h - 4.0) < 1e-9);

    // Boundary day 2026-09-01 and after: $3/$15.
    const std = resolvedRate("claude-sonnet-5", "2026-09-01");
    assert.equal(std.input, 3);
    assert.equal(std.output, 15);
    const later = resolvedRate("claude-sonnet-5", "2027-01-15");
    assert.equal(later.input, 3);

    // Day before the boundary is still intro.
    const aug31 = resolvedRate("claude-sonnet-5", "2026-08-31");
    assert.equal(aug31.input, 2);
  });

  test("opus generations price differently", () => {
    const o48 = resolvedRate("claude-opus-4-8");
    assert.equal(o48.input, 5);
    assert.equal(o48.output, 25);
    assert.ok(Math.abs(o48.cacheRead - 0.5) < 1e-9);
    assert.ok(Math.abs(o48.cacheWrite5m - 6.25) < 1e-9);
    assert.ok(Math.abs(o48.cacheWrite1h - 10.0) < 1e-9);

    const o41 = resolvedRate("claude-opus-4-1");
    assert.equal(o41.input, 15);
    assert.equal(o41.output, 75);

    const haiku = resolvedRate("claude-haiku-4-5");
    assert.equal(haiku.input, 1);
    assert.equal(haiku.output, 5);
  });

  test("fable 5 and haiku 3.5 pin all constants through dated ids", () => {
    const fableRate = resolvedRate("claude-fable-5-20260301");
    assert.deepEqual(fableRate, {
      input: 10,
      output: 50,
      cacheRead: 1,
      cacheWrite5m: 12.5,
      cacheWrite1h: 20,
    });

    const haiku35 = resolvedRate("claude-3-5-haiku-20241022");
    assert.equal(haiku35.input, 0.8);
    assert.equal(haiku35.output, 4);
    assert.ok(Math.abs(haiku35.cacheRead - 0.08) < 1e-12);
    assert.equal(haiku35.cacheWrite5m, 1);
    assert.ok(Math.abs(haiku35.cacheWrite1h - 1.6) < 1e-12);
  });

  test("unknown model falls back to tier rate", () => {
    const alias = resolvedRate("opus");
    assert.equal(alias.input, 5);
    assert.equal(alias.output, 25);

    const other = resolvedRate("glm-4.7");
    assert.equal(other.input, 5);
    assert.equal(other.output, 25);
    assert.ok(Math.abs(other.cacheWrite5m - other.input * 1.25) < 1e-9);

    const synthetic = resolvedRate("<synthetic>");
    assert.equal(synthetic.input, 5);
  });
});

describe("cost / re-sent-context / first-touch math", () => {
  test("cost splits cache writes into 5m and 1h slices", () => {
    // 1M fresh + 1M cache-create of which 400k is the 1h slice, on Opus 4.8:
    //   fresh 1M x $5          = 5.000
    //   cw5m  0.6M x $6.25     = 3.750
    //   cw1h  0.4M x $10 (2x)  = 4.000
    //   total                  = 12.750
    const u = usage({ inputTokens: 1_000_000, cacheCreateTokens: 1_000_000, cacheCreate1hTokens: 400_000 });
    const rate = resolvedRate("claude-opus-4-8");
    assert.ok(Math.abs(costOfUsage(u, rate) - 12.75) < 0.0001);

    // The pre-split lump (all creates at 1.25x) would have said 5 + 1M*6.25 = 11.25.
    const lumped = usage({ inputTokens: 1_000_000, cacheCreateTokens: 1_000_000 });
    assert.ok(Math.abs(costOfUsage(lumped, rate) - 11.25) < 0.0001);
  });

  test("re-sent context is fresh-input premium only; first-touch is cache build", () => {
    // fresh 1M, cache-create 0.4M (all 5m), cache-read 2M on Opus 4.8
    // ($5 in / $0.50 read / $6.25 cw5m):
    //   wasted (re-sent)  = 1M   x ($5 - $0.50) = 4.50
    //   first-touch       = 0.4M x $6.25        = 2.50   (cache build, NOT wasted)
    const u = usage({ inputTokens: 1_000_000, outputTokens: 200_000, cacheCreateTokens: 400_000, cacheReadTokens: 2_000_000 });
    const opus = resolvedRate("claude-opus-4-8");
    assert.ok(Math.abs(reSentContextDollarsOfUsage(u, opus) - 4.5) < 0.0001);
    assert.ok(Math.abs(firstTouchDollarsOfUsage(u, opus) - 2.5) < 0.0001);
  });

  test("first-touch splits the 1h slice at 2x", () => {
    // cache-create 0.4M of which 0.3M is the 1h slice on Opus 4.8:
    //   5m slice 0.1M x $6.25 = 0.625
    //   1h slice 0.3M x $10   = 3.000   -> first-touch 3.625
    const u = usage({ cacheCreateTokens: 400_000, cacheCreate1hTokens: 300_000 });
    const opus = resolvedRate("claude-opus-4-8");
    assert.ok(Math.abs(firstTouchDollarsOfUsage(u, opus) - 3.625) < 0.0001);
    assert.equal(reSentContextDollarsOfUsage(u, opus), 0); // no fresh input -> no waste
  });

  test("pure warm cache has no waste and no first-touch", () => {
    const u = usage({ inputTokens: 0, cacheCreateTokens: 0, cacheReadTokens: 5_000_000 });
    const opus = resolvedRate("claude-opus-4-8");
    assert.equal(reSentContextDollarsOfUsage(u, opus), 0);
    assert.equal(firstTouchDollarsOfUsage(u, opus), 0);
  });

  test("cache hit rate is cache-read / total input", () => {
    const u = usage({ inputTokens: 1_500_000, cacheReadTokens: 500_000 });
    assert.ok(Math.abs(cacheHitRateOfUsage(u) - 0.25) < 1e-9);
    assert.equal(cacheHitRateOfUsage(usage({})), 0); // no input at all -> 0, never NaN
  });
});
