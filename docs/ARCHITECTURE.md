# Architecture

trifola is a native macOS (SwiftUI, Swift 6) reader over `~/.claude`. Zero external
dependencies. The design splits cleanly into three layers.

```
┌──────────────────────────────────────────────────────────────┐
│  ENGINE (Swift, MIT) — commodity, correct, fast              │
│  version-tolerant JSONL parsers · incremental append-only    │
│  index · FSEvents pipeline · attention state machine ·       │
│  pricing math · render/UI · read-only MCP server             │
├──────────────────────────────────────────────────────────────┤
│  STABLE CONTRACT — the "workflow schema"                     │
│  SessionSummary · usageByTier · SkillLedger · probes:        │
│  a documented, versioned surface the detectors query         │
├──────────────────────────────────────────────────────────────┤
│  PLAYBOOK (data) — the judgment, shipped as content          │
│  detectors: evidence query + threshold + finding copy +      │
│  remedy + citation + calibration date + schema-version range │
│  (v1: in Swift · v1.1 roadmap: externalized, updatable data) │
└──────────────────────────────────────────────────────────────┘
```

## Engine

- **Ingestion.** One FSEvents stream over `~/.claude` → debounced incremental rescan of changed
  transcripts → stores. Off-main, cancellable scans; prefilter-before-parse; an append-only
  parse cache keyed by file + offset so a rescan touches only new bytes.
- **Attention state machine.** BLOCKED / WAITING / RUNNING / IDLE derived from a dangling
  `tool_use` older than a threshold — the signal that a human gate is open.
- **Pricing.** A date-stamped per-model rate table with cache splits (5-minute at 1.25×, 1-hour
  at 2×, warm reads at ~0.1×), embedded at build time. Cache **leak** (avoidable) and unavoidable
  **first-touch** are tracked separately and never summed into one dishonest number.
- **MCP server.** A read-only surface (`session_brief`, `context_tax`, `reroutes`, `cost_today`,
  `quota_windows`) so a *running* Claude Code session can introspect its own state. Local only.

## The durability battle: the upstream format

Claude Code's on-disk JSONL/settings format is unversioned, undocumented, and changes. The engine
treats it as a hostile input:

- **Lenient, field-level parsing** — one bad field degrades to zero; never drop a record, never
  crash a scan.
- **A "tested against Claude Code vX.Y" fixture matrix** in CI — the biggest fragility becomes a
  visible reliability signal.
- **`(messageId, requestId)` dedup as a correctness invariant** with tests — the whole trust story
  is the numbers being right, including on session resume and sidechains.
- `CLAUDE_CONFIG_DIR`, nested sessions, and `subagents/*.jsonl` layouts are handled so totals don't
  silently under-count.

## Performance is a feature

An observability app that pegs a CPU core is disqualifying here. Idle CPU is ~0% by design
(off-main scans, incremental cache, no polling render loop). This is a headline property, not an
optimization footnote.

## Testing

The `TrifolaKit` test suite runs against **synthetic** fixtures with known expected findings —
which simultaneously serve as the personal-data strip, the CI-vs-version matrix, and the demo-mode
corpus for marketing assets. No real `~/.claude` data ever enters the repo.
