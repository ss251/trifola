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
        do {
            try relative.joined(separator: "\n")
                .write(to: listFile, atomically: true, encoding: .utf8)
        } catch {
            return Outcome(ok: false,
                           error: "could not write local sync list: \(error.localizedDescription)",
                           filesListed: lines.count)
        }

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
        enum State: Equatable { case testing, reachable, unreachable, unknown }
        let state: State
        let checkedAt: Date?
        let error: String?
    }

    enum ConfigurationError: Error, Equatable, LocalizedError {
        case validation(String)
        case persistence(String)

        var errorDescription: String? {
            switch self {
            case .validation(let message), .persistence(let message): message
            }
        }
    }

    private struct SyncResult: Sendable {
        let name: String
        let reachability: MachineReachability.Status
        let outcome: SyncRunner.Outcome
        let mirrorFreshness: Date?
    }

    @Published private(set) var config: MachinesConfig = .seeded
    @Published private(set) var statuses: [RemoteStatus] = []
    @Published private(set) var syncing = false
    @Published private(set) var connectionTests: [String: ConnectionTestResult] = [:]
    @Published private(set) var persistenceError: String?

    private let configURL: URL
    private let runtimeStateURL: URL
    private let remotesRoot: URL
    private var runtimeState = MachinesRuntimeState()
    private var reachable: [String: MachineReachability.Status] = [:]
    private var persistenceRetry: (() -> Void)?

    /// Called on the main actor after a sync pass finishes so `AppServices` can
    /// re-wire the SessionStore's remote sources and refresh the merged fleet.
    var onSynced: (() -> Void)?
    var onConfigChanged: (() -> Void)?

    var persistenceLocation: URL { configURL.deletingLastPathComponent() }

    init(configURL: URL = MachinePaths.configURL,
         runtimeStateURL: URL = MachinePaths.runtimeStateURL,
         remotesRoot: URL = MachinePaths.remotesRoot) {
        self.configURL = configURL
        self.runtimeStateURL = runtimeStateURL
        self.remotesRoot = remotesRoot
    }

    func load() {
        let configExisted = FileManager.default.fileExists(atPath: configURL.path)
        config = MachinePaths.loadConfig(from: configURL)
        runtimeState = MachinePaths.loadRuntimeState(from: runtimeStateURL)
        reachable = [:] // a previous process can never prove current liveness

        var hydrated = runtimeState
        for remote in config.remotes {
            var receipt = hydrated.remotes[remote.name] ?? RemoteMirrorPersistence()
            if receipt.mirrorFreshness == nil {
                receipt.mirrorFreshness = MachinePaths.mirrorFreshness(
                    for: remote.name, root: remotesRoot)
            }
            hydrated.remotes[remote.name] = receipt
        }
        if hydrated != runtimeState {
            runtimeState = hydrated
            persistRuntimeState(hydrated, operation: "Save mirror freshness")
        }
        if !configExisted && !FileManager.default.fileExists(atPath: configURL.path) {
            recordPersistenceFailure(
                "Machine settings could not be created at \(configURL.path).",
                retry: { [weak self] in self?.retryConfigSnapshot() })
        }
        refreshStatuses(sessionCounts: [:])
    }

    /// Settings owns configuration; the runtime consumes the same persisted config
    /// on the next sync. Names are stable project keys, so duplicate/blank entries
    /// are rejected rather than silently replacing a host.
    @discardableResult
    func addRemote(name: String, host: String, user: String) -> Result<Void, ConfigurationError> {
        let n = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let h = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let u = user.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !n.isEmpty, !h.isEmpty, !u.isEmpty else {
            return .failure(.validation("Enter non-empty name, host, and SSH user values."))
        }
        guard MachineNameSlug.isValid(n) else {
            return .failure(.validation(
                "Name must start with a letter or number and use only letters, numbers, dot, underscore, or hyphen."))
        }
        guard !config.remotes.contains(where: { $0.name == n }) else {
            return .failure(.validation("A host named \(n) is already configured."))
        }
        var next = config
        next.remotes.append(RemoteConfig(name: n, host: h, user: u))
        return commitConfig(next, operation: "Add host") { [weak self] in
            guard let self else { return }
            self.refreshStatuses(sessionCounts: [:])
            self.onConfigChanged?()
        }
    }

    @discardableResult
    func removeRemote(_ remote: RemoteConfig,
                      removeLocalMirror: Bool) -> Result<Void, ConfigurationError> {
        var next = config
        next.remotes.removeAll { $0.name == remote.name }
        return commitConfig(next, operation: "Remove host") { [weak self] in
            guard let self else { return }
            self.connectionTests[remote.name] = nil
            self.reachable[remote.name] = nil
            self.finishRemovalCleanup(remote.name, removeLocalMirror: removeLocalMirror)
            self.refreshStatuses(sessionCounts: [:])
            self.onConfigChanged?()
        }
    }

    func mirrorSize(for remote: RemoteConfig) -> UInt64 {
        MachinePaths.mirrorSize(for: remote.name, root: remotesRoot)
    }

    func mirrorLocation(for remote: RemoteConfig) -> URL? {
        try? MachinePaths.validatedMirror(for: remote.name, root: remotesRoot)
    }

    /// Reuses the fleet's bounded reachability probe. It never starts a sync or a
    /// second networking path; Settings merely surfaces the existing result.
    func testConnection(_ remote: RemoteConfig) {
        connectionTests[remote.name] = .init(state: .testing, checkedAt: nil, error: nil)
        let inheritedError = runtimeState.remotes[remote.name]?.lastError
        Task.detached(priority: .userInitiated) {
            let result = MachineReachability.probe(host: remote.host, timeoutMs: 2000)
            await MainActor.run {
                self.reachable[remote.name] = result
                let state: ConnectionTestResult.State
                let error: String?
                switch result {
                case .reachable:
                    state = .reachable
                    error = nil
                case .unreachable:
                    state = .unreachable
                    error = inheritedError ?? "SSH port did not answer"
                case .unknown:
                    state = .unknown
                    error = "SSH port probe could not be verified"
                }
                self.connectionTests[remote.name] = .init(
                    state: state,
                    checkedAt: Date(),
                    error: error)
                self.refreshStatuses(sessionCounts: [:])
            }
        }
    }

    /// The live remote sources for the SessionStore merge — only remotes whose mirror
    /// already holds transcripts (a successful sync). Inert remotes are omitted, so
    /// the fleet degrades to local-only automatically.
    var remoteSources: [RemoteSource] {
        config.remotes.compactMap { r in
            guard MachinePaths.mirrorHasContent(for: r.name, root: remotesRoot),
                  let dir = try? MachinePaths.validatedMirror(for: r.name, root: remotesRoot)
            else { return nil }
            return RemoteSource(machine: r.machine, dir: dir)
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
            let receipt = runtimeState.remotes[r.name] ?? RemoteMirrorPersistence()
            return RemoteStatus(machine: r.machine,
                                reachable: reachable[r.name] ?? .unknown,
                                hasMirror: MachinePaths.mirrorHasContent(for: r.name, root: remotesRoot),
                                lastSynced: receipt.lastSuccess,
                                lastError: receipt.lastError,
                                sessionCount: sessionCounts[r.name] ?? 0,
                                lastAttempt: receipt.lastAttempt,
                                mirrorFreshness: receipt.mirrorFreshness)
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
        let attemptedAt = Date()
        var attemptedState = runtimeState
        for remote in remotes {
            var receipt = attemptedState.remotes[remote.name] ?? RemoteMirrorPersistence()
            receipt.lastAttempt = attemptedAt
            attemptedState.remotes[remote.name] = receipt
        }
        runtimeState = attemptedState
        persistRuntimeState(attemptedState, operation: "Save machine sync attempt")
        let remotesRoot = self.remotesRoot
        Task.detached(priority: .utility) {
            var results: [SyncResult] = []
            for r in remotes {
                // Quick reachability probe first (hard-deadline, never hangs) so a
                // down host is a fast no-op rather than a full ssh timeout.
                let reach = MachineReachability.probe(host: r.host, timeoutMs: 2000)
                guard reach == .reachable else {
                    let reason = reach == .unknown ? "reachability unverified" : "SSH port unreachable"
                    results.append(SyncResult(
                        name: r.name,
                        reachability: reach,
                        outcome: SyncRunner.Outcome(ok: false, error: reason, filesListed: 0),
                        mirrorFreshness: MachinePaths.mirrorFreshness(for: r.name, root: remotesRoot)))
                    continue
                }
                let outcome: SyncRunner.Outcome
                do {
                    let mirror = try MachinePaths.validatedMirror(for: r.name, root: remotesRoot)
                    let listFile = try MachinePaths.validatedSyncListFile(for: r.name, root: remotesRoot)
                    try FileManager.default.createDirectory(at: mirror, withIntermediateDirectories: true)
                    let plan = try RemoteSync.validatedPlan(
                        remote: r, mirror: mirror, listFile: listFile, remotesRoot: remotesRoot)
                    outcome = SyncRunner.run(plan, listFile: listFile)
                } catch {
                    outcome = SyncRunner.Outcome(
                        ok: false,
                        error: "local mirror setup failed: \(error.localizedDescription)",
                        filesListed: 0)
                }
                results.append(SyncResult(
                    name: r.name,
                    reachability: reach,
                    outcome: outcome,
                    mirrorFreshness: MachinePaths.mirrorFreshness(for: r.name, root: remotesRoot)))
            }
            await MainActor.run { [results] in self.applySyncResults(results) }
        }
    }

    private func applySyncResults(_ results: [SyncResult]) {
        let now = Date()
        var nextRuntime = runtimeState
        for r in results {
            reachable[r.name] = r.reachability
            var receipt = nextRuntime.remotes[r.name] ?? RemoteMirrorPersistence()
            if r.outcome.ok {
                receipt.lastSuccess = now
                receipt.lastError = nil
                receipt.mirrorFreshness = r.mirrorFreshness ?? receipt.mirrorFreshness
            } else {
                receipt.lastError = r.outcome.error
            }
            nextRuntime.remotes[r.name] = receipt
        }
        runtimeState = nextRuntime
        persistRuntimeState(nextRuntime, operation: "Save machine sync result")
        syncing = false
        refreshStatuses(sessionCounts: [:])
        onSynced?()
    }

    // MARK: Persistence outcomes

    private func commitConfig(_ next: MachinesConfig,
                              operation: String,
                              onSuccess: @escaping () -> Void) -> Result<Void, ConfigurationError> {
        switch MachinePaths.saveConfig(next, to: configURL) {
        case .success:
            config = next
            clearPersistenceFailure()
            onSuccess()
            return .success(())
        case .failure(let error):
            let message = "\(operation) was not saved. \(error.localizedDescription)"
            recordPersistenceFailure(message) { [weak self] in
                _ = self?.commitConfig(next, operation: operation, onSuccess: onSuccess)
            }
            return .failure(.persistence(message))
        }
    }

    private func retryConfigSnapshot() {
        _ = commitConfig(config, operation: "Save machine settings") {}
    }

    private func persistRuntimeState(_ state: MachinesRuntimeState, operation: String) {
        switch MachinePaths.saveRuntimeState(state, to: runtimeStateURL) {
        case .success:
            clearPersistenceFailure()
        case .failure(let error):
            recordPersistenceFailure("\(operation) failed. \(error.localizedDescription)") { [weak self] in
                self?.persistRuntimeState(state, operation: operation)
            }
        }
    }

    private func finishRemovalCleanup(_ name: String, removeLocalMirror: Bool) {
        var nextRuntime = runtimeState
        nextRuntime.remotes[name] = nil
        runtimeState = nextRuntime

        var errors: [String] = []
        if case .failure(let error) = MachinePaths.saveRuntimeState(nextRuntime, to: runtimeStateURL) {
            errors.append(error.localizedDescription)
        }
        if removeLocalMirror,
           case .failure(let error) = MachinePaths.removeMirror(for: name, root: remotesRoot) {
            errors.append(error.localizedDescription)
        }
        if errors.isEmpty {
            clearPersistenceFailure()
        } else {
            let message = "Host removed, but local cleanup was incomplete. \(errors.joined(separator: " "))"
            recordPersistenceFailure(message) { [weak self] in
                self?.finishRemovalCleanup(name, removeLocalMirror: removeLocalMirror)
            }
        }
    }

    private func recordPersistenceFailure(_ message: String,
                                          retry: @escaping () -> Void) {
        persistenceError = message
        persistenceRetry = retry
    }

    private func clearPersistenceFailure() {
        persistenceError = nil
        persistenceRetry = nil
    }

    func retryPersistence() {
        persistenceRetry?()
    }
}
