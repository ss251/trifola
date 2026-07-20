#!/usr/bin/env node
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { spawnSync } from "node:child_process";
import { DatabaseSync } from "node:sqlite";
import { fileURLToPath } from "node:url";
import { scanProjects, withCodexCorpus, withGrokCorpus } from "../dist/transcripts.js";
import { scanCodexSessions } from "../dist/codex.js";
import { scanGrokSessions } from "../dist/grok.js";
import { costOfUsage, resolvedRate } from "../dist/pricing.js";
import { resolveSearchIndexPaths } from "../dist/search-index.js";

const here = path.dirname(fileURLToPath(import.meta.url));
const cliRoot = path.dirname(here);
const entry = path.join(cliRoot, "dist", "trifola.js");

function parseArgs(argv) {
  const result = { app: process.env.TRIFOLA_APP_BINARY || "", days: [] };
  for (let i = 0; i < argv.length; i += 1) {
    if (argv[i] === "--app") result.app = argv[++i] || "";
    else if (argv[i] === "--days") {
      while (argv[i + 1] && !argv[i + 1].startsWith("--")) result.days.push(argv[++i]);
    } else throw new Error(`unknown option ${argv[i]}`);
  }
  return result;
}

function resolveApp(explicit) {
  const candidates = [
    explicit,
    path.join(path.dirname(cliRoot), "dist", "trifola.app", "Contents", "MacOS", "Trifola"),
    path.join(path.dirname(cliRoot), ".build", "debug", "Trifola"),
    path.join(path.dirname(cliRoot), ".build", "arm64-apple-macosx", "debug", "Trifola"),
  ].filter(Boolean);
  return candidates.find((candidate) => fs.existsSync(candidate)) || "";
}

function snapshotDatabase(source) {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), "trifola-parity-db-"));
  const target = path.join(directory, "search-index.sqlite3");
  fs.copyFileSync(source, target);
  if (fs.existsSync(source + "-wal")) fs.copyFileSync(source + "-wal", target + "-wal");
  return { target, cleanup: () => fs.rmSync(directory, { recursive: true, force: true }) };
}

function indexFacts(databasePath) {
  const database = new DatabaseSync(databasePath, { readOnly: true });
  database.exec("PRAGMA query_only=ON");
  const documents = new Map();
  const sessions = new Map();
  const rows = new Map();
  for (const row of database.prepare("SELECT provider, count(*) AS n FROM documents GROUP BY provider").all()) {
    documents.set(String(row.provider), Number(row.n));
  }
  for (const row of database.prepare("SELECT DISTINCT provider, session_id FROM documents").all()) {
    const provider = String(row.provider);
    if (!sessions.has(provider)) sessions.set(provider, new Set());
    sessions.get(provider).add(String(row.session_id));
  }
  for (const row of database.prepare(`
    SELECT d.provider, d.session_id, count(r.rowid) AS n
    FROM documents d
    LEFT JOIN search_rows r ON r.document_key=d.key AND r.scope='conversation'
    GROUP BY d.provider, d.session_id
  `).all()) {
    rows.set(`${row.provider}\u0001${row.session_id}`, Number(row.n));
  }
  database.close();
  return { documents, sessions, rows };
}

function setDiff(left, right) {
  return [...left].filter((value) => !right.has(value));
}

