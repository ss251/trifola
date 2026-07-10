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

/// The authoritative live-session join written by Claude Code under
/// `<config root>/sessions`. A session id is stronger identity than cwd: many
/// concurrently-live sessions routinely share the same repository (or `$HOME`).
public struct TerminalSessionRegistryRecord: Sendable, Equatable, Decodable {
    public let sessionID: String
    public let processID: Int32
    public let cwd: String?

    public init(sessionID: String, processID: Int32, cwd: String? = nil) {
        self.sessionID = sessionID
        self.processID = processID
        self.cwd = cwd
    }

    private enum CodingKeys: String, CodingKey {
        case sessionID = "sessionId"
        case processID = "pid"
        case cwd
    }
}

public protocol TerminalSessionRegistryProviding: Sendable {
    func records() throws -> [TerminalSessionRegistryRecord]
}

/// Reads only the small live-registry JSON documents. A malformed individual
/// record is ignored (Claude can be replacing it while we scan); failure to read
/// the directory itself is preserved so callers can report resolution failure.
public struct FileTerminalSessionRegistryProvider: TerminalSessionRegistryProviding {
    public let directory: URL

    public init(directory: URL = ClaudePaths.process.sessions) {
        self.directory = directory
    }

    public func records() throws -> [TerminalSessionRegistryRecord] {
        let manager = FileManager.default
        var isDirectory: ObjCBool = false
        guard manager.fileExists(atPath: directory.path, isDirectory: &isDirectory) else {
            return []
        }
        guard isDirectory.boolValue else {
            throw CocoaError(.fileReadInvalidFileName)
        }
        let urls = try manager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        return urls
            .filter { $0.pathExtension.lowercased() == "json" }
            .compactMap { url in
                guard let data = try? Data(contentsOf: url) else { return nil }
                return try? JSONDecoder().decode(TerminalSessionRegistryRecord.self, from: data)
            }
    }
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

    /// Human name for launch confirmations and diagnostics.
    public var displayName: String {
        switch self {
        case .terminal: "Terminal"
        case .iTerm2: "iTerm"
        case .ghostty: "Ghostty"
        case .other(let name): name
        }
    }
}

/// Everything the app target needs to perform the tiered launch. No activation
/// occurs here: exact AppleScript and app-level activation remain app concerns.
public struct TerminalLinkTarget: Sendable, Equatable {
    public enum Match: Sendable, Equatable {
        case sessionID
        case cwd
    }

    public let processID: Int32
    /// Canonical `/dev/ttys…` form, or nil when the process has no controlling TTY.
    public let tty: String?
    public let startedAt: Date
    public let ownerProcessID: Int32?
    public let ownerApplication: TerminalApplication?
    public let match: Match

    public init(processID: Int32, tty: String?, startedAt: Date,
                ownerProcessID: Int32?, ownerApplication: TerminalApplication?,
                match: Match = .cwd) {
        self.processID = processID
        self.tty = tty
        self.startedAt = startedAt
        self.ownerProcessID = ownerProcessID
        self.ownerApplication = ownerApplication
        self.match = match
    }

    /// True when all information needed for Tier 1 is present.
    public var supportsExactTargeting: Bool {
        tty != nil && ownerApplication?.supportsExactTTYTargeting == true
    }
}

/// Pure resolution result. Launch side effects deliberately use a separate,
/// user-visible outcome type below.
public enum TerminalLinkResolution: Sendable, Equatable {
    case target(TerminalLinkTarget)
    case notLive
    case ambiguous
    case failed(String)
}

public protocol TerminalLinkResolving: Sendable {
    func resolve(sessionID: String, cwd: String, machineID: String) -> TerminalLinkResolution
}

/// Pure parser/selector for session → Claude PID → TTY + terminal ancestry.
public struct TerminalLinkResolver: Sendable, TerminalLinkResolving {
    private let snapshots: any TerminalProcessSnapshotProviding
    private let registry: any TerminalSessionRegistryProviding

    public init(
        snapshots: any TerminalProcessSnapshotProviding = SystemTerminalProcessSnapshotProvider(),
        registry: any TerminalSessionRegistryProviding = FileTerminalSessionRegistryProvider()
    ) {
        self.snapshots = snapshots
        self.registry = registry
    }

