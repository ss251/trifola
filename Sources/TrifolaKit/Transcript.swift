import Foundation
import Combine

// MARK: - Transcript event model

public struct TranscriptEvent: Identifiable, Sendable, Equatable {
    public enum Kind: Sendable, Equatable {
        case userPrompt(String)
        case assistantText(String)
        case thinking(String)
        case toolUse(name: String, detail: String)
        case toolResult(preview: String, isError: Bool)
        case system(subtype: String, text: String)
        case summary(String)
    }
    public let id: String
    public let timestamp: Date?
    public let kind: Kind
    public let isSidechain: Bool
    /// A bounded, immutable projection prepared once when the event is parsed.
    /// SwiftUI consumes whole lines from this value; it never tokenizes or
    /// pretty-prints transcript payloads while scrolling.
    public let textPresentation: TranscriptTextPresentation

    public init(id: String, timestamp: Date?, kind: Kind, isSidechain: Bool = false) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.isSidechain = isSidechain
        self.textPresentation = Self.makeTextPresentation(for: kind)
    }

    private static func makeTextPresentation(for kind: Kind) -> TranscriptTextPresentation {
        switch kind {
        case .assistantText(let text), .toolResult(let text, _), .system(_, let text):
            return StructuredTranscriptProjector.project(text)
                .map(TranscriptTextPresentation.structured) ?? .plain
        case .userPrompt, .thinking, .toolUse, .summary:
            return .plain
        }
    }
}

// MARK: - Structured text projection

public enum TranscriptTextPresentation: Sendable, Equatable {
    case plain
    case structured(StructuredTranscriptPresentation)
}

public struct StructuredTranscriptPresentation: Sendable, Equatable {
    public enum Format: String, Sendable, Equatable {
        case json
        case xml
        case diff

        public var label: String {
            switch self {
            case .json: return "JSON"
            case .xml: return "Markup"
            case .diff: return "Diff"
            }
        }
    }

    public struct Line: Sendable, Equatable, Identifiable {
        public enum Role: Sendable, Equatable {
            /// Braces, tags, diff headers, and other structural-only lines.
            case markup
            case content
            case addition
            case removal
        }

        public let id: Int
        public let text: String
        public let depth: Int
        public let role: Role

        public init(id: Int, text: String, depth: Int, role: Role) {
            self.id = id
            self.text = text
            self.depth = depth
            self.role = role
        }
    }

    /// Deliberately small enough for a single transcript row to remain cheap.
    public static let maximumLines = 28
    public static let maximumCharactersPerLine = 320
    public static let maximumGuideDepth = 8

    public let format: Format
    public let lines: [Line]
    public let didTruncate: Bool

    public init(format: Format, lines: [Line], didTruncate: Bool) {
        self.format = format
        self.lines = lines
        self.didTruncate = didTruncate
    }
}

/// One-time, Foundation-only projection for JSON, XML-like markup, and unified
/// diffs. The raw event text remains the source of truth and powers the Raw
/// affordance; this type stores only the bounded readable projection.
private enum StructuredTranscriptProjector {
    private struct ProjectedLine {
        let text: String
        let depth: Int
        let role: StructuredTranscriptPresentation.Line.Role
    }

