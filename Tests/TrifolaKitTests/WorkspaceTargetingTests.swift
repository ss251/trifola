import Foundation
import Testing
@testable import TrifolaKit

@Suite("Workspace candidate scoring")
struct WorkspaceTargetingTests {
    private func identity(
        sessionID: String = "1881b475-1111-2222-3333-444455556666",
        sessionName: String? = nil,
        cwd: String = "/Users/dev/Developer/trifola",
        project: String = "trifola",
        tty: String? = "/dev/ttys009",
        command: String? = "/opt/claude/versions/2.1.202 --resume 1881b475"
    ) -> WorkspaceTargetIdentity {
        WorkspaceTargetIdentity(
            sessionID: sessionID,
            sessionName: sessionName,
            cwd: cwd,
            project: project,
            tty: tty,
            processCommand: command)
    }

    @Test("real session name beats unrelated multi-workspace titles")
    func multiWorkspaceSessionName() {
        let candidates = [
            WorkspaceCandidate(id: "0", role: "AXRow", title: "brisk-ember"),
            WorkspaceCandidate(id: "1", role: "AXRow", title: "portfolio"),
            WorkspaceCandidate(id: "2", role: "AXRow", title: "quiet-river"),
        ]

        let result = WorkspaceCandidateScorer.select(
            from: candidates,
            for: identity(
                sessionName: "portfolio",
                cwd: "/Users/dev/workspace",
                project: "workspace",
                command: "/opt/claude/versions/2.1.202 --resume portfolio"))

        guard case .matched(let match) = result else {
            Issue.record("expected the observed workspace title to match")
            return
        }
        #expect(match.candidate.id == "1")
        #expect(match.score >= WorkspaceCandidateScorer.minimumScore)
        #expect(match.evidence.contains(.sessionNameExact))
    }

    @Test("an exact project title is sufficient when unique")
    func exactProjectTitle() {
        let result = WorkspaceCandidateScorer.select(
            from: [
                WorkspaceCandidate(id: "a", role: "AXRow", title: "trifola"),
                WorkspaceCandidate(id: "b", role: "AXRow", title: "website"),
            ],
            for: identity(command: nil))

        guard case .matched(let match) = result else {
            Issue.record("expected a unique exact project title")
            return
        }
        #expect(match.candidate.id == "a")
        #expect(match.evidence.contains(.projectExact))
    }

    @Test("Ghostty short-cwd title segment matches")
    func ghosttyTitle() {
        let result = WorkspaceCandidateScorer.select(
            from: [
                WorkspaceCandidate(
                    id: "wanted", role: "AXRadioButton",
                    title: "trifola — claude"),
                WorkspaceCandidate(
                    id: "decoy", role: "AXRadioButton",
                    title: "docs — zsh"),
            ],
            for: identity(command: "/usr/local/bin/claude"))

        guard case .matched(let match) = result else {
            Issue.record("expected Ghostty's short-cwd segment to match")
            return
        }
        #expect(match.candidate.id == "wanted")
        #expect(match.evidence.contains(.projectSegment))
        #expect(match.evidence.contains(.processCommand))
    }

    @Test("VS Code folder title segment matches without app-specific policy")
    func vsCodeTitle() {
        let result = WorkspaceCandidateScorer.select(
            from: [
                WorkspaceCandidate(
                    id: "wanted", role: "AXRow",
                    title: "trifola — SessionsScreen.swift"),
                WorkspaceCandidate(
                    id: "decoy", role: "AXRow",
                    title: "website — index.ts"),
            ],
            for: identity(command: nil))

        guard case .matched(let match) = result else {
            Issue.record("expected VS Code's folder segment to match")
            return
        }
        #expect(match.candidate.id == "wanted")
        #expect(match.score == 70)
    }

