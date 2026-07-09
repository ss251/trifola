#!/usr/bin/env node
// trifola — `npx trifola`: reads the local ~/.claude (or $CLAUDE_CONFIG_DIR),
// never uploads anything, and prints an anonymized share-card finding —
// dead skills, prompt tax, and re-sent context — priced at API-equivalent
// rates ported from the trifola macOS app's TrifolaKit (see cli/src/pricing.ts,
// ledger.ts, skills.ts, transcripts.ts for the exact per-file parity notes).

import { resolveClaudeDir, skillsDirOf, projectsDirOf } from "./config.js";
import { scanUserSkills } from "./skills.js";
import { scanProjects } from "./transcripts.js";
import { buildFinding } from "./ledger.js";
import { renderCard, renderJSON, HELP_TEXT } from "./card.js";

function run(argv: string[]): void {
  if (argv.includes("--help") || argv.includes("-h")) {
    process.stdout.write(HELP_TEXT + "\n");
    return;
  }

  const asJson = argv.includes("--json");
  const claudeDir = resolveClaudeDir();
  const skills = scanUserSkills(skillsDirOf(claudeDir));
  const corpus = scanProjects(projectsDirOf(claudeDir));
  const finding = buildFinding(skills, corpus);

  if (asJson) {
    process.stdout.write(JSON.stringify(renderJSON(finding), null, 2) + "\n");
  } else {
    process.stdout.write(renderCard(finding) + "\n");
  }
}

try {
  run(process.argv.slice(2));
} catch (err) {
  const message = err instanceof Error ? err.message : String(err);
  process.stderr.write(`trifola: ${message}\n`);
  process.exitCode = 1;
}
