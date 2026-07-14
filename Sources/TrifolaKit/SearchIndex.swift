import Foundation
import SQLite3
import Darwin

/// Exact search over the human-authored/narrative parts of local transcripts.
/// Tool calls, tool results, thinking, summaries, and system records are never
/// projected into this index.
public enum SearchText {
    public static let maximumTokenLength = 64
    public static let maximumDistinctTokensPerDocument = 4_096
    public static let maximumOrderedTokensPerDocument = 20_000

    public static func tokens(in text: String) -> [String] {
        let normalized = text.lowercased(with: Locale(identifier: "en_US_POSIX"))
        var output: [String] = []
        var current = ""
        func flush() {
            guard current.count >= 2, current.count <= maximumTokenLength else {
                current.removeAll(keepingCapacity: true)
                return
            }
            output.append(current)
            current.removeAll(keepingCapacity: true)
        }
        for character in normalized {
            if character.isLetter || character.isNumber {
                current.append(character)
            } else {
                flush()
            }
        }
        flush()
        return output
    }

    public static func searchableText(from event: TranscriptEvent) -> String? {
        switch event.kind {
        case .userPrompt(let text), .assistantText(let text): return text
        case .thinking, .toolUse, .toolResult, .system, .summary: return nil
        }
    }

    public static func searchableEvents(at url: URL,
                                        provider: Provider) -> [TranscriptEvent]? {
        switch provider {
        case .claude:
            guard let data = try? Data(contentsOf: url) else { return nil }
            return events(in: data, provider: provider, includeValidFinalLine: true).events
        case .codex:
            return CodexRolloutTranscriptParser.events(at: url, maximumEvents: .max)
        }
    }

    fileprivate static func events(
        in data: Data,
        provider: Provider,
        includeValidFinalLine: Bool
    ) -> (events: [TranscriptEvent], consumedBytes: Int) {
        var output: [TranscriptEvent] = []
        var start = data.startIndex
        var lineNumber = 0
        while start < data.endIndex,
              let newline = data[start...].firstIndex(of: 0x0A) {
            if newline > start {
                output.append(contentsOf: parse(
                    line: data.subdata(in: start..<newline),
                    provider: provider, lineNumber: lineNumber))
            }
            lineNumber += 1
            start = data.index(after: newline)
        }
        if start < data.endIndex, includeValidFinalLine {
            let tail = data.subdata(in: start..<data.endIndex)
            if (try? JSONSerialization.jsonObject(with: tail)) != nil {
                output.append(contentsOf: parse(
                    line: tail, provider: provider, lineNumber: lineNumber))
                return (output, data.count)
            }
        }
        return (output, data.distance(from: data.startIndex, to: start))
    }

    private static func parse(line: Data, provider: Provider,
                              lineNumber: Int) -> [TranscriptEvent] {
        switch provider {
        case .claude:
            return TranscriptParser.events(
                fromLine: line, fallbackID: "search-L\(lineNumber)")
        case .codex:
            return CodexRolloutTranscriptParser.events(
                fromLine: line, fallbackID: "search-codex-L\(lineNumber)")
        }
    }
}

public struct SearchQuery: Sendable, Equatable {
    public let rawValue: String
    public let tokens: [String]

    public init(_ rawValue: String) {
        self.rawValue = rawValue
        self.tokens = SearchText.tokens(in: rawValue)
    }

    public var isEmpty: Bool { tokens.isEmpty }
}

public enum SearchScope: Sendable, Equatable {
    case all
    case conversationText
}

public struct SearchCandidate: Identifiable, Sendable, Equatable {
    public let id: String
    public let provider: Provider
    public let project: String
    public let cwd: String
    public let title: String
    public let filePath: String
    public let lastActivity: Date?
    public let score: Double
    public let exactPhrase: Bool
    public let matchedConversationText: Bool

    public init(id: String, provider: Provider, project: String, cwd: String,
                title: String, filePath: String, lastActivity: Date?,
                score: Double, exactPhrase: Bool,
                matchedConversationText: Bool) {
        self.id = id
        self.provider = provider
        self.project = project
        self.cwd = cwd
        self.title = title
        self.filePath = filePath
        self.lastActivity = lastActivity
        self.score = score
        self.exactPhrase = exactPhrase
        self.matchedConversationText = matchedConversationText
    }
}

public struct SearchHighlight: Sendable, Equatable, Codable {
    public let start: Int
    public let length: Int

    public init(start: Int, length: Int) {
        self.start = start
        self.length = length
    }
}

public struct SearchSnippet: Sendable, Equatable {
    public let text: String
    public let highlights: [SearchHighlight]
    public let role: String

