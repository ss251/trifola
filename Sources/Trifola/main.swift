import Foundation
import TrifolaKit
import Security

// `--render-layout <base>` permanently rasterizes the production rail and shared
// Overview composition at 1440×900 and 1680×900, dark + light.
if let i = CommandLine.arguments.firstIndex(of: "--render-layout") {
    let base = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : "/tmp/layout"
    MainActor.assumeIsolated { LayoutRender.run(base: base) }
    exit(0)
}

// `--render-attention <png>` rasterizes the Attention Strip headlessly (no window,
// Space, or Screen-Recording permission needed) so the component can be seen and
// judged — including a BLOCKED case that's rare on live data.
if let i = CommandLine.arguments.firstIndex(of: "--render-attention") {
    let base = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : "/tmp/attention"
    MainActor.assumeIsolated {
        AttentionRender.run(to: base + "-dark.png", dark: true)
        AttentionRender.run(to: base + "-light.png", dark: false)
    }
    exit(0)
}

// `--render-fleet <base>` rasterizes the REAL Fleet Board ("the Floor") with
// seeded bays/tokens/states — a swarm bay with nested subagents + collision chip,
// a BLOCKED-STILL seat, a RUNNING one, an idle ember bay — so the spatial
// layout can be Read + judged against the spec's litmus tests
// (does a frozen frame still read? does BLOCKED read as stillness?) without a
// window/Space. The heartbeat is motion (verified by test + selfcheck, not here).
if let i = CommandLine.arguments.firstIndex(of: "--render-fleet") {
    let base = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : "/tmp/fleet"
    MainActor.assumeIsolated {
        FleetRender.run(to: base + "-dark.png", dark: true)
        FleetRender.run(to: base + "-light.png", dark: false)
    }
    exit(0)
}

// `--render-audit <base>` rasterizes the REAL Audit views with a seeded report
// (populated tables, not an empty state) so the AUDIT screen can be seen + judged
// without a window/Space/Screen-Recording permission.
if let i = CommandLine.arguments.firstIndex(of: "--render-audit") {
    let base = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : "/tmp/audit"
    MainActor.assumeIsolated {
        AuditRender.run(to: base + "-dark.png", dark: true)
        AuditRender.run(to: base + "-light.png", dark: false)
    }
    exit(0)
}

// `--render-ledger <base>` rasterizes the REAL Dreaming Ledger (LedgerContent +
// LessonCard) with seeded lessons — L-001 (model-pin, its copy-able CLAUDE.md
// doctrine hunk + an APPLIED verification annotation), L-002…L-005 (incl the
// xhigh effort furnace) — so the flywheel (finding → copy-able candidate fix) is
// the visual truth, judgeable without a window/Space. snapshot.sh is Space-broken.
if let i = CommandLine.arguments.firstIndex(of: "--render-ledger") {
    let base = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : "/tmp/ledger"
    MainActor.assumeIsolated {
        LedgerRender.run(to: base + "-dark.png", dark: true)
        LedgerRender.run(to: base + "-light.png", dark: false)
    }
    exit(0)
}

// `--render-launch <base>` rasterizes the REAL Session Builder components
// (CommandPreview + RecipeCardView + the form projection) with a seeded recipe —
// the composed `claude …` command incl. the opus model pin is visible + judgeable
// without a window/Space.
if let i = CommandLine.arguments.firstIndex(of: "--render-launch") {
    let base = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : "/tmp/launch"
    MainActor.assumeIsolated {
        LaunchRender.run(to: base + "-dark.png", dark: true)
        LaunchRender.run(to: base + "-light.png", dark: false)
    }
    exit(0)
}

// `--render-skills <base>` rasterizes the REAL skill-hierarchy components (lane
// stats · trigger collisions · lane→namespace→node tree + detail) with a seeded
// multi-lane skill set + ledger so the structure can be seen + judged headlessly.
if let i = CommandLine.arguments.firstIndex(of: "--render-skills") {
    let base = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : "/tmp/skills"
    MainActor.assumeIsolated {
        SkillsRender.run(to: base + "-dark.png", dark: true)
        SkillsRender.run(to: base + "-light.png", dark: false)
    }
    exit(0)
}

// `--render-crossmachine <base>` rasterizes THE DIFFERENTIATOR — one pane over this
// Mac + workstation: fleet-wide totals + per-machine roll-up, the calm offline
// indicator, machine-chipped session rows, and the Fleet Board with machine-tagged
// bays (the same repo on both machines reads as two bays). snapshot.sh is
// Space-broken; this is the verification path (Read the PNGs, judge them).
if let i = CommandLine.arguments.firstIndex(of: "--render-crossmachine") {
    let base = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : "/tmp/crossmachine"
    MainActor.assumeIsolated {
        CrossMachineRender.run(to: base + "-dark.png", dark: true)
        CrossMachineRender.run(to: base + "-light.png", dark: false)
    }
    exit(0)
}

// `--render-palette <base>` rasterizes THE FRONT DOOR (VISION 3.4) — the ⌘K
// command palette over a seeded multi-kind index, ranked by the real fuzzy matcher
// on a seeded query ("cr") that hits a few sessions + a skill + a screen + a
// recipe. Read the PNGs and judge: door-light dots, mono ids, one accent on the
// selected row, legibility in both themes. snapshot.sh is Space-broken.
if let i = CommandLine.arguments.firstIndex(of: "--render-palette") {
    let base = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : "/tmp/palette"
    MainActor.assumeIsolated {
        PaletteRender.run(to: base + "-dark.png", dark: true)
        PaletteRender.run(to: base + "-light.png", dark: false)
    }
    exit(0)
}

// `--render-identity <base>` rasterizes THE SIGNATURE — the door light: the
// sidebar lockup (mark + wordmark, ring tinted by the fleet's worst live state) at
// every state, the menu-bar template glyph's three honest states, and the dock
// tile — so the app's identity can be Read + judged without a window/Space.
if let i = CommandLine.arguments.firstIndex(of: "--render-identity") {
    let base = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : "/tmp/identity"
    MainActor.assumeIsolated {
        IdentityRender.run(to: base + "-dark.png", dark: true)
        IdentityRender.run(to: base + "-light.png", dark: false)
    }
    exit(0)
}

// `--render-burn <base>` rasterizes THE CREDIT-ERA BURN GOVERNOR (VISION 2.5) — the
// Jul-7 countdown's successor: today's API-equiv burn + Opus share + the recent-
// run-rate month projection, over a per-day, tier-colored sparkline (the evidence
// grammar). Seeded with ~30 days of dated sessions so the trend + projection read.
// Read the PNGs and judge: restrained, honest "API-equiv, not your bill" label, no
// nag/red-panic, tier hues consistent with the spend-split bar. snapshot.sh is
// Space-broken; this is the verification path.
if let i = CommandLine.arguments.firstIndex(of: "--render-burn") {
    let base = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : "/tmp/burn"
    MainActor.assumeIsolated {
        BurnRender.run(to: base + "-dark.png", dark: true)
        BurnRender.run(to: base + "-light.png", dark: false)
    }
    exit(0)
}

// `--render-config <base>` rasterizes THE CONFIG-SURFACE HEALTH cards (VISION 2.4)
// — MCP servers, hooks, plugins — over fixture config JSON through the same pure
// parsers the live Stack grid uses: a healthy read + a config-rot read (missing MCP
// binary, missing hook script, stale plugin). snapshot.sh is Space-broken; this is
// the verification path (Read the PNGs, judge them in both themes).
if let i = CommandLine.arguments.firstIndex(of: "--render-config") {
    let base = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : "/tmp/config"
    MainActor.assumeIsolated {
        ConfigRender.run(to: base + "-dark.png", dark: true)
        ConfigRender.run(to: base + "-light.png", dark: false)
    }
    exit(0)
}

// `--render-deadlines <base>` rasterizes THE DEADLINE BOARD (docs/DEADLINE_BOARD.md)
// — the real DeadlineContent with seeded STALLED / OVERDUE / AT-RISK / ON-TRACK /
// SHIPPED cards (jeopardy-sorted, worst-first) + the connect-Linear affordance in BOTH
// states (not-connected "Connect Linear" / connected "team X · Sync"). snapshot.sh is
// Space-broken; this is the verification path (Read the PNGs, judge them in both
// themes: does the jeopardy sort read, is STALLED the alarm, is the connect state calm?).
if let i = CommandLine.arguments.firstIndex(of: "--render-deadlines") {
    let base = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : "/tmp/deadlines"
    MainActor.assumeIsolated {
        DeadlineRender.run(to: base + "-dark.png", dark: true)
        DeadlineRender.run(to: base + "-light.png", dark: false)
    }
    exit(0)
}

