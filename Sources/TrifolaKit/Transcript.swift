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

    public init(id: String, timestamp: Date?, kind: Kind, isSidechain: Bool = false) {
        self.id = id
        self.timestamp = timestamp
        self.kind = kind
        self.isSidechain = isSidechain
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

    public init() {}

    public func open(path: String, tailBytes: UInt64 = 2_000_000) {
        close()
        guard !path.isEmpty else { state = .error("No transcript file for this session."); return }
        guard FileManager.default.fileExists(atPath: path) else {
            state = .error("Transcript not found:\n\(path)")
            return
        }
        state = .live
        let tailer = FileTailer(url: URL(fileURLWithPath: path), tailBytes: tailBytes) { [weak self] chunk in
            // parse off-main, then hop to the actor with results
            var parsed: [TranscriptEvent] = []
            for (i, line) in chunk.lines.enumerated() {
                parsed.append(contentsOf: TranscriptParser.events(fromLine: line, fallbackID: "L\(chunk.firstLineIndex + i)"))
            }
            let reset = chunk.reset
            let mid = chunk.startedMidFile
            Task { @MainActor [weak self] in
                self?.apply(parsed, reset: reset, startedMidFile: mid)
            }
        }
        self.tailer = tailer
        tailer.start()
    }

    public func close() {
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
