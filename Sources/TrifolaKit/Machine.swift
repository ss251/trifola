import Foundation
#if canImport(Glibc)
import Glibc
#endif

// MARK: - Cross-Machine Fleet (the differentiator)
//
// Every competitor sees ONE machine, ONE session, or a cloud. Nobody sees the
// user's actual reality: a FLEET across two Tailscale machines (this Mac +
// `workstation`). This file is the whole cross-machine layer — and it is deliberately
// PURE and doctrine-safe:
//
//   • The fleet = LOCAL (this Mac, machine id "local") + zero-or-more REMOTES.
//   • A remote is mirrored READ-ONLY: rsync-over-ssh pulls a bounded set of recent
//     transcript files into THIS app's own Application Support dir. It NEVER writes
//     the remote `~/.claude`; the remote is only ever an rsync SOURCE, never a sink.
//   • The MERGE + machine-tagging + fleet roll-up is a pure function (`FleetMerge`),
//     unit-tested with a local fixture dir standing in for "machine #2".
//   • The sync command COMPOSITION is a pure function (`RemoteSync.plan`) — its
//     exact rsync/ssh argv (read-only flags + the last-N-days bound) is unit-tested
//     WITHOUT any live network call. Live verification is deferred to the user.
//   • Reachability is a best-effort TCP probe with a HARD deadline — it never hangs,
//     so a down `workstation` degrades to LOCAL-ONLY with a calm "offline" indicator.

// MARK: - Machine identity

/// One machine in the fleet. `local` is this Mac; a remote carries its config name
/// as its id ("workstation"). Tagged onto every `SessionSummary` so a session always
/// knows which machine it ran on.
public struct Machine: Sendable, Hashable, Codable, Identifiable {
    /// Stable machine id — "local" for this Mac, else the remote's config name.
    public let id: String
    /// Display name for the chip ("this Mac" / "workstation").
    public let name: String
    public let isLocal: Bool

    public init(id: String, name: String, isLocal: Bool) {
        self.id = id
        self.name = name
        self.isLocal = isLocal
    }

    /// This Mac — the machine every locally-parsed session is tagged with.
    public static let localID = "local"
    public static let local = Machine(id: localID, name: "this Mac", isLocal: true)

    /// Tight label for the machine chip ("Mac" / the remote name).
    public var chipLabel: String { isLocal ? "Mac" : name }
    /// SF Symbol for the chip — a laptop for local, a desktop for a remote host.
    public var symbol: String { isLocal ? "laptopcomputer" : "desktopcomputer" }
}

// MARK: - Remote config (seeded with workstation, inert until a sync succeeds)

/// A configured remote: a Tailscale host reachable over SSH whose `~/.claude`
/// transcripts we mirror READ-ONLY. Seeded with `workstation` but INERT — it only
/// contributes sessions once a sync has actually mirrored files locally.
public struct RemoteConfig: Sendable, Hashable, Codable, Identifiable {
    /// The machine id / display name ("workstation").
    public var name: String
    /// SSH host (Tailscale MagicDNS name or IP).
    public var host: String
    /// SSH user.
    public var user: String
    /// The remote transcripts root — always `~/.claude/projects` (read-only source).
    public var remotePath: String
    /// Only mirror transcripts modified within the last N days (bounds the pull so
    /// it never drags GBs).
    public var recentDays: Int

    public init(name: String, host: String, user: String,
                remotePath: String = "~/.claude/projects", recentDays: Int = 7) {
        self.name = name
        self.host = host
        self.user = user
        self.remotePath = remotePath
        self.recentDays = recentDays
    }

    public var id: String { name }
    public var machine: Machine { Machine(id: name, name: name, isLocal: false) }
    /// `user@host` — the rsync/ssh target.
    public var sshTarget: String { "\(user)@\(host)" }
}

