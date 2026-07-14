# Changelog

All notable changes to trifola are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/); versions follow [SemVer](https://semver.org/).

## [Unreleased]

### Fixed
- **No dishonest states, anywhere** — every limitation notice now carries its remedy in-surface
  (terminal fallback toasts gained Open Settings / copy-resume actions with honest copy and
  correct glyph semantics); no surface claims quiet/empty/$0 while the session scan is
  provisional (one canonical "Reading your sessions — N of ~M…" state across the app and menu
  bar); a transient read failure can no longer poison the search index's delta ladder, and
  historical poison self-heals on the next update.
- **Live-append CPU** — changed-path coalescing and key-scoped reconciliation take a 60s
  live-append fixture from 28.8% to 0.5% whole-process CPU; the session index moved from a
  59MB wholesale-rewrite JSON file to versioned SQLite/WAL with per-row delta writes.

### Added
- **Dual-provider CLI, proven** — `npx trifola` audits and searches Claude Code AND Codex with
  the app's exact money rules; `npm run parity` ships as the permanent cross-implementation
  contract (per-provider document/session/row equality and per-day per-model cents vs the app).
- **Dual-provider MCP quota** — `quota_windows` returns both providers with independent honest
  statuses; consent gates unchanged.
- **First-run onboarding** — a once-ever welcome over the live board, a primed user-initiated
  Automation ask, one permission flow per session, live Accessibility status with stale-grant
  recovery guidance; builds sign with a stable identity when available so grants survive
  rebuilds.
- **Perceptual accessibility** — Reduce Motion / Reduce Transparency / Increase Contrast
  honored across cards, chips, tiles, toasts, and onboarding.

### Added
- **Dual-provider MCP quota windows** — `quota_windows` now returns labeled Claude and Codex
  provider blocks, each independently consent-gated and carrying an explicit status when consent,
  credentials, a Codex corpus, or recent rollout rate-limit events are unavailable. Codex values
  come from the same local-only rollout reader as the Quota screen.
- **Calm, value-first onboarding** — corpus-present first launch now shows one persisted
  welcome over the already-live board; the first exact Terminal/iTerm jump explains its
  Apple Event before macOS asks; Automation and Accessibility explanations are spaced to one
  per app session; and `--render-onboarding` captures both production panels in both themes.
- Settings now rechecks Accessibility when its pane appears or Trifola returns to the
  foreground, and source builds get code-signature recovery guidance when a prior grant is
  no longer detected. A regression test also pins the app's no-login-item policy.

## [0.3.1] - 2026-07-14

### Added
- **Tiered CLI search index** — `trifola search` now picks the fastest local engine and labels
  it on every run (`engine` in `--json`): the app's index queried read-only on macOS, the CLI's
  own `node:sqlite` FTS5 index elsewhere (Node 22.5+; built lazily behind the first search's
  streamed results, then delta-updated per run), or the honest streaming scan on older Node.
  Zero new dependencies; the bare `npx trifola` audit never creates an index.
- Search performance benchmark harness (`--benchmark-search`) and `docs/BENCHMARKS.md` with
  measured, reproducible numbers.

### Fixed
- **Conversation-search indexing no longer rewrites the whole cache** — the v1 app encoded and
  atomically replaced a 98.5 MB `search-index.json` after every live transcript change, which
  could pin a CPU core and delay searches indefinitely. The index is now a schema-versioned
  system SQLite FTS5 database in WAL mode: unchanged transcripts read zero source bytes,
  append-only sessions parse and persist only their new JSONL suffix, rewrites replace only that
  session, first-run work commits in queryable 200-session batches with an honest partial-progress
  label, and the obsolete JSON cache is removed after a successful migration.
- **Search snippets are served from the index** — query-time re-parsing of source files made a
  15 ms query take 15 s against multi-hundred-MB live transcripts; the stored rows are the
  parsed truth and now provide snippets directly (file reread kept only as a fallback).
- **Typing in Sessions never blanks or flickers** — pending now strictly means "the answer on
  screen is for a different question": same-query refreshes from live index updates recompute
  silently and swap atomically; a partially built index can no longer claim "No matches"; a
  transiently failing terminal-registry probe keeps the last good live set instead of flapping
  every projection; the duplicate Codex filter chip is gone.

## [0.3.0] - 2026-07-14

### Added
- **Conversation search** — the macOS Sessions field now searches exact words across Claude Code
  and Codex user prompts plus assistant prose through a separately versioned, incremental local
  index. Results keep title/path scope distinct from conversation text, reread exact highlighted
  snippets on demand, blend phrase hits with recency, and explicitly exclude tool output/thinking.
- **Streaming CLI search** — `npx trifola search <terms...>` scans Claude Code conversation text
  locally with phrase-first streaming, `--limit N`, and newline-delimited `--json` carrying a raw-
  output warning. The CLI remains Claude-only; the app covers both providers.

### Fixed
- **Cross-surface number honesty** — the app's Overview header now counts top-level sessions
  (matching the npm CLI's denominator) and discloses subagent runs separately
  ("N sessions (+M subagent runs)"); the CLI card states its scope explicitly ("Claude Code
  only — the macOS app also reads Codex"). Two trifola surfaces must never disagree silently.

## [0.2.0] - 2026-07-13

### Added
- **Dual-provider ingestion** — trifola now reads `~/.codex` natively alongside `~/.claude`: a
  tagged-union rollout parser (`.jsonl` + bounded `.jsonl.zst`), Codex session titles from the
  provider's own index with a first-prompt fallback, Codex transcripts rendered from rollout
  events (never a blank pane), provider-aware first-run onboarding, and live FSEvents watching of
  both roots. Threads Codex re-imported from Claude are deduplicated at the source.
- **Provider-honest attention** — Codex sessions classify WAITING / RUNNING / IDLE from
  provider-native signals and are *never* shown BLOCKED (approval prompts are not persisted to
  disk, so disk cannot know) — encoded as a tested invariant.
- **Codex quota windows** — read locally from rate-limit events already persisted in rollouts;
  no network request, no spawned process.
- **Model-exact spend transparency** — the models card and the Spend & Routing tier table expand
  every tier that aggregates more than one model id into its members (id, sessions, dollars,
  share), so no tier is an opaque bucket; a per-id spend table names exact model ids with a
  provider column. Fallback-priced ids are marked "est. rate".
- **Custom model tier** — a Settings match + label pair routes private/internal model families
  into their own named display tier, applied corpus-wide without a reparse.
- **Session transport ladder** — "Open session" lands on the exact hosting surface: live-registry
  session-id→PID join (with a named-sibling join for headless daemon background jobs), exact
  AppleScript tab targeting (Terminal.app, iTerm2), tab-exact targeting in workspace-style
  terminal apps through their own bundle-sealed, signature-verified controller (session id joins
  a surface's resume binding; hosting window fronted first; UUID-verified post-conditions), an
  opt-in Accessibility scoring tier with a never-guess confidence floor, and honest fallbacks —
  every failure names its cause, every success confirms what it did.
- **Launch feedback** — the open action shows an immediate "Opening session…" busy state; repeat
  clicks coalesce instead of restarting the launch; transcript-only actions carry a visible
  reason (Codex session, remote, not running, headless, no confident match).
- **Quota consent** — plan-quota access is opt-in and off by default, per provider, with
  exact-scope copy in Settings; no credential file, Keychain, or network access happens before
  consent, including through MCP.
- **Design system** — role-based type scale, responsive layout tokens (fullscreen composition,
  width-matrix verified), a rebuilt menu-bar panel, structured-transcript rendering, a code-drawn
  brand mark with icon/menu-bar/social variants, and a navigation-performance architecture
  (off-main snapshot projections; destination switches paint within a frame).

### Changed
- **Pricing catalog verified against official sources** (2026-07-13): every bundled rate matches
  the official Anthropic and OpenAI pricing pages exactly, with provenance stated at the seed;
  Sonnet 5's introductory pricing era is date-encoded. The MCP session-identity contract is
  explicit (registered session, explicit `session_id`, or `use_newest: true` — omission alone is
  an error). README data-flow and permissions tables document the consent-gated quota reads and
  the optional local Automation/Accessibility permissions.

### Fixed
- **Codex money accuracy** — Codex's inclusive cached-input representation converts losslessly at
  parse time (no double-billing); cumulative counter resets start a new epoch instead of minting
  negative usage; usage recorded before a resumed rollout names its model attributes to the first
  observed model instead of an anonymous bucket; `gpt-5-codex` and `gpt-5.2-codex` carry their
  official rates instead of a ~4× tier fallback.
- Session rows and titles fall back to the working-directory basename instead of a wall of
  "Untitled session".
- The manual Refresh control reflects only user-initiated refreshes; background scans no longer
  animate or disable it.
- The Codex tier hue is a distinct steel-blue (it was near-identical to Haiku's teal, making the
  legend and split bar ambiguous).

### Security
- Quota access consent-gated per provider, off by default (file/Keychain/network only after
  explicit opt-in). The bundled-controller transport tier requires a same-team code signature on
  a binary sealed inside the owning app's bundle, runs with fixed argv, a minimal environment,
  bounded IO and hard deadlines, and fails closed on any ambiguity. Accessibility is requested
  only at the moment of value with a plain-language explainer; the compressed-rollout reader is
  bounded (deadline + decompressed-size cap).

## [0.1.0] - 2026-07-10

Initial public tree.

### Added
- **Attention board** — every session as BLOCKED / WAITING / RUNNING / IDLE, worst-first, in a menu-bar glance.
- **Cost-cause audit** — re-sent context vs unavoidable first-touch (never summed into one number), Opus-on-lint model mismatch, dead-skill ledger, and per-session receipts.
- **Routing forensics** — silent model fallbacks and subagent model-inheritance leaks, with a copy-able `CLAUDE.md` fix.
- **Context tax** — the warm-vs-cold price of your next message, at the session's own rates.
- **Whole-fleet preview** — experimental cross-machine consolidation over manually configured Tailscale/SSH hosts.
- **Agent-facing MCP preview** — `session_brief`, `context_tax`, `reroutes`, `cost_today`, and `quota_windows` for a running session to introspect itself after manual registration.
- **Quota windows** — real plan windows with file/Keychain credential fallback.
- **npm CLI** — local-only corpus finding card with JSON and dead-skill-list modes.
- **Headless `--render-*` harness** — a synthetic-fixture screenshot factory (also the CI-vs-version and demo surface).
- **Personal-PII CI lint** — fails the build on configured personal identifiers or private paths.

[Unreleased]: https://github.com/ss251/trifola/compare/v0.3.1...HEAD
[0.3.1]: https://github.com/ss251/trifola/releases/tag/v0.3.1
[0.3.0]: https://github.com/ss251/trifola/releases/tag/v0.3.0
[0.2.0]: https://github.com/ss251/trifola/releases/tag/v0.2.0
