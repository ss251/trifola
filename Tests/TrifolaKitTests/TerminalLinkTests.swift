import Foundation
import Testing
@testable import TrifolaKit

private struct FakeTerminalSnapshots: TerminalProcessSnapshotProviding {
    let ps: String?
    var lsofByPID: [Int32: String?] = [:]

    func processListOutput() -> String? { ps }
    func workingDirectoryOutput(for processID: Int32) -> String? {
        lsofByPID[processID] ?? nil
    }
}

private enum FakeRegistryError: Error { case unreadable }

private struct FakeTerminalRegistry: TerminalSessionRegistryProviding {
    var value: [TerminalSessionRegistryRecord] = []
    var fails = false

    func records() throws -> [TerminalSessionRegistryRecord] {
        if fails { throw FakeRegistryError.unreadable }
        return value
    }
}

private func lsofCWD(_ path: String) -> String {
    "p1\nfcwd\nn\(path)\n"
}

@Suite("Terminal deep-link mapping")
struct TerminalLinkTests {
    @Test("found: cwd maps through Claude PID and ancestry to exact Terminal tab")
    func found() {
        let ps = """
          500     1 ??       Fri Jul 10 08:00:00 2026 /System/Applications/Utilities/Terminal.app/Contents/MacOS/Terminal
          501   500 ttys005  Fri Jul 10 08:01:00 2026 -zsh
          502   501 ttys005  Fri Jul 10 08:02:00 2026 /usr/local/bin/claude --dangerously-skip-permissions
        """
        let resolver = TerminalLinkResolver(snapshots: FakeTerminalSnapshots(
            ps: ps,
            lsofByPID: [502: lsofCWD("/Users/dev/Developer/trifola")]
        ))

        let target = resolver.resolve(sessionCWD: "/Users/dev/Developer/trifola/")

        #expect(target?.processID == 502)
        #expect(target?.tty == "/dev/ttys005")
        #expect(target?.ownerProcessID == 500)
        #expect(target?.ownerApplication == .terminal)
        #expect(target?.supportsExactTargeting == true)
    }

    @Test("stale: a dead or cwd-less Claude row is ignored")
    func stale() {
        let ps = """
          600     1 ttys001  Fri Jul 10 09:00:00 2026 /opt/homebrew/bin/claude
        """
        let resolver = TerminalLinkResolver(snapshots: FakeTerminalSnapshots(
            ps: ps,
            lsofByPID: [600: nil]
        ))

        #expect(resolver.resolve(sessionCWD: "/Users/dev/project") == nil)
    }

    @Test("ambiguous: shared cwd never guesses a Claude process")
    func ambiguousDoesNotGuess() {
        let ps = """
          700     1 ??       Fri Jul 10 09:00:00 2026 /Applications/iTerm.app/Contents/MacOS/iTerm2
          701   700 ttys001  Fri Jul 10 09:01:00 2026 /bin/zsh
          702   701 ttys001  Fri Jul 10 09:02:00 2026 claude
          703   701 ttys002  Fri Jul 10 10:02:00 2026 /opt/homebrew/bin/claude --resume abc
        """
        let cwd = "/Users/dev/shared-project"
        let resolver = TerminalLinkResolver(snapshots: FakeTerminalSnapshots(
            ps: ps,
            lsofByPID: [702: lsofCWD(cwd), 703: lsofCWD(cwd)]
        ))

        let target = resolver.resolve(sessionCWD: cwd)

        #expect(target == nil)
    }

    @Test("session id joins the live registry before an ambiguous cwd")
    func registryIdentityWins() {
        let ps = """
          700     1 ??       Fri Jul 10 09:00:00 2026 /Applications/iTerm.app/Contents/MacOS/iTerm2
          701   700 ttys001  Fri Jul 10 09:01:00 2026 /bin/zsh
          702   701 ttys001  Fri Jul 10 09:02:00 2026 claude
          703   701 ttys002  Fri Jul 10 10:02:00 2026 /opt/homebrew/bin/claude --resume other
        """
        let cwd = "/Users/dev/shared-project"
        let resolver = TerminalLinkResolver(
            snapshots: FakeTerminalSnapshots(
                ps: ps,
                lsofByPID: [702: lsofCWD(cwd), 703: lsofCWD(cwd)]
            ),
            registry: FakeTerminalRegistry(value: [
                TerminalSessionRegistryRecord(sessionID: "wanted", processID: 702, cwd: cwd),
                TerminalSessionRegistryRecord(sessionID: "other", processID: 703, cwd: cwd),
            ])
        )

        let resolution = resolver.resolve(
            sessionID: "wanted", cwd: cwd, machineID: Machine.localID
        )

        guard case .target(let target) = resolution else {
            Issue.record("expected an exact registry target, got \(resolution)")
            return
        }
        #expect(target.processID == 702)
        #expect(target.match == .sessionID)
        #expect(target.tty == "/dev/ttys001")
    }

