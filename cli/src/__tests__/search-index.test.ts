import { test, describe } from "node:test";
import assert from "node:assert/strict";
import { createHash } from "node:crypto";
import * as fs from "node:fs";
import * as path from "node:path";
import { withTempDir, writeFile } from "./testutil.js";
import { parseSearchArgs, type SearchMatch } from "../search.js";
import {
  SEARCH_SCHEMA_VERSION,
  detectNodeSqlite,
  resolveSearchIndexPaths,
  runTieredSearch,
  type SearchTierInfo,
  type TieredSearchResult,
} from "../search-index.js";

const sqlite = detectNodeSqlite();

function transcript(root: string, name: string, records: unknown[]): string {
  const filePath = path.join(root, "projects", "demo", `${name}.jsonl`);
  writeFile(filePath, records.map((record) => JSON.stringify(record)).join("\n") + "\n");
  return filePath;
}

function codexRollout(root: string, name: string, records: unknown[]): string {
  const filePath = path.join(root, ".codex", "sessions", "2026", "07", "14", `rollout-${name}.jsonl`);
  writeFile(filePath, records.map((record) => JSON.stringify(record)).join("\n") + "\n");
  return filePath;
}

async function execute(
  root: string,
  cache: string,
  args: string[],
  sqliteLoader?: (specifier: string) => unknown,
): Promise<{ result: TieredSearchResult; matches: SearchMatch[]; tiers: SearchTierInfo[]; notices: string[] }> {
  const matches: SearchMatch[] = [];
  const tiers: SearchTierInfo[] = [];
  const notices: string[] = [];
  const environment = {
    ...process.env,
    HOME: root,
    CLAUDE_CONFIG_DIR: root,
    XDG_CACHE_HOME: cache,
    TRIFOLA_SEARCH_INDEX_CACHE: "",
  };
  const result = await runTieredSearch(
    path.join(root, "projects"),
    parseSearchArgs(args),
    {
      onMatch: (match) => matches.push(match),
      onTier: (tier) => tiers.push(tier),
      onNotice: (notice) => notices.push(notice),
    },
    { environment, platform: "linux", home: root, sqliteLoader },
  );
  return { result, matches, tiers, notices };
}

function stableMatch(match: SearchMatch): Omit<SearchMatch, "engine" | "score"> {
  const { engine: _engine, score: _score, ...stable } = match;
  return stable;
}

function digest(filePath: string): string {
  return createHash("sha256").update(fs.readFileSync(filePath)).digest("hex");
}

