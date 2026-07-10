import Foundation

// MARK: - Approved Codex read surface

public enum CodexConfigLocationSource: Sendable, Equatable {
    case defaultDirectory
    case environmentOverride
}

/// Process-wide resolution of the Codex read adapter's explicitly approved
/// local state. Callers consume the concrete child URLs below; no scanner is
/// ever pointed at the configuration root itself.
public struct CodexPaths: Sendable, Equatable {
    public let root: URL
    public let source: CodexConfigLocationSource

    public var sessions: URL {
        root.appendingPathComponent("sessions", isDirectory: true)
    }

    public var sessionIndexJSONL: URL {
        root.appendingPathComponent("session_index.jsonl")
    }

    public var externalAgentImportsJSON: URL {
        root.appendingPathComponent("external_agent_session_imports.json")
    }

    public init(root: URL, source: CodexConfigLocationSource) {
        self.root = root.standardizedFileURL
        self.source = source
    }

    public static let process = resolve()

    public static func resolve(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> CodexPaths {
        let raw = environment["CODEX_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else {
            return CodexPaths(
                root: home.appendingPathComponent(".codex", isDirectory: true),
                source: .defaultDirectory)
        }
        let expanded = (raw as NSString).expandingTildeInPath
        return CodexPaths(root: URL(fileURLWithPath: expanded, isDirectory: true),
                          source: .environmentOverride)
    }
}

// MARK: - Import manifest dedup

/// One scan's immutable view of Codex's external-session import manifest.
/// `importedThreadIDs` is the direct rollout join; hashes and source paths are
/// retained as the content-level evidence supplied by the manifest.
struct CodexImportManifest: Sendable, Equatable {
    var importedThreadIDs: Set<String> = []
    var contentHashes: Set<String> = []
    var sourcePaths: Set<String> = []

    static func load(from url: URL?) -> CodexImportManifest {
        guard let url,
              let values = try? url.resourceValues(
                forKeys: [.isRegularFileKey, .isSymbolicLinkKey]),
              values.isRegularFile == true,
              values.isSymbolicLink != true,
              let data = try? Data(contentsOf: url),
              let root = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let records = root["records"] as? [[String: Any]] else {
            return CodexImportManifest()
        }
        var manifest = CodexImportManifest()
        for record in records {
            if let value = clean(record["imported_thread_id"] as? String) {
                manifest.importedThreadIDs.insert(value)
            }
            if let value = clean(record["content_sha256"] as? String) {
                manifest.contentHashes.insert(value.lowercased())
            }
            if let value = clean(record["source_path"] as? String) {
                manifest.sourcePaths.insert(value)
            }
        }
        return manifest
    }

    func excludes(sessionID: String, markedImported: Bool,
                  contentHash: String?, sourcePath: String?) -> Bool {
        if markedImported || importedThreadIDs.contains(sessionID) { return true }
        if let contentHash,
           contentHashes.contains(contentHash.lowercased()) { return true }
        if let sourcePath, sourcePaths.contains(sourcePath) { return true }
        return false
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}

// MARK: - Rollout value types

public enum CodexHistoryMode: String, Sendable, Codable {
    case legacy
    case paginated
    case unknown

    init(_ raw: String?) {
        self = raw.flatMap { CodexHistoryMode(rawValue: $0.lowercased()) } ?? .unknown
    }
}

/// Codex's native token shape. `inputTokens` includes `cachedInputTokens`.
public struct CodexTokenUsage: Sendable, Hashable, Codable {
    public let inputTokens: Int
    public let cachedInputTokens: Int
    public let outputTokens: Int
    public let reasoningOutputTokens: Int

    public init(inputTokens: Int, cachedInputTokens: Int,
                outputTokens: Int, reasoningOutputTokens: Int = 0) {
        self.inputTokens = inputTokens
        self.cachedInputTokens = cachedInputTokens
        self.outputTokens = outputTokens
        self.reasoningOutputTokens = reasoningOutputTokens
    }

    init?(_ object: [String: Any]?) {
        guard let object,
              let input = Self.int(object["input_tokens"]),
              let cached = Self.int(object["cached_input_tokens"]),
              let output = Self.int(object["output_tokens"]) else { return nil }
        self.init(inputTokens: input, cachedInputTokens: cached,
                  outputTokens: output,
                  reasoningOutputTokens: Self.int(object["reasoning_output_tokens"]) ?? 0)
    }

    /// Lossless conversion from Codex's inclusive cache representation into
    /// Trifola's additive representation. Reasoning output is already included
    /// in output and is deliberately not added a second time.
    public var sessionUsage: SessionUsage {
        SessionUsage(
            inputTokens: inputTokens - cachedInputTokens,
            outputTokens: outputTokens,
            cacheCreateTokens: 0,
            cacheReadTokens: cachedInputTokens,
            cacheCreate1hTokens: 0)
    }

