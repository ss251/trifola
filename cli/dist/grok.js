import * as fs from "node:fs";
import * as path from "node:path";
import { addUsageInPlace, emptyUsage, normalizeModel } from "./pricing.js";
function object(value) {
    return value !== null && typeof value === "object" && !Array.isArray(value) ? value : null;
}
function clean(value, maximum = 4_000) {
    if (typeof value !== "string")
        return null;
    const trimmed = value.trim();
    if (!trimmed)
        return null;
    const chars = Array.from(trimmed);
    return chars.length <= maximum ? trimmed : `${chars.slice(0, maximum).join("")} … (+${chars.length - maximum} chars)`;
}
function integer(value) {
    if (typeof value === "number" && Number.isFinite(value))
        return Math.max(0, Math.trunc(value));
    if (typeof value === "string" && /^-?\d+$/.test(value))
        return Math.max(0, Number(value));
    return 0;
}
function date(value) {
    const parsed = typeof value === "number" && Number.isFinite(value)
        ? new Date(value > 10_000_000_000 ? value : value * 1_000)
        : typeof value === "string" ? new Date(value) : null;
    if (!parsed)
        return null;
    return Number.isNaN(parsed.getTime()) ? null : parsed;
}
function localDay(value) {
    return `${value.getFullYear()}-${String(value.getMonth() + 1).padStart(2, "0")}-${String(value.getDate()).padStart(2, "0")}`;
}
function parseJSON(data) {
    if (!data)
        return {};
    try {
        return object(JSON.parse(data.toString("utf8"))) ?? {};
    }
    catch {
        return {};
    }
}
function textContent(value) {
    if (typeof value === "string")
        return clean(value);
    if (!Array.isArray(value))
        return null;
    const text = value
        .map((item) => object(item))
        .filter((item) => item !== null && item.type === "text")
        .map((item) => clean(item.text))
        .filter((item) => item !== null)
        .join("\n");
    return clean(text);
}
function lines(data, consume) {
    if (!data)
        return;
    let start = 0;
    while (start < data.length) {
        let newline = data.indexOf(0x0a, start);
        if (newline < 0)
            newline = data.length;
        if (newline > start) {
            try {
                const record = object(JSON.parse(data.toString("utf8", start, newline)));
                if (record)
                    consume(record);
            }
            catch { /* tolerate a concurrently-written or corrupt record */ }
        }
        start = newline + 1;
    }
}
function fallbackCwd(summaryPath) {
    const encoded = path.basename(path.dirname(path.dirname(summaryPath)));
    try {
        return decodeURIComponent(encoded);
    }
    catch {
        return encoded;
    }
}
/** Parse one directory-backed Grok session. Summary metadata is authoritative;
 * chat owns visible prose, and nested ACP updates own per-turn usage. Grok's
 * inputTokens includes cachedReadTokens, so the shared additive representation
 * stores only input-cached as fresh input. */
