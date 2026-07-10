import Foundation

// MARK: - Source lane

/// Where a skill was scanned from. The Stack hierarchy groups by this first —
/// the plugin-cache lane was INVISIBLE to the old flat scanner (an audit gap in
/// itself), so surfacing it is part of the point.
public enum SkillSource: Sendable, Hashable {
    case user                                                   // ~/.claude/skills
    case plugin(marketplace: String, plugin: String, version: String) // ~/.claude/plugins/cache/**
    case project(dir: String)                                   // <proj>/.claude/skills

    /// Coarse lane bucket, ordered user → plugin → project for stable display.
    public enum Lane: Int, Sendable, Hashable, CaseIterable {
        case user = 0, plugin = 1, project = 2
        public var title: String {
            switch self {
            case .user: return "User"
            case .plugin: return "Plugins"
            case .project: return "Project"
            }
        }
        public var subtitle: String {
            switch self {
            case .user: return "Claude user skills"
            case .plugin: return "Claude plugin cache"
            case .project: return ".claude/skills"
            }
        }
        public var icon: String {
            switch self {
            case .user: return "person.crop.circle"
            case .plugin: return "shippingbox"
            case .project: return "folder"
            }
        }
    }

    public var lane: Lane {
        switch self {
        case .user: return .user
        case .plugin: return .plugin
        case .project: return .project
        }
    }

    /// The owning plugin name (plugin lane only) — the `<plugin>` in
    /// cache/<marketplace>/<plugin>/<version>/skills/<name>. Used for `plugin:skill`
    /// namespacing and grouping.
    public var pluginName: String? {
        if case .plugin(_, let plugin, _) = self { return plugin }
        return nil
    }

    public var marketplace: String? {
        if case .plugin(let m, _, _) = self { return m }
        return nil
    }

    public var version: String? {
        if case .plugin(_, _, let v) = self { return v }
        return nil
    }
}

// MARK: - Model

/// One installed skill under `~/.claude/skills`, a plugin cache, or a project.
///
/// Either a directory containing `SKILL.md` (the normal shape) or a stray
/// top-level `*.md` file (a single-file skill, e.g. `delete-clerk-user.md`).
/// Skills with no YAML frontmatter at all still appear — `hasManifest` is
/// false and the name falls back to the folder name.
public struct Skill: Identifiable, Hashable, Sendable {
    public let id: String            // folder (or file stem) under skills/
    public let name: String          // frontmatter `name:` or folder fallback
    public let description: String   // folded/plain frontmatter description, or first prose
    public let version: String?      // frontmatter `version:`
    public let triggers: [String]    // frontmatter `triggers:` list
    public let allowedTools: [String]// frontmatter `allowed-tools:` list
    public let hasManifest: Bool     // true if frontmatter block was present
    public let wordCount: Int        // body words (rough prompt-size signal)
    public let fileCount: Int        // files in the skill folder (1 for single-file)
    public let modified: Date        // SKILL.md mtime
    public let path: String          // absolute path to SKILL.md / the .md file
    public let source: SkillSource   // which lane this came from

    public init(id: String, name: String, description: String, version: String?,
                triggers: [String], allowedTools: [String], hasManifest: Bool,
                wordCount: Int, fileCount: Int, modified: Date, path: String,
                source: SkillSource = .user) {
        self.id = id; self.name = name; self.description = description
        self.version = version; self.triggers = triggers; self.allowedTools = allowedTools
        self.hasManifest = hasManifest; self.wordCount = wordCount
        self.fileCount = fileCount; self.modified = modified; self.path = path
        self.source = source
    }

    /// The canonical ledger key: `plugin:skill` for a plugin skill (matches how
    /// Claude Code names namespaced skills), else the bare id. This is what the
    /// Skill Ledger's invocation counts are joined against.
    public var qualifiedID: String {
        if let plugin = source.pluginName { return "\(plugin):\(id)" }
        return id
    }
}

// MARK: - Frontmatter

