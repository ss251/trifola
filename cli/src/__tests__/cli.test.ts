import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import { withTempDir, buildSyntheticClaudeTree } from "./testutil.js";

// Subprocess-level test against the COMPILED entry point (dist/trifola.js) —
// the closest thing to actually running `npx trifola`. Exercises argv
// parsing, the CLAUDE_CONFIG_DIR override, and the shebang/executable story
// end to end, on top of the exact same synthetic fixture fixture.test.ts
// pins numerically.

const here = path.dirname(fileURLToPath(import.meta.url));
const entry = path.join(here, "..", "trifola.js"); // dist/__tests__/../trifola.js == dist/trifola.js

function runCli(args: string[], env: NodeJS.ProcessEnv): { stdout: string; stderr: string; status: number | null } {
  const result = spawnSync(process.execPath, [entry, ...args], {
    env,
    encoding: "utf8",
  });
  return { stdout: result.stdout, stderr: result.stderr, status: result.status };
}

describe("trifola CLI entry point (subprocess)", () => {
  test("--help prints usage and exits 0 without touching disk", () => {
    const { stdout, status } = runCli(["--help"], { ...process.env, CLAUDE_CONFIG_DIR: "/nonexistent-on-purpose" });
    assert.equal(status, 0);
    assert.match(stdout, /npx trifola/);
    assert.match(stdout, /CLAUDE_CONFIG_DIR/);
  });

  test("default (text card) run against CLAUDE_CONFIG_DIR resolves the synthetic fixture and prints the known numbers", async () => {
    await withTempDir("trifola-cli-e2e-", async (root) => {
      buildSyntheticClaudeTree(root);
      const { stdout, status } = runCli([], { ...process.env, CLAUDE_CONFIG_DIR: root });
      assert.equal(status, 0);
      assert.match(stdout, /2 of 4 catalog skills never fired, across 2 sessions\./);
      assert.match(stdout, /29% of 3 reads served from cache/);
      assert.ok(!stdout.toLowerCase().includes("leak"));
    });
  });

  test("--json run against CLAUDE_CONFIG_DIR prints machine-readable JSON with the same numbers", async () => {
    await withTempDir("trifola-cli-json-", async (root) => {
      buildSyntheticClaudeTree(root);
      const { stdout, status } = runCli(["--json"], { ...process.env, CLAUDE_CONFIG_DIR: root });
      assert.equal(status, 0);
      const parsed = JSON.parse(stdout);
      assert.equal(parsed.deadSkills.dead, 2);
      assert.equal(parsed.deadSkills.catalog, 4);
      assert.equal(parsed.deadSkills.sessions, 2);
      assert.equal(parsed.resentContext.reads, 3);
      assert.equal(parsed.resentContext.cacheHitRatePct, 29);
      assert.ok(Math.abs(parsed.resentContext.wastedUsd - 9.45) < 0.0001);
      assert.ok(Math.abs(parsed.resentContext.firstTouchUsd - 1.45) < 0.0001);
      assert.equal(parsed.promptTax.label, "API-equivalent");
    });
  });

  test("an empty CLAUDE_CONFIG_DIR degrades to an honest all-zero card, never a crash", async () => {
    await withTempDir("trifola-cli-empty-", async (root) => {
      const { stdout, status } = runCli([], { ...process.env, CLAUDE_CONFIG_DIR: root });
      assert.equal(status, 0);
      assert.match(stdout, /0 of 0 catalog skills never fired, across 0 sessions\./);
    });
  });
});
