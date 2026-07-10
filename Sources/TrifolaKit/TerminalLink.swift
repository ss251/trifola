import Foundation

/// Supplies the two read-only process snapshots used to map a transcript
/// session back to the terminal that owns it. Keeping the shell-outs behind
/// this boundary makes the mapping deterministic in tests and keeps AppKit /
/// AppleScript out of TrifolaKit.
public protocol TerminalProcessSnapshotProviding: Sendable {
    /// Output shaped like `ps -ww -axo pid=,ppid=,tty=,lstart=,command=`.
    func processListOutput() -> String?

    /// Output shaped like `lsof -a -p <pid> -d cwd -Fn`.
    func workingDirectoryOutput(for processID: Int32) -> String?
}

/// The live, read-only implementation used by the app. Callers should run a
/// resolution away from the main actor because `ps` and `lsof` are synchronous.
public struct SystemTerminalProcessSnapshotProvider: TerminalProcessSnapshotProviding {
    public init() {}

    public func processListOutput() -> String? {
        guard let result = ProbePrimitives.runCommand(
            "/bin/ps",
            ["-ww", "-axo", "pid=,ppid=,tty=,lstart=,command="],
            timeout: 2
        ), result.status == 0 else { return nil }
        return String(data: result.stdout, encoding: .utf8)
    }

    public func workingDirectoryOutput(for processID: Int32) -> String? {
        let lsof = ProbePrimitives.firstExecutable(["/usr/sbin/lsof", "/usr/bin/lsof"])
        guard let lsof,
              let result = ProbePrimitives.runCommand(
                lsof,
                ["-a", "-p", String(processID), "-d", "cwd", "-Fn"],
                timeout: 2
              ), result.status == 0 else { return nil }
        return String(data: result.stdout, encoding: .utf8)
    }
}

/// A terminal application found in the selected Claude process's ancestry.
public enum TerminalApplication: Sendable, Equatable, Hashable {
    case terminal
    case iTerm2
    case ghostty
    /// Another `.app` ancestor (Warp, Alacritty, Kitty, etc.). The app can
    /// activate its owner PID for the Tier-2 fallback without knowing its API.
    case other(name: String)

    /// Only Terminal and iTerm2 have Tier-1 tab targeting in the launch order.
    public var supportsExactTTYTargeting: Bool {
        switch self {
        case .terminal, .iTerm2: true
        case .ghostty, .other: false
        }
    }
}

/// Everything the app target needs to perform the tiered launch. No activation
/// occurs here: exact AppleScript and app-level activation remain app concerns.
public struct TerminalLinkTarget: Sendable, Equatable {
    public let processID: Int32
    /// Canonical `/dev/ttys…` form, or nil when the process has no controlling TTY.
    public let tty: String?
    public let startedAt: Date
    public let ownerProcessID: Int32?
    public let ownerApplication: TerminalApplication?

    public init(processID: Int32, tty: String?, startedAt: Date,
                ownerProcessID: Int32?, ownerApplication: TerminalApplication?) {
        self.processID = processID
        self.tty = tty
        self.startedAt = startedAt
        self.ownerProcessID = ownerProcessID
        self.ownerApplication = ownerApplication
    }

    /// True when all information needed for Tier 1 is present.
    public var supportsExactTargeting: Bool {
        tty != nil && ownerApplication?.supportsExactTTYTargeting == true
    }
}

/// Pure parser/selector for session → Claude PID → TTY + terminal ancestry.
public struct TerminalLinkResolver: Sendable {
    private let snapshots: any TerminalProcessSnapshotProviding

    public init(snapshots: any TerminalProcessSnapshotProviding = SystemTerminalProcessSnapshotProvider()) {
        self.snapshots = snapshots
    }

    /// Finds all live Claude processes whose cwd exactly matches `sessionCWD`.
    /// When more than one matches, the newest process wins (then highest PID as
    /// a deterministic tie-break). Missing/stale snapshots simply return nil so
    /// the app can silently fall through to its transcript-inspector behavior.
    public func resolve(sessionCWD: String) -> TerminalLinkTarget? {
        guard !sessionCWD.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let output = snapshots.processListOutput() else { return nil }

        let processes = Self.parseProcessList(output)
        let byPID = Dictionary(uniqueKeysWithValues: processes.map { ($0.processID, $0) })
        let wantedCWD = Self.normalizedPath(sessionCWD)

        let matches = processes.compactMap { process -> (TerminalProcess, String)? in
            guard process.isClaudeProcess,
                  let cwdOutput = snapshots.workingDirectoryOutput(for: process.processID),
                  let cwd = Self.parseWorkingDirectory(cwdOutput),
                  Self.normalizedPath(cwd) == wantedCWD else { return nil }
            return (process, cwd)
        }

        guard let selected = matches.map(\.0).max(by: {
            ($0.startedAt, $0.processID) < ($1.startedAt, $1.processID)
        }) else { return nil }

        let owner = Self.terminalOwner(for: selected, in: byPID)
        return TerminalLinkTarget(
            processID: selected.processID,
            tty: Self.normalizedTTY(selected.tty),
            startedAt: selected.startedAt,
            ownerProcessID: owner?.processID,
            ownerApplication: owner?.application
        )
    }

