#!/usr/bin/env node
// trifola — `npx trifola`: reads the local ~/.claude (or $CLAUDE_CONFIG_DIR),
// never uploads anything, and prints an anonymized share-card finding —
// dead skills, prompt tax, and re-sent context — priced at API-equivalent
// rates ported from the trifola macOS app's TrifolaKit (see cli/src/pricing.ts,
// ledger.ts, skills.ts, transcripts.ts for the exact per-file parity notes).

// Exit quietly when stdout closes early (`trifola | head`) instead of crashing
// with an unhandled EPIPE 'error' event — standard CLI etiquette.
process.stdout.on("error", (err: NodeJS.ErrnoException) => {
  if (err.code === "EPIPE") process.exit(0);
  throw err;
});

import { resolveClaudeDir, skillsDirOf, projectsDirOf } from "./config.js";
import { scanUserSkills } from "./skills.js";
import { scanProjects } from "./transcripts.js";
import { buildFinding } from "./ledger.js";
import { renderCard, renderJSON, HELP_TEXT } from "./card.js";
import { spin } from "./spinner.js";
import { fmtCount } from "./format.js";

function run(argv: string[]): void {
  if (argv.includes("--help") || argv.includes("-h")) {
    process.stdout.write(HELP_TEXT + "\n");
    return;
  }

  const asJson = argv.includes("--json");
  const claudeDir = resolveClaudeDir();
  const spinner = spin("reading your skill catalog…");
  const skills = scanUserSkills(skillsDirOf(claudeDir));
  const corpus = scanProjects(projectsDirOf(claudeDir), (done, total) => {
    spinner.update(`reading ${fmtCount(done + 1)} of ${fmtCount(total)} transcripts · nothing leaves this machine`);
  });
  spinner.update("pricing at public API rates…");
  const finding = buildFinding(skills, corpus);
  spinner.done();

  if (argv.includes("--list-dead")) {
    // Local prune-list mode: real skill ids, one per line. Deliberately NOT part
    // of the share card or --json — names are personal; the card stays anonymized.
    process.stdout.write(
      `# ${finding.deadCount} of ${finding.catalogCount} skills never explicit-fired across ` +
        `${finding.sessionCount} sessions (local prune list — don't share raw)\n`,
    );
    for (const name of finding.deadNames) process.stdout.write(name + "\n");
    return;
  }

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