    @Test("a stale exact registry PID never falls through to a cwd peer")
    func staleRegistryDoesNotRetarget() {
        let cwd = "/Users/dev/shared-project"
        let ps = """
          703     1 ttys002  Fri Jul 10 10:02:00 2026 /opt/homebrew/bin/claude
        """
        let resolver = TerminalLinkResolver(
            snapshots: FakeTerminalSnapshots(ps: ps, lsofByPID: [703: lsofCWD(cwd)]),
            registry: FakeTerminalRegistry(value: [
                TerminalSessionRegistryRecord(sessionID: "wanted", processID: 702, cwd: cwd)
            ])
        )

        #expect(resolver.resolve(
            sessionID: "wanted", cwd: cwd, machineID: Machine.localID
        ) == .notLive)
    }

    @Test("typed cwd fallback reports ambiguity")
    func typedAmbiguity() {
        let cwd = "/Users/dev/shared-project"
        let ps = """
          702     1 ttys001  Fri Jul 10 09:02:00 2026 claude
          703     1 ttys002  Fri Jul 10 10:02:00 2026 claude --resume other
        """
        let resolver = TerminalLinkResolver(
            snapshots: FakeTerminalSnapshots(
                ps: ps,
                lsofByPID: [702: lsofCWD(cwd), 703: lsofCWD(cwd)]
            ),
            registry: FakeTerminalRegistry()
        )

        #expect(resolver.resolve(
            sessionID: "unregistered", cwd: cwd, machineID: Machine.localID
        ) == .ambiguous)
    }

    @Test("none: unrelated processes and cwd mismatches produce no target")
    func none() {
        let ps = """
          800     1 ??       Fri Jul 10 09:00:00 2026 /Applications/Safari.app/Contents/MacOS/Safari
          801   800 ttys003  Fri Jul 10 09:01:00 2026 /usr/local/bin/claude
        """
        let resolver = TerminalLinkResolver(snapshots: FakeTerminalSnapshots(
            ps: ps,
            lsofByPID: [801: lsofCWD("/Users/dev/a-different-project")]
        ))

        #expect(resolver.resolve(sessionCWD: "/Users/dev/wanted-project") == nil)
    }

    @Test("Ghostty resolves for app-level fallback but not exact targeting")
    func ghosttyUsesTierTwo() {
        let ps = """
          900     1 ??       Fri Jul 10 09:00:00 2026 /Applications/Ghostty.app/Contents/MacOS/ghostty
          901   900 ttys009  Fri Jul 10 09:01:00 2026 /bin/zsh
          902   901 ttys009  Fri Jul 10 09:02:00 2026 /usr/local/bin/claude
        """
        let resolver = TerminalLinkResolver(snapshots: FakeTerminalSnapshots(
            ps: ps,
            lsofByPID: [902: lsofCWD("/Users/dev/project")]
        ))

        let target = resolver.resolve(sessionCWD: "/Users/dev/project")

        #expect(target?.ownerApplication == .ghostty)
        #expect(target?.ownerProcessID == 900)
        #expect(target?.supportsExactTargeting == false)
    }

    @Test("parser accepts tabular lsof diagnostics and rejects malformed ps")
    func parserTolerance() {
        let tabular = "claude 100 test cwd DIR 1,2 64 123 /Users/dev/My Project\n"
        #expect(TerminalLinkResolver.parseWorkingDirectory(tabular) == "/Users/dev/My Project")
        #expect(TerminalLinkResolver.parseProcessList("not ps output").isEmpty)
        #expect(TerminalLinkResolver.normalizedTTY("ttys004") == "/dev/ttys004")
        #expect(TerminalLinkResolver.normalizedTTY("??") == nil)
    }
}