    static func project(_ text: String) -> StructuredTranscriptPresentation? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        if let lines = jsonLines(trimmed) {
            return bounded(.json, lines)
        }
        if let lines = xmlLines(trimmed) {
            return bounded(.xml, lines)
        }
        if let lines = diffLines(text) {
            return bounded(.diff, lines)
        }
        return nil
    }

    private static func jsonLines(_ text: String) -> [ProjectedLine]? {
        guard let first = text.first, first == "{" || first == "[",
              let data = text.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data),
              object is [String: Any] || object is [Any],
              let prettyData = try? JSONSerialization.data(
                withJSONObject: object, options: [.prettyPrinted]),
              let pretty = String(data: prettyData, encoding: .utf8)
        else { return nil }

        return pretty.components(separatedBy: .newlines).map { rawLine in
            let leading = rawLine.prefix { $0 == " " || $0 == "\t" }
            let spaces = leading.reduce(into: 0) { count, character in
                count += character == "\t" ? 2 : 1
            }
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let structural = !line.isEmpty && line.allSatisfy { "{}[],:".contains($0) }
            return ProjectedLine(
                text: line,
                depth: spaces / 2,
                role: structural ? .markup : .content)
        }
    }

    private static func xmlLines(_ text: String) -> [ProjectedLine]? {
        guard text.first == "<", text.contains("</") || text.contains("/>") else {
            return nil
        }

        var units: [String] = []
        var cursor = text.startIndex
        var tagCount = 0
        while cursor < text.endIndex {
            if text[cursor] == "<" {
                guard let close = text[cursor...].firstIndex(of: ">") else { return nil }
                let afterClose = text.index(after: close)
                units.append(String(text[cursor..<afterClose]))
                tagCount += 1
                cursor = afterClose
            } else {
                let next = text[cursor...].firstIndex(of: "<") ?? text.endIndex
                let content = text[cursor..<next]
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !content.isEmpty { units.append(content) }
                cursor = next
            }
        }
        guard tagCount >= 2 else { return nil }

        var depth = 0
        return units.map { unit in
            let isTag = unit.first == "<"
            let isClosing = unit.hasPrefix("</")
            if isClosing { depth = max(0, depth - 1) }
            let projected = ProjectedLine(
                text: unit,
                depth: depth,
                role: isTag ? .markup : .content)
            let isDeclaration = unit.hasPrefix("<?") || unit.hasPrefix("<!")
            let isSelfClosing = unit.hasSuffix("/>")
            if isTag && !isClosing && !isDeclaration && !isSelfClosing {
                depth += 1
            }
            return projected
        }
    }

    private static func diffLines(_ text: String) -> [ProjectedLine]? {
        let sourceLines = text.components(separatedBy: .newlines)
        guard sourceLines.count >= 3 else { return nil }
        let hasHeader = sourceLines.contains { $0.hasPrefix("diff --git ") }
        let hasHunk = sourceLines.contains { $0.hasPrefix("@@") }
        let hasOldFile = sourceLines.contains { $0.hasPrefix("--- ") }
        let hasNewFile = sourceLines.contains { $0.hasPrefix("+++ ") }
        let hasChange = sourceLines.contains {
            ($0.hasPrefix("+") && !$0.hasPrefix("+++"))
                || ($0.hasPrefix("-") && !$0.hasPrefix("---"))
        }
        guard hasHeader || (hasHunk && hasChange) || (hasOldFile && hasNewFile && hasChange) else {
            return nil
        }

        return sourceLines.map { line in
            let role: StructuredTranscriptPresentation.Line.Role
            if line.hasPrefix("diff --git ") || line.hasPrefix("index ")
                || line.hasPrefix("--- ") || line.hasPrefix("+++ ")
                || line.hasPrefix("@@") || line.hasPrefix("\\ No newline") {
                role = .markup
            } else if line.hasPrefix("+") {
                role = .addition
            } else if line.hasPrefix("-") {
                role = .removal
            } else {
                role = .content
            }
            return ProjectedLine(text: line, depth: 0, role: role)
        }
    }

    private static func bounded(
        _ format: StructuredTranscriptPresentation.Format,
        _ source: [ProjectedLine]
    ) -> StructuredTranscriptPresentation {
        let maxLines = StructuredTranscriptPresentation.maximumLines
        let maxCharacters = StructuredTranscriptPresentation.maximumCharactersPerLine
        let maxDepth = StructuredTranscriptPresentation.maximumGuideDepth
        var didTruncate = source.count > maxLines
        let visibleCount = didTruncate ? maxLines - 1 : source.count
        var lines = Array(source.prefix(visibleCount)).enumerated().map { index, sourceLine in
            var text = sourceLine.text
            if text.count > maxCharacters {
                text = String(text.prefix(maxCharacters)) + " …"
                didTruncate = true
            }
            return StructuredTranscriptPresentation.Line(
                id: index,
                text: text,
                depth: min(max(0, sourceLine.depth), maxDepth),
                role: sourceLine.role)
        }
        if source.count > maxLines {
            lines.append(.init(
                id: lines.count,
                text: "… \(source.count - visibleCount) more lines",
                depth: 0,
                role: .markup))
        }
        return StructuredTranscriptPresentation(
            format: format, lines: lines, didTruncate: didTruncate)
    }
}

