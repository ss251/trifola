// Port of the transcript-accumulation slice of Sources/TrifolaKit/Stores.swift
// (SessionAccumulator + SessionIndex) needed for THIS finding: the dead-skill
// invocation census (Skill tool_use + slash-command <command-name> tags,
// task #41's merge of both lanes) and the deduped, per-(day, model) usage
// map that Audit.swift's cache-leak/first-touch math prices.
//
// Faithful to the Swift accumulator's hard-won rules:
//  - dedup usage on (message.id, requestId), LAST cumulative chunk wins
//    (streaming lines are cumulative, not additive — summing them
//    over-counts spend by ~2.6x, per Stores.swift's own comment).
//  - a day key falls back to the last-seen valid timestamp in the file,
//    then to "" (undated -> priced at today's rate).
//  - isSubagent is a path convention: any path segment literally named
//    "subagents".

import * as fs from "node:fs";
import * as path from "node:path";
import { normalizeModel, addUsageInPlace, emptyUsage, type UsageTotals } from "./pricing.js";

// MARK: - Per-file accumulator state

interface UsageEntry {
  model: string; // normalized
  day: string; // "yyyy-MM-dd" or "" (undated)
  usage: UsageTotals;
}

interface FileState {
  usageByKey: Map<string, UsageEntry>;
  unkeyedSeq: number;
  skillCounts: Map<string, number>;
  commandCounts: Map<string, number>;
  lastDate: Date | null;
  currentModel: string | null;
}

function newFileState(): FileState {
  return {
    usageByKey: new Map(),
    unkeyedSeq: 0,
    skillCounts: new Map(),
    commandCounts: new Map(),
    lastDate: null,
    currentModel: null,
  };
}

function bump(map: Map<string, number>, key: string, n = 1): void {
  map.set(key, (map.get(key) ?? 0) + n);
}

function intOr0(v: unknown): number {
  return typeof v === "number" && Number.isFinite(v) ? Math.trunc(v) : 0;
}

function parseTimestamp(s: unknown): Date | null {
  if (typeof s !== "string" || s.length === 0) return null;
  const d = new Date(s);
  return Number.isNaN(d.getTime()) ? null : d;
}

function localDayKeyOf(d: Date): string {
  const y = d.getFullYear();
  const mo = String(d.getMonth() + 1).padStart(2, "0");
  const da = String(d.getDate()).padStart(2, "0");
  return `${y}-${mo}-${da}`;
}

/** "<command-name>/commit</command-name>..." -> "commit"; null when absent/empty. */
function extractCommandName(text: string): string | null {
  const openTag = "<command-name>";
  const closeTag = "</command-name>";
  const start = text.indexOf(openTag);
  if (start === -1) return null;
  const contentStart = start + openTag.length;
  const end = text.indexOf(closeTag, contentStart);
  if (end === -1) return null;
  let name = text.slice(contentStart, end).trim();
  if (name.startsWith("/")) name = name.slice(1);
  return name.length > 0 ? name : null;
}

// MARK: - Line processing (mirrors SessionAccumulator.consume(line:))

type JsonRecord = Record<string, any>;

function processLine(line: string, st: FileState): void {
  if (line.length === 0) return;
  let obj: unknown;
  try {
    obj = JSON.parse(line);
  } catch {
    return;
  }
  if (obj === null || typeof obj !== "object") return;
  const rec = obj as JsonRecord;

  const ts = parseTimestamp(rec["timestamp"]);
  if (ts !== null && (st.lastDate === null || ts > st.lastDate)) st.lastDate = ts;

  const type = rec["type"];

  // Slash-command census, Shape B — system lines whose top-level `content`
  // string carries a `<command-name>` tag (CLI built-ins mostly land here).
  if (type === "system" && typeof rec["content"] === "string") {
    const name = extractCommandName(rec["content"]);
    if (name) bump(st.commandCounts, name);
  }

  // Slash-command census, Shape A — user lines whose message.content (a
  // plain string, or the first `text` block when it's an array) carries the
  // raw tag.
  if (type === "user" && rec["message"] && typeof rec["message"] === "object") {
    const message = rec["message"] as JsonRecord;
    let raw: string | undefined;
    const content = message["content"];
    if (typeof content === "string") {
      raw = content;
    } else if (Array.isArray(content)) {
      const textBlock = content.find((b) => b && typeof b === "object" && b.type === "text");
      raw = typeof textBlock?.text === "string" ? textBlock.text : undefined;
    }
    if (typeof raw === "string") {
      const name = extractCommandName(raw);
      if (name) bump(st.commandCounts, name);
    }
  }

  if (type !== "assistant") return;
  const message = rec["message"];
  if (!message || typeof message !== "object") return;
  const m = message as JsonRecord;

  if (typeof m["model"] === "string" && m["model"].length > 0) st.currentModel = m["model"];

  // Tool-call census: Skill tool_use only (the dead-skill ledger's raw
  // material). Agent/Task/Edit/Write census is out of scope for this MVP.
  const blocks = m["content"];
  if (Array.isArray(blocks)) {
    for (const block of blocks) {
      if (!block || typeof block !== "object") continue;
      if (block.type === "tool_use" && block.name === "Skill") {
        const input = block.input;
        const skillArg = input && typeof input === "object" ? input.skill : undefined;
        if (typeof skillArg === "string" && skillArg.length > 0) bump(st.skillCounts, skillArg);
      }
    }
  }

  const usage = m["usage"];
  if (!usage || typeof usage !== "object") return;
  const u = usage as JsonRecord;

  const inputTokens = intOr0(u["input_tokens"]);
  const outputTokens = intOr0(u["output_tokens"]);
  const cacheCreateTokens = intOr0(u["cache_creation_input_tokens"]);
  const cacheReadTokens = intOr0(u["cache_read_input_tokens"]);
  const cacheCreationBlock = u["cache_creation"];
  const cache1hRaw =
    cacheCreationBlock && typeof cacheCreationBlock === "object"
      ? intOr0((cacheCreationBlock as JsonRecord)["ephemeral_1h_input_tokens"])
      : 0;
  const cacheCreate1hTokens = Math.min(cacheCreateTokens, cache1hRaw);

  const msgModel = normalizeModel(st.currentModel);
  const dayKey = (ts ? localDayKeyOf(ts) : null) ?? (st.lastDate ? localDayKeyOf(st.lastDate) : null) ?? "";

  const mid = typeof m["id"] === "string" ? m["id"] : "";
  const rid = typeof rec["requestId"] === "string" ? rec["requestId"] : "";
  let key: string;
  if (mid.length > 0 && rid.length > 0) {
    key = `${mid}:${rid}`;
  } else {
    key = `#${st.unkeyedSeq}`;
    st.unkeyedSeq += 1;
  }

  // Last cumulative chunk wins — overwrite, never sum (see file header note).
  st.usageByKey.set(key, {
    model: msgModel,
    day: dayKey,
    usage: { inputTokens, outputTokens, cacheCreateTokens, cacheReadTokens, cacheCreate1hTokens },
  });
}

