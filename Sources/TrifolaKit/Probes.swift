import Foundation
import Darwin

// MARK: - Probe vocabulary

/// Health of one tool in the stack.
public enum ProbeStatus: String, Sendable, Equatable, CaseIterable {
    case up          // fully operational
    case degraded    // reachable but partially configured / some channels off
    case down        // installed but not running / not reachable
    case unknown     // probe errored or timed out — never blocks the UI
}

/// What a probe learned. `detail` is the one-line headline; `metrics` are
/// small label/value pairs rendered under it (e.g. "channels" → "11/13 ok").
public struct ProbeResult: Sendable, Equatable {
    public var status: ProbeStatus
    public var detail: String
    public var metrics: [(label: String, value: String)]
    public var latencyMs: Int

    public init(status: ProbeStatus, detail: String,
                metrics: [(label: String, value: String)] = [], latencyMs: Int = 0) {
        self.status = status
        self.detail = detail
        self.metrics = metrics
        self.latencyMs = latencyMs
    }

    public static func == (l: ProbeResult, r: ProbeResult) -> Bool {
        l.status == r.status && l.detail == r.detail && l.latencyMs == r.latencyMs
            && l.metrics.map(\.label) == r.metrics.map(\.label)
            && l.metrics.map(\.value) == r.metrics.map(\.value)
    }
}

/// One entry in the stack. Adding a probe = one struct + one line in
/// `ToolProbeEngine.defaultProbes`.
public protocol ToolProbe: Sendable {
    var id: String { get }
    var name: String { get }
    var subtitle: String { get }
    var symbolName: String { get }
    func check() async -> ProbeResult
}

// MARK: - Engine

/// Runs every probe concurrently, clamps each to a timeout, and never throws.
/// A probe that hangs comes back `.unknown` — the stack screen always renders.
public enum ToolProbeEngine {

    public static let perProbeTimeout: Duration = .seconds(6)

    public static func run(
        _ probes: [any ToolProbe],
        timeout: Duration = perProbeTimeout,
        coordinator: ProviderRefreshCoordinator = .shared
    ) async -> [String: ProbeResult] {
        let results = Locked<[String: ProbeResult]>([:])
        let refreshProbes = probes.map { probe in
            ProviderRefreshProbe(id: "stack.\(probe.id)") {
                let start = ContinuousClock.now
                let result = await withTimeout(timeout, fallback: ProbeResult(
                    status: .unknown, detail: "probe timed out")) {
                    await probe.check()
                }
                let elapsed = start.duration(to: .now)
                var stamped = result
                stamped.latencyMs = Int(elapsed.components.seconds) * 1000
                    + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
                results.withLock { $0[probe.id] = stamped }
            }
        }
        let batch = await coordinator.refresh(refreshProbes)
        let skipped = Set(batch.skippedProbeIDs)
        return results.withLock { captured in
            var out = captured
            for probe in probes where out[probe.id] == nil {
                let refreshID = "stack.\(probe.id)"
                let detail = skipped.contains(refreshID)
                    ? "probe skipped — hard ceiling of \(ProviderRefreshCoordinator.hardProbeCeiling)"
                    : "probe coalesced with an in-flight provider batch"
                out[probe.id] = ProbeResult(status: .unknown, detail: detail)
            }
            return out
        }
    }

    /// Race `work` against a clock; whoever finishes first wins.
    static func withTimeout<T: Sendable>(_ timeout: Duration, fallback: T,
                                         _ work: @escaping @Sendable () async -> T) async -> T {
        await withTaskGroup(of: T?.self) { group in
            group.addTask { await work() }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first ?? fallback
        }
    }
}

// MARK: - Cheap primitives shared by probes

public enum ProbePrimitives {

