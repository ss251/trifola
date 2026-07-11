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
            subtitle: "Ranked cost causes from recorded usage · public API-rate estimates, never your bill",
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
                        footnotes: r.footnotes + [String(format: "cache setup (5m ×1.25 · 1h ×2) = $%.2f — necessary cache-build work, not included in the fresh-vs-warm difference", s.firstTouchDollars)])
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
        VStack(alignment: .leading, spacing: Theme.blockGap) {
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
            StatTile(label: "Context re-billed above a warm cache", value: fmtUSD(report.totalLeakDollars),
                     sub: "API-rate estimate · excludes \(fmtUSD(report.totalFirstTouchDollars)) needed to build cache",
                     emphasis: .standard)
            Divider()
            StatTile(label: "Unused catalog skills", value: "\(l.deadCount)/\(l.catalogCount)",
                     sub: "never explicitly invoked · ≈\(fmtTokens(l.deadPromptTaxTokens)) prompt tokens",
                     emphasis: .supporting)
            Divider()
            StatTile(label: "Cheaper-model review candidates", value: "\(report.mismatchCount)",
                     sub: "≈\(fmtUSD(report.totalMismatchOverspend)) at API rates · heuristic",
                     emphasis: .supporting)
        }
    }
}

// MARK: - Section header + calm empty line

private struct AuditSectionHeader: View {
    let title: String
    let caption: String
    @State private var showsMethod = false

