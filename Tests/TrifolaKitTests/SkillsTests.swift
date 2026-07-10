import Foundation
import Testing
@testable import TrifolaKit

// MARK: - Helpers

private func skillsDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("mck-skills-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

@discardableResult
private func addSkill(_ dir: URL, _ folder: String, manifest: String?) throws -> URL {
    let d = dir.appendingPathComponent(folder)
    try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
    if let manifest {
        try manifest.write(to: d.appendingPathComponent("SKILL.md"),
                           atomically: true, encoding: .utf8)
    }
    return d
}

// MARK: - Frontmatter parsing

@Suite struct SkillFrontmatterTests {

    @Test func plainScalars() {
        let (fm, body) = SkillFrontmatter.split("""
        ---
        name: gstack
        version: 1.1.0
        description: Fast headless browser for QA testing. (gstack)
        ---

        # Body
        """)
        #expect(fm?.scalars["name"] == "gstack")
        #expect(fm?.scalars["version"] == "1.1.0")
        #expect(fm?.scalars["description"] == "Fast headless browser for QA testing. (gstack)")
        #expect(body.contains("# Body"))
    }

    @Test func foldedDescription() {
        let (fm, _) = SkillFrontmatter.split("""
        ---
        name: api-client
        description: >
          MUST USE when user wants to research anything on the
          internet — e.g. "do a deep dive on X".

          Also MUST USE when user mentions any platform or URL.
        ---
        body
        """)
        let d = fm?.scalars["description"] ?? ""
        // Folded: adjacent lines join with a space…
        #expect(d.contains("research anything on the internet — e.g."))
        // …and a blank line becomes a paragraph break, not a lost space.
        #expect(d.contains("\n\n"))
        #expect(d.hasSuffix("platform or URL."))
    }

    @Test func foldedStripVariant() {
        let (fm, _) = SkillFrontmatter.split("""
        ---
        description: >-
          Line one
          line two
        ---
        """)
        #expect(fm?.scalars["description"] == "Line one line two")
    }

    @Test func literalBlockKeepsNewlines() {
        let (fm, _) = SkillFrontmatter.split("""
        ---
        script: |
          step one
          step two
        ---
        """)
        #expect(fm?.scalars["script"] == "step one\nstep two")
    }

    @Test func blockAndInlineLists() {
        let (fm, _) = SkillFrontmatter.split("""
        ---
        allowed-tools:
          - Bash
          - Read
          - AskUserQuestion
        triggers:
          - browse this page
          - take a screenshot
        benefits-from: [office-hours, qa]
        ---
        """)
        #expect(fm?.lists["allowed-tools"] == ["Bash", "Read", "AskUserQuestion"])
        #expect(fm?.lists["triggers"] == ["browse this page", "take a screenshot"])
        #expect(fm?.lists["benefits-from"] == ["office-hours", "qa"])
    }

    @Test func quotedScalarsAndColonValues() {
        let (fm, _) = SkillFrontmatter.split("""
        ---
        name: "quoted name"
        note: 'single'
        url: https://example.com/path
        ---
        """)
        #expect(fm?.scalars["name"] == "quoted name")
        #expect(fm?.scalars["note"] == "single")
        // First colon splits key from value; the rest stays intact.
        #expect(fm?.scalars["url"] == "https://example.com/path")
    }

    @Test func noFrontmatter() {
        let (fm, body) = SkillFrontmatter.split("# Just a doc\n\nProse here.")
        #expect(fm == nil)
        #expect(body.contains("Prose here."))
    }

    @Test func unterminatedFenceIsBody() {
        let (fm, body) = SkillFrontmatter.split("---\nname: broken\nno closing fence")
        #expect(fm == nil)
        #expect(body.contains("name: broken"))
    }
}

// MARK: - Catalog scanning

@Suite struct SkillCatalogTests {

    @Test func scanMixedDirectory() throws {
        let dir = try skillsDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        try addSkill(dir, "alpha", manifest: """
        ---
        name: alpha-skill
        version: 2.0
        description: >-
          Folded description
          across lines.
        triggers:
          - use alpha
        ---
        # Alpha
        one two three four
        """)
        try addSkill(dir, "no-manifest", manifest: "# Heading\n\nFirst prose line.\nmore")
        try addSkill(dir, "empty-folder", manifest: nil)
        // Stray single-file skill at top level.
        try "---\nname: stray\ndescription: single file\n---\nbody".write(
            to: dir.appendingPathComponent("stray-skill.md"),
            atomically: true, encoding: .utf8)
        // Hidden entries are ignored.
        try FileManager.default.createDirectory(
            at: dir.appendingPathComponent(".hidden"), withIntermediateDirectories: true)

        let skills = SkillCatalog.scan(directory: dir.path)
        #expect(skills.count == 4)

        let alpha = try #require(skills.first { $0.id == "alpha" })
        #expect(alpha.name == "alpha-skill")
        #expect(alpha.version == "2.0")
        #expect(alpha.description == "Folded description across lines.")
        #expect(alpha.triggers == ["use alpha"])
        #expect(alpha.hasManifest)
        #expect(alpha.wordCount >= 5)  // "# Alpha one two three four"

        let bare = try #require(skills.first { $0.id == "no-manifest" })
        #expect(!bare.hasManifest)
        #expect(bare.name == "no-manifest")
        #expect(bare.description == "First prose line.")

        let empty = try #require(skills.first { $0.id == "empty-folder" })
        #expect(!empty.hasManifest)
        #expect(empty.description == "no SKILL.md in this folder")

        let stray = try #require(skills.first { $0.id == "stray-skill" })
        #expect(stray.name == "stray")
        #expect(stray.fileCount == 1)
    }

    @Test func missingDirectoryYieldsEmpty() {
        #expect(SkillCatalog.scan(directory: "/nonexistent/\(UUID())").isEmpty)
    }

    // Opportunistic real-corpus check: runs only where a real library exists
    // (developer machines). CI runners have no ~/.claude — that absence is an
    // environment fact, not a regression, so the test disables itself there.
    @Test(.enabled(if: FileManager.default.fileExists(
        atPath: NSString(string: "~/.claude/skills").expandingTildeInPath)))
    func realSkillsDirectoryParsesCleanly() throws {
        // Guard against regressions on the machine's actual library: every
        // entry must produce a non-empty name and description.
        let skills = SkillCatalog.scan()
        try #require(!skills.isEmpty, "no ~/.claude/skills on this machine")
        for s in skills {
            #expect(!s.name.isEmpty, "empty name for \(s.id)")
            #expect(!s.description.isEmpty, "empty description for \(s.id)")
        }
    }
}

// MARK: - Filtering

@Suite struct SkillsFilterTests {

    private func mk(_ id: String, desc: String = "", triggers: [String] = []) -> Skill {
        Skill(id: id, name: id, description: desc, version: nil, triggers: triggers,
              allowedTools: [], hasManifest: true, wordCount: 0, fileCount: 1,
              modified: .distantPast, path: "/tmp/\(id)")
    }

    @Test func filterMatchesNameDescriptionAndTriggers() {
        let skills = [
            mk("codeflow", desc: "context compression"),
            mk("api-client", desc: "internet research", triggers: ["deep dive"]),
            mk("qa"),
        ]
        #expect(SkillsStore.filter(skills, query: "").count == 3)
        #expect(SkillsStore.filter(skills, query: "CODEFLOW").map(\.id) == ["codeflow"])
        #expect(SkillsStore.filter(skills, query: "compression").map(\.id) == ["codeflow"])
        #expect(SkillsStore.filter(skills, query: "deep dive").map(\.id) == ["api-client"])
        #expect(SkillsStore.filter(skills, query: "zzz").isEmpty)
    }
}
