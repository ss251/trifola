import Foundation

// MARK: - Approved Grok read surface

public enum GrokConfigLocationSource: Sendable, Equatable {
    case defaultDirectory
    case environmentOverride
}

/// Process-wide resolution of Grok Build's local, read-only session corpus.
/// The scanner is always rooted at the concrete `sessions` child.
public struct GrokPaths: Sendable, Equatable {
    public let root: URL
    public let source: GrokConfigLocationSource

    public var sessions: URL {
        root.appendingPathComponent("sessions", isDirectory: true)
    }

    public var activeSessionsJSON: URL {
        root.appendingPathComponent("active_sessions.json")
    }

    public init(root: URL, source: GrokConfigLocationSource) {
        self.root = root.standardizedFileURL
        self.source = source
    }

    public static let process = resolve()

    public static func resolve(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> GrokPaths {
        let raw = environment["GROK_HOME"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard let raw, !raw.isEmpty else {
            return GrokPaths(
                root: home.appendingPathComponent(".grok", isDirectory: true),
                source: .defaultDirectory)
        }
        return GrokPaths(
            root: URL(fileURLWithPath: (raw as NSString).expandingTildeInPath,
                      isDirectory: true),
            source: .environmentOverride)
    }
}

// MARK: - Grok lineage evidence

public struct GrokThreadMetadata: Sendable, Hashable, Codable {
    public let sessionID: String
    public let parentSessionID: String?
    public let sessionKind: String?
    public let forkedAt: Date?
    public let parentPromptID: String?
    public let contextSource: String?

    public init(sessionID: String, parentSessionID: String? = nil,
                sessionKind: String? = nil, forkedAt: Date? = nil,
                parentPromptID: String? = nil, contextSource: String? = nil) {
        self.sessionID = sessionID
        self.parentSessionID = parentSessionID
        self.sessionKind = sessionKind
        self.forkedAt = forkedAt
        self.parentPromptID = parentPromptID
        self.contextSource = contextSource
    }

    public var isResume: Bool {
        sessionKind?.lowercased().contains("resume") == true
    }
}

public struct GrokSpawnMetadata: Sendable, Hashable, Codable {
    public let childSessionID: String
    public let parentSessionID: String
    public let parentPromptID: String?
    public let subagentType: String?
    public let description: String?
    public let model: String?
    public let spawnedAt: Date?
}

// MARK: - Session accumulator

/// One Grok session is a directory-backed record. `summary.json` owns metadata,
/// `chat_history.jsonl` owns prose, and `updates.jsonl` owns turn usage. The two
/// JSONL streams retain independent offsets so a changed session can resume
/// without rereading a multi-megabyte ACP history.
public struct GrokSessionAccumulator: Sendable, Codable {
    struct KeyedUsage: Sendable, Codable {
        let usage: SessionUsage
        let model: String
        let day: String
        let calls: Int
    }

    var sid: String
    var cwd = ""
    var generatedTitle: String?
    var sessionSummaryText: String?
    var currentModelID: String?
    var startedAt: Date?
    var last: Date?
    var summaryMessageCount = 0
    var chatRecordCount = 0
    var firstUserMessage: String?
    var lastUserMessage: String?
    var assistantTurnsByModel: [String: Int] = [:]
    var transcriptModelsSeen: Set<String> = []
    var usageModelsSeen: Set<String> = []
    var usageByKey: [String: KeyedUsage] = [:]
    var rawUsageBlocks = 0
    var contextWeight = 0
    var usageIsPartial = false
    var parentSessionID: String?
    var sessionKind: String?
    var forkedAt: Date?
    var forkParentPromptID: String?
    var forkContextSource: String?
    var spawnedChildren: [GrokSpawnMetadata] = []
    var chatBytesIngested: UInt64 = 0
    var updatesBytesIngested: UInt64 = 0
    var chatPending = Data()
    var updatesPending = Data()
    var unkeyedUsageSequence = 0

    public init(defaultID: String) {
        sid = defaultID
    }

    public var threadMetadata: GrokThreadMetadata {
        GrokThreadMetadata(
            sessionID: sid, parentSessionID: parentSessionID,
            sessionKind: sessionKind, forkedAt: forkedAt,
            parentPromptID: forkParentPromptID,
            contextSource: forkContextSource)
    }

    var chatResumeOffset: UInt64 {
        chatBytesIngested - UInt64(chatPending.count)
    }

    var updatesResumeOffset: UInt64 {
        updatesBytesIngested - UInt64(updatesPending.count)
    }

    /// Compatibility arm for `SessionParserState`; Grok's index path uses the
    /// two explicit offsets above rather than pretending two files share one.
    var resumeOffset: UInt64 { max(chatResumeOffset, updatesResumeOffset) }

    public mutating func ingestSummary(_ data: Data, fallbackCWD: String? = nil) {
        guard let object = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any] else {
            if cwd.isEmpty, let fallbackCWD { cwd = fallbackCWD }
            return
        }
        let info = object["info"] as? [String: Any]
        sid = Self.clean(info?["id"] as? String) ?? sid
        cwd = Self.clean(info?["cwd"] as? String)
            ?? Self.clean(fallbackCWD) ?? cwd
        generatedTitle = Self.clean(object["generated_title"] as? String)
        sessionSummaryText = Self.clean(object["session_summary"] as? String)
        currentModelID = Self.clean(object["current_model_id"] as? String)
        startedAt = Self.date(object["created_at"]) ?? startedAt
        last = Self.date(object["last_active_at"])
            ?? Self.date(object["updated_at"]) ?? last
        summaryMessageCount = Self.int(object["num_chat_messages"])
            ?? Self.int(object["num_messages"]) ?? summaryMessageCount
        parentSessionID = Self.clean(object["parent_session_id"] as? String)
        sessionKind = Self.clean(object["session_kind"] as? String)
        forkedAt = Self.date(object["forked_at"])
        forkParentPromptID = Self.clean(object["fork_parent_prompt_id"] as? String)
        forkContextSource = Self.clean(object["fork_context_source"] as? String)
    }

    public mutating func ingestChatHistory(_ data: Data) {
        chatBytesIngested += UInt64(data.count)
        let split = Self.lines(in: data, after: chatPending)
        chatPending = split.pending
        for line in split.lines { consumeChat(line: line) }
    }

    public mutating func ingestUpdates(_ data: Data) {
        updatesBytesIngested += UInt64(data.count)
        let split = Self.lines(in: data, after: updatesPending)
        updatesPending = split.pending
        for line in split.lines { consumeUpdate(line: line) }
    }

    mutating func resetChatPendingForTail(at offset: UInt64) {
        chatPending = Data()
        chatBytesIngested = offset
    }

    mutating func resetUpdatesPendingForTail(at offset: UInt64) {
        updatesPending = Data()
        updatesBytesIngested = offset
    }

    public func summary(filePath: String,
                        machineID: String = Machine.localID) -> SessionSummary {
        var snapshot = self
        if !snapshot.chatPending.isEmpty {
            snapshot.consumeChat(line: snapshot.chatPending)
        }
        if !snapshot.updatesPending.isEmpty {
            snapshot.consumeUpdate(line: snapshot.updatesPending)
        }
        let project = snapshot.cwd.isEmpty
            ? "—" : (snapshot.cwd as NSString).lastPathComponent
        let usageByModel = snapshot.usageByModel
        let badgeModels = snapshot.usageModelsSeen.isEmpty
            ? snapshot.transcriptModelsSeen
            : snapshot.usageModelsSeen
        let badge = badgeModels.isEmpty
            ? snapshot.currentModelID
            : badgeModels.sorted().joined(separator: " + ")
        let allModels = snapshot.transcriptModelsSeen.union(snapshot.usageModelsSeen)
        return SessionSummary(
            id: snapshot.sid,
            provider: .grok,
            project: project,
            cwd: snapshot.cwd,
            model: badge,
            lastActivity: snapshot.last,
            messageCount: max(snapshot.summaryMessageCount,
                              snapshot.chatRecordCount),
            usage: usageByModel.values.reduce(SessionUsage(), +),
            contextWeight: snapshot.contextWeight,
            filePath: filePath,
            lastUserMessage: snapshot.lastUserMessage,
            name: snapshot.generatedTitle,
            handle: SessionHandles.derive(
                autoName: snapshot.generatedTitle,
                summary: snapshot.sessionSummaryText,
                firstUserMessage: snapshot.firstUserMessage,
                cwd: snapshot.cwd),
            usageByTier: snapshot.usageByTier,
            usageByDay: snapshot.usageByDay,
            usageByModel: usageByModel,
            usageByModelDay: snapshot.usageByModelDay,
            messagesByModelDay: snapshot.messagesByModelDay,
            rawUsageBlocks: snapshot.rawUsageBlocks,
            usageIsPartial: snapshot.usageIsPartial,
            tiersSeen: Set(allModels.map { ModelTier(raw: $0) }),
            assistantTurnsByModel: snapshot.assistantTurnsByModel,
            machineID: machineID)
            .computingCostBundle()
    }

    public var attentionSignals: AttentionSignals {
        AttentionSignals(lastEventAt: last, lastKind: .turnComplete,
                         canObserveBlocking: false)
    }

    static func attentionSignals(fromTailLines lines: [Data]) -> AttentionSignals {
        var accumulator = GrokSessionAccumulator(defaultID: "attention-tail")
        for line in lines { accumulator.consumeUpdate(line: line) }
        return accumulator.attentionSignals
    }

    private var usageByModel: [String: SessionUsage] {
        usageByKey.values.reduce(into: [:]) { result, value in
            result[value.model] = (result[value.model] ?? SessionUsage()) + value.usage
        }
    }

    private var usageByTier: [ModelTier: SessionUsage] {
        usageByKey.values.reduce(into: [:]) { result, value in
            let tier = ModelTier(raw: value.model)
            result[tier] = (result[tier] ?? SessionUsage()) + value.usage
        }
    }

    private var usageByDay: [String: [ModelTier: SessionUsage]] {
        usageByKey.values.reduce(into: [:]) { result, value in
            let tier = ModelTier(raw: value.model)
            result[value.day, default: [:]][tier] =
                (result[value.day]?[tier] ?? SessionUsage()) + value.usage
        }
    }

    private var usageByModelDay: [String: [String: SessionUsage]] {
        usageByKey.values.reduce(into: [:]) { result, value in
            result[value.day, default: [:]][value.model] =
                (result[value.day]?[value.model] ?? SessionUsage()) + value.usage
        }
    }

    private var messagesByModelDay: [String: [String: Int]] {
        usageByKey.values.reduce(into: [:]) { result, value in
            result[value.day, default: [:]][value.model, default: 0] += value.calls
        }
    }

    private mutating func consumeChat(line: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: line))
                as? [String: Any], let type = object["type"] as? String else { return }
        chatRecordCount += 1
        if type == "user", object["synthetic_reason"] == nil,
           let text = GrokTranscriptParser.textContent(object["content"]) {
            if firstUserMessage == nil { firstUserMessage = text }
            lastUserMessage = text
        }
        if type == "assistant", let raw = Self.clean(object["model_id"] as? String) {
            let model = PricingCatalog.normalize(raw)
            transcriptModelsSeen.insert(model)
            assistantTurnsByModel[model, default: 0] += 1
        }
    }

    private mutating func consumeUpdate(line: Data) {
        guard let object = (try? JSONSerialization.jsonObject(with: line))
                as? [String: Any] else { return }
        let params = object["params"] as? [String: Any]
        let update = (params?["update"] as? [String: Any]) ?? object
        let timestamp = Self.date(object["timestamp"])
        if let timestamp, last == nil || timestamp > last! { last = timestamp }

        switch update["sessionUpdate"] as? String {
        case "turn_completed":
            consumeTurnCompleted(update, timestamp: timestamp)
        case "subagent_spawned":
            consumeSubagentSpawned(update, timestamp: timestamp)
        default:
            break
        }
    }

    private mutating func consumeTurnCompleted(_ update: [String: Any],
                                               timestamp: Date?) {
        guard let usage = update["usage"] as? [String: Any] else { return }
        rawUsageBlocks += 1
        usageIsPartial = usageIsPartial
            || Self.bool(usage["costIsPartial"]) == true
        contextWeight = max(0, Self.int(usage["inputTokens"]) ?? contextWeight)
        let day = timestamp.map(localDayKey) ?? ""
        let promptID = Self.clean(update["prompt_id"] as? String)
        let modelUsage = usage["modelUsage"] as? [String: Any] ?? [:]

        if modelUsage.isEmpty {
            let model = PricingCatalog.normalize(currentModelID)
            recordUsage(usage, model: model.isEmpty ? "grok-unattributed" : model,
                        day: day, key: promptID)
            return
        }
        for (rawModel, value) in modelUsage {
            guard let modelObject = value as? [String: Any] else { continue }
            let model = PricingCatalog.normalize(rawModel)
            usageModelsSeen.insert(model)
            recordUsage(modelObject, model: model, day: day,
                        key: promptID.map { "\($0):\(model)" })
        }
    }

    private mutating func recordUsage(_ object: [String: Any], model: String,
                                      day: String, key suppliedKey: String?) {
        let input = max(0, Self.int(object["inputTokens"]) ?? 0)
        let cached = max(0, Self.int(object["cachedReadTokens"]) ?? 0)
        let output = max(0, Self.int(object["outputTokens"]) ?? 0)
        guard input != 0 || cached != 0 || output != 0 else { return }
        let fresh = input >= cached ? input - cached : 0
        let calls = max(1, Self.int(object["modelCalls"])
            ?? Self.int(object["numTurns"]) ?? 1)
        let key: String
        if let suppliedKey {
            key = suppliedKey
        } else {
            unkeyedUsageSequence += 1
            key = "#\(unkeyedUsageSequence):\(model)"
        }
        usageByKey[key] = KeyedUsage(
            usage: SessionUsage(inputTokens: fresh, outputTokens: output,
                                cacheCreateTokens: 0,
                                cacheReadTokens: min(input, cached),
                                cacheCreate1hTokens: 0),
            model: model, day: day, calls: calls)
    }

    private mutating func consumeSubagentSpawned(_ update: [String: Any],
                                                 timestamp: Date?) {
        guard let child = Self.clean(update["child_session_id"] as? String)
                ?? Self.clean(update["subagent_id"] as? String),
              let parent = Self.clean(update["parent_session_id"] as? String)
                ?? Optional(sid) else { return }
        let metadata = GrokSpawnMetadata(
            childSessionID: child, parentSessionID: parent,
            parentPromptID: Self.clean(update["parent_prompt_id"] as? String),
            subagentType: Self.clean(update["subagent_type"] as? String),
            description: Self.clean(update["description"] as? String),
            model: Self.clean(update["model"] as? String), spawnedAt: timestamp)
        if !spawnedChildren.contains(metadata) { spawnedChildren.append(metadata) }
    }

    private static func lines(in data: Data, after pending: Data)
        -> (lines: [Data], pending: Data) {
        var buffer = pending
        buffer.append(data)
        var lines: [Data] = []
        var start = buffer.startIndex
        while start < buffer.endIndex,
              let newline = buffer[start...].firstIndex(of: 0x0A) {
            if newline > start { lines.append(buffer.subdata(in: start..<newline)) }
            start = buffer.index(after: newline)
        }
        return (lines, start < buffer.endIndex ? Data(buffer[start...]) : Data())
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func int(_ value: Any?) -> Int? {
        if let value = value as? NSNumber { return value.intValue }
        if let value = value as? String { return Int(value) }
        return nil
    }

    private static func bool(_ value: Any?) -> Bool? {
        if let value = value as? NSNumber { return value.boolValue }
        if let value = value as? String { return Bool(value) }
        return nil
    }

    private static func date(_ value: Any?) -> Date? {
        if let value = value as? String { return parseDate(value) }
        if let value = value as? NSNumber {
            let raw = value.doubleValue
            return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1_000 : raw)
        }
        return nil
    }
}