    private var summary: String {
        guard let end = caption.range(of: ". ") else { return caption }
        return String(caption[..<end.upperBound]).trimmingCharacters(in: .whitespaces)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.micro) {
            SectionLabel(title)
            Text(showsMethod ? caption : summary)
                .font(Theme.Typography.body)
                .foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            MutedDisclosureRow(label: showsMethod ? "Hide calculation" : "How this is calculated",
                               isExpanded: showsMethod) {
                showsMethod.toggle()
            }
            .frame(maxWidth: 220)
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
                title: "Context charged above the warm-cache price",
                caption: "\(fmtUSD(totalLeak)) is the API-rate difference between context billed as fresh input and the same context served from a warm cache at about 10% of the input rate. It is not money known to have left your account. The separate \(fmtUSD(totalFirstTouch)) cache-build estimate is necessary first-use work and is never included here. Idle time, /compact, and task switches can expire cache, so some re-sending is unavoidable; the cached percentage is the denominator.")
            if findings.isEmpty {
                LeanRow("Context is running warm — negligible cost above the warm-cache rate.")
            } else {
                let top = max(findings.first?.leakDollars ?? 1, 0.0001)
                EvidenceColumns(leading: "Session", columns: [
                    ("rank", Theme.rankBarWidth, .leading),
                    ("cached", Theme.subValueColWidth, .trailing),
                    ("setup", Theme.subValueColWidth, .trailing),
                    ("extra cost", Theme.valueColWidth, .trailing),
                ])
                ForEach(findings) { f in
                    VStack(alignment: .leading, spacing: 2) {
                        EvidenceRow(barFraction: f.leakDollars / top) {
                            onSelect(f.id)
                        } leading: {
                            IdentityCell(project: "\(f.project) · \(f.handle)", id: f.shortID,
                                         caption: "\(fmtAgo(f.lastActivity)) · \(fmtTokens(f.billedInput)) billed input tokens\(f.isSubagent ? " · subagent" : "")",
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
                                .padding(.leading, Theme.intraCell)
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
    @State private var showsAllDead = false

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
                title: "Skill catalog — used versus never explicitly invoked",
                caption: "\(ledger.deadCount) of \(ledger.catalogCount) catalog skills have no recorded Skill-tool or slash-command invocation. Their descriptions still enter each session prompt: about \(String(format: "$%.4f/session", perSessionTax)) and \(String(format: "$%.2f", totalTax)) across \(fmtGrouped(ledger.sessionCount)) scanned sessions at Sonnet cache-read API rates. Auto-loaded skills are not observable here, so this is a review list, not proof that a skill is useless.")

            ArtifactPill(icon: "folder", name: "Skill catalog", help: "Reveal ~/.claude/skills in Finder") {
                onReveal(FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent(".claude/skills", isDirectory: true).path)
            }

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
                            .font(.subheadline)
                            .foregroundStyle(Theme.ink).lineLimit(1)
                        if !e.inCatalog {
                            Text("ext")
                                .font(.caption2).foregroundStyle(Theme.faint)
                        }
                        Spacer(minLength: 6)
                        Text(e.lastFired.map { fmtAgo($0) } ?? "—")
                            .font(.caption2).foregroundStyle(Theme.muted)
                            .frame(width: 60, alignment: .trailing)
                        Text("×\(e.invocations)")
                            .font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink)
                            .frame(width: Theme.microColWidth, alignment: .trailing)
                            .monospacedDigit()
                      }
                      .padding(.horizontal, Theme.rhythm)
                      .padding(.vertical, Theme.rhythm / 2)
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
            ColumnLabel("Unused — never explicitly invoked")
            if ledger.dead.isEmpty {
                LeanRow("Every catalog skill has fired at least once.")
            } else {
                let top = max(ledger.dead.map(\.descriptionTokens).max() ?? 1, 1)
                ForEach(showsAllDead ? ledger.dead : Array(ledger.dead.prefix(10))) { e in
                    HoverRow(action: { onReveal(artifactPath(for: e)) }) {
                      HStack(spacing: 8) {
                        Text(e.name)
                            .font(.subheadline)
                            .foregroundStyle(Theme.muted).lineLimit(1)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        CapsuleBar(fraction: Double(e.descriptionTokens) / Double(top))
                            .frame(width: Theme.rankBarWidth)
                        Text("≈\(fmtTokens(e.descriptionTokens)) prompt tokens")
                            .font(.caption2).foregroundStyle(Theme.muted)
                            .frame(width: Theme.rankBarWidth, alignment: .trailing)
                            .monospacedDigit()
                      }
                      .padding(.horizontal, Theme.rhythm)
                      .padding(.vertical, Theme.rhythm / 2)
                      .contentShape(Rectangle())
                      .overlay(alignment: .top) { Divider() }
                    }
                }
                if ledger.dead.count > 10 {
                    MutedDisclosureRow(
                        label: showsAllDead
                            ? "Show only the first 10 · the app never edits ~/.claude"
                            : "+\(ledger.dead.count - 10) more never explicitly invoked — archive candidates (the app never edits ~/.claude)",
                        isExpanded: showsAllDead) {
                            showsAllDead.toggle()
                        }
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
                title: "Sessions that may fit a cheaper model",
                caption: "Heuristic, not a verdict: these frontier-model sessions had few messages and no Agent fan-out. The estimate reprices only their Opus usage at the date-aware Sonnet API rate; usage already at or below Sonnet is excluded. Review the transcript before changing routing — task difficulty is not visible from counts alone.")
            if candidates.isEmpty {
                LeanRow("No frontier sessions look obviously right-sizable — routing looks lean.")
            } else {
                EvidenceColumns(leading: "Session (ran on frontier)", columns: [
                    ("rank", Theme.rankBarWidth, .leading),
                    ("API price", Theme.subValueColWidth, .trailing),
                    ("price diff", Theme.valueColWidth, .trailing),
                ])
                ForEach(candidates) { c in
                    let top = max(candidates.first?.estOverspend ?? 1, 0.0001)
                    VStack(alignment: .leading, spacing: 2) {
                        EvidenceRow(barFraction: c.estOverspend / top) {
                            onSelect(c.id)
                        } leading: {
                            IdentityCell(project: "\(c.project) · \(c.handle)", id: c.shortID,
                                         caption: "\(fmtAgo(c.lastActivity)) · \(c.messageCount) messages · \(c.fileEdits) edit\(c.fileEdits == 1 ? "" : "s") · \(c.agentCalls) agent\(c.agentCalls == 1 ? "" : "s")",
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
                                .padding(.leading, Theme.intraCell)
                        }
                    }
                }
            }
        }
    }
}
