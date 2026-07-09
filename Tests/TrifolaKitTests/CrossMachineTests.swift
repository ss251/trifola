import Foundation
import Testing
@testable import TrifolaKit

// The Cross-Machine Fleet is the differentiator — and it is built to be provable
// WITHOUT a live network. These tests drive the whole thing off pure functions and a
// LOCAL FIXTURE dir standing in for "machine #2":
//   • the MERGE + machine-tagging + fleet roll-up (fixture dir as workstation),
//   • the read-only sync-command COMPOSITION (exact rsync/ssh argv, no live call),
//   • graceful degradation (absent/unreachable remote → local-only, never a crash),
//   • the calm offline indicator.

private let t0 = Date(timeIntervalSince1970: 1_780_000_000)
private func iso(_ off: TimeInterval) -> String {
    let f = ISO8601DateFormatter()
    f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
    return f.string(from: t0.addingTimeInterval(off))
}

// A plain summary tagged to a machine (default local), for the pure merge tests.
// `cost` drives the usage so `.cost` equals it exactly (fresh Opus input, no output/
// cache), keeping the roll-up arithmetic clean and self-checking.
private func summary(_ id: String, project: String, machine: String = Machine.localID,
                     cost: Double = 3, ageSecs: TimeInterval = 60, active: Bool = false) -> SessionSummary {
    let last = active ? Date() : t0.addingTimeInterval(-ageSecs)
    let inp = Int((cost / ModelTier.opus.rates.inp) * 1_000_000)   // fresh input → .cost == cost
    return SessionSummary(id: id, project: project, cwd: "/repo/\(project)",
                          model: "claude-opus-4-8", lastActivity: last, messageCount: 5,
                          usage: SessionUsage(inputTokens: inp),
                          contextWeight: 1000, filePath: "/repo/\(project)/\(id).jsonl",
                          machineID: machine)
}

// MARK: - Fixture: a temp dir standing in for "machine #2"

/// Writes a couple of real .jsonl transcripts into a fresh temp dir — a stand-in for
/// a remote's read-only mirror, parsed by the SAME parser the local corpus uses.
private struct RemoteFixture {
    let dir: URL
    init(_ files: [(id: String, model: String, inp: Int, out: Int)]) {
        dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmc-fixture-\(UUID().uuidString)", isDirectory: true)
        let enc = dir.appendingPathComponent("-home-dev-Developer-webapp", isDirectory: true)
        try? FileManager.default.createDirectory(at: enc, withIntermediateDirectories: true)
        for f in files {
            let lines = [
                #"{"type":"user","sessionId":"\#(f.id)","cwd":"/Users/dev/Developer/webapp","timestamp":"\#(iso(0))","message":{"content":"ship the fleet"}}"#,
                #"{"type":"assistant","sessionId":"\#(f.id)","cwd":"/Users/dev/Developer/webapp","timestamp":"\#(iso(1))","message":{"model":"\#(f.model)","stop_reason":"end_turn","usage":{"input_tokens":\#(f.inp),"output_tokens":\#(f.out)},"content":[{"type":"text","text":"done"}]}}"#,
            ]
            let url = enc.appendingPathComponent("\(f.id).jsonl")
            try? lines.joined(separator: "\n").write(to: url, atomically: true, encoding: .utf8)
        }
    }
    func cleanup() { try? FileManager.default.removeItem(at: dir) }
}

// MARK: - Merge + tagging + roll-up (fixture dir as machine #2)

@Suite("Cross-machine merge")
struct CrossMachineMergeTests {

    @Test func fixtureDirScansAsASecondMachineAndTagsCorrectly() {
        let fx = RemoteFixture([
            ("aaaa1111-0000-0000-0000-000000000001", "claude-opus-4-8", 2_000_000, 200_000),
            ("bbbb2222-0000-0000-0000-000000000002", "claude-sonnet-4-6", 500_000, 60_000),
        ])
        defer { fx.cleanup() }

        // Scan the fixture with the REAL parser — untagged (defaults to local).
        let scanned = SessionStore.scan(fx.dir)
        #expect(scanned.count == 2)
        #expect(scanned.allSatisfy { $0.machineID == Machine.localID })   // untagged yet

        // Merge a local set + the fixture tagged as workstation.
        let local = [summary("local-1", project: "my-app"),
                     summary("local-2", project: "webapp")]
        let workstation = Machine(id: "workstation", name: "workstation", isLocal: false)
        let merged = FleetMerge.merge(local: local, remotes: [(workstation, scanned)])

        // Both sources present, no dup.
        #expect(merged.count == 4)
        // Local tags preserved; fixture summaries stamped workstation.
        #expect(merged.filter { $0.machineID == Machine.localID }.count == 2)
        #expect(merged.filter { $0.machineID == "workstation" }.count == 2)
        // The workstation sessions are exactly the two fixture ids, now remote.
        let dcIDs = Set(merged.filter { $0.isRemote }.map(\.id))
        #expect(dcIDs.contains("aaaa1111-0000-0000-0000-000000000001"))
        #expect(dcIDs.contains("bbbb2222-0000-0000-0000-000000000002"))
    }

