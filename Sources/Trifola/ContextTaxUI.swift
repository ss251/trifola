import SwiftUI
import TrifolaKit

// MARK: - The CONTEXT-TAX GAUGE (spree #1 — the "$20 hey" killer)
// One pure view, two densities: the inspector block (eyebrow + gauge bar +
// price line) and the Live-tile strip (`compact`). Evidence grammar throughout:
// the bar is normalized to the app's one context scale (400k), the numbers are
// tabular (POLISH C8), the model id renders mono (disk truth, POLISH II.C), and
// the cache-hit rate rides along as the honest denominator. The advisor line
// appears ONLY when a LIVE session crosses the visible 200k threshold — the
// threshold is in the copy, so it reads as a measurement, never a nag.

struct ContextTaxGaugeView: View {
    let gauge: ContextTaxGauge
    /// Live-tile density: one bar + one price line, no eyebrow row.
    var compact = false
    /// Composition override (plan 12) — render/tests inject a fixture built
    /// from a seeded gauge. `nil` (the default every live call site uses)
    /// means the view resolves it itself off the real `~/.claude/CLAUDE.md` +
    /// this gauge's own project CLAUDE.md + `~/.claude.json`, inspector
    /// density ONLY — the compact live tile never triggers the read.
    var composition: ContextComposition? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: compact ? 3 : 4) {
            if compact {
                compactStrip
            } else {
                headerRow
                CapsuleBar(fraction: gauge.gaugeFraction, tint: Theme.accent)
                priceLine
                compositionRow(composition ?? Self.liveComposition(for: gauge))
            }
            if gauge.isLive, let line = gauge.advisorLine {
                advisorRow(line)
            }
        }
    }

    /// The real-disk composition for a gauge, self-resolved so no call site
    /// (SessionsScreen's inspector) needs to thread file paths through —
    /// global CLAUDE.md + this session's project CLAUDE.md (if any) + the
    /// connected-MCP count off `~/.claude.json`. Read-only (see
    /// `ContextFootprint`'s doc comments).
    // Compute-once cache: `body` re-evaluates on every FSEvents refresh (the whole
    // fleet writes ~/.claude constantly), and reading CLAUDE.md + ~/.claude.json
    // synchronously per render starved the main thread. Composition is deterministic
    // for a (cwd, contextWeight) and its source files are near-static — cache it.
    private static let compositionCacheLock = NSLock()
    nonisolated(unsafe) private static var compositionCache: [String: ContextComposition] = [:]

    static func liveComposition(for gauge: ContextTaxGauge) -> ContextComposition {
        let key = "\(gauge.cwd)|\(gauge.contextWeight)"
        compositionCacheLock.lock()
        let hit = compositionCache[key]
        compositionCacheLock.unlock()
        if let hit { return hit }
        var paths = [ContextFootprint.defaultClaudeMdPath]
        if !gauge.cwd.isEmpty {
            paths.append(gauge.cwd + "/CLAUDE.md")
        }
        let composed = ContextFootprint.composition(contextWeight: gauge.contextWeight,
                                                    claudeMdPaths: paths)
        compositionCacheLock.lock()
        compositionCache[key] = composed
        compositionCacheLock.unlock()
        return composed
    }

    // MARK: inspector density

    private var headerRow: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Eyebrow("Context tax")
            Spacer(minLength: 8)
            // Exact token count, grouped + mono — what the disk said the last
            // message re-sent, never the compact "0.3M".
            Text("\(fmtGrouped(gauge.contextWeight)) tok resent/msg")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Theme.muted)
        }
    }

    private var priceLine: some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text("next message ≈")
                .font(.caption)
                .foregroundStyle(Theme.muted)
            Text("\(fmtUSD(gauge.warmPerMessage)) warm · \(fmtUSD(gauge.coldPerMessage)) cold")
                .font(.caption.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
            Text("· \(fmtPct(gauge.cacheHitRate)) cached · cold = cache expired (>5m idle)")
                .font(.caption)
                .foregroundStyle(Theme.faint)
                .lineLimit(1)
            Spacer(minLength: 0)
            if !gauge.modelID.isEmpty {
                Text(gauge.modelID)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Theme.faint)
            }
        }
    }

    // MARK: composition sub-line (plan 12 — inspector density only)
    // "Of your 312k resent tokens, ~40k is 6 idle MCP tool schemas, ~18k is
    // CLAUDE.md" — turns the opaque contextWeight into an actionable one.
    // Estimate grammar throughout: "≈" prefix on every number, faint/caption2
    // so it reads as a footnote under the priced gauge, never competes with it.

    private func compositionRow(_ c: ContextComposition) -> some View {
        Text(c.line)
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(Theme.faint)
            .lineLimit(1)
    }

    // MARK: tile density

    private var compactStrip: some View {
        HStack(spacing: 8) {
            CapsuleBar(fraction: gauge.gaugeFraction, tint: Theme.accent)
                .frame(width: 72)
            Text("\(fmtTokens(gauge.contextWeight)) ctx")
                .font(.system(.caption2, design: .monospaced))
                .foregroundStyle(Theme.muted)
            Text("next ≈ \(fmtUSD(gauge.warmPerMessage)) warm · \(fmtUSD(gauge.coldPerMessage)) cold")
                .font(.caption2.weight(.medium))
                .monospacedDigit()
                .foregroundStyle(Theme.ink)
            Text("\(fmtPct(gauge.cacheHitRate)) cached")
                .font(.caption2)
                .foregroundStyle(Theme.faint)
            Spacer(minLength: 0)
        }
    }

    // MARK: the advisor (live + over-threshold only)

    private func advisorRow(_ line: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle")
                .font(.caption2)
                .foregroundStyle(Theme.amber)
            Text(line)
                .font(compact ? .caption2 : .caption)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
