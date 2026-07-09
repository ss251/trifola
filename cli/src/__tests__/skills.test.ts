import { test, describe } from "node:test";
import assert from "node:assert/strict";
import * as fs from "node:fs";
import * as path from "node:path";
import { splitFrontmatter, scanUserSkills } from "../skills.js";
import { withTempDir, writeFile } from "./testutil.js";

// Mirrors Tests/TrifolaKitTests/SkillsTests.swift's SkillFrontmatterTests +
// SkillCatalogTests — same scenarios, same expected values, so a pass here
// cross-validates the port against the Swift source's own fixtures.

describe("splitFrontmatter", () => {
  test("plain scalars", () => {
    const { frontmatter, body } = splitFrontmatter(
      ["---", "name: gstack", "version: 1.1.0", "description: Fast headless browser for QA testing. (gstack)", "---", "", "# Body"].join(
        "\n"
      )
    );
    assert.equal(frontmatter?.scalars["name"], "gstack");
    assert.equal(frontmatter?.scalars["version"], "1.1.0");
    assert.equal(frontmatter?.scalars["description"], "Fast headless browser for QA testing. (gstack)");
    assert.ok(body.includes("# Body"));
  });

  test("folded description joins lines with a space and keeps paragraph breaks", () => {
    const { frontmatter } = splitFrontmatter(
      [
        "---",
        "name: api-client",
        "description: >",
        '  MUST USE when user wants to research anything on the',
        '  internet — e.g. "do a deep dive on X".',
        "",
        "  Also MUST USE when user mentions any platform or URL.",
        "---",
        "body",
      ].join("\n")
    );
    const d = frontmatter?.scalars["description"] ?? "";
    assert.ok(d.includes("research anything on the internet — e.g."));
    assert.ok(d.includes("\n\n"));
    assert.ok(d.endsWith("platform or URL."));
  });

  test("folded strip variant (>-) joins with a single space, no trailing newline", () => {
    const { frontmatter } = splitFrontmatter(["---", "description: >-", "  Line one", "  line two", "---"].join("\n"));
    assert.equal(frontmatter?.scalars["description"], "Line one line two");
  });

  test("literal block (|) keeps newlines", () => {
    const { frontmatter } = splitFrontmatter(["---", "script: |", "  step one", "  step two", "---"].join("\n"));
    assert.equal(frontmatter?.scalars["script"], "step one\nstep two");
  });

  test("block and inline lists", () => {
    const { frontmatter } = splitFrontmatter(
      [
        "---",
        "allowed-tools:",
        "  - Bash",
        "  - Read",
        "  - AskUserQuestion",
        "triggers:",
        "  - browse this page",
        "  - take a screenshot",
        "benefits-from: [office-hours, qa]",
        "---",
      ].join("\n")
    );
    assert.deepEqual(frontmatter?.lists["allowed-tools"], ["Bash", "Read", "AskUserQuestion"]);
    assert.deepEqual(frontmatter?.lists["triggers"], ["browse this page", "take a screenshot"]);
    assert.deepEqual(frontmatter?.lists["benefits-from"], ["office-hours", "qa"]);
  });

  test("quoted scalars and colon-containing values", () => {
    const { frontmatter } = splitFrontmatter(
      ["---", 'name: "quoted name"', "note: 'single'", "url: https://example.com/path", "---"].join("\n")
    );
    assert.equal(frontmatter?.scalars["name"], "quoted name");
    assert.equal(frontmatter?.scalars["note"], "single");
    assert.equal(frontmatter?.scalars["url"], "https://example.com/path");
  });

  test("no frontmatter", () => {
    const { frontmatter, body } = splitFrontmatter("# Just a doc\n\nProse here.");
    assert.equal(frontmatter, null);
    assert.ok(body.includes("Prose here."));
  });

  test("unterminated fence is treated as body", () => {
    const { frontmatter, body } = splitFrontmatter("---\nname: broken\nno closing fence");
    assert.equal(frontmatter, null);
    assert.ok(body.includes("name: broken"));
  });
});

describe("scanUserSkills", () => {
  test("scans a mixed directory: manifest folder, no-manifest folder, empty folder, stray file, hidden entry", async () => {
    await withTempDir("trifola-skills-", async (dir) => {
      writeFile(
        path.join(dir, "alpha", "SKILL.md"),
        ["---", "name: alpha-skill", "version: 2.0", "description: >-", "  Folded description", "  across lines.", "triggers:", "  - use alpha", "---", "# Alpha", "one two three four"].join(
          "\n"
        )
      );
      writeFile(path.join(dir, "no-manifest", "SKILL.md"), "# Heading\n\nFirst prose line.\nmore");
      fs.mkdirSync(path.join(dir, "empty-folder"), { recursive: true }); // truly empty — no SKILL.md, no files at all
      writeFile(path.join(dir, "stray-skill.md"), "---\nname: stray\ndescription: single file\n---\nbody");
      writeFile(path.join(dir, ".hidden", "SKILL.md"), "---\nname: hidden\n---\n");

      const skills = scanUserSkills(dir);
      assert.equal(skills.length, 4); // hidden entry excluded

      const alpha = skills.find((s) => s.id === "alpha");
      assert.ok(alpha);
      assert.equal(alpha!.name, "alpha-skill");
      assert.equal(alpha!.version, "2.0");
      assert.equal(alpha!.description, "Folded description across lines.");
      assert.deepEqual(alpha!.triggers, ["use alpha"]);
      assert.ok(alpha!.hasManifest);
      assert.ok(alpha!.wordCount >= 5);

      const bare = skills.find((s) => s.id === "no-manifest");
      assert.ok(bare);
      assert.ok(!bare!.hasManifest);
      assert.equal(bare!.name, "no-manifest");
      assert.equal(bare!.description, "First prose line.");

      const empty = skills.find((s) => s.id === "empty-folder");
      assert.ok(empty);
      assert.ok(!empty!.hasManifest);
      assert.equal(empty!.description, "no SKILL.md in this folder");

      const stray = skills.find((s) => s.id === "stray-skill");
      assert.ok(stray);
      assert.equal(stray!.name, "stray");
      assert.equal(stray!.fileCount, 1);
    });
  });

  test("missing directory yields empty, never throws", () => {
    assert.deepEqual(scanUserSkills(`/nonexistent/${Date.now()}-${Math.random()}`), []);
  });
});
