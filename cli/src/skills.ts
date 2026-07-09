// Port of Sources/TrifolaKit/Skills.swift — catalog enumeration + the
// SKILL.md frontmatter reader. USER LANE ONLY (`<claudeDir>/skills`): the
// Swift app's AuditStore.refresh(sessions:skills:) call site feeds the
// dead-skill ledger from `SkillsStore.skills` (user lane), never
// `allSkills` (which also folds in the plugin cache + project dirs) — so
// that is the honest denominator this CLI reproduces. Plugin-cache and
// project-lane skills are out of scope for this MVP finding.

import * as fs from "node:fs";
import * as path from "node:path";

export interface Skill {
  /** Folder (or file stem) under skills/. */
  readonly id: string;
  /** Frontmatter `name:` or folder fallback. */
  readonly name: string;
  /** Folded/plain frontmatter description, or first prose line of the body. */
  readonly description: string;
  readonly version: string | undefined;
  readonly triggers: readonly string[];
  readonly allowedTools: readonly string[];
  /** True if a `---`-fenced frontmatter block was present at all. */
  readonly hasManifest: boolean;
  /** Body words — a rough prompt-size signal. */
  readonly wordCount: number;
  /** Files in the skill folder (1 for a single-file skill). */
  readonly fileCount: number;
  /** Absolute path to SKILL.md / the .md file. */
  readonly path: string;
}

// MARK: - Frontmatter

export interface ParsedFrontmatter {
  scalars: Record<string, string>;
  lists: Record<string, string[]>;
}

export interface SplitResult {
  frontmatter: ParsedFrontmatter | null;
  body: string;
}

const BLOCK_MARKERS = new Set([">", ">-", ">+", "|", "|-", "|+"]);

/**
 * Deliberately not a full YAML parser: top-level `key: value` scalars,
 * folded/literal blocks (`>`, `>-`, `|`, `|-`), and block lists of `- item`.
 * Anything fancier degrades gracefully to "value missing", never to a
 * crash — mirrors SkillFrontmatter.split/parse.
 */
export function splitFrontmatter(text: string): SplitResult {
  const allLines = text.split("\n");
  const first = allLines[0]?.trim();
  if (first !== "---") return { frontmatter: null, body: text };

  const rest = allLines.slice(1);
  const endIdx = rest.findIndex((l) => l.trim() === "---");
  if (endIdx === -1) return { frontmatter: null, body: text }; // unterminated fence -> treat as body

  const block = rest.slice(0, endIdx);
  const bodyLines = rest.slice(endIdx + 1);
  return { frontmatter: parseBlock(block), body: bodyLines.join("\n") };
}

function parseBlock(block: string[]): ParsedFrontmatter {
  const scalars: Record<string, string> = {};
  const lists: Record<string, string[]> = {};
  let i = 0;

  while (i < block.length) {
    const raw = block[i]!;
    const line = raw.trim();
    i += 1;
    if (line.length === 0 || raw.startsWith(" ") || raw.startsWith("\t")) continue;
    const colon = line.indexOf(":");
    if (colon === -1) continue;
    const key = line.slice(0, colon).trim();
    let value = line.slice(colon + 1).trim();

    // Folded (`>`/`>-`) and literal (`|`/`|-`) blocks: consume all following
    // indented lines. Folded joins with spaces (blank line = paragraph
    // break); literal preserves newlines.
    if (BLOCK_MARKERS.has(value)) {
      const folded = value.startsWith(">");
      const parts: string[] = [];
      while (i < block.length) {
        const next = block[i]!;
        const trimmed = next.trim();
        if (trimmed.length === 0) {
          parts.push("");
          i += 1;
          continue;
        }
        if (!(next.startsWith(" ") || next.startsWith("\t"))) break;
        parts.push(trimmed);
        i += 1;
      }
      while (parts.length > 0 && parts[parts.length - 1] === "") parts.pop();
      if (folded) {
        let acc = "";
        for (const p of parts) {
          if (p === "") acc += "\n\n";
          else if (acc === "" || acc.endsWith("\n")) acc += p;
          else acc += " " + p;
        }
        value = acc;
      } else {
        value = parts.join("\n");
      }
      scalars[key] = value;
      continue;
    }

    // Block list: `key:` followed by `- item` lines.
    if (value.length === 0) {
      const items: string[] = [];
      while (i < block.length) {
        const rawNext = block[i]!;
        const next = rawNext.trim();
        if (!next.startsWith("- ")) break;
        if (!(rawNext.startsWith(" ") || rawNext.startsWith("\t"))) break;
        items.push(next.slice(2).trim());
        i += 1;
      }
      if (items.length > 0) lists[key] = items;
      else scalars[key] = "";
      continue;
    }

    // Inline list `[a, b]` — rare but cheap to support.
    if (value.startsWith("[") && value.endsWith("]")) {
      lists[key] = value
        .slice(1, -1)
        .split(",")
        .map((s) => s.trim())
        .filter((s) => s.length > 0);
      continue;
    }

    // Plain scalar; strip symmetric quotes.
    if (
      value.length >= 2 &&
      ((value.startsWith('"') && value.endsWith('"')) || (value.startsWith("'") && value.endsWith("'")))
    ) {
      value = value.slice(1, -1);
    }
    scalars[key] = value;
  }

  return { scalars, lists };
}