/// Stable, path-safe machine identifiers. Remote names become directory and
/// transient-file components, so accepting anything broader than this ASCII
/// slug would turn a display label into a filesystem traversal primitive.
public enum MachineNameSlug {
    public static func isValid(_ value: String) -> Bool {
        guard let first = value.utf8.first, isASCIIAlphaNumeric(first) else { return false }
        return value.utf8.dropFirst().allSatisfy {
            isASCIIAlphaNumeric($0) || $0 == 0x2E || $0 == 0x5F || $0 == 0x2D
        }
    }

    private static func isASCIIAlphaNumeric(_ byte: UInt8) -> Bool {
        (0x30...0x39).contains(byte)
            || (0x41...0x5A).contains(byte)
            || (0x61...0x7A).contains(byte)
    }
}

/// The persisted fleet config (JSON in the app's OWN Application Support dir — never
/// `~/.claude`). Seeded with `workstation` on first launch.
public struct MachinesConfig: Sendable, Codable, Equatable {
    public var version: Int
    public var remotes: [RemoteConfig] {
        didSet {
            // The app layer mutates this array directly. Keep the trust boundary
            // in TrifolaKit so an invalid UI/config value never survives long
            // enough to reach createDirectory, the files-list write, or rsync.
            remotes = remotes.filter { MachineNameSlug.isValid($0.name) }
        }
    }

    public init(version: Int = MachinesConfig.currentVersion, remotes: [RemoteConfig]) {
        self.version = version
        self.remotes = remotes.filter { MachineNameSlug.isValid($0.name) }
    }

    public static let currentVersion = 1

    /// The default config: this Mac only, no remotes. Add remotes in Settings —
    /// each is mirrored READ-ONLY and stays inert until a sync mirrors files.
    public static var seeded: MachinesConfig {
        MachinesConfig(remotes: [])
    }
}

/// The durable receipt for one remote mirror. Reachability is deliberately absent:
/// a TCP result from a previous process cannot prove that a host is online now.
/// The current process starts at `.unknown`, while these timestamps explain how old
/// the last local evidence is and what happened on the most recent sync attempt.
public struct RemoteMirrorPersistence: Sendable, Codable, Equatable {
    public var lastAttempt: Date?
    public var lastSuccess: Date?
    public var lastError: String?
    public var mirrorFreshness: Date?

    public init(lastAttempt: Date? = nil,
                lastSuccess: Date? = nil,
                lastError: String? = nil,
                mirrorFreshness: Date? = nil) {
        self.lastAttempt = lastAttempt
        self.lastSuccess = lastSuccess
        self.lastError = lastError
        self.mirrorFreshness = mirrorFreshness
    }
}

/// App-owned, low-frequency runtime receipts keyed by the stable remote slug.
public struct MachinesRuntimeState: Sendable, Codable, Equatable {
    public var remotes: [String: RemoteMirrorPersistence]

    public init(remotes: [String: RemoteMirrorPersistence] = [:]) {
        self.remotes = remotes.filter { MachineNameSlug.isValid($0.key) }
    }
}

/// A short, user-presentable persistence failure. Keeping the path in the error
/// makes Settings' Reveal/Retry surface useful without exposing Foundation errors
/// across every store boundary.
public enum MachinePersistenceError: Error, Sendable, Equatable, LocalizedError {
    case invalidMachineName(String)
    case write(path: String, reason: String)
    case remove(path: String, reason: String)

    public var errorDescription: String? {
        switch self {
        case .invalidMachineName(let name):
            return "Invalid machine name \(name)."
        case .write(let path, let reason):
            return "Could not save \(path): \(reason)"
        case .remove(let path, let reason):
            return "Could not remove \(path): \(reason)"
        }
    }
}

// MARK: - Application Support paths (the read-only mirror lives here, never ~/.claude)

