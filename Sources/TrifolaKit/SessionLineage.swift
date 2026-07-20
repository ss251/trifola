import Foundation

// MARK: - Lineage evidence readers

/// Codex-native parentage retained from the rollout's first `session_meta`
/// record. Every field is optional because rollout payloads are unversioned and
/// older clients did not persist the tree source.
public struct CodexThreadMetadata: Sendable, Hashable, Codable {
    public let threadID: String
    public let parentThreadID: String?
    public let forkedFromID: String?
    public let sourceDepth: Int?
    public let agentNickname: String?
    public let originator: String?
    public let entrypoint: String?
    public let startedAt: Date?

    public init(threadID: String, parentThreadID: String? = nil,
                forkedFromID: String? = nil, sourceDepth: Int? = nil,
                agentNickname: String? = nil, originator: String? = nil,
                entrypoint: String? = nil, startedAt: Date? = nil) {
        self.threadID = threadID
        self.parentThreadID = parentThreadID
        self.forkedFromID = forkedFromID
        self.sourceDepth = sourceDepth
        self.agentNickname = agentNickname
        self.originator = originator
        self.entrypoint = entrypoint
        self.startedAt = startedAt
    }

    public var isNonInteractive: Bool {
        let values = [originator, entrypoint]
            .compactMap { $0?.lowercased() }
        return values.contains { $0 == "codex_exec" || $0 == "sdk-cli" }
    }
}

/// One Claude remote-agent sidecar. `parentSessionID` comes only from the
/// `<parent-session-dir>/remote-agents/` directory convention.
public struct RemoteAgentSidecar: Sendable, Hashable, Codable {
    public let parentSessionID: String
    public let taskID: String
    public let remoteTaskType: String?
    public let sessionID: String?
    public let title: String?
    public let spawnedAt: Date?
    public let isUltraplan: Bool
    public let filePath: String

    public init(parentSessionID: String, taskID: String,
                remoteTaskType: String? = nil, sessionID: String? = nil,
                title: String? = nil, spawnedAt: Date? = nil,
                isUltraplan: Bool = false, filePath: String = "") {
        self.parentSessionID = parentSessionID
        self.taskID = taskID
        self.remoteTaskType = remoteTaskType
        self.sessionID = sessionID
        self.title = title
        self.spawnedAt = spawnedAt
        self.isUltraplan = isUltraplan
        self.filePath = filePath
    }
}

/// A source-to-imported-thread record from Codex's external-agent manifest.
public struct CodexImportRecord: Sendable, Hashable, Codable {
    public let sourcePath: String
    public let contentSHA256: String?
    public let importedThreadID: String

    public init(sourcePath: String, contentSHA256: String? = nil,
                importedThreadID: String) {
        self.sourcePath = sourcePath
        self.contentSHA256 = contentSHA256
        self.importedThreadID = importedThreadID
    }
}

/// Immutable evidence captured beside one session-index generation.
public struct SessionLineageEvidence: Sendable, Equatable {
    public var codexThreads: [CodexThreadMetadata]
    public var remoteTasks: [RemoteAgentSidecar]
    public var importRecords: [CodexImportRecord]
    public var sessionStartedAt: [String: Date]

    public init(codexThreads: [CodexThreadMetadata] = [],
                remoteTasks: [RemoteAgentSidecar] = [],
                importRecords: [CodexImportRecord] = [],
                sessionStartedAt: [String: Date] = [:]) {
        self.codexThreads = codexThreads
        self.remoteTasks = remoteTasks
        self.importRecords = importRecords
        self.sessionStartedAt = sessionStartedAt
    }

    public static let empty = SessionLineageEvidence()
}

/// Bounded, symlink-rejecting readers for the lineage-only sidecars. Transcript
/// enumeration remains owned by `SessionIndex`.
public enum SessionLineageEvidenceReader {
    public static func read(claudeProjectsRoot: URL,
                            codexImportManifestURL: URL?) -> SessionLineageEvidence {
        SessionLineageEvidence(
            remoteTasks: remoteAgentSidecars(beneath: claudeProjectsRoot),
            importRecords: CodexImportManifest.load(
                from: codexImportManifestURL).records)
    }