    @Test func rollupSumsAcrossMachines() {
        let local = [summary("l1", project: "a", cost: 10, active: true),
                     summary("l2", project: "b", cost: 5)]
        let workstation = Machine(id: "workstation", name: "workstation", isLocal: false)
        let remote = [summary("r1", project: "a", machine: "workstation", cost: 7),
                      summary("r2", project: "c", machine: "workstation", cost: 3, active: true)]
        let merged = FleetMerge.merge(local: local, remotes: [(workstation, remote)])
        let rollups = FleetMerge.rollups(merged, machines: [.local, workstation])

        #expect(rollups.count == 2)
        let localRoll = rollups.first { $0.machine.isLocal }!
        let dcRoll = rollups.first { $0.machine.id == "workstation" }!
        #expect(localRoll.sessionCount == 2)
        #expect(dcRoll.sessionCount == 2)
        #expect(localRoll.activeCount == 1)
        #expect(dcRoll.activeCount == 1)
        #expect(abs(localRoll.cost - 15) < 0.001)
        #expect(abs(dcRoll.cost - 10) < 0.001)
        // Tokens roll up per machine (sum of the machine's session usage totals).
        #expect(localRoll.tokens == local.reduce(0) { $0 + $1.usage.total })
        #expect(dcRoll.tokens == remote.reduce(0) { $0 + $1.usage.total })
        // Fleet-wide totals are the sum of the machine slices.
        let totalCost = rollups.reduce(0) { $0 + $1.cost }
        #expect(abs(totalCost - 25) < 0.001)
        #expect(FleetMerge.machineCount(merged) == 2)
    }

    @Test func sameSessionIdOnOneMachineDeDupesToTheFreshest() {
        // Two summaries, same id + machine (a re-scan racing an append) → one row,
        // the freshest kept. No double-count.
        let older = summary("dup", project: "a", cost: 4, ageSecs: 600)
        let newer = summary("dup", project: "a", cost: 9, ageSecs: 5)
        let merged = FleetMerge.merge(local: [older, newer], remotes: [])
        #expect(merged.count == 1)
        #expect(abs(merged[0].cost - 9) < 0.001)   // freshest (age 5s) won
    }

    @Test func sameIdOnDifferentMachinesAreDistinct() {
        // Astronomically unlikely with UUIDs, but the merge key is (machine, id): the
        // same id on two machines is two real sessions, never collapsed.
        let workstation = Machine(id: "workstation", name: "workstation", isLocal: false)
        let l = summary("shared", project: "webapp", cost: 4)
        let r = summary("shared", project: "webapp", machine: "workstation", cost: 6)
        let merged = FleetMerge.merge(local: [l], remotes: [(workstation, [r])])
        #expect(merged.count == 2)
        #expect(Set(merged.map(\.machineID)) == ["local", "workstation"])
    }

    @Test func machineCountsMapIsPerMachine() {
        let workstation = Machine(id: "workstation", name: "workstation", isLocal: false)
        let merged = FleetMerge.merge(
            local: [summary("l1", project: "a"), summary("l2", project: "b")],
            remotes: [(workstation, [summary("r1", project: "a", machine: "workstation")])])
        let counts = FleetMerge.machineCounts(merged)
        #expect(counts["local"] == 2)
        #expect(counts["workstation"] == 1)
    }
}

// MARK: - Graceful degradation (absent/unreachable remote → local-only)

@Suite("Cross-machine graceful degradation")
struct CrossMachineGracefulTests {

    @Test func noRemotesMeansLocalOnly() {
        let local = [summary("l1", project: "a"), summary("l2", project: "b")]
        let merged = FleetMerge.merge(local: local, remotes: [])
        #expect(merged.count == 2)
        #expect(merged.allSatisfy { $0.machineID == Machine.localID })
        #expect(FleetMerge.machineCount(merged) == 1)
    }