/// Where the cross-machine layer keeps its files — all under the app's OWN
/// Application Support dir. The remote mirrors sit under `remotes/<name>/`; nothing
/// here ever touches `~/.claude` (local) or the remote host beyond a read-only pull.
public enum MachinePaths {
    public enum PathError: Error, Equatable {
        case invalidMachineName(String)
        case escapedRemotesRoot(String)
    }

    public static var appSupport: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Trifola", isDirectory: true)
    }
    public static var configURL: URL {
        appSupport.appendingPathComponent("machines.json")
    }
    public static var runtimeStateURL: URL {
        appSupport.appendingPathComponent("machine-runtime.json")
    }
    /// Root of all remote mirrors.
    public static var remotesRoot: URL {
        appSupport.appendingPathComponent("remotes", isDirectory: true)
    }
    /// The read-only mirror dir for one remote — the parser reads this like a second
    /// `~/.claude/projects`.
    /// Compatibility surface for already-validated/config-owned names. Runtime
    /// input must use `validatedMirror`; invalid values fail closed there.
    public static func mirror(for name: String) -> URL {
        guard let path = try? validatedMirror(for: name) else {
            preconditionFailure("invalid remote machine name or mirror path")
        }
        return path
    }

    public static func validatedMirror(for name: String, root: URL = remotesRoot) throws -> URL {
        try remotePath(component: name, root: root, isDirectory: true)
    }
    /// The transient file list a sync pass feeds to `rsync --files-from`.
    public static func syncListFile(for name: String) -> URL {
        guard let path = try? validatedSyncListFile(for: name) else {
            preconditionFailure("invalid remote machine name or files-list path")
        }
        return path
    }

    public static func validatedSyncListFile(for name: String, root: URL = remotesRoot) throws -> URL {
        guard MachineNameSlug.isValid(name) else { throw PathError.invalidMachineName(name) }
        return try contained(
            root.appendingPathComponent(".\(name).files", isDirectory: false),
            under: root)
    }

    /// Re-check an already-composed path immediately before a create, write, or
    /// rsync invocation. The standardized boundary includes a trailing slash so
    /// sibling prefixes such as `remotes-evil` cannot pass.
    public static func contained(_ candidate: URL, under root: URL = remotesRoot) throws -> URL {
        let base = root.standardizedFileURL
        let child = candidate.standardizedFileURL
        let prefix = base.path.hasSuffix("/") ? base.path : base.path + "/"
        guard child.path.hasPrefix(prefix), child.path != base.path else {
            throw PathError.escapedRemotesRoot(child.path)
        }
        return child
    }

    private static func remotePath(
        component: String,
        root: URL,
        isDirectory: Bool
    ) throws -> URL {
        guard MachineNameSlug.isValid(component) else {
            throw PathError.invalidMachineName(component)
        }
        return try contained(
            root.appendingPathComponent(component, isDirectory: isDirectory),
            under: root)
    }

    /// Load the config, SEEDING it with workstation on first run (idempotent).
    public static func loadConfig(from url: URL = configURL) -> MachinesConfig {
        if let data = try? Data(contentsOf: url),
           let cfg = try? JSONDecoder().decode(MachinesConfig.self, from: data) {
            let valid = cfg.remotes.filter { MachineNameSlug.isValid($0.name) }
            return MachinesConfig(version: cfg.version, remotes: valid)
        }
        let seed = MachinesConfig.seeded
        _ = saveConfig(seed, to: url)
        return seed
    }

    /// Persist configuration atomically and return the actual outcome so callers
    /// never publish a host change that disk rejected.
    @discardableResult
    public static func saveConfig(_ cfg: MachinesConfig,
                                  to url: URL = configURL) -> Result<Void, MachinePersistenceError> {
        guard cfg.remotes.allSatisfy({ MachineNameSlug.isValid($0.name) }) else {
            let invalid = cfg.remotes.first { !MachineNameSlug.isValid($0.name) }?.name ?? ""
            return .failure(.invalidMachineName(invalid))
        }
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(cfg).write(to: url, options: .atomic)
            return .success(())
        } catch {
            return .failure(.write(path: url.path, reason: error.localizedDescription))
        }
    }

    public static func loadRuntimeState(from url: URL = runtimeStateURL) -> MachinesRuntimeState {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        guard let data = try? Data(contentsOf: url),
              let state = try? decoder.decode(MachinesRuntimeState.self, from: data)
        else { return MachinesRuntimeState() }
        return state
    }

    @discardableResult
    public static func saveRuntimeState(_ state: MachinesRuntimeState,
                                        to url: URL = runtimeStateURL) -> Result<Void, MachinePersistenceError> {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                    withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .iso8601
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            try encoder.encode(state).write(to: url, options: .atomic)
            return .success(())
        } catch {
            return .failure(.write(path: url.path, reason: error.localizedDescription))
        }
    }

    /// True once a remote's mirror dir exists AND holds at least one transcript —
    /// i.e. a sync has actually succeeded. Until then the remote is INERT (configured
    /// but contributing nothing), exactly as the seed requires.
    public static func mirrorHasContent(for name: String, root: URL = remotesRoot) -> Bool {
        guard let dir = try? validatedMirror(for: name, root: root) else { return false }
        guard let en = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil,
                                                      options: [.skipsHiddenFiles]) else { return false }
        for case let u as URL in en where u.pathExtension == "jsonl" { return true }
        return false
    }

    /// Newest on-disk transcript modification. This is mirror freshness, not host
    /// liveness and not the time the app happened to launch.
    public static func mirrorFreshness(for name: String, root: URL = remotesRoot) -> Date? {
        guard let dir = try? validatedMirror(for: name, root: root),
              let en = FileManager.default.enumerator(
                at: dir,
                includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
                options: [.skipsHiddenFiles])
        else { return nil }
        var newest: Date?
        for case let url as URL in en where url.pathExtension == "jsonl" {
            guard let values = try? url.resourceValues(forKeys: [.contentModificationDateKey,
                                                                 .isRegularFileKey]),
                  values.isRegularFile == true,
                  let modified = values.contentModificationDate else { continue }
            if newest == nil || modified > newest! { newest = modified }
        }
        return newest
    }

    /// Logical bytes retained under the local mirror, used by the removal
    /// confirmation. Missing/unreadable files contribute zero rather than making
    /// the confirmation itself fail.
    public static func mirrorSize(for name: String, root: URL = remotesRoot) -> UInt64 {
        guard let dir = try? validatedMirror(for: name, root: root),
              let en = FileManager.default.enumerator(
                at: dir,
                includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey],
                options: [.skipsHiddenFiles])
        else { return 0 }
        var bytes: UInt64 = 0
        for case let url as URL in en {
            guard let values = try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]),
                  values.isRegularFile == true,
                  let size = values.fileSize,
                  size > 0 else { continue }
            bytes += UInt64(size)
        }
        return bytes
    }

    /// Remove only app-owned local copies (mirror + transient rsync file list).
    /// The remote source is never touched.
    @discardableResult
    public static func removeMirror(for name: String,
                                    root: URL = remotesRoot) -> Result<Void, MachinePersistenceError> {
        guard MachineNameSlug.isValid(name) else {
            return .failure(.invalidMachineName(name))
        }
        do {
            let fm = FileManager.default
            let mirror = try validatedMirror(for: name, root: root)
            let list = try validatedSyncListFile(for: name, root: root)
            if fm.fileExists(atPath: mirror.path) { try fm.removeItem(at: mirror) }
            if fm.fileExists(atPath: list.path) { try fm.removeItem(at: list) }
            return .success(())
        } catch let error as MachinePersistenceError {
            return .failure(error)
        } catch {
            let path = (try? validatedMirror(for: name, root: root))?.path ?? name
            return .failure(.remove(path: path, reason: error.localizedDescription))
        }
    }
}

