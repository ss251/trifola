import * as fs from "node:fs";
import * as path from "node:path";
import { codexRolloutIsImported, loadCodexImportManifest, readCodexRollout, parseCodexRollout, walkCodexRollouts, } from "./codex.js";
export const SEARCH_SCOPE = "Claude Code + Codex conversation text (user prompts + assistant prose; tool output excluded)";
export const RAW_WARNING = "don't share raw search output without reviewing conversation text";
export const MAX_ORDERED_TOKENS_PER_DOCUMENT = 20_000;
export function tokenizeSearchText(text) {
    const runs = text.toLocaleLowerCase("en-US").match(/[\p{L}\p{N}]+/gu) ?? [];
    return runs.filter((token) => {
        const length = Array.from(token).length;
        return length >= 2 && length <= 64;
    });
}
export function parseSearchArgs(argv) {
    let limit = 10;
    let json = false;
    let rebuildIndex = false;
    const queryParts = [];
    for (let index = 0; index < argv.length; index += 1) {
        const value = argv[index];
        if (value === "--json") {
            json = true;
        }
        else if (value === "--rebuild-index") {
            rebuildIndex = true;
        }
        else if (value === "--limit") {
            const raw = argv[index + 1];
            if (!raw || !/^\d+$/.test(raw) || Number(raw) < 1) {
                throw new Error("search --limit requires a positive integer");
            }
            limit = Number(raw);
            index += 1;
        }
        else if (value.startsWith("--")) {
            throw new Error(`unknown search option ${value}`);
        }
        else {
            queryParts.push(value);
        }
    }
    const raw = queryParts.join(" ").trim();
    const terms = tokenizeSearchText(raw);
    if (terms.length === 0 && !rebuildIndex) {
        throw new Error("search requires one or more word terms");
    }
    return { raw, terms, limit, json, rebuildIndex };
}
/**
 * The scan fallback deliberately retains the existing phrase-first two-pass
 * behavior. It is the compatibility path for Node versions without node:sqlite
 * and the result-serving path while a first CLI index is built.
 */
