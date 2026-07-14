# Search benchmarks

Honest numbers, reproducible commands, stated caveats. All measurements on an Apple Silicon
Mac (arm64), macOS 15, against either the generated production-scale fixture (7,000 JSONL
files, 3 GiB) or a real 3.1GB / ~7,300-session corpus as labeled.

## App index (SQLite FTS5, WAL) — churn contract

Measured by the built-in harness on the generated 3 GiB fixture with a live appender writing
one searchable message every 2s for 60s:

| Metric | Measured | Contract |
|---|---:|---:|
| Whole-process CPU during churn (incl. query sampler) | 5.6% | <10% |
| Max bytes written by one append (db+WAL growth) | 61.8 KB | <1 MB |
| Warm query p95 **during** churn | 49.9 ms | <100 ms |
| First batch queryable (progressive first run) | 363 ms | — |
| Full first-run build (fixture) | 12.5 s | background |

Reproduce:

```bash
.build/release/Trifola --benchmark-search \
  --benchmark-search-root /tmp/bench --benchmark-search-count 7000 \
  --benchmark-search-bytes 3221225472 --benchmark-search-churn-seconds 60 \
  --benchmark-search-append-interval 2
```

Real-corpus note: the first-run build over a real 3.1GB corpus takes minutes, not seconds —
real transcripts carry megabyte-scale JSON lines that dominate extraction. It runs in the
background with visible progress, results are queryable from the first 200-document batch,
and it never happens again (per-file offsets make subsequent runs delta-only).

## CLI index (node:sqlite FTS5) — 7,000-file fixture

Subprocess-inclusive timings (i.e. includes Node startup), Node 22:

| Metric | Measured |
|---|---:|
| Cold first streamed result (scan streams while index builds) | 151 ms |
| Cold build complete | 1.05 s |
| Warm query p50 / p95 | 107 / 112 ms |
| Incremental run, 20 changed files (6.3 KB source read) | 129 ms |

Reproduce: `cd cli && npm run benchmark:search`

## Baseline: ripgrep over the raw corpus

`rg -c --no-ignore 'clean'` over the real 3.1GB corpus: **1.89 s** (35,563 raw line matches).

Caveats that make this apples-to-oranges in rg's favor AND against it: rg does no JSON
parsing, no tool-output exclusion, no ranking, no snippets, and matches raw transcript lines
(tool dumps included — most of those 35k matches are noise trifola deliberately excludes);
trifola's warm queries answer from the index in ~50 ms with ranked, scoped, deduplicated
sessions. rg re-pays its full cost every query; the index pays once and updates by delta.

## Reading the numbers

- The claim is not "faster than ripgrep at grepping" — it's *scoped conversation recall at
  interactive latency, kept fresh against a live-appending corpus for ~5% CPU*.
- Query latency targets are for warm queries; the first search during a first-run build
  streams partial results and says so on screen.
