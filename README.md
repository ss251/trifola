<div align="center">

# trifola

**The command center for your whole Claude Code fleet.**
Reads your local `~/.claude`, uploads nothing, and tells you what your agents
cost you, where the spend is being wasted, and which one is blocked waiting on
you — across every machine.

<!-- Badges: wire real URLs at launch -->
![License: MIT](https://img.shields.io/badge/License-MIT-blue)
![Platform: macOS 15+](https://img.shields.io/badge/macOS-15%2B-black)
![Swift 6](https://img.shields.io/badge/Swift-6-orange)
![Dependencies: none](https://img.shields.io/badge/dependencies-0-brightgreen)

<picture>
  <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/audit-dark.png">
  <img alt="trifola — attribute workflow spend to a cause: re-sent context vs first-touch, dead skills, model-mismatch" src="docs/screenshots/audit-light.png" width="920">
</picture>

_A truffle pig for your agent fleet: it sniffs out the valuable — and the
wasteful — hidden in data Claude Code already writes to disk. (Demo data — trifola
renders every screenshot from synthetic fixtures; your real `~/.claude` never leaves your machine.)_

</div>

---

## Why trifola

Claude Code made running 5–10 agents at once normal. Two failure modes came with it,
and nothing on your machine surfaces either:

- **You can't see where the money goes.** `/usage` shows a total. It won't tell you
  that a chunk of that total was **fresh input a warm cache would have served at a tenth
  the price**, that a run went to **Opus when Sonnet was configured**, or that your
  subagents **silently inherited the wrong model**. trifola attributes spend to a
  **cause**, not a number — and prices your *next* message warm-vs-cold before you send it.
- **You can't see who's stuck.** Agent #7 has been blocked on a `y/N` for forty minutes
  and you'd never know. trifola watches every live transcript and flags **BLOCKED /
  needs-approval / silently-stalled** the moment it happens — in the menu bar, all day,
  and across every machine you run on.

It reads only what Claude Code already writes to `~/.claude`. **No account, no telemetry,
no network. Source-auditable.** The observability app that costs nothing to run —
literally: idle CPU is ~0%.

## What it does

- 🟢 **Attention board** — every session as BLOCKED / WAITING / RUNNING / IDLE, worst-first,
  in a menu-bar glance.
- 🧾 **Cost-cause audit** — **re-sent context** vs unavoidable first-touch (never summed into one
  dishonest number), the "$20 hey" wasted-resend tax, Opus-on-lint, per-session receipts.
- 🧭 **Routing forensics** — silent model fallbacks and subagents that inherited the wrong model, with the
  exact fix you can paste into `CLAUDE.md`.
- 🧹 **Config hygiene** — which of your skills never fire, priced as the per-session tax they
  levy on every run.
- 📉 **Context tax** — what your next message costs warm vs cold, at your session's own rates.
- 🌐 **Whole fleet** — consolidate every machine you run on (over your own Tailscale), not one.
- 🔌 **Agent-facing MCP** — a read-only server so a *running* session can ask trifola about its
  own cost, routing, and quota mid-flight. Your agent can audit itself.
- 📅 **Quota windows** — your real plan windows, read-only.

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/attention-dark.png">
    <img alt="Attention strip — which sessions are blocked or waiting on you" src="docs/screenshots/attention-light.png" width="820">
  </picture>
  <br><em>The attention strip — the door light. BLOCKED / WAITING on you at a glance; a calm all-clear when nothing needs you.</em>
</p>

<p align="center">
  <picture>
    <source media="(prefers-color-scheme: dark)" srcset="docs/screenshots/fleet-dark.png">
    <img alt="Fleet board — every agent and subagent across bays" src="docs/screenshots/fleet-light.png" width="920">
  </picture>
  <br><em>The Fleet Board — every agent and subagent across bays, stable seats, live presence, spend per bay.</em>
</p>

## Install

> Pre-launch. Today: build from source (below). At launch: a signed, notarized DMG and
> `brew install --cask trifola`.

```bash
git clone https://github.com/ss251/trifola.git
cd trifola
swift build -c release
bash Scripts/make-app.sh      # → dist/trifola.app
open dist/trifola.app
```

Requires macOS 15+ and a Swift 6 toolchain. Zero external dependencies.

## Your agent can audit itself (MCP)

trifola ships a **read-only** MCP server. Point a Claude Code session at it and the session
can introspect its own state — `session_brief`, `context_tax`, `reroutes`, `cost_today`,
`quota_windows`. Ask *"what will my next message cost warm vs cold?"* or *"am I about to
violate my routing policy?"* — mid-run, before it costs you. Nobody else in this category has
this shape.

## trifola vs. the neighbors (honestly)

trifola doesn't replace the cost bars or the native agent view — it does the layer they don't.

| | **trifola** | Claude Code **Agent View** | **ccusage / CodexBar** |
|---|:---:|:---:|:---:|
| "Which agent needs me now" | ✅ menu-bar + **cross-machine** | ✅ native, in-CLI, **single machine** | ❌ |
| Cost **cause** (re-sent vs first-touch, misroute) | ✅ | ❌ no cost in-view | 〜 totals only |
| Dead-skill / config hygiene | ✅ | ❌ | ❌ |
| Cross-machine fleet | ✅ (Tailscale) | ❌ single machine | ❌ |
| Agent-facing MCP (self-introspection) | ✅ | ❌ local `--json` | ❌ |
| Local-first, uploads nothing | ✅ | ✅ | ✅ |

**Agent View** (native, free, in your CLI) does the live single-machine attention board well —
if that's all you need, use it. **ccusage** and **CodexBar** are excellent ambient cost bars.
trifola is the **audit + judgment layer over your whole fleet**: the *cause* of the spend, the
routing and skill hygiene, and every machine at once.

## Privacy

Everything stays on your machine. trifola reads `~/.claude` locally and renders. It opens no
network connection of its own, has no account, and ships no telemetry. The source is here —
audit it.

## Contributing

Rules, detectors, and fixes are the point — see [CONTRIBUTING.md](CONTRIBUTING.md).
**AI-assisted PRs are welcome.** Bring a failure mode, a threshold, and a fix template.

## Related projects

- [ccusage](https://github.com/ryoppippi/ccusage) — cross-platform token/cost totals from local data.
- [CodexBar](https://github.com/steipete/CodexBar) — every AI coding limit, in your menu bar.
- Claude Code **Agent View** — the native in-CLI live agent board.

## License

[MIT](LICENSE).
