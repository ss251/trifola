import Foundation
import Testing
@testable import TrifolaKit

// MARK: - Fixtures

private func mkSkill(_ id: String, desc: String = "", triggers: [String] = [],
                     source: SkillSource = .user, name: String? = nil) -> Skill {
    Skill(id: id, name: name ?? id, description: desc, version: nil, triggers: triggers,
          allowedTools: [], hasManifest: true, wordCount: 0, fileCount: 1,
          modified: .distantPast, path: "/tmp/\(id)", source: source)
}

// MARK: - Grouping

@Suite struct SkillHierarchyGroupingTests {

    @Test func lanesSplitBySource() {
        let skills = [
            mkSkill("agent-reach", source: .user),
            mkSkill("access", source: .plugin(marketplace: "official", plugin: "imessage", version: "0.1.0")),
            mkSkill("deploy", source: .project(dir: "/proj/.claude/skills")),
        ]
        let h = SkillHierarchy.build(skills)
        #expect(h.totalSkills == 3)
        #expect(h.laneCount(.user) == 1)
        #expect(h.laneCount(.plugin) == 1)
        #expect(h.laneCount(.project) == 1)
        // Lanes present in user → plugin → project order.
        #expect(h.lanes.map { $0.lane } == [.user, .plugin, .project])
    }

    @Test func gstackFamilyGroups() {
        let skills = [
            mkSkill("browse", desc: "Fast headless browser for QA. (gstack)"),
            mkSkill("codex", desc: "OpenAI Codex CLI wrapper. (gstack)"),
            mkSkill("graphify", desc: "any input to knowledge graph"),
        ]
        let h = SkillHierarchy.build(skills)
        let user = try! #require(h.lanes.first { $0.lane == .user })
        let gstack = try! #require(user.namespaces.first { $0.key == "gstack" })
        #expect(gstack.count == 2)
        #expect(gstack.skills.map(\.id) == ["browse", "codex"])
    }

    @Test func sharedPrefixFamiliesGroupWhenTwoOrMore() {
        let skills = [
            mkSkill("hyperframes-animation"),
            mkSkill("hyperframes-core"),
            mkSkill("hyperframes-media"),
            mkSkill("graphify"),          // singleton → Standalone
        ]
        let h = SkillHierarchy.build(skills)
        let user = try! #require(h.lanes.first { $0.lane == .user })
        let hf = try! #require(user.namespaces.first { $0.key == "hyperframes" })
        #expect(hf.count == 3)
        let standalone = try! #require(user.namespaces.first { $0.key == "" })
        #expect(standalone.skills.map(\.id) == ["graphify"])
        #expect(standalone.displayName == "Standalone")
    }

    @Test func pluginLaneGroupsByPluginName() {
        let skills = [
            mkSkill("access", source: .plugin(marketplace: "official", plugin: "imessage", version: "0.1.0")),
            mkSkill("configure", source: .plugin(marketplace: "official", plugin: "imessage", version: "0.1.0")),
            mkSkill("setup", source: .plugin(marketplace: "openai-codex", plugin: "codex", version: "1.0.4")),
        ]
        let h = SkillHierarchy.build(skills)
        let plugin = try! #require(h.lanes.first { $0.lane == .plugin })
        #expect(plugin.namespaces.map(\.key) == ["codex", "imessage"])  // sorted
        let imsg = try! #require(plugin.namespaces.first { $0.key == "imessage" })
        #expect(imsg.count == 2)
    }

    @Test func pluginSkillQualifiedID() {
        let s = mkSkill("setup", source: .plugin(marketplace: "openai-codex", plugin: "codex", version: "1.0.4"))
        #expect(s.qualifiedID == "codex:setup")
        #expect(mkSkill("agent-reach").qualifiedID == "agent-reach")
    }
}

// MARK: - Trigger index / collisions

@Suite struct TriggerCollisionTests {