// MARK: - Parser
// JSONSerialization (not Codable) because transcript content blocks are polymorphic
// and we want maximum leniency: a malformed line yields [] instead of failing a file.

public enum TranscriptParser {

    public static let maxTextLength = 4000
    public static let maxResultLength = 1600
    public static let maxThinkingLength = 1200

    /// Parse one .jsonl line into zero or more display events.
    public static func events(fromLine data: Data, fallbackID: String) -> [TranscriptEvent] {
        guard let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let type = obj["type"] as? String else { return [] }

        let uuid = (obj["uuid"] as? String) ?? fallbackID
        let ts = parseDate(obj["timestamp"] as? String)
        let side = (obj["isSidechain"] as? Bool) ?? false
        if (obj["isMeta"] as? Bool) == true { return [] }

        switch type {
        case "user":
            return userEvents(obj, uuid: uuid, ts: ts, side: side)
        case "assistant":
            return assistantEvents(obj, uuid: uuid, ts: ts, side: side)
        case "system":
            let sub = (obj["subtype"] as? String) ?? "system"
            let text = (obj["content"] as? String) ?? ""
            guard !text.isEmpty else { return [] }
            return [TranscriptEvent(id: uuid, timestamp: ts,
                                    kind: .system(subtype: sub, text: clip(text, maxResultLength)),
                                    isSidechain: side)]
        case "summary":
            guard let s = obj["summary"] as? String, !s.isEmpty else { return [] }
            return [TranscriptEvent(id: uuid + "-sum", timestamp: ts, kind: .summary(clip(s, 300)))]
        default:
            return []   // queue-operation, attachment, file-history-snapshot, progress, …
        }
    }

    private static func userEvents(_ obj: [String: Any], uuid: String, ts: Date?, side: Bool) -> [TranscriptEvent] {
        guard let message = obj["message"] as? [String: Any] else { return [] }
        var out: [TranscriptEvent] = []
        if let text = message["content"] as? String {
            if let cleaned = cleanUserText(text) {
                out.append(TranscriptEvent(id: uuid, timestamp: ts,
                                           kind: .userPrompt(cleaned), isSidechain: side))
            }
            return out
        }
        guard let blocks = message["content"] as? [[String: Any]] else { return [] }
        for (i, block) in blocks.enumerated() {
            let bid = "\(uuid)-\(i)"
            switch block["type"] as? String {
            case "text":
                if let t = block["text"] as? String, let cleaned = cleanUserText(t) {
                    out.append(TranscriptEvent(id: bid, timestamp: ts,
                                               kind: .userPrompt(cleaned), isSidechain: side))
                }
            case "tool_result":
                let isError = (block["is_error"] as? Bool) ?? false
                let preview = resultPreview(block["content"])
                out.append(TranscriptEvent(id: bid, timestamp: ts,
                                           kind: .toolResult(preview: preview, isError: isError),
                                           isSidechain: side))
            default:
                break
            }
        }
        return out
    }