function compareIndexes(app, cli) {
  const checks = [];
  for (const provider of ["claude", "codex", "grok"]) {
    // Claude/Codex keep their pre-existing exact contract; only the Grok
    // corpus — snapshotted twice while sessions may still be writing — is
    // allowed the small live-drift tolerances.
    const documentTolerance = provider === "grok" ? 2 : 0;
    const sessionTolerance = provider === "grok" ? 2 : 0;
    const rowTolerance = provider === "grok" ? 10 : 0;
    const appSessions = app.sessions.get(provider) || new Set();
    const cliSessions = cli.sessions.get(provider) || new Set();
    const missing = setDiff(appSessions, cliSessions);
    const extra = setDiff(cliSessions, appSessions);
    const appDocumentCount = app.documents.get(provider) || 0;
    const cliDocumentCount = cli.documents.get(provider) || 0;
    const documentDrift = Math.abs(appDocumentCount - cliDocumentCount);
    checks.push({
      check: `search documents · ${provider}`,
      pass: documentDrift <= documentTolerance,
      detail: `app ${appDocumentCount} · cli ${cliDocumentCount}${documentDrift && documentTolerance ? ` · live drift ≤${documentTolerance}` : ""}`,
    });
    checks.push({
      check: `session-id set · ${provider}`,
      pass: missing.length + extra.length <= sessionTolerance,
      detail: `missing ${missing.length}${missing.length ? ` [${missing.slice(0, 3).join(", ")}]` : ""} · extra ${extra.length}${extra.length ? ` [${extra.slice(0, 3).join(", ")}]` : ""}${missing.length + extra.length && sessionTolerance ? ` · live drift ≤${sessionTolerance}` : ""}`,
    });
    const keys = new Set([...app.rows.keys(), ...cli.rows.keys()].filter((key) => key.startsWith(provider + "\u0001")));
    const mismatches = [...keys].filter((key) => (app.rows.get(key) || 0) !== (cli.rows.get(key) || 0));
    checks.push({
      check: `conversation rows · ${provider}`,
      pass: mismatches.length <= rowTolerance,
      detail: mismatches.length === 0
        ? `${keys.size} sessions exact`
        : `${mismatches.length} ${rowTolerance ? `live row drift${mismatches.length <= rowTolerance ? ` (within ≤${rowTolerance} bound)` : ""}` : "mismatches"} [${mismatches.slice(0, 3).map((key) => `${key.split("\u0001")[1]} app=${app.rows.get(key) || 0}/cli=${cli.rows.get(key) || 0}`).join(", ")}]`,
    });
  }
  return checks;
}

function cliCorpus(claudeRoot, codexHome, grokHome) {
  return withGrokCorpus(
    withCodexCorpus(scanProjects(claudeRoot), scanCodexSessions(codexHome)),
    scanGrokSessions(grokHome),
  );
}

function localDay(date) {
  return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
}

function parseAppMoney(output) {
  const days = new Map();
  const totals = new Map();
  let day = null;
  let pricing = "";
  for (const line of output.split(/\r?\n/)) {
    if (line.startsWith("pricing:")) pricing = line.slice("pricing:".length).trim();
    const heading = line.match(/^--- (\d{4}-\d{2}-\d{2}) ---$/);
    if (heading) { day = heading[1]; days.set(day, new Map()); continue; }
    if (!day) continue;
    const row = line.match(/^\s+(\S+)\s+in=\s*(\d+)\s+cr=\s*(\d+)\s+cc=\s*(\d+)\s+cc1h=\s*(\d+)\s+out=\s*(\d+)\s+\$\s*([\d.]+)/);
    if (row) {
      days.get(day).set(row[1], {
        inputTokens: Number(row[2]), cacheReadTokens: Number(row[3]),
        cacheCreateTokens: Number(row[4]), cacheCreate1hTokens: Number(row[5]),
        outputTokens: Number(row[6]), cents: Math.round(Number(row[7]) * 100),
      });
    }
    const total = line.match(/^\s+TOTAL\s+\$\s*([\d.]+)/);
    if (total) totals.set(day, Math.round(Number(total[1]) * 100));
  }
  return { pricing, days, totals };
}

