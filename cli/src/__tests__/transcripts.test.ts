import { test, describe } from "node:test";
import assert from "node:assert/strict";
import * as path from "node:path";
import { scanProjects } from "../transcripts.js";
import { withTempDir, writeFile } from "./testutil.js";

// Mirrors the accumulator-level behavior pinned by
// Tests/TrifolaKitTests/AuditTests.swift's ToolCensusTests +
// SkillLedgerTests.sessionCountExcludesSubagents, and the dedup rule from
// Stores.swift's own comment ("last cumulative chunk wins — summing
// over-counted spend ~2.6x").

function assistantLine(opts: {
  model: string;
  requestId: string;
  messageId: string;
  timestamp: string;
  input: number;
  output?: number;
  cacheCreate?: number;
  cacheRead?: number;
  cache1h?: number;
  speed?: string;
  serviceTier?: string;
  toolUseSkill?: string;
}): string {
  const blocks: unknown[] = [];
  if (opts.toolUseSkill) blocks.push({ type: "tool_use", name: "Skill", input: { skill: opts.toolUseSkill } });
  blocks.push({ type: "text", text: "ok" });
  const usage: Record<string, unknown> = {
    input_tokens: opts.input,
    output_tokens: opts.output ?? 0,
    cache_creation_input_tokens: opts.cacheCreate ?? 0,
    cache_read_input_tokens: opts.cacheRead ?? 0,
  };
  if (opts.cache1h) {
    usage["cache_creation"] = { ephemeral_1h_input_tokens: opts.cache1h };
  }
  if (opts.speed !== undefined) usage["speed"] = opts.speed;
  if (opts.serviceTier !== undefined) usage["service_tier"] = opts.serviceTier;
  return JSON.stringify({
    type: "assistant",
    requestId: opts.requestId,
    timestamp: opts.timestamp,
    message: { id: opts.messageId, model: opts.model, content: blocks, usage },
  });
}