    private static func assistantEvents(_ obj: [String: Any], uuid: String, ts: Date?, side: Bool) -> [TranscriptEvent] {
        guard let message = obj["message"] as? [String: Any],
              let blocks = message["content"] as? [[String: Any]] else { return [] }
        var out: [TranscriptEvent] = []
        for (i, block) in blocks.enumerated() {
            let bid = "\(uuid)-\(i)"
            switch block["type"] as? String {
            case "text":
                if let t = block["text"] as? String, !t.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    out.append(TranscriptEvent(id: bid, timestamp: ts,
                                               kind: .assistantText(clip(t, maxTextLength)), isSidechain: side))
                }
            case "thinking":
                if let t = block["thinking"] as? String, !t.isEmpty {
                    out.append(TranscriptEvent(id: bid, timestamp: ts,
                                               kind: .thinking(clip(t, maxThinkingLength)), isSidechain: side))
                }
            case "tool_use":
                let name = (block["name"] as? String) ?? "tool"
                let detail = toolDetail(name: name, input: block["input"] as? [String: Any] ?? [:])
                out.append(TranscriptEvent(id: bid, timestamp: ts,
                                           kind: .toolUse(name: name, detail: detail), isSidechain: side))
            default:
                break
            }
        }
        return out
    }

    /// Human-scannable one-liner for a tool invocation.
    public static func toolDetail(name: String, input: [String: Any]) -> String {
        func s(_ key: String) -> String? {
            guard let v = input[key] as? String, !v.isEmpty else { return nil }
            return v
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        func path(_ key: String) -> String? {
            s(key).map { $0.replacingOccurrences(of: home, with: "~") }
        }
        var detail: String
        switch name {
        case "Bash": detail = s("command") ?? ""
        case "Read", "Write", "Edit", "NotebookEdit": detail = path("file_path") ?? path("notebook_path") ?? ""
        case "Grep": detail = [s("pattern"), path("path")].compactMap { $0 }.joined(separator: "  in ")
        case "Glob": detail = s("pattern") ?? ""
        case "Agent", "Task": detail = s("description") ?? s("subagent_type") ?? s("prompt") ?? ""
        case "WebFetch": detail = s("url") ?? ""
        case "WebSearch": detail = s("query") ?? ""
        case "TaskCreate": detail = s("subject") ?? ""
        case "TaskUpdate": detail = ["#" + (s("taskId") ?? "?"), s("status")].compactMap { $0 }.joined(separator: " → ")
        case "Skill": detail = s("skill") ?? ""
        default:
            detail = input.compactMap { k, v -> String? in
                guard let str = v as? String, !str.isEmpty else { return nil }
                return "\(k): \(str)"
            }.sorted().joined(separator: " · ")
        }
        return clip(detail.replacingOccurrences(of: "\n", with: " ⏎ "), 400)
    }

    private static func resultPreview(_ content: Any?) -> String {
        if let str = content as? String { return clip(str, maxResultLength) }
        if let blocks = content as? [[String: Any]] {
            let text = blocks.compactMap { b -> String? in
                if b["type"] as? String == "text" { return b["text"] as? String }
                if b["type"] as? String == "image" { return "[image]" }
                return nil
            }.joined(separator: "\n")
            return clip(text, maxResultLength)
        }
        return ""
    }

    /// Strip injected wrappers from user text; nil if nothing human remains.
    static func cleanUserText(_ text: String) -> String? {
        var t = text
        // <command-name>/model</command-name><command-args>opus</command-args> → "/model opus"
        if let name = extract(t, tag: "command-name") {
            let args = extract(t, tag: "command-args") ?? ""
            t = args.isEmpty ? name : "\(name) \(args)"
            return clip(t.trimmingCharacters(in: .whitespacesAndNewlines), maxTextLength)
        }
        if t.contains("<local-command-stdout>") { return nil }
        // drop injected reminder blocks
        while let r = rangeOfBlock(t, tag: "system-reminder") { t.removeSubrange(r) }
        t = t.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.isEmpty || t.hasPrefix("Caveat:") { return nil }
        return clip(t, maxTextLength)
    }

    private static func extract(_ text: String, tag: String) -> String? {
        guard let r = rangeOfBlock(text, tag: tag) else { return nil }
        let inner = text[r].dropFirst(tag.count + 2).dropLast(tag.count + 3)
        let v = inner.trimmingCharacters(in: .whitespacesAndNewlines)
        return v.isEmpty ? nil : v
    }

    private static func rangeOfBlock(_ text: String, tag: String) -> Range<String.Index>? {
        guard let start = text.range(of: "<\(tag)>"),
              let end = text.range(of: "</\(tag)>", range: start.upperBound..<text.endIndex)
        else { return nil }
        return start.lowerBound..<end.upperBound
    }

    static func clip(_ s: String, _ max: Int) -> String {
        guard s.count > max else { return s }
        return String(s.prefix(max)) + " … (+\(s.count - max) chars)"
    }
}