private struct FixedTerminalResolver: TerminalLinkResolving {
    let resolution: TerminalLinkResolution

    func resolve(sessionID: String, cwd: String,
                 machineID: String) -> TerminalLinkResolution {
        resolution
    }
}

@MainActor
private final class FakeExactTargeter: TerminalExactTargeting {
    var result: TerminalExactTargetResult
    private(set) var calls: [(String, TerminalApplication)] = []

    init(_ result: TerminalExactTargetResult) { self.result = result }

    func target(tty: String,
                application: TerminalApplication) -> TerminalExactTargetResult {
        calls.append((tty, application))
        return result
    }
}

@MainActor
private final class FakeOwnerActivator: TerminalOwnerActivating {
    var result: Bool
    private(set) var processIDs: [Int32] = []

    init(_ result: Bool) { self.result = result }

    func activate(processID: Int32) -> Bool {
        processIDs.append(processID)
        return result
    }
}

@MainActor
private final class FakeTerminalWindows: TerminalWindowAdapting {
    var frontWindow: String
    var selectedSessionID: String?
    private(set) var events: [String] = []
    private(set) var outcomes: [TerminalLaunchOutcome] = []

    init(frontWindow: String = "main", selectedSessionID: String? = nil) {
        self.frontWindow = frontWindow
        self.selectedSessionID = selectedSessionID
    }

    func openMainWindow() {
        frontWindow = "main"
        events.append("open:main")
    }

    func selectSession(id: String) {
        selectedSessionID = id
        events.append("select:\(id)")
    }

    func revealTranscript(sessionID: String, outcome: TerminalLaunchOutcome) {
        outcomes.append(outcome)
        events.append("reveal:\(sessionID)")
    }
}

private func launchTarget(ownerProcessID: Int32? = 500,
                          application: TerminalApplication? = .terminal,
                          tty: String? = "/dev/ttys005") -> TerminalLinkTarget {
    TerminalLinkTarget(
        processID: 502,
        tty: tty,
        startedAt: Date(timeIntervalSince1970: 1_700_000_000),
        ownerProcessID: ownerProcessID,
        ownerApplication: application,
        match: .sessionID
    )
}

@Suite("Observable terminal launch flow")
@MainActor
struct TerminalLaunchFlowTests {
    @Test("exact tab targeting returns exact and does not show transcript")
    func exact() async {
        let target = launchTarget()
        let exact = FakeExactTargeter(.targeted)
        let owner = FakeOwnerActivator(true)
        let windows = FakeTerminalWindows()
        let flow = TerminalLaunchFlow(
            resolver: FixedTerminalResolver(resolution: .target(target)),
            exactTargeter: exact,
            ownerActivator: owner,
            windows: windows
        )

        let outcome = await flow.open(
            sessionID: "session-a", cwd: "/repo", machineID: Machine.localID
        )

        #expect(outcome == .exact(target))
        #expect(exact.calls.count == 1)
        #expect(owner.processIDs.isEmpty)
        #expect(windows.events.isEmpty)
    }

    @Test("TCC denial preserves the AppleScript dictionary and reveals transcript")
    func permissionDenied() async {
        let error = TerminalAutomationError(
            number: -1743,
            message: "Not authorized to send Apple events",
            dictionary: [
                "NSAppleScriptErrorNumber": "-1743",
                "NSAppleScriptErrorMessage": "Not authorized to send Apple events",
            ]
        )
        let windows = FakeTerminalWindows()
        let flow = TerminalLaunchFlow(
            resolver: FixedTerminalResolver(resolution: .target(launchTarget())),
            exactTargeter: FakeExactTargeter(.permissionDenied(error)),
            ownerActivator: FakeOwnerActivator(true),
            windows: windows
        )

        let outcome = await flow.open(
            sessionID: "session-a", cwd: "/repo", machineID: Machine.localID
        )

        #expect(outcome == .permissionDenied(error))
        #expect(windows.events == ["open:main", "select:session-a", "reveal:session-a"])
        #expect(windows.outcomes == [.permissionDenied(error)])
    }

