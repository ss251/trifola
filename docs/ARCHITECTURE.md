# Architecture

trifola is a native macOS (SwiftUI, Swift 6) reader over `~/.claude`, `~/.codex`, **and**
`~/.grok`. Zero external dependencies. The design splits cleanly into three layers.

```
┌──────────────────────────────────────────────────────────────┐
│  ENGINE (Swift, MIT) — commodity, correct, fast              │
│  version-tolerant per-provider parsers · incremental         │
│  append-only index · FSEvents pipeline · attention state     │
│  machine · pricing math · session transport ladder ·         │
│  render/UI · read-only MCP server                            │
├──────────────────────────────────────────────────────────────┤
│  STABLE CONTRACT — the "workflow schema"                     │
│  SessionSummary (provider-tagged) · usageByModel/Tier ·      │
│  SkillLedger · probes: a documented, versioned surface       │
│  the detectors query                                         │
├──────────────────────────────────────────────────────────────┤
│  PLAYBOOK (data) — the judgment, shipped as content          │
│  detectors: evidence query + threshold + finding copy +      │
│  remedy + citation + calibration date + schema-version range │
│  (v1: in Swift · v1.1 roadmap: externalized, updatable data) │
└──────────────────────────────────────────────────────────────┘
```

## Engine

### Multi-provider ingestion

One incremental index, N `SessionSource`s. Each source owns its root, its filename filter, and
its parser; everything downstream consumes the same provider-tagged `SessionSummary`.

- **Claude source** — `~/.claude/projects/**/*.jsonl` through the flat-record accumulator:
  `(messageId, requestId)` dedup, sidechain/subagent layouts, per-message model+day usage
  attribution, cross-file replay reconciliation.
- **Codex source** — `$CODEX_HOME/sessions/**/rollout-*.jsonl` (+ `.jsonl.zst`, decompressed
  through a bounded subprocess: hard deadline, output cap, kill on breach) through a tagged-union
  rollout accumulator. Three traps it exists to defuse:
  - **The cache trap.** Codex `input_tokens` *includes* cached input; Anthropic's excludes it.
    Conversion to trifola's additive representation happens at parse time — applying the Claude
    formula raw would double-bill the cached slice.
  - **Counter resets.** Cumulative token counters can reset mid-thread; each reset starts a new
    epoch that namespaces dedup keys, so a fresh baseline can never overwrite paid usage, and
    `cached > input` records clamp instead of minting negative dollars.
  - **Pre-context usage.** Resumed rollouts emit usage before the file names its model; the first
    observed model retroactively owns it, so spend lands on a real id, not a placeholder bucket.
  - Threads Codex re-imported *from* Claude (its import manifest) are dropped at the source so
    the same conversation is never counted twice.
- **Grok source** — `$GROK_HOME/sessions/<session-id>/`, a directory-backed record split across
  three files: `summary.json` owns metadata (cwd, title, model, fork/subagent lineage),
  `chat_history.jsonl` owns visible prose, and `updates.jsonl` owns ACP per-turn/per-model usage.
  The accumulator keeps an independent incremental offset per file, and a
  `turn_completed.usage.costIsPartial` marker surfaces as a per-session billing-partial
  disclosure instead of being silently summed as final.
- **FSEvents** watches every provider root; changes debounce into incremental rescans (off-main,
  cancellable, prefilter-before-parse, append-only parse cache keyed by file + offset). The
  on-disk index cache is version-laddered — any summary-shaping change bumps the version and
  forces a loud one-time reparse instead of silently serving stale shapes.

### Attention state machine — honesty as architecture

BLOCKED / WAITING / RUNNING / IDLE derive from provider-native signals, produced where the
provider is parsed — the classifier itself is provider-free.

- Claude: a dangling `tool_use` older than a threshold is the open-human-gate signal.
- Codex: `task_complete` → WAITING, recent runtime records → RUNNING, staleness → IDLE — and a
  `canObserveBlocking` capability gates both BLOCKED paths, because Codex approval prompts are
  **never persisted**: disk cannot know, so trifola never claims. Encoded as a tested invariant.