    public static func remoteAgentSidecars(beneath root: URL) -> [RemoteAgentSidecar] {
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isSymbolicLinkKey]
        guard let enumerator = fm.enumerator(
            at: root, includingPropertiesForKeys: Array(keys), options: [],
            errorHandler: { _, _ in true }) else { return [] }
        let resolvedRoot = root.resolvingSymlinksInPath().standardizedFileURL.path
        var result: [RemoteAgentSidecar] = []
        while let url = enumerator.nextObject() as? URL {
            guard url.lastPathComponent.hasPrefix("remote-agent-"),
                  url.lastPathComponent.hasSuffix(".meta.json"),
                  url.deletingLastPathComponent().lastPathComponent == "remote-agents",
                  let values = try? url.resourceValues(forKeys: keys),
                  values.isRegularFile == true, values.isSymbolicLink != true else {
                continue
            }
            let resolved = url.resolvingSymlinksInPath().standardizedFileURL.path
            guard resolved.hasPrefix(resolvedRoot + "/"),
                  let data = try? Data(contentsOf: url),
                  let object = (try? JSONSerialization.jsonObject(with: data))
                    as? [String: Any] else { continue }
            let parentID = url.deletingLastPathComponent()
                .deletingLastPathComponent().lastPathComponent
            guard let taskID = clean(object["taskId"] as? String),
                  !parentID.isEmpty else { continue }
            result.append(RemoteAgentSidecar(
                parentSessionID: parentID,
                taskID: taskID,
                remoteTaskType: clean(object["remoteTaskType"] as? String),
                sessionID: clean(object["sessionId"] as? String),
                title: clean(object["title"] as? String),
                spawnedAt: date(object["spawnedAt"]),
                isUltraplan: (object["isUltraplan"] as? NSNumber)?.boolValue
                    ?? (object["isUltraplan"] as? Bool) ?? false,
                filePath: url.path))
        }
        return result.sorted {
            ($0.spawnedAt ?? .distantPast, $0.taskID)
                < ($1.spawnedAt ?? .distantPast, $1.taskID)
        }
    }

    private static func clean(_ value: String?) -> String? {
        guard let value else { return nil }
        let cleaned = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? nil : cleaned
    }

    private static func date(_ value: Any?) -> Date? {
        if let value = value as? String { return parseDate(value) }
        if let number = value as? NSNumber {
            let raw = number.doubleValue
            return Date(timeIntervalSince1970: raw > 10_000_000_000 ? raw / 1_000 : raw)
        }
        return nil
    }
}

// MARK: - Pure lineage resolver

public enum LineageEdgeKind: Sendable, Hashable, Codable {
    case subagent
    case remoteTask
    case codexSpawn
    case codexFork
    case importBridge
    case orchestrated

    public var label: String {
        switch self {
        case .subagent: return "Claude subagent"
        case .remoteTask: return "Remote task"
        case .codexSpawn: return "Codex spawn"
        case .codexFork: return "Codex fork"
        case .importBridge: return "Imported into Codex"
        case .orchestrated: return "linked by workspace + timing"
        }
    }
}

public enum LineageConfidence: String, Sendable, Hashable, Codable {
    case deterministic
    case heuristic
}

/// Compact reference deliberately omitting transcript usage maps and other
/// corpus-heavy fields. It is safe to carry into navigation snapshots.
public struct LineageSessionReference: Identifiable, Sendable, Hashable {
    public let id: String
    public let stableKey: String
    public let provider: Provider
    public let project: String
    public let cwd: String
    public let title: String
    public let model: String?
    public let tier: ModelTier
    public let lastActivity: Date?
    public let startedAt: Date?
    public let cost: Double
    public let contextWeight: Int
    public let totalTokens: Int
    public let filePath: String
    public let machineID: String
    public let isMetadataOnly: Bool
    public let transcriptNote: String?

