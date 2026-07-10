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
            lsofByPID: [502: lsofCWD("/Users/test/Developer/trifola")]
        ))

        let target = resolver.resolve(sessionCWD: "/Users/test/Developer/trifola/")

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

        #expect(resolver.resolve(sessionCWD: "/Users/test/project") == nil)
    }

    @Test("ambiguous: the newest Claude process with the same cwd wins")
    func ambiguousNewestWins() {
        let ps = """
          700     1 ??       Fri Jul 10 09:00:00 2026 /Applications/iTerm.app/Contents/MacOS/iTerm2
          701   700 ttys001  Fri Jul 10 09:01:00 2026 /bin/zsh
          702   701 ttys001  Fri Jul 10 09:02:00 2026 claude
          703   701 ttys002  Fri Jul 10 10:02:00 2026 /opt/homebrew/bin/claude --resume abc
        """
        let cwd = "/Users/test/shared-project"
        let resolver = TerminalLinkResolver(snapshots: FakeTerminalSnapshots(
            ps: ps,
            lsofByPID: [702: lsofCWD(cwd), 703: lsofCWD(cwd)]
        ))

        let target = resolver.resolve(sessionCWD: cwd)

        #expect(target?.processID == 703)
        #expect(target?.tty == "/dev/ttys002")
        #expect(target?.ownerApplication == .iTerm2)
        #expect(target?.supportsExactTargeting == true)
    }

    @Test("none: unrelated processes and cwd mismatches produce no target")
    func none() {
        let ps = """
          800     1 ??       Fri Jul 10 09:00:00 2026 /Applications/Safari.app/Contents/MacOS/Safari
          801   800 ttys003  Fri Jul 10 09:01:00 2026 /usr/local/bin/claude
        """
        let resolver = TerminalLinkResolver(snapshots: FakeTerminalSnapshots(
            ps: ps,
            lsofByPID: [801: lsofCWD("/Users/test/a-different-project")]
        ))

        #expect(resolver.resolve(sessionCWD: "/Users/test/wanted-project") == nil)
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
            lsofByPID: [902: lsofCWD("/Users/test/project")]
        ))

        let target = resolver.resolve(sessionCWD: "/Users/test/project")

        #expect(target?.ownerApplication == .ghostty)
        #expect(target?.ownerProcessID == 900)
        #expect(target?.supportsExactTargeting == false)
    }

    @Test("parser accepts tabular lsof diagnostics and rejects malformed ps")
    func parserTolerance() {
        let tabular = "claude 100 test cwd DIR 1,2 64 123 /Users/test/My Project\n"
        #expect(TerminalLinkResolver.parseWorkingDirectory(tabular) == "/Users/test/My Project")
        #expect(TerminalLinkResolver.parseProcessList("not ps output").isEmpty)
        #expect(TerminalLinkResolver.normalizedTTY("ttys004") == "/dev/ttys004")
        #expect(TerminalLinkResolver.normalizedTTY("??") == nil)
    }
}