// MARK: - Visible/searchable transcript projection

public enum GrokTranscriptParser {
    public static func events(fromLine data: Data,
                              fallbackID: String) -> [TranscriptEvent] {
        guard let object = (try? JSONSerialization.jsonObject(with: data))
                as? [String: Any], let type = object["type"] as? String else { return [] }
        let id = (object["id"] as? String) ?? fallbackID
        switch type {
        case "user":
            guard object["synthetic_reason"] == nil,
                  let text = textContent(object["content"]) else { return [] }
            return [TranscriptEvent(id: id, timestamp: nil,
                                    kind: .userPrompt(text))]
        case "assistant":
            guard let text = textContent(object["content"]) else { return [] }
            return [TranscriptEvent(id: id, timestamp: nil,
                                    kind: .assistantText(text))]
        case "reasoning":
            guard let text = textContent(object["summary"]) else { return [] }
            return [TranscriptEvent(id: id, timestamp: nil,
                                    kind: .thinking(text))]
        case "tool_result":
            guard let text = textContent(object["content"]) else { return [] }
            return [TranscriptEvent(id: id, timestamp: nil,
                                    kind: .toolResult(preview: text, isError: false))]
        case "system":
            guard let text = textContent(object["content"]) else { return [] }
            return [TranscriptEvent(id: id, timestamp: nil,
                                    kind: .system(subtype: "grok", text: text))]
        default:
            return []
        }
    }