function countWords(body: string): number {
  const tokens = body.split(/[ \t\n]+/).filter((s) => s.length > 0);
  return tokens.length;
}

// MARK: - Catalog

function loadSkill(id: string, manifestPath: string, fileCount: number): Skill | null {
  let text: string;
  try {
    text = fs.readFileSync(manifestPath, "utf8");
  } catch {
    return null;
  }

  const { frontmatter, body } = splitFrontmatter(text);
  const wordCount = countWords(body);

  let description: string;
  const fmDescription = frontmatter?.scalars["description"];
  if (fmDescription && fmDescription.length > 0) {
    description = fmDescription;
  } else {
    const line = body
      .split("\n")
      .map((l) => l.trim())
      .find((l) => l.length > 0 && !l.startsWith("#") && !l.startsWith("---"));
    description = line ?? "no description";
  }

  const nameRaw = frontmatter?.scalars["name"];
  const name = nameRaw && nameRaw.length > 0 ? nameRaw : id;
  const versionRaw = frontmatter?.scalars["version"];
  const version = versionRaw && versionRaw.length > 0 ? versionRaw : undefined;

  return {
    id,
    name,
    description,
    version,
    triggers: frontmatter?.lists["triggers"] ?? [],
    allowedTools: frontmatter?.lists["allowed-tools"] ?? [],
    hasManifest: frontmatter !== null,
    wordCount,
    fileCount,
    path: manifestPath,
  };
}

/**
 * Scan the user-lane skills directory (`<claudeDir>/skills`). Pure +
 * synchronous. Never throws — an unreadable entry just doesn't appear.
 * Mirrors SkillCatalog.scan(directory:source:.user).
 */
export function scanUserSkills(directory: string): Skill[] {
  let entries: string[];
  try {
    entries = fs.readdirSync(directory);
  } catch {
    return [];
  }

  const skills: Skill[] = [];
  for (const entry of [...entries].sort()) {
    if (entry.startsWith(".")) continue;
    const entryPath = path.join(directory, entry);

    let stat: fs.Stats;
    try {
      stat = fs.statSync(entryPath);
    } catch {
      continue;
    }

    if (stat.isDirectory()) {
      const manifest = path.join(entryPath, "SKILL.md");
      let fileCount = 0;
      try {
        fileCount = fs.readdirSync(entryPath).filter((e) => !e.startsWith(".")).length;
      } catch {
        /* fileCount stays 0 */
      }
      const skill = loadSkill(entry, manifest, fileCount);
      if (skill) {
        skills.push(skill);
      } else {
        // Folder with no SKILL.md at all — still worth surfacing.
        skills.push({
          id: entry,
          name: entry,
          description: "no SKILL.md in this folder",
          version: undefined,
          triggers: [],
          allowedTools: [],
          hasManifest: false,
          wordCount: 0,
          fileCount,
          path: entryPath,
        });
      }
    } else if (entry.toLowerCase().endsWith(".md")) {
      const id = entry.slice(0, -3);
      const skill = loadSkill(id, entryPath, 1);
      if (skill) skills.push(skill);
    }
  }
  return skills;
}