    public init(text: String, highlights: [SearchHighlight], role: String) {
        self.text = text
        self.highlights = highlights
        self.role = role
    }
}

public struct SearchResult: Identifiable, Sendable, Equatable {
    public let candidate: SearchCandidate
    public let snippet: SearchSnippet?
    public var id: String { candidate.id }

    public init(candidate: SearchCandidate, snippet: SearchSnippet?) {
        self.candidate = candidate
        self.snippet = snippet
    }
}

public struct SearchIndexStatistics: Sendable, Equatable {
    public let documentCount: Int
    public let uniqueTermCount: Int
    public let tokenCount: Int
    public let estimatedBytes: Int
}

public struct SearchIndexBatchProgress: Sendable, Equatable {
    public let indexed: Int
    public let total: Int

    public init(indexed: Int, total: Int) {
        self.indexed = min(max(0, indexed), max(0, total))
        self.total = max(0, total)
    }
}

public struct SearchIndexUpdate: Sendable {
    public let index: SearchIndex
    public let succeeded: Bool
    public let failureReason: String?
    public let rebuiltDocuments: Int
    public let appendedDocuments: Int
    public let reusedDocuments: Int
    public let removedDocuments: Int
    public let sourceBytesRead: UInt64
}

public enum SearchIndexLoadResult: Sendable {
    case ready(SearchIndex)
    case missing
    case versionMismatch(found: Int)
    case corrupt
}

public final class SearchIndexReadLease: @unchecked Sendable {
    private let connection: SQLiteConnection

    fileprivate init(connection: SQLiteConnection) {
        self.connection = connection
        try? connection.execute("BEGIN")
        _ = try? connection.scalarInt("SELECT count(*) FROM documents")
    }
}

/// A path-backed SQLite FTS5 index. Values are cheap, Sendable handles: every
/// query opens its own read connection while update owns a separate WAL writer.
public struct SearchIndex: Sendable {
    public static let currentVersion = 3
    public static let defaultBatchSize = 200

    public let databaseURL: URL
    public var walURL: URL { URL(fileURLWithPath: databaseURL.path + "-wal") }

    public init() {
        databaseURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("trifola-search-\(UUID().uuidString).sqlite3")
        try? Self.prepareDatabase(at: databaseURL)
    }

    public init(storageURL: URL) throws {
        databaseURL = storageURL
        try Self.prepareDatabase(at: storageURL)
    }

    private init(preparedURL: URL) {
        databaseURL = preparedURL
    }

    public static func reference(to url: URL) -> SearchIndex {
        SearchIndex(preparedURL: url)
    }

    public static func load(from url: URL) -> SearchIndexLoadResult {
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do {
            let connection = try SQLiteConnection(url: url, readOnly: true)
            let version = try connection.scalarInt("PRAGMA user_version")
            guard version == currentVersion else {
                return .versionMismatch(found: version)
            }
            _ = try connection.scalarInt("SELECT count(*) FROM documents")
            _ = try connection.scalarInt("SELECT count(*) FROM search_fts")
            return .ready(SearchIndex(preparedURL: url))
        } catch {
            return .corrupt
        }
    }

    public static func removeDatabase(at url: URL) {
        let manager = FileManager.default
        for path in [url.path, url.path + "-wal", url.path + "-shm"] {
            try? manager.removeItem(atPath: path)
        }
    }

    public var statistics: SearchIndexStatistics {
        guard let connection = try? SQLiteConnection(url: databaseURL, readOnly: true) else {
            return SearchIndexStatistics(documentCount: 0, uniqueTermCount: 0,
                                         tokenCount: 0, estimatedBytes: 0)
        }
        let documents = (try? connection.scalarInt(
            "SELECT count(*) FROM documents")) ?? 0
        let terms = (try? connection.scalarInt(
            "SELECT count(*) FROM search_vocab")) ?? 0
        let tokens = (try? connection.scalarInt(
            "SELECT coalesce(sum(metadata_token_count + conversation_token_count), 0) FROM documents")) ?? 0
        let manager = FileManager.default
        let bytes = [databaseURL.path, databaseURL.path + "-wal",
                     databaseURL.path + "-shm"].reduce(0) { total, path in
            let attributes = try? manager.attributesOfItem(atPath: path)
            return total + ((attributes?[.size] as? NSNumber)?.intValue ?? 0)
        }
        return SearchIndexStatistics(documentCount: documents,
                                     uniqueTermCount: terms,
                                     tokenCount: tokens,
                                     estimatedBytes: bytes)
    }