    private static func int(_ value: Any?) -> Int? {
        if let number = value as? NSNumber { return number.intValue }
        if let string = value as? String { return Int(string) }
        return nil
    }
}

struct CodexRateLimitWindow: Sendable, Hashable, Codable {
    let usedPercent: Double
    let windowMinutes: Int?
    let resetsAt: Date?

    init?(_ object: [String: Any]?) {
        guard let object,
              let used = (object["used_percent"] as? NSNumber)?.doubleValue,
              used.isFinite else { return nil }
        usedPercent = used
        windowMinutes = (object["window_minutes"] as? NSNumber)?.intValue
        if let seconds = (object["resets_at"] as? NSNumber)?.doubleValue {
            resetsAt = Date(timeIntervalSince1970: seconds)
        } else {
            resetsAt = parseDate(object["resets_at"] as? String)
        }
    }
}

struct CodexRateLimits: Sendable, Hashable, Codable {
    let primary: CodexRateLimitWindow?
    let secondary: CodexRateLimitWindow?

    init?(_ object: [String: Any]?) {
        guard let object else { return nil }
        let primary = CodexRateLimitWindow(object["primary"] as? [String: Any])
        let secondary = CodexRateLimitWindow(object["secondary"] as? [String: Any])
        guard primary != nil || secondary != nil else { return nil }
        self.primary = primary
        self.secondary = secondary
    }

    func snapshot(now: Date) -> QuotaSnapshot {
        let fiveHour = primary.map {
            QuotaWindow(title: Self.title(for: $0, fallback: "Session (5h)"),
                        usedPercent: $0.usedPercent, resetsAt: $0.resetsAt)
        }
        let weekly = secondary.map {
            QuotaWindow(title: Self.title(for: $0, fallback: "Weekly (all models)"),
                        usedPercent: $0.usedPercent, resetsAt: $0.resetsAt)
        }
        return QuotaSnapshot(fiveHour: fiveHour, weekly: weekly,
                             scoped: [], fetchedAt: now)
    }

    private static func title(for window: CodexRateLimitWindow,
                              fallback: String) -> String {
        guard let minutes = window.windowMinutes else { return fallback }
        switch minutes {
        case 300: return "Session (5h)"
        case 10_080: return "Weekly (all models)"
        default:
            if minutes.isMultiple(of: 1_440) {
                return String(minutes / 1_440) + "d window"
            }
            if minutes.isMultiple(of: 60) {
                return String(minutes / 60) + "h window"
            }
            return String(minutes) + "m window"
        }
    }
}

// MARK: - Rollout accumulator

/// Tolerant tagged-union parser for Codex rollout JSONL. Unknown outer and
/// payload discriminators are ignored; malformed lines never abort the file.
public struct CodexRolloutAccumulator: Sendable, Codable {
    struct KeyedUsage: Sendable, Codable {
        let usage: SessionUsage
        let model: String
        let day: String
    }

    public private(set) var historyMode: CodexHistoryMode = .unknown
    var sid: String
    var cwd = ""
    var model: String?
    var last: Date?
    var count = 0
    var usageByKey: [String: KeyedUsage] = [:]
    var unkeyedSequence = 0
    var rawUsageBlocks = 0
    var contextWeight = 0
    var tiersSeen: Set<ModelTier> = []
    var assistantTurnsByModel: [String: Int] = [:]
    var latestTotalUsage: CodexTokenUsage?
    var latestRateLimits: CodexRateLimits?
    var latestRateLimitsAt: Date?
    var sawSessionMeta = false
    var markedImported = false
    var importedContentHash: String?
    var importedSourcePath: String?
    var bytesIngested: UInt64 = 0
    var pending = Data()

    public init(defaultID: String) {
        sid = defaultID
    }

    public mutating func ingest(_ data: Data) {
        bytesIngested += UInt64(data.count)
        var buffer = pending
        buffer.append(data)
        var start = buffer.startIndex
        while let newline = buffer[start...].firstIndex(of: 0x0A) {
            if newline > start {
                consume(line: buffer.subdata(in: start..<newline))
            }
            start = buffer.index(after: newline)
        }
        pending = start < buffer.endIndex ? Data(buffer[start...]) : Data()
    }

