# Changelog

All notable changes to trifola are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/); versions follow [SemVer](https://semver.org/).

## [Unreleased]

### Added
- **Attention board** — every session as BLOCKED / WAITING / RUNNING / IDLE, worst-first, in a menu-bar glance.
- **Cost-cause audit** — cache *leak* vs unavoidable first-touch (never summed into one number), the re-sent-context tax, Opus-on-lint model-mismatch, dead-skill ledger, per-session receipts.
- **Routing forensics** — silent model fallbacks and subagent model-inheritance leaks, with a copy-able `CLAUDE.md` fix.
- **Context tax** — the warm-vs-cold price of your next message, at the session's own rates.
- **Whole-fleet** — cross-machine consolidation over your own Tailscale.
- **Agent-facing MCP server** (read-only) — `session_brief`, `context_tax`, `reroutes`, `cost_today`, `quota_windows` for a running session to introspect itself.
- **Quota windows** — real plan windows, read-only.
- **Headless `--render-*` harness** — a synthetic-fixture screenshot factory (also the CI-vs-version and demo surface).
- **Secret-scan CI gate** — fails the build on any personal identifier or private path.

[Unreleased]: https://github.com/ss251/trifola