    public static func update(
        _ previous: SearchIndex,
        sessions: [SessionSummary],
        batchSize: Int = defaultBatchSize,
        automaticCheckpointPages: Int = 256,
        progress: (@Sendable (SearchIndexBatchProgress) -> Void)? = nil
    ) -> SearchIndexUpdate {
        do {
            return try updateThrowing(previous, sessions: sessions,
                                      batchSize: max(1, batchSize),
                                      automaticCheckpointPages: automaticCheckpointPages,
                                      progress: progress)
        } catch {
            return SearchIndexUpdate(
                index: previous, succeeded: false,
                failureReason: String(describing: error),
                rebuiltDocuments: 0, appendedDocuments: 0,
                reusedDocuments: 0, removedDocuments: 0, sourceBytesRead: 0)
        }
    }

    public func query(
        _ query: SearchQuery,
        scope: SearchScope = .all,
        limit: Int = 20,
        now: Date = Date()
    ) -> [SearchCandidate] {
        guard !query.tokens.isEmpty, limit > 0,
              let connection = try? SQLiteConnection(
                url: databaseURL, readOnly: true) else { return [] }
        let terms = Array(Set(query.tokens)).sorted()
        guard var candidates = matchingDocuments(
            term: terms[0], scope: scope, connection: connection) else { return [] }
        for term in terms.dropFirst() {
            guard let matches = matchingDocuments(
                term: term, scope: scope, connection: connection) else { return [] }
            candidates.formIntersection(matches)
            if candidates.isEmpty { return [] }
        }
        let phrase = phraseMatches(
            terms: query.tokens, scope: scope, connection: connection)
        let conversationMatches: Set<String> = scope == .conversationText
            ? candidates
            : terms.reduce(nil as Set<String>?) { current, term in
                guard let matches = matchingDocuments(
                    term: term, scope: .conversationText, connection: connection) else {
                    return []
                }
                guard let current else { return matches }
                return current.intersection(matches)
            } ?? []

        guard let statement = try? connection.prepare(
            "SELECT key, session_id, provider, project, cwd, title, file_path, last_activity FROM documents") else {
            return []
        }
        var ranked: [SearchCandidate] = []
        while statement.step() == SQLITE_ROW {
            let key = statement.text(0)
            guard candidates.contains(key),
                  let provider = Provider(rawValue: statement.text(2)) else { continue }
            let last = statement.isNull(7) ? nil
                : Date(timeIntervalSince1970: statement.double(7))
            let recency: Double
            if let last {
                let days = max(0, now.timeIntervalSince(last) / 86_400)
                recency = max(0, 30 * (1 - min(days, 365) / 365))
            } else {
                recency = 0
            }
            let isPhrase = phrase.contains(key)
            ranked.append(SearchCandidate(
                id: statement.text(1), provider: provider,
                project: statement.text(3), cwd: statement.text(4),
                title: statement.text(5), filePath: statement.text(6),
                lastActivity: last,
                score: Double(terms.count * 25) + recency + (isPhrase ? 1_000 : 0),
                exactPhrase: isPhrase,
                matchedConversationText: conversationMatches.contains(key)))
        }
        ranked.sort {
            if $0.score != $1.score { return $0.score > $1.score }
            let lhs = $0.lastActivity ?? .distantPast
            let rhs = $1.lastActivity ?? .distantPast
            return lhs == rhs ? $0.id < $1.id : lhs > rhs
        }
        return Array(ranked.prefix(limit))
    }

    public func keepReaderOpen() -> SearchIndexReadLease? {
        guard let connection = try? SQLiteConnection(
            url: databaseURL, readOnly: true) else { return nil }
        return SearchIndexReadLease(connection: connection)
    }

    public func truncateWAL() {
        guard let connection = try? SQLiteConnection(
            url: databaseURL, readOnly: false) else { return }
        try? connection.execute("PRAGMA wal_checkpoint(TRUNCATE)")
    }