    public func summary(filePath: String,
                        machineID: String = Machine.localID) -> SessionSummary {
        var snapshot = self
        if !snapshot.pending.isEmpty { snapshot.consume(line: snapshot.pending) }
        let project = snapshot.cwd.isEmpty
            ? "—" : (snapshot.cwd as NSString).lastPathComponent
        return SessionSummary(
            id: snapshot.sid,
            provider: .codex,
            project: project,
            cwd: snapshot.cwd,
            model: snapshot.model,
            lastActivity: snapshot.last,
            messageCount: snapshot.count,
            usage: snapshot.usage,
            contextWeight: snapshot.contextWeight,
            filePath: filePath,
            handle: SessionHandles.untitled,
            usageByTier: snapshot.usageByTier,
            usageByDay: snapshot.usageByDay,
            usageByModel: snapshot.usageByModel,
            usageByModelDay: snapshot.usageByModelDay,
            messagesByModelDay: snapshot.messagesByModelDay,
            rawUsageBlocks: snapshot.rawUsageBlocks,
            tiersSeen: snapshot.tiersSeen,
            assistantTurnsByModel: snapshot.assistantTurnsByModel,
            machineID: machineID)
            .computingCostBundle()
    }

    /// True when summed per-call deltas match the latest cumulative counters.
    /// Missing cumulative data is treated as not enough evidence, not failure.
    public var usageReconcilesWithLatestTotal: Bool? {
        guard let latestTotalUsage else { return nil }
        return usage == latestTotalUsage.sessionUsage
    }

    var resumeOffset: UInt64 { bytesIngested - UInt64(pending.count) }

    var usage: SessionUsage {
        usageByKey.values.reduce(SessionUsage()) { $0 + $1.usage }
    }

    var usageByTier: [ModelTier: SessionUsage] {
        var result: [ModelTier: SessionUsage] = [:]
        for value in usageByKey.values {
            let tier = ModelTier(raw: value.model)
            result[tier] = (result[tier] ?? SessionUsage()) + value.usage
        }
        return result
    }

    var usageByDay: [String: [ModelTier: SessionUsage]] {
        var result: [String: [ModelTier: SessionUsage]] = [:]
        for value in usageByKey.values where !value.day.isEmpty {
            let tier = ModelTier(raw: value.model)
            result[value.day, default: [:]][tier] =
                (result[value.day]?[tier] ?? SessionUsage()) + value.usage
        }
        return result
    }

    var usageByModel: [String: SessionUsage] {
        var result: [String: SessionUsage] = [:]
        for value in usageByKey.values {
            result[value.model] = (result[value.model] ?? SessionUsage()) + value.usage
        }
        return result
    }

    var usageByModelDay: [String: [String: SessionUsage]] {
        var result: [String: [String: SessionUsage]] = [:]
        for value in usageByKey.values {
            result[value.day, default: [:]][value.model] =
                (result[value.day]?[value.model] ?? SessionUsage()) + value.usage
        }
        return result
    }

    var messagesByModelDay: [String: [String: Int]] {
        var result: [String: [String: Int]] = [:]
        for value in usageByKey.values {
            result[value.day, default: [:]][value.model, default: 0] += 1
        }
        return result
    }

    private mutating func consume(line data: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let outerType = object["type"] as? String else { return }
        count += 1
        let timestamp = parseDate(object["timestamp"] as? String)
        observe(timestamp)
        let payload = object["payload"] as? [String: Any] ?? [:]

        switch outerType {
        case "session_meta":
            consumeSessionMeta(payload)
        case "turn_context":
            consumeTurnContext(payload)
        case "event_msg":
            switch historyMode {
            case .paginated:
                consumePaginatedEvent(payload, timestamp: timestamp)
            case .legacy, .unknown:
                consumeLegacyEvent(payload, timestamp: timestamp)
            }
        case "response_item":
            // Paginated history persists completed turn items. Usage remains a
            // discriminated token_count payload when present; other items carry
            // transcript content and need no P1 cost handling.
            if historyMode == .paginated,
               payload["type"] as? String == "item_completed",
               let item = payload["item"] as? [String: Any] {
                consumePaginatedItem(item, timestamp: timestamp)
            }
        default:
            break
        }
    }

    private mutating func consumeSessionMeta(_ payload: [String: Any]) {
        // A subagent rollout starts with its own metadata, then may replay the
        // parent's session_meta as copied history. Codex defines this field as
        // set-once: the first record identifies this rollout and later copies
        // must never overwrite its id/cwd/history mode.
        guard !sawSessionMeta else { return }
        sawSessionMeta = true
        if let id = clean(payload["id"] as? String)
            ?? clean(payload["session_id"] as? String) {
            sid = id
        }
        if let value = clean(payload["cwd"] as? String) { cwd = value }
        historyMode = CodexHistoryMode(payload["history_mode"] as? String)
        markedImported = markedImported
            || Self.marksImport(payload["thread_source"])
            || Self.marksImport(payload["source"])
        importedContentHash = clean(payload["content_sha256"] as? String)?
            .lowercased()
        importedSourcePath = clean(payload["source_path"] as? String)
        observe(parseDate(payload["timestamp"] as? String))
    }

