#!/usr/bin/env node
// trifola — `npx trifola`: reads the local ~/.claude (or $CLAUDE_CONFIG_DIR),
// never uploads anything, and prints an anonymized share-card finding —
// dead skills, prompt tax, and re-sent context — priced at API-equivalent
// rates ported from the trifola macOS app's TrifolaKit (see cli/src/pricing.ts,
// ledger.ts, skills.ts, transcripts.ts for the exact per-file parity notes).
// Exit quietly when stdout closes early (`trifola | head`) instead of crashing
// with an unhandled EPIPE 'error' event — standard CLI etiquette.
process.stdout.on("error", (err) => {
    if (err.code === "EPIPE")
        process.exit(0);
    throw err;
});
import { resolveClaudeDir, skillsDirOf, projectsDirOf } from "./config.js";
import { scanUserSkills } from "./skills.js";
import { scanProjects } from "./transcripts.js";
import { buildFinding } from "./ledger.js";
import { renderCard, renderJSON, HELP_TEXT } from "./card.js";
import { spin } from "./spinner.js";
import { fmtCount } from "./format.js";
import { dim } from "./style.js";
import { parseSearchArgs, markedSnippet, relativeAge, SEARCH_SCOPE, RAW_WARNING, } from "./search.js";
import { runTieredSearch } from "./search-index.js";
async function runSearch(argv) {
    const request = parseSearchArgs(argv);
    const claudeDir = resolveClaudeDir();
    const spinner = spin("searching Claude Code conversation text…");
    if (!request.json) {
        process.stdout.write(`trifola search — ${SEARCH_SCOPE}\n`);
    }
    const notices = [];
    const emit = (match) => {
        if (request.json) {
            process.stdout.write(JSON.stringify(match) + "\n");
            return;
        }
        process.stdout.write(`${match.title} · ${match.project} · ${relativeAge(match.lastActivity)}\n` +
            `  ${match.role === "user" ? "You" : "Assistant"}: ${markedSnippet(match)}\n`);
    };
    const summary = await runTieredSearch(projectsDirOf(claudeDir), request, {
        onMatch: emit,
        onTier: (info) => {
            if (!request.json)
                process.stdout.write(dim(`engine: Tier ${info.tier} — ${info.detail}`) + "\n");
        },
        onNotice: (message) => {
            notices.push(message);
            if (!request.json)
                process.stdout.write(message + "\n");
        },
        onProgress: (done, total, pass) => {
            spinner.update(`${pass === "phrase" ? "phrase" : "term"} pass · ${fmtCount(done + 1)} of ${fmtCount(total)} file reads · nothing leaves this machine`);
        },
    });
    spinner.done();
    if (request.json) {
        process.stdout.write(JSON.stringify({
            type: "status",
            status: summary.scannedFiles === 0
                ? "empty-corpus"
                : request.terms.length === 0 || summary.emitted > 0
                    ? "complete"
                    : "no-matches",
            provider: "claude",
            scope: "conversation-text",
            engine: summary.engine,
            tier: summary.tier,
            scannedFiles: summary.scannedFiles,
            emitted: summary.emitted,
            indexBuilt: summary.indexBuilt,
            ...(summary.indexPath ? { indexPath: summary.indexPath } : {}),
            ...(summary.update ? { update: summary.update } : {}),
            ...(notices.length > 0 ? { notices } : {}),
            warning: RAW_WARNING,
        }) + "\n");
    }
    else if (summary.scannedFiles === 0) {
        process.stdout.write("No Claude Code session transcripts found under this config directory.\n");
    }
    else if (summary.emitted === 0 && request.terms.length > 0) {
        process.stdout.write("No matches in Claude Code conversation text.\n");
    }
    if (!request.json)
        process.stdout.write(`Warning: ${RAW_WARNING}.\n`);
}
async function run(argv) {
    if (argv.includes("--help") || argv.includes("-h")) {
        process.stdout.write(HELP_TEXT + "\n");
        return;
    }
    if (argv[0] === "search") {
        await runSearch(argv.slice(1));
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
        process.stdout.write(`# ${finding.deadCount} of ${finding.catalogCount} skills never explicit-fired across ` +
            `${finding.sessionCount} sessions (local prune list — don't share raw)\n`);
        for (const name of finding.deadNames)
            process.stdout.write(name + "\n");
        return;
    }
    if (asJson) {
        process.stdout.write(JSON.stringify(renderJSON(finding), null, 2) + "\n");
    }
    else {
        process.stdout.write(renderCard(finding) + "\n");
    }
}
try {
    await run(process.argv.slice(2));
}
catch (err) {
    const message = err instanceof Error ? err.message : String(err);
    process.stderr.write(`trifola: ${message}\n`);
    process.exitCode = 1;
}
