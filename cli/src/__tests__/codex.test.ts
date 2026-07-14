import { describe, test } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import { withTempDir, writeFile } from "./testutil.js";
import {
  detectZstd,
  parseCodexRollout,
  readCodexRolloutFile,
  scanCodexSessions,
} from "../codex.js";

function jsonl(records: unknown[]): Buffer {
  return Buffer.from(records.map((record) => JSON.stringify(record)).join("\n") + "\n");
}

function meta(id: string, extra: Record<string, unknown> = {}): unknown {
  return { timestamp: "2026-07-14T10:00:00Z", type: "session_meta", payload: { id, cwd: "/work/demo", ...extra } };
}

function tokens(total: Record<string, number>, last?: Record<string, number>, timestamp = "2026-07-14T10:01:00Z"): unknown {
  return {
    timestamp,
    type: "event_msg",
    payload: {
      type: "token_count",
      info: { total_token_usage: total, ...(last ? { last_token_usage: last } : {}) },
    },
  };
}

describe("Codex rollout parser", () => {
  test("converts inclusive cache, resets epochs, clamps malformed cache, and retro-attributes", () => {
    const first = { input_tokens: 100, cached_input_tokens: 80, output_tokens: 10, reasoning_output_tokens: 4 };
    const secondTotal = { input_tokens: 200, cached_input_tokens: 150, output_tokens: 30 };
    const secondLast = { input_tokens: 100, cached_input_tokens: 70, output_tokens: 20 };
    const reset = { input_tokens: 50, cached_input_tokens: 60, output_tokens: 5 };
    const rollout = parseCodexRollout(jsonl([
      meta("epoch-thread"),
      tokens(first),
      { timestamp: "2026-07-14T10:01:30Z", type: "turn_context", payload: { model: "openai/gpt-5.4" } },
      tokens(secondTotal, secondLast, "2026-07-14T10:02:00Z"),
      tokens(secondTotal, secondLast, "2026-07-14T10:02:01Z"),
      tokens(reset, undefined, "2026-07-14T10:03:00Z"),
    ]), "fallback");

    assert.equal(rollout.sessionId, "epoch-thread");
    assert.equal(rollout.usageEntries, 3);
    assert.deepEqual(rollout.totalUsage, {
      inputTokens: 50,
      cacheReadTokens: 210,
      outputTokens: 35,
      cacheCreateTokens: 0,
      cacheCreate1hTokens: 0,
    });
    assert.deepEqual([...rollout.usageByDayModel.values()].flatMap((models) => [...models.keys()]), ["gpt-5.4"]);
  });

  test("first session metadata wins and search includes only user/assistant prose", () => {
    const rollout = parseCodexRollout(jsonl([
      meta("first", { cwd: "/first" }),
      meta("copied-parent", { cwd: "/wrong" }),
      { type: "event_msg", payload: { type: "user_message", message: "Visible user needle" } },
      { type: "event_msg", payload: { type: "agent_message", message: "Visible assistant needle" } },
      { type: "response_item", payload: { type: "item_completed", item: { type: "message", role: "assistant", content: [{ type: "output_text", text: "Nested prose" }] } } },
      { type: "response_item", payload: { type: "function_call", arguments: "tool-secret" } },
      { type: "response_item", payload: { type: "reasoning", summary: "thinking-secret" } },
    ]), "fallback");
    assert.equal(rollout.sessionId, "first");
    assert.equal(rollout.cwd, "/first");
    assert.deepEqual(rollout.events.map((event) => event.text), [
      "Visible user needle", "Visible assistant needle", "Nested prose",
    ]);
  });

  test("manifest import IDs are excluded and subagent path controls the count", async () => {
    await withTempDir("trifola-codex-scan-", async (root) => {
      const sessions = path.join(root, "sessions", "2026", "07", "14");
      writeFile(path.join(sessions, "rollout-keep.jsonl"), jsonl([meta("keep")]).toString());
      writeFile(path.join(sessions, "rollout-drop.jsonl"), jsonl([meta("drop")]).toString());
      writeFile(path.join(sessions, "subagents", "rollout-child.jsonl"), jsonl([meta("child")]).toString());
      writeFile(path.join(root, "external_agent_session_imports.json"), JSON.stringify({
        records: [{ imported_thread_id: "drop" }],
      }));
      const stats = scanCodexSessions(root);
      assert.equal(stats.sessionCount, 1);
      assert.equal(stats.fileCount, 2);
    });
  });

  test("a symlinked import manifest is ignored, matching the Swift safety boundary", async () => {
    await withTempDir("trifola-codex-manifest-link-", async (root) => {
      const sessions = path.join(root, "sessions", "2026", "07", "14");
      writeFile(path.join(sessions, "rollout-keep.jsonl"), jsonl([meta("keep")]).toString());
      const target = path.join(root, "manifest-target.json");
      writeFile(target, JSON.stringify({ records: [{ imported_thread_id: "keep" }] }));
      fs.symlinkSync(target, path.join(root, "external_agent_session_imports.json"));
      assert.equal(scanCodexSessions(root).sessionCount, 1);
    });
  });

  test("zstd is feature-detected and unavailable archives report a skip", async () => {
    assert.equal(detectZstd(() => ({})), false);
    assert.equal(detectZstd(() => ({ zstdDecompressSync: () => new Uint8Array() })), true);
    await withTempDir("trifola-zstd-", async (root) => {
      const archive = path.join(root, "rollout-test.jsonl.zst");
      fs.writeFileSync(archive, Buffer.from([1, 2, 3]));
      assert.deepEqual(readCodexRolloutFile(archive, () => ({})), { data: null, compressedSkipped: true });
      const decompressed = jsonl([meta("zstd")]);
      const read = readCodexRolloutFile(archive, () => ({ zstdDecompressSync: () => decompressed }));
      assert.equal(read.compressedSkipped, false);
      assert.deepEqual(read.data, decompressed);
    });
  });
});