// MARK: - The sync command composition (PURE — no live call)

/// Composes the exact rsync/ssh argv that mirrors a remote's recent transcripts
/// READ-ONLY into the local mirror. Nothing here runs a process; the argv is a
/// value that `SyncRunner` (app side) executes and tests assert on. Live
/// verification against a real `workstation` is deferred to the user.
public enum RemoteSync {
    /// SSH connect timeout — short so a down host fails fast instead of hanging.
    public static let connectTimeoutSeconds = 8

    /// SSH options shared by the list + pull steps: a bounded connect, batch mode
    /// (never blocks on a password prompt), and auto-accepting a new Tailscale host
    /// key. `BatchMode=yes` is the graceful-degradation guarantee — a down or
    /// unknown host errors out immediately, it never sits waiting for input.
    public static func sshOptions(timeout: Int = connectTimeoutSeconds) -> [String] {
        ["-o", "ConnectTimeout=\(timeout)",
         "-o", "BatchMode=yes",
         "-o", "StrictHostKeyChecking=accept-new"]
    }

    /// The `-e` transport string rsync uses for its ssh tunnel.
    public static func sshTransport(timeout: Int = connectTimeoutSeconds) -> String {
        (["ssh"] + sshOptions(timeout: timeout)).joined(separator: " ")
    }

