import Foundation

// MARK: - Session names (the user's own handles: "custom-salvage", "mc-work")
//
// Claude Code keeps names in three places, none of them the transcript body:
//   1. ~/.claude/sessions/<PID>.json — a heartbeated LIVE-process registry:
//      {pid, sessionId, name, status, updatedAt, …}. `name` is the /rename value
//      (or the auto title). Reaped on exit, so it only covers running sessions.
//   2. ~/.claude/history.jsonl — the durable command log; every `/rename <name>`
//      line carries its sessionId. Survives exit → names for dead sessions.
//   3. type:"ai-title" records INSIDE each transcript — the auto topic title.
// Precedence: live registry > last /rename > ai-title (parsed by the
// accumulator) > project directory name.

public enum SessionNames {

    /// Parse the live registry files (contents of ~/.claude/sessions/*.json) into
    /// sessionID → name. Entries without a non-empty name are skipped.
    public static func parseLiveRegistry(_ files: [Data]) -> [String: String] {
        var out: [String: String] = [:]
        for data in files {
            guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let sid = obj["sessionId"] as? String,
                  let name = obj["name"] as? String,
                  !name.trimmingCharacters(in: .whitespaces).isEmpty else { continue }
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
            let name = String(display.dropFirst("/rename ".count))
                .trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { out[sid] = name }   // later lines overwrite = last wins
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
