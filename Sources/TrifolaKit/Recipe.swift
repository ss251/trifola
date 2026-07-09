import Foundation

// MARK: - LAUNCH pillar — the Session Builder
// A RECIPE composes a `claude` launch (cwd + agents-with-model-pins + effort +
// permission-mode + skill hints + mcp/settings) into an exact, copy-pasteable
// command — the moment Mission Control stops being a rear-view mirror. Every flag
// here is verified against `claude --help`. All value types, pure + Sendable, so
// composition is unit-tested (the exact `claude …` string is asserted) and
// reproduced in `--selfcheck`. Recipes persist as JSON in the app's OWN dir
// (~/Library/Application Support/Trifola/recipes) — NEVER ~/.claude.
//
// The honest nuance (from VISION 3.1): skills resolve at RUNTIME via /skill-name,
// not a launch flag. So the builder's skills section does NOT pretend to install
// them — it appends a system-prompt hint via `--append-system-prompt-file`. The
// command preview labels what's a real flag vs. a prompt hint.

// MARK: Effort

/// `--effort <level>` — verified choices (low, medium, high, xhigh, max).
public enum EffortLevel: String, CaseIterable, Codable, Sendable {
    case low, medium, high, xhigh, max

    /// Doctrine default: "effort High by default; XHigh only for the truly hard."
    public static let doctrineDefault: EffortLevel = .high

    public var label: String {
        switch self {
        case .low: return "Low"
        case .medium: return "Medium"
        case .high: return "High"
        case .xhigh: return "XHigh"
        case .max: return "Max"
        }
    }
    /// The furnace warning (RESEARCH pain-point #5: "xhigh is a furnace").
    public var isFurnace: Bool { self == .xhigh || self == .max }
}

// MARK: Permission mode

/// `--permission-mode <mode>` — verified choices. `.standard` means "don't pass
/// the flag" (let the session default rule), so the composer omits it.
public enum PermissionMode: String, CaseIterable, Codable, Sendable {
    case standard          // synthetic: omit the flag entirely
    case plan
    case acceptEdits
    case auto
    case dontAsk
    case bypassPermissions
    case manual

    public var flagValue: String? { self == .standard ? nil : rawValue }

    public var label: String {
        switch self {
        case .standard: return "Default (ask)"
        case .plan: return "Plan"
        case .acceptEdits: return "Accept edits"
        case .auto: return "Auto"
        case .dontAsk: return "Don't ask"
        case .bypassPermissions: return "Bypass permissions"
        case .manual: return "Manual"
        }
    }
    /// Loosest modes get a caution dot in the UI (they skip prompts).
    public var isLoose: Bool { self == .bypassPermissions || self == .auto || self == .dontAsk }
}

// MARK: Agent model pin (enforced at composition time)

/// A per-agent `model:` pin inside `--agents <json>`. The pin lever: a subagent
/// gets an explicit model rather than silently inheriting the main-loop model —
/// enforced when the recipe is COMPOSED, not hoped for at run time. Raw value is
/// the `claude` model alias (verified: 'opus'/'sonnet'/'haiku').
public enum AgentModel: String, CaseIterable, Codable, Sendable {
    case opus, sonnet, haiku

    /// The recommended default for any build/verify subagent.
    public static let recommendedDefault: AgentModel = .opus

    public var tier: ModelTier { ModelTier(raw: rawValue) }
    public var label: String { tier.label }
}

// MARK: Agent

/// One custom agent in the recipe's `--agents <json>`. `name` is the JSON object
/// key; `model` is always emitted (never omitted → never inherits silently).
public struct RecipeAgent: Identifiable, Codable, Sendable, Hashable {
    public var id: String { name }
    public var name: String
    public var description: String
    public var prompt: String
    public var model: AgentModel

    public init(name: String, description: String, prompt: String,
                model: AgentModel = .recommendedDefault) {
        self.name = name
        self.description = description
        self.prompt = prompt
        self.model = model
    }