export function parseGrokSession(summaryData, chatData, updatesData, fallbackId, summaryPath = path.join("/Users/dev/.grok/sessions/project", fallbackId, "summary.json")) {
    const summary = parseJSON(summaryData);
    const info = object(summary.info) ?? {};
    const sessionId = clean(info.id) ?? fallbackId;
    const cwd = clean(info.cwd) ?? fallbackCwd(summaryPath);
    const currentModel = clean(summary.current_model_id);
    const title = clean(summary.generated_title) ?? clean(summary.session_summary) ?? path.basename(cwd) ?? sessionId;
    let lastActivity = date(summary.last_active_at) ?? date(summary.updated_at) ?? date(summary.created_at);
    const events = [];
    const models = new Set();
    let rawRecordCount = 0;
    lines(chatData, (record) => {
        rawRecordCount += 1;
        const timestamp = date(record.timestamp);
        if (timestamp && (!lastActivity || timestamp > lastActivity))
            lastActivity = timestamp;
        if (record.type === "user" && record.synthetic_reason == null) {
            const text = textContent(record.content);
            if (text)
                events.push({ role: "user", text });
        }
        else if (record.type === "assistant") {
            const text = textContent(record.content);
            if (text)
                events.push({ role: "assistant", text });
            const model = clean(record.model_id);
            if (model)
                models.add(normalizeModel(model));
        }
    });
    const keyed = new Map();
    const spawned = new Set();
    let usageIsPartial = false;
    let unkeyed = 0;
    lines(updatesData, (outer) => {
        const timestamp = date(outer.timestamp);
        if (timestamp && (!lastActivity || timestamp > lastActivity))
            lastActivity = timestamp;
        const update = object(object(outer.params)?.update) ?? outer;
        if (update.sessionUpdate === "subagent_spawned") {
            const child = clean(update.child_session_id) ?? clean(update.subagent_id);
            if (child)
                spawned.add(child);
            return;
        }
        if (update.sessionUpdate !== "turn_completed")
            return;
        const usage = object(update.usage);
        if (!usage)
            return;
        usageIsPartial ||= usage.costIsPartial === true;
        const day = timestamp ? localDay(timestamp) : "";
        const promptId = clean(update.prompt_id);
        const modelUsage = object(usage.modelUsage) ?? {};
        const rows = Object.entries(modelUsage).filter(([, value]) => object(value) !== null);
        if (rows.length === 0) {
            const model = normalizeModel(currentModel) || "grok-unattributed";
            rows.push([model, usage]);
        }
        for (const [rawModel, rawUsage] of rows) {
            const values = object(rawUsage);
            const model = normalizeModel(rawModel) || "grok-unattributed";
            models.add(model);
            const inclusiveInput = integer(values.inputTokens);
            const cached = Math.min(inclusiveInput, integer(values.cachedReadTokens));
            const output = integer(values.outputTokens);
            if (inclusiveInput === 0 && output === 0)
                continue;
            const key = promptId ? `${promptId}:${model}` : `#${++unkeyed}:${model}`;
            keyed.set(key, {
                model,
                day,
                usage: {
                    inputTokens: Math.max(0, inclusiveInput - cached),
                    outputTokens: output,
                    cacheCreateTokens: 0,
                    cacheReadTokens: cached,
                    cacheCreate1hTokens: 0,
                },
            });
        }
    });
    if (models.size === 0 && currentModel)
        models.add(normalizeModel(currentModel));
    const usageByDayModel = new Map();
    const totalUsage = emptyUsage();
    for (const entry of keyed.values()) {
        addUsageInPlace(totalUsage, entry.usage);
        let byModel = usageByDayModel.get(entry.day);
        if (!byModel)
            usageByDayModel.set(entry.day, byModel = new Map());
        const existing = byModel.get(entry.model);
        if (existing)
            addUsageInPlace(existing, entry.usage);
        else
            byModel.set(entry.model, { ...entry.usage });
    }
    return {
        provider: "grok",
        sessionId,
        cwd,
        title,
        model: models.size > 0 ? [...models].sort().join(" + ") : null,
        models: [...models].sort(),
        lastActivity: lastActivity?.toISOString() ?? null,
        events,
        usageByDayModel,
        totalUsage,
        usageEntries: keyed.size,
        rawRecordCount,
        usageIsPartial,
        parentSessionId: clean(summary.parent_session_id),
        sessionKind: clean(summary.session_kind),
        spawnedChildSessionIds: [...spawned].sort(),
        consumedBytes: chatData?.length ?? 0,
    };
}
export function walkGrokSessions(grokHome) {
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
            if (entry.isSymbolicLink())
                continue;
            const full = path.join(directory, entry.name);
            if (entry.isDirectory())
                walk(full);
            else if (entry.isFile() && entry.name === "summary.json")
                output.push(full);
        }
    }
    walk(path.join(grokHome, "sessions"));
    return output.sort();
}
function safeRead(filePath) {
    try {
        const stat = fs.lstatSync(filePath);
        return stat.isFile() && !stat.isSymbolicLink() ? fs.readFileSync(filePath) : null;
    }
    catch {
        return null;
    }
}
export function readGrokSession(summaryPath) {
    const summary = safeRead(summaryPath);
    if (!summary)
        return null;
    const directory = path.dirname(summaryPath);
    return parseGrokSession(summary, safeRead(path.join(directory, "chat_history.jsonl")), safeRead(path.join(directory, "updates.jsonl")), path.basename(directory), summaryPath);
}
export function scanGrokSessions(grokHome, onProgress) {
    const files = walkGrokSessions(grokHome);
    const result = {
        sessionCount: 0,
        fileCount: 0,
        totalDedupedEntries: 0,
        totalUsage: emptyUsage(),
        usageByDayModel: new Map(),
        partialUsageSessions: 0,
    };
    let done = 0;
    for (const summaryPath of files) {
        onProgress?.(done++, files.length);
        const rollout = readGrokSession(summaryPath);
        if (!rollout)
            continue;
        result.sessionCount += 1;
        result.fileCount += 1;
        result.totalDedupedEntries += rollout.usageEntries;
        if (rollout.usageIsPartial)
            result.partialUsageSessions += 1;
        addUsageInPlace(result.totalUsage, rollout.totalUsage);
        for (const [day, modelsForDay] of rollout.usageByDayModel) {
            let target = result.usageByDayModel.get(day);
            if (!target)
                result.usageByDayModel.set(day, target = new Map());
            for (const [model, usage] of modelsForDay) {
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