/** Read a whole file and split on raw newline bytes — faster than readline
 * for a multi-GB transcript corpus, and mirrors the Swift accumulator's own
 * Data-based 0x0A splitting. */
function processFile(filePath: string): FileState {
  const st = newFileState();
  const buf = fs.readFileSync(filePath);
  const len = buf.length;
  let start = 0;
  while (start < len) {
    let nl = buf.indexOf(0x0a, start);
    if (nl === -1) nl = len;
    if (nl > start) {
      processLine(buf.toString("utf8", start, nl), st);
    }
    start = nl + 1;
  }
  return st;
}

// MARK: - Corpus-wide accumulation

export interface CorpusStats {
  /** Non-subagent .jsonl transcript files found — the "S sessions" denominator. */
  sessionCount: number;
  /** Every .jsonl file found (mains + subagents). */
  fileCount: number;
  /** Merged Skill-tool-call + slash-command invocation counts, name -> count. */
  skillFireCounts: Map<string, number>;
  /** Total deduped (message.id:requestId) usage entries across the whole corpus — "R reads". */
  totalDedupedEntries: number;
  /** Fleet-wide token totals (for the cache-hit-rate "H% of R reads" figure). */
  totalUsage: UsageTotals;
  /** day -> normalized model id -> summed usage — what the pricing catalog prices exactly. */
  usageByDayModel: Map<string, Map<string, UsageTotals>>;
}

function newCorpusStats(): CorpusStats {
  return {
    sessionCount: 0,
    fileCount: 0,
    skillFireCounts: new Map(),
    totalDedupedEntries: 0,
    totalUsage: emptyUsage(),
    usageByDayModel: new Map(),
  };
}

function mergeFileIntoCorpus(acc: CorpusStats, st: FileState, isSubagent: boolean): void {
  acc.fileCount += 1;
  if (!isSubagent) acc.sessionCount += 1;

  for (const [name, n] of st.skillCounts) bump(acc.skillFireCounts, name, n);
  for (const [name, n] of st.commandCounts) bump(acc.skillFireCounts, name, n);

  for (const entry of st.usageByKey.values()) {
    acc.totalDedupedEntries += 1;
    addUsageInPlace(acc.totalUsage, entry.usage);

    let byModel = acc.usageByDayModel.get(entry.day);
    if (!byModel) {
      byModel = new Map();
      acc.usageByDayModel.set(entry.day, byModel);
    }
    const existing = byModel.get(entry.model);
    if (existing) {
      addUsageInPlace(existing, entry.usage);
    } else {
      byModel.set(entry.model, { ...entry.usage });
    }
  }
}

/** Recursively collect every `.jsonl` file under `dir` (mirrors
 * FileManager.subpathsOfDirectory + a `.jsonl` suffix filter). Missing/
 * unreadable directories yield an empty list — never throws. */
function walkJsonlFiles(dir: string): string[] {
  const out: string[] = [];
  function walk(d: string): void {
    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(d, { withFileTypes: true });
    } catch {
      return;
    }
    for (const e of entries) {
      const full = path.join(d, e.name);
      if (e.isDirectory()) {
        walk(full);
      } else if (e.isFile() && e.name.endsWith(".jsonl")) {
        out.push(full);
      }
    }
  }
  walk(dir);
  return out;
}

function isSubagentPath(filePath: string): boolean {
  return filePath.split(path.sep).includes("subagents");
}

/**
 * Scan every `.jsonl` transcript under `projectsDir` (mirrors
 * SessionStore.projectsDir + SessionIndex.update). Pure + synchronous;
 * unreadable files are skipped (never thrown), matching the Swift scan's
 * `try?` culture.
 */
export function scanProjects(projectsDir: string): CorpusStats {
  const acc = newCorpusStats();
  const files = walkJsonlFiles(projectsDir);
  for (const file of files) {
    let st: FileState;
    try {
      st = processFile(file);
    } catch {
      continue; // unreadable/vanished file — not counted, matching Swift's SessionIndex
    }
    mergeFileIntoCorpus(acc, st, isSubagentPath(file));
  }
  return acc;
}