    /// Non-blocking TCP connect with a hard deadline. No Network.framework
    /// spin-up cost — one socket, one poll, done.
    public nonisolated static func tcpPortOpen(host: String = "127.0.0.1",
                                               port: UInt16,
                                               timeoutMs: Int32 = 400) -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }

        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        guard inet_pton(AF_INET, host, &addr.sin_addr) == 1 else { return false }

        let rc = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        if rc == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, timeoutMs) > 0, pfd.revents & Int16(POLLOUT) != 0 else { return false }

        var err: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
        return err == 0
    }

    /// Short shell-out with output capture. Returns nil on launch failure.
    /// The engine's timeout covers runaway children; we also reap on cancel.
    ///
    /// `timeout` is an optional hard deadline on waiting for the child (default
    /// `nil` = today's unbounded behavior, byte-for-byte, for every existing
    /// caller). When set, the read + wait run on a background queue; if the
    /// deadline passes, the child is `terminate()`d and this returns `nil`
    /// (indistinguishable from a launch failure — callers already treat `nil`
    /// as "probe unavailable"). Some subprocesses (e.g. `security` blocked on
    /// a keychain ACL prompt) can outlive the terminate signal briefly; the
    /// caller is never blocked past the deadline either way.
    public nonisolated static func runCommand(_ binary: String, _ args: [String],
                                              environment: [String: String]? = nil,
                                              timeout: TimeInterval? = nil) -> (status: Int32, stdout: Data)? {
        guard FileManager.default.isExecutableFile(atPath: binary) else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: binary)
        p.arguments = args
        if let environment {
            p.environment = ProcessInfo.processInfo.environment.merging(environment) { _, new in new }
        }
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return nil }

        guard let timeout else {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, data)
        }

        let box = Locked<(status: Int32, stdout: Data)?>(nil)
        let done = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .utility).async {
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            box.withLock { $0 = (p.terminationStatus, data) }
            done.signal()
        }
        if done.wait(timeout: .now() + timeout) == .timedOut {
            p.terminate()
            return nil
        }
        return box.withLock { $0 }
    }

    /// First executable among candidates — GUI apps don't inherit shell PATH,
    /// so probes must spell out where CLIs live.
    public nonisolated static func firstExecutable(_ candidates: [String]) -> String? {
        candidates
            .map { ($0 as NSString).expandingTildeInPath }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }
}

// MARK: - Concrete probes

/// Claude Code's own config root — the directory everything else in this app
/// reads from. If `~/.claude` is missing, there is nothing else to probe.
public struct ClaudeConfigProbe: ToolProbe {
    public let id = "claude"
    public let name = "Claude Code"
    public let subtitle = "Claude config root"
    public let symbolName = "terminal"
    public var directory: String

    public init(directory: String = ClaudePaths.process.root.path) {
        self.directory = directory
    }

    public func check() async -> ProbeResult {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: directory, isDirectory: &isDir), isDir.boolValue else {
            return ProbeResult(status: .down, detail: "Claude config root not found — Claude Code isn't set up here")
        }
        let entries = (try? fm.contentsOfDirectory(atPath: directory)) ?? []
        return ProbeResult(status: .up, detail: "config present",
                           metrics: [("entries", "\(entries.count)")])
    }
}

/// ~/.claude/skills — how big is the toolbox, and what changed last?
public struct SkillsProbe: ToolProbe {
    public let id = "skills"
    public let name = "Skills"
    public let subtitle = "Claude user skills"
    public let symbolName = "wand.and.stars"
    public var directory: String

    public init(directory: String = ClaudePaths.process.skills.path) {
        self.directory = directory
    }

    public func check() async -> ProbeResult {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: directory) else {
            return ProbeResult(status: .down, detail: "skills directory missing")
        }
        let skills = entries.filter { !$0.hasPrefix(".") }
        guard !skills.isEmpty else {
            return ProbeResult(status: .degraded, detail: "no skills installed")
        }
        // Most recently touched skill = the one the fleet is actually using.
        let newest = skills
            .compactMap { name -> (String, Date)? in
                let path = (directory as NSString).appendingPathComponent(name)
                guard let mtime = (try? fm.attributesOfItem(atPath: path))?[.modificationDate] as? Date
                else { return nil }
                return (name, mtime)
            }
            .max { $0.1 < $1.1 }
        var metrics: [(String, String)] = []
        if let newest { metrics.append(("freshest", newest.0)) }
        return ProbeResult(status: .up, detail: "\(skills.count) skills installed", metrics: metrics)
    }
}

// MARK: - Config-surface health (VISION 2.4) — MCP servers · hooks · plugins
//
// The workflow's failure points are invisible until a session mysteriously lacks a
// tool. These three surfaces read the on-disk config (~/.claude.json mcpServers,
// ~/.claude/settings.json hooks, installed_plugins.json) and make the rot visible.
//
// Each is split into a PURE parse (JSON → configs) + a PURE classify (configs →
// statuses) that takes an injected resolver, so the whole config→result mapping is
// testable without touching the live machine. HONEST LIMIT (phase 1): a resolving
// command means the binary/script is present — NOT that the server actually
// handshakes (that needs spawning it). The labels say so.