/// The YAML subset that skill manifests actually use. Deliberately not a full
/// YAML parser: top-level `key: value` scalars, folded/literal blocks
/// (`>`, `>-`, `|`, `|-`), and block lists of `- item`. Anything fancier
/// degrades gracefully to "value missing", never to a crash.
public enum SkillFrontmatter {

    public struct Parsed: Sendable {
        public var scalars: [String: String] = [:]
        public var lists: [String: [String]] = [:]
    }

    /// Returns (frontmatter, body). Frontmatter is nil when the file does not
    /// open with a `---` fence.
    public static func split(_ text: String) -> (Parsed?, body: Substring) {
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)[...]
        guard lines.first.map({ $0.trimmingCharacters(in: .whitespaces) }) == "---" else {
            return (nil, text[...])
        }
        lines = lines.dropFirst()
        guard let end = lines.firstIndex(where: {
            $0.trimmingCharacters(in: .whitespaces) == "---"
        }) else { return (nil, text[...]) }  // unterminated fence → treat as body

        let block = lines[..<end]
        let bodyStart = lines.index(after: end)
        let bodyText = lines[bodyStart...].joined(separator: "\n")
        return (parse(block: Array(block)), Substring(bodyText))
    }

    static func parse(block: [Substring]) -> Parsed {
        var out = Parsed()
        var i = 0
        while i < block.count {
            let raw = block[i]
            let line = raw.trimmingCharacters(in: .whitespaces)
            i += 1
            guard !line.isEmpty, !raw.hasPrefix(" "), !raw.hasPrefix("\t"),
                  let colon = line.firstIndex(of: ":") else { continue }
            let key = String(line[..<colon]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: colon)...])
                .trimmingCharacters(in: .whitespaces)

            // Folded (`>`/`>-`) and literal (`|`/`|-`) blocks: consume all
            // following indented lines. Folded joins with spaces (blank line =
            // paragraph break); literal preserves newlines.
            if ["\u{3E}", ">-", ">+", "|", "|-", "|+"].contains(value) {
                let folded = value.hasPrefix(">")
                var parts: [String] = []
                while i < block.count {
                    let next = block[i]
                    let trimmed = next.trimmingCharacters(in: .whitespaces)
                    if trimmed.isEmpty { parts.append(""); i += 1; continue }
                    guard next.hasPrefix(" ") || next.hasPrefix("\t") else { break }
                    parts.append(trimmed)
                    i += 1
                }
                // Trim trailing blanks (the `-` chomp; harmless for `>` too).
                while parts.last == "" { parts.removeLast() }
                if folded {
                    value = parts.reduce(into: "") { acc, p in
                        if p.isEmpty { acc += "\n\n" }
                        else if acc.isEmpty || acc.hasSuffix("\n") { acc += p }
                        else { acc += " " + p }
                    }
                } else {
                    value = parts.joined(separator: "\n")
                }
                out.scalars[key] = value
                continue
            }

            // Block list: `key:` followed by `- item` lines.
            if value.isEmpty {
                var items: [String] = []
                while i < block.count {
                    let next = block[i].trimmingCharacters(in: .whitespaces)
                    guard next.hasPrefix("- "),
                          block[i].hasPrefix(" ") || block[i].hasPrefix("\t")
                    else { break }
                    items.append(String(next.dropFirst(2)).trimmingCharacters(in: .whitespaces))
                    i += 1
                }
                if !items.isEmpty { out.lists[key] = items } else { out.scalars[key] = "" }
                continue
            }

            // Inline list `[a, b]` — rare but cheap to support.
            if value.hasPrefix("["), value.hasSuffix("]") {
                out.lists[key] = value.dropFirst().dropLast()
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                continue
            }

            // Plain scalar; strip symmetric quotes.
            if value.count >= 2,
               (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
               (value.hasPrefix("'") && value.hasSuffix("'")) {
                value = String(value.dropFirst().dropLast())
            }
            out.scalars[key] = value
        }
        return out
    }
}

// MARK: - Catalog

public enum SkillCatalog {

    public static var defaultDirectory: String {
        ClaudePaths.process.skills.path
    }