    private static func updateThrowing(
        _ index: SearchIndex,
        sessions: [SessionSummary],
        batchSize: Int,
        automaticCheckpointPages: Int,
        progress: (@Sendable (SearchIndexBatchProgress) -> Void)?
    ) throws -> SearchIndexUpdate {
        try prepareDatabase(at: index.databaseURL)
        let connection = try SQLiteConnection(url: index.databaseURL, readOnly: false)
        try connection.execute(
            "PRAGMA wal_autocheckpoint=\(max(0, automaticCheckpointPages))")
        let old = try loadDocuments(connection)
        let currentKeys = Set(sessions.map(documentKey))
        let removed = Set(old.keys).subtracting(currentKeys)
        if !removed.isEmpty {
            try connection.transaction {
                let delete = try connection.prepare("DELETE FROM documents WHERE key = ?")
                for key in removed {
                    delete.reset()
                    try delete.bind(key, at: 1)
                    try delete.run()
                }
            }
        }

        var reused = 0
        var work: [IndexWork] = []
        for summary in sessions {
            let key = documentKey(summary)
            let metadata = fileMetadata(at: summary.filePath)
            let size = metadata.size
            let modifiedNanoseconds = metadata.modifiedNanoseconds
            if let existing = old[key], existing.matches(
                summary, size: size,
                modifiedNanoseconds: modifiedNanoseconds) {
                reused += 1
                continue
            }
            work.append(IndexWork(summary: summary, key: key, size: size,
                                  modifiedNanoseconds: modifiedNanoseconds,
                                  existing: old[key]))
        }

        var rebuilt = 0
        var appended = 0
        var bytesRead: UInt64 = 0
        var completed = reused
        if work.isEmpty {
            progress?(SearchIndexBatchProgress(indexed: sessions.count,
                                               total: sessions.count))
        }
        for start in stride(from: 0, to: work.count, by: batchSize) {
            let end = min(start + batchSize, work.count)
            let items = Array(work[start..<end])
            let preparedState = Locked(
                [PreparedChange?](repeating: nil, count: items.count))
            DispatchQueue.concurrentPerform(iterations: items.count) { offset in
                let change = prepare(items[offset])
                preparedState.withLock { $0[offset] = change }
            }
            let prepared = preparedState.withLock { values in
                values.compactMap { $0 }
            }
            for change in prepared {
                bytesRead += change.bytesRead
                if change.isAppend { appended += 1 } else if change.readSource { rebuilt += 1 }
            }
            try connection.transaction {
                for change in prepared { try apply(change, connection: connection) }
            }
            completed += prepared.count
            progress?(SearchIndexBatchProgress(indexed: completed,
                                               total: sessions.count))
        }
        return SearchIndexUpdate(
            index: index, succeeded: true, failureReason: nil,
            rebuiltDocuments: rebuilt,
            appendedDocuments: appended, reusedDocuments: reused,
            removedDocuments: removed.count, sourceBytesRead: bytesRead)
    }

    private static func prepare(_ work: IndexWork) -> PreparedChange {
        let metadata = SearchText.tokens(in: [
            work.summary.displayTitle, work.summary.project, work.summary.cwd,
        ].joined(separator: " "))
        if let old = work.existing,
           old.fileSize == work.size,
           old.modifiedNanoseconds == work.modifiedNanoseconds {
            return PreparedChange(work: work, rows: [], parsedOffset: old.parsedOffset,
                                  prefixLength: old.prefixLength,
                                  prefixHash: old.prefixHash,
                                  metadataTokens: metadata,
                                  conversationTokenCount: old.conversationTokenCount,
                                  bytesRead: 0, isAppend: false, readSource: false,
                                  replaceConversation: false)
        }

        let url = URL(fileURLWithPath: work.summary.filePath)
        let canAppend: Bool
        if let old = work.existing,
           !work.summary.filePath.hasSuffix(".zst"),
           work.size > old.fileSize,
           old.parsedOffset <= work.size,
           let hash = prefixHash(at: url, length: old.prefixLength) {
            canAppend = hash == old.prefixHash
        } else {
            canAppend = false
        }

        if canAppend, let old = work.existing,
           let suffix = read(at: url, offset: old.parsedOffset) {
            let parsed = SearchText.events(
                in: suffix, provider: work.summary.provider,
                includeValidFinalLine: true)
            let rows = tokenRows(
                parsed.events,
                remaining: max(0, SearchText.maximumOrderedTokensPerDocument
                    - old.conversationTokenCount))
            return PreparedChange(
                work: work, rows: rows.rows,
                parsedOffset: old.parsedOffset + UInt64(parsed.consumedBytes),
                prefixLength: old.prefixLength, prefixHash: old.prefixHash,
                metadataTokens: metadata,
                conversationTokenCount: old.conversationTokenCount + rows.count,
                bytesRead: UInt64(suffix.count) + UInt64(old.prefixLength),
                isAppend: true, readSource: true, replaceConversation: false)
        }

        if work.summary.filePath.hasSuffix(".zst") {
            let events = SearchText.searchableEvents(
                at: url, provider: work.summary.provider) ?? []
            let rows = tokenRows(
                events, remaining: SearchText.maximumOrderedTokensPerDocument)
            let length = Int(min(work.size, 4_096))
            return PreparedChange(
                work: work, rows: rows.rows, parsedOffset: work.size,
                prefixLength: length,
                prefixHash: prefixHash(at: url, length: length) ?? 0,
                metadataTokens: metadata,
                conversationTokenCount: rows.count,
                bytesRead: work.size + UInt64(length), isAppend: false,
                readSource: true, replaceConversation: true)
        }

        let data = read(at: url, offset: 0) ?? Data()
        let parsed = SearchText.events(
            in: data, provider: work.summary.provider,
            includeValidFinalLine: true)
        let rows = tokenRows(
            parsed.events, remaining: SearchText.maximumOrderedTokensPerDocument)
        let length = min(data.count, 4_096)
        return PreparedChange(
            work: work, rows: rows.rows,
            parsedOffset: UInt64(parsed.consumedBytes),
            prefixLength: length, prefixHash: hash(data.prefix(length)),
            metadataTokens: metadata, conversationTokenCount: rows.count,
            bytesRead: UInt64(data.count), isAppend: false,
            readSource: true, replaceConversation: true)
    }

