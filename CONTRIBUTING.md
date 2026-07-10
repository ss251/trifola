# Contributing to trifola

The engine is Swift; **the moat is the rules.** The most valuable contribution isn't a
screen — it's a **detector**: a failure mode you hit, the threshold that catches it, and the
fix you'd paste into `CLAUDE.md`. Those are what make trifola smarter than a dashboard.

## Merge by default

Good-faith PRs get merged. **AI-assisted PRs are welcome** — describe what you verified, not
how you wrote it. Keep changes focused; one concern per PR.

## Adding a detector

A detector is a distilled finding turned into a deterministic lint rule over a stranger's own
`~/.claude`. Every one needs:

1. **Evidence** — a query over the documented session/usage contract (no model calls).
2. **Threshold** — the honest line at which it fires, named in the finding copy itself.
3. **Finding copy** — with a **denominator** (never a bare "99%"; always "N of M").
4. **Remedy** — a copy-able edit / archive list / recipe the human can apply.
5. **Citation + calibration date** — what produced the rule and when it was last true (pricing
   and models age; rules carry version ranges so they can expire visibly rather than lie).
6. **A fixture** — a synthetic JSONL corpus with the expected finding, added to `Tests/`.

## Ground rules

- **Never commit real `~/.claude` data.** Transcripts hold secrets, client names, and dollar
  figures. Fixtures are **synthetic only** — the secret-scan CI gate fails the build on any
  personal string or absolute home path. Marketing assets come from demo mode, not real data.
- **Manually review every screenshot before committing it.** `Scripts/secret-scan.sh` is a
  personal-PII/path lint, not a credential scanner and not an image scanner. Confirm that each
  image uses synthetic data and contains no credentials, private names, paths, hosts, or account data.
- **Correctness is the trust story.** Dedup on `(messageId, requestId)`; degrade a bad field to
  zero, never drop a record or crash a scan. Numbers that are wrong once are fatal in this
  category — label every estimate ("API-equivalent, not your bill").
- **No new external dependencies** without discussion. Zero-deps is a feature.
- **No CLA.** MIT in, MIT out.

## Building

```bash
swift build -c release
swift test
bash Scripts/make-app.sh
bash Scripts/secret-scan.sh   # must pass before any push
```