    /// The shape `claude --agents` expects for this agent's VALUE object. Encoded
    /// with sorted keys so the composed command is byte-deterministic (testable).
    struct Payload: Codable { let description: String; let model: String; let prompt: String }
    var payload: Payload { Payload(description: description, model: model.rawValue, prompt: prompt) }
}

// MARK: Recipe

/// A named, saveable launch recipe. Minimal-but-real: exactly the fields that
/// change how the next session starts. This is the self-populating half the
/// Dreaming Ledger will later feed (mined recipes land here as JSON).
public struct Recipe: Identifiable, Codable, Sendable, Hashable {
    public var id: String
    public var name: String
    public var cwd: String
    public var addDirs: [String]
    public var agents: [RecipeAgent]
    public var effort: EffortLevel
    public var permissionMode: PermissionMode
    public var background: Bool
    /// MAIN-loop model pin (`--model <id>`), e.g. "claude-custom-5" for the
    /// explicitly-Custom tasks (W5). nil = don't pass the flag (session default
    /// rules) — every pre-W5 recipe decodes to nil and composes unchanged.
    public var model: String?
    /// The task prompt, passed as `claude`'s trailing positional argument —
    /// the session opens already working the brief. nil = interactive start.
    public var prompt: String?
    /// A caution chip shown on the card + preview (e.g. the field-reported
    /// quota burn of the train-the-replacement run). Display-only; never
    /// composed into the command.
    public var warning: String?
    /// Skill NAMES to hint (not install) — appended as a system-prompt block.
    public var skillRefs: [String]
    /// The skill to "lead with" — surfaces first in the hint. nil → first skillRef.
    public var leadSkill: String?
    public var mcpConfigPath: String?
    public var settingsPath: String?
    public var createdAt: Date
    public var updatedAt: Date

    public init(id: String = UUID().uuidString, name: String, cwd: String,
                addDirs: [String] = [], agents: [RecipeAgent] = [],
                effort: EffortLevel = .doctrineDefault,
                permissionMode: PermissionMode = .standard,
                background: Bool = false, model: String? = nil,
                prompt: String? = nil, warning: String? = nil,
                skillRefs: [String] = [],
                leadSkill: String? = nil, mcpConfigPath: String? = nil,
                settingsPath: String? = nil,
                createdAt: Date = Date(), updatedAt: Date = Date()) {
        self.id = id
        self.name = name
        self.cwd = cwd
        self.addDirs = addDirs
        self.agents = agents
        self.effort = effort
        self.permissionMode = permissionMode
        self.background = background
        self.model = model
        self.prompt = prompt
        self.warning = warning
        self.skillRefs = skillRefs
        self.leadSkill = leadSkill
        self.mcpConfigPath = mcpConfigPath
        self.settingsPath = settingsPath
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }

    /// The lead skill, resolved: explicit `leadSkill` if present in `skillRefs`,
    /// else the first ref.
    public var resolvedLeadSkill: String? {
        if let l = leadSkill, skillRefs.contains(l) { return l }
        return skillRefs.first
    }

    /// A blank starter rooted at a directory (used by "new recipe" + skill-seed).
    public static func blank(cwd: String = "") -> Recipe {
        Recipe(name: "New recipe", cwd: cwd)
    }
}

// MARK: - Composition (the testable core)

/// The composed launch: the exact strings the UI shows (no black box) and copies.
public struct RecipeCommand: Sendable, Equatable {
    /// `claude` argv (flag + value tokens), without the leading `claude`.
    public let claudeArgs: [String]
    /// The full shell one-liner: `cd '<cwd>' && claude …` (single-quote-escaped).
    public let shellCommand: String
    /// The `--agents` JSON (empty when no agents). Deterministic, sorted keys.
    public let agentsJSON: String
    /// The system-prompt hint text (empty when no skill refs). Written to the file
    /// `--append-system-prompt-file` points at.
    public let systemPromptText: String

    public init(claudeArgs: [String], shellCommand: String,
                agentsJSON: String, systemPromptText: String) {
        self.claudeArgs = claudeArgs
        self.shellCommand = shellCommand
        self.agentsJSON = agentsJSON
        self.systemPromptText = systemPromptText
    }
}

