# Changelog

All notable changes to trifola are documented here. The format follows
[Keep a Changelog](https://keepachangelog.com/); versions follow [SemVer](https://semver.org/).

## [Unreleased]

## [0.1.0] - 2026-07-10

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

[Unreleased]: https://github.com/ss251/trifola/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/ss251/trifola/releases/tag/v0.1.0
