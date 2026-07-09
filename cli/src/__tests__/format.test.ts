import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { fmtUSD, fmtPct, fmtCount } from "../format.js";

// Mirrors the fmtUSD / fmtPct / fmtGrouped expectations baked into
// Sources/TrifolaKit/Models.swift and exercised throughout its UI/receipt
// code (e.g. Ledger.swift's cacheMissDiscipline lesson uses fmtUSD(41.30) and
// the totalLeakDollars=214.60 style figures).

describe("fmtUSD", () => {
  test("small values show two decimal places", () => {
    assert.equal(fmtUSD(0), "$0.00");
    assert.equal(fmtUSD(4.5), "$4.50");
    assert.equal(fmtUSD(0.000018), "$0.00"); // honestly negligible, not hidden
  });

  test("values >= 10 round to whole dollars", () => {
    assert.equal(fmtUSD(41.3), "$41");
    assert.equal(fmtUSD(214.6), "$215");
  });

  test("values >= 1000 compact to $N.Nk", () => {
    assert.equal(fmtUSD(1500), "$1.5k");
    assert.equal(fmtUSD(33745), "$33.7k");
  });
});

describe("fmtPct", () => {
  test("rounds a 0..1 fraction to a whole percent", () => {
    assert.equal(fmtPct(0.34), "34%");
    assert.equal(fmtPct(0.293103448), "29%");
    assert.equal(fmtPct(0), "0%");
    assert.equal(fmtPct(1), "100%");
  });
});

describe("fmtCount", () => {
  test("adds thousands separators", () => {
    assert.equal(fmtCount(2691), "2,691");
    assert.equal(fmtCount(41204), "41,204");
    assert.equal(fmtCount(0), "0");
    assert.equal(fmtCount(95), "95");
  });
});