/// A command name is "present" if it resolves to something runnable. A path
/// (contains "/") is checked directly; a bare name is searched across the process
/// PATH plus a curated set of GUI-fallback dirs — a windowed app inherits no shell
/// PATH, so probes must spell out where CLIs live (same reason `firstExecutable`
/// exists). Pure given the dir list.
public extension ProbePrimitives {
    /// Common user/system bin dirs to search when a GUI app has no inherited PATH.
    static let fallbackBinDirs: [String] = [
        "~/.local/bin", "~/.bun/bin", "~/.cargo/bin", "~/go/bin", "~/.deno/bin",
        "~/.pyenv/shims", "~/.nvm/current/bin", "/opt/homebrew/bin", "/opt/homebrew/sbin",
        "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"
    ]

    nonisolated static func commandResolves(_ command: String) -> Bool {
        let cmd = command.trimmingCharacters(in: .whitespaces)
        guard !cmd.isEmpty else { return false }
        let fm = FileManager.default
        if cmd.contains("/") {
            return fm.isExecutableFile(atPath: (cmd as NSString).expandingTildeInPath)
        }
        let pathDirs = (ProcessInfo.processInfo.environment["PATH"] ?? "")
            .split(separator: ":").map(String.init)
        for dir in pathDirs + fallbackBinDirs {
            let full = ((dir as NSString).expandingTildeInPath as NSString)
                .appendingPathComponent(cmd)
            if fm.isExecutableFile(atPath: full) { return true }
        }
        return false
    }
}

// MARK: MCP servers (~/.claude.json → mcpServers)

public struct MCPServerConfig: Sendable, Equatable {
    public let name: String
    public let transport: String     // "stdio" | "http" | "sse" | "unknown"
    public let command: String?      // stdio launch command
    public let url: String?          // http/sse endpoint

    public init(name: String, transport: String, command: String?, url: String?) {
        self.name = name; self.transport = transport; self.command = command; self.url = url
    }
}

public enum MCPServerHealthStatus: String, Sendable, Equatable {
    case present   // stdio command resolves on disk / PATH
    case missing   // stdio command declared but not found
    case remote    // http/sse — a URL, no local binary to check (phase-1 honest)
    case unknown   // stdio but no command declared (malformed)
}

public struct MCPServerHealth: Sendable, Equatable {
    public let name: String
    public let transport: String
    public let command: String?
    public let url: String?
    public let status: MCPServerHealthStatus

    public init(name: String, transport: String, command: String?, url: String?,
                status: MCPServerHealthStatus) {
        self.name = name; self.transport = transport; self.command = command
        self.url = url; self.status = status
    }
}

public enum MCPConfig {
    /// `~/.claude.json` → `mcpServers`. Pure parse (JSON → configs), sorted by name.
    public nonisolated static func parse(_ data: Data) -> [MCPServerConfig] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let servers = root["mcpServers"] as? [String: Any] else { return [] }
        return servers.compactMap { name, value -> MCPServerConfig? in
            guard let d = value as? [String: Any] else { return nil }
            let url = d["url"] as? String
            let cmd = d["command"] as? String
            let transport = (d["type"] as? String)
                ?? (url != nil ? "http" : (cmd != nil ? "stdio" : "unknown"))
            return MCPServerConfig(name: name, transport: transport, command: cmd, url: url)
        }.sorted { $0.name < $1.name }
    }

    /// Pure config → statuses: presence check ONLY (phase 1 — NOT a live handshake).
    public nonisolated static func classify(_ servers: [MCPServerConfig],
                                            resolves: (String) -> Bool) -> [MCPServerHealth] {
        servers.map { s in
            let status: MCPServerHealthStatus
            if let cmd = s.command, !cmd.isEmpty {
                status = resolves(cmd) ? .present : .missing
            } else if s.url != nil {
                status = .remote
            } else {
                status = .unknown
            }
            return MCPServerHealth(name: s.name, transport: s.transport,
                                   command: s.command, url: s.url, status: status)
        }
    }

    public nonisolated static func summary(_ h: [MCPServerHealth])
        -> (present: Int, missing: Int, remote: Int) {
        (h.filter { $0.status == .present }.count,
         h.filter { $0.status == .missing }.count,
         h.filter { $0.status == .remote }.count)
    }

    /// Pure health → ProbeCard result, shared by the live probe + the render, so the
    /// card the render shows is the exact one the app draws.
    public nonisolated static func probeResult(_ health: [MCPServerHealth]) -> ProbeResult {
        guard !health.isEmpty else {
            return ProbeResult(status: .degraded, detail: "no MCP servers configured")
        }
        let (present, missing, remote) = summary(health)
        let status: ProbeStatus = missing > 0 ? .degraded : .up
        let parts = ["\(present) present", missing > 0 ? "\(missing) missing" : nil,
                     remote > 0 ? "\(remote) remote" : nil].compactMap { $0 }
        let detail = "\(health.count) configured · \(parts.joined(separator: " · ")) · presence only, not a live handshake"
        let metrics: [(String, String)] = health.map { h in
            let v: String
            switch h.status {
            case .present: v = "\(h.command ?? "?") · binary present"
            case .missing: v = "\(h.command ?? "?") · binary missing"
            case .remote:  v = "\(h.transport) · remote endpoint"
            case .unknown: v = "no command declared"
            }
            return (h.name, v)
        }
        return ProbeResult(status: status, detail: detail, metrics: metrics)
    }
}