    private mutating func consumeTurnContext(_ payload: [String: Any]) {
        if let value = clean(payload["cwd"] as? String), cwd.isEmpty { cwd = value }
        guard let value = clean(payload["model"] as? String) else { return }
        model = value
        tiersSeen.insert(ModelTier(raw: value))
    }

    private mutating func consumeLegacyEvent(_ payload: [String: Any],
                                             timestamp: Date?) {
        guard payload["type"] as? String == "token_count" else { return }
        consumeTokenCount(payload, timestamp: timestamp)
    }

    private mutating func consumePaginatedEvent(_ payload: [String: Any],
                                                timestamp: Date?) {
        switch payload["type"] as? String {
        case "token_count":
            consumeTokenCount(payload, timestamp: timestamp)
        case "item_completed":
            if let item = payload["item"] as? [String: Any] {
                consumePaginatedItem(item, timestamp: timestamp)
            }
        default:
            break
        }
    }

    private mutating func consumePaginatedItem(_ item: [String: Any],
                                               timestamp: Date?) {
        guard item["type"] as? String == "token_count" else { return }
        consumeTokenCount(item, timestamp: timestamp)
    }

    private mutating func consumeTokenCount(_ payload: [String: Any],
                                            timestamp: Date?) {
        if let limits = CodexRateLimits(payload["rate_limits"] as? [String: Any]) {
            latestRateLimits = limits
            latestRateLimitsAt = timestamp ?? last
        }
        guard let info = payload["info"] as? [String: Any] else { return }
        let total = CodexTokenUsage(info["total_token_usage"] as? [String: Any])
        let delta = CodexTokenUsage(info["last_token_usage"] as? [String: Any])
            ?? total.flatMap { current in
                latestTotalUsage.map { Self.delta(current, minus: $0) }
            }
        if let total { latestTotalUsage = total }
        guard let delta else { return }
        rawUsageBlocks += 1
        contextWeight = delta.inputTokens
        let normalizedModel = PricingCatalog.normalize(model)
        let billingModel = normalizedModel.isEmpty ? "<synthetic>" : normalizedModel
        let day = timestamp.map(localDayKey) ?? ""
        let key: String
        if let total {
            key = "\(total.inputTokens):\(total.cachedInputTokens):\(total.outputTokens)"
        } else {
            unkeyedSequence += 1
            key = "#\(unkeyedSequence)"
        }
        let isNew = usageByKey[key] == nil
        usageByKey[key] = KeyedUsage(usage: delta.sessionUsage,
                                     model: billingModel, day: day)
        if isNew {
            assistantTurnsByModel[billingModel, default: 0] += 1
        }
    }

    private mutating func observe(_ timestamp: Date?) {
        guard let timestamp else { return }
        if last == nil || timestamp > last! { last = timestamp }
    }

    private static func delta(_ current: CodexTokenUsage,
                              minus prior: CodexTokenUsage) -> CodexTokenUsage {
        CodexTokenUsage(
            inputTokens: current.inputTokens - prior.inputTokens,
            cachedInputTokens: current.cachedInputTokens - prior.cachedInputTokens,
            outputTokens: current.outputTokens - prior.outputTokens,
            reasoningOutputTokens: current.reasoningOutputTokens - prior.reasoningOutputTokens)
    }

    private static func marksImport(_ value: Any?) -> Bool {
        if let string = value as? String {
            return string.lowercased().contains("import")
        }
        if let object = value as? [String: Any] {
            return object.values.contains(where: marksImport)
        }
        if let values = value as? [Any] {
            return values.contains(where: marksImport)
        }
        return false
    }

    private func clean(_ value: String?) -> String? {
        Self.clean(value)
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}

// MARK: - Rollout file reads

enum CodexRolloutFile {
    static func data(at url: URL) -> Data? {
        guard url.path.hasSuffix(".jsonl.zst") else {
            return try? Data(contentsOf: url)
        }
        guard let executable = zstdExecutable() else { return nil }
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = ["--decompress", "--stdout", "--quiet", url.path]
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        do {
            try process.run()
            let data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            return process.terminationStatus == 0 ? data : nil
        } catch {
            return nil
        }
    }

    private static func zstdExecutable() -> URL? {
        let candidates = [
            "/opt/homebrew/bin/zstd",
            "/usr/local/bin/zstd",
            "/usr/bin/zstd",
        ]
        for path in candidates where FileManager.default.isExecutableFile(atPath: path) {
            return URL(fileURLWithPath: path)
        }
        return nil
    }
}
