import Foundation

// MARK: - Skill hierarchy (VISION 3.3)
// The flat 110-skill list → real structure: SOURCE LANES (user / plugin-cache /
// project) → NAMESPACE groups (gstack family, plugin:skill ids, shared prefixes)
// → skill nodes. Plus a TRIGGER INDEX over declared `triggers:` phrases that
// surfaces COLLISIONS — two skills claiming the same phrase is a real routing
// failure. Pure value types over `[Skill]`, so grouping + collision detection are
// unit-tested and the whole tree rasterizes headlessly via `--render-skills`.
// Per-node usage stats (invocations / last-fired / dead-badge) are joined at the
// view layer from the AUDIT Skill Ledger — "hierarchy without the ledger is décor".

/// One skill's declared trigger phrase claimed by 2+ skills — a routing collision.
public struct TriggerCollision: Identifiable, Sendable, Hashable {
    public var id: String { phrase }
    public let phrase: String
    public let skillNames: [String]   // distinct skills claiming this phrase, sorted

    public init(phrase: String, skillNames: [String]) {
        self.phrase = phrase
        self.skillNames = skillNames
    }
}

/// A namespace group within a lane: gstack family, a plugin's skills, or a
/// shared-prefix family (datakit-*, plan-*, …). `key == ""` is the catch-all.
public struct SkillNamespace: Identifiable, Sendable, Hashable {
    public var id: String { "\(laneRaw)/\(key)" }
    public let laneRaw: Int
    public let key: String
    public let skills: [Skill]

    public init(laneRaw: Int, key: String, skills: [Skill]) {
        self.laneRaw = laneRaw; self.key = key; self.skills = skills
    }

    public var count: Int { skills.count }
    public var displayName: String {
        switch key {
        case "": return "Standalone"
        case "gstack": return "gstack"
        default: return key
        }
    }
}

/// A source lane with its namespace groups.
public struct SkillLaneGroup: Identifiable, Sendable, Hashable {
    public var id: Int { lane.rawValue }
    public let lane: SkillSource.Lane
    public let namespaces: [SkillNamespace]

    public init(lane: SkillSource.Lane, namespaces: [SkillNamespace]) {
        self.lane = lane; self.namespaces = namespaces
    }

    public var count: Int { namespaces.reduce(0) { $0 + $1.count } }
}

/// The whole hierarchy: lanes (user → plugin → project) + the collision index.
/// Equatable so the store can compare-before-assign (W6 wave 4).
public struct SkillHierarchy: Sendable, Equatable {
    public let lanes: [SkillLaneGroup]
    public let collisions: [TriggerCollision]
    public let totalSkills: Int
    public let distinctTriggers: Int   // distinct normalized declared trigger phrases

    public static let empty = SkillHierarchy(lanes: [], collisions: [], totalSkills: 0, distinctTriggers: 0)

    public init(lanes: [SkillLaneGroup], collisions: [TriggerCollision],
                totalSkills: Int, distinctTriggers: Int) {
        self.lanes = lanes; self.collisions = collisions
        self.totalSkills = totalSkills; self.distinctTriggers = distinctTriggers
    }

    public func laneCount(_ lane: SkillSource.Lane) -> Int {
        lanes.first { $0.lane == lane }?.count ?? 0
    }

    // MARK: Build

    /// Normalize a trigger phrase for the inverted index: lowercase, collapse
    /// internal whitespace, strip surrounding quotes/punctuation.
    public static func normalizeTrigger(_ s: String) -> String {
        let collapsed = s.lowercased()
            .components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return collapsed.trimmingCharacters(in: CharacterSet(charactersIn: "\"'.,;:!?“”‘’"))
    }

    /// A skill is in the gstack family when its description carries the "(gstack)"
    /// suffix tag — the marker the gstack toolchain stamps on its ~40 skills.
    static func isGstack(_ s: Skill) -> Bool {
        s.description.hasSuffix("(gstack)") || s.id.hasPrefix("_gstack")
    }

    /// The shared-prefix family key: the token before the first `-` (or `:`), used
    /// only when 2+ skills share it. Singletons fall into the "" catch-all.
    static func prefixFamily(_ id: String) -> String {
        if let dash = id.firstIndex(where: { $0 == "-" || $0 == ":" }) {
            return String(id[..<dash])
        }
        return id
    }