public enum RecipeComposer {

    /// POSIX single-quote escaping (matches `SessionResume.command`): wrap in
    /// single quotes, and escape any embedded single quote as `'\''`.
    public static func shellQuote(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// The `--agents` JSON object. Keys sorted (agent names + inner keys) so the
    /// composed command is byte-deterministic — the exact string is asserted in
    /// tests. Empty string when there are no agents.
    public static func agentsJSON(_ agents: [RecipeAgent]) -> String {
        guard !agents.isEmpty else { return "" }
        var map: [String: RecipeAgent.Payload] = [:]
        for a in agents { map[a.name] = a.payload }
        let enc = JSONEncoder()
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? enc.encode(map), let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    /// The skills system-prompt hint. Lead skill first; honest that skills resolve
    /// at runtime via /skill-name. Empty when there are no skill refs.
    public static func systemPromptText(_ recipe: Recipe) -> String {
        let refs = orderedSkillRefs(recipe)
        guard !refs.isEmpty else { return "" }
        let list = refs.joined(separator: ", ")
        var out = "You have these Claude Code skills available: \(list)."
        if let lead = recipe.resolvedLeadSkill {
            out += " Lead with /\(lead) for this task."
        }
        out += " Skills resolve at runtime via /skill-name — invoke one when its trigger applies."
        return out
    }

    /// Skill refs with the lead skill hoisted to the front, de-duplicated,
    /// insertion order otherwise preserved.
    public static func orderedSkillRefs(_ recipe: Recipe) -> [String] {
        var seen = Set<String>()
        var out: [String] = []
        if let lead = recipe.resolvedLeadSkill, !lead.isEmpty {
            out.append(lead); seen.insert(lead)
        }
        for r in recipe.skillRefs where !r.isEmpty && !seen.contains(r) {
            out.append(r); seen.insert(r)
        }
        return out
    }

    /// Compose the full launch. `promptFilePath` is where the system-prompt hint
    /// will be written — passed only when the recipe has skill refs (the caller
    /// materializes the file before launch/copy). Pass nil to omit the append flag.
    public static func compose(_ recipe: Recipe, promptFilePath: String? = nil) -> RecipeCommand {
        var args: [String] = []

        // 1. Extra CLAUDE.md dirs (variadic --add-dir).
        let dirs = recipe.addDirs.filter { !$0.isEmpty }
        if !dirs.isEmpty { args.append("--add-dir"); args.append(contentsOf: dirs) }

        // 2. Agents with model pins — doctrine enforced at composition time.
        let json = agentsJSON(recipe.agents)
        if !json.isEmpty { args.append("--agents"); args.append(json) }

        // 3. Skills → a system-prompt HINT (not an install). Only when both the
        //    refs and a materialized file path exist.
        let promptText = systemPromptText(recipe)
        if !promptText.isEmpty, let path = promptFilePath, !path.isEmpty {
            args.append("--append-system-prompt-file"); args.append(path)
        }

        // 4. MCP + settings files.
        if let mcp = recipe.mcpConfigPath, !mcp.isEmpty { args.append("--mcp-config"); args.append(mcp) }
        if let set = recipe.settingsPath, !set.isEmpty { args.append("--settings"); args.append(set) }

        // 5. MAIN-loop model pin (W5) — omitted when unset (session default rules).
        if let model = recipe.model, !model.isEmpty { args.append("--model"); args.append(model) }

        // 6. Effort — always pinned by the recipe (honest: the recipe sets it).
        args.append("--effort"); args.append(recipe.effort.rawValue)

        // 7. Permission mode — omitted when standard.
        if let pm = recipe.permissionMode.flagValue { args.append("--permission-mode"); args.append(pm) }

        // 8. Background.
        if recipe.background { args.append("--bg") }

        // 9. The task prompt — `claude`'s trailing positional argument, so the
        //    session opens already working the brief. Always LAST.
        if let prompt = recipe.prompt, !prompt.isEmpty { args.append(prompt) }

        // Shell one-liner: quote the JSON arg and any token with shell-significant
        // characters; bare flags/values stay unquoted for readability.
        let claudePart = "claude " + args.map(quoteIfNeeded).joined(separator: " ")
        let shell: String
        if recipe.cwd.isEmpty {
            shell = claudePart
        } else {
            shell = "cd \(shellQuote(recipe.cwd)) && \(claudePart)"
        }
        return RecipeCommand(claudeArgs: args, shellCommand: shell,
                             agentsJSON: json, systemPromptText: promptText)
    }

    /// Quote a token only if it contains shell-significant characters — keeps
    /// `--effort high` readable while safely wrapping the `--agents` JSON and paths.
    static func quoteIfNeeded(_ token: String) -> String {
        if token.isEmpty { return "''" }
        let safe = CharacterSet(charactersIn:
            "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789._-/=:,")
        if token.unicodeScalars.allSatisfy({ safe.contains($0) }) { return token }
        return shellQuote(token)
    }
}

// MARK: - Persistence (the app's OWN dir — never ~/.claude)

public enum RecipeStoreError: Error, LocalizedError, Equatable {
    case notWritable(String)
    public var errorDescription: String? {
        switch self { case .notWritable(let p): return "Can't write recipes to \(p)" }
    }
}

/// Reads/writes recipe JSON in ~/Library/Application Support/Trifola/
/// recipes (overridable for tests). Pure file I/O over `Codable` — no UI, no state.
public struct RecipeRepository: Sendable {
    public let directory: URL

    /// The default app-support recipes directory. Explicitly NOT ~/.claude — the
    /// app never writes there (the user's own rule).
    public static var defaultDirectory: URL {
        let base = (try? FileManager.default.url(for: .applicationSupportDirectory,
                                                 in: .userDomainMask, appropriateFor: nil, create: false))
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Trifola/recipes", isDirectory: true)
    }

    public init(directory: URL = RecipeRepository.defaultDirectory) {
        self.directory = directory
    }

    private var promptsDir: URL { directory.appendingPathComponent("prompts", isDirectory: true) }

    private func ensureDir(_ url: URL) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    public func recipeURL(_ id: String) -> URL {
        directory.appendingPathComponent("\(id).json")
    }

    /// Stable on-disk path for a recipe's system-prompt hint file (the target of
    /// `--append-system-prompt-file`). Lives beside the recipes, in the app dir.
    public func promptURL(_ id: String) -> URL {
        promptsDir.appendingPathComponent("\(id).txt")
    }

    /// Write (or overwrite) the system-prompt hint file and return its path, or nil
    /// if the recipe has no skill refs. Idempotent — safe to call before each launch.
    @discardableResult
    public func materializePrompt(_ recipe: Recipe) throws -> String? {
        let text = RecipeComposer.systemPromptText(recipe)
        guard !text.isEmpty else { return nil }
        try ensureDir(promptsDir)
        let url = promptURL(recipe.id)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url.path
    }

    public func save(_ recipe: Recipe) throws {
        try ensureDir(directory)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        let data = try enc.encode(recipe)
        try data.write(to: recipeURL(recipe.id), options: .atomic)
    }

    public func delete(_ id: String) {
        try? FileManager.default.removeItem(at: recipeURL(id))
        try? FileManager.default.removeItem(at: promptURL(id))
    }

    public func load(_ id: String) -> Recipe? {
        decode(recipeURL(id))
    }

    /// All saved recipes, newest-updated first. Unreadable files are skipped.
    public func list() -> [Recipe] {
        let fm = FileManager.default
        guard let entries = try? fm.contentsOfDirectory(at: directory,
                                                        includingPropertiesForKeys: nil) else { return [] }
        return entries
            .filter { $0.pathExtension == "json" }
            .compactMap(decode)
            .sorted { $0.updatedAt > $1.updatedAt }
    }

    private func decode(_ url: URL) -> Recipe? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try? dec.decode(Recipe.self, from: data)
    }
}