    @Test func absentMirrorDirIsSkippedNotCrashed() {
        // A configured remote whose mirror dir does not exist contributes nothing —
        // `scanRemotes` skips it, so the fleet stays local-only. No throw, no crash.
        let ghost = RemoteSource(
            machine: Machine(id: "workstation", name: "workstation", isLocal: false),
            dir: FileManager.default.temporaryDirectory.appendingPathComponent("does-not-exist-\(UUID())"))
        let scans = SessionStore.scanRemotes([ghost])
        #expect(scans.isEmpty)
        // Merged fleet = local only.
        let merged = FleetMerge.merge(local: [summary("l1", project: "a")], remotes: scans)
        #expect(merged.count == 1)
    }

    @Test func emptyMirrorDirContributesNothing() {
        // A mirror dir that exists but holds no transcripts (a remote synced but with
        // nothing recent) is inert — no sessions, no dup, no crash.
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("cmc-empty-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let src = RemoteSource(machine: Machine(id: "workstation", name: "workstation", isLocal: false), dir: dir)
        #expect(SessionStore.scanRemotes([src]).isEmpty)
    }

    @Test func offlineIndicatorIsCalmAndFactual() {
        let dev = Machine(id: "workstation", name: "workstation", isLocal: false)
        // Never synced → "offline — not yet synced".
        let neverSynced = RemoteStatus(machine: dev, reachable: .unknown, hasMirror: false,
                                       lastSynced: nil, lastError: nil, sessionCount: 0)
        #expect(!neverSynced.isOnline)
        #expect(neverSynced.indicator.contains("offline"))
        #expect(neverSynced.indicator.contains("not yet synced"))

        // Was synced but now unreachable → "offline — last synced …".
        let wentDown = RemoteStatus(machine: dev, reachable: .unreachable, hasMirror: true,
                                    lastSynced: Date().addingTimeInterval(-720), lastError: "unreachable",
                                    sessionCount: 12)
        #expect(!wentDown.isOnline)
        #expect(wentDown.indicator.contains("offline"))
        #expect(wentDown.indicator.contains("last synced"))

        // Online → session count surfaces, no "offline".
        let online = RemoteStatus(machine: dev, reachable: .reachable, hasMirror: true,
                                  lastSynced: Date().addingTimeInterval(-60), lastError: nil,
                                  sessionCount: 8)
        #expect(online.isOnline)
        #expect(online.indicator.contains("8 session"))
        #expect(!online.indicator.contains("offline"))
    }

    @Test func reachabilityProbeToAClosedPortReturnsPromptlyWithoutHanging() {
        // A closed local port refuses immediately — the probe returns a bounded,
        // non-reachable verdict and never hangs (the graceful-degradation guarantee).
        let start = Date()
        let status = MachineReachability.probe(host: "127.0.0.1", port: 1, timeoutMs: 800)
        #expect(status != .reachable)
        #expect(Date().timeIntervalSince(start) < 3)   // bounded — did not hang
    }
}

// MARK: - Sync-command composition (PURE — no live call)

@Suite("Cross-machine sync composition")
struct CrossMachineSyncTests {

    private let workstation = RemoteConfig(name: "workstation", host: "workstation", user: "dev",
                                       remotePath: "~/.claude/projects", recentDays: 7)
    private var mirror: URL { MachinePaths.mirror(for: "workstation") }
    private var listFile: URL { MachinePaths.syncListFile(for: "workstation") }

    @Test func listStepCarriesTheLastNDaysBound() {
        let plan = RemoteSync.plan(remote: workstation, mirror: mirror, listFile: listFile)
        #expect(plan.list.first == "ssh")
        #expect(plan.list.contains("find"))
        #expect(plan.list.contains("~/.claude/projects"))
        #expect(plan.list.contains("dev@workstation"))
        // The BOUND: only transcripts modified in the last 7 days are enumerated.
        #expect(plan.list.contains("-mtime"))
        #expect(plan.list.contains("-7"))
        #expect(plan.list.contains("*.jsonl"))
    }

    @Test func dayBoundFollowsTheConfig() {
        let threeDay = RemoteConfig(name: "d", host: "h", user: "u", recentDays: 3)
        let plan = RemoteSync.plan(remote: threeDay, mirror: mirror, listFile: listFile)
        #expect(plan.list.contains("-3"))
        #expect(!plan.list.contains("-7"))
    }