    /// A two-step sync plan. rsync cannot filter by mtime, so step 1 enumerates the
    /// recently-modified transcripts on the remote (the last-N-days BOUND) and step 2
    /// pulls exactly those files, read-only, into the local mirror.
    public struct Plan: Sendable, Equatable {
        /// `ssh … find … -mtime -N …` — lists recent transcript paths on the remote.
        public let list: [String]
        /// `rsync … --files-from=<list> <remote>:/ <mirror>` — the read-only pull.
        public let pull: [String]

        public init(list: [String], pull: [String]) {
            self.list = list
            self.pull = pull
        }
    }

    /// Build the plan for `remote`, mirroring into `mirror`, driving rsync's
    /// `--files-from` off `listFile`.
    ///
    /// Read-only guarantees encoded here (asserted by tests):
    ///  • the remote appears ONLY as an rsync SOURCE (`user@host:/`), never a dest;
    ///  • no `--remove-source-files` / no delete-on-remote flag is ever emitted;
    ///  • the destination is always the LOCAL mirror dir.
    /// Bound guarantee: the list step carries `-mtime -N` so only the last N days of
    /// transcripts are ever enumerated (and therefore pulled).
    public static func plan(remote: RemoteConfig, mirror: URL, listFile: URL,
                            timeout: Int = connectTimeoutSeconds) -> Plan {
        do {
            return try validatedPlan(
                remote: remote, mirror: mirror, listFile: listFile,
                timeout: timeout)
        } catch {
            preconditionFailure("unsafe remote sync plan: \(error)")
        }
    }

    public static func validatedPlan(
        remote: RemoteConfig,
        mirror: URL,
        listFile: URL,
        remotesRoot: URL = MachinePaths.remotesRoot,
        timeout: Int = connectTimeoutSeconds
    ) throws -> Plan {
        guard MachineNameSlug.isValid(remote.name) else {
            throw MachinePaths.PathError.invalidMachineName(remote.name)
        }
        let mirror = try MachinePaths.contained(mirror, under: remotesRoot)
        let listFile = try MachinePaths.contained(listFile, under: remotesRoot)
        let opts = sshOptions(timeout: timeout)

        // Step 1 — enumerate recent transcripts on the remote. The remote shell
        // expands `~` before find runs, so find prints absolute paths. `-mtime -N`
        // is the day bound; `-type f` + the `.jsonl` glob keep it to transcripts.
        let list: [String] =
            ["ssh"] + opts + [
                remote.sshTarget,
                "find", remote.remotePath,
                "-name", "*.jsonl",
                "-type", "f",
                "-mtime", "-\(remote.recentDays)"
            ]

        // Step 2 — pull exactly the enumerated files, read-only, into the mirror.
        //   -a  archive (perms/times), -z compress
        //   --files-from  the enumerated list (bounded set — never the whole tree)
        //   --relative + --no-implied-dirs  reproduce the remote tree under mirror
        //   -e  the bounded-timeout ssh transport
        // The remote (`:/`) is the SOURCE; `mirror.path` is the DEST. There is
        // intentionally NO --remove-source-files and NO remote-side deletion.
        let pull: [String] = [
            "rsync",
            "-az",
            "--relative",
            "--no-implied-dirs",
            "--prune-empty-dirs",
            "--files-from=\(listFile.path)",
            "-e", sshTransport(timeout: timeout),
            "\(remote.sshTarget):/",
            mirror.path
        ]
        return Plan(list: list, pull: pull)
    }
}