// MARK: - File tailer
// Follows an append-only file with a DispatchSource vnode watcher. All state is
// confined to a private serial queue; parsed chunks are delivered via callback.

public final class FileTailer: @unchecked Sendable {
    public struct Chunk: Sendable {
        public let lines: [Data]
        public let firstLineIndex: Int  // running index of lines[0] since tailing began
        public let reset: Bool          // true → replace state (initial read / truncation)
        public let startedMidFile: Bool // true → initial read began past byte 0
    }

    private let url: URL
    private let tailBytes: UInt64
    private let onChunk: @Sendable (Chunk) -> Void
    private let queue = DispatchQueue(label: "mc.filetailer", qos: .utility)
    private var handle: FileHandle?
    private var source: DispatchSourceFileSystemObject?
    private var offset: UInt64 = 0
    private var pending = Data()
    private var lineCount = 0
    private var readScheduled = false
    private var stopped = false

    public init(url: URL, tailBytes: UInt64 = 2_000_000, onChunk: @escaping @Sendable (Chunk) -> Void) {
        self.url = url
        self.tailBytes = tailBytes
        self.onChunk = onChunk
    }

    public func start() { queue.async { self.openAndRead(initial: true) } }
    public func stop() {
        queue.async {
            self.stopped = true
            self.teardown()
        }
    }

    // — queue-confined below —

    private func teardown() {
        source?.cancel()
        source = nil
        try? handle?.close()
        handle = nil
    }

    private func openAndRead(initial: Bool) {
        guard !stopped else { return }
        teardown()
        guard let fh = FileHandle(forReadingAtPath: url.path) else {
            // file not there (yet/anymore) — retry shortly
            queue.asyncAfter(deadline: .now() + 1.0) { [weak self] in self?.openAndRead(initial: initial) }
            return
        }
        handle = fh
        let size = (try? fh.seekToEnd()) ?? 0
        var startedMid = false
        if initial || size < offset {
            offset = size > tailBytes ? size - tailBytes : 0
            startedMid = offset > 0
            pending = Data()
        }
        try? fh.seek(toOffset: offset)
        let data = (try? fh.readToEnd()) ?? Data()
        deliver(data, reset: true, startedMidFile: startedMid, dropFirstPartial: startedMid)
        watch(fh)
    }

    private func watch(_ fh: FileHandle) {
        let src = DispatchSource.makeFileSystemObjectSource(
            fileDescriptor: fh.fileDescriptor,
            eventMask: [.write, .extend, .delete, .rename],
            queue: queue
        )
        src.setEventHandler { [weak self] in
            guard let self, !self.stopped else { return }
            let flags = src.data
            if flags.contains(.delete) || flags.contains(.rename) {
                self.queue.asyncAfter(deadline: .now() + 0.5) { [weak self] in self?.openAndRead(initial: false) }
                return
            }
            self.scheduleRead()
        }
        src.resume()
        source = src
    }

    private func scheduleRead() {
        guard !readScheduled else { return }
        readScheduled = true
        queue.asyncAfter(deadline: .now() + 0.15) { [weak self] in
            guard let self else { return }
            self.readScheduled = false
            self.readAppended()
        }
    }

    private func readAppended() {
        guard !stopped, let fh = handle else { return }
        let size = (try? fh.seekToEnd()) ?? 0
        if size < offset {                       // truncated/replaced — re-tail
            openAndRead(initial: true)
            return
        }
        guard size > offset else { return }
        try? fh.seek(toOffset: offset)
        let data = (try? fh.readToEnd()) ?? Data()
        deliver(data, reset: false, startedMidFile: false, dropFirstPartial: false)
    }

