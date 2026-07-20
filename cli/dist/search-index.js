import * as fs from "node:fs";
import * as os from "node:os";
import * as path from "node:path";
import { createRequire } from "node:module";
import { MAX_ORDERED_TOKENS_PER_DOCUMENT, parseSearchBuffer, readSearchDocument, searchCorpora, searchMatchForDocument, tokenizeSearchText, collectSearchFiles, } from "./search.js";
import { resolveCodexDir, resolveGrokDir, codexSessionsDirOf } from "./config.js";
import { detectZstd, walkCodexRollouts } from "./codex.js";
export const SEARCH_SCHEMA_VERSION = 4;
export const CLI_INDEX_FILENAME = "search-index.sqlite3";
function rootForProvider(provider, roots) {
    switch (provider) {
        case "claude": return roots.claude;
        case "codex": return roots.codex;
        case "grok": return roots.grok;
    }
}
const defaultLoader = createRequire(import.meta.url);
export function detectNodeSqlite(loader = defaultLoader) {
    try {
        const loaded = loader("node:sqlite");
        return loaded && typeof loaded.DatabaseSync === "function" ? loaded : null;
    }
    catch {
        return null;
    }
}
export function resolveSearchIndexPaths(environment = process.env, platform = process.platform, home = os.homedir()) {
    const cliBase = environment.XDG_CACHE_HOME?.trim()
        ? path.resolve(environment.XDG_CACHE_HOME.trim())
        : platform === "darwin"
            ? path.join(home, "Library", "Caches")
            : path.join(home, ".cache");
    const cli = path.join(cliBase, "trifola", CLI_INDEX_FILENAME);
    const explicitApp = environment.TRIFOLA_SEARCH_INDEX_CACHE?.trim();
    if (explicitApp) {
        const app = explicitApp.toLowerCase().endsWith(".json")
            ? explicitApp.slice(0, -5) + ".sqlite3"
            : explicitApp;
        return { app: path.resolve(app), cli };
    }
    const appBase = path.join(home, "Library", "Application Support", "Trifola");
    const override = environment.CLAUDE_CONFIG_DIR?.trim();
    const appName = override
        ? `search-index-${fnv1a64(Buffer.from(path.resolve(override))).toString(16)}.sqlite3`
        : CLI_INDEX_FILENAME;
    return { app: path.join(appBase, appName), cli };
}
export async function runTieredSearch(projectsDir, request, callbacks, options = {}) {
    const sqlite = detectNodeSqlite(options.sqliteLoader ?? defaultLoader);
    const environment = options.environment ?? process.env;
    const home = options.home ?? os.homedir();
    const codexHome = resolveCodexDir(environment, home);
    const grokHome = resolveGrokDir(environment, home);
    const roots = {
        claude: projectsDir,
        codex: codexSessionsDirOf(codexHome),
        codexHome,
        grok: path.join(grokHome, "sessions"),
        grokHome,
    };
    const compressed = walkCodexRollouts(roots.codex).filter((file) => file.endsWith(".jsonl.zst")).length;
    if (compressed > 0 && !detectZstd()) {
        callbacks.onNotice?.(`${compressed} compressed rollouts skipped — Node <22.15`);
    }
    if (!sqlite) {
        callbacks.onTier?.({
            tier: 3,
            engine: "scan",
            detail: "no index available on this Node — searching by scan (Node 22.5+ enables the index)",
        });
        const summary = searchCorpora(roots, request, callbacks.onMatch, callbacks.onProgress);
        return { ...summary, tier: 3, engine: "scan", indexBuilt: false };
    }
    const paths = resolveSearchIndexPaths(environment, options.platform ?? process.platform, home);
    if (!request.rebuildIndex) {
        const app = openAppIndexSnapshot(sqlite, paths.app);
        if (app) {
            callbacks.onTier?.({
                tier: 1,
                engine: "app-index",
                indexPath: paths.app,
                detail: `app index (read-only) · ${paths.app}`,
            });
            try {
                const summary = queryIndex(app.database, roots, request, "app-index", callbacks.onMatch);
                return { ...summary, tier: 1, engine: "app-index", indexPath: paths.app, indexBuilt: false };
            }
            finally {
                app.database.close();
                app.cleanup();
            }
        }
    }
    if (request.rebuildIndex && fs.existsSync(paths.cli)) {
        removeDatabase(paths.cli);
        callbacks.onNotice?.(`rebuilding CLI search index at ${paths.cli}`);
    }
    let needsBuild = !fs.existsSync(paths.cli);
    if (!needsBuild) {
        const state = inspectIndex(sqlite, paths.cli);
        if (state !== "ready") {
            removeDatabase(paths.cli);
            needsBuild = true;
            callbacks.onNotice?.(state === "corrupt"
                ? `CLI search index is unreadable — rebuilding schema v${SEARCH_SCHEMA_VERSION}`
                : `CLI search index schema ${state} does not match v${SEARCH_SCHEMA_VERSION} — rebuilding`);
        }
    }
    if (needsBuild) {
        callbacks.onTier?.({
            tier: 2,
            engine: "scan",
            indexPath: paths.cli,
            detail: `CLI index cold start · serving this search by scan while building ${paths.cli}`,
        });
        const summary = searchCorpora(roots, request, callbacks.onMatch, callbacks.onProgress);
        try {
            const database = openWritableIndex(sqlite, paths.cli);
            try {
                const update = await updateIndex(database, roots);
                callbacks.onNotice?.("index built — next searches are instant.");
                return {
                    ...summary,
                    tier: 2,
                    engine: "scan",
                    indexPath: paths.cli,
                    indexBuilt: true,
                    update,
                };
            }
            finally {
                database.close();
            }
        }
        catch (error) {
            removeDatabase(paths.cli);
            callbacks.onNotice?.(`could not build the CLI index; scan results are complete (${errorMessage(error)})`);
            return { ...summary, tier: 2, engine: "scan", indexPath: paths.cli, indexBuilt: false };
        }
    }
    try {
        const database = openWritableIndex(sqlite, paths.cli);
        try {
            const update = await updateIndex(database, roots);
            callbacks.onTier?.({
                tier: 2,
                engine: "cli-index",
                indexPath: paths.cli,
                detail: `CLI index · ${paths.cli}`,
            });
            const summary = queryIndex(database, roots, request, "cli-index", callbacks.onMatch);
            return {
                ...summary,
                tier: 2,
                engine: "cli-index",
                indexPath: paths.cli,
                indexBuilt: false,
                update,
            };
        }
        finally {
            database.close();
        }
    }
    catch (error) {
        removeDatabase(paths.cli);
        callbacks.onNotice?.(`CLI search index failed — rebuilding after this scan (${errorMessage(error)})`);
        callbacks.onTier?.({
            tier: 2,
            engine: "scan",
            indexPath: paths.cli,
            detail: `CLI index recovery · serving this search by scan while rebuilding ${paths.cli}`,
        });
        const summary = searchCorpora(roots, request, callbacks.onMatch, callbacks.onProgress);
        try {
            const database = openWritableIndex(sqlite, paths.cli);
            try {
                const update = await updateIndex(database, roots);
                callbacks.onNotice?.("index built — next searches are instant.");
                return { ...summary, tier: 2, engine: "scan", indexPath: paths.cli, indexBuilt: true, update };
            }
            finally {
                database.close();
            }
        }
        catch (rebuildError) {
            removeDatabase(paths.cli);
            callbacks.onNotice?.(`could not rebuild the CLI index (${errorMessage(rebuildError)})`);
            return { ...summary, tier: 2, engine: "scan", indexPath: paths.cli, indexBuilt: false };
        }
    }
}
/**
 * A WAL reader can create or touch -wal/-shm files even when SQLite opened the
 * primary database read-only. Snapshotting with ordinary read-only file copies
 * keeps the app store byte-for-byte untouched while preserving its WAL view.
 */
