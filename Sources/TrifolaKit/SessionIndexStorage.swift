import Foundation
import SQLite3

/// Observable cache lifecycle. Schema/payload mismatches are explicit rebuilds,
/// never silent misses that look like a healthy cold start.
public enum SessionIndexCacheState: Sendable, Equatable {
    case missing
    case ready
    case rebuilding(String)
}

/// Delta-write evidence returned by each SQLite persistence pass.
public struct SessionIndexPersistenceReport: Sendable, Equatable {
    public let inserted: Int
    public let updated: Int
    public let reused: Int
    public let deleted: Int
    public let payloadBytesWritten: Int

    public init(inserted: Int, updated: Int, reused: Int, deleted: Int,
                payloadBytesWritten: Int) {
        self.inserted = inserted
        self.updated = updated
        self.reused = reused
        self.deleted = deleted
        self.payloadBytesWritten = payloadBytesWritten
    }
}

enum SessionIndexCacheLoad {
    case ready(SessionIndex)
    case missing
    case rebuild(String)
}

/// One row per transcript accumulator. WAL transactions update only changed
/// rows, replacing the former 59MB whole-file JSON rewrite with page deltas.
enum SessionIndexDatabase {
    static let schemaVersion = 1
    /// Bump with any incompatible SessionParserState Codable shape.
    static let payloadVersion = 21
    private static let decodeRowsPerChunk = 128
    private static let decodeWorkerCount = max(
        1, min(ProcessInfo.processInfo.activeProcessorCount, 16))
    private static let decodeBatchRowCount = decodeRowsPerChunk * decodeWorkerCount

    private struct Fingerprint: Equatable {
        let size: UInt64
        let mtime: Double
        let provider: String
        let machineID: String
    }

    static func databaseURL(for requested: URL) -> URL {
        guard requested.pathExtension.lowercased() == "json" else { return requested }
        return requested.deletingPathExtension().appendingPathExtension("sqlite3")
    }

    static func legacyJSONURL(for requested: URL) -> URL {
        if requested.pathExtension.lowercased() == "json" { return requested }
        return requested.deletingPathExtension().appendingPathExtension("json")
    }