    /// Resolves exact session identity first. CWD is only a compatibility fallback
    /// when the registry has no record for the requested session and exactly one
    /// live Claude process has that cwd. It never guesses among candidates.
    public func resolve(sessionID: String, cwd: String,
                        machineID: String) -> TerminalLinkResolution {
        guard machineID == Machine.localID else {
            return .failed("remote sessions have no local terminal route")
        }
        guard let output = snapshots.processListOutput() else {
            return .failed("process snapshot unavailable")
        }

        let processes = Self.parseProcessList(output)
        let byPID = processes.reduce(into: [Int32: TerminalProcess]()) {
            $0[$1.processID] = $1
        }

        let records: [TerminalSessionRegistryRecord]
        do {
            records = try registry.records()
        } catch {
            return .failed("live session registry unavailable: \(error.localizedDescription)")
        }

        if !sessionID.isEmpty {
            let exactPIDs = Set(records.lazy
                .filter { $0.sessionID == sessionID }
                .map(\.processID))
            if exactPIDs.count > 1 { return .ambiguous }
            if let processID = exactPIDs.first {
                guard let process = byPID[processID], process.isClaudeProcess else {
                    // A registry entry whose PID has exited (or been reused by a
                    // different program) is not permission to target a cwd peer.
                    return .notLive
                }
                return .target(Self.target(for: process, match: .sessionID, in: byPID))
            }
        }

        guard !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return .notLive
        }
        let wantedCWD = Self.normalizedPath(cwd)

        let matches = processes.compactMap { process -> TerminalProcess? in
            guard process.isClaudeProcess,
                  let cwdOutput = snapshots.workingDirectoryOutput(for: process.processID),
                  let processCWD = Self.parseWorkingDirectory(cwdOutput),
                  Self.normalizedPath(processCWD) == wantedCWD else { return nil }
            return process
        }

