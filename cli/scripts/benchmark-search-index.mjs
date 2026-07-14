#!/usr/bin/env node
import { spawn } from "node:child_process";
import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { performance } from "node:perf_hooks";

const FILES = 7_000;
const WARM_RUNS = 30;
const WARMUP_RUNS = 3;
const root = fs.mkdtempSync(path.join(os.tmpdir(), "trifola-search-benchmark-"));
const cache = path.join(root, "cache");
const project = path.join(root, "projects", "benchmark");
const entry = path.resolve("dist", "trifola.js");

fs.mkdirSync(project, { recursive: true });
for (let index = 0; index < FILES; index += 1) {
  const record = {
    type: "user",
    sessionId: `benchmark-${index}`,
    timestamp: new Date(Date.UTC(2026, 0, 1, 0, 0, index % 60)).toISOString(),
    message: {
      content: index % 700 === 0
        ? `Benchmarkneedle commonterm deterministic file ${index}`
        : `Background commonterm deterministic transcript file ${index}`,
    },
  };
  fs.writeFileSync(path.join(project, `${String(index).padStart(4, "0")}.jsonl`), `${JSON.stringify(record)}\n`);
}

const environment = {
  ...process.env,
  HOME: root,
  CLAUDE_CONFIG_DIR: root,
  XDG_CACHE_HOME: cache,
  NO_COLOR: "1",
};

function percentile(values, fraction) {
  const sorted = [...values].sort((left, right) => left - right);
  return sorted[Math.min(sorted.length - 1, Math.ceil(sorted.length * fraction) - 1)];
}

function runSearch() {
  return new Promise((resolve, reject) => {
    const started = performance.now();
    const child = spawn(process.execPath, [entry, "search", "benchmarkneedle", "--json", "--limit", "10"], {
      env: environment,
      stdio: ["ignore", "pipe", "pipe"],
    });
    let stdout = "";
    let stderr = "";
    let firstResultMs = null;
    child.stdout.setEncoding("utf8");
    child.stderr.setEncoding("utf8");
    child.stdout.on("data", (chunk) => {
      stdout += chunk;
      if (firstResultMs === null && stdout.includes("\n")) firstResultMs = performance.now() - started;
    });
    child.stderr.on("data", (chunk) => { stderr += chunk; });
    child.on("error", reject);
    child.on("close", (code) => {
      if (code !== 0) {
        reject(new Error(`search exited ${code}: ${stderr}`));
        return;
      }
      const lines = stdout.trim().split("\n").filter(Boolean).map((line) => JSON.parse(line));
      resolve({
        elapsedMs: performance.now() - started,
        firstResultMs,
        status: lines.at(-1),
      });
    });
  });
}

try {
  const cold = await runSearch();
  for (let index = 0; index < WARMUP_RUNS; index += 1) await runSearch();
  const warm = [];
  for (let index = 0; index < WARM_RUNS; index += 1) warm.push((await runSearch()).elapsedMs);

  for (let index = 0; index < 20; index += 1) {
    const filePath = path.join(project, `${String(index).padStart(4, "0")}.jsonl`);
    fs.appendFileSync(filePath, `${JSON.stringify({
      type: "assistant",
      sessionId: `benchmark-${index}`,
      timestamp: "2026-07-14T12:00:00.000Z",
      message: { content: [{ type: "text", text: `Incremental update ${index}` }] },
    })}\n`);
    const now = new Date();
    fs.utimesSync(filePath, now, now);
  }
  const incremental = await runSearch();
  process.stdout.write(JSON.stringify({
    node: process.version,
    platform: `${process.platform}-${process.arch}`,
    fixtureFiles: FILES,
    cold: {
      firstResultMs: Number(cold.firstResultMs?.toFixed(2)),
      completeMs: Number(cold.elapsedMs.toFixed(2)),
      engine: cold.status.engine,
      indexBuilt: cold.status.indexBuilt,
    },
    warm: {
      runs: WARM_RUNS,
      warmupRuns: WARMUP_RUNS,
      p50Ms: Number(percentile(warm, 0.50).toFixed(2)),
      p95Ms: Number(percentile(warm, 0.95).toFixed(2)),
      minMs: Number(Math.min(...warm).toFixed(2)),
      maxMs: Number(Math.max(...warm).toFixed(2)),
    },
    incremental20: {
      elapsedMs: Number(incremental.elapsedMs.toFixed(2)),
      update: incremental.status.update,
    },
  }, null, 2) + "\n");
} finally {
  fs.rmSync(root, { recursive: true, force: true });
}
