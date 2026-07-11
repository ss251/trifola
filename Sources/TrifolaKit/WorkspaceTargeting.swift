import Foundation

/// Stable, AppKit-free identity evidence for matching a live session to one
/// selectable workspace in its owning terminal application.
public struct WorkspaceTargetIdentity: Sendable, Equatable {
    public let sessionID: String
    public let sessionName: String?
    public let cwd: String
    public let project: String
    public let gitBranch: String?
    public let tty: String?
    public let processCommand: String?

    public init(
        sessionID: String,
        sessionName: String? = nil,
        cwd: String,
        project: String = "",
        gitBranch: String? = nil,
        tty: String? = nil,
        processCommand: String? = nil
    ) {
        self.sessionID = sessionID
        self.sessionName = sessionName
        self.cwd = cwd
        self.project = project
        self.gitBranch = gitBranch
        self.tty = tty
        self.processCommand = processCommand
    }

    public var sessionIDPrefix: String {
        String(sessionID.prefix(8))
    }

    public var cwdBasename: String {
        URL(fileURLWithPath: cwd).lastPathComponent
    }
}

/// Complete request passed to an ordered workspace-targeting strategy.
public struct WorkspaceTargetRequest: Sendable, Equatable {
    public let target: TerminalLinkTarget
    public let identity: WorkspaceTargetIdentity

    public init(target: TerminalLinkTarget, identity: WorkspaceTargetIdentity) {
        self.target = target
        self.identity = identity
    }

    public init(
        target: TerminalLinkTarget,
        sessionID: String,
        sessionName: String? = nil,
        cwd: String,
        project: String = "",
        gitBranch: String? = nil
    ) {
        self.init(
            target: target,
            identity: WorkspaceTargetIdentity(
                sessionID: sessionID,
                sessionName: sessionName,
                cwd: cwd,
                project: project,
                gitBranch: gitBranch,
                tty: target.tty,
                processCommand: target.processCommand))
    }
}

/// A pure descriptor for one title-bearing AX element. The executable target
/// retains the corresponding AXUIElement behind this opaque traversal id.
public struct WorkspaceCandidate: Sendable, Equatable, Identifiable {
    public let id: String
    public let role: String
    public let title: String?
    public let label: String?
    public let document: String?

    public init(
        id: String,
        role: String,
        title: String? = nil,
        label: String? = nil,
        document: String? = nil
    ) {
        self.id = id
        self.role = role
        self.title = title
        self.label = label
        self.document = document
    }

