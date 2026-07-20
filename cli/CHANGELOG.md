# Changelog

## [Unreleased]

### Added

- Grok Build joins the audit and conversation search as a third provider: directory-backed
  `~/.grok` (or `GROK_HOME`) sessions are scanned for per-turn usage priced at xAI list rates
  with billing-partial disclosure, Grok search results and JSON provider breakdowns, and Grok
  checks in `npm run parity`.

- Full dual-provider audit and conversation search for Claude Code plus Codex, including exact
  rollout counter/cache/import rules, Codex pricing, provider JSON breakdowns, `.jsonl.zst`
  feature detection, mixed-corpus fixtures, and `npm run parity` for real-corpus app/CLI parity.

- Conversation search now uses a labeled three-tier engine: the matching macOS app FTS5 index
  read-only, a separate incremental `node:sqlite` CLI index on Node 22.5+, or the existing scan on
  older Node versions. The CLI index supports append-only updates, schema-version rebuilds,
  `--rebuild-index`, and an `engine` field in newline-delimited JSON without adding dependencies.