    private static func tokenRows(
        _ events: [TranscriptEvent],
        remaining: Int
    ) -> (rows: [String], count: Int) {
        var rows: [String] = []
        var count = 0
        for event in events {
            guard count < remaining,
                  let text = SearchText.searchableText(from: event) else { continue }
            let tokens = Array(SearchText.tokens(in: text).prefix(remaining - count))
            guard !tokens.isEmpty else { continue }
            rows.append(tokens.joined(separator: " "))
            count += tokens.count
        }
        return (rows, count)
    }

    private static func apply(_ change: PreparedChange,
                              connection: SQLiteConnection) throws {
        let document = try connection.prepare("""
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
            """)
        let summary = change.work.summary
        try document.bind(change.work.key, at: 1)
        try document.bind(summary.id, at: 2)
        try document.bind(summary.provider.rawValue, at: 3)
        try document.bind(summary.project, at: 4)
        try document.bind(summary.cwd, at: 5)
        try document.bind(summary.displayTitle, at: 6)
        try document.bind(summary.filePath, at: 7)
        try document.bind(Int64(bitPattern: change.work.size), at: 8)
        try document.bind(change.work.modifiedNanoseconds, at: 9)
        try document.bind(Int64(bitPattern: change.parsedOffset), at: 10)
        try document.bind(Int64(change.prefixLength), at: 11)
        try document.bind(change.prefixHash, at: 12)
        if let activity = summary.lastActivity {
            try document.bind(activity.timeIntervalSince1970, at: 13)
        } else {
            try document.bindNull(at: 13)
        }
        try document.bind(Int64(change.metadataTokens.count), at: 14)
        try document.bind(Int64(change.conversationTokenCount), at: 15)
        try document.run()

        let deleteMetadata = try connection.prepare(
            "DELETE FROM search_rows WHERE document_key = ? AND scope = 'metadata'")
        try deleteMetadata.bind(change.work.key, at: 1)
        try deleteMetadata.run()
        if !change.metadataTokens.isEmpty {
            try insertRow(documentKey: change.work.key, scope: "metadata",
                          content: change.metadataTokens.joined(separator: " "),
                          connection: connection)
        }
        if change.replaceConversation {
            let deleteConversation = try connection.prepare(
                "DELETE FROM search_rows WHERE document_key = ? AND scope = 'conversation'")
            try deleteConversation.bind(change.work.key, at: 1)
            try deleteConversation.run()
        }
        for row in change.rows {
            try insertRow(documentKey: change.work.key, scope: "conversation",
                          content: row, connection: connection)
        }
    }

    private static func insertRow(documentKey: String, scope: String,
                                  content: String,
                                  connection: SQLiteConnection) throws {
        let statement = try connection.prepare(
            "INSERT INTO search_rows(document_key, scope, content) VALUES(?, ?, ?)")
        try statement.bind(documentKey, at: 1)
        try statement.bind(scope, at: 2)
        try statement.bind(content, at: 3)
        try statement.run()
    }