    @Test("missing exact tab activates its known terminal owner")
    func missingTabActivatesOwner() async {
        let target = launchTarget()
        let owner = FakeOwnerActivator(true)
        let windows = FakeTerminalWindows()
        let flow = TerminalLaunchFlow(
            resolver: FixedTerminalResolver(resolution: .target(target)),
            exactTargeter: FakeExactTargeter(.notFound),
            ownerActivator: owner,
            windows: windows
        )

        let outcome = await flow.open(
            sessionID: "session-a", cwd: "/repo", machineID: Machine.localID
        )

        #expect(outcome == .ownerActivated(target))
        #expect(owner.processIDs == [500])
        #expect(windows.events.isEmpty)
    }

    @Test("daemon with no terminal owner visibly falls back")
    func daemonFallsBack() async {
        let windows = FakeTerminalWindows()
        let flow = TerminalLaunchFlow(
            resolver: FixedTerminalResolver(
                resolution: .target(launchTarget(
                    ownerProcessID: nil, application: nil, tty: nil
                ))
            ),
            exactTargeter: FakeExactTargeter(.notFound),
            ownerActivator: FakeOwnerActivator(false),
            windows: windows
        )

        let outcome = await flow.open(
            sessionID: "daemon", cwd: "/repo", machineID: Machine.localID
        )

        #expect(outcome == .failed(.noTerminalOwner))
        #expect(windows.events == ["open:main", "select:daemon", "reveal:daemon"])
    }

    @Test("ambiguous resolution visibly falls back")
    func ambiguousFallsBack() async {
        let windows = FakeTerminalWindows()
        let flow = TerminalLaunchFlow(
            resolver: FixedTerminalResolver(resolution: .ambiguous),
            exactTargeter: FakeExactTargeter(.notFound),
            ownerActivator: FakeOwnerActivator(false),
            windows: windows
        )

        let outcome = await flow.open(
            sessionID: "ambiguous", cwd: "/repo", machineID: Machine.localID
        )

        #expect(outcome == .ambiguous)
        #expect(outcome.fallbackMessage == "Multiple live terminals matched — showing transcript")
        #expect(windows.events == ["open:main", "select:ambiguous", "reveal:ambiguous"])
    }

    @Test("already-selected inspector still receives a fresh reveal")
    func alreadySelectedStillReveals() async {
        let windows = FakeTerminalWindows(
            frontWindow: "main", selectedSessionID: "selected"
        )
        let flow = TerminalLaunchFlow(
            resolver: FixedTerminalResolver(resolution: .notLive),
            exactTargeter: FakeExactTargeter(.notFound),
            ownerActivator: FakeOwnerActivator(false),
            windows: windows
        )

        _ = await flow.open(
            sessionID: "selected", cwd: "/repo", machineID: Machine.localID
        )

        #expect(windows.events == ["open:main", "select:selected", "reveal:selected"])
        #expect(windows.outcomes.count == 1)
    }

    @Test("Settings-front fallback opens the main window before selecting")
    func settingsFront() async {
        let windows = FakeTerminalWindows(frontWindow: "Settings")
        let flow = TerminalLaunchFlow(
            resolver: FixedTerminalResolver(resolution: .notLive),
            exactTargeter: FakeExactTargeter(.notFound),
            ownerActivator: FakeOwnerActivator(false),
            windows: windows
        )

        _ = await flow.open(
            sessionID: "session-a", cwd: "/repo", machineID: Machine.localID
        )

        #expect(windows.frontWindow == "main")
        #expect(windows.events.first == "open:main")
    }

    @Test("remote Transcript path never invokes the local resolver")
    func remoteSkipsResolver() async {
        let windows = FakeTerminalWindows()
        let flow = TerminalLaunchFlow(
            resolver: FixedTerminalResolver(
                resolution: .failed("local resolver was invoked")
            ),
            exactTargeter: FakeExactTargeter(.notFound),
            ownerActivator: FakeOwnerActivator(false),
            windows: windows
        )

        let outcome = await flow.open(
            sessionID: "remote", cwd: "/repo", machineID: "buildbox"
        )

        #expect(outcome == .notLive)
        #expect(windows.events == ["open:main", "select:remote", "reveal:remote"])
    }
}