    /// Parsed row from the fixed-width `ps` snapshot. Public to make corpus
    /// diagnostics possible without duplicating parser behavior in the app.
    public struct TerminalProcess: Sendable, Equatable {
        public let processID: Int32
        public let parentProcessID: Int32
        public let tty: String?
        public let startedAt: Date
        public let command: String

        public init(processID: Int32, parentProcessID: Int32, tty: String?,
                    startedAt: Date, command: String) {
            self.processID = processID
            self.parentProcessID = parentProcessID
            self.tty = tty
            self.startedAt = startedAt
            self.command = command
        }

        public var isClaudeProcess: Bool { TerminalLinkResolver.commandLooksLikeClaude(command) }
    }

    /// Parses `ps -ww -axo pid=,ppid=,tty=,lstart=,command=`. `lstart` is five
    /// whitespace-separated fields, so commands remain intact after field 8.
    public static func parseProcessList(_ output: String) -> [TerminalProcess] {
        output.split(whereSeparator: \.isNewline).compactMap { rawLine in
            let fields = rawLine.split(omittingEmptySubsequences: true, whereSeparator: \.isWhitespace)
            guard fields.count >= 9,
                  let pid = Int32(fields[0]),
                  let ppid = Int32(fields[1]) else { return nil }

            let dateText = fields[3...7].joined(separator: " ")
            guard let date = processDateFormatter.date(from: dateText) else { return nil }
            let command = fields[8...].joined(separator: " ")
            let rawTTY = String(fields[2])
            return TerminalProcess(
                processID: pid,
                parentProcessID: ppid,
                tty: rawTTY == "??" || rawTTY == "-" ? nil : rawTTY,
                startedAt: date,
                command: command
            )
        }
    }

    /// Parses lsof's field output. A small tabular fallback makes diagnostics
    /// tolerant of fixtures copied from an unflagged `lsof` command.
    public static func parseWorkingDirectory(_ output: String) -> String? {
        let lines = output.split(whereSeparator: \.isNewline).map(String.init)
        if let nameField = lines.first(where: { $0.hasPrefix("n") && $0.count > 1 }) {
            return String(nameField.dropFirst())
        }
        for line in lines where line.split(whereSeparator: \.isWhitespace).contains("cwd") {
            let fields = line.split(whereSeparator: \.isWhitespace)
            // Default lsof columns after FD are TYPE, DEVICE, SIZE/OFF, NODE,
            // then NAME. Keep the suffix joined because cwd paths may contain spaces.
            if let cwdIndex = fields.firstIndex(of: "cwd"), cwdIndex + 5 < fields.endIndex {
                return fields[(cwdIndex + 5)...].joined(separator: " ")
            }
        }
        return nil
    }

    public static func normalizedTTY(_ tty: String?) -> String? {
        guard var tty = tty?.trimmingCharacters(in: .whitespacesAndNewlines),
              !tty.isEmpty, tty != "??", tty != "-" else { return nil }
        if !tty.hasPrefix("/dev/") { tty = "/dev/" + tty }
        return tty
    }

    public static func normalizedPath(_ path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
            .standardizedFileURL
            .resolvingSymlinksInPath()
            .path
    }

    private static func commandLooksLikeClaude(_ command: String) -> Bool {
        let lowered = command.lowercased()
        let tokens = lowered.split(whereSeparator: \.isWhitespace).prefix(4)
        if tokens.contains(where: { token in
            let basename = token.split(separator: "/").last ?? token
            return basename == "claude" || basename == "claude-code"
        }) { return true }
        return lowered.contains("/@anthropic-ai/claude-code/")
    }

    private struct TerminalOwner {
        let processID: Int32
        let application: TerminalApplication
    }

    private static func terminalOwner(for process: TerminalProcess,
                                      in processes: [Int32: TerminalProcess]) -> TerminalOwner? {
        var parentID = process.parentProcessID
        var visited: Set<Int32> = [process.processID]
        while parentID > 0, visited.insert(parentID).inserted,
              let parent = processes[parentID] {
            if let app = terminalApplication(for: parent.command) {
                return TerminalOwner(processID: parent.processID, application: app)
            }
            parentID = parent.parentProcessID
        }
        return nil
    }

    private static func terminalApplication(for command: String) -> TerminalApplication? {
        let lowered = command.lowercased()
        if lowered.contains("terminal.app/contents/macos/terminal") ||
            lowered.contains("com.apple.terminal") {
            return .terminal
        }
        if lowered.contains("iterm.app/contents/macos/iterm2") ||
            lowered.contains("iterm2.app/contents/macos/iterm2") {
            return .iTerm2
        }
        if lowered.contains("ghostty.app/contents/macos/ghostty") { return .ghostty }

        // Preserve app-level focus for terminal emulators we do not know yet.
        if let appRange = command.range(of: ".app/Contents/MacOS/", options: .caseInsensitive) {
            let before = command[..<appRange.lowerBound]
            let name = before.split(separator: "/").last.map(String.init) ?? "Terminal"
            return .other(name: name)
        }
        return nil
    }

    private static var processDateFormatter: DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        return formatter
    }
}