    private static func prepareDatabase(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let connection = try SQLiteConnection(url: url, readOnly: false)
        let version = try connection.scalarInt("PRAGMA user_version")
        if version != 0 && version != currentVersion {
            throw SQLiteFailure.message("search schema version \(version) is not \(currentVersion)")
        }
        try connection.execute("PRAGMA journal_mode=WAL")
        try connection.execute("PRAGMA synchronous=NORMAL")
        try connection.execute("PRAGMA foreign_keys=ON")
        try connection.execute("PRAGMA wal_autocheckpoint=256")
        try connection.execute("""
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
            )
            """)
        try connection.execute("""
            CREATE TABLE IF NOT EXISTS search_rows(
                rowid INTEGER PRIMARY KEY,
                document_key TEXT NOT NULL REFERENCES documents(key) ON DELETE CASCADE,
                scope TEXT NOT NULL,
                content TEXT NOT NULL
            )
            """)
        try connection.execute(
            "CREATE INDEX IF NOT EXISTS search_rows_document ON search_rows(document_key, scope)")
        try connection.execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS search_fts USING fts5(
                content, content='search_rows', content_rowid='rowid',
                tokenize='unicode61 remove_diacritics 0'
            )
            """)
        try connection.execute("""
            CREATE TRIGGER IF NOT EXISTS search_rows_insert AFTER INSERT ON search_rows BEGIN
                INSERT INTO search_fts(rowid, content) VALUES (new.rowid, new.content);
            END
            """)
        try connection.execute("""
            CREATE TRIGGER IF NOT EXISTS search_rows_delete AFTER DELETE ON search_rows BEGIN
                INSERT INTO search_fts(search_fts, rowid, content)
                VALUES('delete', old.rowid, old.content);
            END
            """)
        try connection.execute("""
            CREATE TRIGGER IF NOT EXISTS search_rows_update AFTER UPDATE ON search_rows BEGIN
                INSERT INTO search_fts(search_fts, rowid, content)
                VALUES('delete', old.rowid, old.content);
                INSERT INTO search_fts(rowid, content) VALUES (new.rowid, new.content);
            END
            """)
        try connection.execute(
            "CREATE VIRTUAL TABLE IF NOT EXISTS search_vocab USING fts5vocab(search_fts, 'row')")
        if version == 0 {
            // Live appends must remain bounded. FTS5's default auto/crisis
            // segment merges can rewrite megabytes of index pages when one tiny
            // message arrives; explicit maintenance can compact later, off the
            // latency-sensitive append path.
            try connection.execute(
                "INSERT INTO search_fts(search_fts, rank) VALUES('automerge', 0)")
            try connection.execute(
                "INSERT INTO search_fts(search_fts, rank) VALUES('crisismerge', 0)")
            try connection.execute("PRAGMA user_version=\(currentVersion)")
        }
    }

    private static func loadDocuments(
        _ connection: SQLiteConnection
    ) throws -> [String: StoredDocument] {
        let statement = try connection.prepare("""
            SELECT key, provider, project, cwd, title, file_path, file_size,
                   modified_ns, parsed_offset, prefix_length, prefix_hash,
                   last_activity, conversation_token_count
            FROM documents
            """)
        var output: [String: StoredDocument] = [:]
        while statement.step() == SQLITE_ROW {
            let key = statement.text(0)
            output[key] = StoredDocument(
                provider: statement.text(1), project: statement.text(2),
                cwd: statement.text(3), title: statement.text(4),
                filePath: statement.text(5),
                fileSize: UInt64(bitPattern: statement.int64(6)),
                modifiedNanoseconds: statement.int64(7),
                parsedOffset: UInt64(bitPattern: statement.int64(8)),
                prefixLength: Int(statement.int64(9)),
                prefixHash: statement.int64(10),
                lastActivity: statement.isNull(11) ? nil
                    : Date(timeIntervalSince1970: statement.double(11)),
                conversationTokenCount: Int(statement.int64(12)))
        }
        return output
    }

    private func matchingDocuments(term: String, scope: SearchScope,
                                   connection: SQLiteConnection) -> Set<String>? {
        let sql = """
            SELECT DISTINCT r.document_key
            FROM search_fts JOIN search_rows r ON r.rowid = search_fts.rowid
            WHERE search_fts MATCH ? \(scope == .conversationText ? "AND r.scope = 'conversation'" : "")
            """
        guard let statement = try? connection.prepare(sql),
              (try? statement.bind(quoted(term), at: 1)) != nil else { return nil }
        var output: Set<String> = []
        while statement.step() == SQLITE_ROW { output.insert(statement.text(0)) }
        return output
    }

    private func phraseMatches(terms: [String], scope: SearchScope,
                               connection: SQLiteConnection) -> Set<String> {
        guard !terms.isEmpty else { return [] }
        let sql = """
            SELECT DISTINCT r.document_key
            FROM search_fts JOIN search_rows r ON r.rowid = search_fts.rowid
            WHERE search_fts MATCH ? \(scope == .conversationText ? "AND r.scope = 'conversation'" : "")
            """
        guard let statement = try? connection.prepare(sql),
              (try? statement.bind(quoted(terms.joined(separator: " ")), at: 1)) != nil else {
            return []
        }
        var output: Set<String> = []
        while statement.step() == SQLITE_ROW { output.insert(statement.text(0)) }
        return output
    }

    private func quoted(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    private static func documentKey(_ summary: SessionSummary) -> String {
        [summary.provider.rawValue, summary.machineID,
         summary.id, summary.filePath].joined(separator: "\u{1}")
    }

    private static func read(at url: URL, offset: UInt64) -> Data? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        try? handle.seek(toOffset: offset)
        return try? handle.readToEnd()
    }

    private static func fileMetadata(
        at path: String
    ) -> (size: UInt64, modifiedNanoseconds: Int64) {
        var value = stat()
        guard lstat(path, &value) == 0 else { return (0, 0) }
        let seconds = Int64(value.st_mtimespec.tv_sec)
        let nanoseconds = Int64(value.st_mtimespec.tv_nsec)
        return (UInt64(max(0, value.st_size)),
                seconds &* 1_000_000_000 &+ nanoseconds)
    }

    private static func prefixHash(at url: URL, length: Int) -> Int64? {
        guard length >= 0,
              let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        return try? hash(handle.read(upToCount: length) ?? Data())
    }

    private static func hash<S: Sequence>(_ bytes: S) -> Int64 where S.Element == UInt8 {
        var value: UInt64 = 14_695_981_039_346_656_037
        for byte in bytes {
            value ^= UInt64(byte)
            value &*= 1_099_511_628_211
        }
        return Int64(bitPattern: value)
    }
}

private struct StoredDocument {
    let provider: String
    let project: String
    let cwd: String
    let title: String
    let filePath: String
    let fileSize: UInt64
    let modifiedNanoseconds: Int64
    let parsedOffset: UInt64
    let prefixLength: Int
    let prefixHash: Int64
    let lastActivity: Date?
    let conversationTokenCount: Int

    func matches(_ summary: SessionSummary, size: UInt64,
                 modifiedNanoseconds: Int64) -> Bool {
        provider == summary.provider.rawValue && project == summary.project
            && cwd == summary.cwd && title == summary.displayTitle
            && filePath == summary.filePath && fileSize == size
            && self.modifiedNanoseconds == modifiedNanoseconds
            && lastActivity == summary.lastActivity
    }
}

private struct IndexWork {
    let summary: SessionSummary
    let key: String
    let size: UInt64
    let modifiedNanoseconds: Int64
    let existing: StoredDocument?
}

private struct PreparedChange {
    let work: IndexWork
    let rows: [String]
    let parsedOffset: UInt64
    let prefixLength: Int
    let prefixHash: Int64
    let metadataTokens: [String]
    let conversationTokenCount: Int
    let bytesRead: UInt64
    let isAppend: Bool
    let readSource: Bool
    let replaceConversation: Bool
}

private enum SQLiteFailure: Error {
    case message(String)
}

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

private final class SQLiteConnection {
    private var database: OpaquePointer?

    init(url: URL, readOnly: Bool) throws {
        let flags = readOnly
            ? SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX
            : SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(url.path, &database, flags, nil) == SQLITE_OK,
              database != nil else {
            let message = database.map { String(cString: sqlite3_errmsg($0)) }
                ?? "could not open SQLite database"
            if let database { sqlite3_close(database) }
            database = nil
            throw SQLiteFailure.message(message)
        }
        sqlite3_busy_timeout(database, 5_000)
        if readOnly { try execute("PRAGMA query_only=ON") }
    }

    deinit {
        if let database { sqlite3_close(database) }
    }

    func execute(_ sql: String) throws {
        var error: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(database, sql, nil, nil, &error) == SQLITE_OK else {
            let message = error.map { String(cString: $0) }
                ?? String(cString: sqlite3_errmsg(database))
            sqlite3_free(error)
            throw SQLiteFailure.message(message)
        }
    }

    func scalarInt(_ sql: String) throws -> Int {
        let statement = try prepare(sql)
        guard statement.step() == SQLITE_ROW else {
            throw SQLiteFailure.message("SQLite scalar returned no row")
        }
        return Int(statement.int64(0))
    }

    func prepare(_ sql: String) throws -> SQLiteStatement {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(database, sql, -1, &statement, nil) == SQLITE_OK,
              let statement else {
            throw SQLiteFailure.message(String(cString: sqlite3_errmsg(database)))
        }
        return SQLiteStatement(statement: statement, database: database)
    }

    func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }
}

private final class SQLiteStatement {
    private let statement: OpaquePointer
    private let database: OpaquePointer?

    init(statement: OpaquePointer, database: OpaquePointer?) {
        self.statement = statement
        self.database = database
    }

    deinit { sqlite3_finalize(statement) }

    func reset() {
        sqlite3_reset(statement)
        sqlite3_clear_bindings(statement)
    }

    func bind(_ value: String, at index: Int32) throws {
        guard sqlite3_bind_text(statement, index, value, -1, sqliteTransient) == SQLITE_OK else {
            throw error()
        }
    }

    func bind(_ value: Int64, at index: Int32) throws {
        guard sqlite3_bind_int64(statement, index, value) == SQLITE_OK else { throw error() }
    }

    func bind(_ value: Double, at index: Int32) throws {
        guard sqlite3_bind_double(statement, index, value) == SQLITE_OK else { throw error() }
    }

    func bindNull(at index: Int32) throws {
        guard sqlite3_bind_null(statement, index) == SQLITE_OK else { throw error() }
    }

    @discardableResult
    func step() -> Int32 { sqlite3_step(statement) }

    func run() throws {
        guard step() == SQLITE_DONE else { throw error() }
    }

    func text(_ column: Int32) -> String {
        guard let value = sqlite3_column_text(statement, column) else { return "" }
        return String(cString: value)
    }

    func int64(_ column: Int32) -> Int64 {
        sqlite3_column_int64(statement, column)
    }

    func double(_ column: Int32) -> Double {
        sqlite3_column_double(statement, column)
    }

    func isNull(_ column: Int32) -> Bool {
        sqlite3_column_type(statement, column) == SQLITE_NULL
    }

    private func error() -> SQLiteFailure {
        .message(String(cString: sqlite3_errmsg(database)))
    }
}

public enum SearchSnippetExtractor {
    public static let maximumCharacters = 220

    public static func snippet(
        for candidate: SearchCandidate,
        query: SearchQuery
    ) -> SearchSnippet? {
        guard !candidate.filePath.isEmpty,
              let events = SearchText.searchableEvents(
                at: URL(fileURLWithPath: candidate.filePath),
                provider: candidate.provider) else { return nil }

        var best: (text: String, role: String, score: Int)?
        let unique = Set(query.tokens)
        for event in events {
            guard let text = SearchText.searchableText(from: event) else { continue }
            let tokens = SearchText.tokens(in: text)
            let present = unique.reduce(0) { $0 + (tokens.contains($1) ? 1 : 0) }
            guard present > 0 else { continue }
            let phrase = phraseAppears(query.rawValue, in: text)
            let score = present * 100 + (phrase ? 1_000 : 0)
            let role: String
            switch event.kind {
            case .userPrompt: role = "You"
            case .assistantText: role = "Assistant"
            default: continue
            }
            if best == nil || score > best!.score { best = (text, role, score) }
        }
        guard let best else { return nil }
        let excerpt = excerpt(from: best.text, terms: query.tokens)
        return SearchSnippet(
            text: excerpt, highlights: highlights(in: excerpt, terms: query.tokens),
            role: best.role)
    }

    private static func phraseAppears(_ phrase: String, in text: String) -> Bool {
        guard !phrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return text.range(of: phrase, options: [.caseInsensitive, .diacriticInsensitive],
                          locale: Locale(identifier: "en_US_POSIX")) != nil
    }

    private static func excerpt(from text: String, terms: [String]) -> String {
        guard text.count > maximumCharacters else { return text }
        let first = terms.compactMap {
            text.range(of: $0, options: [.caseInsensitive, .diacriticInsensitive],
                       locale: Locale(identifier: "en_US_POSIX"))?.lowerBound
        }.min() ?? text.startIndex
        let location = text.distance(from: text.startIndex, to: first)
        let startOffset = max(0, location - maximumCharacters / 3)
        let endOffset = min(text.count, startOffset + maximumCharacters)
        let start = text.index(text.startIndex, offsetBy: startOffset)
        let end = text.index(text.startIndex, offsetBy: endOffset)
        return (startOffset > 0 ? "…" : "") + String(text[start..<end])
            + (endOffset < text.count ? "…" : "")
    }

    private static func highlights(in text: String,
                                   terms: [String]) -> [SearchHighlight] {
        var output: [SearchHighlight] = []
        let locale = Locale(identifier: "en_US_POSIX")
        for term in Set(terms) {
            var cursor = text.startIndex
            while cursor < text.endIndex,
                  let range = text.range(
                    of: term, options: [.caseInsensitive, .diacriticInsensitive],
                    range: cursor..<text.endIndex, locale: locale) {
                output.append(SearchHighlight(
                    start: text.distance(from: text.startIndex, to: range.lowerBound),
                    length: text.distance(from: range.lowerBound, to: range.upperBound)))
                cursor = range.upperBound
            }
        }
        return output.sorted { $0.start < $1.start }
    }
}