function compareMoney(cli, app, selectedDays) {
  const checks = [];
  let modelRows = 0;
  let mismatches = [];
  let totalMismatches = [];
  for (const day of selectedDays) {
    const cliModels = cli.get(day) || new Map();
    const appModels = app.days.get(day) || new Map();
    const models = new Set([
      ...[...cliModels].filter(([, usage]) => Object.values(usage).some((value) => value > 0)).map(([model]) => model),
      ...appModels.keys(),
    ]);
    for (const model of models) {
      modelRows += 1;
      const usage = cliModels.get(model) || { inputTokens: 0, outputTokens: 0, cacheCreateTokens: 0, cacheReadTokens: 0, cacheCreate1hTokens: 0 };
      const expected = { ...usage, cents: Math.round(costOfUsage(usage, resolvedRate(model, day)) * 100) };
      const actual = appModels.get(model);
      if (!actual || ["inputTokens", "cacheReadTokens", "cacheCreateTokens", "cacheCreate1hTokens", "outputTokens", "cents"]
        .some((key) => expected[key] !== actual[key])) {
        mismatches.push(`${day}/${model} app=${actual ? JSON.stringify(actual) : "missing"} cli=${JSON.stringify(expected)}`);
      }
    }
    let cliTotal = 0;
    for (const [model, usage] of cliModels) {
      if (Object.values(usage).some((value) => value > 0)) cliTotal += costOfUsage(usage, resolvedRate(model, day));
    }
    const expectedTotalCents = Math.round(cliTotal * 100);
    const actualTotalCents = app.totals.get(day);
    if (actualTotalCents !== expectedTotalCents) {
      totalMismatches.push(`${day} app=${actualTotalCents ?? "missing"} cli=${expectedTotalCents}`);
    }
  }
  checks.push({
    check: "money · day/model tokens+cents",
    pass: mismatches.length === 0,
    detail: mismatches.length === 0 ? `${modelRows} model-day rows exact` : `${mismatches.length} mismatches [${mismatches.slice(0, 3).join("; ")}]`,
  });
  checks.push({
    check: "money · daily total cents",
    pass: totalMismatches.length === 0,
    detail: totalMismatches.length === 0 ? `${selectedDays.length} daily totals exact` : `${totalMismatches.length} mismatches [${totalMismatches.slice(0, 3).join("; ")}]`,
  });
  return checks;
}

function compareGrok(app, scan) {
  const checks = [];
  const cliTotalTokens = Object.values(scan.totalUsage).reduce((sum, value) => sum + value, 0);
  // Session count is a live-mutable quantity: a session written between the
  // app and CLI snapshots legitimately shifts it by ±1-2, exactly as the
  // generic `session-id set` check already tolerates (≤2). An exact equality
  // here would be stricter than its own sibling and flap on a live corpus.
  const sessionCountDrift = Math.abs(Number(app.sessionCount) - scan.sessionCount);
  checks.push({
    check: "grok · session count",
    pass: sessionCountDrift <= 2,
    detail: `app ${app.sessionCount} · cli ${scan.sessionCount}${sessionCountDrift ? " · live drift ≤2" : ""}`,
  });
  checks.push({
    check: "grok · total tokens",
    pass: Number(app.totalTokens) === cliTotalTokens,
    detail: `app ${app.totalTokens} · cli ${cliTotalTokens}`,
  });
  checks.push({
    check: "grok · billing-partial sessions",
    pass: Number(app.partialSessions) === scan.partialUsageSessions,
    detail: `app ${app.partialSessions} · cli ${scan.partialUsageSessions}`,
  });
  const mismatches = [];
  const appDays = app.modelDays || {};
  const days = new Set([...Object.keys(appDays), ...scan.usageByDayModel.keys()]);
  let rows = 0;
  for (const day of days) {
    const appModels = appDays[day] || {};
    const cliModels = scan.usageByDayModel.get(day) || new Map();
    const models = new Set([...Object.keys(appModels), ...cliModels.keys()]);
    for (const model of models) {
      rows += 1;
      const usage = cliModels.get(model) || { inputTokens: 0, outputTokens: 0, cacheCreateTokens: 0, cacheReadTokens: 0, cacheCreate1hTokens: 0 };
      const expected = { ...usage, cents: Math.round(costOfUsage(usage, resolvedRate(model, day)) * 100) };
      const actual = appModels[model];
      if (!actual || Object.keys(expected).some((key) => expected[key] !== actual[key])) {
        mismatches.push(`${day}/${model} app=${actual ? JSON.stringify(actual) : "missing"} cli=${JSON.stringify(expected)}`);
      }
    }
  }
  checks.push({
    check: "grok · day/model tokens+cents",
    pass: mismatches.length === 0,
    detail: mismatches.length === 0 ? `${rows} model-day rows exact` : `${mismatches.length} mismatches [${mismatches.slice(0, 3).join("; ")}]`,
  });
  return checks;
}

function printTable(checks) {
  const width = Math.max(...checks.map((row) => row.check.length), 5);
  console.log(`| ${"CHECK".padEnd(width)} | RESULT | DETAIL |`);
  console.log(`|-${"-".repeat(width)}-|--------|--------|`);
  for (const row of checks) console.log(`| ${row.check.padEnd(width)} | ${row.pass ? "PASS" : "FAIL"} | ${row.detail.replaceAll("|", "\\|")} |`);
  console.log(`\nOVERALL: ${checks.every((row) => row.pass) ? "PASS" : "FAIL"}`);
}