// MARK: - Reachability (best-effort, hard-deadline, never hangs)

/// A best-effort reachability probe. Used only by `--selfcheck` and the background
/// sync scheduler — NEVER on the merge path — so an unreachable `workstation` can never
/// block the UI. The probe runs on a background queue and is bounded by a hard
/// deadline, so even a stalled DNS lookup returns `.unknown` on time.
public enum MachineReachability {
    public enum Status: String, Sendable, Codable, Equatable {
        case reachable, unreachable, unknown
    }

    /// Probe `host:port` with a hard `timeoutMs` deadline. Returns within
    /// ~timeoutMs+250ms no matter what (a hung getaddrinfo yields `.unknown`).
    public static func probe(
        host: String,
        port: Int32 = 22,
        timeoutMs: Int = 2000,
        coordinator: ProviderRefreshCoordinator = .shared
    ) -> Status {
        let done = DispatchSemaphore(value: 0)
        let outcome = Locked<Status>(.unknown)
        Task.detached(priority: .utility) {
            let refreshProbe = ProviderRefreshProbe(id: "machine.\(host):\(port)") {
                let status = directProbe(host: host, port: port, timeoutMs: timeoutMs)
                outcome.withLock { $0 = status }
            }
            _ = await coordinator.refresh([refreshProbe])
            done.signal()
        }
        // The public synchronous seam remains hard-bounded for existing callers.
        // If another provider batch owns the flight, this returns UNKNOWN instead
        // of waiting on or overlapping it.
        guard done.wait(timeout: .now() + .milliseconds(timeoutMs + 250)) == .success else {
            return .unknown
        }
        return outcome.withLock { $0 }
    }

    private static func directProbe(host: String, port: Int32, timeoutMs: Int) -> Status {
        let sem = DispatchSemaphore(value: 0)
        let box = Locked<Status>(.unknown)
        DispatchQueue.global(qos: .userInitiated).async {
            let r = tcpConnect(host: host, port: port, timeoutMs: timeoutMs)
            box.withLock { $0 = r }
            sem.signal()
        }
        // Hard ceiling: even if the socket work stalls, we stop waiting here.
        if sem.wait(timeout: .now() + .milliseconds(timeoutMs + 250)) == .timedOut {
            return .unknown
        }
        return box.withLock { $0 }
    }

    /// A single non-blocking TCP connect bounded by `poll()` — cleaner and more
    /// portable than select() (millisecond timeout, no fd_set macros). No hang: the
    /// connect is non-blocking and poll carries the deadline.
    private static func tcpConnect(host: String, port: Int32, timeoutMs: Int) -> Status {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = SOCK_STREAM
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, String(port), &hints, &res) == 0, let info = res else {
            return .unreachable
        }
        defer { freeaddrinfo(res) }