function openAppIndexSnapshot(sqlite, databasePath) {
    if (!fs.existsSync(databasePath))
        return null;
    const directory = fs.mkdtempSync(path.join(os.tmpdir(), "trifola-app-index-"));
    const snapshotPath = path.join(directory, CLI_INDEX_FILENAME);
    try {
        fs.copyFileSync(databasePath, snapshotPath);
        if (fs.existsSync(databasePath + "-wal")) {
            fs.copyFileSync(databasePath + "-wal", snapshotPath + "-wal");
        }
        const database = openReadyReadOnlyIndex(sqlite, snapshotPath);
        if (!database)
            throw new Error("app index is not ready");
        return {
            database,
            cleanup: () => fs.rmSync(directory, { recursive: true, force: true }),
        };
    }
    catch {
        fs.rmSync(directory, { recursive: true, force: true });
        return null;
    }
}
function openReadyReadOnlyIndex(sqlite, databasePath) {
    if (!fs.existsSync(databasePath))
        return null;
    let database = null;
    try {
        database = new sqlite.DatabaseSync(databasePath, { readOnly: true });
        database.exec("PRAGMA query_only=ON");
        if (userVersion(database) !== SEARCH_SCHEMA_VERSION)
            throw new Error("schema mismatch");
        scalarCount(database, "SELECT count(*) AS value FROM documents");
        scalarCount(database, "SELECT count(*) AS value FROM search_fts");
        return database;
    }
    catch {
        database?.close();
        return null;
    }
}
function inspectIndex(sqlite, databasePath) {
    const database = openReadyReadOnlyIndex(sqlite, databasePath);
    if (database) {
        database.close();
        return "ready";
    }
    let probe = null;
    try {
        probe = new sqlite.DatabaseSync(databasePath, { readOnly: true });
        probe.exec("PRAGMA query_only=ON");
        return String(userVersion(probe));
    }
    catch {
        return "corrupt";
    }
    finally {
        probe?.close();
    }
}
function openWritableIndex(sqlite, databasePath) {
    fs.mkdirSync(path.dirname(databasePath), { recursive: true });
    const database = new sqlite.DatabaseSync(databasePath);
    const version = userVersion(database);
    if (version !== 0 && version !== SEARCH_SCHEMA_VERSION) {
        database.close();
        throw new Error(`search schema version ${version} is not ${SEARCH_SCHEMA_VERSION}`);
    }
    database.exec("PRAGMA journal_mode=WAL");
    database.exec("PRAGMA synchronous=NORMAL");
    database.exec("PRAGMA foreign_keys=ON");
    database.exec("PRAGMA wal_autocheckpoint=256");
    database.exec(`
    CREATE TABLE IF NOT EXISTS documents(
      key TEXT PRIMARY KEY,
      session_id TEXT NOT NULL,
      provider TEXT NOT NULL,
      project TEXT NOT NULL,
      cwd TEXT NOT NULL,
      title TEXT NOT NULL,
      file_path TEXT NOT NULL,
      file_size INTEGER NOT NULL,
      modified_ns INTEGER NOT NULL,
      parsed_offset INTEGER NOT NULL,
      prefix_length INTEGER NOT NULL,
      prefix_hash INTEGER NOT NULL,
      last_activity REAL,
      metadata_token_count INTEGER NOT NULL,
      conversation_token_count INTEGER NOT NULL
    );
    CREATE TABLE IF NOT EXISTS search_rows(
      rowid INTEGER PRIMARY KEY,
      document_key TEXT NOT NULL REFERENCES documents(key) ON DELETE CASCADE,
      scope TEXT NOT NULL,
      content TEXT NOT NULL
    );
    CREATE INDEX IF NOT EXISTS search_rows_document ON search_rows(document_key, scope);
    CREATE VIRTUAL TABLE IF NOT EXISTS search_fts USING fts5(
      content, content='search_rows', content_rowid='rowid',
      tokenize='unicode61 remove_diacritics 0'
    );
    CREATE TRIGGER IF NOT EXISTS search_rows_insert AFTER INSERT ON search_rows BEGIN
      INSERT INTO search_fts(rowid, content) VALUES (new.rowid, new.content);
    END;
    CREATE TRIGGER IF NOT EXISTS search_rows_delete AFTER DELETE ON search_rows BEGIN
      INSERT INTO search_fts(search_fts, rowid, content)
      VALUES('delete', old.rowid, old.content);
    END;
    CREATE TRIGGER IF NOT EXISTS search_rows_update AFTER UPDATE ON search_rows BEGIN
      INSERT INTO search_fts(search_fts, rowid, content)
      VALUES('delete', old.rowid, old.content);
      INSERT INTO search_fts(rowid, content) VALUES (new.rowid, new.content);
    END;
    CREATE VIRTUAL TABLE IF NOT EXISTS search_vocab USING fts5vocab(search_fts, 'row');
  `);
    if (version === 0) {
        database.exec("INSERT INTO search_fts(search_fts, rank) VALUES('automerge', 0)");
        database.exec("INSERT INTO search_fts(search_fts, rank) VALUES('crisismerge', 0)");
        database.exec(`PRAGMA user_version=${SEARCH_SCHEMA_VERSION}`);
    }
    return database;
}
export async function updateIndex(database, roots) {
    const resolvedRoots = typeof roots === "string"
        ? {
            claude: roots,
            codex: path.join(roots, ".codex-disabled"),
            codexHome: path.dirname(roots),
            grok: path.join(roots, ".grok-disabled"),
            grokHome: path.dirname(roots),
        }
        : roots;
    const existing = loadStoredFingerprints(database);
    const files = collectSearchFiles(resolvedRoots);
    const current = new Set(files.map((source) => source.filePath));
    const stats = { rebuilt: 0, appended: 0, reused: 0, removed: 0, sourceBytesRead: 0 };
    database.exec("BEGIN IMMEDIATE");
    try {
        const deleteDocument = database.prepare("DELETE FROM documents WHERE key = ?");
        for (const stored of existing.values()) {
            if (!current.has(stored.filePath)) {
                deleteDocument.run(stored.key);
                stats.removed += 1;
            }
        }
        for (const source of files) {
            const absolute = source.filePath;
            const fingerprint = existing.get(absolute);
            let metadata;
            try {
                metadata = fs.statSync(absolute, { bigint: true });
            }
            catch {
                continue;
            }
            if (fingerprint && fingerprint.fileSize === metadata.size && fingerprint.modifiedNs === metadata.mtimeNs) {
                stats.reused += 1;
                continue;
            }
            const old = fingerprint ? loadStoredDocument(database, fingerprint.key) : undefined;
            const change = prepareChange(source, metadata, old);
            if (!change)
                continue;
            applyChange(database, change);
            stats.sourceBytesRead += change.sourceBytesRead;
            if (change.appended)
                stats.appended += 1;
            else
                stats.rebuilt += 1;
        }
        database.exec("COMMIT");
    }
    catch (error) {
        try {
            database.exec("ROLLBACK");
        }
        catch { /* preserve the original failure */ }
        throw error;
    }
    return stats;
}
function prepareChange(source, metadata, old) {
    const filePath = source.filePath;
    const seed = old ? {
        sessionId: old.sessionId,
        title: old.title,
        cwd: old.cwd,
        lastActivity: old.lastActivity,
        provider: old.provider,
    } : undefined;
    const canAppend = source.provider === "claude" && old
        && metadata.size > old.fileSize
        && old.parsedOffset <= metadata.size
        && prefixHash(filePath, old.prefixLength) === old.prefixHash;
    if (canAppend && old) {
        const suffix = readFromOffset(filePath, old.parsedOffset);
        if (!suffix)
            return null;
        const parsed = parseSearchBuffer(suffix, filePath, source.root, seed);
        const rows = tokenRows(parsed, Math.max(0, MAX_ORDERED_TOKENS_PER_DOCUMENT - old.conversationTokenCount));
        return makePreparedChange({
            old,
            document: parsed,
            metadata,
            parsedOffset: old.parsedOffset + BigInt(parsed.consumedBytes),
            prefixLength: old.prefixLength,
            prefixHashValue: old.prefixHash,
            rows,
            conversationTokenCount: old.conversationTokenCount + rows.count,
            replaceConversation: false,
            appended: true,
            sourceBytesRead: suffix.length + old.prefixLength,
        });
    }
    const parsed = source.provider === "claude"
        ? readSearchDocument(filePath, source.root)
        : readSearchDocument(filePath, source.root, { provider: source.provider, sessionId: "", title: "", cwd: "", lastActivity: null });
    if (!parsed)
        return null;
    let data;
    try {
        data = fs.readFileSync(filePath);
    }
    catch {
        return null;
    }
    const rows = tokenRows(parsed, MAX_ORDERED_TOKENS_PER_DOCUMENT);
    const prefixLength = Math.min(data.length, 4_096);
    return makePreparedChange({
        old,
        document: parsed,
        metadata,
        parsedOffset: BigInt(parsed.consumedBytes),
        prefixLength,
        prefixHashValue: fnv1a64(data.subarray(0, prefixLength), true),
        rows,
        conversationTokenCount: rows.count,
        replaceConversation: true,
        appended: false,
        sourceBytesRead: data.length,
    });
}
function makePreparedChange(input) {
    const document = input.document;
    const key = [document.provider, "local", document.sessionId, document.filePath].join("\u0001");
    const metadataTokens = tokenizeSearchText([document.title, document.project, document.cwd].join(" "));
    return {
        oldKey: input.old?.key,
        key,
        document,
        fileSize: input.metadata.size,
        modifiedNs: input.metadata.mtimeNs,
        parsedOffset: input.parsedOffset,
        prefixLength: input.prefixLength,
        prefixHash: input.prefixHashValue,
        metadataTokens,
        conversationRows: input.rows.rows,
        conversationTokenCount: input.conversationTokenCount,
        replaceConversation: input.replaceConversation,
        appended: input.appended,
        sourceBytesRead: input.sourceBytesRead,
    };
}
function applyChange(database, change) {
    if (change.oldKey && change.oldKey !== change.key) {
        database.prepare("DELETE FROM documents WHERE key = ?").run(change.oldKey);
    }
    database.prepare(`
    INSERT INTO documents(
      key, session_id, provider, project, cwd, title, file_path,
      file_size, modified_ns, parsed_offset, prefix_length, prefix_hash,
      last_activity, metadata_token_count, conversation_token_count
    ) VALUES(?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
    ON CONFLICT(key) DO UPDATE SET
      session_id=excluded.session_id, provider=excluded.provider,
      project=excluded.project, cwd=excluded.cwd, title=excluded.title,
      file_path=excluded.file_path, file_size=excluded.file_size,
      modified_ns=excluded.modified_ns, parsed_offset=excluded.parsed_offset,
      prefix_length=excluded.prefix_length, prefix_hash=excluded.prefix_hash,
      last_activity=excluded.last_activity,
      metadata_token_count=excluded.metadata_token_count,
      conversation_token_count=excluded.conversation_token_count
  `).run(change.key, change.document.sessionId, change.document.provider, change.document.project, change.document.cwd, change.document.title, change.document.filePath, change.fileSize, change.modifiedNs, change.parsedOffset, change.prefixLength, change.prefixHash, change.document.lastActivity ? new Date(change.document.lastActivity).getTime() / 1_000 : null, change.metadataTokens.length, change.conversationTokenCount);
    database.prepare("DELETE FROM search_rows WHERE document_key = ? AND scope = 'metadata'").run(change.key);
    const insertRow = database.prepare("INSERT INTO search_rows(document_key, scope, content) VALUES(?, ?, ?)");
    if (change.metadataTokens.length > 0) {
        insertRow.run(change.key, "metadata", change.metadataTokens.join(" "));
    }
    if (change.replaceConversation) {
        database.prepare("DELETE FROM search_rows WHERE document_key = ? AND scope = 'conversation'").run(change.key);
    }
    for (const row of change.conversationRows)
        insertRow.run(change.key, "conversation", row);
}
function tokenRows(document, remaining) {
    const rows = [];
    let count = 0;
    for (const event of document.events) {
        if (count >= remaining)
            break;
        const tokens = tokenizeSearchText(event.text).slice(0, remaining - count);
        if (tokens.length === 0)
            continue;
        rows.push(tokens.join(" "));
        count += tokens.length;
    }
    return { rows, count };
}
function loadStoredFingerprints(database) {
    const statement = database.prepare(`
    SELECT key, file_path, file_size, modified_ns
    FROM documents
  `);
    statement.setReadBigInts(true);
    const arrayRows = typeof statement.setReturnArrays === "function";
    if (arrayRows)
        statement.setReturnArrays(true);
    const output = new Map();
    for (const raw of statement.all()) {
        const row = arrayRows ? raw : null;
        const record = arrayRows ? null : raw;
        const filePath = String(row ? row[1] : record.file_path);
        output.set(filePath, {
            key: String(row ? row[0] : record.key),
            filePath,
            fileSize: asBigInt(row ? row[2] : record.file_size),
            modifiedNs: asBigInt(row ? row[3] : record.modified_ns),
        });
    }
    return output;
}
function loadStoredDocument(database, key) {
    const statement = database.prepare(`
    SELECT key, session_id, provider, project, cwd, title, file_path, file_size,
           modified_ns, parsed_offset, prefix_length, prefix_hash,
           last_activity, conversation_token_count
    FROM documents WHERE key = ?
  `);
    statement.setReadBigInts(true);
    const row = statement.get(key);
    if (!row)
        return undefined;
    return {
        key: String(row.key),
        sessionId: String(row.session_id),
        provider: String(row.provider),
        project: String(row.project),
        cwd: String(row.cwd),
        title: String(row.title),
        filePath: String(row.file_path),
        fileSize: asBigInt(row.file_size),
        modifiedNs: asBigInt(row.modified_ns),
        parsedOffset: asBigInt(row.parsed_offset),
        prefixLength: Number(row.prefix_length),
        prefixHash: asBigInt(row.prefix_hash),
        lastActivity: row.last_activity === null
            ? null
            : new Date(Number(row.last_activity) * 1_000).toISOString(),
        conversationTokenCount: Number(row.conversation_token_count),
    };
}
function queryIndex(database, roots, request, engine, onMatch) {
    const terms = [...new Set(request.terms)].sort();
    if (terms.length === 0)
        return { scannedFiles: 0, emitted: 0 };
    let candidates = matchingDocuments(database, terms[0]);
    for (const term of terms.slice(1)) {
        const matches = matchingDocuments(database, term);
        candidates = new Set([...candidates].filter((key) => matches.has(key)));
        if (candidates.size === 0)
            break;
    }
    const phrases = matchingDocuments(database, request.terms.join(" "));
    const now = Date.now();
    const candidateKeys = [...candidates];
    const rows = candidateKeys.length === 0
        ? []
        : candidateKeys.length <= 900
            ? database.prepare(`
          SELECT key, session_id, provider, project, cwd, title, file_path, last_activity
          FROM documents
          WHERE key IN (${candidateKeys.map(() => "?").join(",")})
        `).all(...candidateKeys)
            : database.prepare(`
          SELECT key, session_id, provider, project, cwd, title, file_path, last_activity
          FROM documents
        `).all();
    const ranked = [];
    for (const row of rows) {
        const key = String(row.key);
        if (!candidates.has(key))
            continue;
        const lastActivity = row.last_activity === null
            ? null
            : new Date(Number(row.last_activity) * 1_000).toISOString();
        let recency = 0;
        if (lastActivity) {
            const days = Math.max(0, (now - new Date(lastActivity).getTime()) / 86_400_000);
            recency = Math.max(0, 30 * (1 - Math.min(days, 365) / 365));
        }
        const exactPhrase = phrases.has(key);
        ranked.push({
            key,
            sessionId: String(row.session_id),
            project: String(row.project),
            cwd: String(row.cwd),
            title: String(row.title),
            filePath: String(row.file_path),
            lastActivity,
            score: terms.length * 25 + recency + (exactPhrase ? 1_000 : 0),
            exactPhrase,
            provider: String(row.provider),
        });
    }
    ranked.sort((left, right) => {
        if (left.score !== right.score)
            return right.score - left.score;
        const activity = (right.lastActivity ? new Date(right.lastActivity).getTime() : -Infinity)
            - (left.lastActivity ? new Date(left.lastActivity).getTime() : -Infinity);
        return activity !== 0 ? activity : left.sessionId.localeCompare(right.sessionId);
    });
    let emitted = 0;
    for (const candidate of ranked) {
        if (emitted >= request.limit)
            break;
        const parsed = readSearchDocument(candidate.filePath, rootForProvider(candidate.provider, roots), {
            provider: candidate.provider,
            sessionId: candidate.sessionId,
            title: candidate.title,
            cwd: candidate.cwd,
            lastActivity: candidate.lastActivity,
        });
        if (!parsed)
            continue;
        const document = {
            ...parsed,
            sessionId: candidate.sessionId,
            title: candidate.title,
            project: candidate.project,
            cwd: candidate.cwd,
            lastActivity: candidate.lastActivity,
        };
        const match = searchMatchForDocument(document, request, engine, candidate.exactPhrase, candidate.score);
        if (!match)
            continue;
        onMatch(match);
        emitted += 1;
    }
    return { scannedFiles: scalarCount(database, "SELECT count(*) AS value FROM documents"), emitted };
}
function matchingDocuments(database, value) {
    const statement = database.prepare(`
    SELECT DISTINCT r.document_key AS document_key
    FROM search_fts
    JOIN search_rows r ON r.rowid = search_fts.rowid
    JOIN documents d ON d.key = r.document_key
    WHERE search_fts MATCH ? AND r.scope = 'conversation'
  `);
    const quoted = `"${value.replaceAll('"', '""')}"`;
    return new Set(statement.all(quoted).map((row) => String(row.document_key)));
}
function userVersion(database) {
    const row = database.prepare("PRAGMA user_version").get();
    return row ? Number(row.user_version) : 0;
}
function scalarCount(database, sql) {
    const row = database.prepare(sql).get();
    return row ? Number(row.value) : 0;
}
function readFromOffset(filePath, offset) {
    if (offset > BigInt(Number.MAX_SAFE_INTEGER))
        return null;
    let descriptor = null;
    try {
        descriptor = fs.openSync(filePath, "r");
        const size = fs.fstatSync(descriptor).size - Number(offset);
        const buffer = Buffer.alloc(Math.max(0, size));
        fs.readSync(descriptor, buffer, 0, buffer.length, Number(offset));
        return buffer;
    }
    catch {
        return null;
    }
    finally {
        if (descriptor !== null)
            fs.closeSync(descriptor);
    }
}
function prefixHash(filePath, length) {
    let descriptor = null;
    try {
        descriptor = fs.openSync(filePath, "r");
        const buffer = Buffer.alloc(length);
        const bytes = fs.readSync(descriptor, buffer, 0, length, 0);
        return fnv1a64(buffer.subarray(0, bytes), true);
    }
    catch {
        return null;
    }
    finally {
        if (descriptor !== null)
            fs.closeSync(descriptor);
    }
}
function fnv1a64(bytes, signed = false) {
    let value = 14695981039346656037n;
    for (const byte of bytes) {
        value ^= BigInt(byte);
        value = BigInt.asUintN(64, value * 1099511628211n);
    }
    return signed ? BigInt.asIntN(64, value) : value;
}
function asBigInt(value) {
    return typeof value === "bigint" ? value : BigInt(Number(value));
}
function removeDatabase(databasePath) {
    for (const candidate of [databasePath, `${databasePath}-wal`, `${databasePath}-shm`]) {
        try {
            fs.rmSync(candidate, { force: true });
        }
        catch { /* best effort */ }
    }
}
function errorMessage(error) {
    return error instanceof Error ? error.message : String(error);
}