    public var duration: TimeInterval? {
        guard !isMetadataOnly, let startedAt, let lastActivity else { return nil }
        return max(0, lastActivity.timeIntervalSince(startedAt))
    }

    public init(summary: SessionSummary, startedAt: Date? = nil,
                stableKey: String? = nil) {
        id = summary.id
        self.stableKey = stableKey ?? SessionLineage.key(summary)
        provider = summary.provider
        project = summary.project
        cwd = summary.cwd
        title = summary.displayTitle
        model = summary.model
        tier = summary.tier
        lastActivity = summary.lastActivity
        self.startedAt = startedAt
        cost = summary.cost
        contextWeight = summary.contextWeight
        totalTokens = summary.usage.total
        filePath = summary.filePath
        machineID = summary.machineID
        isMetadataOnly = false
        transcriptNote = nil
    }

    init(id: String, stableKey: String, provider: Provider, project: String,
         cwd: String, title: String, startedAt: Date?, machineID: String,
         transcriptNote: String) {
        self.id = id
        self.stableKey = stableKey
        self.provider = provider
        self.project = project
        self.cwd = cwd
        self.title = title
        model = nil
        tier = provider == .codex ? .codex : .other
        lastActivity = startedAt
        self.startedAt = startedAt
        cost = 0
        contextWeight = 0
        totalTokens = 0
        filePath = ""
        self.machineID = machineID
        isMetadataOnly = true
        self.transcriptNote = transcriptNote
    }
}

public struct LineageNode: Identifiable, Sendable, Hashable {
    public let session: LineageSessionReference
    public let children: [LineageNode]
    public let edgeKind: LineageEdgeKind?
    public let confidence: LineageConfidence?
    public let spawnDepth: Int
    /// Visual indentation stops at two; deeper ancestry remains explicit here.
    public let displayDepth: Int
    public let parentMissingNote: String?
    public let edgeDetail: String?
    public var id: String { session.stableKey }

    public init(session: LineageSessionReference, children: [LineageNode],
                edgeKind: LineageEdgeKind?, confidence: LineageConfidence?,
                spawnDepth: Int, displayDepth: Int,
                parentMissingNote: String?, edgeDetail: String?) {
        self.session = session
        self.children = children
        self.edgeKind = edgeKind
        self.confidence = confidence
        self.spawnDepth = spawnDepth
        self.displayDepth = displayDepth
        self.parentMissingNote = parentMissingNote
        self.edgeDetail = edgeDetail
    }

    public var descendantCount: Int {
        children.reduce(children.count) { $0 + $1.descendantCount }
    }

    public var totalDescendantCost: Double {
        children.reduce(0) { $0 + $1.session.cost + $1.totalDescendantCost }
    }
}

public struct SessionLineageForest: Sendable, Equatable {
    public let roots: [LineageNode]
    public let transcriptSessionCount: Int
    public let metadataOnlyCount: Int

    public init(roots: [LineageNode], transcriptSessionCount: Int,
                metadataOnlyCount: Int) {
        self.roots = roots
        self.transcriptSessionCount = transcriptSessionCount
        self.metadataOnlyCount = metadataOnlyCount
    }

    public var allNodes: [LineageNode] {
        func flatten(_ nodes: [LineageNode]) -> [LineageNode] {
            nodes.flatMap { [$0] + flatten($0.children) }
        }
        return flatten(roots)
    }
}

public enum SessionLineage {
    private struct Candidate: Sendable {
        let parentKey: String?
        let missingParentID: String?
        let kind: LineageEdgeKind
        let confidence: LineageConfidence
        let detail: String?
        let priority: Int
    }

    private struct MutableNode {
        var session: LineageSessionReference
        var candidate: Candidate?
    }