        var ai: UnsafeMutablePointer<addrinfo>? = info
        while let cur = ai {
            let fd = socket(cur.pointee.ai_family, cur.pointee.ai_socktype, cur.pointee.ai_protocol)
            if fd < 0 { ai = cur.pointee.ai_next; continue }

            // Non-blocking so connect returns immediately with EINPROGRESS.
            let flags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

            let rc = connect(fd, cur.pointee.ai_addr, cur.pointee.ai_addrlen)
            if rc == 0 { close(fd); return .reachable }        // immediate connect

            if errno == EINPROGRESS {
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let r = poll(&pfd, 1, Int32(timeoutMs))
                if r > 0 {
                    var err: Int32 = 0
                    var len = socklen_t(MemoryLayout<Int32>.size)
                    getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
                    close(fd)
                    if err == 0 { return .reachable }
                    ai = cur.pointee.ai_next                    // refused — try next addr
                    continue
                }
                close(fd)                                       // 0 = timed out, <0 = error
                return .unreachable
            }
            close(fd)
            ai = cur.pointee.ai_next
        }
        return .unreachable
    }
}

// MARK: - Machine roll-up (fleet-wide totals, per machine)

/// One machine's slice of the fleet — the fleet-wide roll-up the Overview shows
/// ("2 machines · N sessions · $X today").
public struct MachineRollup: Sendable, Equatable, Identifiable {
    public let machine: Machine
    public let sessionCount: Int
    public let activeCount: Int
    public let cost: Double
    public let tokens: Int

    public init(machine: Machine, sessionCount: Int, activeCount: Int, cost: Double, tokens: Int) {
        self.machine = machine
        self.sessionCount = sessionCount
        self.activeCount = activeCount
        self.cost = cost
        self.tokens = tokens
    }
    public var id: String { machine.id }
}

/// A live remote source the `SessionStore` merges into the fleet: a machine + the
/// read-only mirror dir the parser scans for it (like a second `~/.claude/projects`).
public struct RemoteSource: Sendable, Equatable {
    public let machine: Machine
    public let dir: URL
    public init(machine: Machine, dir: URL) { self.machine = machine; self.dir = dir }
}

// MARK: - The merge (PURE — the heart of the cross-machine layer)

/// Merges local + remote session summaries into one fleet, tagging each with its
/// machine and rolling the fleet up machine-by-machine. Entirely pure: it takes
/// already-parsed summaries (local from `~/.claude/projects`, remotes from their
/// read-only mirror dirs) and returns the merged, tagged, de-duplicated set. This
/// is what the fixture test drives with a temp dir standing in for machine #2.
public enum FleetMerge {

    /// Merge `local` (already tagged "local") with each remote's summaries, tagging
    /// the remotes with their machine id. De-duplicates by
    /// (provider, machine, session id),
    /// keeping the freshest — so no session is ever double-counted. Ordering is
    /// recency-first across the whole fleet.
    public static func merge(local: [SessionSummary],
                             remotes: [(machine: Machine, sessions: [SessionSummary])]) -> [SessionSummary] {
        var byKey: [String: SessionSummary] = [:]

        func upsert(_ s: SessionSummary, machineID: String) {
            let tagged = s.machineID == machineID ? s : s.taggedWith(machineID)
            // \u{1} can't occur in a machine id or a session id, so it is a safe
            // composite key — a subagent id already contains "/", the machine id
            // does not, so the two never collide.
            let key = "\(s.provider.rawValue)\u{1}\(machineID)\u{1}\(s.id)"
            if let existing = byKey[key] {
                let a = existing.lastActivity ?? .distantPast
                let b = tagged.lastActivity ?? .distantPast
                if b >= a { byKey[key] = tagged }
            } else {
                byKey[key] = tagged
            }
        }

        for s in local { upsert(s, machineID: Machine.localID) }
        for r in remotes { for s in r.sessions { upsert(s, machineID: r.machine.id) } }

        return byKey.values.sorted {
            ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast)
        }
    }

    /// Fleet-wide roll-up, one row per machine, in the given machine order. A
    /// machine with no sessions still gets a zero row (so a configured-but-offline
    /// remote shows as "0 · offline" rather than vanishing).
    public static func rollups(_ sessions: [SessionSummary], machines: [Machine]) -> [MachineRollup] {
        var counts: [String: (n: Int, active: Int, cost: Double, tok: Int)] = [:]
        for s in sessions {
            var c = counts[s.machineID] ?? (0, 0, 0, 0)
            c.n += 1
            if s.isActive { c.active += 1 }
            c.cost += s.cost
            c.tok += s.usage.total
            counts[s.machineID] = c
        }
        return machines.map { m in
            let c = counts[m.id] ?? (0, 0, 0, 0)
            return MachineRollup(machine: m, sessionCount: c.n, activeCount: c.active,
                                 cost: c.cost, tokens: c.tok)
        }
    }

    /// Session count per machine id — the compact selfcheck line.
    public static func machineCounts(_ sessions: [SessionSummary]) -> [String: Int] {
        var out: [String: Int] = [:]
        for s in sessions { out[s.machineID, default: 0] += 1 }
        return out
    }

    /// The number of distinct machines that actually contributed a session.
    public static func machineCount(_ sessions: [SessionSummary]) -> Int {
        Set(sessions.map(\.machineID)).count
    }
}