/// MCP servers configured for Claude Code — are their launch commands present?
/// Phase-1 depth: presence/executability only, never a spawned handshake.
public struct MCPServersProbe: ToolProbe {
    public let id = "mcp-servers"
    public let name = "MCP servers"
    public let subtitle = "Claude MCP config · configured tools"
    public let symbolName = "point.3.connected.trianglepath.dotted"
    public var configFile: String

    public init(configFile: String = ClaudePaths.process.mcpConfigJSON.path) {
        self.configFile = configFile
    }

    public func check() async -> ProbeResult {
        guard let data = FileManager.default.contents(atPath: configFile) else {
            return ProbeResult(status: .down, detail: "Claude MCP config unreadable")
        }
        let health = MCPConfig.classify(MCPConfig.parse(data),
                                        resolves: ProbePrimitives.commandResolves)
        return MCPConfig.probeResult(health)
    }
}

// MARK: Hooks (~/.claude/settings.json → hooks)

public struct HookConfig: Sendable, Equatable {
    public let event: String        // "SessionStart" | "PreCompact" | ...
    public let matcher: String      // "" | "compact" | ...
    public let type: String         // "command"
    public let command: String      // full command string
    public let binary: String       // first shell token — the executable to resolve

    public init(event: String, matcher: String, type: String, command: String, binary: String) {
        self.event = event; self.matcher = matcher; self.type = type
        self.command = command; self.binary = binary
    }
}

public enum HookHealthStatus: String, Sendable, Equatable {
    case present   // a real binary/script resolves
    case builtin   // a shell builtin (echo/true/…): a reminder hook — always fires
    case missing   // binary declared but not found
    case unknown   // non-command hook / empty command
}

public struct HookHealth: Sendable, Equatable {
    public let event: String
    public let matcher: String
    public let binary: String
    public let command: String
    public let status: HookHealthStatus

    public init(event: String, matcher: String, binary: String, command: String,
                status: HookHealthStatus) {
        self.event = event; self.matcher = matcher; self.binary = binary
        self.command = command; self.status = status
    }
}

public enum HooksConfig {
    /// Shell builtins used as reminder hooks (`echo '…'`) — they need no binary on
    /// disk, so they always fire. Kept distinct from real tool hooks so the card is
    /// honest about which hooks depend on an installed executable.
    static let shellBuiltins: Set<String> = [
        "echo", "true", "false", ":", "test", "[", "cd", "printf", "export",
        "unset", "read", "exit", "set", "source", "eval"
    ]

