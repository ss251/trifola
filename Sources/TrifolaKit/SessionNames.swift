import Foundation

// MARK: - Human session handles

/// Pure derivation of the short, human-readable handle used to identify a
/// session. Transcript records outrank prompt-derived handles; an empty session
/// gets a stable phrase rather than leaking its UUID into the UI.
public enum SessionHandles {
    public static let maxLength = 60
    public static let untitled = "Untitled session"

    /// Resolve the complete precedence chain for transcript-backed handles.
    /// Explicit `/rename` and live-registry names remain the separate
    /// `SessionSummary.name` overlay and therefore outrank this result at display
    /// time.
    public static func derive(autoName: String?, summary: String?,
                              firstUserMessage: String?) -> String {
        if let value = record(autoName) { return value }
        if let value = record(summary) { return value }
        if let value = fromFirstUserMessage(firstUserMessage) { return value }
        return untitled
    }

    /// Clean an auto-name or summary record without rewriting its intentional
    /// casing. These are already titles; only whitespace and runaway length need
    /// normalization.
    public static func record(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let value = collapsedWhitespace(raw)
        guard !value.isEmpty else { return nil }
        return clipped(value)
    }

    /// Turn the first genuinely useful human prompt into a compact handle.
    /// Slash-command-only prompts are transport, not intent. Paths collapse to
    /// their basename so a handle says `App.swift`, not a private home directory.
    public static func fromFirstUserMessage(_ raw: String?) -> String? {
        guard let raw else { return nil }
        var value = collapsedWhitespace(raw)
        guard !value.isEmpty, !isSlashCommand(value) else { return nil }

        value = value.split(separator: " ", omittingEmptySubsequences: true)
            .map { pathCollapsed(String($0)) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        value = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        // Sentence-case only the first alphabetic scalar. Preserve the rest so
        // identifiers such as SwiftUI, MCP, and API do not get damaged.
        if let index = value.firstIndex(where: { $0.isLetter }) {
            let next = value.index(after: index)
            value.replaceSubrange(index..<next, with: String(value[index]).uppercased())
        }
        return clipped(value)
    }

    private static func collapsedWhitespace(_ value: String) -> String {
        value.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
    }

    private static func isSlashCommand(_ value: String) -> Bool {
        guard let token = value.split(separator: " ", maxSplits: 1).first,
              token.hasPrefix("/") else { return false }
        let command = token.dropFirst()
        guard !command.isEmpty else { return false }
        return command.allSatisfy {
            $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" || $0 == ":"
        }
    }

    /// Preserve surrounding punctuation while shortening a filesystem path to
    /// its final component. Relative source paths are recognized when the final
    /// component looks like a file; ordinary prose such as `and/or` is untouched.
    private static func pathCollapsed(_ token: String) -> String {
        let leading = token.prefix { "([{'\"`".contains($0) }
        let trailing = token.reversed().prefix { ")]}'\"`,.;:!?".contains($0) }.reversed()
        let start = token.index(token.startIndex, offsetBy: leading.count)
        let end = token.index(token.endIndex, offsetBy: -trailing.count)
        guard start < end else { return token }
        let core = String(token[start..<end])
        let fileURLPrefix = "file://"
        let path = core.hasPrefix(fileURLPrefix) ? String(core.dropFirst(fileURLPrefix.count)) : core
        let last = (path as NSString).lastPathComponent
        let isPath = path.hasPrefix("/") || path.hasPrefix("~/")
            || path.hasPrefix("./") || path.hasPrefix("../")
            || (path.contains("/") && last.contains("."))
        guard isPath, !last.isEmpty else { return token }
        return String(leading) + last + String(trailing)
    }

    private static func clipped(_ value: String) -> String {
        guard value.count > maxLength else { return value }
        let budget = maxLength - 1
        var head = String(value.prefix(budget))
        if let space = head.lastIndex(of: " "), head.distance(from: head.startIndex, to: space) >= 36 {
            head = String(head[..<space])
        }
        return head.trimmingCharacters(in: .whitespacesAndNewlines) + "…"
    }
}

// MARK: - Session names (the user's own handles: "custom-salvage", "mc-work")
//
// Claude Code keeps names in three places, none of them the transcript body:
//   1. ~/.claude/sessions/<PID>.json — a heartbeated LIVE-process registry:
//      {pid, sessionId, name, status, updatedAt, …}. `name` is the /rename value
//      (or the auto title). Reaped on exit, so it only covers running sessions.
//   2. ~/.claude/history.jsonl — the durable command log; every `/rename <name>`
//      line carries its sessionId. Survives exit → names for dead sessions.
//   3. type:"ai-title" records INSIDE each transcript — the auto topic title.
// Display precedence: live registry > last /rename > ai-title > summary record
// > first meaningful user prompt > "Untitled session". The transcript-derived
// fallback is cached in SessionAccumulator; a UUID is transport metadata only.

public enum SessionNames {

