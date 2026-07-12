import Foundation
import Darwin

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
        // Rollouts are an upstream, version-unstable input. Negative counters
        // cannot represent billable usage and must never flow into dollar math.
        self.inputTokens = max(0, inputTokens)
        self.cachedInputTokens = max(0, cachedInputTokens)
        self.outputTokens = max(0, outputTokens)
        self.reasoningOutputTokens = max(0, reasoningOutputTokens)
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
        // Spell the clamp as a comparison rather than max(0, input - cached):
        // malformed extreme integers must not trap before max gets to run.
        let freshInput = inputTokens >= cachedInputTokens
            ? inputTokens - cachedInputTokens
            : 0
        return SessionUsage(
            inputTokens: freshInput,
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
    let credits: QuotaCredits?

    init?(_ object: [String: Any]?) {
        guard let object else { return nil }
        let primary = CodexRateLimitWindow(object["primary"] as? [String: Any])
        let secondary = CodexRateLimitWindow(object["secondary"] as? [String: Any])
        let credits: QuotaCredits? = {
            guard let value = object["credits"] as? [String: Any] else { return nil }
            let hasCredits = (value["has_credits"] as? NSNumber)?.boolValue ?? false
            let unlimited = (value["unlimited"] as? NSNumber)?.boolValue ?? false
            let balance: String?
            if let raw = value["balance"] as? String {
                balance = raw
            } else if let raw = value["balance"] as? NSNumber {
                balance = raw.stringValue
            } else {
                balance = nil
            }
            return QuotaCredits(hasCredits: hasCredits,
                                unlimited: unlimited,
                                balance: balance)
        }()
        guard primary != nil || secondary != nil || credits != nil else { return nil }
        self.primary = primary
        self.secondary = secondary
        self.credits = credits
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
                             scoped: [], credits: credits, fetchedAt: now)
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

enum CodexAttentionRecordKind: String, Sendable, Codable {
    case activity
    case taskComplete
}

/// Tolerant tagged-union parser for Codex rollout JSONL. Unknown outer and
/// payload discriminators are ignored; malformed lines never abort the file.
public struct CodexRolloutAccumulator: Sendable, Codable {
    struct KeyedUsage: Sendable, Codable {
        let usage: SessionUsage
        let model: String
        let day: String
    }

    /// Billing id for usage observed before the file names a model. The gpt-
    /// prefix maps it into the Codex tier; `reattributeUnattributedUsage`
    /// replaces it with the real model on first observation.
    static let unattributedModel = "gpt-unattributed"

    public private(set) var historyMode: CodexHistoryMode = .unknown
    var sid: String
    var cwd = ""
    var model: String?
    var last: Date?
    var count = 0
    /// Genuine human prompts only. The first drives the title fallback; the
    /// latest supplies the same calm context line Claude summaries expose.
    var firstUserMessage: String?
    var lastUserMessage: String?
    var usageByKey: [String: KeyedUsage] = [:]
    var unkeyedSequence = 0
    var rawUsageBlocks = 0
    var contextWeight = 0
    var tiersSeen: Set<ModelTier> = []
    var assistantTurnsByModel: [String: Int] = [:]
    var latestTotalUsage: CodexTokenUsage?
    var counterEpoch = 0
    var sawCounterReset = false
    var latestRateLimits: CodexRateLimits?
    var latestRateLimitsAt: Date?
    var attentionRecordKind: CodexAttentionRecordKind?
    var attentionEventAt: Date?
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
            lastUserMessage: snapshot.lastUserMessage,
            handle: SessionHandles.derive(
                autoName: nil, summary: nil,
                firstUserMessage: snapshot.firstUserMessage,
                cwd: snapshot.cwd),
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

    /// Provider-honest facts derived from the rollout tail. Codex approval and
    /// request-user-input states are transient and never persisted, so these
    /// signals explicitly cannot support BLOCKED classification.
    public var attentionSignals: AttentionSignals {
        let kind: AttentionSignals.LastKind = switch attentionRecordKind {
        case .activity: .runtimeActivity
        case .taskComplete: .turnComplete
        case nil: .none
        }
        return AttentionSignals(
            lastEventAt: attentionEventAt ?? last,
            lastKind: kind,
            canObserveBlocking: false)
    }

    static func attentionSignals(fromTailLines lines: [Data]) -> AttentionSignals {
        var accumulator = CodexRolloutAccumulator(defaultID: "attention-tail")
        for line in lines { accumulator.consume(line: line) }
        return accumulator.attentionSignals
    }

    /// True when summed per-call deltas match the latest cumulative counters.
    /// Missing cumulative data is treated as not enough evidence, not failure.
    public var usageReconcilesWithLatestTotal: Bool? {
        // A post-reset total is scoped only to the new counter epoch and is no
        // longer a whole-session checksum.
        guard !sawCounterReset, let latestTotalUsage else { return nil }
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
        observeAttention(outerType: outerType, payload: payload,
                         timestamp: timestamp)

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
        let firstObservation = model == nil
        model = value
        tiersSeen.insert(ModelTier(raw: value))
        if firstObservation { reattributeUnattributedUsage(to: value) }
    }

    /// Resumed rollouts emit token_count records BEFORE the file's first
    /// turn_context (measured: 3,441 of 42,688 records on a real corpus —
    /// ~624M input / ~604M cached tokens), so the rolling model starts nil and
    /// that usage was billed under the placeholder id, landing in the "Other"
    /// tier instead of Codex. The first observed model in a thread is the
    /// honest owner of its preceding turns (Codex model changes are rare and
    /// per-turn): re-key the placeholder usage exactly once, when the rolling
    /// model transitions nil → value. Files that never name a model keep the
    /// placeholder, which itself resolves to the Codex tier by prefix.
    private mutating func reattributeUnattributedUsage(to rawModel: String) {
        let normalized = PricingCatalog.normalize(rawModel)
        guard !normalized.isEmpty, normalized != Self.unattributedModel else { return }
        for (key, value) in usageByKey where value.model == Self.unattributedModel {
            usageByKey[key] = KeyedUsage(usage: value.usage, model: normalized,
                                         day: value.day)
        }
        if let orphanTurns = assistantTurnsByModel.removeValue(
            forKey: Self.unattributedModel) {
            assistantTurnsByModel[normalized, default: 0] += orphanTurns
        }
    }

    private mutating func consumeLegacyEvent(_ payload: [String: Any],
                                             timestamp: Date?) {
        switch payload["type"] as? String {
        case "user_message":
            consumeUserMessage(payload["message"] as? String)
        case "token_count":
            consumeTokenCount(payload, timestamp: timestamp)
        default:
            break
        }
    }

    private mutating func consumePaginatedEvent(_ payload: [String: Any],
                                                timestamp: Date?) {
        switch payload["type"] as? String {
        case "user_message":
            consumeUserMessage(payload["message"] as? String)
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

    private mutating func consumeUserMessage(_ raw: String?) {
        guard let message = CodexRolloutText.clean(raw),
              // Slash-only transport commands are not human task intent. Keep
              // scanning until the first prompt that can produce a real handle.
              SessionHandles.fromFirstUserMessage(message) != nil else { return }
        if firstUserMessage == nil { firstUserMessage = message }
        lastUserMessage = message
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
        let priorTotal = latestTotalUsage
        let reset = total.flatMap { current in
            priorTotal.map { Self.counterReset(current, after: $0) }
        } ?? false
        if reset {
            counterEpoch += 1
            sawCounterReset = true
        }
        let delta = CodexTokenUsage(info["last_token_usage"] as? [String: Any])
            ?? total.map { current in
                guard let priorTotal else { return current }
                return reset ? current : Self.delta(current, minus: priorTotal)
            }
        if let total { latestTotalUsage = total }
        guard let delta else { return }
        guard delta.inputTokens != 0
                || delta.cachedInputTokens != 0
                || delta.outputTokens != 0 else {
            // Repeated cumulative snapshots are heartbeats, not new usage. In
            // particular, never overwrite the prior non-zero slice at this key.
            return
        }
        rawUsageBlocks += 1
        contextWeight = delta.inputTokens
        let normalizedModel = PricingCatalog.normalize(model)
        // The gpt- prefix keeps unattributed Codex usage in the Codex tier
        // (priced at the tier's representative rate) instead of vanishing into
        // "Other"; reattributeUnattributedUsage re-keys it to the real model
        // the moment the file names one.
        let billingModel = normalizedModel.isEmpty ? Self.unattributedModel : normalizedModel
        let day = timestamp.map(localDayKey) ?? ""
        let key: String
        if let total {
            // Totals can revisit an earlier tuple after a reset. Namespacing by
            // epoch prevents the fresh baseline from overwriting pre-reset usage.
            key = "\(counterEpoch):\(total.inputTokens):\(total.cachedInputTokens):\(total.outputTokens)"
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

    private mutating func observeAttention(
        outerType: String,
        payload: [String: Any],
        timestamp: Date?
    ) {
        let payloadType = (payload["type"] as? String)?.lowercased()
        let nestedItem = payload["item"] as? [String: Any]
        let nestedType = (nestedItem?["type"] as? String)?.lowercased()

        let kind: CodexAttentionRecordKind?
        if outerType == "task_complete"
            || payloadType == "task_complete"
            || nestedType == "task_complete" {
            kind = .taskComplete
        } else if outerType == "response_item"
                    || outerType == "function_call"
                    || payloadType == "token_count"
                    || payloadType == "function_call"
                    || nestedType == "token_count"
                    || nestedType == "function_call" {
            kind = .activity
        } else {
            kind = nil
        }

        guard let kind else { return }
        attentionRecordKind = kind
        attentionEventAt = timestamp ?? last
    }

    private static func counterReset(_ current: CodexTokenUsage,
                                     after prior: CodexTokenUsage) -> Bool {
        current.inputTokens < prior.inputTokens
            || current.cachedInputTokens < prior.cachedInputTokens
            || current.outputTokens < prior.outputTokens
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

// MARK: - Rollout transcript projection

/// Shared lenient text helpers for the summary accumulator and the visible
/// rollout transcript. Upstream Codex payloads are versioned tagged unions, so
/// every helper accepts multiple compatible shapes and declines malformed data.
private enum CodexRolloutText {
    static func clean(_ raw: String?, limit: Int = 4_000) -> String? {
        guard let raw else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        return TranscriptParser.clip(value, limit)
    }

    static func content(_ value: Any?, limit: Int = 4_000) -> String? {
        if let string = value as? String { return clean(string, limit: limit) }
        if let object = value as? [String: Any] {
            for key in ["text", "message", "output", "content"] {
                if let text = content(object[key], limit: limit) { return text }
            }
            return json(object, limit: limit)
        }
        if let values = value as? [Any] {
            let joined = values.compactMap { content($0, limit: limit) }
                .joined(separator: "\n")
            return clean(joined, limit: limit)
        }
        return nil
    }

    static func toolDetail(_ value: Any?) -> String {
        let object: [String: Any]? = {
            if let object = value as? [String: Any] { return object }
            guard let string = value as? String,
                  let data = string.data(using: .utf8) else { return nil }
            return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        }()
        if let object {
            for key in ["cmd", "command", "query", "path", "file_path",
                        "prompt", "url", "skill"] {
                if let detail = content(object[key], limit: 400) { return detail }
            }
            return json(object, limit: 400) ?? ""
        }
        return content(value, limit: 400) ?? ""
    }

    static func output(_ value: Any?) -> String {
        content(value, limit: TranscriptParser.maxResultLength) ?? ""
    }

    static func isError(_ object: [String: Any]) -> Bool {
        if let success = (object["success"] as? NSNumber)?.boolValue, !success {
            return true
        }
        let status = (object["status"] as? String)?.lowercased() ?? ""
        return ["error", "failed", "failure", "aborted"].contains(status)
            || object["error"] != nil
    }

    private static func json(_ object: Any, limit: Int) -> String? {
        guard JSONSerialization.isValidJSONObject(object),
              let data = try? JSONSerialization.data(
                withJSONObject: object, options: [.sortedKeys]),
              let string = String(data: data, encoding: .utf8) else { return nil }
        return clean(string, limit: limit)
    }
}

/// Provider-aware projection of Codex rollout JSONL into Trifola's existing
/// transcript event model. It renders the useful record types honestly and
/// ignores unknown/malformed records without aborting the rest of the file.
public enum CodexRolloutTranscriptParser {
    public static let defaultMaximumEvents = 2_500

    public static func events(fromLine data: Data,
                              fallbackID: String) -> [TranscriptEvent] {
        guard let object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let outerType = object["type"] as? String else { return [] }
        let payload = object["payload"] as? [String: Any] ?? [:]
        let timestamp = parseDate(object["timestamp"] as? String)
        let identifier = stringID(payload["id"])
            ?? stringID(payload["call_id"])
            ?? stringID(payload["turn_id"])
            ?? fallbackID

        switch outerType {
        case "session_meta":
            return sessionMeta(payload, id: identifier, timestamp: timestamp)
        case "turn_context":
            return turnContext(payload, id: identifier, timestamp: timestamp)
        case "event_msg", "response_item":
            if let item = payload["item"] as? [String: Any],
               payload["type"] as? String == "item_completed" {
                return itemEvents(item, id: identifier, timestamp: timestamp)
            }
            return itemEvents(payload, id: identifier, timestamp: timestamp)
        case "function_call", "custom_tool_call", "function_call_output",
             "custom_tool_call_output":
            return itemEvents(payload.isEmpty ? object : payload,
                              id: identifier, timestamp: timestamp)
        default:
            return []
        }
    }

    /// Parse an already-decoded rollout, retaining only the newest bounded event
    /// window just like the live TranscriptStore. One bad line never poisons the
    /// valid records on either side of it.
    public static func events(from data: Data,
                              maximumEvents: Int = defaultMaximumEvents) -> [TranscriptEvent] {
        let limit = max(0, maximumEvents)
        guard limit > 0 else { return [] }
        var result: [TranscriptEvent] = []
        var start = data.startIndex
        var lineNumber = 0
        func append(_ line: Data) {
            result.append(contentsOf: events(
                fromLine: line, fallbackID: "codex-L\(lineNumber)"))
            lineNumber += 1
            if result.count > limit {
                result.removeFirst(result.count - limit)
            }
        }
        while start < data.endIndex,
              let newline = data[start...].firstIndex(of: 0x0A) {
            if newline > start { append(data.subdata(in: start..<newline)) }
            start = data.index(after: newline)
        }
        if start < data.endIndex { append(data.subdata(in: start..<data.endIndex)) }
        return result
    }

    /// Reads plain `.jsonl` and archived `.jsonl.zst` through the adapter's one
    /// bounded decompression seam; callers never need a second archive path.
    public static func events(at url: URL,
                              maximumEvents: Int = defaultMaximumEvents) -> [TranscriptEvent]? {
        CodexRolloutFile.data(at: url).map {
            events(from: $0, maximumEvents: maximumEvents)
        }
    }

    private static func sessionMeta(_ payload: [String: Any], id: String,
                                    timestamp: Date?) -> [TranscriptEvent] {
        var facts: [String] = []
        if let provider = CodexRolloutText.clean(payload["model_provider"] as? String,
                                                 limit: 80) {
            facts.append("provider \(provider)")
        }
        if let version = CodexRolloutText.clean(payload["cli_version"] as? String,
                                                limit: 80) {
            facts.append("CLI \(version)")
        }
        if let mode = CodexRolloutText.clean(payload["history_mode"] as? String,
                                             limit: 80) {
            facts.append("\(mode) history")
        }
        if let cwd = CodexRolloutText.clean(payload["cwd"] as? String, limit: 400) {
            facts.append(cwd)
        }
        let text = facts.isEmpty ? "Session metadata" : facts.joined(separator: " · ")
        return [TranscriptEvent(id: id + "-meta", timestamp: timestamp,
                                kind: .system(subtype: "Codex rollout", text: text))]
    }

    private static func turnContext(_ payload: [String: Any], id: String,
                                    timestamp: Date?) -> [TranscriptEvent] {
        var facts: [String] = []
        if let model = CodexRolloutText.clean(payload["model"] as? String, limit: 120) {
            facts.append(model)
        }
        if let effort = CodexRolloutText.clean(payload["effort"] as? String, limit: 80) {
            facts.append("effort \(effort)")
        }
        guard !facts.isEmpty else { return [] }
        return [TranscriptEvent(id: id + "-context", timestamp: timestamp,
                                kind: .system(subtype: "Codex turn",
                                              text: facts.joined(separator: " · ")))]
    }

    private static func itemEvents(_ item: [String: Any], id: String,
                                   timestamp: Date?) -> [TranscriptEvent] {
        let type = (item["type"] as? String)?.lowercased() ?? ""
        switch type {
        case "user_message":
            guard let text = CodexRolloutText.clean(item["message"] as? String) else { return [] }
            return [TranscriptEvent(id: id + "-user", timestamp: timestamp,
                                    kind: .userPrompt(text))]
        case "agent_message":
            guard let text = CodexRolloutText.clean(item["message"] as? String) else { return [] }
            return [TranscriptEvent(id: id + "-agent", timestamp: timestamp,
                                    kind: .assistantText(text))]
        case "agent_reasoning":
            guard let text = CodexRolloutText.clean(item["text"] as? String,
                                                    limit: TranscriptParser.maxThinkingLength) else { return [] }
            return [TranscriptEvent(id: id + "-reasoning", timestamp: timestamp,
                                    kind: .thinking(text))]
        case "message":
            guard let text = CodexRolloutText.content(item["content"]) else { return [] }
            switch (item["role"] as? String)?.lowercased() {
            case "user":
                return [TranscriptEvent(id: id + "-message", timestamp: timestamp,
                                        kind: .userPrompt(text))]
            case "assistant":
                return [TranscriptEvent(id: id + "-message", timestamp: timestamp,
                                        kind: .assistantText(text))]
            default:
                return []
            }
        case "reasoning":
            guard let text = CodexRolloutText.content(
                item["summary"], limit: TranscriptParser.maxThinkingLength) else { return [] }
            return [TranscriptEvent(id: id + "-reasoning", timestamp: timestamp,
                                    kind: .thinking(text))]
        case "function_call", "custom_tool_call":
            let name = CodexRolloutText.clean(item["name"] as? String, limit: 120) ?? "tool"
            let input = item["arguments"] ?? item["input"]
            return [TranscriptEvent(id: id + "-call", timestamp: timestamp,
                                    kind: .toolUse(
                                        name: name,
                                        detail: CodexRolloutText.toolDetail(input)))]
        case "function_call_output", "custom_tool_call_output":
            return [TranscriptEvent(id: id + "-output", timestamp: timestamp,
                                    kind: .toolResult(
                                        preview: CodexRolloutText.output(item["output"]),
                                        isError: CodexRolloutText.isError(item)))]
        case "exec_command_begin":
            return [TranscriptEvent(id: id + "-exec", timestamp: timestamp,
                                    kind: .toolUse(
                                        name: "Command",
                                        detail: CodexRolloutText.toolDetail(
                                            item["command"] ?? item["cmd"])))]
        case "exec_command_end", "patch_apply_end", "mcp_tool_call_end":
            let output = item["output"] ?? item["result"]
                ?? item["stdout"] ?? item["stderr"] ?? item["changes"]
            return [TranscriptEvent(id: id + "-result", timestamp: timestamp,
                                    kind: .toolResult(
                                        preview: CodexRolloutText.output(output),
                                        isError: CodexRolloutText.isError(item)))]
        case "patch_apply_begin":
            return [TranscriptEvent(id: id + "-patch", timestamp: timestamp,
                                    kind: .toolUse(name: "Apply patch", detail: ""))]
        case "mcp_tool_call_begin":
            let name = CodexRolloutText.clean(item["action_name"] as? String,
                                              limit: 120) ?? "MCP tool"
            return [TranscriptEvent(id: id + "-mcp", timestamp: timestamp,
                                    kind: .toolUse(
                                        name: name,
                                        detail: CodexRolloutText.toolDetail(item["invocation"])))]
        case "web_search_begin", "web_search_end", "web_search_call":
            return [TranscriptEvent(id: id + "-search", timestamp: timestamp,
                                    kind: .toolUse(
                                        name: "Web search",
                                        detail: CodexRolloutText.toolDetail(
                                            item["query"] ?? item["action"])))]
        case "token_count":
            return tokenEvent(item, id: id, timestamp: timestamp)
        case "task_complete":
            var text = "Turn complete"
            if let duration = (item["duration_ms"] as? NSNumber)?.intValue {
                text += " · \(duration)ms"
            }
            return [TranscriptEvent(id: id + "-complete", timestamp: timestamp,
                                    kind: .system(subtype: "Codex turn", text: text))]
        case "turn_aborted":
            let reason = CodexRolloutText.clean(item["reason"] as? String,
                                                limit: 300) ?? "Turn aborted"
            return [TranscriptEvent(id: id + "-aborted", timestamp: timestamp,
                                    kind: .system(subtype: "Codex turn", text: reason))]
        case "context_compacted":
            return [TranscriptEvent(id: id + "-compact", timestamp: timestamp,
                                    kind: .summary("Codex context compacted"))]
        default:
            return []
        }
    }

    private static func tokenEvent(_ item: [String: Any], id: String,
                                   timestamp: Date?) -> [TranscriptEvent] {
        guard let info = item["info"] as? [String: Any] else { return [] }
        let last = CodexTokenUsage(info["last_token_usage"] as? [String: Any])
        let total = CodexTokenUsage(info["total_token_usage"] as? [String: Any])
        guard let usage = last ?? total else { return [] }
        var text = "\(usage.inputTokens) input"
        if usage.cachedInputTokens > 0 { text += " · \(usage.cachedInputTokens) cached" }
        text += " · \(usage.outputTokens) output"
        if usage.reasoningOutputTokens > 0 {
            text += " · \(usage.reasoningOutputTokens) reasoning"
        }
        if last == nil { text = "Cumulative · " + text }
        return [TranscriptEvent(id: id + "-tokens", timestamp: timestamp,
                                kind: .system(subtype: "Codex tokens", text: text))]
    }

    private static func stringID(_ value: Any?) -> String? {
        guard let value = value as? String else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}

// MARK: - Rollout file reads

enum CodexRolloutFile {
    static let decompressionTimeout: TimeInterval = 30
    static let maxDecompressedBytes = 512 * 1_024 * 1_024

    static func data(at url: URL) -> Data? {
        guard url.path.hasSuffix(".jsonl.zst") else {
            return try? Data(contentsOf: url)
        }
        guard let executable = zstdExecutable() else { return nil }
        return runBounded(
            executable: executable,
            arguments: ["--decompress", "--stdout", "--quiet", url.path],
            timeout: decompressionTimeout,
            maxOutputBytes: maxDecompressedBytes)
    }

    /// Drain a subprocess concurrently with a hard deadline and byte ceiling.
    /// Exceeding either bound SIGKILLs the writer so it cannot remain blocked on
    /// a full pipe. Internal for direct unit tests of the bounding seam.
    static func runBounded(
        executable: URL,
        arguments: [String],
        timeout: TimeInterval,
        maxOutputBytes: Int
    ) -> Data? {
        guard timeout > 0, maxOutputBytes >= 0,
              FileManager.default.isExecutableFile(atPath: executable.path) else {
            return nil
        }
        let process = Process()
        let output = Pipe()
        process.executableURL = executable
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice
        let processDone = DispatchSemaphore(value: 0)
        let readerDone = DispatchSemaphore(value: 0)
        let result = Locked<(data: Data, exceeded: Bool, failed: Bool)>(
            (Data(), false, false))
        process.terminationHandler = { _ in processDone.signal() }
        do {
            try process.run()
        } catch {
            return nil
        }

        DispatchQueue.global(qos: .utility).async {
            var data = Data()
            var exceeded = false
            var failed = false
            do {
                while true {
                    let remaining = maxOutputBytes - data.count
                    // Read one sentinel byte beyond the remaining capacity so an
                    // exact-cap result succeeds while cap+1 is rejected.
                    let request = remaining >= 64 * 1_024
                        ? 64 * 1_024
                        : remaining + 1
                    let chunk = try output.fileHandleForReading.read(
                        upToCount: max(1, request)) ?? Data()
                    if chunk.isEmpty { break }
                    if chunk.count > remaining {
                        exceeded = true
                        Self.kill(process)
                        break
                    }
                    data.append(chunk)
                }
            } catch {
                failed = true
            }
            result.withLock { $0 = (data, exceeded, failed) }
            readerDone.signal()
        }

        let deadline = DispatchTime.now() + timeout
        guard processDone.wait(timeout: deadline) != .timedOut else {
            kill(process)
            _ = processDone.wait(timeout: .now() + 0.25)
            return nil
        }
        guard readerDone.wait(timeout: deadline) != .timedOut else {
            kill(process)
            return nil
        }
        let captured = result.withLock { $0 }
        guard process.terminationStatus == 0,
              !captured.exceeded, !captured.failed else { return nil }
        return captured.data
    }

    private static func kill(_ process: Process) {
        guard process.isRunning else { return }
        Darwin.kill(process.processIdentifier, SIGKILL)
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