    static func removeDatabase(at requested: URL) {
        let url = databaseURL(for: requested)
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(
                at: URL(fileURLWithPath: url.path + suffix))
        }
    }

    private static func chunkCount(_ rows: Int) -> Int {
        max(1, min(decodeWorkerCount,
                   (rows + decodeRowsPerChunk - 1) / decodeRowsPerChunk))
    }

    static func load(from requested: URL, timeZone: TimeZone) -> SessionIndexCacheLoad {
        let url = databaseURL(for: requested)
        guard FileManager.default.fileExists(atPath: url.path) else { return .missing }
        do {
            let connection = try SQLiteConnection(url: url, readOnly: true)
            let schema = try connection.scalarInt("PRAGMA user_version")
            guard schema == schemaVersion else {
                return .rebuild("session-index schema v\(schema) → v\(schemaVersion)")
            }
            let metadata = try connection.prepare(
                "SELECT payload_version, time_zone FROM cache_metadata WHERE id = 1")
            guard metadata.step() == SQLITE_ROW else {
                return .rebuild("session-index metadata is missing")
            }
            let payload = Int(metadata.int64(0))
            guard payload == payloadVersion else {
                return .rebuild("session-index payload v\(payload) → v\(payloadVersion)")
            }
            let storedZone = metadata.text(1)
            guard storedZone == timeZone.identifier else {
                return .rebuild("session-index time zone \(storedZone) → \(timeZone.identifier)")
            }

            let rows = try connection.prepare("""
                SELECT path, file_size, modified_at, provider, machine_id, accumulator
                FROM session_entries
                """)
            // Row payloads decode in parallel: sequential JSONDecoder work on
            // tens of thousands of accumulator blobs is what made a "warm"
            // launch take tens of seconds. SQLite reads stay on this thread.
            struct RawRow {
                let path: String
                let size: Int64
                let mtime: Double
                let provider: Provider
                let machineID: String
                let blob: Data
            }
            var index = SessionIndex()
            while true {
                var raw: [RawRow] = []
                raw.reserveCapacity(decodeBatchRowCount)
                while raw.count < decodeBatchRowCount,
                      rows.step() == SQLITE_ROW {
                    guard let provider = Provider(rawValue: rows.text(3)) else {
                        return .rebuild("session-index contains an unknown provider")
                    }
                    raw.append(RawRow(
                        path: rows.text(0),
                        size: rows.int64(1),
                        mtime: rows.double(2),
                        provider: provider,
                        machineID: rows.text(4),
                        blob: rows.data(5)))
                }
                guard !raw.isEmpty else { break }
                let chunks = chunkCount(raw.count)
                let batch = raw
                let decoded = Locked<[[(String, SessionIndex.Entry)]]>(
                    Array(repeating: [], count: chunks))
                let failed = Locked<Error?>(nil)
                let stride = (raw.count + chunks - 1) / chunks
                DispatchQueue.concurrentPerform(iterations: chunks) { chunk in
                    let decoder = JSONDecoder()
                    let lower = chunk * stride
                    let upper = min(batch.count, lower + stride)
                    var entries: [(String, SessionIndex.Entry)] = []
                    entries.reserveCapacity(upper - lower)
                    for i in lower..<upper {
                        let row = batch[i]
                        do {
                            let accumulator = try decoder.decode(
                                SessionParserState.self, from: row.blob)
                            entries.append((row.path, SessionIndex.Entry(
                                size: UInt64(bitPattern: row.size),
                                mtime: Date(timeIntervalSince1970: row.mtime),
                                acc: accumulator,
                                provider: row.provider,
                                machineID: row.machineID,
                                summary: accumulator.summary(
                                    filePath: row.path,
                                    machineID: row.machineID))))
                        } catch {
                            failed.withLock { $0 = $0 ?? error }
                            return
                        }
                    }
                    decoded.withLock { $0[chunk] = entries }
                }
                if let error = failed.withLock({ $0 }) { throw error }
                index.entries.reserveCapacity(index.entries.count + raw.count)
                for chunk in decoded.withLock({ $0 }) {
                    for (path, entry) in chunk { index.entries[path] = entry }
                }
            }
            index.reconcileCrossFileUsage()
            return .ready(index)
        } catch {
            return .rebuild("session-index unreadable: \(error)")
        }
    }

    static func save(_ index: SessionIndex, to requested: URL,
                     timeZone: TimeZone) -> SessionIndexPersistenceReport? {
        let url = databaseURL(for: requested)
        do {
            try prepareDatabase(at: url)
            let connection = try SQLiteConnection(url: url, readOnly: false)
            let old = try fingerprints(connection)
            let currentPaths = Set(index.entries.keys)
            let removed = Set(old.keys).subtracting(currentPaths)
            var inserted = 0
            var updated = 0
            var reused = 0
            var bytesWritten = 0
            var encoded: [(String, SessionIndex.Entry, Data)] = []
            let encoder = JSONEncoder()

            for (path, entry) in index.entries {
                let fingerprint = Fingerprint(
                    size: entry.size,
                    mtime: entry.mtime.timeIntervalSince1970,
                    provider: entry.provider.rawValue,
                    machineID: entry.machineID)
                if old[path] == fingerprint {
                    reused += 1
                    continue
                }
                let data = try encoder.encode(entry.acc)
                bytesWritten += data.count
                encoded.append((path, entry, data))
                if old[path] == nil { inserted += 1 } else { updated += 1 }
            }

            try connection.transaction {
                if !removed.isEmpty {
                    let delete = try connection.prepare(
                        "DELETE FROM session_entries WHERE path = ?")
                    for path in removed {
                        delete.reset()
                        try delete.bind(path, at: 1)
                        try delete.run()
                    }
                }
                let upsert = try connection.prepare("""
                    INSERT INTO session_entries(
                        path, file_size, modified_at, provider, machine_id, accumulator
                    ) VALUES(?, ?, ?, ?, ?, ?)
                    ON CONFLICT(path) DO UPDATE SET
                        file_size=excluded.file_size,
                        modified_at=excluded.modified_at,
                        provider=excluded.provider,
                        machine_id=excluded.machine_id,
                        accumulator=excluded.accumulator
                    """)
                for (path, entry, data) in encoded {
                    upsert.reset()
                    try upsert.bind(path, at: 1)
                    try upsert.bind(Int64(bitPattern: entry.size), at: 2)
                    try upsert.bind(entry.mtime.timeIntervalSince1970, at: 3)
                    try upsert.bind(entry.provider.rawValue, at: 4)
                    try upsert.bind(entry.machineID, at: 5)
                    try upsert.bind(data, at: 6)
                    try upsert.run()
                }
                let metadata = try connection.prepare("""
                    INSERT INTO cache_metadata(id, payload_version, time_zone)
                    VALUES(1, ?, ?)
                    ON CONFLICT(id) DO UPDATE SET
                        payload_version=excluded.payload_version,
                        time_zone=excluded.time_zone
                    """)
                try metadata.bind(Int64(payloadVersion), at: 1)
                try metadata.bind(timeZone.identifier, at: 2)
                try metadata.run()
            }
            return SessionIndexPersistenceReport(
                inserted: inserted, updated: updated, reused: reused,
                deleted: removed.count, payloadBytesWritten: bytesWritten)
        } catch {
            return nil
        }
    }

    private static func prepareDatabase(at url: URL) throws {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let connection = try SQLiteConnection(url: url, readOnly: false)
        let version = try connection.scalarInt("PRAGMA user_version")
        guard version == 0 || version == schemaVersion else {
            throw SQLiteFailure.message(
                "session-index schema version \(version) is not \(schemaVersion)")
        }
        try connection.execute("PRAGMA journal_mode=WAL")
        try connection.execute("PRAGMA synchronous=NORMAL")
        try connection.execute("PRAGMA wal_autocheckpoint=256")
        try connection.execute("""
            CREATE TABLE IF NOT EXISTS cache_metadata(
                id INTEGER PRIMARY KEY CHECK(id = 1),
                payload_version INTEGER NOT NULL,
                time_zone TEXT NOT NULL
            )
            """)
        try connection.execute("""
            CREATE TABLE IF NOT EXISTS session_entries(
                path TEXT PRIMARY KEY,
                file_size INTEGER NOT NULL,
                modified_at REAL NOT NULL,
                provider TEXT NOT NULL,
                machine_id TEXT NOT NULL,
                accumulator BLOB NOT NULL
            )
            """)
        if version == 0 {
            try connection.execute("PRAGMA user_version=\(schemaVersion)")
        }
    }

    private static func fingerprints(
        _ connection: SQLiteConnection
    ) throws -> [String: Fingerprint] {
        let rows = try connection.prepare("""
            SELECT path, file_size, modified_at, provider, machine_id
            FROM session_entries
            """)
        var output: [String: Fingerprint] = [:]
        while rows.step() == SQLITE_ROW {
            output[rows.text(0)] = Fingerprint(
                size: UInt64(bitPattern: rows.int64(1)),
                mtime: rows.double(2), provider: rows.text(3),
                machineID: rows.text(4))
        }
        return output
    }
}