// `--render-provenance <base>` rasterizes THE TRUST CAPSTONE (W3) — the Burn tile
// with its receipt EXPANDED: per-model legs (deduped token split incl. 5m/1h
// cache writes × the exact dated rate, Sonnet-5's effective-date rule visible),
// Σ = the tile's number via the same code path, pricing/dedup/bucketing footers,
// and the month-projection formula. Read the PNGs and judge: mono receipt,
// arithmetic legible, no layout breakage. snapshot.sh is Space-broken; this is
// the verification path.
if let i = CommandLine.arguments.firstIndex(of: "--render-provenance") {
    let base = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : "/tmp/provenance"
    MainActor.assumeIsolated {
        ProvenanceRender.run(to: base + "-dark.png", dark: true)
        ProvenanceRender.run(to: base + "-light.png", dark: false)
    }
    exit(0)
}

// `--render-contexttax <base>` rasterizes THE CONTEXT-TAX GAUGE + fresh-session
// advisor (spree #1 — the "$20 hey" killer): the inspector-density gauge for a
// warm heavy session (advisor ON), the 847k cache-cold field case, a light
// session (no advisor), an IDLE over-threshold session (advisor honestly
// suppressed — it only speaks about live sessions), and the Live-tile compact
// strip. Read the PNGs and judge: mono token counts + model ids, tabular
// prices, the threshold visible in the advisor copy, no nag-red anywhere.
if let i = CommandLine.arguments.firstIndex(of: "--render-contexttax") {
    let base = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : "/tmp/contexttax"
    MainActor.assumeIsolated {
        ContextTaxRender.run(to: base + "-dark.png", dark: true)
        ContextTaxRender.run(to: base + "-light.png", dark: false)
    }
    exit(0)
}

// `--render-reroutes <base>` rasterizes REROUTE RECEIPTS + the orchestrator-hog
// alert (spree #2): a session receipt with silent flips (upshift + fallback)
// and an excluded /model switch, the clean-session case (renders NOTHING —
// asserted by an empty state), the 14-day trend row, and the hog alert at a
// firing share. Read the PNGs and judge: mono model pairs + message refs, the
// semantics sentence present, threshold visible in the hog copy, zero nag-red.
if let i = CommandLine.arguments.firstIndex(of: "--render-reroutes") {
    let base = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : "/tmp/reroutes"
    MainActor.assumeIsolated {
        RerouteRender.run(to: base + "-dark.png", dark: true)
        RerouteRender.run(to: base + "-light.png", dark: false)
    }
    exit(0)
}

// `--render-quota <base>` rasterizes PLAN QUOTA (W7, plan 04) — the REAL
// rate-limit windows (5h / weekly / model-scoped) over a fixture snapshot that
// mirrors today's ~09:55 IST 'resets 10am' anchor: the 5h window at 91% with a
// ~35-min reset runway, plus the calm no-credentials degradation. Read the PNGs
// and judge: red only ≥90, mono %, reset runway legible, degraded state is one
// quiet line — advisor, not nag.
if let i = CommandLine.arguments.firstIndex(of: "--render-quota") {
    let base = i + 1 < CommandLine.arguments.count ? CommandLine.arguments[i + 1] : "/tmp/quota"
    MainActor.assumeIsolated {
        QuotaRender.run(to: base + "-dark.png", dark: true)
        QuotaRender.run(to: base + "-light.png", dark: false)
    }
    exit(0)
}

// `--spend-by-model <day> [<day>…]` prints the fleet's per-MODEL spend for the
// given LOCAL days ("yyyy-MM-dd"; defaults to yesterday + today) — token pile and
// catalog-priced dollars per model id. The reconcile surface against CodexBar's
// per-model-day computed cache, and the honest way to see what a day's model mix
// cost. Also prints what the flat pre-W2 tier pricing would have said, so a
// pricing-rule change is explainable line by line.
if let i = CommandLine.arguments.firstIndex(of: "--spend-by-model") {
    let home = FileManager.default.homeDirectoryForCurrentUser
    var days = CommandLine.arguments.dropFirst(i + 1).filter { $0.count == 10 && $0.contains("-") }
    if days.isEmpty {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd"
        days = [f.string(from: Date(timeIntervalSinceNow: -86400)), f.string(from: Date())]
    }
    let sessions = SessionStore.cachedScan(home.appendingPathComponent(".claude/projects"))
    let catalog = PricingCatalog.current
    print("pricing: \(catalog.sourceLabel)")
    for day in days {
        // Sum every session's (model, day) slice for this day.
        var byModel: [String: SessionUsage] = [:]
        for s in sessions {
            for (model, u) in s.usageByModelDay[day] ?? [:] {
                byModel[model] = (byModel[model] ?? SessionUsage()) + u
            }
        }
        print("--- \(day) ---")
        var total = 0.0, legacyTotal = 0.0
        for (model, u) in byModel.sorted(by: { $0.key < $1.key }) where u.total > 0 {
            let rate = catalog.resolvedRate(model: model, onDay: day)
            let cost = u.cost(rate: rate)
            // What the flat per-TIER rule (pre-W2: all cache writes 1.25×, tier
            // rates) would have billed — the explainable delta.
            let legacy = SessionUsage(inputTokens: u.inputTokens, outputTokens: u.outputTokens,
                                      cacheCreateTokens: u.cacheCreateTokens,
                                      cacheReadTokens: u.cacheReadTokens).cost(ModelTier(raw: model))
            total += cost; legacyTotal += legacy
            let name = model.isEmpty ? "(unknown)" : model
            print(String(format: "  %-28s in=%11d cr=%13d cc=%11d cc1h=%11d out=%9d  $%8.2f  (flat-tier $%8.2f)",
                         (name as NSString).utf8String!, u.inputTokens, u.cacheReadTokens,
                         u.cacheCreateTokens, u.cacheCreate1hTokens, u.outputTokens, cost, legacy))
        }
        print(String(format: "  TOTAL $%.2f  (flat-tier $%.2f)", total, legacyTotal))
    }
    exit(0)
}

// Headless modes must NEVER hang on a keychain ACL prompt: every rebuild
// changes this binary's code hash, the legacy file keychain then wants a GUI
// "Allow" click before releasing items (SecItemCopyMatching parks inside
// securityd's mach_msg forever), and an MCP server spawned by Claude Code —
// or a selfcheck piped through CI — has no GUI to click. Flip the global
// interaction switch off so those reads fail fast with
// errSecInteractionNotAllowed; every caller already treats a failed read as
// "not configured" and degrades gracefully. GUI launches keep their prompts.
// Every headless entry point — `--mcp`, `--selfcheck`, and the `--render-*` snapshot
// commands — has no GUI to click, so a parked ACL prompt froze the process (renders
// blocked on the "enter your login keychain password" dialog). Suppress interaction
// for ALL of them so keychain reads fail fast → "not configured". GUI launches (no
// headless flag) keep their prompts.
let headlessFlags = CommandLine.arguments.contains { arg in
    arg == "--mcp" || arg == "--selfcheck" || arg.hasPrefix("--render")
}
if headlessFlags {
    SecKeychainSetUserInteractionAllowed(false)
}

// `--mcp` runs the SELF-INTROSPECTION MCP ENDPOINT (spree #4 — rauchg,
// RESEARCH_top_voices #20): a stdio JSON-RPC 2.0 MCP server (protocol
// 2025-06-18) exposing the app's already-built forensics — session_brief /
// context_tax / reroutes / cost_today / quota_windows — so a LIVE Claude Code
// session can self-diagnose mid-run. Line-delimited JSON-RPC on stdin, strict
// single-line replies on stdout (NOTHING else ever prints to stdout in this
// mode — the transport would corrupt). Read-only; registration is the
// coordinator's job, never this binary's.
if CommandLine.arguments.contains("--mcp") {
    let server = MCPIntrospectionServer.live()
    FileHandle.standardError.write(Data("trifola --mcp: stdio MCP server up (protocol \(MCPIntrospectionServer.latestProtocolVersion), \(MCPIntrospectionServer.toolDescriptors().count) tools)\n".utf8))
    while let line = readLine(strippingNewline: true) {
        if let reply = server.handleLine(line) {
            print(reply)
            fflush(stdout)
        }
    }
    exit(0)
}

