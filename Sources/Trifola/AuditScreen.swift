import SwiftUI
import AppKit
import TrifolaKit

/// The AUDIT pillar — "the whole point". Four findings, each computed from disk
/// and rendered as evidence: a sorted table, one accent, click → the offending
/// transcript. No AI-prose paragraphs, no nag banners; a calm "lean" line where a
/// finding has nothing. The content view is pure (data + callbacks) so the real
/// tables rasterize headlessly via `--render-audit`.
struct AuditScreen: View {
    @EnvironmentObject var services: AppServices

    var body: some View {
        ScreenScaffold(
            title: "Audit",
            subtitle: "Waste attributed to a cause — cache-miss dollars, dead skills, model-mismatch.",
            epithet: "evidence, not nags"
        ) {
            AuditContent(
                report: services.auditReport.report,
                onInspect: { id in
                    if let s = services.sessions.sessions.first(where: { $0.id == id }) {
                        services.inspect(s)
                    }
                },
                onReveal: { path in
                    guard !path.isEmpty else { return }
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
                },
                skillPaths: services.skills.allSkills.reduce(into: [:]) { paths, skill in
                    paths[skill.id] = skill.path
                    paths[skill.name] = skill.path
                    paths[skill.qualifiedID] = skill.path
                },
                // "Show the math" (W3): each finding's receipt — same slices,
                // same rates, same formula as the number on the row.
                leakReceipt: { finding in
                    guard let s = services.sessions.sessions.first(where: { $0.id == finding.id }) else { return nil }
                    let r = CostProvenance.sessionReceipt(s, metric: .cacheLeak)
                    return CostReceipt(
                        scope: r.scope, metric: r.metric, legs: r.legs, total: r.total,
                        pricingSource: r.pricingSource, dedupNote: r.dedupNote,
                        bucketingNote: r.bucketingNote,
                        footnotes: r.footnotes + [String(format: "first-touch cache creation (5m ×1.25 · 1h ×2) = $%.2f — the cost of building cache, never summed into the leak", s.firstTouchDollars)])
                },
                mismatchReceipt: { candidate in
                    guard let s = services.sessions.sessions.first(where: { $0.id == candidate.id }) else { return nil }
                    return CostProvenance.mismatchReceipt(s)
                }
            )
        }
    }
}

// MARK: - Pure content (renderable headlessly)

struct AuditContent: View {
    let report: AuditReport
    let onInspect: (String) -> Void
    let onReveal: (String) -> Void
    var skillPaths: [String: String] = [:]
    /// COST PROVENANCE (W3): per-finding receipt providers ("show the math" on
    /// the leak / overspend rows). nil (the default, and the render harness's
    /// choice) = no disclosure; a provider returning nil for an id not in the
    /// current index also shows none.
    var leakReceipt: ((CacheMissFinding) -> CostReceipt?)? = nil
    var mismatchReceipt: ((MismatchCandidate) -> CostReceipt?)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            AuditHeadline(report: report)
            Divider()
            CacheMissSection(findings: report.cacheMiss,
                             totalLeak: report.totalLeakDollars,
                             totalFirstTouch: report.totalFirstTouchDollars,
                             onSelect: onInspect,
                             receiptFor: leakReceipt)
            Divider()
            SkillLedgerSection(ledger: report.skillLedger,
                               artifactPaths: skillPaths,
                               onReveal: onReveal)
            Divider()
            MismatchSection(candidates: report.mismatches,
                            total: report.totalMismatchOverspend,
                            onSelect: onInspect,
                            receiptFor: mismatchReceipt)
        }
    }
}

// MARK: - Headline

private struct AuditHeadline: View {
    let report: AuditReport

    var body: some View {
        let l = report.skillLedger
        return StatRow {
            StatTile(label: "Re-sent context (the leak)", value: fmtUSD(report.totalLeakDollars),
                     sub: "above warm-cache floor · +\(fmtUSD(report.totalFirstTouchDollars)) first-touch")
            Divider()
            StatTile(label: "Dead skills", value: "\(l.deadCount)/\(l.catalogCount)",
                     sub: "never explicit-fired · ≈\(fmtTokens(l.deadPromptTaxTokens)) tok tax")
            Divider()
            StatTile(label: "Review candidates", value: "\(report.mismatchCount)",
                     sub: "≈\(fmtUSD(report.totalMismatchOverspend)) est. overspend")
        }
    }
}

// MARK: - Section header + calm empty line