    /// First shell token of a command string (the executable), stepping over a
    /// leading `VAR=value` env-assignment prefix.
    public nonisolated static func firstToken(_ command: String) -> String {
        for tok in command.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
            let s = String(tok)
            if s.contains("=") && !s.contains("/") { continue }   // VAR=val prefix
            return s
        }
        return ""
    }

    public nonisolated static func parse(_ data: Data) -> [HookConfig] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let hooks = root["hooks"] as? [String: Any] else { return [] }
        var out: [HookConfig] = []
        for (event, value) in hooks {
            guard let groups = value as? [[String: Any]] else { continue }
            for g in groups {
                let matcher = (g["matcher"] as? String) ?? ""
                guard let entries = g["hooks"] as? [[String: Any]] else { continue }
                for e in entries {
                    let type = (e["type"] as? String) ?? "command"
                    let cmd = (e["command"] as? String) ?? ""
                    out.append(HookConfig(event: event, matcher: matcher, type: type,
                                          command: cmd, binary: firstToken(cmd)))
                }
            }
        }
        return out.sorted {
            ($0.event, $0.matcher, $0.binary) < ($1.event, $1.matcher, $1.binary)
        }
    }

    /// Pure config → statuses with an injected resolver.
    public nonisolated static func classify(_ hooks: [HookConfig],
                                            resolves: (String) -> Bool) -> [HookHealth] {
        hooks.map { h in
            let base = (h.binary as NSString).lastPathComponent
            let status: HookHealthStatus
            if h.type != "command" || h.binary.isEmpty {
                status = .unknown
            } else if shellBuiltins.contains(base) {
                status = .builtin
            } else if resolves(h.binary) {
                status = .present
            } else {
                status = .missing
            }
            return HookHealth(event: h.event, matcher: h.matcher, binary: h.binary,
                              command: h.command, status: status)
        }
    }

    public nonisolated static func summary(_ h: [HookHealth])
        -> (present: Int, builtin: Int, missing: Int, events: Int) {
        (h.filter { $0.status == .present }.count,
         h.filter { $0.status == .builtin }.count,
         h.filter { $0.status == .missing }.count,
         Set(h.map(\.event)).count)
    }

    public nonisolated static func probeResult(_ health: [HookHealth]) -> ProbeResult {
        guard !health.isEmpty else {
            return ProbeResult(status: .up, detail: "no hooks configured")
        }
        let (present, builtin, missing, events) = summary(health)
        let status: ProbeStatus = missing > 0 ? .degraded : .up
        let toolNote = missing > 0 ? "\(present) tool present, \(missing) missing"
                                   : "\(present) tool\(present == 1 ? "" : "s") present"
        let detail = "\(health.count) hook\(health.count == 1 ? "" : "s") across "
            + "\(events) event\(events == 1 ? "" : "s") · \(toolNote) · command resolves only"
        // One line per DISTINCT real (non-builtin) binary — labels stay unique — then
        // a rolled-up reminders line for the echo hooks.
        var metrics: [(String, String)] = []
        var seen = Set<String>()
        for h in health where h.status == .present || h.status == .missing {
            let base = (h.binary as NSString).lastPathComponent
            if seen.insert(base).inserted {
                metrics.append((base, "\(h.event) · \(h.status == .present ? "present" : "missing")"))
            }
        }
        if builtin > 0 {
            metrics.append(("reminders", "\(builtin) echo hook\(builtin == 1 ? "" : "s") · always fire"))
        }
        return ProbeResult(status: status, detail: detail, metrics: metrics)
    }
}

/// SessionStart / PreCompact / … hooks — does each hook's command resolve on disk?
public struct HooksProbe: ToolProbe {
    public let id = "hooks"
    public let name = "Hooks"
    public let subtitle = "Claude settings.json · lifecycle"
    public let symbolName = "arrow.triangle.branch"
    public var settingsFile: String

    public init(settingsFile: String = ClaudePaths.process.settingsJSON.path) {
        self.settingsFile = settingsFile
    }

    public func check() async -> ProbeResult {
        guard let data = FileManager.default.contents(atPath: settingsFile) else {
            return ProbeResult(status: .down, detail: "Claude settings.json unreadable")
        }
        let health = HooksConfig.classify(HooksConfig.parse(data),
                                          resolves: ProbePrimitives.commandResolves)
        return HooksConfig.probeResult(health)
    }
}

// MARK: Plugins (~/.claude/plugins/installed_plugins.json)

public struct PluginRecord: Sendable, Equatable {
    public let name: String
    public let marketplace: String
    public let version: String
    public let scope: String
    public let lastUpdated: Date?
    public let ageDays: Double?     // now − lastUpdated, in days
    public let isStale: Bool        // ageDays > staleThresholdDays

    public init(name: String, marketplace: String, version: String, scope: String,
                lastUpdated: Date?, ageDays: Double?, isStale: Bool) {
        self.name = name; self.marketplace = marketplace; self.version = version
        self.scope = scope; self.lastUpdated = lastUpdated; self.ageDays = ageDays
        self.isStale = isStale
    }
}

public enum PluginsConfig {
    /// Past this many days since the last update, a plugin is flagged stale — a soft
    /// signal (amber), never "down".
    public static let staleThresholdDays: Double = 90