    /// Parse the live registry files (contents of ~/.claude/sessions/*.json) into
    /// sessionID → name. Entries without a non-empty name are skipped.
    public static func parseLiveRegistry(_ files: [Data]) -> [String: String] {
        var out: [String: String] = [:]
        for data in files {
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sid = obj["sessionId"] as? String,
                  let name = SessionHandles.record(obj["name"] as? String) else { continue }
            out[sid] = name
        }
        return out
    }

    /// Extract the LAST `/rename <name>` per session from history.jsonl bytes.
    /// The file is a few MB; lines are pre-filtered by a cheap byte scan so the
    /// JSON parser only ever sees the handful of rename lines.
    public static func parseRenames(_ history: Data) -> [String: String] {
        guard let text = String(data: history, encoding: .utf8) else { return [:] }
        var out: [String: String] = [:]
        for line in text.split(separator: "\n") where line.contains("\"/rename ") {
            guard let data = line.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let display = obj["display"] as? String,
                  display.hasPrefix("/rename "),
                  let sid = obj["sessionId"] as? String else { continue }
            let rawName = String(display.dropFirst("/rename ".count))
            if let name = SessionHandles.record(rawName) {
                out[sid] = name   // later lines overwrite = last wins
            }
        }
        return out
    }
}

/// Reads + caches the two name sources. The live registry is ~10 tiny files
/// (re-read every refresh — sub-millisecond); history.jsonl is MBs and re-parsed
/// only when its mtime moves.
public final class SessionNameResolver: @unchecked Sendable {
    private let claudeDir: String
    private let lock = NSLock()
    private var renameCache: [String: String] = [:]
    private var renameMtime: Date? = nil

    public init(claudeDir: String = (NSHomeDirectory() as NSString).appendingPathComponent(".claude")) {
        self.claudeDir = claudeDir
    }

    /// sessionID → best known name (live registry wins over historical rename).
    public func names() -> [String: String] {
        let fm = FileManager.default

        let historyPath = (claudeDir as NSString).appendingPathComponent("history.jsonl")
        let mtime = (try? fm.attributesOfItem(atPath: historyPath)[.modificationDate]) as? Date
        lock.lock()
        if mtime != renameMtime {
            renameMtime = mtime
            renameCache = (fm.contents(atPath: historyPath)).map(SessionNames.parseRenames) ?? [:]
        }
        var out = renameCache
        lock.unlock()

        let sessionsDir = (claudeDir as NSString).appendingPathComponent("sessions")
        if let entries = try? fm.contentsOfDirectory(atPath: sessionsDir) {
            let files = entries.filter { $0.hasSuffix(".json") }
                .compactMap { fm.contents(atPath: (sessionsDir as NSString).appendingPathComponent($0)) }
            out.merge(SessionNames.parseLiveRegistry(files)) { _, live in live }
        }
        return out
    }
}
