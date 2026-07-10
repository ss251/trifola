import Foundation
import Combine
import TrifolaKit

// MARK: - Cross-Machine Fleet — the app-side sync runner + store
//
// The Kit owns the PURE layer (config, command composition, merge, reachability).
// This file owns the two impure pieces that can't be unit-tested against a live
// network: running the composed rsync/ssh plan (SyncRunner) and holding the live
// per-remote status the UI reads (MachineStore). Both are best-effort and
// bounded — a down `workstation` degrades to LOCAL-ONLY, never a hang or a crash.

// MARK: - Sync runner (executes the pure plan, read-only, hard-deadline)

/// Runs a `RemoteSync.Plan` with a hard wall-clock deadline. The plan is read-only
/// by construction (it only ever pulls remote→local); this just executes it and
/// terminates any process that overruns, so a stalled ssh/rsync never hangs the app.
/// LIVE verification against a real `workstation` is deferred to the user.
enum SyncRunner {
    struct Outcome: Sendable {
        let ok: Bool
        let error: String?
        let filesListed: Int
    }

    /// Execute the two-step plan: enumerate recent transcripts (ssh+find), then pull
    /// exactly those, read-only, into the local mirror (rsync). Never throws; a
    /// failure at either step returns `.ok == false` with a short reason.
    static func run(_ plan: RemoteSync.Plan, listFile: URL, deadline: TimeInterval = 25) -> Outcome {
        // Step 1 — list recent files on the remote.
        let (listStatus, listOut, listedTimedOut) = runProcess(plan.list, deadline: deadline)
        guard !listedTimedOut else { return Outcome(ok: false, error: "list timed out", filesListed: 0) }
        guard listStatus == 0 else {
            return Outcome(ok: false, error: "unreachable (ssh exit \(listStatus))", filesListed: 0)
        }
        // Convert the absolute paths find printed into a `--files-from` list. The
        // paths are rooted at "/", matching the rsync SRC of "<host>:/".
        let text = String(data: listOut, encoding: .utf8) ?? ""
        let lines = text.split(separator: "\n").map(String.init).filter { !$0.isEmpty }
        guard !lines.isEmpty else { return Outcome(ok: true, error: nil, filesListed: 0) }
        // rsync --files-from paths are relative to SRC ("<host>:/"), so strip the
        // leading slash from each absolute path.
        let relative = lines.map { $0.hasPrefix("/") ? String($0.dropFirst()) : $0 }
        try? relative.joined(separator: "\n").write(to: listFile, atomically: true, encoding: .utf8)

        // Step 2 — pull only those files, read-only, into the mirror.
        let (pullStatus, _, pullTimedOut) = runProcess(plan.pull, deadline: deadline)
        guard !pullTimedOut else { return Outcome(ok: false, error: "pull timed out", filesListed: lines.count) }
        guard pullStatus == 0 else {
            return Outcome(ok: false, error: "rsync exit \(pullStatus)", filesListed: lines.count)
        }
        return Outcome(ok: true, error: nil, filesListed: lines.count)
    }

    /// Run one argv through `/usr/bin/env` (so PATH resolves ssh/rsync), capturing
    /// stdout, with a hard-deadline watchdog that terminates an overrunning process.
    /// The stdout pipe is drained on a background thread so a full buffer can't
    /// deadlock the wait.
    private static func runProcess(_ argv: [String], deadline: TimeInterval)
        -> (status: Int32, stdout: Data, timedOut: Bool) {
        guard let first = argv.first else { return (127, Data(), false) }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        proc.arguments = argv
        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = Pipe()   // discarded — the exit status carries the verdict

        let box = Locked<Data>(Data())
        let readDone = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInitiated).async {
            let d = outPipe.fileHandleForReading.readDataToEndOfFile()
            box.withLock { $0 = d }
            readDone.signal()
        }

        do { try proc.run() } catch {
            return (127, Data(), false)   // ssh/rsync not found or not runnable
        }
        _ = first

        var timedOut = false
        let watchdog = DispatchWorkItem {
            if proc.isRunning { timedOut = true; proc.terminate() }
        }
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + deadline, execute: watchdog)
        proc.waitUntilExit()
        watchdog.cancel()
        _ = readDone.wait(timeout: .now() + 2)
        let data = box.withLock { $0 }
        return (proc.terminationStatus, data, timedOut)
    }
}

// MARK: - Machine store (the live per-remote status the UI reads)

/// Loads the fleet config (seeded with `workstation`), holds each remote's live status
/// (reachable? last synced? offline indicator?), and drives best-effort background
/// syncs. Every remote stays INERT until its mirror actually holds transcripts, so
/// a configured-but-never-reached `workstation` contributes nothing and surfaces only as
/// a calm "offline" line — the fleet runs LOCAL-ONLY and never blocks.
@MainActor
final class MachineStore: ObservableObject {
    struct ConnectionTestResult: Equatable {
        enum State: Equatable { case testing, reachable, unreachable }
        let state: State
        let checkedAt: Date?
        let error: String?
    }

    @Published private(set) var config: MachinesConfig = .seeded
    @Published private(set) var statuses: [RemoteStatus] = []
    @Published private(set) var syncing = false
    @Published private(set) var connectionTests: [String: ConnectionTestResult] = [:]

    private var lastSynced: [String: Date] = [:]
    private var lastError: [String: String] = [:]
    private var reachable: [String: MachineReachability.Status] = [:]

