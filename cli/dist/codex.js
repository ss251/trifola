import * as fs from "node:fs";
import * as path from "node:path";
import { createRequire } from "node:module";
import { addUsageInPlace, emptyUsage, normalizeModel, } from "./pricing.js";
const require = createRequire(import.meta.url);
function clean(value, maximum = 4_000) {
    if (typeof value !== "string")
        return null;
    const trimmed = value.trim();
    if (!trimmed)
        return null;
    const chars = Array.from(trimmed);
    return chars.length <= maximum
        ? trimmed
        : `${chars.slice(0, maximum).join("")} … (+${chars.length - maximum} chars)`;
}
function integer(value) {
    if (typeof value === "number" && Number.isFinite(value))
        return Math.max(0, Math.trunc(value));
    if (typeof value === "string" && /^-?\d+$/.test(value))
        return Math.max(0, Number(value));
    return null;
}
function nativeUsage(value) {
    if (!value || typeof value !== "object")
        return null;
    const object = value;
    const input = integer(object.input_tokens);
    const cached = integer(object.cached_input_tokens);
    const output = integer(object.output_tokens);
    if (input === null || cached === null || output === null)
        return null;
    return { input, cached, output, reasoning: integer(object.reasoning_output_tokens) ?? 0 };
}
function additiveUsage(value) {
    return {
        inputTokens: value.input >= value.cached ? value.input - value.cached : 0,
        outputTokens: value.output,
        cacheCreateTokens: 0,
        cacheReadTokens: value.cached,
        cacheCreate1hTokens: 0,
    };
}
function subtract(current, prior) {
    return {
        input: Math.max(0, current.input - prior.input),
        cached: Math.max(0, current.cached - prior.cached),
        output: Math.max(0, current.output - prior.output),
        reasoning: Math.max(0, current.reasoning - prior.reasoning),
    };
}
function counterReset(current, prior) {
    return current.input < prior.input || current.cached < prior.cached || current.output < prior.output;
}
function parseDate(value) {
    if (typeof value !== "string")
        return null;
    const date = new Date(value);
    return Number.isNaN(date.getTime()) ? null : date;
}
function localDay(date) {
    return `${date.getFullYear()}-${String(date.getMonth() + 1).padStart(2, "0")}-${String(date.getDate()).padStart(2, "0")}`;
}
function marksImport(value) {
    if (typeof value === "string")
        return value.toLowerCase().includes("import");
    if (Array.isArray(value))
        return value.some(marksImport);
    return !!value && typeof value === "object" && Object.values(value).some(marksImport);
}
function content(value) {
    if (typeof value === "string")
        return clean(value);
    if (Array.isArray(value)) {
        const joined = value.map(content).filter((item) => item !== null).join("\n");
        return clean(joined);
    }
    if (value && typeof value === "object") {
        const object = value;
        for (const key of ["text", "message", "output", "content"]) {
            const result = content(object[key]);
            if (result)
                return result;
        }
    }
    return null;
}
function searchableItem(item) {
    const type = typeof item.type === "string" ? item.type.toLowerCase() : "";
    if (type === "user_message") {
        const text = clean(item.message);
        return text ? [{ role: "user", text }] : [];
    }
    if (type === "agent_message") {
        const text = clean(item.message);
        return text ? [{ role: "assistant", text }] : [];
    }
    if (type === "message") {
        const text = content(item.content);
        const role = typeof item.role === "string" ? item.role.toLowerCase() : "";
        return text && (role === "user" || role === "assistant")
            ? [{ role: role, text }]
            : [];
    }
    return [];
}
function isHumanPrompt(text) {
    const value = text.trim();
    return value.length > 0 && !(/^\/\S+$/.test(value));
}
function emptyManifest() {
    return { importedThreadIds: new Set(), contentHashes: new Set(), sourcePaths: new Set() };
}
export function loadCodexImportManifest(codexHome) {
    const manifestPath = path.join(codexHome, "external_agent_session_imports.json");
    let parsed;
    try {
        const stat = fs.lstatSync(manifestPath);
        if (!stat.isFile() || stat.isSymbolicLink())
            return emptyManifest();
        parsed = JSON.parse(fs.readFileSync(manifestPath, "utf8"));
    }
    catch {
        return emptyManifest();
    }
    const manifest = emptyManifest();
    for (const record of Array.isArray(parsed?.records) ? parsed.records : []) {
        const id = clean(record?.imported_thread_id);
        const hash = clean(record?.content_sha256);
        const source = clean(record?.source_path);
        if (id)
            manifest.importedThreadIds.add(id);
        if (hash)
            manifest.contentHashes.add(hash.toLowerCase());
        if (source)
            manifest.sourcePaths.add(source);
    }
    return manifest;
}
export function codexRolloutIsImported(rollout, manifest) {
    return rollout.markedImported
        || manifest.importedThreadIds.has(rollout.sessionId)
        || (rollout.importedContentHash !== null && manifest.contentHashes.has(rollout.importedContentHash.toLowerCase()))
        || (rollout.importedSourcePath !== null && manifest.sourcePaths.has(rollout.importedSourcePath));
}
export function detectZstd(zlibLoader = () => require("node:zlib")) {
    try {
        return typeof zlibLoader()?.zstdDecompressSync === "function";
    }
    catch {
        return false;
    }
}
export function readCodexRolloutFile(filePath, zlibLoader = () => require("node:zlib")) {
    let raw;
    try {
        raw = fs.readFileSync(filePath);
    }
    catch {
        return { data: null, compressedSkipped: false };
    }
    if (!filePath.endsWith(".jsonl.zst"))
        return { data: raw, compressedSkipped: false };
    try {
        const decompress = zlibLoader().zstdDecompressSync;
        if (typeof decompress !== "function")
            return { data: null, compressedSkipped: true };
        return { data: Buffer.from(decompress(raw)), compressedSkipped: false };
    }
    catch {
        return { data: null, compressedSkipped: false };
    }
}
export function walkCodexRollouts(sessionsDir) {
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
            if (entry.isSymbolicLink())
                continue;
            if (entry.isDirectory())
                walk(full);
            else if (entry.isFile()
                && entry.name.startsWith("rollout-")
                && (entry.name.endsWith(".jsonl") || entry.name.endsWith(".jsonl.zst")))
                output.push(full);
        }
    }
    walk(sessionsDir);
    return output;
}
export function parseCodexRollout(data, fallbackId) {
    let sessionId = fallbackId;
    let cwd = "";
    let model = null;
    let lastActivity = null;
    let sawSessionMeta = false;
    let historyMode = "unknown";
    let markedImported = false;
    let importedContentHash = null;
    let importedSourcePath = null;
    let firstUser = null;
    const events = [];
    const keyed = new Map();
    let latestTotal = null;
    let epoch = 0;
    let unkeyed = 0;
    let rawRecordCount = 0;
    let usageEntries = 0;
    const reattribute = (rawModel) => {
        const normalized = normalizeModel(rawModel);
        if (!normalized || normalized === "gpt-unattributed")
            return;
        for (const [key, value] of keyed) {
            if (value.model === "gpt-unattributed")
                keyed.set(key, { ...value, model: normalized });
        }
    };
    const consumeTokenCount = (item, timestamp) => {
        const info = item.info;
        if (!info || typeof info !== "object")
            return;
        const total = nativeUsage(info.total_token_usage);
        const prior = latestTotal;
        const reset = !!(total && prior && counterReset(total, prior));
        if (reset)
            epoch += 1;
        const delta = nativeUsage(info.last_token_usage)
            ?? (total ? (!prior || reset ? total : subtract(total, prior)) : null);
        if (total)
            latestTotal = total;
        if (!delta || (delta.input === 0 && delta.cached === 0 && delta.output === 0))
            return;
        const billingModel = normalizeModel(model) || "gpt-unattributed";
        const key = total
            ? `${epoch}:${total.input}:${total.cached}:${total.output}`
            : `#${++unkeyed}`;
        if (!keyed.has(key))
            usageEntries += 1;
        keyed.set(key, {
            usage: additiveUsage(delta),
            model: billingModel,
            day: timestamp ? localDay(timestamp) : "",
        });
    };
    let start = 0;
    let consumedBytes = 0;
    while (start < data.length) {
        let newline = data.indexOf(0x0a, start);
        if (newline < 0)
            newline = data.length;
        const line = data.subarray(start, newline);
        start = newline + 1;
        consumedBytes = newline < data.length ? newline + 1 : data.length;
        if (line.length === 0)
            continue;
        let object;
        try {
            object = JSON.parse(line.toString("utf8"));
        }
        catch {
            continue;
        }
        if (!object || typeof object !== "object" || typeof object.type !== "string")
            continue;
        rawRecordCount += 1;
        const timestamp = parseDate(object.timestamp);
        if (timestamp && (!lastActivity || timestamp > lastActivity))
            lastActivity = timestamp;
        const payload = object.payload && typeof object.payload === "object" ? object.payload : {};
        if (object.type === "session_meta") {
            if (!sawSessionMeta) {
                sawSessionMeta = true;
                sessionId = clean(payload.id) ?? clean(payload.session_id) ?? sessionId;
                cwd = clean(payload.cwd) ?? cwd;
                markedImported = marksImport(payload.thread_source) || marksImport(payload.source);
                importedContentHash = clean(payload.content_sha256)?.toLowerCase() ?? null;
                importedSourcePath = clean(payload.source_path);
                const rawHistory = clean(payload.history_mode)?.toLowerCase();
                historyMode = rawHistory === "legacy" || rawHistory === "paginated" ? rawHistory : "unknown";
                const nestedTimestamp = parseDate(payload.timestamp);
                if (nestedTimestamp && (!lastActivity || nestedTimestamp > lastActivity))
                    lastActivity = nestedTimestamp;
            }
            continue;
        }
        if (object.type === "turn_context") {
            if (!cwd)
                cwd = clean(payload.cwd) ?? "";
            const observed = clean(payload.model);
            if (observed) {
                const first = model === null;
                model = observed;
                if (first)
                    reattribute(observed);
            }
            continue;
        }
        let item = null;
        if (object.type === "event_msg" || object.type === "response_item") {
            item = payload.type === "item_completed" && payload.item && typeof payload.item === "object"
                ? payload.item
                : payload;
        }
        if (!item)
            continue;
        events.push(...searchableItem(item));
        if (item.type === "user_message") {
            const text = clean(item.message);
            if (text && isHumanPrompt(text) && firstUser === null)
                firstUser = text;
        }
        const usageItem = object.type === "event_msg"
            ? (payload.type === "item_completed" ? (historyMode === "paginated" ? item : null) : payload)
            : object.type === "response_item" && historyMode === "paginated" && payload.type === "item_completed"
                ? item
                : null;
        if (usageItem?.type === "token_count")
            consumeTokenCount(usageItem, timestamp);
    }
    const usageByDayModel = new Map();
    const totalUsage = emptyUsage();
    for (const value of keyed.values()) {
        addUsageInPlace(totalUsage, value.usage);
        let byModel = usageByDayModel.get(value.day);
        if (!byModel)
            usageByDayModel.set(value.day, byModel = new Map());
        const existing = byModel.get(value.model);
        if (existing)
            addUsageInPlace(existing, value.usage);
        else
            byModel.set(value.model, { ...value.usage });
    }
    return {
        provider: "codex",
        sessionId,
        cwd,
        model,
        lastActivity: lastActivity?.toISOString() ?? null,
        events,
        usageByDayModel,
        totalUsage,
        usageEntries,
        rawRecordCount,
        markedImported,
        importedContentHash,
        importedSourcePath,
        consumedBytes,
    };
}
export function readCodexRollout(filePath) {
    const read = readCodexRolloutFile(filePath);
    if (!read.data)
        return { rollout: null, compressedSkipped: read.compressedSkipped };
    const base = path.basename(filePath)
        .replace(/\.jsonl\.zst$/, "")
        .replace(/\.jsonl$/, "");
    return { rollout: parseCodexRollout(read.data, base), compressedSkipped: false };
}
function isSubagent(filePath) {
    return filePath.split(path.sep).includes("subagents");
}
export function scanCodexSessions(codexHome, onProgress) {
    const files = walkCodexRollouts(path.join(codexHome, "sessions"));
    const manifest = loadCodexImportManifest(codexHome);
    const result = {
        sessionCount: 0,
        fileCount: 0,
        skippedCompressed: 0,
        totalDedupedEntries: 0,
        totalUsage: emptyUsage(),
        usageByDayModel: new Map(),
    };
    let done = 0;
    for (const filePath of files) {
        onProgress?.(done++, files.length);
        const read = readCodexRollout(filePath);
        if (read.compressedSkipped) {
            result.skippedCompressed += 1;
            continue;
        }
        if (!read.rollout || codexRolloutIsImported(read.rollout, manifest))
            continue;
        result.fileCount += 1;
        if (!isSubagent(filePath))
            result.sessionCount += 1;
        result.totalDedupedEntries += read.rollout.usageEntries;
        addUsageInPlace(result.totalUsage, read.rollout.totalUsage);
        for (const [day, models] of read.rollout.usageByDayModel) {
            let target = result.usageByDayModel.get(day);
            if (!target)
                result.usageByDayModel.set(day, target = new Map());
            for (const [model, usage] of models) {
                const existing = target.get(model);
                if (existing)
                    addUsageInPlace(existing, usage);
                else
                    target.set(model, { ...usage });
            }
        }
    }
    return result;
}