    @Test func detectsPhraseClaimedByTwoSkills() {
        let skills = [
            mkSkill("browse", triggers: ["take a screenshot", "navigate to url"], name: "browse"),
            mkSkill("qa", triggers: ["Take a Screenshot", "run qa"], name: "qa"),
            mkSkill("solo", triggers: ["unique phrase"], name: "solo"),
        ]
        let h = SkillHierarchy.build(skills)
        // Case-insensitive normalize → "take a screenshot" collides.
        let collision = try! #require(h.collisions.first { $0.phrase == "take a screenshot" })
        #expect(collision.skillNames == ["browse", "qa"])
        // "unique phrase" is claimed once → not a collision.
        #expect(!h.collisions.contains { $0.phrase == "unique phrase" })
    }

    @Test func distinctTriggersCounted() {
        let skills = [
            mkSkill("a", triggers: ["one", "two"]),
            mkSkill("b", triggers: ["two", "three"]),
        ]
        let h = SkillHierarchy.build(skills)
        #expect(h.distinctTriggers == 3)      // one, two, three
        #expect(h.collisions.map(\.phrase) == ["two"])
    }

    @Test func normalizeTriggerCollapsesAndTrims() {
        #expect(SkillHierarchy.normalizeTrigger("  Take   a  Screenshot. ") == "take a screenshot")
        #expect(SkillHierarchy.normalizeTrigger("\"run qa\"") == "run qa")
    }

    @Test func collisionsSortedByBreadthThenPhrase() {
        let skills = [
            mkSkill("a", triggers: ["wide", "narrow"], name: "a"),
            mkSkill("b", triggers: ["wide", "narrow"], name: "b"),
            mkSkill("c", triggers: ["wide"], name: "c"),
        ]
        let h = SkillHierarchy.build(skills)
        // "wide" (3 skills) before "narrow" (2 skills).
        #expect(h.collisions.map(\.phrase) == ["wide", "narrow"])
        #expect(h.collisions.first?.skillNames == ["a", "b", "c"])
    }
}

// MARK: - Multi-lane scanning (fixtures)

@Suite struct SkillScanAllTests {

    private func mkDir() throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("mck-scanall-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func writeManifest(_ dir: URL, _ folder: String, _ body: String) throws {
        let d = dir.appendingPathComponent(folder)
        try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        try body.write(to: d.appendingPathComponent("SKILL.md"), atomically: true, encoding: .utf8)
    }

    @Test func scanPluginsTagsSource() throws {
        let cache = try mkDir()
        defer { try? FileManager.default.removeItem(at: cache) }
        // cache/<market>/<plugin>/<version>/skills/<name>/SKILL.md
        let skillsDir = cache
            .appendingPathComponent("openai-codex/codex/1.0.4/skills")
        try writeManifest(skillsDir, "runtime", """
        ---
        name: codex-cli-runtime
        description: Codex CLI runtime.
        ---
        body
        """)

        let skills = SkillCatalog.scanPlugins(cacheDir: cache.path)
        #expect(skills.count == 1)
        let s = try #require(skills.first)
        #expect(s.source.pluginName == "codex")
        #expect(s.source.marketplace == "openai-codex")
        #expect(s.source.lane == .plugin)
        #expect(s.qualifiedID == "codex:runtime")
    }

    @Test func scanAllMergesUserAndPluginLanes() throws {
        let user = try mkDir()
        let cache = try mkDir()
        defer {
            try? FileManager.default.removeItem(at: user)
            try? FileManager.default.removeItem(at: cache)
        }
        try writeManifest(user, "agent-reach", "---\nname: agent-reach\ndescription: research\n---\nb")
        try writeManifest(cache.appendingPathComponent("m/p/1.0.0/skills"), "s",
                          "---\nname: s\ndescription: d\n---\nb")

        let all = SkillCatalog.scanAll(userDir: user.path, cacheDir: cache.path)
        let h = SkillHierarchy.build(all)
        #expect(h.laneCount(.user) == 1)
        #expect(h.laneCount(.plugin) == 1)
    }
}
