# trifola

Audit your Claude Code and Codex corpus in one line — no install, no account, no upload:

```bash
npx trifola
```

It prints a one-screen, anonymized finding card about *your own* `~/.claude` and `~/.codex`:

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

Search covers both Claude Code and Codex. It reads user prompts and assistant prose, excluding tool
calls/results, thinking, and system records. Matching words are
marked in text output; `--json` emits newline-delimited result and final status objects, each labeled
with the serving `engine`.

Search chooses the fastest available local tier:

1. **App index** — on macOS, a matching Trifola app index is queried read-only. The CLI never writes
   to the app store.
2. **CLI index** — when `node:sqlite` is available (Node 22.5+), search maintains a separate FTS5
   index. The first query streams the normal scan results while the index is built, then announces
   that later searches are instant. Warm runs parse only changed or appended transcripts.
3. **Scan** — older Node versions keep the existing phrase-first, newest-first two-pass scan and say
   honestly that Node 22.5+ enables indexing.

The CLI index is stored at `$XDG_CACHE_HOME/trifola/search-index.sqlite3` when XDG cache is set,
`~/Library/Caches/trifola/search-index.sqlite3` on macOS, or `~/.cache/trifola/search-index.sqlite3`
on other platforms. It is never stored under either provider's config root. Rebuild it with:

```bash
npx trifola search --rebuild-index
```

To delete it manually, remove `search-index.sqlite3` and its optional `-wal`/`-shm` sidecars from
that cache directory. A bare `npx trifola` audit never creates or updates the search index.

Search is exact-word only—no fuzzy or semantic matching. Unicode letters/numbers form words;
unspaced CJK text is generally one long token in v1, so a substring inside that run may not match.
Search output contains real local conversation text. Review it before sharing.

## Options

```
--json       Print the finding as machine-readable JSON.
--list-dead  Print never-fired skill IDs, one per line, for local pruning.
search <terms...> [--limit N] [--json] [--rebuild-index]
             Stream Claude Code + Codex conversation-text matches (default limit: 10).
search --rebuild-index
             Recreate the CLI-owned index without running a query.
--help, -h   Print usage and exit.
```

Set `CLAUDE_CONFIG_DIR` to inspect a Claude Code config directory other than
`~/.claude`; set `CODEX_HOME` for a Codex root other than `~/.codex`. Runs anywhere
Node ≥ 18 does — macOS, Linux, WSL. Node 22.15+ reads `.jsonl.zst` rollouts through
built-in zstd; older Nodes report how many compressed rollouts they skipped.

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
