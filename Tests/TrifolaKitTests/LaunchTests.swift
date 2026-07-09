import Foundation
import Testing
@testable import TrifolaKit

// MARK: - Recipe → command composition (the LAUNCH pillar's testable core)

@Suite struct RecipeComposeTests {

    private func sampleRecipe() -> Recipe {
        Recipe(
            id: "fixed-id",
            name: "crypto sweep",
            cwd: "/Users/dev/crypto",
            agents: [RecipeAgent(name: "researcher",
                                 description: "Deep researcher",
                                 prompt: "You research crypto.",
                                 model: .opus)],
            effort: .high,
            permissionMode: .standard,
            background: false,
            skillRefs: ["release-notes", "api-client"],
            leadSkill: "release-notes")
    }

    @Test func exactComposedCommandIncludesOpusPin() {
        let cmd = RecipeComposer.compose(sampleRecipe(), promptFilePath: "/tmp/p.txt")

        let expectedAgents =
            #"{"researcher":{"description":"Deep researcher","model":"opus","prompt":"You research crypto."}}"#
        #expect(cmd.agentsJSON == expectedAgents)

        // The exact `claude …` one-liner, incl. the opus model pin. If this string
        // drifts, the launch is no longer what the preview shows.
        let expectedShell =
            "cd '/Users/dev/crypto' && claude "
            + "--agents '\(expectedAgents)' "
            + "--append-system-prompt-file /tmp/p.txt "
            + "--effort high"
        #expect(cmd.shellCommand == expectedShell)
        #expect(cmd.shellCommand.contains(#""model":"opus""#))
    }

    @Test func argvTokensAreExact() {
        let cmd = RecipeComposer.compose(sampleRecipe(), promptFilePath: "/tmp/p.txt")
        #expect(cmd.claudeArgs == [
            "--agents",
            #"{"researcher":{"description":"Deep researcher","model":"opus","prompt":"You research crypto."}}"#,
            "--append-system-prompt-file", "/tmp/p.txt",
            "--effort", "high",
        ])
    }

    @Test func doctrineDefaultIsOpus() {
        // A subagent added without an explicit model pins Opus at composition time
        // — killing the silent-inheritance bug at its source.
        let agent = RecipeAgent(name: "builder", description: "d", prompt: "p")
        #expect(agent.model == .opus)
        let json = RecipeComposer.agentsJSON([agent])
        #expect(json.contains(#""model":"opus""#))
    }

    @Test func explicitSonnetPinIsHonored() {
        let recipe = Recipe(name: "r", cwd: "/x",
                            agents: [RecipeAgent(name: "vision", description: "d", prompt: "p", model: .sonnet)])
        let cmd = RecipeComposer.compose(recipe)
        #expect(cmd.agentsJSON.contains(#""model":"sonnet""#))
    }

    @Test func allFlagsCompose() {
        let recipe = Recipe(
            name: "full", cwd: "/proj",
            addDirs: ["/proj/docs", "/proj/lib"],
            agents: [RecipeAgent(name: "a", description: "d", prompt: "p", model: .sonnet)],
            effort: .xhigh,
            permissionMode: .acceptEdits,
            background: true,
            skillRefs: ["x-ray"],
            mcpConfigPath: "/proj/.mcp.json",
            settingsPath: "/proj/settings.json")
        let cmd = RecipeComposer.compose(recipe, promptFilePath: "/tmp/full.txt")
        let a = cmd.claudeArgs
        #expect(a.first == "--add-dir")
        #expect(a.contains("/proj/docs") && a.contains("/proj/lib"))
        #expect(a.contains("--agents"))
        #expect(a.contains("--append-system-prompt-file") && a.contains("/tmp/full.txt"))
        #expect(a.contains("--mcp-config") && a.contains("/proj/.mcp.json"))
        #expect(a.contains("--settings") && a.contains("/proj/settings.json"))
        #expect(a.contains("--effort") && a.contains("xhigh"))
        #expect(a.contains("--permission-mode") && a.contains("acceptEdits"))
        #expect(a.contains("--bg"))
    }

    @Test func standardPermissionModeOmitsFlag() {
        let cmd = RecipeComposer.compose(Recipe(name: "r", cwd: "/x", permissionMode: .standard))
        #expect(!cmd.claudeArgs.contains("--permission-mode"))
    }

    @Test func noSkillRefsMeansNoAppendFlag() {
        // Skills resolve at runtime — no refs, no append-system-prompt-file (and
        // the composer never pretends to install a skill).
        let cmd = RecipeComposer.compose(Recipe(name: "r", cwd: "/x"), promptFilePath: "/tmp/p.txt")
        #expect(!cmd.claudeArgs.contains("--append-system-prompt-file"))
        #expect(cmd.systemPromptText.isEmpty)
    }

    @Test func systemPromptLeadsWithLeadSkill() {
        let text = RecipeComposer.systemPromptText(sampleRecipe())
        #expect(text.contains("release-notes, api-client"))
        #expect(text.contains("Lead with /release-notes"))
        #expect(text.contains("resolve at runtime via /skill-name"))
    }

    @Test func orderedSkillRefsHoistsLeadAndDedupes() {
        let recipe = Recipe(name: "r", cwd: "/x",
                            skillRefs: ["api-client", "x-ray", "api-client"],
                            leadSkill: "x-ray")
        #expect(RecipeComposer.orderedSkillRefs(recipe) == ["x-ray", "api-client"])
    }

    @Test func shellQuoteEscapesSingleQuotes() {
        #expect(RecipeComposer.shellQuote("a'b") == #"'a'\''b'"#)
    }

    @Test func emptyCwdOmitsCd() {
        let cmd = RecipeComposer.compose(Recipe(name: "r", cwd: ""))
        #expect(cmd.shellCommand.hasPrefix("claude "))
    }
}