    public static func events(at url: URL,
                              maximumEvents: Int = .max) -> [TranscriptEvent]? {
        let chatURL = url.lastPathComponent == "summary.json"
            ? url.deletingLastPathComponent().appendingPathComponent("chat_history.jsonl")
            : url
        guard let data = try? Data(contentsOf: chatURL) else { return nil }
        var output: [TranscriptEvent] = []
        var start = data.startIndex
        var lineNumber = 0
        while start < data.endIndex {
            let end = data[start...].firstIndex(of: 0x0A) ?? data.endIndex
            if end > start {
                output.append(contentsOf: events(
                    fromLine: data.subdata(in: start..<end),
                    fallbackID: "grok-L\(lineNumber)"))
                if output.count > maximumEvents {
                    output.removeFirst(output.count - maximumEvents)
                }
            }
            guard end < data.endIndex else { break }
            lineNumber += 1
            start = data.index(after: end)
        }
        return output
    }

    static func textContent(_ raw: Any?) -> String? {
        if let string = raw as? String { return clean(string) }
        guard let values = raw as? [Any] else { return nil }
        let text = values.compactMap { value -> String? in
            if let string = value as? String { return clean(string) }
            guard let object = value as? [String: Any] else { return nil }
            return clean(object["text"] as? String)
                ?? clean(object["content"] as? String)
        }.joined(separator: "\n")
        return clean(text)
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }
}