    @Test("full cwd, tty, and session prefix are independently strong")
    func transportEvidence() {
        let probes: [(WorkspaceCandidate, WorkspaceMatchEvidence)] = [
            (WorkspaceCandidate(
                id: "cwd", role: "AXWindow",
                document: "file:///Users/dev/Developer/trifola"),
             .fullWorkingDirectory),
            (WorkspaceCandidate(
                id: "tty", role: "AXRadioButton", label: "ttys009"),
             .tty),
            (WorkspaceCandidate(
                id: "session", role: "AXRow", title: "1881b475"),
             .sessionIDPrefix),
        ]

        for (candidate, evidence) in probes {
            guard case .matched(let match) = WorkspaceCandidateScorer.select(
                from: [candidate], for: identity(project: "", command: nil)) else {
                Issue.record("expected \(evidence.rawValue) to clear the threshold")
                continue
            }
            #expect(match.evidence.contains(evidence))
        }
    }

    @Test("ties and near-ties are honest misses")
    func tiesMiss() {
        let tied = [
            WorkspaceCandidate(id: "a", role: "AXRow", title: "trifola"),
            WorkspaceCandidate(id: "b", role: "AXRow", title: "trifola"),
        ]
        #expect(WorkspaceCandidateScorer.select(
            from: tied, for: identity(command: nil)) == .noConfidentMatch)

        let near = [
            WorkspaceCandidate(id: "a", role: "AXRow", title: "trifola"),
            WorkspaceCandidate(id: "b", role: "AXRow", title: "trifola — zsh"),
        ]
        #expect(WorkspaceCandidateScorer.select(
            from: near, for: identity(command: nil)) == .noConfidentMatch)
    }

    @Test("weak substrings and generic labels stay below threshold")
    func weakEvidenceMisses() {
        let candidates = [
            WorkspaceCandidate(id: "a", role: "AXRow", title: "trifola-notes"),
            WorkspaceCandidate(id: "b", role: "AXWindow", title: "Terminal"),
        ]
        #expect(WorkspaceCandidateScorer.select(
            from: candidates, for: identity(command: nil)) == .noConfidentMatch)
    }

    @Test("strong transport signals reject prefix collisions")
    func strongSignalBoundaries() {
        let decoys = [
            WorkspaceCandidate(
                id: "cwd", role: "AXRow",
                document: "file:///Users/dev/Developer/trifola-copy"),
            WorkspaceCandidate(
                id: "tty", role: "AXRadioButton", label: "ttys0099"),
            WorkspaceCandidate(
                id: "session", role: "AXRow", title: "1881b4750"),
        ]
        for decoy in decoys {
            #expect(WorkspaceCandidateScorer.select(
                from: [decoy],
                for: identity(project: "", command: nil)) == .noConfidentMatch)
        }
    }
}