- Grok: turn records in the `updates.jsonl` tail drive the same completed/recent/stale ladder;
  approval prompts are likewise never persisted, so the `canObserveBlocking` gate keeps Grok
  sessions honest too — BLOCKED is never claimed.

### The provider boundary

Analyses keep to the sessions they can honestly describe. Claude-scoped: the dead-skill
denominator (only Claude sessions carry the skill catalog in their prompts), settings-vs-resolved
routing legs, frontier right-sizing, and the external cost-bar reconciliation. Provider-neutral:
cache economics and burn (they price normalized usage by model id). Mixed corpora are proven by
fixture tests to leave Claude-only findings unmoved.

### Pricing

A per-model, date-era rate catalog (Sonnet 5's introductory era is encoded, not hardcoded),
bundled at build time and **verified against the official Anthropic, OpenAI, and xAI pricing
pages** — the seed states its verification date. Cache splits: 5-minute writes at 1.25×, 1-hour
at 2×, warm reads at 0.1× — except xAI, whose cached-input prices are model-specific, so Grok
rows carry the published cached rate verbatim. Ids without an official per-model rate price through a tier fallback and are
*marked* "est. rate" in the UI rather than implying a source exists. Cache **leak** (avoidable)
and unavoidable **first-touch** are tracked separately and never summed into one dishonest
number. An opt-in models.dev refresh can extend the catalog; it never overwrites a bundled row.

### Quota — a consent-gated trust boundary

Plan-quota reading is **off by default, per provider**. Claude quota reads the local credential
and may query Keychain, then makes one HTTPS request to the vendor's usage endpoint — nothing is
read before the Settings toggle is enabled, and the MCP `quota_windows` tool sits behind the same
gate for every provider. Codex quota is a pure local read of rate-limit events already persisted
in rollout files: no network, no spawned process, symlink- and traversal-rejecting. Grok
SuperGrok plan usage reads `~/.grok/auth.json` (OIDC/SuperGrok scope, legacy session fallback)
only after consent, then POSTs once to xAI's billing endpoint with the bearer token confined to
the request `Authorization` header; the HTTP transport is injectable so tests never hit the
network.

### Session transport — the "Open session" ladder

Opening a session lands on the exact terminal surface hosting it, through ordered tiers that
never guess:

1. **Registry join** — Claude Code's live session registry maps session id → live PID; a
   headless daemon background job follows its unique *named interactive sibling* (the surface a
   human actually sees it through). Zero or many candidates refuse.
2. **Exact tab via AppleScript** — Terminal.app and iTerm2 select the precise tab by TTY.
3. **Surface-exact via a bundled controller** — workspace-style terminal apps that ship their own
   signed control binary inside their bundle get tab-exact targeting: the session id recorded in
   a surface's resume binding joins to exactly one tab, its hosting window is fronted first
   (cross-Space), and the selection is verified by the host's own UUID reads. Capability-gated
   and fail-closed: same-team code-signature required, fixed argv, bounded IO, duplicate or
   malformed records refuse.
4. **Accessibility scoring** — with the user's explicit, at-the-moment-of-value Accessibility
   grant, window/tab titles are scored against session identity (cwd, project, id prefix) with a
   confidence floor and a required winner margin; a tie is an honest miss, never a guessed tab.
5. **Owner activation, then transcript** — fronting the owning app, else a read-only transcript
   reveal. Every failure path names its cause in the UI; every success confirms what it did.

### Navigation performance

Screen projections (sessions, fleet, deadlines, burn, lessons) are store-owned snapshots computed
off the main thread when their *inputs* change — never at click time. Navigation state lives in a
small dedicated observable, so selecting a destination invalidates the navigation shell, not the
heavyweight store graph. Destination switches paint within a frame and hydrate from ready
snapshots; a benchmark harness (`--benchmark-nav-live`) drives the real selection-to-draw path.

### Session lineage resolution

The Sessions browser treats spawn ownership as a presentation join, never an accounting rewrite.
`SessionLineage` receives the immutable session summaries plus lineage-only evidence captured beside
the index generation, then produces a cycle-safe, orphan-safe forest off the main actor. The input
session count, token totals, and costs are unchanged; metadata-only children carry zero usage and an
explicit transcript-availability explanation.

Edges are applied in evidence priority order:

1. Claude `Agent`/`Task` results joined to `subagents/agent-<id>.jsonl` (`subagent`).
2. Claude `remote-agents/remote-agent-*.meta.json` sidecars (`remoteTask`).
3. Codex `thread_spawn`, `parent_thread_id`, and `forked_from_id` metadata (`codexSpawn` / `codexFork`).
4. Grok `summary.json` fork/resume/subagent metadata, with parent-side `subagent_spawned`
   records filling gaps (`grokSpawn` / `grokFork`).
5. Codex `external_agent_session_imports.json` source/import pairs (`importBridge`).
6. Cross-provider, non-interactive runs sharing workspace and timing (`orchestrated`).

The first five are `deterministic`. The last is the only `heuristic` edge and is always labeled
“linked by workspace + timing”; Settings can hide heuristic links without affecting deterministic
lineage. A heuristic parent whose known start is later than the child is rejected; when that start is
unknown, the observed-activity window remains the timing authority. `bridgeSessionId`,
`origin.kind: "peer"`, and `senderTaskId` are deliberately not edges.

A Claude subagent attaches only when its existing parent transcript records the matching spawn; the
filename comparison removes exactly one leading `agent-` prefix. If the parent exists without that
record, the child stays top-level with a mismatch explanation. Missing-parent children likewise
remain top-level with a parent-missing note. Cycles lose the edge that would close the loop, so every
session remains visible. Only accepted parent links carry an edge kind, confidence, or edge detail;
roots carry explanation notes instead. Spawn depth is retained, while visual indentation caps at two
levels.

`NavigationSnapshotStore` resolves and projects the forest in detached work. The published Sessions
snapshot contains at most 400 `SessionLineageDisplayRow` values rather than a `[SessionSummary]`
corpus array. Lineage search returns matching descendants with their ancestor context and forced
expansion keys; Flat mode retains cross-file search/sort behavior over all transcript sessions.

### MCP server

A source-safe surface (`session_brief`, `context_tax`, `reroutes`, `cost_today`,
`quota_windows`) so a *running* session can introspect its own state. Identity is explicit: tools
resolve the session registered for the connection; without one, callers pass `session_id` or opt
in with `use_newest: true` — omission alone is an error, never a silent guess. It never mutates
`~/.claude`, `~/.codex`, or `~/.grok`; the shared scanner maintains an app-local session index.

## The durability battle: the upstream formats

All three providers' on-disk formats are unversioned, undocumented, and change. The engine treats
them as hostile inputs:

- **Lenient, field-level parsing** — one bad field degrades to zero; never drop a record, never
  crash a scan. Malformed or adversarial records (negative counters, impossible cache figures,
  oversized compressed files) clamp or fail closed with fixtures proving it.
- **Synthetic fixture matrices in CI** — the biggest fragility becomes a visible reliability
  signal.
- **Dedup as a correctness invariant** with tests — the whole trust story is the numbers being
  right, including on session resume, sidechains, and cross-provider re-imports.
- `CLAUDE_CONFIG_DIR` / `CODEX_HOME` / `GROK_HOME`, nested sessions, and `subagents/*.jsonl`
  layouts are handled so totals don't silently under-count.

## Performance is a feature

An observability app that pegs a CPU core is disqualifying here. The pipeline is event-driven
(FSEvents) with no polling render loop; scans are off-main and incremental. Warm launch reads
SQLite on one thread while accumulator payloads decode concurrently in bounded batches, then
publishes the unchanged cached index before reconciliation. Set `TRIFOLA_LAUNCH_METRICS=1` to emit
cache-hydration and scan-reconciliation entry counts and timings, plus the first Sessions snapshot's
row count, to standard error. Destination navigation is budgeted and benchmarked.

## Testing

The `TrifolaKit` test suite runs against **synthetic** fixtures with known expected findings —
which simultaneously serve as the personal-data strip, the CI-vs-version matrix, and the demo-mode
corpus for marketing assets. No real `~/.claude`, `~/.codex`, or `~/.grok` data ever enters the
repo; a personal-identifier lint gates every commit in CI.