describe("scanProjects", () => {
  test("dedups streaming chunks by message.id:requestId — last cumulative chunk wins, never summed", async () => {
    await withTempDir("trifola-dedup-", async (dir) => {
      const lineA = assistantLine({
        model: "claude-opus-4-8",
        requestId: "r1",
        messageId: "m1",
        timestamp: "2026-07-01T10:00:00.000Z",
        input: 100_000,
        output: 10_000,
      });
      const lineB = assistantLine({
        model: "claude-opus-4-8",
        requestId: "r1",
        messageId: "m1",
        timestamp: "2026-07-01T10:00:05.000Z",
        input: 900_000, // cumulative growth, NOT additive
        output: 90_000,
      });
      writeFile(path.join(dir, "proj", "session1.jsonl"), [lineA, lineB].join("\n"));

      const stats = scanProjects(dir);
      assert.equal(stats.totalDedupedEntries, 1); // one message, not two
      assert.equal(stats.totalUsage.inputTokens, 900_000); // last chunk wins
      assert.equal(stats.totalUsage.outputTokens, 90_000);
    });
  });

  test("dedups stable usage keys across files and prefers the parent transcript", async () => {
    await withTempDir("trifola-cross-file-dedup-", async (dir) => {
      const parent = assistantLine({
        model: "claude-opus-4-8", requestId: "shared-request", messageId: "shared-message",
        timestamp: "2026-07-01T10:00:00.000Z", input: 900,
      });
      const copiedSubagent = assistantLine({
        model: "claude-opus-4-8", requestId: "shared-request", messageId: "shared-message",
        timestamp: "2026-07-01T10:00:00.000Z", input: 100,
      });
      writeFile(path.join(dir, "proj", "parent.jsonl"), parent);
      writeFile(path.join(dir, "proj", "parent", "subagents", "agent-copy.jsonl"), copiedSubagent);

      const stats = scanProjects(dir);
      assert.equal(stats.totalDedupedEntries, 1);
      assert.equal(stats.totalUsage.inputTokens, 900);
      assert.equal(stats.usageEntriesByProvider.claude, 1);
    });
  });

  test("merges Skill tool_use invocations across sessions", async () => {
    await withTempDir("trifola-skillcount-", async (dir) => {
      const s1 = assistantLine({
        model: "claude-opus-4-8",
        requestId: "r1",
        messageId: "m1",
        timestamp: "2026-07-01T10:00:00.000Z",
        input: 1000,
        toolUseSkill: "code-review",
      });
      const s2 = assistantLine({
        model: "claude-opus-4-8",
        requestId: "r2",
        messageId: "m2",
        timestamp: "2026-07-01T11:00:00.000Z",
        input: 1000,
        toolUseSkill: "code-review",
      });
      writeFile(path.join(dir, "proj", "session1.jsonl"), s1);
      writeFile(path.join(dir, "proj", "session2.jsonl"), s2);

      const stats = scanProjects(dir);
      assert.equal(stats.skillFireCounts.get("code-review"), 2);
    });
  });

  test("merges slash-command invocations (task #41: a skill fired only via /name still counts)", async () => {
    await withTempDir("trifola-slash-", async (dir) => {
      const userLine = JSON.stringify({
        type: "user",
        message: { role: "user", content: "<command-name>my-skill</command-name><command-args></command-args>" },
      });
      const systemLine = JSON.stringify({ type: "system", subtype: "cli", content: "<command-name>doctor</command-name>" });
      writeFile(path.join(dir, "proj", "session1.jsonl"), [userLine, systemLine].join("\n"));

      const stats = scanProjects(dir);
      assert.equal(stats.skillFireCounts.get("my-skill"), 1);
      assert.equal(stats.skillFireCounts.get("doctor"), 1);
    });
  });

  test("malformed lines and lines with no tool calls never crash and leave the census untouched", async () => {
    await withTempDir("trifola-malformed-", async (dir) => {
      const noise = ["not json at all", "", JSON.stringify({ type: "queue-operation", foo: "bar" }), "{broken"].join(
        "\n"
      );
      writeFile(path.join(dir, "proj", "session1.jsonl"), noise);
      const stats = scanProjects(dir);
      assert.equal(stats.skillFireCounts.size, 0);
      assert.equal(stats.totalDedupedEntries, 0);
      assert.equal(stats.sessionCount, 1); // the file itself still counts as a session
    });
  });

  test("subagent transcripts are excluded from sessionCount but included in usage totals", async () => {
    await withTempDir("trifola-subagent-", async (dir) => {
      const main = assistantLine({
        model: "claude-opus-4-8",
        requestId: "r1",
        messageId: "m1",
        timestamp: "2026-07-01T10:00:00.000Z",
        input: 1_000_000,
      });
      const sub = assistantLine({
        model: "claude-haiku-4-5",
        requestId: "r2",
        messageId: "m2",
        timestamp: "2026-07-01T10:05:00.000Z",
        input: 500_000,
      });
      writeFile(path.join(dir, "proj", "PARENT123.jsonl"), main);
      writeFile(path.join(dir, "proj", "PARENT123", "subagents", "agent-1.jsonl"), sub);

      const stats = scanProjects(dir);
      assert.equal(stats.fileCount, 2);
      assert.equal(stats.sessionCount, 1); // only the main transcript counts
      assert.equal(stats.totalUsage.inputTokens, 1_500_000); // but the subagent's tokens still count
    });
  });

  test("buckets usage by the message's own local day and normalized model", async () => {
    await withTempDir("trifola-daybucket-", async (dir) => {
      const day1 = assistantLine({
        model: "us.anthropic.claude-opus-4-8",
        requestId: "r1",
        messageId: "m1",
        timestamp: "2026-07-05T10:00:00.000Z",
        input: 100_000,
      });
      const day2 = assistantLine({
        model: "claude-sonnet-5",
        requestId: "r2",
        messageId: "m2",
        timestamp: "2026-07-06T10:00:00.000Z",
        input: 200_000,
      });
      writeFile(path.join(dir, "proj", "session1.jsonl"), [day1, day2].join("\n"));

      const stats = scanProjects(dir);
      const d1 = stats.usageByDayModel.get("2026-07-05");
      const d2 = stats.usageByDayModel.get("2026-07-06");
      assert.equal(d1?.get("claude-opus-4-8")?.inputTokens, 100_000); // provider prefix normalized away
      assert.equal(d2?.get("claude-sonnet-5")?.inputTokens, 200_000);
    });
  });

  test("missing projects directory yields empty stats, never throws", () => {
    const stats = scanProjects(`/nonexistent/${Date.now()}-${Math.random()}`);
    assert.equal(stats.sessionCount, 0);
    assert.equal(stats.fileCount, 0);
    assert.equal(stats.totalDedupedEntries, 0);
  });

  test("clamps malformed token fields and bounds 1h cache creation", async () => {
    await withTempDir("trifola-clamps-", async (dir) => {
      const negative = assistantLine({
        model: "claude-opus-4-8", requestId: "r1", messageId: "m1",
        timestamp: "2026-07-01T10:00:00.000Z", input: -10, output: -20,
        cacheCreate: -30, cacheRead: -40, cache1h: -50,
      });
      const oversized = assistantLine({
        model: "claude-opus-4-8", requestId: "r2", messageId: "m2",
        timestamp: "2026-07-01T10:01:00.000Z", input: 1, output: 2,
        cacheCreate: 100, cacheRead: 3, cache1h: 900,
      });
      writeFile(path.join(dir, "p", "s.jsonl"), [negative, oversized].join("\n"));
      const usage = scanProjects(dir).totalUsage;
      assert.deepEqual(usage, {
        inputTokens: 1, outputTokens: 2, cacheCreateTokens: 100,
        cacheReadTokens: 3, cacheCreate1hTokens: 100,
      });
    });
  });

  test("counts non-standard speed/service tiers once per deduped entry", async () => {
    await withTempDir("trifola-speed-", async (dir) => {
      const standard = assistantLine({
        model: "claude-opus-4-8", requestId: "r1", messageId: "m1",
        timestamp: "2026-07-01T10:00:00.000Z", input: 1, speed: "standard",
      });
      const fastChunk = assistantLine({
        model: "claude-opus-4-8", requestId: "r2", messageId: "m2",
        timestamp: "2026-07-01T10:01:00.000Z", input: 1, speed: "fast",
      });
      const batchLastChunk = assistantLine({
        model: "claude-opus-4-8", requestId: "r2", messageId: "m2",
        timestamp: "2026-07-01T10:02:00.000Z", input: 2, serviceTier: "batch",
      });
      writeFile(path.join(dir, "p", "s.jsonl"), [standard, fastChunk, batchLastChunk].join("\n"));
      const stats = scanProjects(dir);
      assert.equal(stats.totalDedupedEntries, 2);
      assert.equal(stats.unsupportedPricingModeEntries, 1);
      assert.equal(stats.totalUsage.inputTokens, 3);
    });
  });
});
