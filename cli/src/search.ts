import * as fs from "node:fs";
import * as path from "node:path";

export const SEARCH_SCOPE = "Claude Code conversation text only (user prompts + assistant prose; tool output excluded)";
export const RAW_WARNING = "don't share raw search output without reviewing conversation text";

export interface SearchRequest {
  raw: string;
  terms: string[];
  limit: number;
  json: boolean;
}

export interface SearchMatch {
  type: "result";
  provider: "claude";
  scope: "conversation-text";
  sessionId: string;
  title: string;
  project: string;
  filePath: string;
  lastActivity: string | null;
  role: "user" | "assistant";
  snippet: string;
  matchedTerms: string[];
  exactPhrase: boolean;
  score: number;
  warning: string;
}

export interface SearchSummary {
  scannedFiles: number;
  emitted: number;
}

interface SearchableEvent {
  role: "user" | "assistant";
  text: string;
}

interface FileMatch {
  match: SearchMatch;
  exactPhrase: boolean;
}

export function tokenizeSearchText(text: string): string[] {
  const runs = text.toLocaleLowerCase("en-US").match(/[\p{L}\p{N}]+/gu) ?? [];
  return runs.filter((token) => token.length >= 2 && token.length <= 64);
}

export function parseSearchArgs(argv: string[]): SearchRequest {
  let limit = 10;
  let json = false;
  const queryParts: string[] = [];
  for (let index = 0; index < argv.length; index += 1) {
    const value = argv[index]!;
    if (value === "--json") {
      json = true;
    } else if (value === "--limit") {
      const raw = argv[index + 1];
      if (!raw || !/^\d+$/.test(raw) || Number(raw) < 1) {
        throw new Error("search --limit requires a positive integer");
      }
      limit = Number(raw);
      index += 1;
    } else if (value.startsWith("--")) {
      throw new Error(`unknown search option ${value}`);
    } else {
      queryParts.push(value);
    }
  }
  const raw = queryParts.join(" ").trim();
  const terms = tokenizeSearchText(raw);
  if (terms.length === 0) {
    throw new Error("search requires one or more word terms");
  }
  return { raw, terms, limit, json };
}

/**
 * Two streaming passes preserve the one global ranking promise without a
 * result buffer: exact-phrase files stream first, then bag-of-words files.
 * Each pass walks newest files first, so recency is the stable tie-breaker.
 */
export function searchClaudeProjects(
  projectsDir: string,
  request: SearchRequest,
  onMatch: (match: SearchMatch) => void,
  onProgress?: (filesDone: number, totalFiles: number, pass: "phrase" | "terms") => void,
): SearchSummary {
  const files = walkJsonlFiles(projectsDir).sort((a, b) => {
    const aTime = safeMtime(a);
    const bTime = safeMtime(b);
    return aTime === bTime ? a.localeCompare(b) : bTime - aTime;
  });
  let emitted = 0;
  let attempts = 0;
  for (const pass of ["phrase", "terms"] as const) {
    for (const filePath of files) {
      onProgress?.(attempts, files.length * 2, pass);
      attempts += 1;
      const found = scanFile(filePath, projectsDir, request);
      if (!found || found.exactPhrase !== (pass === "phrase")) continue;
      onMatch(found.match);
      emitted += 1;
      if (emitted >= request.limit) return { scannedFiles: files.length, emitted };
    }
  }
  return { scannedFiles: files.length, emitted };
}

export function markedSnippet(match: SearchMatch): string {
  let output = match.snippet;
  const terms = [...new Set(match.matchedTerms)].sort((a, b) => b.length - a.length);
  for (const term of terms) {
    const escaped = term.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
    output = output.replace(new RegExp(escaped, "giu"), (value) => `⟦${value}⟧`);
  }
  return output.replace(/\s+/g, " ").trim();
}

export function relativeAge(lastActivity: string | null, now = new Date()): string {
  if (!lastActivity) return "age unknown";
  const date = new Date(lastActivity);
  if (Number.isNaN(date.getTime())) return "age unknown";
  const seconds = Math.max(0, Math.floor((now.getTime() - date.getTime()) / 1000));
  if (seconds < 60) return `${seconds}s ago`;
  if (seconds < 3_600) return `${Math.floor(seconds / 60)}m ago`;
  if (seconds < 86_400) return `${Math.floor(seconds / 3_600)}h ago`;
  return `${Math.floor(seconds / 86_400)}d ago`;
}