    /// Build the full hierarchy from a merged multi-lane skill list.
    public static func build(_ skills: [Skill]) -> SkillHierarchy {
        // Group by lane, then namespace within each lane.
        var byLane: [SkillSource.Lane: [Skill]] = [:]
        for s in skills { byLane[s.source.lane, default: []].append(s) }

        var laneGroups: [SkillLaneGroup] = []
        for lane in SkillSource.Lane.allCases {
            guard let laneSkills = byLane[lane], !laneSkills.isEmpty else { continue }
            let namespaces: [SkillNamespace]
            switch lane {
            case .user:    namespaces = userNamespaces(laneSkills, laneRaw: lane.rawValue)
            case .plugin:  namespaces = pluginNamespaces(laneSkills, laneRaw: lane.rawValue)
            case .project: namespaces = projectNamespaces(laneSkills, laneRaw: lane.rawValue)
            }
            laneGroups.append(SkillLaneGroup(lane: lane, namespaces: namespaces))
        }

        let (collisions, distinct) = triggerIndex(skills)
        return SkillHierarchy(lanes: laneGroups, collisions: collisions,
                              totalSkills: skills.count, distinctTriggers: distinct)
    }

    // User lane: gstack family first, then shared-prefix families (2+), then a
    // "Standalone" catch-all. All groups + members sorted for determinism.
    static func userNamespaces(_ skills: [Skill], laneRaw: Int) -> [SkillNamespace] {
        let gstack = skills.filter(isGstack).sorted { $0.id < $1.id }
        let rest = skills.filter { !isGstack($0) }

        var families: [String: [Skill]] = [:]
        for s in rest { families[prefixFamily(s.id), default: []].append(s) }

        var groups: [SkillNamespace] = []
        var standalone: [Skill] = []
        for (key, members) in families {
            if members.count >= 2 {
                groups.append(SkillNamespace(laneRaw: laneRaw, key: key,
                                             skills: members.sorted { $0.id < $1.id }))
            } else {
                standalone.append(contentsOf: members)
            }
        }
        groups.sort { $0.key < $1.key }

        var out: [SkillNamespace] = []
        if !gstack.isEmpty { out.append(SkillNamespace(laneRaw: laneRaw, key: "gstack", skills: gstack)) }
        out += groups
        if !standalone.isEmpty {
            out.append(SkillNamespace(laneRaw: laneRaw, key: "",
                                      skills: standalone.sorted { $0.id < $1.id }))
        }
        return out
    }

    // Plugin lane: one namespace per plugin (`codex`, `imessage`, …).
    static func pluginNamespaces(_ skills: [Skill], laneRaw: Int) -> [SkillNamespace] {
        var byPlugin: [String: [Skill]] = [:]
        for s in skills { byPlugin[s.source.pluginName ?? "plugin", default: []].append(s) }
        return byPlugin
            .map { SkillNamespace(laneRaw: laneRaw, key: $0.key, skills: $0.value.sorted { $0.id < $1.id }) }
            .sorted { $0.key < $1.key }
    }

    // Project lane: one namespace per project dir (basename).
    static func projectNamespaces(_ skills: [Skill], laneRaw: Int) -> [SkillNamespace] {
        var byDir: [String: [Skill]] = [:]
        for s in skills {
            let dir: String
            if case .project(let d) = s.source { dir = (d as NSString).lastPathComponent } else { dir = "project" }
            byDir[dir, default: []].append(s)
        }
        return byDir
            .map { SkillNamespace(laneRaw: laneRaw, key: $0.key, skills: $0.value.sorted { $0.id < $1.id }) }
            .sorted { $0.key < $1.key }
    }

    /// Inverted index of declared trigger phrases → the collisions (2+ skills) and
    /// the count of distinct phrases.
    static func triggerIndex(_ skills: [Skill]) -> (collisions: [TriggerCollision], distinct: Int) {
        var index: [String: Set<String>] = [:]
        for s in skills {
            for t in s.triggers {
                let phrase = normalizeTrigger(t)
                guard !phrase.isEmpty else { continue }
                index[phrase, default: []].insert(s.name)
            }
        }
        let collisions = index
            .filter { $0.value.count >= 2 }
            .map { TriggerCollision(phrase: $0.key, skillNames: $0.value.sorted()) }
            .sorted { $0.skillNames.count != $1.skillNames.count
                ? $0.skillNames.count > $1.skillNames.count : $0.phrase < $1.phrase }
        return (collisions, index.count)
    }
}