    /// Honest user-facing identity for a successful match. AX adapters should
    /// reject a candidate with no usable title before actuation.
    public var confirmationTitle: String? {
        for value in [title, label, document] {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}

public enum WorkspaceMatchEvidence: String, Sendable, Equatable, Hashable {
    case fullWorkingDirectory
    case tty
    case sessionIDPrefix
    case sessionNameExact
    case sessionNameSegment
    case projectExact
    case projectSegment
    case cwdBasenameExact
    case cwdBasenameSegment
    case gitBranch
    case processCommand
}

public struct WorkspaceCandidateMatch: Sendable, Equatable {
    public let candidate: WorkspaceCandidate
    public let score: Int
    public let evidence: [WorkspaceMatchEvidence]

    public init(
        candidate: WorkspaceCandidate,
        score: Int,
        evidence: [WorkspaceMatchEvidence]
    ) {
        self.candidate = candidate
        self.score = score
        self.evidence = evidence
    }
}

public enum WorkspaceCandidateSelection: Sendable, Equatable {
    case matched(WorkspaceCandidateMatch)
    case noConfidentMatch
}

/// Conservative, deterministic workspace matching. A project-only exact title
/// can clear the floor (a common multi-workspace shape), but duplicate project titles tie
/// and therefore miss. Partial substrings never count as strong identity.
public enum WorkspaceCandidateScorer {
    public static let minimumScore = 70
    public static let minimumLead = 15

    public static func select(
        from candidates: [WorkspaceCandidate],
        for identity: WorkspaceTargetIdentity
    ) -> WorkspaceCandidateSelection {
        var ranked: [WorkspaceCandidateMatch] = candidates.map { candidate in
            score(candidate, for: identity)
        }
        ranked.sort { lhs, rhs in
            if lhs.score == rhs.score {
                return lhs.candidate.id < rhs.candidate.id
            }
            return lhs.score > rhs.score
        }
        guard let winner = ranked.first,
              winner.score >= minimumScore else {
            return .noConfidentMatch
        }
        if ranked.count > 1,
           winner.score - ranked[1].score < minimumLead {
            return .noConfidentMatch
        }
        return .matched(winner)
    }

    public static func score(
        _ candidate: WorkspaceCandidate,
        for identity: WorkspaceTargetIdentity
    ) -> WorkspaceCandidateMatch {
        let allStrings = [candidate.title, candidate.label, candidate.document]
            .compactMap { value -> String? in
                guard let value else { return nil }
                let normalized = normalize(value)
                return normalized.isEmpty ? nil : normalized
            }
        let primaryStrings = [candidate.title, candidate.label]
            .compactMap { value -> String? in
                guard let value else { return nil }
                let normalized = normalize(value)
                return normalized.isEmpty ? nil : normalized
            }

        var value = 0
        var evidence: [WorkspaceMatchEvidence] = []

        let cwd = normalizePath(identity.cwd)
        if !cwd.isEmpty, allStrings.contains(where: {
            containsPathSignal(normalizePath($0), path: cwd)
        }) {
            value += 100
            evidence.append(.fullWorkingDirectory)
        }

        if let tty = normalizedTTY(identity.tty),
           allStrings.contains(where: { containsTokenSignal($0, signal: tty) }) {
            value += 90
            evidence.append(.tty)
        }

        let sessionPrefix = normalize(identity.sessionIDPrefix)
        if sessionPrefix.count >= 4,
           allStrings.contains(where: {
               containsTokenSignal($0, signal: sessionPrefix)
           }) {
            value += 85
            evidence.append(.sessionIDPrefix)
        }

        var seenNames: Set<String> = []
        if let sessionName = identity.sessionName.map(normalize),
           !sessionName.isEmpty,
           seenNames.insert(sessionName).inserted {
            addNameEvidence(
                sessionName,
                exact: .sessionNameExact,
                segment: .sessionNameSegment,
                exactScore: 85,
                segmentScore: 80,
                primaryStrings: primaryStrings,
                value: &value,
                evidence: &evidence)
        }
        let project = normalize(identity.project)
        if !project.isEmpty, seenNames.insert(project).inserted {
            addNameEvidence(
                project,
                exact: .projectExact,
                segment: .projectSegment,
                exactScore: 75,
                segmentScore: 70,
                primaryStrings: primaryStrings,
                value: &value,
                evidence: &evidence)
        }
        let basename = normalize(identity.cwdBasename)
        if !basename.isEmpty, seenNames.insert(basename).inserted {
            addNameEvidence(
                basename,
                exact: .cwdBasenameExact,
                segment: .cwdBasenameSegment,
                exactScore: 75,
                segmentScore: 70,
                primaryStrings: primaryStrings,
                value: &value,
                evidence: &evidence)
        }

        if let branch = identity.gitBranch.map(normalize), !branch.isEmpty,
           primaryStrings.contains(where: { segments(in: $0).contains(branch) }) {
            value += 35
            evidence.append(.gitBranch)
        }

        let commandHints = processCommandHints(identity.processCommand)
        if !commandHints.isEmpty,
           allStrings.contains(where: { string in
               let parts = segments(in: string)
               return !parts.isDisjoint(with: commandHints)
           }) {
            value += 20
            evidence.append(.processCommand)
        }

        return WorkspaceCandidateMatch(
            candidate: candidate,
            score: value,
            evidence: evidence)
    }

    private static func addNameEvidence(
        _ name: String,
        exact: WorkspaceMatchEvidence,
        segment: WorkspaceMatchEvidence,
        exactScore: Int,
        segmentScore: Int,
        primaryStrings: [String],
        value: inout Int,
        evidence: inout [WorkspaceMatchEvidence]
    ) {
        if primaryStrings.contains(name) {
            value += exactScore
            evidence.append(exact)
        } else if primaryStrings.contains(where: { segments(in: $0).contains(name) }) {
            value += segmentScore
            evidence.append(segment)
        }
    }

    private static func normalize(_ value: String) -> String {
        value
            .folding(options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func normalizePath(_ value: String) -> String {
        var normalized = normalize(value)
        if normalized.hasPrefix("file://") {
            normalized.removeFirst("file://".count)
        }
        while normalized.count > 1, normalized.hasSuffix("/") {
            normalized.removeLast()
        }
        return normalized.removingPercentEncoding ?? normalized
    }

    private static func normalizedTTY(_ value: String?) -> String? {
        guard var value = value.map(normalize), !value.isEmpty else { return nil }
        if value.hasPrefix("/dev/") { value.removeFirst("/dev/".count) }
        return value
    }

    private static func containsTokenSignal(
        _ value: String,
        signal: String
    ) -> Bool {
        containsDelimitedSignal(
            value,
            signal: signal,
            isContinuation: { character in
            character.unicodeScalars.allSatisfy {
                CharacterSet.alphanumerics.contains($0)
                    || CharacterSet(charactersIn: "_").contains($0)
            }
        })
    }

    private static func containsPathSignal(_ value: String, path: String) -> Bool {
        containsDelimitedSignal(
            value,
            signal: path,
            isContinuation: { character in
                character.unicodeScalars.allSatisfy {
                    CharacterSet.alphanumerics.contains($0)
                        || CharacterSet(charactersIn: "._-~%").contains($0)
                }
            },
            allowingSlashAfter: true)
    }

    /// Strong transport evidence must occupy a complete token/path component.
    /// A raw substring would let `ttys009` select `ttys0099`, or `/repo/foo`
    /// select `/repo/foobar`, which is exactly the kind of guessed target this
    /// scorer is designed to reject.
    private static func containsDelimitedSignal(
        _ value: String,
        signal: String,
        isContinuation: (Character) -> Bool,
        allowingSlashAfter: Bool = false
    ) -> Bool {
        guard !signal.isEmpty else { return false }
        var searchStart = value.startIndex
        while searchStart < value.endIndex,
              let range = value.range(
                  of: signal,
                  range: searchStart..<value.endIndex) {
            let before = range.lowerBound == value.startIndex
                ? nil : value[value.index(before: range.lowerBound)]
            let after = range.upperBound == value.endIndex
                ? nil : value[range.upperBound]
            let beforeIsClear = before.map { !isContinuation($0) } ?? true
            let afterIsClear = after.map {
                (allowingSlashAfter && $0 == "/") || !isContinuation($0)
            } ?? true
            if beforeIsClear && afterIsClear { return true }
            searchStart = range.upperBound
        }
        return false
    }

    /// Split common terminal title separators while preserving hyphenated
    /// project names such as `api-gateway`.
    private static func segments(in value: String) -> Set<String> {
        let separators = CharacterSet(charactersIn: "—–|·•:[](){}<>\t\n")
        return Set(value.components(separatedBy: separators)
            .map(normalize)
            .filter { !$0.isEmpty })
    }

    private static func processCommandHints(_ command: String?) -> Set<String> {
        guard let command, !command.isEmpty else { return [] }
        let normalized = normalize(command)
        var result: Set<String> = []
        if normalized.contains("claude") { result.insert("claude") }
        let first = normalized.split(separator: " ").first.map(String.init) ?? ""
        let executable = first.split(separator: "/").last.map(String.init) ?? ""
        if executable.contains(where: \Character.isLetter) {
            result.insert(executable)
        }
        return result
    }
}

/// Pure policy for the one verified sidebar refinement used by the generic AX
/// adapter. The refinement is admitted by its complete accessibility shape, not
/// by a terminal name: a stable row identifier, the observed sidebar/container
/// ancestry, and a contiguous `workspace N of M` list. This keeps app-private
/// names out of the public source while preventing an identifier prefix alone
/// from bypassing the generic control gates.
public enum WorkspaceSidebarRefinementPolicy {
    public struct Entry: Sendable, Equatable {
        public let identifier: String
        public let title: String
        public let position: Int
        public let total: Int

        public init(
            identifier: String,
            title: String,
            position: Int,
            total: Int
        ) {
            self.identifier = identifier
            self.title = title
            self.position = position
            self.total = total
        }
    }

    public static let identifierPrefix = "sidebarWorkspace."
    public static let expectedDepth = 5
    public static let parentRole = "AXOpaqueProviderGroup"
    public static let sidebarRole = "AXScrollArea"
    public static let sidebarIdentifier = "Sidebar"
    public static let activationHelp = "Activate to focus this workspace. Drag to reorder, or use Move Up and Move Down actions."

    public static func parse(
        identifier: String?,
        label: String?
    ) -> Entry? {
        guard let identifier,
              identifier.hasPrefix(identifierPrefix),
              let label else { return nil }
        let cleaned = label.trimmingCharacters(in: .whitespacesAndNewlines)
        let pattern = #",\s*workspace\s+(\d+)\s+of\s+(\d+)\s*$"#
        guard let expression = try? NSRegularExpression(
            pattern: pattern, options: [.caseInsensitive]) else { return nil }
        let fullRange = NSRange(cleaned.startIndex..., in: cleaned)
        guard let match = expression.firstMatch(
            in: cleaned, options: [], range: fullRange),
              match.numberOfRanges == 3,
              let positionRange = Range(match.range(at: 1), in: cleaned),
              let totalRange = Range(match.range(at: 2), in: cleaned),
              let position = Int(cleaned[positionRange]),
              let total = Int(cleaned[totalRange]),
              position > 0,
              total > 0,
              position <= total,
              let suffixRange = Range(match.range(at: 0), in: cleaned)
        else { return nil }

        let title = removingObservedStatusMarker(
            String(cleaned[..<suffixRange.lowerBound]))
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { return nil }
        return Entry(
            identifier: identifier,
            title: title,
            position: position,
            total: total)
    }

    public static func hasObservedAncestry(
        depth: Int,
        parentRole actualParentRole: String?,
        ancestorRoles: [String],
        ancestorIdentifiers: [String?]
    ) -> Bool {
        depth == expectedDepth
            && actualParentRole == parentRole
            && ancestorRoles.contains(sidebarRole)
            && ancestorIdentifiers.contains(sidebarIdentifier)
    }

    public static func hasObservedActivationHelp(_ help: String?) -> Bool {
        help?.trimmingCharacters(in: .whitespacesAndNewlines)
            == activationHelp
    }

    public static func removingObservedStatusMarker(_ raw: String) -> String {
        var title = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // The verified shape exposes exactly this one status marker. Do not
        // strip arbitrary symbols or emoji: those can be real workspace names.
        if title.hasPrefix("✳ ") {
            title.removeFirst(2)
        }
        return title.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The refined surface owns the full window title, so verification is exact
    /// after removing only its one observed status marker. Separator segments or
    /// path basenames are deliberately not accepted here.
    public static func focusedWindowTitleMatchesExactly(
        _ raw: String,
        expected: String
    ) -> Bool {
        normalizedTitle(removingObservedStatusMarker(raw))
            == normalizedTitle(expected)
    }

    private static func normalizedTitle(_ value: String) -> String {
        value.folding(
            options: [.caseInsensitive, .diacriticInsensitive], locale: .current)
            .lowercased()
            .split(whereSeparator: \Character.isWhitespace)
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public static func isCompleteSurface(
        _ entries: [Entry],
        directChildCount: Int,
        parentChildrenReadComplete: Bool
    ) -> Bool {
        guard parentChildrenReadComplete,
              let total = entries.first?.total,
              total > 0,
              directChildCount == total,
              entries.count == total,
              entries.allSatisfy({ $0.total == total }),
              Set(entries.map(\.identifier)).count == total,
              Set(entries.map(\.position)) == Set(1...total)
        else { return false }
        return true
    }
}

/// Pure parsing and identity policy for an optional, bundled local workspace
/// controller. The executable adapter discovers support by capability rather
/// than application name. It may act only when the controller maps Trifola's
/// already-resolved live session PID to exactly one workspace and that
/// workspace's title agrees with the independently matched AX title.
public struct WorkspaceBundledControlTarget: Sendable, Equatable {
    public let windowID: String
    public let windowRef: String
    public let workspaceID: String
    public let workspaceRef: String
    public let matchedTitle: String

    public init(
        windowID: String,
        windowRef: String,
        workspaceID: String,
        workspaceRef: String,
        matchedTitle: String
    ) {
        self.windowID = windowID
        self.windowRef = windowRef
        self.workspaceID = workspaceID
        self.workspaceRef = workspaceRef
        self.matchedTitle = matchedTitle
    }
}

public enum WorkspaceBundledControlPolicy {
    private struct Capabilities: Decodable {
        let methods: [String]
        let version: Int
    }

    private struct WindowList: Decodable {
        struct Window: Decodable {
            let id: String
            let workspaceCount: Int

            enum CodingKeys: String, CodingKey {
                case id
                case workspaceCount = "workspace_count"
            }
        }

        let windows: [Window]
    }

    private struct ResourceSnapshot: Decodable {
        struct Window: Decodable {
            struct Workspace: Decodable {
                struct Resources: Decodable {
                    let pids: [Int32]
                }

                let id: String
                let ref: String
                let title: String
                let resources: Resources
            }

            let id: String
            let ref: String
            let appProcessPIDs: [Int32]
            let workspaces: [Workspace]

            enum CodingKeys: String, CodingKey {
                case id
                case ref
                case appProcessPIDs = "app_process_pids"
                case workspaces
            }
        }

        let windows: [Window]
    }

    private static let requiredMethods: Set<String> = [
        "system.top",
        "window.current",
        "window.focus",
        "window.list",
        "workspace.current",
        "workspace.select",
    ]

    public static func supportsExpectedCapabilities(_ data: Data) -> Bool {
        guard let decoded = try? JSONDecoder().decode(
            Capabilities.self, from: data),
              decoded.version == 2 else { return false }
        return requiredMethods.isSubset(of: Set(decoded.methods))
    }

    /// Parses the stable window UUIDs used for subsequent structured resource
    /// queries. Count and identity validation keep a changing or malformed
    /// controller surface from being treated as complete.
    public static func windowIDs(from data: Data) -> [String]? {
        guard let decoded = try? JSONDecoder().decode(WindowList.self, from: data),
              !decoded.windows.isEmpty else { return nil }
        var seen: Set<String> = []
        var ids: [String] = []
        ids.reserveCapacity(decoded.windows.count)
        for window in decoded.windows {
            guard isUUID(window.id),
                  window.workspaceCount > 0,
                  seen.insert(window.id.lowercased()).inserted else {
                return nil
            }
            ids.append(window.id)
        }
        return ids
    }

    /// The PID join is authoritative. Title agreement is a separate
    /// cross-check with the AX candidate, not a fallback when the PID is absent.
    public static func target(
        from snapshotsByWindowID: [String: Data],
        ownerProcessID: Int32,
        sessionProcessID: Int32,
        matchedTitle: String
    ) -> WorkspaceBundledControlTarget? {
        let expectedTitle = matchedTitle.trimmingCharacters(
            in: .whitespacesAndNewlines)
        guard ownerProcessID > 0,
              sessionProcessID > 0,
              ownerProcessID != sessionProcessID,
              !expectedTitle.isEmpty,
              !snapshotsByWindowID.isEmpty else { return nil }

        var workspaceIDs: Set<String> = []
        var workspaceRefs: Set<String> = []
        var pidMatches: [WorkspaceBundledControlTarget] = []
        for (expectedWindowID, data) in snapshotsByWindowID {
            guard isUUID(expectedWindowID),
                  let decoded = try? JSONDecoder().decode(
                    ResourceSnapshot.self, from: data),
                  decoded.windows.count == 1,
                  let window = decoded.windows.first,
                  window.id.caseInsensitiveCompare(expectedWindowID) == .orderedSame,
                  validRef(window.ref, prefix: "window"),
                  window.appProcessPIDs.contains(ownerProcessID),
                  Set(window.appProcessPIDs).count == window.appProcessPIDs.count,
                  !window.workspaces.isEmpty else { return nil }

            for workspace in window.workspaces {
                guard isUUID(workspace.id),
                      validRef(workspace.ref, prefix: "workspace"),
                      workspaceIDs.insert(workspace.id.lowercased()).inserted,
                      workspaceRefs.insert(workspace.ref).inserted,
                      !workspace.title.trimmingCharacters(
                        in: .whitespacesAndNewlines).isEmpty,
                      workspace.resources.pids.allSatisfy({ $0 > 0 }),
                      Set(workspace.resources.pids).count
                        == workspace.resources.pids.count else { return nil }
                guard workspace.resources.pids.contains(sessionProcessID) else {
                    continue
                }
                pidMatches.append(WorkspaceBundledControlTarget(
                    windowID: window.id,
                    windowRef: window.ref,
                    workspaceID: workspace.id,
                    workspaceRef: workspace.ref,
                    matchedTitle: expectedTitle))
                guard WorkspaceSidebarRefinementPolicy
                    .focusedWindowTitleMatchesExactly(
                        workspace.title, expected: expectedTitle) else {
                    return nil
                }
            }
        }
        guard pidMatches.count == 1 else { return nil }
        return pidMatches[0]
    }

    public static func verifies(
        _ target: WorkspaceBundledControlTarget,
        currentWindowOutput: Data,
        currentWorkspaceOutput: Data,
        targetWindowSnapshot: Data,
        ownerProcessID: Int32,
        sessionProcessID: Int32
    ) -> Bool {
        guard singleUUID(from: currentWindowOutput)?
            .caseInsensitiveCompare(target.windowID) == .orderedSame,
              singleUUID(from: currentWorkspaceOutput)?
                .caseInsensitiveCompare(target.workspaceID) == .orderedSame,
              self.target(
                from: [target.windowID: targetWindowSnapshot],
                ownerProcessID: ownerProcessID,
                sessionProcessID: sessionProcessID,
                matchedTitle: target.matchedTitle) == target else {
            return false
        }
        return true
    }

    private static func singleUUID(from data: Data) -> String? {
        guard let raw = String(data: data, encoding: .utf8) else { return nil }
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        return isUUID(value) ? value : nil
    }

    private static func isUUID(_ value: String) -> Bool {
        guard value.count == 36,
              let parsed = UUID(uuidString: value) else { return false }
        return parsed.uuidString.caseInsensitiveCompare(value) == .orderedSame
    }

    private static func validRef(_ value: String, prefix: String) -> Bool {
        let pieces = value.split(
            separator: ":", omittingEmptySubsequences: false)
        guard pieces.count == 2,
              pieces[0] == Substring(prefix),
              let index = Int(pieces[1]),
              index > 0 else { return false }
        return String(index) == pieces[1]
    }
}

/// Pure eligibility/completeness rules shared by the executable AX adapter and
/// regression tests. String roles keep ApplicationServices out of TrifolaKit.
public enum WorkspaceAXSafetyPolicy {
    private static let navigationContainerRoles: Set<String> = [
        "AXTabGroup", "AXRadioGroup", "AXList", "AXTable", "AXOutline",
    ]
    private static let selectableControlRoles: Set<String> = [
        "AXButton", "AXRadioButton", "AXRow", "AXCell",
    ]
    private static let forbiddenAncestorRoles: Set<String> = [
        "AXMenuBar", "AXMenu", "AXMenuItem",
    ]

    public static func genericControlIsEligible(
        role: String,
        ancestorRoles: [String],
        supportsSelection: Bool
    ) -> Bool {
        supportsSelection
            && selectableControlRoles.contains(role)
            && ancestorRoles.contains(where: navigationContainerRoles.contains)
            && ancestorRoles.allSatisfy { !forbiddenAncestorRoles.contains($0) }
    }

    public static func genericTraversalIsComplete(
        hitNodeLimit: Bool,
        hitTimeLimit: Bool,
        hitDepthLimit: Bool,
        hitReadFailure: Bool
    ) -> Bool {
        !hitNodeLimit && !hitTimeLimit && !hitDepthLimit && !hitReadFailure
    }

    /// AX parents can return a child that is destroyed before its first required
    /// role read. That tombstone is no longer selectable and may be omitted.
    /// Mid-node invalidation, failed child enumeration, missing required data,
    /// and any other non-benign error continue to compromise completeness.
    public static func traversalReadCompromisesCompleteness(
        requiredAttribute: Bool,
        benignAbsence: Bool,
        invalidatedElement: Bool
    ) -> Bool {
        if requiredAttribute && invalidatedElement { return false }
        return requiredAttribute || !benignAbsence
    }

    /// A verified shallow surface remains complete when unrelated deeper app
    /// content is truncated. Every node at or above the surface depth must have
    /// been visited and read without a non-benign AX error.
    public static func scopedSurfaceTraversalIsComplete(
        surfaceDepth: Int,
        shallowestReadFailureDepth: Int?,
        minimumUnvisitedDepth: Int?
    ) -> Bool {
        if let shallowestReadFailureDepth,
           shallowestReadFailureDepth <= surfaceDepth {
            return false
        }
        if let minimumUnvisitedDepth,
           minimumUnvisitedDepth <= surfaceDepth {
            return false
        }
        return true
    }
}

public enum WorkspaceTargetPermission: Sendable, Equatable {
    case automation(TerminalAutomationError)
    case accessibility
}

public enum WorkspaceTargetFailure: Sendable, Equatable {
    case automation(TerminalAutomationError)
    case accessibility(String)
}

public enum WorkspaceTargetResult: Sendable, Equatable {
    case targeted(matchedTitle: String?)
    case notFound
    /// The at-value permission coordinator opened System Settings. Stop the
    /// ladder here so a terminal activation cannot hide that user-owned flow.
    case settingsOpened
    /// The user asked to open System Settings, but macOS rejected the request.
    /// Keep this distinct so the app never claims that Settings opened.
    case settingsOpenFailed
    case permissionDenied(WorkspaceTargetPermission)
    case noConfidentMatch
    case failed(WorkspaceTargetFailure)
}

public enum WorkspaceTargetVerification: Sendable, Equatable {
    case verified
    case unavailable
    case failed(String)
}

/// One strategy seam for both exact AppleScript targeting and generic AX
/// targeting. TerminalLaunchFlow owns their order; strategies never choose a
/// different application or guess among candidates.
@MainActor
public protocol WorkspaceTargeting: AnyObject {
    func target(_ request: WorkspaceTargetRequest) async -> WorkspaceTargetResult
    func verify(
        _ request: WorkspaceTargetRequest,
        matchedTitle: String
    ) async -> WorkspaceTargetVerification
}

public extension WorkspaceTargeting {
    func verify(
        _ request: WorkspaceTargetRequest,
        matchedTitle: String
    ) async -> WorkspaceTargetVerification {
        .unavailable
    }
}
