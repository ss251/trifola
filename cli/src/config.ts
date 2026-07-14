import * as os from "node:os";
import * as path from "node:path";

/**
 * Resolve the Claude Code config directory. Honors the CLAUDE_CONFIG_DIR
 * override the real `claude` CLI respects, falling back to `~/.claude` —
 * mirrors Sources/TrifolaKit's `~/.claude` conventions (Ledger.swift's
 * ClaudeSettings.defaultURL, Stores.swift's SessionStore.projectsDir,
 * Skills.swift's SkillCatalog.defaultDirectory), all of which are hardcoded
 * to `~/.claude` in the Swift app. The CLI adds the env override since it
 * is meant to run against ANY machine's config, not just the one it ships
 * with.
 */
export function resolveClaudeDir(env: NodeJS.ProcessEnv = process.env): string {
  const override = env.CLAUDE_CONFIG_DIR;
  if (override && override.trim().length > 0) {
    return path.resolve(override.trim());
  }
  return path.join(os.homedir(), ".claude");
}

/** Resolve Codex's approved local-state root. Mirrors CodexPaths.resolve. */
export function resolveCodexDir(
  env: NodeJS.ProcessEnv = process.env,
  home: string = os.homedir(),
): string {
  const override = env.CODEX_HOME;
  if (override && override.trim().length > 0) {
    const value = override.trim();
    return path.resolve(value === "~" ? home : value.startsWith("~/") ? path.join(home, value.slice(2)) : value);
  }
  const resolvedHome = env.HOME?.trim() || home;
  return path.join(resolvedHome, ".codex");
}

/** The user-lane skills catalog directory — `<claudeDir>/skills`. */
export function skillsDirOf(claudeDir: string): string {
  return path.join(claudeDir, "skills");
}

/** The session transcripts root — `<claudeDir>/projects`. */
export function projectsDirOf(claudeDir: string): string {
  return path.join(claudeDir, "projects");
}

/** The only Codex transcript tree the CLI scans. */
export function codexSessionsDirOf(codexDir: string): string {
  return path.join(codexDir, "sessions");
}