// MARK: - Recipe persistence (JSON round-trip in the app's OWN dir)

@Suite struct RecipeRepositoryTests {

    private func tempRepo() throws -> RecipeRepository {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mck-recipes-\(UUID().uuidString)", isDirectory: true)
        return RecipeRepository(directory: url)
    }

    @Test func saveListLoadRoundTrip() throws {
        let repo = try tempRepo()
        defer { try? FileManager.default.removeItem(at: repo.directory) }

        let recipe = Recipe(
            id: "r1", name: "audit run", cwd: "/proj",
            addDirs: ["/proj/docs"],
            agents: [RecipeAgent(name: "auditor", description: "Security auditor",
                                 prompt: "Audit contracts.", model: .opus)],
            effort: .high, permissionMode: .plan, background: false,
            skillRefs: ["x-ray", "sql-tuner"], leadSkill: "x-ray",
            mcpConfigPath: "/proj/.mcp.json", settingsPath: nil)
        try repo.save(recipe)

        let listed = repo.list()
        #expect(listed.count == 1)
        let loaded = try #require(repo.load("r1"))
        // Field-by-field equality survives the JSON round-trip.
        #expect(loaded.name == recipe.name)
        #expect(loaded.cwd == recipe.cwd)
        #expect(loaded.addDirs == recipe.addDirs)
        #expect(loaded.agents == recipe.agents)
        #expect(loaded.effort == .high)
        #expect(loaded.permissionMode == .plan)
        #expect(loaded.skillRefs == ["x-ray", "sql-tuner"])
        #expect(loaded.leadSkill == "x-ray")
        #expect(loaded.mcpConfigPath == "/proj/.mcp.json")
        #expect(loaded.settingsPath == nil)
        // The composed command from the reloaded recipe is byte-identical.
        #expect(RecipeComposer.compose(loaded).agentsJSON == RecipeComposer.compose(recipe).agentsJSON)
    }

    @Test func materializePromptWritesFileAndPathIsUsed() throws {
        let repo = try tempRepo()
        defer { try? FileManager.default.removeItem(at: repo.directory) }
        let recipe = Recipe(id: "r2", name: "n", cwd: "/x", skillRefs: ["api-client"])
        let path = try #require(try repo.materializePrompt(recipe))
        #expect(FileManager.default.fileExists(atPath: path))
        let contents = try String(contentsOfFile: path, encoding: .utf8)
        #expect(contents.contains("api-client"))
        // A recipe with no skill refs materializes nothing.
        #expect(try repo.materializePrompt(Recipe(id: "r3", name: "n", cwd: "/x")) == nil)
    }

    @Test func deleteRemovesRecipeAndPrompt() throws {
        let repo = try tempRepo()
        defer { try? FileManager.default.removeItem(at: repo.directory) }
        let recipe = Recipe(id: "r4", name: "n", cwd: "/x", skillRefs: ["api-client"])
        try repo.save(recipe)
        _ = try repo.materializePrompt(recipe)
        repo.delete("r4")
        #expect(repo.load("r4") == nil)
        #expect(!FileManager.default.fileExists(atPath: repo.promptURL("r4").path))
    }

    @Test func defaultDirectoryIsAppSupportNeverDotClaude() {
        // The app's own rule: never write to ~/.claude.
        let path = RecipeRepository.defaultDirectory.path
        #expect(path.contains("Trifola/recipes"))
        #expect(!path.contains("/.claude/"))
    }
}