private struct AuditSectionHeader: View {
    let title: String
    let caption: String
    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            SectionLabel(title)
            Text(caption)
                .font(.footnote)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: 1 ── Cache-miss / re-sent-context dollars (the flagship)

private struct CacheMissSection: View {
    let findings: [CacheMissFinding]
    let totalLeak: Double
    let totalFirstTouch: Double
    let onSelect: (String) -> Void
    var receiptFor: ((CacheMissFinding) -> CostReceipt?)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionGap) {
            AuditSectionHeader(
                title: "Re-sent context — the leak",
                caption: "\(fmtUSD(totalLeak)) was re-sent as FRESH input above the warm-cache floor — a warm cache serves it at ~10%. That is the leak. Cache CREATION (\(fmtUSD(totalFirstTouch)) fleet-wide) is first-touch — the unavoidable cost of building cache — shown per session, never counted as leak. Cache expiry (idle, /compact, task switches) makes some re-sending unavoidable; the hit-rate column is the honest denominator. Sorted by dollars leaked.")
            if findings.isEmpty {
                LeanRow("Context is running warm — negligible re-sent-context leak.")
            } else {
                let top = max(findings.first?.leakDollars ?? 1, 0.0001)
                EvidenceColumns(leading: "Session", columns: [
                    ("rank", Theme.rankBarWidth, .leading),
                    ("cached", Theme.subValueColWidth, .trailing),
                    ("first-touch", Theme.subValueColWidth, .trailing),
                    ("leak", Theme.valueColWidth, .trailing),
                ])
                ForEach(findings) { f in
                    VStack(alignment: .leading, spacing: 2) {
                        EvidenceRow(barFraction: f.leakDollars / top) {
                            onSelect(f.id)
                        } leading: {
                            IdentityCell(project: f.project, id: f.shortID,
                                         caption: "\(fmtTokens(f.billedInput)) billed input\(f.isSubagent ? " · subagent" : "")",
                                         tier: f.tier)
                        } trailing: {
                            Text(fmtPct(f.cacheHitRate))
                                .font(.caption).foregroundStyle(Theme.muted)
                                .frame(width: Theme.subValueColWidth, alignment: .trailing)
                                .monospacedDigit()
                            Text(fmtUSD(f.firstTouchDollars))
                                .font(.caption).foregroundStyle(Theme.muted)
                                .frame(width: Theme.subValueColWidth, alignment: .trailing)
                                .monospacedDigit()
                            Text(fmtUSD(f.leakDollars))
                                .font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink)
                                .frame(width: Theme.valueColWidth, alignment: .trailing)
                                .monospacedDigit()
                        }
                        // "Show the math" (W3): the leak receipt — fresh input
                        // × (input − cacheRead) per model leg, Σ = this row.
                        if let make = receiptFor, let receipt = make(f) {
                            ReceiptDisclosure(storageKey: nil) { receipt }
                                .padding(.leading, 8)
                        }
                    }
                }
            }
        }
    }
}

// MARK: 2 ── Dead-skill ledger + prompt tax

private struct SkillLedgerSection: View {
    let ledger: SkillLedger
    let artifactPaths: [String: String]
    let onReveal: (String) -> Void

    private var perSessionTax: Double {
        Double(ledger.deadPromptTaxTokens) / 1_000_000
            * (ModelTier.sonnet.rates.inp * 0.10)
    }