    public static func resolve(
        sessions: [SessionSummary],
        evidence: SessionLineageEvidence = .empty,
        includeHeuristicLinks: Bool = true
    ) -> SessionLineageForest {
        let codexByID = Dictionary(
            evidence.codexThreads.map { ($0.threadID, $0) },
            uniquingKeysWith: { first, _ in first })
        var nodes: [String: MutableNode] = [:]
        var summaryByKey: [String: SessionSummary] = [:]
        // Path standardization dominates key(): compute every session's key
        // exactly once and thread the pair through every later join.
        let keyedSessions: [(summary: SessionSummary, key: String)] =
            sessions.map { ($0, key($0)) }
        for (summary, key) in keyedSessions {
            summaryByKey[key] = summary
            nodes[key] = MutableNode(
                session: LineageSessionReference(
                    summary: summary,
                    startedAt: evidence.sessionStartedAt[key]
                        ?? (summary.provider == .codex
                            ? codexByID[summary.id]?.startedAt : nil),
                    stableKey: key),
                candidate: nil)
        }

        let lookupByProviderMachineID = Dictionary(
            keyedSessions.map {
                (lookupKey($0.summary.provider, $0.summary.machineID,
                           $0.summary.id), $0.key)
            },
            uniquingKeysWith: { first, _ in first })
        let keyByProviderID = Dictionary(
            keyedSessions.map {
                ("\($0.summary.provider.rawValue):\($0.summary.id)", $0.key)
            },
            uniquingKeysWith: { existing, candidate in
                existing.contains(":\(Machine.localID):") ? existing : candidate
            })
        let keyByPath = Dictionary(
            keyedSessions.filter { !$0.summary.filePath.isEmpty }.map {
                (URL(fileURLWithPath: $0.summary.filePath).standardizedFileURL.path,
                 $0.key)
            }, uniquingKeysWith: { first, _ in first })
        func actualKey(provider: Provider, machine: String, id: String) -> String? {
            lookupByProviderMachineID[lookupKey(provider, machine, id)]
        }
        func anyKey(provider: Provider, id: String) -> String? {
            keyByProviderID["\(provider.rawValue):\(id)"]
        }
        func offer(_ candidate: Candidate, to childKey: String) {
            guard var node = nodes[childKey] else { return }
            if node.candidate == nil || candidate.priority < node.candidate!.priority {
                node.candidate = candidate
                nodes[childKey] = node
            }
        }

        // 1. Claude Agent/Task result joined to its directory child.
        for (child, childKey) in keyedSessions
        where child.provider == .claude && child.isSubagent {
            guard let parentID = child.parentSessionID else { continue }
            let parentDirectory = URL(fileURLWithPath: child.filePath)
                .deletingLastPathComponent().deletingLastPathComponent()
            let expectedParentPath = parentDirectory.appendingPathExtension("jsonl")
                .standardizedFileURL.path
            let parentKey = keyByPath[expectedParentPath]
                ?? actualKey(provider: .claude,
                             machine: child.machineID, id: parentID)
            let fileStem = URL(fileURLWithPath: child.filePath)
                .deletingPathExtension().lastPathComponent
            let agentStem = fileStem.hasPrefix("agent-")
                ? String(fileStem.dropFirst("agent-".count)) : fileStem
            let verified = parentKey.flatMap { summaryByKey[$0] }?
                .subagentInvocations.contains { $0.agentID == agentStem } == true
            if verified || parentKey == nil {
                offer(Candidate(
                    parentKey: verified ? parentKey : nil,
                    missingParentID: parentKey == nil ? parentID : nil,
                    kind: .subagent, confidence: .deterministic,
                    detail: nil, priority: 1), to: childKey)
            } else {
                // The parent transcript exists but records no matching spawn.
                // Never mis-attach — but never pretend this is an ordinary
                // top-level session either.
                offer(Candidate(
                    parentKey: nil, missingParentID: nil,
                    kind: .subagent, confidence: .deterministic,
                    detail: "subagent file — parent \(parentID) has no matching spawn record",
                    priority: 1), to: childKey)
            }
        }

        // 2. Remote/cloud task sidecars. A missing local transcript becomes a
        // metadata-only child; an exact task/session id reuses the real row.
        for remote in evidence.remoteTasks {
            let parentKey = anyKey(provider: .claude, id: remote.parentSessionID)
            let parent = parentKey.flatMap { summaryByKey[$0] }
            let actualKey = remote.sessionID.flatMap {
                anyKey(provider: .claude, id: $0)
                    ?? anyKey(provider: .codex, id: $0)
            } ?? anyKey(provider: .claude, id: remote.taskID)
                ?? anyKey(provider: .codex, id: remote.taskID)
            let childKey: String
            if let actualKey {
                childKey = actualKey
            } else {
                childKey = "remote:\(remote.parentSessionID):\(remote.taskID)"
                if nodes[childKey] == nil {
                    nodes[childKey] = MutableNode(
                        session: LineageSessionReference(
                            id: remote.sessionID ?? remote.taskID,
                            stableKey: childKey,
                            provider: .claude,
                            project: parent?.project ?? "Remote task",
                            cwd: parent?.cwd ?? "",
                            title: remote.title ?? remote.remoteTaskType
                                ?? "Remote agent task",
                            startedAt: remote.spawnedAt,
                            machineID: parent?.machineID ?? Machine.localID,
                            transcriptNote: "Remote task metadata is present, but its transcript is not stored locally."),
                        candidate: nil)
                }
            }
            offer(Candidate(
                parentKey: parentKey,
                missingParentID: parentKey == nil ? remote.parentSessionID : nil,
                kind: .remoteTask, confidence: .deterministic,
                detail: remote.isUltraplan ? "Ultraplan remote task" : remote.remoteTaskType,
                priority: 2), to: childKey)
        }

        // 3. Codex-native spawn/fork tree.
        for metadata in evidence.codexThreads {
            guard let childKey = anyKey(
                provider: .codex, id: metadata.threadID),
                  let child = summaryByKey[childKey] else { continue }
            let parentID: String?
            let kind: LineageEdgeKind
            if let forked = metadata.forkedFromID {
                parentID = forked
                kind = .codexFork
            } else if let parent = metadata.parentThreadID {
                parentID = parent
                kind = .codexSpawn
            } else {
                continue
            }
            let parentKey = parentID.flatMap {
                actualKey(provider: .codex, machine: child.machineID, id: $0)
            }
            offer(Candidate(
                parentKey: parentKey,
                missingParentID: parentKey == nil ? parentID : nil,
                kind: kind, confidence: .deterministic,
                detail: metadata.agentNickname,
                priority: 3), to: childKey)
        }

        // 4. Claude → Codex import manifest bridge. Imported rollouts remain
        // source-deduplicated, so most children are intentionally metadata-only.
        for record in evidence.importRecords {
            let parentKey = keyByPath[
                URL(fileURLWithPath: record.sourcePath).standardizedFileURL.path]
            let parent = parentKey.flatMap { summaryByKey[$0] }
            let importedKey = anyKey(
                provider: .codex, id: record.importedThreadID)
            let childKey: String
            if let importedKey {
                childKey = importedKey
            } else {
                childKey = "import:\(record.importedThreadID)"
                if nodes[childKey] == nil {
                    nodes[childKey] = MutableNode(
                        session: LineageSessionReference(
                            id: record.importedThreadID,
                            stableKey: childKey,
                            provider: .codex,
                            project: parent?.project ?? "Imported session",
                            cwd: parent?.cwd ?? "",
                            title: "Codex import \(String(record.importedThreadID.prefix(8)))",
                            startedAt: nil,
                            machineID: parent?.machineID ?? Machine.localID,
                            transcriptNote: "Codex imported this Claude session; the duplicate rollout is excluded from session totals."),
                        candidate: nil)
                }
            }
            offer(Candidate(
                parentKey: parentKey,
                missingParentID: parent == nil ? record.sourcePath : nil,
                kind: .importBridge, confidence: .deterministic,
                detail: parent == nil
                    ? "Imported from a Claude session that is no longer local"
                    : "Imported from Claude session \(parent!.shortID)",
                priority: 4), to: childKey)
        }

        // 5. The only heuristic: cross-provider, non-interactive Codex child,
        // workspace-compatible and temporally inside the parent's observed tail.
        if includeHeuristicLinks {
            struct HeuristicParent {
                let key: String
                let cwd: String
                let lastActivity: Date?
            }
            var claudeByExactWorkspace: [String: [HeuristicParent]] = [:]
            var claudeByWorkspaceName: [String: [HeuristicParent]] = [:]
            for (parent, parentKey) in keyedSessions
            where parent.provider == .claude && !parent.cwd.isEmpty {
                let path = URL(fileURLWithPath: parent.cwd).standardizedFileURL.path
                let entry = HeuristicParent(
                    key: parentKey, cwd: parent.cwd,
                    lastActivity: parent.lastActivity)
                claudeByExactWorkspace["\(parent.machineID):\(path)", default: []]
                    .append(entry)
                let name = URL(fileURLWithPath: path).lastPathComponent
                claudeByWorkspaceName["\(parent.machineID):\(name)", default: []]
                    .append(entry)
            }
            for metadata in evidence.codexThreads where metadata.isNonInteractive {
                guard let childKey = anyKey(
                    provider: .codex, id: metadata.threadID),
                      let child = summaryByKey[childKey],
                      let started = metadata.startedAt else { continue }
                guard nodes[childKey]?.candidate == nil else { continue }
                let childPath = URL(fileURLWithPath: child.cwd)
                    .standardizedFileURL.path
                let childName = URL(fileURLWithPath: childPath).lastPathComponent
                var pool = claudeByExactWorkspace[
                    "\(child.machineID):\(childPath)"] ?? []
                if childPath.contains("/worktrees/") {
                    pool.append(contentsOf: claudeByWorkspaceName[
                        "\(child.machineID):\(childName)"] ?? [])
                } else {
                    pool.append(contentsOf: (claudeByWorkspaceName[
                        "\(child.machineID):\(childName)"] ?? []).filter {
                            $0.cwd.contains("/worktrees/")
                        })
                }
                let candidates = Dictionary(
                    pool.map { ($0.key, $0) }, uniquingKeysWith: { first, _ in first })
                    .values.filter {
                        activeWindowContains(
                            started,
                            parentStart: evidence.sessionStartedAt[$0.key],
                            parentLastActivity: $0.lastActivity)
                    }.sorted {
                    abs(($0.lastActivity ?? .distantPast).timeIntervalSince(started))
                        < abs(($1.lastActivity ?? .distantPast).timeIntervalSince(started))
                }
                guard let parent = candidates.first else { continue }
                offer(Candidate(
                    parentKey: parent.key, missingParentID: nil,
                    kind: .orchestrated, confidence: .heuristic,
                    detail: "linked by workspace + timing", priority: 5),
                    to: childKey)
            }
        }

        // Adding candidates in priority order prevents lower-quality evidence
        // from replacing deterministic joins. Reject any edge that would close
        // a cycle; the child then remains a visible top-level orphan.
        var acceptedParents: [String: String] = [:]
        let candidateOrder = nodes.compactMap { key, value in
            value.candidate.map { (key, $0) }
        }.sorted {
            ($0.1.priority, $0.0) < ($1.1.priority, $1.0)
        }
        for (child, candidate) in candidateOrder {
            guard let parent = candidate.parentKey, nodes[parent] != nil,
                  parent != child else { continue }
            var cursor: String? = parent
            var closesCycle = false
            while let current = cursor {
                if current == child { closesCycle = true; break }
                cursor = acceptedParents[current]
            }
            if !closesCycle { acceptedParents[child] = parent }
        }

        var childrenByParent: [String: [String]] = [:]
        for (child, parent) in acceptedParents {
            childrenByParent[parent, default: []].append(child)
        }
        let roots = nodes.keys.filter { acceptedParents[$0] == nil }

        func materialize(_ nodeKey: String, depth: Int) -> LineageNode {
            let value = nodes[nodeKey]!
            let candidate = value.candidate
            let children = (childrenByParent[nodeKey] ?? []).sorted {
                let lhs = nodes[$0]!.session
                let rhs = nodes[$1]!.session
                let ld = lhs.startedAt ?? lhs.lastActivity ?? .distantPast
                let rd = rhs.startedAt ?? rhs.lastActivity ?? .distantPast
                return ld == rd ? lhs.stableKey < rhs.stableKey : ld < rd
            }.map { materialize($0, depth: depth + 1) }
            let missing: String? = {
                guard acceptedParents[nodeKey] == nil, let candidate else { return nil }
                if let id = candidate.missingParentID {
                    return "Parent missing: \(id)"
                }
                if candidate.parentKey != nil {
                    return "Parent link was ignored to prevent a lineage cycle."
                }
                return candidate.detail
            }()
            return LineageNode(
                session: value.session,
                children: children,
                edgeKind: acceptedParents[nodeKey] == nil ? nil : candidate?.kind,
                confidence: acceptedParents[nodeKey] == nil ? nil : candidate?.confidence,
                spawnDepth: depth,
                displayDepth: min(depth, 2),
                parentMissingNote: missing,
                edgeDetail: acceptedParents[nodeKey] == nil ? nil : candidate?.detail)
        }

        // Sort root KEYS before materializing (sorting materialized nodes
        // deep-copies whole subtrees), and look each root up exactly once —
        // dictionary probes inside the comparator hash long keys per compare.
        struct RootOrder {
            let key: String
            let last: Date
            let stable: String
        }
        var rootOrder: [RootOrder] = []
        rootOrder.reserveCapacity(roots.count)
        for rootKey in roots {
            let session = nodes[rootKey]!.session
            rootOrder.append(RootOrder(
                key: rootKey,
                last: session.lastActivity ?? .distantPast,
                stable: session.stableKey))
        }
        rootOrder.sort { lhs, rhs in
            lhs.last == rhs.last ? lhs.stable < rhs.stable : lhs.last > rhs.last
        }
        let materializedRoots = rootOrder.map { materialize($0.key, depth: 0) }
        return SessionLineageForest(
            roots: materializedRoots,
            transcriptSessionCount: sessions.count,
            metadataOnlyCount: nodes.values.filter(\.session.isMetadataOnly).count)
    }

