# trifola

Audit your Claude Code corpus in one line — no install, no account, no upload:

```bash
npx trifola
```

It prints a one-screen, anonymized finding card about *your own* `~/.claude`:

- **Dead skills** — how many catalog skills never fired across your sessions
  (and what their descriptions still cost by riding every prompt).
- **Prompt tax** — that dead weight priced at the cache-read rate.
- **Re-sent context** — the fresh-input premium above an all-cache-read floor,
  with the unavoidable first-touch cache build shown separately, never summed.

All dollar figures are **API-equivalent estimates at catalog rates — not your
plan bill** — and the card says so on-screen.

## Conversation search

```bash
npx trifola search keychain quota
npx trifola search "release checklist" --limit 5
npx trifola search keychain quota --json
```

Search is Claude Code-only (the macOS app searches Claude Code and Codex). It reads user prompts
and assistant prose, excluding tool calls/results, thinking, and system records. Results stream as
files are parsed: exact phrases first, then all-term matches, newest first within each rank. Matching
words are marked in text output; `--json` emits newline-delimited result and final status objects.

Search is exact-word only—no fuzzy or semantic matching. Unicode letters/numbers form words;
unspaced CJK text is generally one long token in v1, so a substring inside that run may not match.
Search output contains real local conversation text. Review it before sharing.

## Options

```
--json       Print the finding as machine-readable JSON.
--list-dead  Print never-fired skill IDs, one per line, for local pruning.
search <terms...> [--limit N] [--json]
             Stream Claude Code conversation-text matches (default limit: 10).
--help, -h   Print usage and exit.
```

Set `CLAUDE_CONFIG_DIR` to inspect a Claude Code config directory other than
`~/.claude`. Runs anywhere Node ≥ 18 does — macOS, Linux, WSL.

## Privacy

The CLI reads local files only. It opens no network connections, uploads
nothing, has no account, and sends no telemetry. The finding card is
anonymized (counts and dollars, never skill or project names); `--list-dead`
and `search` print real local names/conversation text, so review that output
before sharing it.

## The full product

This card is the 60-second taste. The complete audit — live attention board
(which agent needs you *now*), per-session cost receipts, routing forensics,
cache economics, and Codex support — is
**[trifola for macOS](https://github.com/ss251/trifola)**, free and MIT like
this CLI. (The app has additional, documented network-capable features; the
privacy statement above applies specifically to the npm CLI.)

## License

MIT. See [LICENSE](https://github.com/ss251/trifola/blob/main/LICENSE).