    public static var pluginCacheDirectory: String {
        ClaudePaths.process.pluginCache.path
    }

    /// Scan the skills directory. Pure + synchronous; callers run it off the
    /// main actor (`SkillsStore` does). Never throws — an unreadable entry
    /// just doesn't appear.
    public static func scan(directory: String = defaultDirectory,
                            source: SkillSource = .user) -> [Skill] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(atPath: directory) else { return [] }

        var skills: [Skill] = []
        for entry in entries.sorted() where !entry.hasPrefix(".") {
            let entryPath = (directory as NSString).appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: entryPath, isDirectory: &isDir) else { continue }

            if isDir.boolValue {
                let manifest = (entryPath as NSString).appendingPathComponent("SKILL.md")
                let fileCount = (try? fm.contentsOfDirectory(atPath: entryPath))?
                    .filter { !$0.hasPrefix(".") }.count ?? 0
                if let skill = load(id: entry, manifestPath: manifest, fileCount: fileCount, source: source) {
                    skills.append(skill)
                } else {
                    // Folder with no SKILL.md at all — still worth surfacing.
                    skills.append(Skill(
                        id: entry, name: entry, description: "no SKILL.md in this folder",
                        version: nil, triggers: [], allowedTools: [], hasManifest: false,
                        wordCount: 0, fileCount: fileCount,
                        modified: mtime(entryPath), path: entryPath, source: source))
                }
            } else if entry.lowercased().hasSuffix(".md") {
                let id = String(entry.dropLast(3))
                if let skill = load(id: id, manifestPath: entryPath, fileCount: 1, source: source) {
                    skills.append(skill)
                }
            }
        }
        return skills
    }

    /// Scan plugin caches under `~/.claude/plugins/cache/<marketplace>/<plugin>/
    /// <version>/skills/<name>/SKILL.md` — the lane the flat scanner never saw.
    /// Each skill is tagged with its `.plugin(...)` source so it namespaces as
    /// `plugin:skill`.
    public static func scanPlugins(cacheDir: String = pluginCacheDirectory) -> [Skill] {
        let fm = FileManager.default
        guard let markets = try? fm.contentsOfDirectory(atPath: cacheDir) else { return [] }
        var out: [Skill] = []
        for market in markets.sorted() where !market.hasPrefix(".") {
            let marketPath = (cacheDir as NSString).appendingPathComponent(market)
            guard let plugins = try? fm.contentsOfDirectory(atPath: marketPath) else { continue }
            for plugin in plugins.sorted() where !plugin.hasPrefix(".") {
                let pluginPath = (marketPath as NSString).appendingPathComponent(plugin)
                guard let versions = try? fm.contentsOfDirectory(atPath: pluginPath) else { continue }
                for version in versions.sorted() where !version.hasPrefix(".") {
                    let skillsPath = (pluginPath as NSString)
                        .appendingPathComponent(version)
                        .appending("/skills")
                    var isDir: ObjCBool = false
                    guard fm.fileExists(atPath: skillsPath, isDirectory: &isDir), isDir.boolValue else { continue }
                    out += scan(directory: skillsPath,
                                source: .plugin(marketplace: market, plugin: plugin, version: version))
                }
            }
        }
        return out
    }

    /// Every lane, merged: user skills, plugin-cache skills, and any project
    /// `.claude/skills` dirs passed in. This is the hierarchy's data source.
    public static func scanAll(userDir: String = defaultDirectory,
                               cacheDir: String = pluginCacheDirectory,
                               projectDirs: [String] = []) -> [Skill] {
        var out = scan(directory: userDir, source: .user)
        out += scanPlugins(cacheDir: cacheDir)
        for dir in projectDirs {
            out += scan(directory: dir, source: .project(dir: dir))
        }
        return out
    }

    private static func load(id: String, manifestPath: String, fileCount: Int,
                             source: SkillSource) -> Skill? {
        guard let data = FileManager.default.contents(atPath: manifestPath),
              let text = String(data: data, encoding: .utf8) else { return nil }

        let (fm, body) = SkillFrontmatter.split(text)
        let bodyWords = body.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).count

        let description: String
        if let d = fm?.scalars["description"], !d.isEmpty {
            description = d
        } else {
            // No manifest description → first non-heading prose line of the body.
            description = body.split(separator: "\n")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .first { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("---") }
                ?? "no description"
        }

        return Skill(
            id: id,
            name: fm?.scalars["name"].flatMap { $0.isEmpty ? nil : $0 } ?? id,
            description: description,
            version: fm?.scalars["version"].flatMap { $0.isEmpty ? nil : $0 },
            triggers: fm?.lists["triggers"] ?? [],
            allowedTools: fm?.lists["allowed-tools"] ?? [],
            hasManifest: fm != nil,
            wordCount: bodyWords,
            fileCount: fileCount,
            modified: mtime(manifestPath),
            path: manifestPath,
            source: source)
    }

    private static func mtime(_ path: String) -> Date {
        (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate] as? Date)
            .flatMap { $0 } ?? .distantPast
    }
}