    private func deliver(_ data: Data, reset: Bool, startedMidFile: Bool, dropFirstPartial: Bool) {
        offset += UInt64(data.count)
        var buf = pending
        buf.append(data)
        var lines: [Data] = []
        var start = buf.startIndex
        while let nl = buf[start...].firstIndex(of: 0x0A) {
            if nl > start { lines.append(buf.subdata(in: start..<nl)) }
            start = buf.index(after: nl)
        }
        pending = start < buf.endIndex ? Data(buf[start...]) : Data()
        if dropFirstPartial, !lines.isEmpty { lines.removeFirst() }  // began mid-line
        if reset { lineCount = 0 }
        if reset || !lines.isEmpty {
            let first = lineCount
            lineCount += lines.count
            onChunk(Chunk(lines: lines, firstLineIndex: first, reset: reset, startedMidFile: startedMidFile))
        }
    }
}

// MARK: - Transcript store (one live session feed)

@MainActor
public final class TranscriptStore: ObservableObject {
    public enum State: Equatable { case idle, live, error(String) }

    @Published public private(set) var events: [TranscriptEvent] = []
    @Published public private(set) var state: State = .idle
    @Published public private(set) var startedMidFile = false
    @Published public private(set) var droppedHead = false

    public static let maxEvents = 2500

    private var tailer: FileTailer?
    private var openGeneration = 0

    public init() {}

    public func open(path: String, provider: Provider = .claude,
                     tailBytes: UInt64 = 2_000_000) {
        close()
        guard !path.isEmpty else { state = .error("No transcript file for this session."); return }
        openGeneration += 1
        let generation = openGeneration
        let url = URL(fileURLWithPath: path)

        // Archived Codex rollouts are immutable and compressed. Their bounded
        // read/decompression/parser pipeline runs wholly off-main; live JSONL
        // rollouts use the same FileTailer as Claude with a provider parser.
        if provider == .codex, path.hasSuffix(".jsonl.zst") {
            state = .live
            let maximumEvents = Self.maxEvents
            Task { [weak self] in
                let parsed = await Task.detached(priority: .userInitiated) {
                    CodexRolloutTranscriptParser.events(
                        at: url, maximumEvents: maximumEvents)
                }.value
                guard let self, self.openGeneration == generation else { return }
                guard let parsed else {
                    self.state = .error("Codex rollout could not be read.")
                    return
                }
                self.apply(parsed, reset: true, startedMidFile: false)
            }
            return
        }
        state = .live
        let tailer = FileTailer(url: url, tailBytes: tailBytes) { [weak self] chunk in
            // parse off-main, then hop to the actor with results
            var parsed: [TranscriptEvent] = []
            for (i, line) in chunk.lines.enumerated() {
                let id = "L\(chunk.firstLineIndex + i)"
                if provider == .codex {
                    parsed.append(contentsOf: CodexRolloutTranscriptParser.events(
                        fromLine: line, fallbackID: "codex-" + id))
                } else {
                    parsed.append(contentsOf: TranscriptParser.events(
                        fromLine: line, fallbackID: id))
                }
            }
            let reset = chunk.reset
            let mid = chunk.startedMidFile
            Task { @MainActor [weak self] in
                guard let self, self.openGeneration == generation else { return }
                self.apply(parsed, reset: reset, startedMidFile: mid)
            }
        }
        self.tailer = tailer
        tailer.start()
    }

    public func close() {
        openGeneration += 1
        tailer?.stop()
        tailer = nil
        events = []
        state = .idle
        startedMidFile = false
        droppedHead = false
    }

    private func apply(_ parsed: [TranscriptEvent], reset: Bool, startedMidFile mid: Bool) {
        if reset {
            events = parsed
            startedMidFile = mid
            droppedHead = false
        } else if !parsed.isEmpty {
            events.append(contentsOf: parsed)
        }
        if events.count > Self.maxEvents {
            events.removeFirst(events.count - Self.maxEvents)
            droppedHead = true
        }
    }
}