export function searchClaudeProjects(projectsDir, request, onMatch, onProgress) {
    return searchCorpora({ claude: projectsDir, codex: path.join(projectsDir, ".codex-disabled"), codexHome: path.dirname(projectsDir) }, request, onMatch, onProgress);
}
export function searchCorpora(roots, request, onMatch, onProgress) {
    const files = collectSearchFiles(roots).sort((a, b) => {
        const aTime = safeMtime(a.filePath);
        const bTime = safeMtime(b.filePath);
        return aTime === bTime ? a.filePath.localeCompare(b.filePath) : bTime - aTime;
    });
    if (request.terms.length === 0)
        return { scannedFiles: files.length, emitted: 0 };
    let emitted = 0;
    let attempts = 0;
    for (const pass of ["phrase", "terms"]) {
        for (const source of files) {
            onProgress?.(attempts, files.length * 2, pass);
            attempts += 1;
            const found = scanFile(source, request);
            if (!found || found.exactPhrase !== (pass === "phrase"))
                continue;
            onMatch(found.match);
            emitted += 1;
            if (emitted >= request.limit)
                return { scannedFiles: files.length, emitted };
        }
    }
    return { scannedFiles: files.length, emitted };
}
export function markedSnippet(match) {
    let output = match.snippet;
    const terms = [...new Set(match.matchedTerms)].sort((a, b) => b.length - a.length);
    for (const term of terms) {
        const escaped = term.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
        output = output.replace(new RegExp(escaped, "giu"), (value) => `⟦${value}⟧`);
    }
    return output.replace(/\s+/g, " ").trim();
}
export function relativeAge(lastActivity, now = new Date()) {
    if (!lastActivity)
        return "age unknown";
    const date = new Date(lastActivity);
    if (Number.isNaN(date.getTime()))
        return "age unknown";
    const seconds = Math.max(0, Math.floor((now.getTime() - date.getTime()) / 1000));
    if (seconds < 60)
        return `${seconds}s ago`;
    if (seconds < 3_600)
        return `${Math.floor(seconds / 60)}m ago`;
    if (seconds < 86_400)
        return `${Math.floor(seconds / 3_600)}h ago`;
    return `${Math.floor(seconds / 86_400)}d ago`;
}
export function readSearchDocument(filePath, projectsDir, seed) {
    const provider = seed?.provider ?? "claude";
    if (provider === "codex") {
        const read = readCodexRollout(filePath);
        if (!read.rollout)
            return null;
        return codexSearchDocument(read.rollout, filePath, projectsDir, seed);
    }
    let data;
    try {
        data = fs.readFileSync(filePath);
    }
    catch {
        return null;
    }
    return parseSearchBuffer(data, filePath, projectsDir, seed);
}
/** Parse JSONL bytes and report the durable byte offset consumed. */
export function parseSearchBuffer(data, filePath, projectsDir, seed) {
    if (seed?.provider === "codex") {
        return codexSearchDocument(parseCodexRollout(data, path.basename(filePath).replace(/\.jsonl(?:\.zst)?$/, "")), filePath, projectsDir, seed);
    }
    let sessionId = seed?.sessionId ?? path.basename(filePath, ".jsonl");
    let title = seed?.title ?? "";
    let cwd = seed?.cwd ?? "";
    let lastActivity = seed?.lastActivity ? new Date(seed.lastActivity) : null;
    const events = [];
    let consumedBytes = 0;
    const consume = (line) => {
        if (line.length === 0)
            return true;
        let parsed;
        try {
            parsed = JSON.parse(line.toString("utf8"));
        }
        catch {
            return false;
        }
        if (!parsed || typeof parsed !== "object")
            return true;
        if (typeof parsed.sessionId === "string" && parsed.sessionId.length > 0)
            sessionId = parsed.sessionId;
        if (typeof parsed.cwd === "string" && parsed.cwd.trim())
            cwd = parsed.cwd.trim();
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
        return true;
    };
    let start = 0;
    while (start < data.length) {
        const newline = data.indexOf(0x0a, start);
        if (newline < 0)
            break;
        consume(data.subarray(start, newline));
        consumedBytes = newline + 1;
        start = newline + 1;
    }
    if (start < data.length && consume(data.subarray(start)))
        consumedBytes = data.length;
    const relative = path.relative(projectsDir, filePath).split(path.sep);
    const project = relative.length > 1 ? relative[0] : path.basename(path.dirname(filePath));
    const fallbackTitle = events.find((event) => event.role === "user")?.text
        .replace(/\s+/g, " ").trim().slice(0, 90) || path.basename(filePath, ".jsonl");
    if (filePath.split(path.sep).includes("subagents")) {
        sessionId = `${sessionId}/${path.basename(filePath, ".jsonl")}`;
    }
    return {
        provider: "claude",
        sessionId,
        title: title || fallbackTitle,
        project,
        cwd: cwd || project,
        filePath,
        lastActivity: lastActivity && !Number.isNaN(lastActivity.getTime())
            ? lastActivity.toISOString()
            : null,
        events,
        consumedBytes,
    };
}
export function searchMatchForDocument(document, request, engine, exactPhraseOverride, scoreOverride) {
    const allTokens = document.events.flatMap((event) => tokenizeSearchText(event.text));
    const frequencies = new Map();
    for (const token of allTokens)
        frequencies.set(token, (frequencies.get(token) ?? 0) + 1);
    const uniqueTerms = [...new Set(request.terms)];
    if (!uniqueTerms.every((term) => frequencies.has(term)))
        return null;
    let best = null;
    for (const event of document.events) {
        const tokens = tokenizeSearchText(event.text);
        const exact = containsPhrase(tokens, request.terms);
        const present = uniqueTerms.filter((term) => tokens.includes(term)).length;
        if (present === 0)
            continue;
        const score = (exact ? 1_000 : 0) + present * 100;
        if (!best || score > best.score)
            best = { event, score };
    }
    if (!best)
        return null;
    const exactPhrase = exactPhraseOverride ?? document.events.some((event) => containsPhrase(tokenizeSearchText(event.text), request.terms));
    const activity = document.lastActivity ?? safeStat(document.filePath)?.mtime.toISOString() ?? null;
    return {
        type: "result",
        provider: document.provider,
        scope: "conversation-text",
        engine,
        sessionId: document.sessionId,
        title: document.title,
        project: document.project,
        filePath: document.filePath,
        lastActivity: activity,
        role: best.event.role,
        snippet: excerpt(best.event.text, request.terms),
        matchedTerms: uniqueTerms,
        exactPhrase,
        score: scoreOverride ?? appScore(uniqueTerms.length, exactPhrase, activity),
        warning: RAW_WARNING,
    };
}
export function walkJsonlFiles(root) {
    const output = [];
    function walk(directory) {
        let entries;
        try {
            entries = fs.readdirSync(directory, { withFileTypes: true });
        }
        catch {
            return;
        }
        for (const entry of entries) {
            const full = path.join(directory, entry.name);
            if (entry.isDirectory())
                walk(full);
            else if (entry.isFile() && entry.name.endsWith(".jsonl"))
                output.push(full);
        }
    }
    walk(root);
    return output;
}
export function containsPhrase(tokens, phrase) {
    if (phrase.length === 0 || phrase.length > tokens.length)
        return false;
    for (let start = 0; start <= tokens.length - phrase.length; start += 1) {
        if (phrase.every((term, offset) => tokens[start + offset] === term))
            return true;
    }
    return false;
}
function scanFile(source, request) {
    const document = source.provider === "codex"
        ? readSearchDocument(source.filePath, source.root, { provider: "codex", sessionId: "", title: "", cwd: "", lastActivity: null })
        : readSearchDocument(source.filePath, source.root);
    if (!document)
        return null;
    const match = searchMatchForDocument(document, request, "scan");
    return match ? { match, exactPhrase: match.exactPhrase } : null;
}
export function collectSearchFiles(roots) {
    const output = walkJsonlFiles(roots.claude).map((filePath) => ({
        filePath, provider: "claude", root: roots.claude,
    }));
    const manifest = loadCodexImportManifest(roots.codexHome);
    for (const filePath of walkCodexRollouts(roots.codex)) {
        const read = readCodexRollout(filePath);
        if (!read.rollout || codexRolloutIsImported(read.rollout, manifest))
            continue;
        output.push({ filePath, provider: "codex", root: roots.codex });
    }
    return output;
}
function codexSearchDocument(rollout, filePath, sessionsDir, seed) {
    const cwd = rollout.cwd || seed?.cwd || "";
    const project = cwd ? path.basename(cwd) : "—";
    const fallbackTitle = rollout.events.find((event) => event.role === "user" && !/^\/\S+$/.test(event.text.trim()))?.text
        .replace(/\s+/g, " ").trim().slice(0, 90) || project || rollout.sessionId;
    return {
        provider: "codex",
        sessionId: rollout.sessionId || seed?.sessionId || path.basename(filePath),
        title: seed?.title || fallbackTitle,
        cwd,
        project,
        filePath,
        lastActivity: rollout.lastActivity ?? seed?.lastActivity ?? null,
        events: rollout.events,
        consumedBytes: rollout.consumedBytes,
    };
}
function searchableEvents(record) {
    if (record.isMeta === true)
        return [];
    if (record.type === "user") {
        const content = record.message?.content;
        if (typeof content === "string") {
            const cleaned = cleanUserText(content);
            return cleaned ? [{ role: "user", text: cleaned }] : [];
        }
        if (Array.isArray(content)) {
            return content
                .filter((block) => block?.type === "text" && typeof block.text === "string")
                .map((block) => cleanUserText(block.text))
                .filter((text) => text !== null)
                .map((text) => ({ role: "user", text }));
        }
    }
    if (record.type === "assistant" && Array.isArray(record.message?.content)) {
        return record.message.content
            .filter((block) => block?.type === "text" && typeof block.text === "string" && block.text.trim().length > 0)
            .map((block) => ({ role: "assistant", text: clipText(block.text) }));
    }
    return [];
}
function cleanUserText(text) {
    const command = text.match(/<command-name>([\s\S]*?)<\/command-name>/);
    if (command) {
        const args = text.match(/<command-args>([\s\S]*?)<\/command-args>/)?.[1]?.trim() ?? "";
        const cleaned = `${command[1].trim()}${args ? ` ${args}` : ""}`.trim();
        return cleaned ? clipText(cleaned) : null;
    }
    if (text.includes("<local-command-stdout>"))
        return null;
    const cleaned = text.replace(/<system-reminder>[\s\S]*?<\/system-reminder>/g, " ").trim();
    if (!cleaned || cleaned.startsWith("Caveat:"))
        return null;
    return clipText(cleaned);
}
function clipText(text, maximum = 4_000) {
    const characters = Array.from(text);
    if (characters.length <= maximum)
        return text;
    return `${characters.slice(0, maximum).join("")} … (+${characters.length - maximum} chars)`;
}
function appScore(uniqueTermCount, exactPhrase, lastActivity) {
    let recency = 0;
    if (lastActivity) {
        const timestamp = new Date(lastActivity).getTime();
        if (!Number.isNaN(timestamp)) {
            const days = Math.max(0, (Date.now() - timestamp) / 86_400_000);
            recency = Math.max(0, 30 * (1 - Math.min(days, 365) / 365));
        }
    }
    return uniqueTermCount * 25 + recency + (exactPhrase ? 1_000 : 0);
}
function excerpt(text, terms, maximum = 220) {
    if (text.length <= maximum)
        return text;
    const lower = text.toLocaleLowerCase("en-US");
    const locations = terms.map((term) => lower.indexOf(term)).filter((value) => value >= 0);
    const location = locations.length > 0 ? Math.min(...locations) : 0;
    const start = Math.max(0, location - Math.floor(maximum / 3));
    const end = Math.min(text.length, start + maximum);
    return `${start > 0 ? "…" : ""}${text.slice(start, end)}${end < text.length ? "…" : ""}`;
}
function safeStat(filePath) {
    try {
        return fs.statSync(filePath);
    }
    catch {
        return null;
    }
}
function safeMtime(filePath) {
    return safeStat(filePath)?.mtimeMs ?? 0;
}