// MARK: - Store

/// Background-parsed skills catalog. `scanAll()` walks the user dir, every
/// plugin cache, and any project skill dirs, reading each SKILL.md — so it runs
/// detached; the UI only ever sees the published result on the main actor.
/// `skills` stays the USER lane (the AUDIT dead-skill ledger's honest 110-skill
/// denominator); `allSkills` + `hierarchy` carry every lane for the Stack tree.
@MainActor
public final class SkillsStore: ObservableObject {
    /// User-lane skills only — unchanged shape, feeds the audit ledger + filter.
    @Published public private(set) var skills: [Skill] = []
    /// Every lane (user + plugin caches + project) — feeds the hierarchy.
    @Published public private(set) var allSkills: [Skill] = []
    /// Grouped: lanes → namespaces → nodes, plus the trigger-collision index.
    @Published public private(set) var hierarchy: SkillHierarchy = .empty
    @Published public private(set) var loading = false
    @Published public private(set) var lastScan: Date? = nil

    private let directory: String
    private let pluginCacheDirectory: String
    /// Project `.claude/skills` dirs to fold into the project lane (set by the app
    /// from active session cwds).
    public var projectDirs: [String] = []

    public init(directory: String = SkillCatalog.defaultDirectory,
                pluginCacheDirectory: String = SkillCatalog.pluginCacheDirectory) {
        self.directory = directory
        self.pluginCacheDirectory = pluginCacheDirectory
    }

    public convenience init(paths: ClaudePaths) {
        self.init(directory: paths.skills.path,
                  pluginCacheDirectory: paths.pluginCache.path)
    }

    public func refreshNow() async {
        guard !loading else { return }
        loading = true
        let dir = directory
        let cache = pluginCacheDirectory
        let projects = projectDirs
        let all = await Task.detached(priority: .userInitiated) {
            SkillCatalog.scanAll(userDir: dir, cacheDir: cache,
                                 projectDirs: projects)
        }.value
        // Compare-before-assign (W6 wave 4): a rescan that found the same catalog
        // must not republish — it would drop tree selection hover + re-render the
        // Stack/Launch screens for nothing.
        if allSkills != all { allSkills = all }
        let user = all.filter { $0.source.lane == .user }
        if skills != user { skills = user }
        let built = SkillHierarchy.build(all)
        if hierarchy != built { hierarchy = built }
        lastScan = Date()
        loading = false
    }

    public func refreshIfStale(_ maxAge: TimeInterval = 300) async {
        if let lastScan, Date().timeIntervalSince(lastScan) < maxAge { return }
        await refreshNow()
    }

    /// Case-insensitive match over name, id, description and triggers.
    public nonisolated static func filter(_ skills: [Skill], query: String) -> [Skill] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return skills }
        return skills.filter { s in
            s.name.lowercased().contains(q) || s.id.lowercased().contains(q)
                || s.description.lowercased().contains(q)
                || s.triggers.contains { $0.lowercased().contains(q) }
        }
    }
}