    private var totalTax: Double {
        perSessionTax * Double(ledger.sessionCount)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionGap) {
            AuditSectionHeader(
                title: "Skill ledger — dead weight + prompt tax",
                caption: "\(ledger.deadCount) of \(ledger.catalogCount) catalog skills have never explicit-fired. Their descriptions ride every session's system prompt: \(String(format: "$%.4f/session", perSessionTax)) · \(String(format: "$%.2f", totalTax)) across \(fmtGrouped(ledger.sessionCount)) scanned sessions at Sonnet cache-read rates. \(ledger.distinctFired) distinct skills ever fired (explicit Skill-tool calls + slash commands; auto-loaded skills still uncounted).")

            HStack(alignment: .top, spacing: Theme.gutter) {
                firedColumn.frame(maxWidth: .infinity, alignment: .leading)
                Divider()
                deadColumn.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var firedColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            ColumnLabel("Explicit invocations")
            if ledger.fired.isEmpty {
                LeanRow("No explicit skill invocations recorded (Skill tool or slash command).")
            } else {
                ForEach(ledger.fired.prefix(8)) { e in
                    HoverRow(action: { onReveal(artifactPath(for: e)) }) {
                      HStack(spacing: 8) {
                        Text(e.name)
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(Theme.ink).lineLimit(1)
                        if !e.inCatalog {
                            Text("ext")
                                .font(.caption2).foregroundStyle(Theme.faint)
                        }
                        Spacer(minLength: 6)
                        Text(e.lastFired.map { fmtAgo($0) } ?? "—")
                            .font(.caption2).foregroundStyle(Theme.faint)
                            .frame(width: 60, alignment: .trailing)
                        Text("×\(e.invocations)")
                            .font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink)
                            .frame(width: Theme.microColWidth, alignment: .trailing)
                            .monospacedDigit()
                      }
                      .padding(.horizontal, 6)
                      .padding(.vertical, 3)
                      .contentShape(Rectangle())
                      .overlay(alignment: .top) { Divider() }
                    }
                }
            }
        }
    }

    private var deadColumn: some View {
        // Ranked evidence always shows the bar (UI_GRIND AUD-2/§2.2): "most
        // expensive first" is the claim, so the denominator is made visible — the
        // same shape Ledger L-002 gives the identical data. The count lives in the
        // section caption ("95 of 110…"), never as a floating amber numeral (AUD-3).
        VStack(alignment: .leading, spacing: 6) {
            ColumnLabel("Dead weight — never fired")
            if ledger.dead.isEmpty {
                LeanRow("Every catalog skill has fired at least once.")
            } else {
                let top = max(ledger.dead.map(\.descriptionTokens).max() ?? 1, 1)
                ForEach(ledger.dead.prefix(10)) { e in
                    HoverRow(action: { onReveal(artifactPath(for: e)) }) {
                      HStack(spacing: 8) {
                        Text(e.name)
                            .font(.system(.subheadline, design: .monospaced))
                            .foregroundStyle(Theme.muted).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        CapsuleBar(fraction: Double(e.descriptionTokens) / Double(top))
                            .frame(width: Theme.rankBarWidth)
                        Text("≈\(fmtTokens(e.descriptionTokens)) tok")
                            .font(.caption2).foregroundStyle(Theme.faint)
                            .frame(width: 74, alignment: .trailing)
                            .monospacedDigit()
                      }
                      .padding(.horizontal, 6)
                      .padding(.vertical, 3)
                      .contentShape(Rectangle())
                      .overlay(alignment: .top) { Divider() }
                    }
                }
                if ledger.dead.count > 10 {
                    Text("+\(ledger.dead.count - 10) more never-fired — archive candidates (the app never edits ~/.claude).")
                        .font(.caption2).foregroundStyle(Theme.faint)
                        .padding(.top, 2)
                }
            }
        }
    }

    private func artifactPath(for entry: SkillLedgerEntry) -> String {
        if let path = artifactPaths[entry.name] { return path }
        let base = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".claude/skills", isDirectory: true)
        let directorySkill = base.appendingPathComponent(entry.name, isDirectory: true)
            .appendingPathComponent("SKILL.md")
        if FileManager.default.fileExists(atPath: directorySkill.path) {
            return directorySkill.path
        }
        let fileSkill = base.appendingPathComponent(entry.name).appendingPathExtension("md")
        if FileManager.default.fileExists(atPath: fileSkill.path) { return fileSkill.path }
        return base.path
    }
}

// MARK: 3 ── Model-mismatch review candidates

private struct MismatchSection: View {
    let candidates: [MismatchCandidate]
    let total: Double
    let onSelect: (String) -> Void
    var receiptFor: ((MismatchCandidate) -> CostReceipt?)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionGap) {
            AuditSectionHeader(
                title: "Model-mismatch — review candidates",
                caption: "Heuristic, not a verdict: frontier sessions whose shape (few messages, no Agent fan-out) looks like cheaper-model work. Est. overspend = the FRONTIER (Opus) legs repriced at the date-aware Sonnet rate — legs already at or below Sonnet are never counted. Evidence to review — right-sizing is a per-task judgment.")
            if candidates.isEmpty {
                LeanRow("No frontier sessions look obviously right-sizable — routing looks lean.")
            } else {
                EvidenceColumns(leading: "Session (ran on frontier)", columns: [
                    ("rank", Theme.rankBarWidth, .leading),
                    ("billed", Theme.subValueColWidth, .trailing),
                    ("overspend", Theme.valueColWidth, .trailing),
                ])
                ForEach(candidates) { c in
                    let top = max(candidates.first?.estOverspend ?? 1, 0.0001)
                    VStack(alignment: .leading, spacing: 2) {
                        EvidenceRow(barFraction: c.estOverspend / top) {
                            onSelect(c.id)
                        } leading: {
                            IdentityCell(project: c.project, id: c.shortID,
                                         caption: "\(c.messageCount) msgs · \(c.fileEdits) edit\(c.fileEdits == 1 ? "" : "s") · \(c.agentCalls) agent\(c.agentCalls == 1 ? "" : "s")",
                                         tier: c.tier)
                        } trailing: {
                            Text(fmtUSD(c.cost))
                                .font(.caption).foregroundStyle(Theme.muted)
                                .frame(width: Theme.subValueColWidth, alignment: .trailing)
                                .monospacedDigit()
                            Text("≈\(fmtUSD(c.estOverspend))")
                                .font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink)
                                .frame(width: Theme.valueColWidth, alignment: .trailing)
                                .monospacedDigit()
                        }
                        // "Show the math" (W3): the overspend receipt — actual
                        // vs Sonnet-repriced per frontier leg, Σ = this row.
                        if let make = receiptFor, let receipt = make(c) {
                            ReceiptDisclosure(storageKey: nil) { receipt }
                                .padding(.leading, 8)
                        }
                    }
                }
            }
        }
    }
}
