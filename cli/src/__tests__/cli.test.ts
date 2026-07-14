import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import { withTempDir, buildSyntheticClaudeTree, writeFile } from "./testutil.js";

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
  test("mixed corpus card includes Codex sessions and usage without changing Claude-only tax", async () => {
    await withTempDir("trifola-cli-mixed-", async (root) => {
      buildSyntheticClaudeTree(root);
      const codexHome = path.join(root, ".codex");
      writeFile(path.join(codexHome, "sessions", "2026", "07", "14", "rollout-mixed.jsonl"), [
        { type: "session_meta", payload: { id: "mixed", cwd: "/work/mixed" } },
        { type: "turn_context", payload: { model: "gpt-5.4" } },
        {
          timestamp: "2026-07-14T10:00:00Z",
          type: "event_msg",
          payload: {
            type: "token_count",
            info: { last_token_usage: { input_tokens: 100, cached_input_tokens: 80, output_tokens: 10 } },
          },
        },
      ].map((record) => JSON.stringify(record)).join("\n") + "\n");
      const { stdout, status } = runCli(["--json"], {
        ...process.env,
        CLAUDE_CONFIG_DIR: root,
        CODEX_HOME: codexHome,
      });
      assert.equal(status, 0);
      const parsed = JSON.parse(stdout);
      assert.equal(parsed.sessions.total, 3);
      assert.equal(parsed.sessions.byProvider.claude.sessions, 2);
      assert.equal(parsed.sessions.byProvider.codex.sessions, 1);
      assert.equal(parsed.deadSkills.sessions, 2);
      assert.equal(parsed.promptTax.sessions, 2);
      assert.equal(parsed.usageValue.byProvider.codex, 0.00022);
      assert.deepEqual(parsed.freshInput.byProvider.codex, { totalInputTokens: 100, usageEntries: 1 });
    });
  });

  test("--help prints usage and exits 0 without touching disk", () => {
    const { stdout, status } = runCli(["--help"], { ...process.env, CLAUDE_CONFIG_DIR: "/nonexistent-on-purpose" });
    assert.equal(status, 0);
    assert.match(stdout, /npx trifola/);
    assert.match(stdout, /CLAUDE_CONFIG_DIR/);
  });

  test("default (text card) run against CLAUDE_CONFIG_DIR resolves the synthetic fixture and prints the known numbers", async () => {
    await withTempDir("trifola-cli-e2e-", async (root) => {
      buildSyntheticClaudeTree(root);
      const cache = path.join(root, "cache");
      const { stdout, status } = runCli([], {
        ...process.env,
        CLAUDE_CONFIG_DIR: root,
        XDG_CACHE_HOME: cache,
        HOME: root,
      });
      assert.equal(status, 0);
      assert.match(stdout, /2 sessions \(\+1 subagent run\) · 2 Claude \+ 0 Codex/);
      assert.match(stdout, /2 of 4 catalog skills never fired, across 2 Claude sessions \(\+1 Claude subagent run\)\./);
      assert.match(stdout, /\$18 API-equivalent across the scanned corpus/);
      assert.match(stdout, /29% of 5\.8M input tokens served from cache/);
      assert.match(stdout, /fresh-input premium above an all-cache-read floor/);
      assert.match(stdout, /1 entries used fast\/batch pricing modes trifola does not yet price/);
      assert.ok(!stdout.toLowerCase().includes("leak"));
      assert.equal(fs.existsSync(path.join(cache, "trifola", "search-index.sqlite3")), false);
    });
  });

  test("--json run against CLAUDE_CONFIG_DIR prints machine-readable JSON with the same numbers", async () => {
    await withTempDir("trifola-cli-json-", async (root) => {
      buildSyntheticClaudeTree(root);
      const { stdout, status } = runCli(["--json"], {
        ...process.env,
        CLAUDE_CONFIG_DIR: root,
        CODEX_HOME: path.join(root, ".codex"),
      });
      assert.equal(status, 0);
      const parsed = JSON.parse(stdout);
      assert.equal(parsed.deadSkills.dead, 2);
      assert.equal(parsed.deadSkills.catalog, 4);
      assert.equal(parsed.deadSkills.sessions, 2);
      assert.equal(parsed.usageValue.usd, 18.46);
      assert.equal(parsed.freshInput.usageEntries, 3);
      assert.equal(parsed.freshInput.totalInputTokens, 5_800_000);
      assert.equal(parsed.freshInput.cacheHitRatePct, 29);
      assert.equal(parsed.freshInput.unsupportedPricingModeEntries, 1);
      assert.deepEqual(parsed.freshInput.byProvider.claude, { totalInputTokens: 5_800_000, usageEntries: 3 });
      assert.deepEqual(parsed.freshInput.byProvider.codex, { totalInputTokens: 0, usageEntries: 0 });
      assert.ok(Math.abs(parsed.freshInput.premiumUsd - 9.45) < 0.0001);
      assert.ok(Math.abs(parsed.freshInput.firstTouchUsd - 1.45) < 0.0001);
      assert.equal(parsed.promptTax.perSessionUsd, 0.000009);
      assert.equal(parsed.promptTax.totalUsd, 0.000018);
      assert.equal(parsed.promptTax.label, "API-equivalent");
    });
  });

  test("an empty CLAUDE_CONFIG_DIR degrades to an honest all-zero card, never a crash", async () => {
    await withTempDir("trifola-cli-empty-", async (root) => {
      const { stdout, status } = runCli([], {
        ...process.env,
        CLAUDE_CONFIG_DIR: root,
        CODEX_HOME: path.join(root, ".codex"),
      });
      assert.equal(status, 0);
      assert.match(stdout, /0 of 0 catalog skills never fired, across 0 Claude sessions\./);
    });
  });
});