@Suite("Workspace AX safety policy")
struct WorkspaceAXSafetyPolicyTests {
    @Test("verified sidebar labels strip only the observed status marker")
    func sidebarParsing() {
        let marked = WorkspaceSidebarRefinementPolicy.parse(
            identifier: "sidebarWorkspace.1",
            label: "✳ portfolio, workspace 2 of 3")
        #expect(marked == .init(
            identifier: "sidebarWorkspace.1",
            title: "portfolio",
            position: 2,
            total: 3))

        let legitimateSymbol = WorkspaceSidebarRefinementPolicy.parse(
            identifier: "sidebarWorkspace.2",
            label: "$ portfolio, workspace 3 of 3")
        #expect(legitimateSymbol?.title == "$ portfolio")
        #expect(WorkspaceSidebarRefinementPolicy.parse(
            identifier: "unrelated.1",
            label: "portfolio, workspace 1 of 1") == nil)
        #expect(WorkspaceSidebarRefinementPolicy
            .focusedWindowTitleMatchesExactly(
                "✳  Portfolio ", expected: "portfolio"))
        #expect(!WorkspaceSidebarRefinementPolicy
            .focusedWindowTitleMatchesExactly(
                "portfolio — shell", expected: "portfolio"))
    }

    @Test("sidebar refinement requires its exact observed ancestry")
    func sidebarAncestry() {
        #expect(WorkspaceSidebarRefinementPolicy.hasObservedAncestry(
            depth: 5,
            parentRole: "AXOpaqueProviderGroup",
            ancestorRoles: ["AXWindow", "AXScrollArea"],
            ancestorIdentifiers: [nil, "Sidebar"]))
        #expect(!WorkspaceSidebarRefinementPolicy.hasObservedAncestry(
            depth: 5,
            parentRole: "AXGroup",
            ancestorRoles: ["AXWindow", "AXScrollArea"],
            ancestorIdentifiers: [nil, "Sidebar"]))
        #expect(!WorkspaceSidebarRefinementPolicy.hasObservedAncestry(
            depth: 7,
            parentRole: "AXOpaqueProviderGroup",
            ancestorRoles: ["AXWindow", "AXScrollArea"],
            ancestorIdentifiers: [nil, "Sidebar"]))
        #expect(WorkspaceSidebarRefinementPolicy.hasObservedActivationHelp(
            WorkspaceSidebarRefinementPolicy.activationHelp))
        #expect(!WorkspaceSidebarRefinementPolicy.hasObservedActivationHelp(
            "Move this item"))
    }

    @Test("sidebar refinement acts only on a completely enumerated list")
    func sidebarCompleteness() {
        let entries = (1...3).map { position in
            WorkspaceSidebarRefinementPolicy.Entry(
                identifier: "sidebarWorkspace.\(position)",
                title: "workspace-\(position)",
                position: position,
                total: 3)
        }
        #expect(WorkspaceSidebarRefinementPolicy.isCompleteSurface(
            entries,
            directChildCount: 3,
            parentChildrenReadComplete: true))
        #expect(!WorkspaceSidebarRefinementPolicy.isCompleteSurface(
            Array(entries.dropLast()),
            directChildCount: 3,
            parentChildrenReadComplete: true))
        #expect(!WorkspaceSidebarRefinementPolicy.isCompleteSurface(
            entries,
            directChildCount: 4,
            parentChildrenReadComplete: true))
        #expect(!WorkspaceSidebarRefinementPolicy.isCompleteSurface(
            entries,
            directChildCount: 3,
            parentChildrenReadComplete: false))
    }

    @Test("generic controls require navigation ancestry and never menus")
    func genericControlGating() {
        #expect(WorkspaceAXSafetyPolicy.genericControlIsEligible(
            role: "AXButton",
            ancestorRoles: ["AXWebArea", "AXList"],
            supportsSelection: true))
        #expect(!WorkspaceAXSafetyPolicy.genericControlIsEligible(
            role: "AXButton",
            ancestorRoles: ["AXWebArea"],
            supportsSelection: true))
        #expect(!WorkspaceAXSafetyPolicy.genericControlIsEligible(
            role: "AXButton",
            ancestorRoles: ["AXMenu", "AXList"],
            supportsSelection: true))
        #expect(!WorkspaceAXSafetyPolicy.genericControlIsEligible(
            role: "AXStaticText",
            ancestorRoles: ["AXList"],
            supportsSelection: true))
    }

    @Test("generic and shallow-refinement completeness fail closed")
    func traversalCompleteness() {
        #expect(WorkspaceAXSafetyPolicy.genericTraversalIsComplete(
            hitNodeLimit: false,
            hitTimeLimit: false,
            hitDepthLimit: false,
            hitReadFailure: false))
        #expect(!WorkspaceAXSafetyPolicy.genericTraversalIsComplete(
            hitNodeLimit: false,
            hitTimeLimit: false,
            hitDepthLimit: false,
            hitReadFailure: true))
        #expect(!WorkspaceAXSafetyPolicy.genericTraversalIsComplete(
            hitNodeLimit: false,
            hitTimeLimit: false,
            hitDepthLimit: true,
            hitReadFailure: false))

        #expect(WorkspaceAXSafetyPolicy.scopedSurfaceTraversalIsComplete(
            surfaceDepth: 5,
            shallowestReadFailureDepth: 8,
            minimumUnvisitedDepth: 6))
        #expect(!WorkspaceAXSafetyPolicy.scopedSurfaceTraversalIsComplete(
            surfaceDepth: 5,
            shallowestReadFailureDepth: 4,
            minimumUnvisitedDepth: nil))
        #expect(!WorkspaceAXSafetyPolicy.scopedSurfaceTraversalIsComplete(
            surfaceDepth: 5,
            shallowestReadFailureDepth: nil,
            minimumUnvisitedDepth: 5))
    }

    @Test("only vanished traversal elements are safe to omit")
    func invalidatedTraversalElements() {
        #expect(!WorkspaceAXSafetyPolicy.traversalReadCompromisesCompleteness(
            requiredAttribute: true,
            benignAbsence: false,
            invalidatedElement: true))
        #expect(!WorkspaceAXSafetyPolicy.traversalReadCompromisesCompleteness(
            requiredAttribute: false,
            benignAbsence: true,
            invalidatedElement: false))
        #expect(WorkspaceAXSafetyPolicy.traversalReadCompromisesCompleteness(
            requiredAttribute: false,
            benignAbsence: false,
            invalidatedElement: true))
        #expect(WorkspaceAXSafetyPolicy.traversalReadCompromisesCompleteness(
            requiredAttribute: true,
            benignAbsence: true,
            invalidatedElement: false))
        #expect(WorkspaceAXSafetyPolicy.traversalReadCompromisesCompleteness(
            requiredAttribute: false,
            benignAbsence: false,
            invalidatedElement: false))
    }
}

