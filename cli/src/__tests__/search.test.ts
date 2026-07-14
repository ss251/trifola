import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { spawnSync } from "node:child_process";
import * as fs from "node:fs";
import * as path from "node:path";
import { fileURLToPath } from "node:url";
import { withTempDir, writeFile } from "./testutil.js";
import {
  parseSearchArgs,
  searchClaudeProjects,
  tokenizeSearchText,
  type SearchMatch,
} from "../search.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const entry = path.join(here, "..", "trifola.js");

function transcript(root: string, project: string, name: string, records: unknown[]): string {
  const file = path.join(root, "projects", project, `${name}.jsonl`);
  writeFile(file, records.map((record) => JSON.stringify(record)).join("\n"));
  return file;
}

function runCli(args: string[], root: string) {
  const result = spawnSync(process.execPath, [entry, ...args], {
    env: { ...process.env, CLAUDE_CONFIG_DIR: root, NO_COLOR: "1" },
    encoding: "utf8",
  });
  return { stdout: result.stdout, stderr: result.stderr, status: result.status };
}

describe("Claude conversation search", () => {
  test("tokenization is lowercase exact-word search with the documented CJK run limit", () => {
    assert.deepEqual(tokenizeSearchText("Keychain_QUOTA café42 X"), ["keychain", "quota", "café42"]);
    assert.deepEqual(tokenizeSearchText("密钥配额问题"), ["密钥配额问题"]);
    assert.deepEqual(tokenizeSearchText("密"), []);
  });

  test("finds user text and never finds tool-result-only text", async () => {
    await withTempDir("trifola-search-scope-", async (root) => {
      transcript(root, "demo", "scope", [
        { type: "user", sessionId: "scope", message: { content: "Remember the Keychain quota" } },
        {
          type: "user",
          message: { content: [{ type: "tool_result", content: "private tool needle" }] },
        },
      ]);
      const hits: SearchMatch[] = [];
      const summary = searchClaudeProjects(
        path.join(root, "projects"),
        parseSearchArgs(["keychain", "quota"]),
        (match) => hits.push(match),
      );
      assert.equal(summary.emitted, 1);
      assert.equal(hits[0]?.sessionId, "scope");
      assert.equal(hits[0]?.role, "user");

      const misses: SearchMatch[] = [];
      searchClaudeProjects(
        path.join(root, "projects"),
        parseSearchArgs(["tool", "needle"]),
        (match) => misses.push(match),
      );
      assert.deepEqual(misses, []);
    });
  });

  test("phrase matches stream before newer bag-of-words matches", async () => {
    await withTempDir("trifola-search-rank-", async (root) => {
      const phrase = transcript(root, "demo", "phrase", [
        { type: "user", sessionId: "phrase", message: { content: "Keychain quota repair" } },
      ]);
      const bag = transcript(root, "demo", "bag", [
        { type: "user", sessionId: "bag", message: { content: "Quota notes for Keychain repair" } },
      ]);
      const now = new Date();
      fs.utimesSync(phrase, new Date(now.getTime() - 86_400_000), new Date(now.getTime() - 86_400_000));
      fs.utimesSync(bag, now, now);
      const hits: SearchMatch[] = [];
      searchClaudeProjects(
        path.join(root, "projects"),
        parseSearchArgs(["keychain", "quota"]),
        (match) => hits.push(match),
      );
      assert.deepEqual(hits.map((hit) => hit.sessionId), ["phrase", "bag"]);
      assert.equal(hits[0]?.exactPhrase, true);
      assert.equal(hits[1]?.exactPhrase, false);
    });
  });

  test("--json streams result and status objects with raw-output warning", async () => {
    await withTempDir("trifola-search-json-", async (root) => {
      transcript(root, "demo", "json", [
        { type: "ai-title", aiTitle: "Quota investigation" },
        {
          type: "assistant",
          sessionId: "json-session",
          timestamp: "2026-07-01T10:00:00Z",
          message: { content: [{ type: "text", text: "The Keychain quota guard is ready" }] },
        },
      ]);
      const { stdout, status } = runCli(["search", "keychain", "quota", "--json", "--limit", "1"], root);
      assert.equal(status, 0);
      const lines = stdout.trim().split("\n").map((line) => JSON.parse(line));
      assert.equal(lines.length, 2);
      assert.deepEqual(
        Object.keys(lines[0]).sort(),
        [
          "exactPhrase", "filePath", "lastActivity", "matchedTerms", "project",
          "provider", "role", "scope", "score", "sessionId", "snippet", "title",
          "type", "warning",
        ].sort(),
      );
      assert.equal(lines[0].provider, "claude");
      assert.equal(lines[0].scope, "conversation-text");
      assert.match(lines[0].warning, /don't share raw/);
      assert.equal(lines[1].type, "status");
      assert.equal(lines[1].status, "complete");
      assert.equal(lines[1].emitted, 1);
    });
  });

  test("empty corpus is honest in text and JSON modes", async () => {
    await withTempDir("trifola-search-empty-", async (root) => {
      const text = runCli(["search", "keychain"], root);
      assert.equal(text.status, 0);
      assert.match(text.stdout, /No Claude Code session transcripts found/);
      assert.match(text.stdout, /Claude Code conversation text only/);

      const json = runCli(["search", "keychain", "--json"], root);
      assert.equal(json.status, 0);
      const parsed = JSON.parse(json.stdout.trim());
      assert.equal(parsed.type, "status");
      assert.equal(parsed.status, "empty-corpus");
      assert.equal(parsed.scannedFiles, 0);
      assert.match(parsed.warning, /don't share raw/);
    });
  });
});
