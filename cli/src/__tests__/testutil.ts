import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";

/** A fresh temp directory for one test; caller removes it (see withTempDir). */
export function mkTempDir(prefix: string): string {
  return fs.mkdtempSync(path.join(os.tmpdir(), prefix));
}

export function rmDir(dir: string): void {
  fs.rmSync(dir, { recursive: true, force: true });
}

/** Write `content` to `filePath`, creating parent directories as needed. */
export function writeFile(filePath: string, content: string): void {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
  fs.writeFileSync(filePath, content, "utf8");
}

/** Run `fn` with a fresh temp dir, always cleaning up afterward — even on throw. */
export async function withTempDir<T>(prefix: string, fn: (dir: string) => T | Promise<T>): Promise<T> {
  const dir = mkTempDir(prefix);
  try {
    return await fn(dir);
  } finally {
    rmDir(dir);
  }
}

/**
 * A tiny, fully synthetic fake `~/.claude` tree (never real user data) with
 * hand-computed KNOWN expected N-of-M and dollar figures. Shared by
 * fixture.test.ts (the in-process pipeline test) and cli.test.ts (the
 * subprocess/entry-point test) so both exercise the exact same numbers.
 *
 * See fixture.test.ts's file header for the full by-hand derivation. Summary:
 *   catalogCount=4, deadCount=2, sessionCount=2, reads=3,
 *   cacheHitRatePct=29, taxUsd≈0.000018, wastedUsd≈9.45, firstTouchUsd≈1.45.
 */
export function buildSyntheticClaudeTree(root: string): void {
  const skillsDir = path.join(root, "skills");
  writeFile(
    path.join(skillsDir, "used-skill", "SKILL.md"),
    ["---", "name: used-skill", "description: Handles the widget pipeline end to end.", "---", "Body."].join("\n")
  );
  writeFile(
    path.join(skillsDir, "used-via-command", "SKILL.md"),
    ["---", "name: used-via-command", "description: Runs the release checklist.", "---", "Body."].join("\n")
  );
  writeFile(
    path.join(skillsDir, "dead-one", "SKILL.md"),
    ["---", "name: dead-one", `description: ${"x".repeat(40)}`, "---", "Body."].join("\n")
  );
  writeFile(
    path.join(skillsDir, "dead-two", "SKILL.md"),
    ["---", "name: dead-two", `description: ${"y".repeat(80)}`, "---", "Body."].join("\n")
  );

  const projDir = path.join(root, "projects", "demo-project");

  const session1 = [
    JSON.stringify({
      type: "assistant",
      requestId: "r1",
      timestamp: "2026-07-01T10:00:00.000Z",
      message: {
        id: "m1",
        model: "claude-opus-4-8",
        content: [{ type: "tool_use", name: "Skill", input: { skill: "used-skill" } }],
        usage: {
          input_tokens: 900_000,
          output_tokens: 80_000,
          cache_creation_input_tokens: 0,
          cache_read_input_tokens: 400_000,
        },
      },
    }),
    JSON.stringify({
      type: "assistant",
      requestId: "r1",
      timestamp: "2026-07-01T10:00:05.000Z",
      message: {
        id: "m1",
        model: "claude-opus-4-8",
        content: [{ type: "text", text: "done" }],
        usage: {
          input_tokens: 1_200_000,
          output_tokens: 150_000,
          cache_creation_input_tokens: 0,
          cache_read_input_tokens: 600_000,
        },
      },
    }),
    JSON.stringify({
      type: "user",
      message: {
        role: "user",
        content: "<command-name>used-via-command</command-name><command-args></command-args>",
      },
    }),
  ].join("\n");
  writeFile(path.join(projDir, "session1.jsonl"), session1);

  const session2 = JSON.stringify({
    type: "assistant",
    requestId: "r2",
    timestamp: "2026-07-01T11:00:00.000Z",
    message: {
      id: "m2",
      model: "claude-sonnet-5",
      content: [{ type: "text", text: "ok" }],
      usage: {
        input_tokens: 2_000_000,
        output_tokens: 200_000,
        cache_creation_input_tokens: 400_000,
        cache_read_input_tokens: 1_000_000,
        cache_creation: { ephemeral_5m_input_tokens: 100_000, ephemeral_1h_input_tokens: 300_000 },
      },
    },
  });
  writeFile(path.join(projDir, "session2.jsonl"), session2);

  const subagent = JSON.stringify({
    type: "assistant",
    requestId: "r3",
    timestamp: "2026-07-01T12:00:00.000Z",
    message: {
      id: "m3",
      model: "claude-haiku-4-5",
      content: [{ type: "text", text: "sub done" }],
      usage: {
        input_tokens: 500_000,
        output_tokens: 50_000,
        cache_creation_input_tokens: 0,
        cache_read_input_tokens: 100_000,
      },
    },
  });
  writeFile(path.join(projDir, "PARENT123", "subagents", "agent-1.jsonl"), subagent);
}