    public static func key(_ summary: SessionSummary) -> String {
        let path = summary.filePath.isEmpty
            ? "<synthetic>"
            : URL(fileURLWithPath: summary.filePath).standardizedFileURL.path
        return "\(lookupKey(summary.provider, summary.machineID, summary.id)):\(path)"
    }

    private static func lookupKey(_ provider: Provider, _ machine: String,
                                  _ id: String) -> String {
        "\(provider.rawValue):\(machine):\(id)"
    }

    private static func activeWindowContains(
        _ childStart: Date, parentStart: Date?, parentLastActivity: Date?
    ) -> Bool {
        guard let parentLastActivity else { return false }
        // A parent cannot spawn work before it existed: when the parent's start
        // is known it must precede the child.
        if let parentStart, parentStart > childStart {
            return false
        }
        let delta = parentLastActivity.timeIntervalSince(childStart)
        return delta >= -15 * 60 && delta <= 4 * 60 * 60
    }

    private static func workspaceMatches(_ lhs: String, _ rhs: String) -> Bool {
        guard !lhs.isEmpty, !rhs.isEmpty else { return false }
        let left = URL(fileURLWithPath: lhs).standardizedFileURL.path
        let right = URL(fileURLWithPath: rhs).standardizedFileURL.path
        if left == right { return true }
        let l = URL(fileURLWithPath: left).lastPathComponent
        let r = URL(fileURLWithPath: right).lastPathComponent
        return l == r && (left.contains("/worktrees/") || right.contains("/worktrees/"))
    }
}