        guard matches.count <= 1 else { return .ambiguous }
        guard let selected = matches.first else { return .notLive }
        return .target(Self.target(for: selected, match: .cwd, in: byPID))
    }

    /// Compatibility shim for callers outside the app. Ambiguous and failed
    /// resolutions intentionally collapse to nil; production uses the typed API.
    public func resolve(sessionCWD: String) -> TerminalLinkTarget? {
        guard case .target(let target) = resolve(
            sessionID: "", cwd: sessionCWD, machineID: Machine.localID
        ) else { return nil }
        return target
    }

    private static func target(for selected: TerminalProcess, match: TerminalLinkTarget.Match,
                               in byPID: [Int32: TerminalProcess]) -> TerminalLinkTarget {
        let owner = Self.terminalOwner(for: selected, in: byPID)
        return TerminalLinkTarget(
            processID: selected.processID,
            tty: Self.normalizedTTY(selected.tty),
            startedAt: selected.startedAt,
            ownerProcessID: owner?.processID,
            ownerApplication: owner?.application,
            match: match
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

/// A stable, sendable copy of NSAppleScript's error dictionary. AppKit remains
/// in the executable target, but denial/failure details survive the boundary for
/// UI messaging, diagnostics, and regression tests.
public struct TerminalAutomationError: Sendable, Equatable {
    public let number: Int?
    public let message: String
    public let dictionary: [String: String]

    public init(number: Int?, message: String, dictionary: [String: String]) {
        self.number = number
        self.message = message
        self.dictionary = dictionary
    }
}

public enum TerminalExactTargetResult: Sendable, Equatable {
    case targeted
    case notFound
    case permissionDenied(TerminalAutomationError)
    case failed(TerminalAutomationError)
}

/// The complete user-facing result of an Open session attempt. These cases are
/// intentionally exhaustive: no AppleScript or resolution failure is reduced to
/// a boolean and silently discarded.
public enum TerminalLaunchOutcome: Sendable, Equatable {
    case exact(TerminalLinkTarget)
    case ownerActivated(TerminalLinkTarget)
    case permissionDenied(TerminalAutomationError)
    case notLive
    case ambiguous
    case failed(TerminalLaunchFailure)

    public var fallbackMessage: String? {
        switch self {
        case .exact, .ownerActivated:
            nil
        case .permissionDenied:
            "Terminal automation denied — showing transcript"
        case .notLive:
            "No live terminal found — showing transcript"
        case .ambiguous:
            "Multiple live terminals matched — showing transcript"
        case .failed:
            "Terminal unavailable — showing transcript"
        }
    }

    /// Confirmation shown when a launch SUCCEEDS. Without it, activating a
    /// terminal that is already frontmost (e.g. Ghostty, which has no scriptable
    /// tab for trifola to jump to) produces no visible change — the click reads
    /// as "nothing happened." This makes every successful open acknowledge.
    public var successMessage: String? {
        switch self {
        case .exact(let target):
            "Jumped to your session in \(target.ownerApplication?.displayName ?? "your terminal")"
        case .ownerActivated(let target):
            "Brought \(target.ownerApplication?.displayName ?? "your terminal") to the front"
        case .permissionDenied, .notLive, .ambiguous, .failed:
            nil
        }
    }
}

public enum TerminalLaunchFailure: Sendable, Equatable {
    case resolution(String)
    case automation(TerminalAutomationError)
    case noTerminalOwner
}

@MainActor
public protocol TerminalExactTargeting: AnyObject {
    func target(tty: String, application: TerminalApplication) -> TerminalExactTargetResult
}

@MainActor
public protocol TerminalOwnerActivating: AnyObject {
    func activate(processID: Int32) -> Bool
}

/// The three deterministic Tier-3 effects. They are separate calls so tests can
/// prove that Settings-front and already-selected states still open, select, and
/// reveal instead of accepting a state-preserving no-op.
@MainActor
public protocol TerminalWindowAdapting: AnyObject {
    func openMainWindow()
    func selectSession(id: String)
    func revealTranscript(sessionID: String, outcome: TerminalLaunchOutcome)
}

/// Testable orchestration for the three launch tiers. Process discovery runs off
/// the main actor; AppleScript, application activation, and visible fallback stay
/// on it. A remote session is rejected before the resolver is ever invoked.
@MainActor
public struct TerminalLaunchFlow {
    private let resolver: any TerminalLinkResolving
    private let exactTargeter: any TerminalExactTargeting
    private let ownerActivator: any TerminalOwnerActivating
    private let windows: any TerminalWindowAdapting

    public init(resolver: any TerminalLinkResolving,
                exactTargeter: any TerminalExactTargeting,
                ownerActivator: any TerminalOwnerActivating,
                windows: any TerminalWindowAdapting) {
        self.resolver = resolver
        self.exactTargeter = exactTargeter
        self.ownerActivator = ownerActivator
        self.windows = windows
    }

    @discardableResult
    public func open(sessionID: String, cwd: String,
                     machineID: String) async -> TerminalLaunchOutcome {
        guard machineID == Machine.localID else {
            return presentFallback(.notLive, sessionID: sessionID)
        }

        let resolver = self.resolver
        let resolution = await Task.detached(priority: .userInitiated) {
            resolver.resolve(sessionID: sessionID, cwd: cwd, machineID: machineID)
        }.value

        switch resolution {
        case .notLive:
            return presentFallback(.notLive, sessionID: sessionID)
        case .ambiguous:
            return presentFallback(.ambiguous, sessionID: sessionID)
        case .failed(let reason):
            return presentFallback(.failed(.resolution(reason)), sessionID: sessionID)
        case .target(let target):
            return launch(target: target, sessionID: sessionID)
        }
    }

    private func launch(target: TerminalLinkTarget,
                        sessionID: String) -> TerminalLaunchOutcome {
        var automationFailure: TerminalAutomationError?
        if target.supportsExactTargeting,
           let tty = target.tty,
           let application = target.ownerApplication {
            switch exactTargeter.target(tty: tty, application: application) {
            case .targeted:
                return .exact(target)
            case .notFound:
                break
            case .permissionDenied(let error):
                return presentFallback(.permissionDenied(error), sessionID: sessionID)
            case .failed(let error):
                automationFailure = error
            }
        }

        if let ownerProcessID = target.ownerProcessID,
           ownerActivator.activate(processID: ownerProcessID) {
            return .ownerActivated(target)
        }

        let failure = automationFailure.map(TerminalLaunchFailure.automation)
            ?? .noTerminalOwner
        return presentFallback(.failed(failure), sessionID: sessionID)
    }

    private func presentFallback(_ outcome: TerminalLaunchOutcome,
                                 sessionID: String) -> TerminalLaunchOutcome {
        windows.openMainWindow()
        windows.selectSession(id: sessionID)
        windows.revealTranscript(sessionID: sessionID, outcome: outcome)
        return outcome
    }
}