const options = parseArgs(process.argv.slice(2));
const appBinary = resolveApp(options.app);
if (!appBinary) throw new Error("Trifola binary not found; pass --app PATH or set TRIFOLA_APP_BINARY");
if (!fs.existsSync(entry)) throw new Error("CLI dist missing; run npm run build first");

const environment = { ...process.env };
const home = environment.HOME || os.homedir();
const claudeHome = environment.CLAUDE_CONFIG_DIR || path.join(home, ".claude");
const codexHome = environment.CODEX_HOME || path.join(home, ".codex");
const grokHome = environment.GROK_HOME || path.join(home, ".grok");
const appIndexPath = resolveSearchIndexPaths(environment, process.platform, home).app;
// The app contract refreshes its index synchronously before emitting aggregate
// Grok facts, so the search snapshot and usage checks compare one generation.
const appGrok = spawnSync(appBinary, ["--grok-parity"], {
  env: { ...environment, CLAUDE_CONFIG_DIR: claudeHome, CODEX_HOME: codexHome, GROK_HOME: grokHome },
  encoding: "utf8",
  maxBuffer: 128 * 1024 * 1024,
});
if (appGrok.status !== 0) throw new Error(`app Grok parity command failed: ${appGrok.stderr || appGrok.stdout}`);
const appGrokPayload = JSON.parse(appGrok.stdout);
// Capture the independent parser immediately after the app scan. The corpus is
// live; deferring this until after multi-minute index work makes active turns
// look like parser disagreement.
const grokScan = scanGrokSessions(grokHome);
if (!fs.existsSync(appIndexPath)) throw new Error(`app search index not found: ${appIndexPath}`);

const temp = fs.mkdtempSync(path.join(os.tmpdir(), "trifola-parity-cli-"));
let appSnapshot;
try {
  const rebuild = spawnSync(process.execPath, [entry, "search", "--rebuild-index", "--json"], {
    env: { ...environment, XDG_CACHE_HOME: temp, CLAUDE_CONFIG_DIR: claudeHome, CODEX_HOME: codexHome, GROK_HOME: grokHome, NO_COLOR: "1" },
    encoding: "utf8",
    maxBuffer: 64 * 1024 * 1024,
  });
  if (rebuild.status !== 0) throw new Error(`CLI index build failed: ${rebuild.stderr || rebuild.stdout}`);
  const cliIndexPath = path.join(temp, "trifola", "search-index.sqlite3");
  appSnapshot = snapshotDatabase(appIndexPath);
  const checks = compareIndexes(indexFacts(appSnapshot.target), indexFacts(cliIndexPath));

  const now = new Date();
  const days = options.days.length > 0
    ? options.days
    : [localDay(new Date(now.getTime() - 2 * 86_400_000)), localDay(new Date(now.getTime() - 86_400_000))];
  const spend = spawnSync(appBinary, ["--spend-by-model", ...days], {
    env: { ...environment, CLAUDE_CONFIG_DIR: claudeHome, CODEX_HOME: codexHome, GROK_HOME: grokHome },
    encoding: "utf8",
    maxBuffer: 128 * 1024 * 1024,
  });
  if (spend.status !== 0) throw new Error(
    `app spend command failed (status=${spend.status}, signal=${spend.signal}, error=${spend.error?.message || "none"}): ${spend.stderr || spend.stdout}`,
  );
  const appUsage = parseAppMoney(spend.stdout);
  const corpus = cliCorpus(path.join(claudeHome, "projects"), codexHome, grokHome);
  const cliUsage = corpus.usageByDayModel;
  checks.push({ check: "pricing catalog", pass: appUsage.pricing.startsWith("bundled 2026-07-21"), detail: appUsage.pricing || "missing" });
  checks.push(...compareMoney(cliUsage, appUsage, days));
  checks.push(...compareGrok(appGrokPayload, grokScan));
  printTable(checks);
  process.exitCode = checks.every((row) => row.pass) ? 0 : 1;
} finally {
  appSnapshot?.cleanup();
  fs.rmSync(temp, { recursive: true, force: true });
}
