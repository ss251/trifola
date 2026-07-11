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

    /// CWDs for many candidate processes. The default preserves compatibility
    /// for fixtures; the system provider overrides this with one `lsof` call so
    /// an external session never waits on N sequential subprocesses.
    func workingDirectories(for processIDs: [Int32]) -> [Int32: String]
}

public extension TerminalProcessSnapshotProviding {
    func workingDirectories(for processIDs: [Int32]) -> [Int32: String] {
        processIDs.reduce(into: [:]) { result, processID in
            guard let output = workingDirectoryOutput(for: processID),
                  let cwd = TerminalLinkResolver.parseWorkingDirectory(output) else { return }
            result[processID] = cwd
        }
    }
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

    public func workingDirectories(for processIDs: [Int32]) -> [Int32: String] {
        guard !processIDs.isEmpty,
              let lsof = ProbePrimitives.firstExecutable(["/usr/sbin/lsof", "/usr/bin/lsof"]),
              let result = ProbePrimitives.runCommand(
                lsof,
                ["-a", "-p", processIDs.map(String.init).joined(separator: ","),
                 "-d", "cwd", "-Fn"],
                timeout: 2
              ), result.status == 0 || !result.stdout.isEmpty else { return [:] }
        guard let output = String(data: result.stdout, encoding: .utf8) else { return [:] }
        return TerminalLinkResolver.parseWorkingDirectories(output)
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
    /// Command of the selected live Claude process. AX scoring uses only small
    /// executable/session hints derived from it; the app never renders it.
    public let processCommand: String?

    public init(processID: Int32, tty: String?, startedAt: Date,
                ownerProcessID: Int32?, ownerApplication: TerminalApplication?,
                match: Match = .cwd, processCommand: String? = nil) {
        self.processID = processID
        self.tty = tty
        self.startedAt = startedAt
        self.ownerProcessID = ownerProcessID
        self.ownerApplication = ownerApplication
        self.match = match
        self.processCommand = processCommand
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

/// One bulk read of the authoritative live registry joined against the process
/// table. The Sessions browser consumes this instead of running a resolver (and
/// therefore `ps`) once per visible row.
public struct TerminalLiveSessionSnapshot: Sendable, Equatable {
    public let sessionIDs: Set<String>
    public let failureReason: String?

    public init(sessionIDs: Set<String>, failureReason: String? = nil) {
        self.sessionIDs = sessionIDs
        self.failureReason = failureReason
    }
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

        let exactRecords = sessionID.isEmpty
            ? [] : records.filter { $0.sessionID == sessionID }
        if !exactRecords.isEmpty {
            let exactPIDs = Set(exactRecords.map(\.processID))
            if exactPIDs.count > 1 { return .ambiguous }
            if let processID = exactPIDs.first {
                guard let process = byPID[processID], process.isClaudeProcess else {
                    // A registry entry whose PID has exited (or been reused by a
                    // different program) is not permission to target a cwd peer.
                    return .failed("Registry entry exists, but its process is no longer live")
                }
                guard Self.isTerminalAttached(process, in: byPID) else {
                    return .failed(
                        "Registry entry exists, but its process is not attached to a live terminal")
                }
                return .target(Self.target(for: process, match: .sessionID, in: byPID))
            }
        }

        guard !cwd.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return sessionID.isEmpty
                ? .notLive : .failed("No registry entry for this session")
        }
        let wantedCWD = Self.normalizedPath(cwd)
        let claudeProcesses = processes.filter {
            $0.isClaudeProcess && Self.isTerminalAttached($0, in: byPID)
        }
        let cwdByPID = snapshots.workingDirectories(
            for: claudeProcesses.map(\.processID))
        let matches = claudeProcesses.filter { process in
            guard let processCWD = cwdByPID[process.processID] else { return false }
            return Self.normalizedPath(processCWD) == wantedCWD
        }

        guard matches.count <= 1 else { return .ambiguous }
        guard let selected = matches.first else {
            return sessionID.isEmpty
                ? .notLive
                : .failed("No registry entry for this session and no live terminal matched its working directory")
        }
        return .target(Self.target(for: selected, match: .cwd, in: byPID))
    }

    /// Exact terminal-attached identities for filtering. CWD fallback is
    /// deliberately absent: it can activate an external terminal owner when a
    /// user opens one selected session, but it cannot honestly identify which of
    /// many historical rows in that directory is live. A live background Claude
    /// daemon is not enough: the process must have both a TTY and an app owner.
    /// Duplicate registry identities are also excluded.
    public func liveRegisteredSessionSnapshot() -> TerminalLiveSessionSnapshot {
        guard let output = snapshots.processListOutput() else {
            return TerminalLiveSessionSnapshot(
                sessionIDs: [], failureReason: "process snapshot unavailable")
        }
        let processes = Self.parseProcessList(output)
        let byPID = processes.reduce(into: [Int32: TerminalProcess]()) {
            $0[$1.processID] = $1
        }

        let records: [TerminalSessionRegistryRecord]
        do {
            records = try registry.records()
        } catch {
            return TerminalLiveSessionSnapshot(
                sessionIDs: [],
                failureReason: "live session registry unavailable: \(error.localizedDescription)")
        }

        let recordsBySession = Dictionary(grouping: records, by: \.sessionID)
        let live = recordsBySession.reduce(into: Set<String>()) { result, entry in
            let processIDs = Set(entry.value.map(\.processID))
            guard processIDs.count == 1,
                  let processID = processIDs.first,
                  let process = byPID[processID],
                  process.isClaudeProcess,
                  Self.isTerminalAttached(process, in: byPID) else { return }
            result.insert(entry.key)
        }
        return TerminalLiveSessionSnapshot(sessionIDs: live)
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
            match: match,
            processCommand: selected.command
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

    /// Parses the `-F` shape emitted by one multi-PID `lsof` call:
    /// `p<PID>`, `fcwd`, `n<path>`, repeated for each process.
    public static func parseWorkingDirectories(_ output: String) -> [Int32: String] {
        var currentPID: Int32?
        var result: [Int32: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            if line.first == "p", let pid = Int32(line.dropFirst()) {
                currentPID = pid
            } else if line.first == "n", line.count > 1, let currentPID {
                result[currentPID] = String(line.dropFirst())
            }
        }
        return result
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
        // Current standalone installs execute a version-named binary beneath
        // `.../claude/versions/<semver>`. Constrain the fallback to that path so
        // an unrelated process whose basename happens to be a version is never
        // classified as Claude.
        if lowered.contains("/claude/versions/") {
            let executable = tokens.first.map { token in
                String(token.split(separator: "/").last ?? token)
            } ?? ""
            if executable.first?.isNumber == true,
               executable.split(separator: ".").count >= 3,
               executable.allSatisfy({ $0.isNumber || $0 == "." }) {
                return true
            }
        }
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

    private static func isTerminalAttached(
        _ process: TerminalProcess,
        in processes: [Int32: TerminalProcess]
    ) -> Bool {
        normalizedTTY(process.tty) != nil && terminalOwner(for: process, in: processes) != nil
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

/// The complete user-facing result of an Open session attempt. These cases are
/// intentionally exhaustive: no AppleScript or resolution failure is reduced to
/// a boolean and silently discarded.
public enum TerminalLaunchOutcome: Sendable, Equatable {
    case exact(TerminalLinkTarget)
    case axTargeted(TerminalLinkTarget, matchedTitle: String)
    /// Accessibility was unavailable and the user chose today's safe fallback:
    /// activate the owning app without claiming an exact workspace.
    case axDenied(TerminalLinkTarget)
    case axNoConfidentMatch(TerminalLinkTarget)
    case axFailed(TerminalLinkTarget, reason: String)
    /// The at-value explainer opened Privacy & Security. Do not front the
    /// terminal or reveal a transcript over System Settings.
    case axSettingsOpened(TerminalLinkTarget)
    case axSettingsOpenFailed(TerminalLinkTarget)
    case ownerActivated(TerminalLinkTarget)
    /// A newer user action superseded this launch. Intentionally silent: the
    /// replacement action owns the visible outcome.
    case cancelled
    case permissionDenied(TerminalAutomationError)
    case notLive
    case ambiguous
    case failed(TerminalLaunchFailure)

    public var fallbackMessage: String? {
        switch self {
        case .exact, .axTargeted, .axDenied, .axNoConfidentMatch,
             .axFailed, .axSettingsOpened, .axSettingsOpenFailed,
             .ownerActivated, .cancelled:
            nil
        case .permissionDenied:
            "Terminal automation permission denied — System Settings → Privacy & Security → Automation; showing transcript"
        case .notLive:
            "No live terminal found — showing transcript"
        case .ambiguous:
            "Multiple live terminals matched — showing transcript"
        case .failed(let failure):
            failure.fallbackMessage
        }
    }

    /// Confirmation shown when a launch SUCCEEDS. Without it, activating a
    /// terminal that is already frontmost (e.g. Ghostty, which has no scriptable
    /// tab for trifola to jump to) produces no visible change — the click reads
    /// as "nothing happened." This makes every successful open acknowledge.
    public var successMessage: String? {
        switch self {
        case .exact(let target):
            if target.match == .cwd {
                "Jumped to \(target.ownerApplication?.displayName ?? "your terminal") using a working-directory match (no registry entry)"
            } else {
                "Jumped to your session in \(target.ownerApplication?.displayName ?? "your terminal")"
            }
        case .axTargeted(let target, let matchedTitle):
            "Jumped to workspace '\(matchedTitle)' in \(target.ownerApplication?.displayName ?? "your terminal")"
        case .axDenied(let target):
            "Grant Accessibility to jump to the exact workspace — fronting \(target.ownerApplication?.displayName ?? "your terminal") instead"
        case .axNoConfidentMatch(let target):
            "No confident workspace match in \(target.ownerApplication?.displayName ?? "your terminal") — brought it to the front instead"
        case .axFailed(let target, let reason):
            "Workspace targeting failed in \(target.ownerApplication?.displayName ?? "your terminal"): \(reason) — brought it to the front instead"
        case .axSettingsOpened:
            "Opened Accessibility settings — grant Trifola access, then try Open session again"
        case .axSettingsOpenFailed(let target):
            "Could not open Accessibility settings — fronting \(target.ownerApplication?.displayName ?? "your terminal") instead"
        case .ownerActivated(let target):
            if target.match == .cwd {
                "Brought \(target.ownerApplication?.displayName ?? "your terminal") to the front using a working-directory match (no registry entry)"
            } else {
                "Brought \(target.ownerApplication?.displayName ?? "your terminal") to the front"
            }
        case .cancelled, .permissionDenied, .notLive, .ambiguous, .failed:
            nil
        }
    }
}

public enum TerminalLaunchFailure: Sendable, Equatable {
    case resolution(String)
    case automation(TerminalAutomationError)
    case noTerminalOwner
    case ownerActivationFailed(TerminalApplication?)

    public var fallbackMessage: String {
        switch self {
        case .resolution(let reason):
            "\(reason) — showing transcript"
        case .automation(let error):
            "Terminal automation failed: \(error.message) — showing transcript"
        case .noTerminalOwner:
            "Live process found, but no owning terminal app was identified — showing transcript"
        case .ownerActivationFailed(let application):
            "\(application?.displayName ?? "Terminal") was found but could not be brought forward — showing transcript"
        }
    }
}

@MainActor
public protocol TerminalOwnerActivating: AnyObject {
    func activate(processID: Int32, application: TerminalApplication?) async -> Bool
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
    private let scriptTargeter: any WorkspaceTargeting
    private let axTargeter: any WorkspaceTargeting
    private let ownerActivator: any TerminalOwnerActivating
    private let windows: any TerminalWindowAdapting

    public init(resolver: any TerminalLinkResolving,
                scriptTargeter: any WorkspaceTargeting,
                axTargeter: any WorkspaceTargeting,
                ownerActivator: any TerminalOwnerActivating,
                windows: any TerminalWindowAdapting) {
        self.resolver = resolver
        self.scriptTargeter = scriptTargeter
        self.axTargeter = axTargeter
        self.ownerActivator = ownerActivator
        self.windows = windows
    }

    @discardableResult
    public func open(sessionID: String, cwd: String, project: String = "",
                     sessionName: String? = nil,
                     gitBranch: String? = nil,
                     machineID: String) async -> TerminalLaunchOutcome {
        guard !Task.isCancelled else { return .cancelled }
        guard machineID == Machine.localID else {
            return presentFallback(.notLive, sessionID: sessionID)
        }

        let resolver = self.resolver
        let resolution = await Task.detached(priority: .userInitiated) {
            resolver.resolve(sessionID: sessionID, cwd: cwd, machineID: machineID)
        }.value
        guard !Task.isCancelled else { return .cancelled }

        switch resolution {
        case .notLive:
            return presentFallback(.notLive, sessionID: sessionID)
        case .ambiguous:
            return presentFallback(.ambiguous, sessionID: sessionID)
        case .failed(let reason):
            return presentFallback(.failed(.resolution(reason)), sessionID: sessionID)
        case .target(let target):
            let request = WorkspaceTargetRequest(
                target: target,
                sessionID: sessionID,
                sessionName: sessionName,
                cwd: cwd,
                project: project,
                gitBranch: gitBranch)
            return await launch(
                target: target, request: request, sessionID: sessionID)
        }
    }

    private func launch(target: TerminalLinkTarget,
                        request: WorkspaceTargetRequest,
                        sessionID: String) async -> TerminalLaunchOutcome {
        guard !Task.isCancelled else { return .cancelled }
        var automationFailure: TerminalAutomationError?
        if target.supportsExactTargeting {
            switch await scriptTargeter.target(request) {
            case .targeted:
                return Task.isCancelled ? .cancelled : .exact(target)
            case .notFound, .noConfidentMatch, .settingsOpened,
                 .settingsOpenFailed:
                break
            case .permissionDenied(.automation(let error)):
                return presentFallback(
                    .permissionDenied(error), sessionID: sessionID)
            case .permissionDenied(.accessibility):
                break
            case .failed(.automation(let error)):
                automationFailure = error
            case .failed(.accessibility(let reason)):
                automationFailure = TerminalAutomationError(
                    number: nil,
                    message: reason,
                    dictionary: ["stage": "script-targeting"])
            }
        } else if target.ownerProcessID != nil {
            let result = await axTargeter.target(request)
            guard !Task.isCancelled else { return .cancelled }
            switch result {
            case .settingsOpened:
                return .axSettingsOpened(target)
            case .settingsOpenFailed:
                return await activateOwner(
                    target: target,
                    success: .axSettingsOpenFailed(target),
                    sessionID: sessionID)
            case .targeted(let matchedTitle):
                let title = matchedTitle?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if !title.isEmpty {
                    return await activateAndVerifyAX(
                        target: target,
                        request: request,
                        matchedTitle: title,
                        sessionID: sessionID)
                }
                return await activateOwner(
                    target: target,
                    success: .axNoConfidentMatch(target),
                    sessionID: sessionID)
            case .notFound, .noConfidentMatch:
                return await activateOwner(
                    target: target,
                    success: .axNoConfidentMatch(target),
                    sessionID: sessionID)
            case .permissionDenied(.accessibility):
                return await activateOwner(
                    target: target,
                    success: .axDenied(target),
                    sessionID: sessionID)
            case .permissionDenied(.automation(let error)):
                return await activateOwner(
                    target: target,
                    success: .axFailed(target, reason: error.message),
                    sessionID: sessionID)
            case .failed(.accessibility(let reason)):
                return await activateOwner(
                    target: target,
                    success: .axFailed(target, reason: reason),
                    sessionID: sessionID)
            case .failed(.automation(let error)):
                return await activateOwner(
                    target: target,
                    success: .axFailed(target, reason: error.message),
                    sessionID: sessionID)
            }
        }

        if let ownerProcessID = target.ownerProcessID {
            let activated = await ownerActivator.activate(
                processID: ownerProcessID,
                application: target.ownerApplication)
            guard !Task.isCancelled else { return .cancelled }
            if activated {
                return .ownerActivated(target)
            }
            return presentFallback(
                .failed(.ownerActivationFailed(target.ownerApplication)),
                sessionID: sessionID)
        }

        let failure = automationFailure.map(TerminalLaunchFailure.automation)
            ?? .noTerminalOwner
        return presentFallback(.failed(failure), sessionID: sessionID)
    }

    private func activateOwner(
        target: TerminalLinkTarget,
        success: TerminalLaunchOutcome,
        sessionID: String
    ) async -> TerminalLaunchOutcome {
        guard let ownerProcessID = target.ownerProcessID else {
            return presentFallback(
                .failed(.noTerminalOwner), sessionID: sessionID)
        }
        let activated = await ownerActivator.activate(
            processID: ownerProcessID,
            application: target.ownerApplication)
        guard !Task.isCancelled else { return .cancelled }
        guard activated else {
            return presentFallback(
                .failed(.ownerActivationFailed(target.ownerApplication)),
                sessionID: sessionID)
        }
        return success
    }

    private func activateAndVerifyAX(
        target: TerminalLinkTarget,
        request: WorkspaceTargetRequest,
        matchedTitle: String,
        sessionID: String
    ) async -> TerminalLaunchOutcome {
        guard let ownerProcessID = target.ownerProcessID else {
            return presentFallback(
                .failed(.noTerminalOwner), sessionID: sessionID)
        }
        let activated = await ownerActivator.activate(
            processID: ownerProcessID,
            application: target.ownerApplication)
        guard !Task.isCancelled else { return .cancelled }
        guard activated else {
            return presentFallback(
                .failed(.ownerActivationFailed(target.ownerApplication)),
                sessionID: sessionID)
        }

        let verification = await axTargeter.verify(
            request, matchedTitle: matchedTitle)
        guard !Task.isCancelled else { return .cancelled }
        switch verification {
        case .verified:
            return .axTargeted(target, matchedTitle: matchedTitle)
        case .unavailable:
            return .axFailed(
                target,
                reason: "Workspace selection could not be verified after activation")
        case .failed(let reason):
            return .axFailed(target, reason: reason)
        }
    }

    private func presentFallback(_ outcome: TerminalLaunchOutcome,
                                 sessionID: String) -> TerminalLaunchOutcome {
        windows.openMainWindow()
        windows.selectSession(id: sessionID)
        windows.revealTranscript(sessionID: sessionID, outcome: outcome)
        return outcome
    }
}