function scanFile(filePath: string, projectsDir: string, request: SearchRequest): FileMatch | null {
  let raw: string;
  try {
    raw = fs.readFileSync(filePath, "utf8");
  } catch {
    return null;
  }
  const events: SearchableEvent[] = [];
  let title: string | null = null;
  let sessionId = path.basename(filePath, ".jsonl");
  let lastActivity: Date | null = null;
  for (const line of raw.split("\n")) {
    if (!line) continue;
    let parsed: any;
    try {
      parsed = JSON.parse(line);
    } catch {
      continue;
    }
    if (!parsed || typeof parsed !== "object") continue;
    if (typeof parsed.sessionId === "string" && parsed.sessionId.length > 0) sessionId = parsed.sessionId;
    if (parsed.type === "ai-title" && typeof parsed.aiTitle === "string" && parsed.aiTitle.trim()) {
      title = parsed.aiTitle.trim();
    }
    if (typeof parsed.timestamp === "string") {
      const timestamp = new Date(parsed.timestamp);
      if (!Number.isNaN(timestamp.getTime()) && (!lastActivity || timestamp > lastActivity)) {
        lastActivity = timestamp;
      }
    }
    events.push(...searchableEvents(parsed));
  }
  if (events.length === 0) return null;

  const allTokens = events.flatMap((event) => tokenizeSearchText(event.text));
  const frequencies = new Map<string, number>();
  for (const token of allTokens) frequencies.set(token, (frequencies.get(token) ?? 0) + 1);
  const uniqueTerms = [...new Set(request.terms)];
  if (!uniqueTerms.every((term) => frequencies.has(term))) return null;

  let best: { event: SearchableEvent; score: number; exact: boolean } | null = null;
  for (const event of events) {
    const tokens = tokenizeSearchText(event.text);
    const exact = containsPhrase(tokens, request.terms);
    const present = uniqueTerms.filter((term) => tokens.includes(term)).length;
    if (present === 0) continue;
    const score = (exact ? 1_000 : 0) + present * 100;
    if (!best || score > best.score) best = { event, score, exact };
  }
  if (!best) return null;
  const exactPhrase = events.some((event) =>
    containsPhrase(tokenizeSearchText(event.text), request.terms),
  );
  const stat = safeStat(filePath);
  const activity = lastActivity ?? (stat ? stat.mtime : null);
  const relative = path.relative(projectsDir, filePath).split(path.sep);
  const project = relative.length > 1 ? relative[0]! : path.basename(path.dirname(filePath));
  const fallbackTitle = events.find((event) => event.role === "user")?.text
    .replace(/\s+/g, " ").trim().slice(0, 90) || path.basename(filePath, ".jsonl");
  const hitCount = uniqueTerms.reduce((sum, term) => sum + (frequencies.get(term) ?? 0), 0);
  return {
    exactPhrase,
    match: {
      type: "result",
      provider: "claude",
      scope: "conversation-text",
      sessionId,
      title: title ?? fallbackTitle,
      project,
      filePath,
      lastActivity: activity?.toISOString() ?? null,
      role: best.event.role,
      snippet: excerpt(best.event.text, request.terms),
      matchedTerms: uniqueTerms,
      exactPhrase,
      score: (exactPhrase ? 1_000 : 0) + hitCount * 12,
      warning: RAW_WARNING,
    },
  };
}

function searchableEvents(record: any): SearchableEvent[] {
  if (record.type === "user") {
    if (record.isMeta === true || record.isCompactSummary === true || record.isVisibleInTranscriptOnly === true) return [];
    const content = record.message?.content;
    if (typeof content === "string") {
      const cleaned = cleanUserText(content);
      return cleaned ? [{ role: "user", text: cleaned }] : [];
    }
    if (Array.isArray(content)) {
      return content
        .filter((block: any) => block?.type === "text" && typeof block.text === "string")
        .map((block: any) => cleanUserText(block.text))
        .filter((text: string | null): text is string => text !== null)
        .map((text: string) => ({ role: "user" as const, text }));
    }
  }
  if (record.type === "assistant" && Array.isArray(record.message?.content)) {
    return record.message.content
      .filter((block: any) => block?.type === "text" && typeof block.text === "string" && block.text.trim().length > 0)
      .map((block: any) => ({ role: "assistant" as const, text: block.text }));
  }
  return [];
}

function cleanUserText(text: string): string | null {
  if (text.includes("<local-command-stdout>")) return null;
  let cleaned = text.replace(/<system-reminder>[\s\S]*?<\/system-reminder>/g, " ").trim();
  const command = cleaned.match(/<command-name>([\s\S]*?)<\/command-name>/);
  if (command) {
    const args = cleaned.match(/<command-args>([\s\S]*?)<\/command-args>/)?.[1]?.trim() ?? "";
    cleaned = `${command[1]!.trim()}${args ? ` ${args}` : ""}`;
  }
  if (!cleaned || cleaned.startsWith("Caveat:")) return null;
  return cleaned;
}

function containsPhrase(tokens: string[], phrase: string[]): boolean {
  if (phrase.length === 0 || phrase.length > tokens.length) return false;
  for (let start = 0; start <= tokens.length - phrase.length; start += 1) {
    if (phrase.every((term, offset) => tokens[start + offset] === term)) return true;
  }
  return false;
}

function excerpt(text: string, terms: string[], maximum = 220): string {
  if (text.length <= maximum) return text;
  const lower = text.toLocaleLowerCase("en-US");
  const locations = terms.map((term) => lower.indexOf(term)).filter((value) => value >= 0);
  const location = locations.length > 0 ? Math.min(...locations) : 0;
  const start = Math.max(0, location - Math.floor(maximum / 3));
  const end = Math.min(text.length, start + maximum);
  return `${start > 0 ? "…" : ""}${text.slice(start, end)}${end < text.length ? "…" : ""}`;
}

function walkJsonlFiles(root: string): string[] {
  const output: string[] = [];
  function walk(directory: string): void {
    let entries: fs.Dirent[];
    try {
      entries = fs.readdirSync(directory, { withFileTypes: true });
    } catch {
      return;
    }
    for (const entry of entries) {
      const full = path.join(directory, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.isFile() && entry.name.endsWith(".jsonl")) output.push(full);
    }
  }
  walk(root);
  return output;
}

function safeStat(filePath: string): fs.Stats | null {
  try {
    return fs.statSync(filePath);
  } catch {
    return null;
  }
}

function safeMtime(filePath: string): number {
  return safeStat(filePath)?.mtimeMs ?? 0;
}