// Entry point. `--selfcheck` runs the real data layer headlessly (no GUI) so the
// parsing/aggregation can be verified in environments without Screen Recording perms.
if CommandLine.arguments.contains("--selfcheck") {
    let home = FileManager.default.homeDirectoryForCurrentUser
    let t0 = Date()
    // cachedScan shares the GUI's on-disk index: verifies the exact warm-start
    // path the app uses, and primes it so the next launch paints instantly.
    let sessions = SessionStore.cachedScan(home.appendingPathComponent(".claude/projects"))
        .sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) }
    let scanSecs = Date().timeIntervalSince(t0)

    let active = sessions.filter { $0.isActive }
    let totalTokens = sessions.reduce(0) { $0 + $1.usage.total }

    let totalCost = sessions.reduce(0.0) { $0 + $1.cost }
    // spend by tier — per-message attribution (SessionStore.aggregateTiers),
    // NOT a naive per-session `s.tier`/`s.cost` sum: a mixed-model session must
    // not dump its whole pile onto whichever tier happened to dominate it.
    let tierStats = SessionStore.aggregateTiers(sessions)
    let heavy = sessions.filter { $0.isContextHeavy }.sorted { $0.contextWeight > $1.contextWeight }

    print("=== trifola — self-check ===")
    print("sessions parsed:      \(sessions.count)  (scan \(String(format: "%.2f", scanSecs))s)")
    print("active (<15m):        \(active.count)")
    print("total tokens:         \(fmtTokens(totalTokens))")
    print("est. total spend:     \(fmtUSD(totalCost))")
    // Blended $/Mtok across all tiers over the DEDUPED token pile — a sanity gauge
    // that the per-message dedup landed (a per-line-summed corpus reads absurdly
    // high here). API-equiv at the flat tier rates, not a models.dev catalog price.
    let blended = totalTokens > 0 ? totalCost / (Double(totalTokens) / 1_000_000) : 0
    print("blended $/Mtok:       \(String(format: "$%.2f", blended))/M  (all tiers, API-equiv)")
    // Per-MODEL pricing catalog (W2): every $ figure above/below prices each
    // message at its exact model id + date (Sonnet 5 changes 2026-09-01) with
    // the 5m/1h cache-write split; unknown ids fall back to tier rates.
    print("pricing:              \(PricingCatalog.current.sourceLabel) · \(PricingCatalog.current.models.count) models")
    // Credit-era burn governor (VISION 2.5) — the Jul-7 countdown's successor.
    // Bucket API-equiv cost by day over the last 30d and project a monthly pace
    // from the recent run-rate. API-EQUIV, not the real credit bill.
    let burn = BurnGovernor(sessions: sessions)
    print("--- daily burn (API-rate equivalent — not your bill) ---")
    print("  today:                \(fmtUSD(burn.today.cost)) API-equiv · \(fmtPct(burn.today.opusShare)) Opus · \(burn.today.sessions) session(s)")
    print("  at this pace:         ≈\(fmtUSD(burn.monthProjection))/mo  (from the last \(burn.runRateDays)d run-rate · \(fmtUSD(burn.dailyRunRate))/day avg)")
    print("  30d window:           \(fmtUSD(burn.windowCost)) API-equiv across \(burn.days.count) days")
    let recent = burn.days.suffix(14)
    let spark = recent.map { d -> String in
        let peak = max(burn.days.map(\.cost).max() ?? 0, 0.0001)
        let blocks = ["·", "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█"]
        return blocks[min(blocks.count - 1, Int((d.cost / peak) * Double(blocks.count - 1)))]
    }.joined()
    print("  last 14d:             \(spark)  ($/day, normalized to window peak)")
    print("--- spend by model tier ---")
    for st in tierStats where st.cost > 0 {
        let share = totalCost > 0 ? Int(st.cost / totalCost * 100) : 0
        print("  \(st.tier.label.padding(toLength: 9, withPad: " ", startingAt: 0)) \(fmtUSD(st.cost).padding(toLength: 8, withPad: " ", startingAt: 0)) \(share)%")
    }
    // --- PROVENANCE (W3): the whole-corpus receipt, printed verbatim ---
    // Built from the SAME slices + rates as `est. total spend` above, so Σ legs
    // must equal it to the cent — asserted here, live, on the real corpus.
    let corpusReceipt = CostProvenance.corpusReceipt(sessions: sessions)
    print("=== PROVENANCE — show the math (W3) ===")
    let receiptMatches = abs(corpusReceipt.total - totalCost) < 0.005
    print("  Σ legs vs displayed total: \(String(format: "$%.2f", corpusReceipt.total)) vs \(String(format: "$%.2f", totalCost)) — \(receiptMatches ? "MATCH (same code path)" : "MISMATCH — receipt bug")")
    for line in corpusReceipt.plainText.split(separator: "\n", omittingEmptySubsequences: false) {
        print("  \(line)")
    }

    // --- RECONCILE vs CodexBar (W3): the last 2 CLOSED days, read-only ---
    // CodexBar computes the same per-model-day spend independently; its cache
    // (~/Library/Caches/CodexBar/cost-usage/claude-v4.json) is read strictly
    // read-only. Green = |Δ| ≤ max($0.01, 0.5%); a visible Δ names its likely
    // cause calmly. Absent cache → the app works normally, this block says so.
    print("=== RECONCILE vs CodexBar (read-only) ===")
    switch CodexBarReconcile.load() {
    case .missing:
        print("  CodexBar cache not found (~/Library/Caches/CodexBar/cost-usage/claude-v4.json) — is CodexBar installed? The app works normally without it.")
    case .unreadable(let why):
        print("  CodexBar cache present but unreadable (\(why)) — reconcile skipped; the app's own numbers are unaffected.")
    case .loaded(let cbCache):
        let scanNote = cbCache.lastScan.map { "last scan \(fmtAgo($0))" } ?? "last scan unknown"
        print("  cache: version \(cbCache.version) · \(cbCache.days.count) days (\(cbCache.scanSinceKey ?? "?")…\(cbCache.scanUntilKey ?? "?")) · \(scanNote)")
        let closedDays = CodexBarReconcile.lastClosedDays(2)
        for row in CodexBarReconcile.compare(sessions: sessions, cache: cbCache, days: closedDays) {
            let verdict = row.matches ? "✓ within max($0.01, 0.5%)" : "Δ exceeds tolerance"
            print(String(format: "  %@  ours $%.2f · CodexBar $%.2f · Δ $%+.2f  %@",
                         row.day, row.ours, row.theirs, row.delta, verdict))
            if let cause = row.likelyCause(lastScan: cbCache.lastScan) {
                print("      likely cause: \(cause)")
            }
        }
    }

    print("--- context-heavy sessions (>200k resent/msg): \(heavy.count) ---")
    for s in heavy.prefix(4) {
        // Same honest math as the GUI: warm-cache estimate weighted by the
        // session's observed hit rate, with the cold-cache worst case alongside.
        print("  \(s.project.padding(toLength: 22, withPad: " ", startingAt: 0)) \(fmtTokens(s.contextWeight)) ctx  ≈\(fmtUSD(s.costPerMessage))/msg @ \(fmtPct(s.usage.cacheHitRate)) cached (cold: \(fmtUSD(s.costPerMessageColdCache)))")
    }

    // --- CONTEXT-TAX GAUGE + fresh-session advisor (spree #1 — the "$20 hey" killer) ---
    // The LIVE pool priced per next message, warm (cache-read rate) vs cold
    // (fresh-input rate) at each session's own model rates, plus the advisor
    // verdicts at the visible 200k threshold. Consistency with the receipt
    // machinery (costPerMessage / costPerMessageColdCache) asserted live below.
    func tpad(_ s: String, _ n: Int) -> String { s.padding(toLength: n, withPad: " ", startingAt: 0) }
    let taxNow = Date()
    let tax = ContextTax.build(sessions: sessions, now: taxNow)
    print("=== CONTEXT-TAX GAUGE — the \"$20 hey\" killer (spree #1) ===")
    print("  live mains gauged:    \(tax.live.count)  (active <\(Int(ContextTax.liveWindow / 60))m, context > 0; subagents excluded — nobody types a \"$20 hey\" into one)")
    print("  next round of msgs:   ≈\(fmtUSD(tax.liveWarmTotal)) warm / \(fmtUSD(tax.liveColdTotal)) cold across the live pool (cold = every cache expired >5m idle)")
    print("  advisories:           \(tax.advisories.count) live session(s) over \(fmtTokens(ContextTax.advisoryTokens)) resent/msg — fresh-session advised (visible threshold, evidence not a nag)")
    for g in tax.live.prefix(6) {
        let model = g.modelID.isEmpty ? g.tier.label : g.modelID
        print("  \(tpad(g.project, 26)) \(tpad(fmtTokens(g.contextWeight) + " ctx", 11)) \(tpad(fmtUSD(g.warmPerMessage) + " warm", 12)) \(tpad(fmtUSD(g.coldPerMessage) + " cold", 12)) \(tpad(fmtPct(g.cacheHitRate) + " cached", 11)) \(tpad(model, 18)) \(g.advisory ? "fresh-session advised" : "ok")")
    }
    if let h = tax.heaviest, let line = h.advisorLine {
        print("  heaviest live:        \(h.project) — \(line)")
    }
    // Gauge ↔ receipt consistency, on the real corpus: the gauge's cold price
    // must equal costPerMessageColdCache and its blend must equal costPerMessage
    // for every gauged session (same resolvedRate path, no drift allowed).
    let taxConsistent = sessions
        .filter { !$0.isSubagent && $0.contextWeight > 0 }
        .allSatisfy { s in
            let g = ContextTax.gauge(s, now: taxNow)
            return abs(g.coldPerMessage - s.costPerMessageColdCache) < 1e-9
                && abs(g.blendedPerMessage - s.costPerMessage) < 1e-9
        }
    print("  consistency:          gauge cold == costPerMessageColdCache · blend == costPerMessage — \(taxConsistent ? "MATCH (same rate path)" : "MISMATCH — gauge bug")")

    // --- CONTEXT COMPOSITION (plan 12) — where the resent tokens come from ---
    // Attributes the heaviest live session's contextWeight to CLAUDE.md
    // footprint (global ~/.claude/CLAUDE.md + its own project CLAUDE.md, on-disk
    // byte size ≈bytes/4) and connected-MCP tool-schema footprint (server count
    // off ~/.claude.json × a documented static per-server estimate); the
    // remainder is history. Every number is a labeled "≈" estimate — see
    // ContextFootprint's doc comments for the exact methodology, never shown
    // as a measured token count.
    if let h = tax.heaviest {
        var claudePaths = [ContextFootprint.defaultClaudeMdPath]
        if !h.cwd.isEmpty { claudePaths.append(h.cwd + "/CLAUDE.md") }
        let comp = ContextFootprint.composition(contextWeight: h.contextWeight,
                                                 claudeMdPaths: claudePaths)
        print("  composition (heaviest \(h.project)): \(comp.line)")
        print("                          shares: \(fmtPct(comp.claudeMdShare)) CLAUDE.md · \(fmtPct(comp.mcpShare)) MCP · historyTokens \(comp.historyTokens >= 0 ? "clamped OK" : "NEGATIVE — bug")")
    } else {
        print("  composition:          no live session with context to attribute")
    }

    // --- REROUTE RECEIPTS + orchestrator-hog alert (spree #2, run on real data) ---
    // Prove the flip detector + the hog attribution on the live corpus, and
    // assert the hog's arithmetic against the INDEPENDENT day-receipt path
    // (CostProvenance.dayReceipt sums slice legs; the hog sums cost(onDay:) —
    // two computations, one number, or one of them is lying).
    let rr = Reroutes.build(sessions: sessions)
    print("=== REROUTE RECEIPTS — fallback/reroute forensics (spree #2) ===")
    print("  sessions censused:    \(rr.sessionsCensused) of \(sessions.count) carry a turn census (pre-v13 cache entries stay honestly quiet)")
    print("  silent reroutes:      \(rr.totalSilent) across \(rr.receipts.count) session(s)\(rr.undatedSilent > 0 ? "  (+\(rr.undatedSilent) undated — not smeared onto a day)" : "")")
    print("  /model switches:      \(rr.totalUserSwitches) deliberate — listed on receipts, never counted (\(RerouteReport.semantics))")
    for p in rr.pairs.prefix(5) {
        print("  \(tpad(p.pair, 44)) ×\(p.count)")
    }
    if let last = rr.days.last {
        print("  latest reroute day:   \(last.day) — \(last.count) flip(s)")
    }
    let hogDay = CostProvenance.dayKey(for: Date())
    let hog = OrchestratorHog.alert(sessions: sessions, day: hogDay)
    let hogDayTotal = sessions.reduce(0.0) { $0 + $1.cost(onDay: hogDay) }
    let receiptTotal = CostProvenance.dayReceipt(sessions: sessions, dayKey: hogDay).total
    let hogConsistent = abs(hogDayTotal - receiptTotal) < 0.005
    print("  hog alert today:      \(hog.map { "FIRING — \($0.line)" } ?? "quiet (top session ≤\(fmtPct(OrchestratorHog.shareThreshold)) of \(fmtUSD(hogDayTotal)), or day <\(fmtUSD(OrchestratorHog.minimumDayTotal)))")")
    print("  consistency:          hog day total \(fmtUSD(hogDayTotal)) vs day receipt Σ legs \(fmtUSD(receiptTotal)) — \(hogConsistent ? "MATCH (same cost machinery)" : "MISMATCH — pricing fork")")

    // --- attention state machine (the flagship classifier, run on real data) ---
    // Prove the classifier fires: read each recent transcript's tail, extract the
    // dangling-tool_use / last-event / stop_reason signals, classify against now,
    // and print the per-state breakdown of the live pool.
    let attnNow = Date()
    let windowMin = Int(AttentionBoard.defaultWindow / 60)
    let candidates = sessions.filter {
        guard let d = $0.lastActivity, !$0.isSubagent else { return false }
        let age = attnNow.timeIntervalSince(d)
        return age >= 0 && age <= AttentionBoard.defaultWindow
    }
    var attnSignals: [String: AttentionSignals] = [:]
    for s in candidates where !s.filePath.isEmpty {
        if let sig = AttentionSignals.extractFromTail(path: s.filePath) { attnSignals[s.id] = sig }
    }
    let board = AttentionBoard.build(sessions: sessions, signals: attnSignals, now: attnNow)
    let liveNow = candidates.filter { attnNow.timeIntervalSince($0.lastActivity ?? .distantPast) < 15 * 60 }.count
    print("--- attention state machine (live pool ≤\(windowMin)m, subagents excluded): \(board.items.count) sessions, \(liveNow) active <15m ---")
    print("  BLOCKED \(board.blockedCount)   WAITING \(board.waitingCount)   RUNNING \(board.runningCount)   IDLE \(board.idleCount)")
    for it in board.needsAttention.prefix(8) {
        let st = it.state.label.padding(toLength: 8, withPad: " ", startingAt: 0)
        print("  \(st) \(it.session.project.padding(toLength: 24, withPad: " ", startingAt: 0)) \(fmtAgeShort(it.age).padding(toLength: 5, withPad: " ", startingAt: 0)) \(it.session.tier.label)")
    }

    // --- WALK-AWAY NOTIFY (frontier #2): the rising-edge BLOCKED notifier ---
    // The pure plan against the live board with an EMPTY previously-notified set →
    // exactly the sessions that WOULD post a macOS notification right now (every
    // session currently in BLOCKED reads as a fresh rising edge). Plus the opt-in
    // toggle (app's OWN dir, never ~/.claude) and, when run inside the .app bundle,
    // the live authorization grant. Headless here → auth is n/a (checked live).
    let notifyStore = NotifyPreferencesStore()
    let notifyPrefs = notifyStore.load()
    let notifyPlan = BlockedNotifier.plan(board: board, signals: attnSignals, previouslyBlocked: [])
    let wouldNotify = notifyPlan.notification?.count ?? 0
    print("=== WALK-AWAY NOTIFY (frontier #2) ===")
    print("  opt-in toggle:        \(notifyPrefs.enabled ? "ON" : "off")  (\(notifyStore.url.path.replacingOccurrences(of: home.path, with: "~")))")
    print("  would notify now:     \(wouldNotify) session(s) entering BLOCKED  ·  auth: \(NotifyAuthProbe.describe())")
    if let note = notifyPlan.notification {
        print("    → “\(note.title)” — \(note.body)")
    }

    // --- FLEET BOARD ("the Floor": bays in arrival order, subagents nested) ---
    // The presence instrument over the SAME state machine — but keyed by repo
    // (bays) with subagents nested under their parent main, per-bay cost subtotals,
    // and shared-cwd collision detection. Reads tails for the in-window pool INCL
    // subagents (they carry now-lines too). Fresh ledger → arrival == encounter
    // order here; in the app it accumulates true arrival order across the day.
    func col(_ s: String, _ n: Int) -> String { s.padding(toLength: n, withPad: " ", startingAt: 0) }
    var fleetSignals: [String: AttentionSignals] = [:]
    let fleetPool = sessions.filter {
        guard let d = $0.lastActivity else { return false }
        let age = attnNow.timeIntervalSince(d)
        return age >= 0 && age <= FleetBoard.window && !$0.filePath.isEmpty
    }
    for s in fleetPool {
        if let sig = AttentionSignals.extractFromTail(path: s.filePath) { fleetSignals[s.id] = sig }
    }
    let (fleet, _) = FleetBoard.build(sessions: sessions, signals: fleetSignals,
                                      now: attnNow, arrival: ArrivalLedger())
    print("=== FLEET BOARD (the Floor) ===")
    print("  \(fleet.bays.count) bays · \(fleet.mainCount) mains + \(fleet.subagentCount) subagents = \(fleet.tokenCount) tokens · \(fmtUSD(fleet.totalCost)) today")
    print("  BLOCKED \(fleet.blockedCount)   WAITING \(fleet.waitingCount)   RUNNING \(fleet.runningCount)   IDLE \(fleet.idleCount)   ·   \(fleet.collisions.count) collision(s)")
    for bay in fleet.bays.prefix(8) {
        let subs = bay.allTokens.count - bay.tokens.count
        let nest = subs > 0 ? " +\(subs) sub" : ""
        let coll = bay.collision.map { "  ⚠ \($0.count) editing" } ?? ""
        let idle = bay.isIdle ? "  (idle \(fmtAgeShort(bay.age)))" : ""
        print("  \(col(bay.project, 26)) \(bay.tokens.count) seat(s)\(col(nest, 8)) \(col(fmtUSD(bay.costSubtotal), 8))\(coll)\(idle)")
    }
    // Heartbeat logic (the ambient signal): a stream of disk events coalesces to
    // ≤4/s of visible ticks; a BLOCKED (still) seat emits none. Proven here on a
    // synthetic burst so the selfcheck covers the motion driver's core rule.
    var beat = HeartbeatCoalescer()
    var runTicks = 0, blockedTicks = 0
    for i in 0..<12 {                                   // 12 events over ~1.1s
        let t = attnNow.addingTimeInterval(Double(i) * 0.1)
        if beat.register(session: "run", at: t, isStill: false) { runTicks += 1 }
        if beat.register(session: "blk", at: t, isStill: true) { blockedTicks += 1 }
    }
    print("  heartbeat: 12 disk events → \(runTicks) ticks on a RUNNING seat (≤4/s), \(blockedTicks) on a BLOCKED-still seat")

    // --- AUDIT pillar (the four findings, computed on real disk data) ---
    // Reproduces the briefed headline numbers, honestly: dead-skill count
    // (historical 93/108 → now ~95/110 as the catalog grew) and the Custom-subagent
    // count. NOTE the loose `.message.model` grep that produced the "~90" signal
    // over-counted — it matched files that merely MENTION "claude-custom-5" in
    // content. Counting an actual assistant Custom run yields the precise 78.
    func pad(_ s: String, _ n: Int) -> String { s.padding(toLength: n, withPad: " ", startingAt: 0) }
    let catalog = SkillCatalog.scan()
    let audit = AuditReport.build(sessions: sessions, skills: catalog)
    let l = audit.skillLedger
    print("=== AUDIT pillar ===")
    print("--- ★ re-sent context: the LEAK vs first-touch (top sessions) ---")
    print("  the leak:    \(fmtUSD(audit.totalLeakDollars)) re-sent as fresh input above the warm-cache floor across \(sessions.count) sessions (the avoidable part)")
    print("  first-touch: \(fmtUSD(audit.totalFirstTouchDollars)) cache creation (5m 1.25× / 1h 2×) — the cost of building cache, NOT a leak")
    for f in audit.cacheMiss.prefix(6) {
        print("  \(pad(f.project, 26)) \(pad(fmtUSD(f.leakDollars), 9)) leak  \(pad(fmtUSD(f.firstTouchDollars), 9)) first-touch  \(pad(fmtPct(f.cacheHitRate), 5)) cached  \(pad(fmtTokens(f.billedInput), 7)) billed  \(f.tier.label)")
    }
    print("--- dead-skill ledger + prompt tax ---")
    print("  \(l.deadCount) of \(l.catalogCount) skills never explicit-fired  ·  \(l.distinctFired) distinct fired (\(l.firedInCatalog) in catalog)  ·  ≈\(fmtTokens(l.deadPromptTaxTokens)) tok description tax over ~\(l.sessionCount) sessions")
    // Task #41: the census now merges Skill tool_use calls WITH slash-command
    // (`<command-name>`) invocations before deciding dead-vs-fired; this line
    // isolates the slash lane's own contribution so the merge stays auditable.
    let slashFiredNames = Set(sessions.flatMap { $0.commandInvocations.keys })
    print("  slash-fired: \(slashFiredNames.count) distinct commands (explicit Skill-tool calls + slash commands; auto-loaded skills still uncounted)")
    for e in l.fired.prefix(5) {
        print("  fired  \(pad(e.name, 24)) ×\(pad(String(e.invocations), 4)) \(e.sessionsTouched) sessions")
    }
    print("--- model-mismatch review candidates ---")
    print("  \(audit.mismatchCount) candidates  ·  ≈\(fmtUSD(audit.totalMismatchOverspend)) est. overspend (frontier legs repriced at date-aware Sonnet; heuristic, not verdicts)")
    for c in audit.mismatches.prefix(5) {
        print("  \(pad(c.project, 26)) \(pad(c.tier.label, 9)) \(pad(fmtUSD(c.cost), 8)) → est. overspend \(pad(fmtUSD(c.estOverspend), 8))  (\(c.messageCount) msgs, \(c.fileEdits) edits)")
    }


    // --- LAUNCH pillar: skill hierarchy (source lanes) + saved recipes ---
    // Skill count BY SOURCE LANE (the plugin cache was invisible to the flat
    // scanner) + the trigger-collision index + recipes on disk in the app's OWN dir.
    let allSkills = SkillCatalog.scanAll()
    let hier = SkillHierarchy.build(allSkills)
    print("=== LAUNCH pillar — skill hierarchy (VISION 3.3) ===")
    print("  \(hier.totalSkills) skills across lanes:  user \(hier.laneCount(.user))  ·  plugin-cache \(hier.laneCount(.plugin))  ·  project \(hier.laneCount(.project))")
    for lane in hier.lanes {
        let ns = lane.namespaces.map { "\($0.displayName)×\($0.count)" }.prefix(6).joined(separator: ", ")
        print("  \(pad(lane.lane.title, 9)) \(pad(String(lane.count), 4)) skills  [\(ns)]")
    }
    print("  \(hier.distinctTriggers) distinct declared triggers  ·  \(hier.collisions.count) collision(s)")
    for c in hier.collisions.prefix(4) {
        print("    ⚠ “\(c.phrase)” claimed by \(c.skillNames.joined(separator: ", "))")
    }
    // Recipes on disk (never ~/.claude — the app's own dir).
    let repo = RecipeRepository()
    let recipes = repo.list()
    print("=== LAUNCH pillar — session builder / recipes (VISION 3.1) ===")
    print("  recipes dir:          \(repo.directory.path.replacingOccurrences(of: home.path, with: "~"))")
    print("  saved recipes:        \(recipes.count)")
    for r in recipes.prefix(6) {
        let cmd = RecipeComposer.compose(r, promptFilePath: repo.promptURL(r.id).path)
        print("  \(pad(r.name, 22)) \(pad(r.effort.label, 7)) \(r.agents.count) agents · \(r.skillRefs.count) skills")
        print("    \(cmd.shellCommand.prefix(140))")
    }
    // Prove the composer end-to-end on a synthetic recipe (opus pin present).
    let demo = LaunchRender.seededDraft()
    let demoCmd = RecipeComposer.compose(demo, promptFilePath: "/tmp/demo.txt")
    print("  composer self-test:   opus pin \(demoCmd.agentsJSON.contains(#""model":"opus""#) ? "OK" : "MISSING")  ·  \(demoCmd.claudeArgs.count) argv tokens")
    print("    \(demoCmd.shellCommand)")

    // --- THE DREAMING LEDGER (v1 · Lessons): findings → copy-able candidate fixes ---
    // Deterministic mint over the SAME audit report + real settings.json (model +
    // effortLevel). Prints the lesson count BY TYPE and each firing lesson's
    // headline + candidate. Honest empty behavior: L-005 (effort furnace) does NOT
    // fire while effortLevel is "high" (the current on-disk value).
    let ledgerSettings = ClaudeSettings.load()
    let lessons = LessonMiner.mint(report: audit, catalog: catalog, settings: ledgerSettings)
    print("=== THE DREAMING LEDGER (v1 · Lessons) ===")
    print("  settings.json:        model \(ledgerSettings.model) · effort \(ledgerSettings.effortRaw)")
    print("  lessons minted:       \(lessons.count) of \(LessonKind.allCases.count) detectors fired")
    for k in LessonKind.allCases {
        let fired = lessons.contains { $0.kind == k }
        print("    \(pad(k.code, 6)) \(pad(k.title, 30)) \(fired ? "FIRED" : "— quiet")")
    }
    for l in lessons {
        print("  \(pad(l.kind.code, 6)) \(pad(l.metricLabel, 16)) \(l.candidate.copyLabel) · \(l.why.prefix(88))")
    }

    // --- CROSS-MACHINE FLEET (the differentiator) ---
    // Load the fleet config, scan any already-synced read-only
    // mirrors, merge them tagged-by-machine, and print machines + per-machine counts
    // + a best-effort reachability probe (SHORT timeout — never hangs). Proves the
    // pure merge over real disk and the pure sync-command composition + read-only
    // guarantees, all WITHOUT a live network dependency.
    let fleetConfig = MachinePaths.loadConfig()
    let remoteSources = fleetConfig.remotes.compactMap { r -> RemoteSource? in
        MachinePaths.mirrorHasContent(for: r.name)
            ? RemoteSource(machine: r.machine, dir: MachinePaths.mirror(for: r.name)) : nil
    }
    let remoteScans = SessionStore.scanRemotes(remoteSources)
    let fleetSessions = FleetMerge.merge(local: sessions, remotes: remoteScans)
    let machineList = [Machine.local] + fleetConfig.remotes.map(\.machine)
    let rollups = FleetMerge.rollups(fleetSessions, machines: machineList)
    let fleetCost = rollups.reduce(0.0) { $0 + $1.cost }
    print("=== CROSS-MACHINE FLEET (differentiator) ===")
    print("  config:               \(MachinePaths.configURL.path.replacingOccurrences(of: home.path, with: "~"))")
    print("  machines configured:  \(machineList.count)  (local + \(fleetConfig.remotes.count) remote)")
    print("  fleet totals:         \(FleetMerge.machineCount(fleetSessions)) machine(s) contributing · \(fleetSessions.count) sessions · \(fmtUSD(fleetCost)) total")
    for r in rollups {
        // Best-effort reachability — SHORT timeout, bounded so it never hangs even if
        // workstation is down right now (local is skipped).
        let reach: String
        if r.machine.isLocal { reach = "—" }
        else if let cfg = fleetConfig.remotes.first(where: { $0.name == r.machine.id }) {
            reach = MachineReachability.probe(host: cfg.host, timeoutMs: 1500).rawValue
        } else { reach = "unknown" }
        let mirror = r.machine.isLocal ? "—"
            : (MachinePaths.mirrorHasContent(for: r.machine.id) ? "synced" : "no mirror (inert)")
        print("  \(pad(r.machine.name, 12)) \(pad("\(r.sessionCount) sessions", 14)) reachable: \(pad(reach, 12)) mirror: \(mirror)")
    }
    // Prove the sync-command composition (PURE — no live call) + the read-only + day
    // bound guarantees the tests assert on.
    if let dev = fleetConfig.remotes.first {
        let plan = RemoteSync.plan(remote: dev, mirror: MachinePaths.mirror(for: dev.name),
                                   listFile: MachinePaths.syncListFile(for: dev.name))
        let mtimeOK = plan.list.contains("-mtime") && plan.list.contains("-\(dev.recentDays)")
        let readOnly = !plan.pull.contains("--remove-source-files")
            && plan.pull.contains("\(dev.sshTarget):/")            // remote is SOURCE
            && plan.pull.last == MachinePaths.mirror(for: dev.name).path   // dest is local mirror
        print("  sync composition:     \(dev.name) — \(dev.recentDays)d bound \(mtimeOK ? "OK" : "MISSING") · read-only \(readOnly ? "OK" : "VIOLATION")")
        print("    list: \(plan.list.joined(separator: " "))")
        print("    pull: \(plan.pull.joined(separator: " "))")
    }

    // --- CONFIG-SURFACE HEALTH (VISION 2.4): MCP servers · hooks · plugins ---
    // Read the three real config surfaces off disk through the SAME pure parsers +
    // classify mappings the Stack ProbeCards use, resolving each command with the
    // real GUI-fallback PATH resolver. HONEST LIMIT: a resolving command means the
    // binary/script is PRESENT — not that the MCP server actually handshakes (phase
    // 1 checks presence/executability only).
    func data(_ path: String) -> Data { (try? Data(contentsOf: home.appendingPathComponent(path))) ?? Data() }
    let mcpHealth = MCPConfig.classify(MCPConfig.parse(data(".claude.json")),
                                       resolves: ProbePrimitives.commandResolves)
    let (mcpPresent, mcpMissing, mcpRemote) = MCPConfig.summary(mcpHealth)
    let hookHealth = HooksConfig.classify(HooksConfig.parse(data(".claude/settings.json")),
                                          resolves: ProbePrimitives.commandResolves)
    let (hookPresent, hookBuiltin, hookMissing, hookEvents) = HooksConfig.summary(hookHealth)
    let plugins = PluginsConfig.parse(data(".claude/plugins/installed_plugins.json"))
    let (plugInstalled, plugStale) = PluginsConfig.summary(plugins)
    print("=== CONFIG-SURFACE HEALTH (VISION 2.4) ===")
    print("  MCP servers:  \(mcpHealth.count) configured · \(mcpPresent) binary present · \(mcpMissing) missing · \(mcpRemote) remote  (presence only, not a live handshake)")
    for h in mcpHealth {
        let mark = h.status == .present ? "present" : (h.status == .missing ? "MISSING" : (h.status == .remote ? "remote endpoint" : "no command"))
        print("    \(pad(h.name, 16)) \(pad(h.command ?? h.transport, 14)) \(mark)")
    }
    print("  hooks:        \(hookHealth.count) across \(hookEvents) event(s) · \(hookPresent) tool present, \(hookMissing) missing · \(hookBuiltin) reminder(s)")
    for h in hookHealth where h.status == .present || h.status == .missing {
        print("    \(pad(h.event, 16)) \(pad((h.binary as NSString).lastPathComponent, 16)) \(h.status == .present ? "present" : "MISSING")")
    }
    print("  plugins:      \(plugInstalled) installed · \(plugStale) stale (>\(Int(PluginsConfig.staleThresholdDays))d since update)")
    for p in plugins.prefix(6) {
        let age = p.ageDays.map { "\(Int($0))d" } ?? "unknown"
        print("    \(pad(p.name, 22)) \(pad("v" + p.version, 10)) \(pad(age, 8)) \(p.isStale ? "STALE" : "fresh")")
    }
    print("  probeResult status:   mcp \(MCPConfig.probeResult(mcpHealth).status.rawValue) · hooks \(HooksConfig.probeResult(hookHealth).status.rawValue) · plugins \(PluginsConfig.probeResult(plugins).status.rawValue)")

    // --- THE DEADLINE BOARD (docs/DEADLINE_BOARD.md) ---
    // Parse deadlines from the SAME sources the app reads (MEMORY.md + per-project
    // NOTES.md/README), pick the operative deadline per project, fold in any user
    // `.toml` override, JOIN with live per-project activity, and print the jeopardy-
    // sorted board + the leader. "Linear key present" reads the real Keychain (never a
    // file); the live sync itself is verified by the user with their own key.
    let dlNow = Date()
    let dlHints = Array(Set(sessions.filter { !$0.isSubagent }.map(\.project))).sorted()
    var dlParsed: [ParsedDeadline] = []
    let memSlug = home.path.replacingOccurrences(of: "/", with: "-")
    let memPath = home.appendingPathComponent(".claude/projects/\(memSlug)/memory/MEMORY.md").path
    if let memText = try? String(contentsOfFile: memPath, encoding: .utf8) {
        dlParsed += DeadlineParser.parse(text: memText, file: "MEMORY.md", projectHints: dlHints, now: dlNow)
    }
    var dlCwds = Set<String>()
    for s in sessions where !s.isSubagent && !s.cwd.isEmpty && dlCwds.insert(s.cwd).inserted {
        let base = (s.cwd as NSString).lastPathComponent
        for name in ["NOTES.md", "README.md"] {
            let p = (s.cwd as NSString).appendingPathComponent(name)
            if let t = try? String(contentsOfFile: p, encoding: .utf8) {
                dlParsed += DeadlineParser.parse(text: t, file: p, defaultProject: base, projectHints: dlHints, now: dlNow)
            }
        }
        if dlCwds.count >= 24 { break }
    }
    let dlOperative = DeadlineParser.operativeDeadlines(dlParsed, now: dlNow)
    var dlOverrides: [DeadlineOverride] = []
    let dlToml = home.appendingPathComponent(".claude/mission-control/deadlines.toml").path
    if let t = try? String(contentsOfFile: dlToml, encoding: .utf8) { dlOverrides = DeadlineTOML.parse(t) }
    let dlRecords = DeadlineMerge.resolve(
        parsed: dlOperative, persisted: DeadlineRecordStore().load(), overrides: dlOverrides)
    let dlActivity = DeadlineActivity.summarize(sessions, now: dlNow)
    let dlCards = DeadlineBoard.build(records: dlRecords, activity: dlActivity, now: dlNow)
    let keyPresent = KeychainLinearStore().readKey() != nil
    let linMap = LinearMapStore().load()
    let linSettings = LinearSettingsStore().load()
    print("=== THE DEADLINE BOARD (docs/DEADLINE_BOARD.md) ===")
    print("  parsed deadlines:     \(dlOperative.count) project(s) with a parsed deadline\(dlOverrides.isEmpty ? "" : " · \(dlOverrides.count) .toml override(s)")")
    print("  board cards:          \(dlCards.count) (\(dlCards.filter { $0.state == .stalled }.count) STALLED · \(dlCards.filter { $0.state == .atRisk }.count) at-risk · \(dlCards.filter { $0.state == .onTrack }.count) on-track · \(dlCards.filter { $0.state == .shipped }.count) shipped · \(dlCards.filter { $0.state == .overdue }.count) overdue)")
    for c in dlCards.prefix(10) {
        let confirm = c.source.confirmed ? "confirmed" : "confirm?"
        let jeo = c.jeopardy.isFinite ? String(format: "%.2f", c.jeopardy) : "∞"
        print("  \(pad(c.projectKey, 22)) \(pad(c.state.label, 9)) \(pad(fmtCountdown(c.runway), 11)) jeopardy \(pad(jeo, 6)) \(pad(fmtUSD(c.cost), 8)) \(pad(fmtDeadlineStamp(c.deadline), 18)) [\(c.source.file):\(c.source.line) · \(confirm)]")
    }
    if let leader = DeadlineBoard.worst(dlCards) {
        print("  jeopardy leader:      \(leader.projectKey) — \(leader.state.label) · \(fmtCountdown(leader.runway)) left · untouched \(leader.lastActivity == nil ? "—" : fmtAgeShort(leader.idle)) · jeopardy \(String(format: "%.2f", leader.jeopardy))")
    }
    print("--- Linear one-way exporter (§8) ---")
    print("  Linear key present:   \(keyPresent ? "yes (Keychain: \(KeychainLinearStore.service)/\(KeychainLinearStore.account))" : "no")  ·  team: \(linSettings.teamName ?? "not picked")  ·  mapped projects: \(linMap.count)")
    let dlEligible = dlCards.filter { LinearEligibility.isSyncable($0) }.count
    print("  sync-eligible:        \(dlEligible) of \(dlCards.count) card(s) confirmed — unconfirmed parses are findings and stay local")
    print("  builders self-test:   \(deadlineBuilderSelfTest())")

    // --- PLAN QUOTA (W7, plan 04): decoder replay + the real-world anchor ---
    // No network here — the selfcheck replays payload shapes through the SAME
    // decode path the fetcher's 200 branch uses (QuotaSnapshot.decode), then
    // reconstructs today's observed event: at ~09:55 IST two headless sessions
    // hit "You've hit your session limit · resets 10am (Asia/Calcutta)". The
    // surface must be able to say that BEFORE it happens.
    print("--- plan quota (W7, plan 04) — decoder replay + anchor (no network) ---")
    let quotaISO = ISO8601DateFormatter()
    let anchorReset = quotaISO.date(from: "2026-02-10T04:30:00Z")!   // 10:00 Asia/Calcutta
    let anchorNow   = quotaISO.date(from: "2026-02-10T04:25:00Z")!   // 09:55 Asia/Calcutta
    let anchorJSON = #"""
    {"five_hour":{"utilization":100,"resets_at":"2026-02-10T04:30:00Z"},
     "seven_day":{"utilization":37.5,"resets_at":"2026-02-13T18:00:00Z"},
     "limits":[
       {"kind":"weekly_scoped","group":"weekly","percent":62,"is_active":false,
        "resets_at":"2026-02-13T18:00:00Z","scope":{"model":{"id":"claude-opus-4-8","display_name":"Claude Opus 4-8"}}},
       {"kind":"weekly_scoped","group":"weekly","percent":99,
        "scope":{"model":{"id":"CLAUDE-OPUS-4-8","display_name":"claude opus 4-8"}}},
       {"kind":"extra_usage","group":"weekly","percent":12}]}
    """#
    if let snap = QuotaSnapshot.decode(Data(anchorJSON.utf8), now: anchorNow) {
        let titles = snap.windows.map(\.title)
        let orderOK = titles.first == "Session (5h)" && titles.dropFirst().first == "Weekly (all models)"
        print("  decode: OK · \(snap.windows.count) windows · render order \(orderOK ? "5h → weekly → scoped (OK)" : "WRONG: \(titles)")")
        print("  scoped dedupe: \(snap.scoped.count == 1 ? "OK — duplicate slug collapsed, first entry wins" : "FAIL — expected 1, got \(snap.scoped.count)") · is_active=false still shown (observed enforceable limits report false)")
        print("  unknown kinds: extra_usage decoded-and-dropped \(snap.scoped.contains { $0.title.lowercased().contains("extra") } ? "FAIL — leaked into scoped" : "(OK — plan 04 out-of-scope)")")
        if let fh = snap.fiveHour, let resets = fh.resetsAt {
            let runway = resets.timeIntervalSince(anchorNow)
            let local = DateFormatter()
            local.locale = Locale(identifier: "en_US_POSIX")
            local.timeZone = TimeZone(identifier: "Asia/Calcutta")
            local.dateFormat = "h:mma"
            let anchorOK = fh.usedPercent >= 100 && runway == 300 && resets == anchorReset
            print("  anchor replay (today, ~09:55 IST): \(Int(fh.usedPercent))% used · resets \(fmtCountdown(runway)) → \(local.string(from: resets)) Asia/Calcutta \(anchorOK ? "(OK — the 'resets 10am' moment, visible 5m in advance)" : "MISMATCH — runway \(runway)s")")
        } else {
            print("  anchor replay: FAIL — five_hour window missing from decode")
        }
    } else {
        print("  decode: FAIL — anchor fixture did not decode")
    }
    let quotaQuiet = QuotaSnapshot.decode(Data("{}".utf8), now: anchorNow)
    print("  honest quiet: {} → \(quotaQuiet?.isEmpty == true ? "empty snapshot (OK — no invented zeros; section stays silent)" : "FAIL")")
    print("  never crash: garbage → \(QuotaSnapshot.decode(Data("<!doctype html>".utf8), now: anchorNow) == nil ? "nil (OK)" : "FAIL — decoded HTML")")

    // --- MENU-BAR PRESENCE (plan 03) — the judgment strip, proven headless ---
    // A real NSStatusItem can't paint in a headless run, so the gate is the pure
    // reducer: the SAME AttentionBoard / DeadlineBoard / hog / quota builders the
    // app uses, folded to the exact title + menu text the strip WOULD show now.
    let mbNow = Date()
    let mb = MenuBarReducer.model(board: board, cards: dlCards, todayCost: hogDayTotal,
                                  hog: hog, quota: nil, now: mbNow)
    let mbGlyph: String
    switch mb.glyph {
    case .needsYou(let n): mbGlyph = "needsYou(blocked: \(n))"
    case .running: mbGlyph = "running"
    case .quiet: mbGlyph = "quiet"
    }
    let glyphOK = (board.blockedCount > 0 || board.waitingCount > 0)
        ? mb.glyph == .needsYou(blockedCount: board.blockedCount)
        : (board.runningCount > 0 ? mb.glyph == .running : mb.glyph == .quiet)
    print("=== MENU-BAR PRESENCE (plan 03) — judgment strip, reducer on the real corpus ===")
    print("  glyph: \(mbGlyph) \(glyphOK ? "(OK — matches board \(board.blockedCount)B/\(board.waitingCount)W/\(board.runningCount)R)" : "FAIL — board says \(board.blockedCount)B/\(board.waitingCount)W/\(board.runningCount)R")")
    print("  title beside glyph: \(mb.title.map { "“\($0)”" } ?? "none (calm — no blocked count, no hog)")")
    print("  fleet line: \(mb.fleetLine)")
    for r in mb.blocked.prefix(4) {
        print("  BLOCKED  \(pad(r.title, 30)) \(pad(fmtAgeShort(r.age), 6)) \(r.tierLabel)")
    }
    for r in mb.waiting.prefix(4) {
        print("  WAITING  \(pad(r.title, 30)) \(pad(fmtAgeShort(r.age), 6)) \(r.tierLabel)")
    }
    print("  jeopardy: \(mb.jeopardy.map { "\($0.projectKey) — \($0.stateLabel) · \($0.countdown)" } ?? "none (no deadline in danger)")")
    print("  hog: \(mb.hogLine ?? "quiet (no orchestrator hog today)")")
    print("  quota line (live): \(mb.quotaLine ?? "quiet — no window over \(Int(MenuBarReducer.quotaHotPercent))% (fetch is app-side; selfcheck stays offline)")")
    // Hot-window drill: the anchor fixture (100% used, resets 5m) through the
    // SAME hotQuotaLine the strip uses — proves the hot path without network.
    let mbHot = MenuBarReducer.hotQuotaLine(QuotaSnapshot.decode(Data(anchorJSON.utf8), now: anchorNow), now: anchorNow)
    print("  quota line (anchor replay): \(mbHot ?? "FAIL — the 100% window did not read as hot")")

    // --- PERF: the refresh-path costs, measured on the real corpus ---
    // Every row is one thing the GUI's refresh cascade or a hot view body runs.
    // [main] = runs ON the main actor in the app (a slow row here IS a UI stall);
    // [off]  = runs detached (a slow row here is latency, not jank);
    // [body] = recomputed inside a SwiftUI `body` on every publish/heartbeat tick.
    // Run the GUI with MC_PERF=1 to see the same spans live.
    print("=== PERF — refresh-path costs (\(sessions.count) sessions) ===")
    func perfRow(_ label: String, _ ms: Double, _ note: String = "") {
        print("  \(pad(label, 40)) \(String(format: "%8.1f ms", ms))\(note.isEmpty ? "" : "  \(note)")")
    }
    let pSort = Perf.time { _ = sessions.sorted { ($0.lastActivity ?? .distantPast) > ($1.lastActivity ?? .distantPast) } }
    perfRow("[off]  sort by recency", pSort.ms)
    let sessionsCopy = sessions
    let pEq = Perf.time { _ = (sessions == sessionsCopy) }
    perfRow("[main] publish equality compare", pEq.ms, "compare-before-assign, worst case")
    let pFlags = Perf.time { _ = RoutingAudit.computeFlags(defaultModel: "opus", sessions: sessions) }
    perfRow("[main] RoutingAudit.computeFlags", pFlags.ms)
    let pBoard = Perf.time { _ = AttentionBoard.build(sessions: sessions, signals: attnSignals, now: attnNow) }
    perfRow("[main] AttentionBoard.build", pBoard.ms, "×2-3 per body pass (strip, wordmark, badge)")
    let pFleetTails = Perf.time {
        var out: [String: AttentionSignals] = [:]
        for s in fleetPool {
            if let sig = AttentionSignals.extractFromTail(path: s.filePath) { out[s.id] = sig }
        }
        return out
    }
    perfRow("[off]  tail extraction (\(fleetPool.count) files)", pFleetTails.ms)
    let pFleetBuild = Perf.time {
        _ = FleetBoard.build(sessions: sessions, signals: fleetSignals, now: attnNow, arrival: ArrivalLedger())
    }
    perfRow("[main] FleetBoard.build", pFleetBuild.ms, "per body pass on the Floor")
    let pAudit = Perf.time { _ = AuditReport.build(sessions: sessions, skills: catalog) }
    perfRow("[off]  AuditReport.build", pAudit.ms)
    let pMint = Perf.time { _ = LessonMiner.mint(report: audit, catalog: catalog, settings: ledgerSettings) }
    perfRow("[main] LessonMiner.mint (remint)", pMint.ms)
    let pDeadlines = Perf.time {
        var parsed: [ParsedDeadline] = []
        if let memText = try? String(contentsOfFile: memPath, encoding: .utf8) {
            parsed += DeadlineParser.parse(text: memText, file: "MEMORY.md", projectHints: dlHints, now: dlNow)
        }
        var cwds = Set<String>()
        for s in sessions where !s.isSubagent && !s.cwd.isEmpty && cwds.insert(s.cwd).inserted {
            let base = (s.cwd as NSString).lastPathComponent
            for name in ["NOTES.md", "README.md"] {
                let p = (s.cwd as NSString).appendingPathComponent(name)
                if let t = try? String(contentsOfFile: p, encoding: .utf8) {
                    parsed += DeadlineParser.parse(text: t, file: p, defaultProject: base, projectHints: dlHints, now: dlNow)
                }
            }
            if cwds.count >= 24 { break }
        }
        return DeadlineParser.operativeDeadlines(parsed, now: dlNow)
    }
    perfRow("[off]  deadline source parse", pDeadlines.ms, "MEMORY.md + ≤24 project dirs (detached)")
    let pCost = Perf.time { _ = sessions.reduce(0.0) { $0 + $1.cost } }
    perfRow("[body] totalCost pass", pCost.ms, "Overview stat tile")
    let pTiers = Perf.time { _ = SessionStore.aggregateTiers(sessions) }
    perfRow("[body] tierStats aggregation", pTiers.ms, "Overview spend split")
    let pSavings = Perf.time { _ = sessions.reduce(0.0) { $0 + $1.cacheSavingsDollars } }
    perfRow("[body] totalCacheSavings pass", pSavings.ms, "Overview stat tile")
    let pProject = Perf.time {
        var map: [String: (Double, Int)] = [:]
        for s in sessions {
            let v = map[s.project] ?? (0, 0)
            map[s.project] = (v.0 + s.cost, v.1 + 1)
        }
        return map.count
    }
    perfRow("[body] projectSpend rollup", pProject.ms, "Overview subtitle")
    let pBurn = Perf.time { _ = BurnGovernor(sessions: sessions) }
    perfRow("[body] BurnGovernor init", pBurn.ms, "×2 per body pass (sidebar + Overview)")
    let pReceipt = Perf.time { _ = CostProvenance.corpusReceipt(sessions: sessions) }
    perfRow("[body] corpusReceipt build", pReceipt.ms, "on expand / while expanded")
    let pCostSort = Perf.time {
        // Mirrors SessionsScreen's decorated sort (one cost per row, keys-only
        // sort, single reorder) — the naive `sort { $0.cost > $1.cost }`
        // comparator it replaced recomputed cost O(n log n) times.
        let keys = sessions.enumerated()
            .map { (i: $0.offset, c: $0.element.cost, id: $0.element.id) }
            .sorted { ($0.c, $1.id) > ($1.c, $0.id) }
        return keys.map { sessions[$0.i] }.count
    }
    perfRow("[body] SessionsScreen sort by cost", pCostSort.ms, "the Cost sort key")

    // --- SELF-INTROSPECTION MCP ENDPOINT (spree #4 — rauchg #20) ---
    // Spin the MCP loop in-process on the REAL corpus: the exact handleLine
    // path `--mcp` drives, minus the pipe. Full initialize handshake,
    // tools/list, one tools/call per tool (default self-resolution), and a
    // malformed line — every reply must be well-formed JSON-RPC with non-empty,
    // parseable content. Quota may honestly degrade (no creds/offline) — that
    // is still a well-formed result, which is the contract.
    let mcp = MCPIntrospectionServer(sessions: { sessions },
                                     quota: { MCPIntrospectionServer.blockingQuotaFetch() })
    func mcpCall(_ line: String) -> [String: Any]? {
        guard let out = mcp.handleLine(line) else { return nil }
        return (try? JSONSerialization.jsonObject(with: Data(out.utf8))) as? [String: Any]
    }
    print("=== SELF-INTROSPECTION MCP ENDPOINT (spree #4 — rauchg #20) ===")
    let hs = mcpCall(#"{"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"selfcheck","version":"0"}}}"#)
    let hsVersion = (hs?["result"] as? [String: Any])?["protocolVersion"] as? String
    let hsOK = hsVersion == "2025-06-18"
    print("  initialize:           \(hsOK ? "OK — protocol \(hsVersion ?? "?")" : "FAILED")")
    let noteAbsorbed = mcp.handleLine(#"{"jsonrpc":"2.0","method":"notifications/initialized"}"#) == nil
    let tools = (mcpCall(#"{"jsonrpc":"2.0","id":1,"method":"tools/list"}"#)?["result"] as? [String: Any])?["tools"] as? [[String: Any]] ?? []
    print("  tools/list:           \(tools.count) tools — \(tools.compactMap { $0["name"] as? String }.joined(separator: ", "))")
    var mcpAllOK = hsOK && noteAbsorbed && tools.count == 5
    for (i, tool) in tools.enumerated() {
        guard let name = tool["name"] as? String else { mcpAllOK = false; continue }
        let res = mcpCall(#"{"jsonrpc":"2.0","id":\#(i + 2),"method":"tools/call","params":{"name":"\#(name)","arguments":{}}}"#)?["result"] as? [String: Any]
        let text = (res?["content"] as? [[String: Any]])?.first?["text"] as? String ?? ""
        let parsed = (try? JSONSerialization.jsonObject(with: Data(text.utf8))) as? [String: Any]
        let ok = (res?["isError"] as? Bool) == false && !(parsed?.isEmpty ?? true)
        if !ok { mcpAllOK = false }
        print("  tools/call \(pad(name, 15)) \(ok ? "OK" : "FAILED") — \(text.count) bytes\(ok ? "" : " · \(text.prefix(100))")")
    }
    let malformed = mcpCall("{this is not json")
    let malformedOK = ((malformed?["error"] as? [String: Any])?["code"] as? Int) == -32700
    if !malformedOK { mcpAllOK = false }
    print("  malformed line:       \(malformedOK ? "OK — JSON-RPC -32700, no crash" : "FAILED")")
    print("  verdict:              \(mcpAllOK ? "all tools well-formed on the real corpus" : "MCP FAILURES above")")

    exit(0)
}

/// Proves the LIVE Linear path is wired end-to-end (key → Keychain → GraphQL) without
/// a live key: the exact builders form, the idempotent decision holds, and the auth
/// header is the RAW personal key (no "Bearer "). The only missing input is the user's
/// own key, pasted in-app.
func deadlineBuilderSelfTest() -> String {
    let create = LinearGraphQL.projectCreate(name: "Alpha Hackathon",
                                             description: "Hackathon due July 13, 2026. Source: MEMORY.md line 47.",
                                             targetDate: "2026-07-13", teamId: "team_1", state: "started")
    let update = LinearGraphQL.projectUpdate(id: "proj_1",
                                             description: "Hackathon due July 13, 2026. Source: MEMORY.md line 47.",
                                             targetDate: "2026-07-13", state: "completed")
    let pu = LinearGraphQL.projectUpdateCreate(projectId: "proj_1",
                                               body: "On track — last worked 2 hours ago. 3 days left before the deadline. $14 of estimated Claude usage across 6 sessions.")
    let cancel = LinearGraphQL.projectCancel(id: "proj_1")
    let auth = LinearGraphQL.authorizationHeader(key: "personal_key")
    let ok = create.query.contains("projectCreate(")
        && update.query.contains("projectUpdate(")
        && pu.query.contains("projectUpdateCreate(")
        && cancel.variables.serialized().contains(#""state":"canceled""#)
        && LinearFormat.projectName(projectKey: "alpha-hackathon") == "Alpha Hackathon"
        && LinearSync.decide(mappedID: nil) == .create
        && LinearSync.decide(mappedID: "proj_1") == .update(id: "proj_1")
        && auth.name == "Authorization" && !auth.value.hasPrefix("Bearer")
    return ok
        ? "projectCreate/Update/UpdateCreate/Cancel + human name/description + idempotent upsert + raw-key header all wired — awaiting only your key"
        : "MISMATCH"
}

TrifolaApp.main()