    private nonisolated static func parseDate(_ s: String?) -> Date? {
        guard let s else { return nil }
        let withFrac = ISO8601DateFormatter()
        withFrac.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = withFrac.date(from: s) { return d }
        let plain = ISO8601DateFormatter()
        plain.formatOptions = [.withInternetDateTime]
        return plain.date(from: s)
    }

    /// `installed_plugins.json` → records, sorted stalest-first. `now` is injected so
    /// staleness is deterministic in tests.
    public nonisolated static func parse(_ data: Data, now: Date = Date()) -> [PluginRecord] {
        guard let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let plugins = root["plugins"] as? [String: Any] else { return [] }
        var out: [PluginRecord] = []
        for (key, value) in plugins {
            let parts = key.split(separator: "@", maxSplits: 1)
            let name = String(parts.first ?? "")
            let marketplace = parts.count > 1 ? String(parts[1]) : ""
            guard let records = value as? [[String: Any]] else { continue }
            for r in records {
                let version = (r["version"] as? String) ?? "unknown"
                let scope = (r["scope"] as? String) ?? "user"
                let lu = parseDate((r["lastUpdated"] as? String) ?? (r["installedAt"] as? String))
                let age = lu.map { now.timeIntervalSince($0) / 86400 }
                out.append(PluginRecord(name: name, marketplace: marketplace, version: version,
                                        scope: scope, lastUpdated: lu, ageDays: age,
                                        isStale: (age ?? 0) > staleThresholdDays))
            }
        }
        return out.sorted { ($0.ageDays ?? -1) > ($1.ageDays ?? -1) }
    }

    public nonisolated static func summary(_ p: [PluginRecord]) -> (installed: Int, stale: Int) {
        (p.count, p.filter(\.isStale).count)
    }

    public nonisolated static func probeResult(_ plugins: [PluginRecord]) -> ProbeResult {
        guard !plugins.isEmpty else {
            return ProbeResult(status: .up, detail: "no plugins installed")
        }
        let (installed, stale) = summary(plugins)
        let status: ProbeStatus = stale > 0 ? .degraded : .up
        let threshold = Int(staleThresholdDays)
        let detail = stale > 0
            ? "\(installed) installed · \(stale) stale (>\(threshold)d since last update)"
            : "\(installed) installed · all fresh (<\(threshold)d)"
        var metrics: [(String, String)] = [("installed", "\(installed)")]
        var seen = Set<String>()
        // The three stalest first (the sort order) — the ones worth an eye.
        for p in plugins where seen.insert(p.name).inserted {
            let age = p.ageDays.map { "\(Int($0))d" } ?? "unknown"
            metrics.append((p.name, "v\(p.version) · \(age)\(p.isStale ? " · stale" : "")"))
            if metrics.count >= 4 { break }   // "installed" + 3 plugins
        }
        return ProbeResult(status: status, detail: detail, metrics: metrics)
    }
}

/// Installed plugins + their staleness — a plugin not updated in a long time is a
/// quiet rot signal (amber), surfaced before a session mysteriously misbehaves.
public struct PluginsProbe: ToolProbe {
    public let id = "plugins"
    public let name = "Plugins"
    public let subtitle = "installed_plugins.json · freshness"
    public let symbolName = "puzzlepiece"
    public var pluginsFile: String

    public init(pluginsFile: String =
                ClaudePaths.process.installedPluginsJSON.path) {
        self.pluginsFile = pluginsFile
    }

    public func check() async -> ProbeResult {
        guard let data = FileManager.default.contents(atPath: pluginsFile) else {
            return ProbeResult(status: .down, detail: "installed_plugins.json unreadable")
        }
        return PluginsConfig.probeResult(PluginsConfig.parse(data))
    }
}

public extension ToolProbeEngine {
    /// The default stack, in display order — generic config-surface checks only.
    /// No third-party or personal-tool integrations ship by default: Claude
    /// Code's own config root, the skills directory, and the three
    /// config-surface health checks (VISION 2.4): MCP servers, hooks, plugins.
    /// Add a probe: write the struct, append it here — done.
    nonisolated static var defaultProbes: [any ToolProbe] {
        defaultProbes(paths: .process)
    }

    nonisolated static func defaultProbes(paths: ClaudePaths) -> [any ToolProbe] {
        [ClaudeConfigProbe(directory: paths.root.path),
         SkillsProbe(directory: paths.skills.path),
         MCPServersProbe(configFile: paths.mcpConfigJSON.path),
         HooksProbe(settingsFile: paths.settingsJSON.path),
         PluginsProbe(pluginsFile: paths.installedPluginsJSON.path)]
    }
}