describe("search index tiers", () => {
  test("Codex documents join Claude in scan and warm Tier 2 with provider labels", { skip: !sqlite }, async () => {
    await withTempDir("trifola-index-codex-", async (root) => {
      const cache = path.join(root, "cache");
      transcript(root, "claude", [
        { type: "user", sessionId: "claude", message: { content: "Shared parityneedle from Claude" } },
      ]);
      codexRollout(root, "codex", [
        { type: "session_meta", payload: { id: "codex", cwd: "/work/codex-demo" } },
        { type: "event_msg", payload: { type: "user_message", message: "Shared parityneedle from Codex" } },
        { type: "response_item", payload: { type: "function_call", arguments: "excludedtoolneedle" } },
      ]);
      const cold = await execute(root, cache, ["parityneedle"]);
      const warm = await execute(root, cache, ["parityneedle"]);
      assert.deepEqual(new Set(cold.matches.map((match) => match.provider)), new Set(["claude", "codex"]));
      const byProvider = (matches: SearchMatch[]) => matches.map(stableMatch)
        .sort((left, right) => left.provider.localeCompare(right.provider));
      assert.deepEqual(byProvider(warm.matches), byProvider(cold.matches));
      assert.equal((await execute(root, cache, ["excludedtoolneedle"])).matches.length, 0);
    });
  });

  test("feature-detected node:sqlite failure preserves Tier 3 and never creates a cache", async () => {
    await withTempDir("trifola-index-tier3-", async (root) => {
      const cache = path.join(root, "cache");
      transcript(root, "scope", [
        { type: "user", sessionId: "scope", message: { content: "Keychain quota" } },
      ]);
      const execution = await execute(root, cache, ["keychain"], () => {
        const error = new Error("missing") as NodeJS.ErrnoException;
        error.code = "ERR_UNKNOWN_BUILTIN_MODULE";
        throw error;
      });
      assert.equal(execution.result.tier, 3);
      assert.equal(execution.result.engine, "scan");
      assert.equal(execution.matches[0]?.engine, "scan");
      assert.match(execution.tiers[0]?.detail ?? "", /Node 22\.5\+ enables the index/);
      assert.equal(fs.existsSync(cache), false);
    });
  });

  test("first search streams scan-equivalent results, then warm search uses the CLI index", { skip: !sqlite }, async () => {
    await withTempDir("trifola-index-first-", async (root) => {
      const cache = path.join(root, "cache");
      transcript(root, "phrase", [
        { type: "user", sessionId: "phrase", timestamp: "2026-07-01T10:00:00Z", message: { content: "Keychain quota repair" } },
      ]);
      transcript(root, "bag", [
        { type: "assistant", sessionId: "bag", timestamp: "2026-07-01T11:00:00Z", message: { content: [{ type: "text", text: "Quota notes for Keychain repair" }] } },
      ]);

      const cold = await execute(root, cache, ["keychain", "quota"]);
      assert.equal(cold.result.engine, "scan");
      assert.equal(cold.result.indexBuilt, true);
      assert.match(cold.notices.join("\n"), /index built — next searches are instant/);
      assert.ok(fs.existsSync(resolveSearchIndexPaths({ XDG_CACHE_HOME: cache }, "linux", root).cli));

      const warm = await execute(root, cache, ["keychain", "quota"]);
      assert.equal(warm.result.engine, "cli-index");
      assert.deepEqual(warm.matches.map(stableMatch), cold.matches.map(stableMatch));
      assert.deepEqual(warm.result.update, {
        rebuilt: 0,
        appended: 0,
        reused: 2,
        removed: 0,
        sourceBytesRead: 0,
      });
    });
  });

  test("append-only update reads the changed suffix and preserves existing terms", { skip: !sqlite }, async () => {
    await withTempDir("trifola-index-append-", async (root) => {
      const cache = path.join(root, "cache");
      const filePath = transcript(root, "append", [
        { type: "user", sessionId: "append", timestamp: "2026-07-01T10:00:00Z", message: { content: "Existing keychain note" } },
      ]);
      await execute(root, cache, ["keychain"]);
      fs.appendFileSync(filePath, JSON.stringify({
        type: "assistant",
        sessionId: "append",
        timestamp: "2026-07-01T10:01:00Z",
        message: { content: [{ type: "text", text: "New appendneedle detail" }] },
      }) + "\n");
      const now = new Date();
      fs.utimesSync(filePath, now, now);

      const appended = await execute(root, cache, ["appendneedle"]);
      assert.equal(appended.result.engine, "cli-index");
      assert.equal(appended.matches[0]?.sessionId, "append");
      assert.equal(appended.result.update?.appended, 1);
      assert.equal(appended.result.update?.rebuilt, 0);
      assert.ok((appended.result.update?.sourceBytesRead ?? 0) < fs.statSync(filePath).size * 2);
      assert.equal((await execute(root, cache, ["keychain"])).matches[0]?.sessionId, "append");
    });
  });

  test("schema mismatch is loudly rebuilt through the user_version ladder", { skip: !sqlite }, async () => {
    await withTempDir("trifola-index-schema-", async (root) => {
      const cache = path.join(root, "cache");
      transcript(root, "schema", [
        { type: "user", sessionId: "schema", message: { content: "Schema ladder needle" } },
      ]);
      await execute(root, cache, ["needle"]);
      const databasePath = resolveSearchIndexPaths({ XDG_CACHE_HOME: cache }, "linux", root).cli;
      const DatabaseSync = (sqlite as any).DatabaseSync;
      const database = new DatabaseSync(databasePath);
      database.exec("PRAGMA user_version=1");
      database.close();

      const rebuilt = await execute(root, cache, ["needle"]);
      assert.equal(rebuilt.result.engine, "scan");
      assert.equal(rebuilt.result.indexBuilt, true);
      assert.match(rebuilt.notices.join("\n"), /schema 1 does not match v3 — rebuilding/);
      const verified = new DatabaseSync(databasePath, { readOnly: true });
      assert.equal(Number(verified.prepare("PRAGMA user_version").get().user_version), SEARCH_SCHEMA_VERSION);
      verified.close();
    });
  });

  test("matching app index is queried read-only without changing bytes or sidecars", { skip: !sqlite }, async () => {
    await withTempDir("trifola-index-app-", async (root) => {
      const buildCache = path.join(root, "build-cache");
      transcript(root, "app", [
        { type: "user", sessionId: "app", message: { content: "Read only appneedle" } },
      ]);
      await execute(root, buildCache, ["appneedle"]);
      const built = resolveSearchIndexPaths({ XDG_CACHE_HOME: buildCache }, "linux", root).cli;
      const environment = { HOME: root, CLAUDE_CONFIG_DIR: root, XDG_CACHE_HOME: path.join(root, "empty-cache") };
      const app = resolveSearchIndexPaths(environment, "linux", root).app;
      fs.mkdirSync(path.dirname(app), { recursive: true });
      fs.copyFileSync(built, app);
      fs.chmodSync(app, 0o444);
      const beforeDigest = digest(app);
      const beforeEntries = fs.readdirSync(path.dirname(app)).sort();

      const matches: SearchMatch[] = [];
      const result = await runTieredSearch(
        path.join(root, "projects"),
        parseSearchArgs(["appneedle"]),
        { onMatch: (match) => matches.push(match) },
        { environment, platform: "linux", home: root },
      );
      assert.equal(result.engine, "app-index");
      assert.equal(matches[0]?.engine, "app-index");
      assert.equal(digest(app), beforeDigest);
      assert.deepEqual(fs.readdirSync(path.dirname(app)).sort(), beforeEntries);
      fs.chmodSync(app, 0o644);
    });
  });

  test("scan and index share prompt/prose projection and exclude tool/system records", { skip: !sqlite }, async () => {
    await withTempDir("trifola-index-parity-", async (root) => {
      const cache = path.join(root, "cache");
      transcript(root, "parity", [
        { type: "user", sessionId: "parity", message: { content: "Visible café42 promptneedle" } },
        { type: "assistant", message: { content: [{ type: "text", text: "Assistant prosenoodle" }] } },
        { type: "assistant", message: { content: [{ type: "tool_use", input: { value: "toolneedle" } }, { type: "thinking", thinking: "thinkneedle" }] } },
        { type: "user", message: { content: [{ type: "tool_result", content: "resultneedle" }] } },
        { type: "system", content: "systemneedle" },
        { type: "summary", summary: "summaryneedle" },
        { type: "user", isMeta: true, message: { content: "metaneedle" } },
      ]);
      const cold = await execute(root, cache, ["promptneedle"]);
      const warm = await execute(root, cache, ["promptneedle"]);
      assert.deepEqual(warm.matches.map(stableMatch), cold.matches.map(stableMatch));
      assert.equal((await execute(root, cache, ["prosenoodle"])).matches.length, 1);
      for (const excluded of ["toolneedle", "thinkneedle", "resultneedle", "systemneedle", "summaryneedle", "metaneedle"]) {
        assert.equal((await execute(root, cache, [excluded])).matches.length, 0, excluded);
      }
    });
  });

  test("--rebuild-index replaces only the CLI-owned index", { skip: !sqlite }, async () => {
    await withTempDir("trifola-index-rebuild-", async (root) => {
      const cache = path.join(root, "cache");
      transcript(root, "rebuild", [
        { type: "user", sessionId: "rebuild", message: { content: "Rebuild needle" } },
      ]);
      await execute(root, cache, ["needle"]);
      const rebuilt = await execute(root, cache, ["--rebuild-index"]);
      assert.equal(rebuilt.result.engine, "scan");
      assert.equal(rebuilt.result.indexBuilt, true);
      assert.match(rebuilt.notices.join("\n"), /rebuilding CLI search index/);
    });
  });
});