    /// Called on the main actor after a sync pass finishes so `AppServices` can
    /// re-wire the SessionStore's remote sources and refresh the merged fleet.
    var onSynced: (() -> Void)?
    var onConfigChanged: (() -> Void)?

    func load() {
        config = MachinePaths.loadConfig()
        refreshStatuses(sessionCounts: [:])
    }

    /// Settings owns configuration; the runtime consumes the same persisted config
    /// on the next sync. Names are stable project keys, so duplicate/blank entries
    /// are rejected rather than silently replacing a host.
    @discardableResult
    func addRemote(name: String, host: String, user: String) -> Bool {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let u = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !h.isEmpty, !u.isEmpty,
              !config.remotes.contains(where: { $0.name == n }) else { return false }
        config.remotes.append(RemoteConfig(name: n, host: h, user: u))
        MachinePaths.saveConfig(config)
        refreshStatuses(sessionCounts: [:])
        onConfigChanged?()
        return true
    }

    func removeRemote(_ remote: RemoteConfig) {
        config.remotes.removeAll { $0.name == remote.name }
        connectionTests[remote.name] = nil
        MachinePaths.saveConfig(config)
        refreshStatuses(sessionCounts: [:])
        onConfigChanged?()
    }

    /// Reuses the fleet's bounded reachability probe. It never starts a sync or a
    /// second networking path; Settings merely surfaces the existing result.
    func testConnection(_ remote: RemoteConfig) {
        connectionTests[remote.name] = .init(state: .testing, checkedAt: nil, error: nil)
        let inheritedError = lastError[remote.name]
        Task.detached(priority: .userInitiated) {
            let result = MachineReachability.probe(host: remote.host, timeoutMs: 2000)
            await MainActor.run {
                let ok = result == .reachable
                self.reachable[remote.name] = result
                self.connectionTests[remote.name] = .init(
                    state: ok ? .reachable : .unreachable,
                    checkedAt: Date(),
                    error: ok ? nil : (inheritedError ?? "host did not answer the fleet probe"))
                self.refreshStatuses(sessionCounts: [:])
            }
        }
    }

    /// The live remote sources for the SessionStore merge — only remotes whose mirror
    /// already holds transcripts (a successful sync). Inert remotes are omitted, so
    /// the fleet degrades to local-only automatically.
    var remoteSources: [RemoteSource] {
        config.remotes.compactMap { r in
            MachinePaths.mirrorHasContent(for: r.name)
                ? RemoteSource(machine: r.machine, dir: MachinePaths.mirror(for: r.name))
                : nil
        }
    }

    /// Configured remotes that are NOT currently contributing (no mirror yet, or last
    /// seen unreachable) — the calm offline indicators the Overview shows.
    var offlineIndicators: [RemoteStatus] { statuses.filter { !$0.isOnline } }
    var onlineIndicators: [RemoteStatus] { statuses.filter { $0.isOnline } }

    /// Rebuild the per-remote status lines. `sessionCounts` maps machine id → count
    /// (fed from the merged fleet) so an online remote shows its real contribution.
    func refreshStatuses(sessionCounts: [String: Int]) {
        let fresh = config.remotes.map { r in
            RemoteStatus(machine: r.machine,
                         reachable: reachable[r.name] ?? .unknown,
                         hasMirror: MachinePaths.mirrorHasContent(for: r.name),
                         lastSynced: lastSynced[r.name],
                         lastError: lastError[r.name],
                         sessionCount: sessionCounts[r.name] ?? 0)
        }
        // Compare-before-assign (W6 wave 4).
        if statuses != fresh { statuses = fresh }
    }

    /// Best-effort background sync of every configured remote. Off-main, bounded,
    /// never blocks or crashes. On success the mirror gains transcripts and the next
    /// merge picks them up; on failure the remote stays offline (local-only).
    func syncInBackground() {
        guard !syncing else { return }
        let remotes = config.remotes
        guard !remotes.isEmpty else { return }
        syncing = true
        Task.detached(priority: .utility) {
            var results: [(name: String, reach: MachineReachability.Status, outcome: SyncRunner.Outcome)] = []
            for r in remotes {
                // Quick reachability probe first (hard-deadline, never hangs) so a
                // down host is a fast no-op rather than a full ssh timeout.
                let reach = MachineReachability.probe(host: r.host, timeoutMs: 2000)
                guard reach == .reachable else {
                    results.append((r.name, reach, SyncRunner.Outcome(ok: false, error: "unreachable", filesListed: 0)))
                    continue
                }
                let mirror = MachinePaths.mirror(for: r.name)
                try? FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)
                let plan = RemoteSync.plan(remote: r, mirror: mirror,
                                           listFile: MachinePaths.syncListFile(for: r.name))
                let outcome = SyncRunner.run(plan, listFile: MachinePaths.syncListFile(for: r.name))
                results.append((r.name, reach, outcome))
            }
            await MainActor.run { [results] in self.applySyncResults(results) }
        }
    }

    private func applySyncResults(_ results: [(name: String, reach: MachineReachability.Status, outcome: SyncRunner.Outcome)]) {
        let now = Date()
        for r in results {
            reachable[r.name] = r.reach
            if r.outcome.ok {
                lastSynced[r.name] = now
                lastError[r.name] = nil
            } else {
                lastError[r.name] = r.outcome.error
            }
        }
        syncing = false
        refreshStatuses(sessionCounts: [:])
        onSynced?()
    }
}