@Suite("Bundled workspace control policy")
struct WorkspaceBundledControlPolicyTests {
    private let firstWindow = "11111111-1111-4111-8111-111111111111"
    private let secondWindow = "22222222-2222-4222-8222-222222222222"
    private let targetWorkspace = "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"
    private let otherWorkspace = "BBBBBBBB-BBBB-4BBB-8BBB-BBBBBBBBBBBB"
    private let secondWindowWorkspace = "CCCCCCCC-CCCC-4CCC-8CCC-CCCCCCCCCCCC"

    @Test("capability contract is exact and versioned")
    func capabilityContract() {
        let supported = json("""
        {
          "version": 2,
          "methods": [
            "system.top", "window.current", "window.focus", "window.list",
            "workspace.current", "workspace.select", "unrelated.method"
          ]
        }
        """)
        #expect(WorkspaceBundledControlPolicy
            .supportsExpectedCapabilities(supported))

        let oldVersion = json("""
        {
          "version": 1,
          "methods": [
            "system.top", "window.current", "window.focus", "window.list",
            "workspace.current", "workspace.select"
          ]
        }
        """)
        #expect(!WorkspaceBundledControlPolicy
            .supportsExpectedCapabilities(oldVersion))

        let missingMutation = json("""
        {
          "version": 2,
          "methods": [
            "system.top", "window.current", "window.focus", "window.list",
            "workspace.current"
          ]
        }
        """)
        #expect(!WorkspaceBundledControlPolicy
            .supportsExpectedCapabilities(missingMutation))
    }

    @Test("window enumeration rejects duplicates and incomplete records")
    func windowEnumeration() {
        let valid = json("""
        {
          "windows": [
            {"id": "\(firstWindow)", "workspace_count": 2},
            {"id": "\(secondWindow)", "workspace_count": 1}
          ]
        }
        """)
        #expect(WorkspaceBundledControlPolicy.windowIDs(from: valid)
            == [firstWindow, secondWindow])

        let duplicate = json("""
        {
          "windows": [
            {"id": "\(firstWindow)", "workspace_count": 2},
            {"id": "\(firstWindow)", "workspace_count": 1}
          ]
        }
        """)
        #expect(WorkspaceBundledControlPolicy.windowIDs(from: duplicate) == nil)

        let emptyWindow = json("""
        {"windows": [{"id": "\(firstWindow)", "workspace_count": 0}]}
        """)
        #expect(WorkspaceBundledControlPolicy.windowIDs(
            from: emptyWindow) == nil)
    }

    @Test("session PID maps to one UUID target with an AX-title cross-check")
    func uniquePIDMapping() {
        let snapshots = validSnapshots()
        let expected = WorkspaceBundledControlTarget(
            windowID: firstWindow,
            windowRef: "window:1",
            workspaceID: targetWorkspace,
            workspaceRef: "workspace:2",
            matchedTitle: "atlas")
        #expect(WorkspaceBundledControlPolicy.target(
            from: snapshots,
            ownerProcessID: 400,
            sessionProcessID: 701,
            matchedTitle: "atlas") == expected)
        #expect(WorkspaceBundledControlPolicy.target(
            from: snapshots,
            ownerProcessID: 400,
            sessionProcessID: 701,
            matchedTitle: "other") == nil)
        #expect(WorkspaceBundledControlPolicy.target(
            from: snapshots,
            ownerProcessID: 999,
            sessionProcessID: 701,
            matchedTitle: "atlas") == nil)
    }

    @Test("duplicate PID ownership and malformed refs fail closed")
    func ambiguousOrMalformedMapping() {
        var duplicate = validSnapshots()
        duplicate[secondWindow] = secondSnapshot(pids: [701, 800])
        #expect(WorkspaceBundledControlPolicy.target(
            from: duplicate,
            ownerProcessID: 400,
            sessionProcessID: 701,
            matchedTitle: "atlas") == nil)

        var malformed = validSnapshots()
        malformed[firstWindow] = firstSnapshot(
            targetRef: "workspace:02")
        #expect(WorkspaceBundledControlPolicy.target(
            from: malformed,
            ownerProcessID: 400,
            sessionProcessID: 701,
            matchedTitle: "atlas") == nil)
    }

    @Test("verification requires exact current UUIDs and stable PID ownership")
    func exactVerification() {
        let target = WorkspaceBundledControlTarget(
            windowID: firstWindow,
            windowRef: "window:1",
            workspaceID: targetWorkspace,
            workspaceRef: "workspace:2",
            matchedTitle: "atlas")
        #expect(WorkspaceBundledControlPolicy.verifies(
            target,
            currentWindowOutput: Data("\(firstWindow)\n".utf8),
            currentWorkspaceOutput: Data("\(targetWorkspace)\n".utf8),
            targetWindowSnapshot: firstSnapshot(),
            ownerProcessID: 400,
            sessionProcessID: 701))
        #expect(!WorkspaceBundledControlPolicy.verifies(
            target,
            currentWindowOutput: Data("\(secondWindow)\n".utf8),
            currentWorkspaceOutput: Data("\(targetWorkspace)\n".utf8),
            targetWindowSnapshot: firstSnapshot(),
            ownerProcessID: 400,
            sessionProcessID: 701))
        #expect(!WorkspaceBundledControlPolicy.verifies(
            target,
            currentWindowOutput: Data("\(firstWindow)\n".utf8),
            currentWorkspaceOutput: Data("\(targetWorkspace)\nextra".utf8),
            targetWindowSnapshot: firstSnapshot(),
            ownerProcessID: 400,
            sessionProcessID: 701))
        #expect(!WorkspaceBundledControlPolicy.verifies(
            target,
            currentWindowOutput: Data("\(firstWindow)\n".utf8),
            currentWorkspaceOutput: Data("\(targetWorkspace)\n".utf8),
            targetWindowSnapshot: firstSnapshot(targetPIDs: [702]),
            ownerProcessID: 400,
            sessionProcessID: 701))
    }

    private func validSnapshots() -> [String: Data] {
        [
            firstWindow: firstSnapshot(),
            secondWindow: secondSnapshot(),
        ]
    }

    private func firstSnapshot(
        targetRef: String = "workspace:2",
        targetPIDs: [Int] = [701, 702]
    ) -> Data {
        json("""
        {
          "windows": [{
            "id": "\(firstWindow)",
            "ref": "window:1",
            "app_process_pids": [400],
            "workspaces": [
              {
                "id": "\(otherWorkspace)",
                "ref": "workspace:1",
                "title": "home",
                "resources": {"pids": [101]}
              },
              {
                "id": "\(targetWorkspace)",
                "ref": "\(targetRef)",
                "title": "✳ atlas",
                "resources": {"pids": \(array(targetPIDs))}
              }
            ]
          }]
        }
        """)
    }

    private func secondSnapshot(pids: [Int] = [800]) -> Data {
        json("""
        {
          "windows": [{
            "id": "\(secondWindow)",
            "ref": "window:2",
            "app_process_pids": [400],
            "workspaces": [{
              "id": "\(secondWindowWorkspace)",
              "ref": "workspace:3",
              "title": "docs",
              "resources": {"pids": \(array(pids))}
            }]
          }]
        }
        """)
    }

    private func array(_ values: [Int]) -> String {
        "[\(values.map(String.init).joined(separator: ","))]"
    }

    private func json(_ value: String) -> Data {
        Data(value.utf8)
    }
}