    @Test func pullIsReadOnly_remoteIsSourceNeverDestination() {
        let plan = RemoteSync.plan(remote: workstation, mirror: mirror, listFile: listFile)
        #expect(plan.pull.first == "rsync")
        // The remote appears ONLY as an rsync SOURCE (second-to-last), and the LOCAL
        // mirror is the destination (last). Never the other way round.
        #expect(plan.pull.last == mirror.path)
        #expect(plan.pull.contains("dev@workstation:/"))
        let src = plan.pull[plan.pull.count - 2]
        #expect(src == "dev@workstation:/")
        // Read-only guarantee: never a remote-mutating flag.
        #expect(!plan.pull.contains("--remove-source-files"))
        #expect(!plan.pull.contains(where: { $0.contains("--remove") }))
        // The bounded file list drives the pull (never the whole tree).
        #expect(plan.pull.contains("--files-from=\(listFile.path)"))
    }

    @Test func sshTransportHasABoundedConnectTimeoutSoItNeverHangs() {
        let plan = RemoteSync.plan(remote: workstation, mirror: mirror, listFile: listFile)
        // Both steps must carry a bounded connect timeout + batch mode (no password
        // prompt to hang on) — the graceful-degradation guarantee at the transport.
        #expect(plan.list.contains("-o"))
        #expect(plan.list.contains(where: { $0.hasPrefix("ConnectTimeout=") }))
        #expect(plan.list.contains("BatchMode=yes"))
        // rsync's -e transport string carries the same options.
        guard let eIdx = plan.pull.firstIndex(of: "-e") else { Issue.record("no -e transport"); return }
        let transport = plan.pull[eIdx + 1]
        #expect(transport.hasPrefix("ssh "))
        #expect(transport.contains("ConnectTimeout="))
        #expect(transport.contains("BatchMode=yes"))
    }

    @Test func planIsPureAndDeterministic() {
        let a = RemoteSync.plan(remote: workstation, mirror: mirror, listFile: listFile)
        let b = RemoteSync.plan(remote: workstation, mirror: mirror, listFile: listFile)
        #expect(a == b)   // same inputs → identical argv, no hidden state
    }
}

// MARK: - Config seeding + machine-tagged bays

@Suite("Cross-machine config + bays")
struct CrossMachineConfigTests {

    @Test func seededConfigCarriesEmptyRemotes() {
        let cfg = MachinesConfig.seeded
        #expect(cfg.remotes.isEmpty)
    }

    @Test func sameRepoOnTwoMachinesBecomesTwoDistinctBays() {
        // webapp open on BOTH machines: the machine-namespaced bay key keeps them
        // separate, each carrying its own machine tag (the whole differentiator).
        let localRally = summary("l", project: "webapp", ageSecs: 100)
        let devRally = SessionSummary(
            id: "d", project: "webapp", cwd: "/Users/dev/Developer/webapp",
            model: "claude-opus-4-8", lastActivity: t0.addingTimeInterval(-50), messageCount: 5,
            usage: SessionUsage(inputTokens: 1000), contextWeight: 1000,
            filePath: "/Users/dev/Developer/webapp/d.jsonl", machineID: "workstation")
        let (board, _) = FleetBoard.build(sessions: [localRally, devRally], signals: [:],
                                          now: t0, arrival: ArrivalLedger())
        #expect(board.bays.count == 2)
        let machineIDs = Set(board.bays.map(\.machineID))
        #expect(machineIDs == ["local", "workstation"])
        // Local bay keeps the bare cwd key (backward-compatible); remote is namespaced.
        #expect(board.bays.contains { $0.machineID == "local" && !$0.isRemote })
        #expect(board.bays.contains { $0.machineID == "workstation" && $0.isRemote })
    }

    @Test func localOnlyLayoutIsUnchangedByTheMachineKey() {
        // With everything on this Mac, bay keys stay the bare cwd — no regression to
        // the single-machine Fleet Board.
        let a = summary("a", project: "A", ageSecs: 100)
        let b = summary("b", project: "B", ageSecs: 10)
        let (board, _) = FleetBoard.build(sessions: [a, b], signals: [:],
                                          now: t0, arrival: ArrivalLedger())
        #expect(board.bays.map(\.key) == ["/repo/A", "/repo/B"])
        #expect(board.bays.allSatisfy { !$0.isRemote })
    }
}
