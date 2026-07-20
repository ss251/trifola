import { describe, test } from "node:test";
import assert from "node:assert/strict";
import * as path from "node:path";
import { withTempDir, writeFile } from "./testutil.js";
import { parseGrokSession, scanGrokSessions } from "../grok.js";

function jsonl(records: unknown[]): Buffer {
  return Buffer.from(records.map((record) => JSON.stringify(record)).join("\n") + "\n");
}

describe("Grok session parser", () => {
  test("joins summary metadata, visible prose, model union, usage, and lineage", () => {
    const summary = Buffer.from(JSON.stringify({
      info: { id: "grok-child", cwd: "/Users/dev/work/demo" },
      generated_title: "Build the parser",
      current_model_id: "grok-4.5",
      created_at: "2026-07-20T09:00:00Z",
      parent_session_id: "grok-parent",
      session_kind: "subagent_fork",
    }));
    const chat = jsonl([
      { type: "user", content: [{ type: "text", text: "Visible user needle" }] },
      { type: "user", synthetic_reason: "system", content: [{ type: "text", text: "hidden synthetic" }] },
      { type: "assistant", model_id: "grok-4.5", content: "Visible assistant prose" },
      { type: "tool_result", content: "hidden tool output" },
    ]);
    const updates = jsonl([
      {
        timestamp: 1_784_541_600,
        method: "session/update",
        params: { update: {
          sessionUpdate: "turn_completed",
          prompt_id: "prompt-1",
          usage: {
            inputTokens: 1_500,
            cachedReadTokens: 900,
            outputTokens: 300,
            costIsPartial: true,
            modelUsage: {
              "grok-4.5": { inputTokens: 1_000, cachedReadTokens: 800, outputTokens: 200, modelCalls: 1 },
              "grok-4.5-build": { inputTokens: 500, cachedReadTokens: 100, outputTokens: 100, modelCalls: 2 },
            },
          },
        } },
      },
      {
        timestamp: "2026-07-20T10:01:00Z",
        params: { update: {
          sessionUpdate: "subagent_spawned",
          parent_session_id: "grok-child",
          child_session_id: "grok-grandchild",
        } },
      },
    ]);

    const rollout = parseGrokSession(
      summary, chat, updates, "fallback",
      "/Users/dev/.grok/sessions/%2FUsers%2Fdev%2Ffallback/grok-child/summary.json",
    );
    assert.equal(rollout.sessionId, "grok-child");
    assert.equal(rollout.cwd, "/Users/dev/work/demo");
    assert.equal(rollout.title, "Build the parser");
    assert.equal(rollout.parentSessionId, "grok-parent");
    assert.equal(rollout.sessionKind, "subagent_fork");
    assert.deepEqual(rollout.spawnedChildSessionIds, ["grok-grandchild"]);
    assert.deepEqual(rollout.events.map((event) => event.text), ["Visible user needle", "Visible assistant prose"]);
    assert.deepEqual(rollout.models, ["grok-4.5", "grok-4.5-build"]);
    assert.equal(rollout.usageIsPartial, true);
    assert.equal(rollout.usageEntries, 2);
    assert.deepEqual(rollout.totalUsage, {
      inputTokens: 600,
      cacheReadTokens: 900,
      outputTokens: 300,
      cacheCreateTokens: 0,
      cacheCreate1hTokens: 0,
    });
    assert.deepEqual([...rollout.usageByDayModel.get("2026-07-20")!.keys()].sort(), ["grok-4.5", "grok-4.5-build"]);
  });

  test("scan counts directory-backed sessions and billing-partial disclosure", async () => {
    await withTempDir("trifola-grok-scan-", async (root) => {
      const session = path.join(root, "sessions", "%2FUsers%2Fdev%2Fwork", "session-1");
      writeFile(path.join(session, "summary.json"), JSON.stringify({ info: { id: "session-1", cwd: "/Users/dev/work" } }));
      writeFile(path.join(session, "chat_history.jsonl"), jsonl([{ type: "user", content: "hello" }]).toString());
      writeFile(path.join(session, "updates.jsonl"), jsonl([{
        timestamp: "2026-07-20T10:00:00Z",
        params: { update: { sessionUpdate: "turn_completed", usage: {
          costIsPartial: true,
          modelUsage: { "grok-4.5": { inputTokens: 10, cachedReadTokens: 4, outputTokens: 2 } },
        } } },
      }]).toString());
      const stats = scanGrokSessions(root);
      assert.equal(stats.sessionCount, 1);
      assert.equal(stats.fileCount, 1);
      assert.equal(stats.partialUsageSessions, 1);
      assert.deepEqual(stats.totalUsage, {
        inputTokens: 6, cacheReadTokens: 4, outputTokens: 2,
        cacheCreateTokens: 0, cacheCreate1hTokens: 0,
      });
    });
  });
});