// MARK: - Offline indicator (calm, never a nag)

/// The muted status a remote surfaces when it isn't contributing — "workstation offline
/// — last synced 12m ago". Absence is information (Fleet Board doctrine), rendered
/// calm: never red, never a nag.
public struct RemoteStatus: Sendable, Equatable, Identifiable {
    public let machine: Machine
    public let reachable: MachineReachability.Status
    /// True once the mirror holds transcripts (a sync has succeeded at least once).
    public let hasMirror: Bool
    public let lastSynced: Date?
    public let lastError: String?
    public let sessionCount: Int
    public let lastAttempt: Date?
    public let mirrorFreshness: Date?

    public init(machine: Machine, reachable: MachineReachability.Status, hasMirror: Bool,
                lastSynced: Date?, lastError: String?, sessionCount: Int,
                lastAttempt: Date? = nil, mirrorFreshness: Date? = nil) {
        self.machine = machine
        self.reachable = reachable
        self.hasMirror = hasMirror
        self.lastSynced = lastSynced
        self.lastError = lastError
        self.sessionCount = sessionCount
        self.lastAttempt = lastAttempt
        self.mirrorFreshness = mirrorFreshness
    }
    public var id: String { machine.id }

    /// Online requires evidence from THIS process. A retained mirror plus unknown
    /// reachability is useful local data, but it is never proof that the host is up.
    public var isOnline: Bool { hasMirror && reachable == .reachable }

    /// The one-line indicator text. It names the local mirror separately from live
    /// reachability so a stale copy can never read as a currently-online machine.
    public var indicator: String {
        let freshest = mirrorFreshness ?? lastSynced
        let mirror: String
        if hasMirror {
            mirror = freshest.map { "local mirror updated \(fmtAgo($0))" }
                ?? "local mirror age unknown"
        } else {
            mirror = "no local mirror"
        }
        let failure = lastError.map { error in
            let attempted = lastAttempt.map { " \(fmtAgo($0))" } ?? ""
            return " · last sync attempt\(attempted) failed: \(error)"
        } ?? ""

        switch reachable {
        case .reachable where hasMirror:
            return "\(machine.name) · \(sessionCount) session\(sessionCount == 1 ? "" : "s") · \(mirror)\(failure)"
        case .reachable:
            return "\(machine.name) · SSH port reachable — \(mirror)\(failure)"
        case .unreachable:
            return "\(machine.name) unreachable — \(mirror)\(failure)"
        case .unknown:
            return "\(machine.name) unverified — \(mirror)\(failure)"
        }
    }
}
