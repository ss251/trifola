import SwiftUI
import AppKit
import TrifolaKit

// MARK: - THE DREAMING LEDGER screen (v1 · Lessons)
// The capstone. The AUDIT screen shows FINDINGS; the Ledger turns each into an
// approvable CANDIDATE FIX — a copy-able edit or a Reveal action the human takes.
// The card grammar makes the transformation obvious: evidence (numbers + click
// through, the audit's own grammar) → the candidate fix (diff-styled, copy-able) →
// approve/copy/keep/dismiss. Pure content view (data + callbacks) so the real
// cards rasterize headlessly via `--render-ledger`. The app NEVER writes ~/.claude;
// [Copy] puts the edit on the clipboard and the human pastes it.

struct LedgerScreen: View {
    @EnvironmentObject var services: AppServices
    @State private var feedback: String? = nil
    @State private var showHistory = false

    private var store: LedgerStore { services.ledger }

    var body: some View {
        ScreenScaffold(
            title: "Dreaming Ledger",
            subtitle: "Each lesson is minted deterministically from the audit — evidence, then the exact copy-able edit you approve. Lessons flow to the clipboard; the app never writes ~/.claude.",
            epithet: "findings become fixes",
            trailing: { dreamButton }
        ) {
            LedgerContent(
                dream: store.lastDream,
                pending: store.pending,
                history: store.history,
                showHistory: $showHistory,
                onCopy: copy,
                onReveal: reveal,
                onInspect: inspect,
                onKeep: { store.keep($0) },
                onDismiss: { store.dismiss($0) }
            )
        }
        .overlay(alignment: .top) {
            if let feedback { Toast(text: feedback).padding(.top, 8) }
        }
        .animation(.snappy(duration: 0.25), value: feedback)
        .task {
            // On-launch delta pass — opening the app IS the "overnight" experience.
            services.dreamNow(trigger: .onLaunch)
        }
    }

    private var dreamButton: some View {
        DreamNowButton {
            services.dreamNow(trigger: .manual)
            flash("Dreamed · \(store.pending.count) proposal\(store.pending.count == 1 ? "" : "s")")
        }
    }

    // MARK: Actions (the write path — clipboard + Finder, never ~/.claude)

    private func copy(_ lesson: Lesson) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(lesson.candidate.copyText, forType: .string)
        // Copying an edit == the human is applying it → snapshot the metric so the
        // next dream can grade whether it took.
        store.markApplied(lesson)
        flash("\(lesson.candidate.copyLabel) copied — paste it in")
    }

    private func reveal(_ path: String) {
        guard !path.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }

    private func inspect(_ path: String) {
        guard !path.isEmpty,
              let s = services.sessions.sessions.first(where: { $0.filePath == path }) else {
            // Fall back to revealing the transcript if it isn't in the live index.
            reveal(path); return
        }
        services.inspect(s)
    }

    private func flash(_ text: String) {
        feedback = text
        Task { try? await Task.sleep(for: .seconds(2.5)); feedback = nil }
    }
}

// MARK: - The screen's ONE prominent verb (POLISH C9 / UI_GRIND LDG-1)
// The namesake act, filled blue, in the header — shared by the live scaffold's
// trailing slot and `--render-ledger` (which composes it into its header row so
// the render carries the real button, not a caption-gray ghost of it).

struct DreamNowButton: View {
    var action: () -> Void = {}
    var body: some View {
        ProminentTapButton(size: .small, action: action) {
            Label("Dream now", systemImage: "sparkles")
        }
        .help("Run the deterministic pass: recompute lessons from the current audit + settings.")
    }
}

// MARK: - Pure content (renderable headlessly via --render-ledger)

struct LedgerContent: View {
    let dream: DreamResult?
    let pending: [AdjudicatedLesson]
    let history: [AdjudicatedLesson]
    @Binding var showHistory: Bool
    let onCopy: (Lesson) -> Void
    let onReveal: (String) -> Void
    let onInspect: (String) -> Void
    let onKeep: (Lesson) -> Void
    let onDismiss: (Lesson) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            DreamLine(dream: dream, proposals: pending.count)
            Divider()
            if pending.isEmpty {
                LedgerEmptyState(dream: dream)
            } else {
                ForEach(pending) { adj in
                    LessonCard(adj: adj, onCopy: onCopy, onReveal: onReveal,
                               onInspect: onInspect, onKeep: onKeep, onDismiss: onDismiss)
                }
            }
            if !history.isEmpty {
                Divider()
                AdjudicatedLedger(history: history, expanded: $showHistory)
            }
        }
    }
}

// MARK: - The dream line (header — always present, honest about triggers)

private struct DreamLine: View {
    let dream: DreamResult?
    let proposals: Int

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "moon.stars")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.muted)
            if let d = dream {
                // One reading survives (UI_GRIND LDG-5): the clock time is labeled,
                // the duration says "took", and the trigger is a noun ("manual" /
                // "on launch") — never the verb "Dream now", which read as an
                // illegible header button in the render.
                Text("Last dream \(DreamLine.time.string(from: d.ranAt))")
                    .font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink)
                Text("·").foregroundStyle(Theme.faint)
                Text("took \(d.durationMs)ms")
                    .font(.caption).foregroundStyle(Theme.faint)
                Text("·").foregroundStyle(Theme.faint)
                Text("\(fmtTokens(d.sessionsScanned)) sessions")
                    .font(.subheadline).foregroundStyle(Theme.muted)
                Text("·").foregroundStyle(Theme.faint)
                Text("\(proposals) proposal\(proposals == 1 ? "" : "s")")
                    .font(.subheadline).foregroundStyle(Theme.muted)
                Text("·").foregroundStyle(Theme.faint)
                Text(d.trigger == .manual ? "manual" : d.trigger.label)
                    .font(.caption).foregroundStyle(Theme.faint)
            } else {
                Text("Never dreamed")
                    .font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink)
                Text("— press Dream now to run the deterministic pass.")
                    .font(.subheadline).foregroundStyle(Theme.muted)
            }
            Spacer()
        }
    }

    static let time: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "HH:mm"; return f
    }()
}

// MARK: - Empty state (designed with pride — the trust engine)

private struct LedgerEmptyState: View {
    let dream: DreamResult?
    var body: some View {
        // The shared EmptyState (POLISH C6), keeping the pride: the green
        // checkmark.seal + 460 width + the verbatim copy that IS the trust engine.
        EmptyState(
            icon: "checkmark.seal",
            title: "Workflow is lean — nothing to distill.",
            detail: dream.map {
                "Dreamed over \(fmtTokens($0.sessionsScanned)) sessions — no finding crossed the threshold worth proposing. A ledger that mostly says nothing is believed the day it says something."
            } ?? "Press Dream now to mine the audit findings into candidate fixes.",
            tint: Theme.green,
            maxWidth: 460)
    }
}

// MARK: - Lesson card (evidence → candidate fix → adjudicate)

struct LessonCard: View {
    let adj: AdjudicatedLesson
    let onCopy: (Lesson) -> Void
    let onReveal: (String) -> Void
    let onInspect: (String) -> Void
    let onKeep: (Lesson) -> Void
    let onDismiss: (Lesson) -> Void

    private var lesson: Lesson { adj.lesson }

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.sectionGap) {
            header
            Text(lesson.why)
                .font(.subheadline).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
            if let v = adj.verification { verificationBanner(v) }
            EvidenceTable(evidence: lesson.evidence, onReveal: onReveal, onInspect: onInspect)
            CandidateFixBlock(fix: lesson.candidate, onReveal: onReveal)
            actions
        }
        .padding(14)
        .background {
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.28))
            // The applied card's pride is carried by the capsule + the "−2 since —
            // the edit is taking" line — evidence, not chrome. A green border is a
            // colored panel by another name (POLISH C5 / UI_GRIND LDG-3).
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text(lesson.kind.code)
                .font(.system(.caption, design: .monospaced).weight(.semibold))
                .foregroundStyle(Theme.accent)
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Capsule().fill(Theme.accent.opacity(0.12)))
            Text(lesson.kind.title)
                .font(.headline).foregroundStyle(Theme.ink)
            StatusPill(status: adj.status)
            Spacer()
            Text(lesson.metricLabel)
                .font(.subheadline.weight(.semibold)).foregroundStyle(Theme.ink)
            Text(lesson.detectorVersion)
                .font(.caption2).foregroundStyle(Theme.faint)
        }
    }

    // A plain line, not a panel (POLISH C5): green already means "ok" without a
    // swatch behind it — a green panel is a nag in party dress.
    private func verificationBanner(_ text: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark")
                .font(.caption2.weight(.medium)).foregroundStyle(Theme.green)
            Text(text).font(.caption).foregroundStyle(Theme.muted)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var actions: some View {
        HStack(spacing: 8) {
            // Quiet verbs (POLISH C9 / UI_GRIND LDG-1): the screen's one prominent
            // verb is the header's Dream now — five filled Copy buttons were the
            // screen shouting five times while whispering its name.
            Button { onCopy(lesson) } label: {
                Label(lesson.candidate.copyLabel, systemImage: "doc.on.doc")
            }
            .buttonStyle(.bordered).controlSize(.small)
            if let first = lesson.candidate.revealTargets.first {
                Button { onReveal(first.path) } label: {
                    Label("Reveal target", systemImage: "folder")
                }
                .buttonStyle(.bordered).controlSize(.small)
            }
            Spacer()
            Button { onKeep(lesson) } label: { Text("Keep") }
                .buttonStyle(.bordered).controlSize(.small)
            Button { onDismiss(lesson) } label: { Text("Dismiss") }
                .buttonStyle(.bordered).controlSize(.small)
        }
    }
}

// MARK: - Status pill

private struct StatusPill: View {
    let status: LessonStatus
    var body: some View {
        if status == .pending { EmptyView() } else {
            Text(text).font(.caption2.weight(.medium))
                .foregroundStyle(color)
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Capsule().strokeBorder(color.opacity(0.5), lineWidth: 1))
        }
    }
    private var text: String {
        switch status {
        case .kept: return "kept"
        case .dismissed: return "dismissed"
        case .applied: return "applied"
        case .pending: return ""
        }
    }
    private var color: Color {
        switch status {
        case .applied: return Theme.green
        case .kept: return Theme.accent
        default: return Theme.muted
        }
    }
}

// MARK: - Evidence table (the audit's findings-as-evidence grammar, reused)

private struct EvidenceTable: View {
    let evidence: [LessonEvidence]
    let onReveal: (String) -> Void
    let onInspect: (String) -> Void

    var body: some View {
        // The app's tell (POLISH C1/II.B): the same canonical evidence row Audit
        // wears — identity → rank (Theme.rankBarWidth) → value → destination. ONE
        // header line per table (UI_GRIND LDG-2/§2.2): the eyebrow noun rides the
        // column row's leading label, never stacked bare above it.
        VStack(alignment: .leading, spacing: 2) {
            EvidenceColumns(leading: "Evidence — finding", columns: [
                ("rank", Theme.rankBarWidth, .leading),
                ("value", Theme.valueColWidth, .trailing),
            ], hasNavGlyph: true)
            ForEach(evidence) { e in
                EvidenceRow(barFraction: e.barFraction, navGlyph: navGlyph(e.nav),
                            reservesNavGutter: true) {
                    switch e.nav {
                    case .inspect: onInspect(e.navPath)
                    case .reveal: onReveal(e.navPath)
                    case .none: break
                    }
                } leading: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(e.label)
                            .font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink).lineLimit(1)
                        Text(e.detail)
                            .font(.caption2).foregroundStyle(Theme.faint).lineLimit(1)
                    }
                } trailing: {
                    Text(e.value)
                        .font(.subheadline.weight(.medium)).foregroundStyle(Theme.ink)
                        .frame(width: Theme.valueColWidth, alignment: .trailing)
                        .monospacedDigit()
                }
            }
        }
    }

    private func navGlyph(_ nav: EvidenceNav) -> String? {
        switch nav {
        case .reveal: return "folder"
        case .inspect: return "arrow.up.right.square"
        case .none: return nil   // gutter reserved, glyph absent (LDG-4)
        }
    }
}

// MARK: - Candidate fix block (THE flywheel — diff-styled, copy-able)

private struct CandidateFixBlock: View {
    let fix: CandidateFix
    let onReveal: (String) -> Void

    var body: some View {
        // The candidate fix is a thing you can act on → the accent CalloutPanel
        // (POLISH C5), the one licensed accent tint.
        CalloutPanel(tone: Theme.accent) {
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    Image(systemName: "wrench.and.screwdriver")
                        .font(.caption).foregroundStyle(Theme.accent)
                    Text("Candidate fix")
                        .font(.caption.weight(.semibold)).foregroundStyle(Theme.ink)
                    Spacer()
                }
                Text(fix.summary)
                    .font(.caption).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)

                // Diff hunk (before/after) when the candidate is a concrete text edit.
                if let before = fix.beforeText, let after = fix.afterText {
                    VStack(alignment: .leading, spacing: 3) {
                        DiffLine(sign: "-", text: before, color: Theme.red)
                        DiffLine(sign: "+", text: after, color: Theme.green)
                    }
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor).opacity(0.5))
                        RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 1)
                    }
                }

                // The full copy-able text — a legible, obviously-copyable monospaced block.
                Text(fix.copyText)
                    .font(.system(.caption2, design: .monospaced))
                    .foregroundStyle(Theme.ink)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background {
                        RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
                            .fill(Color(nsColor: .textBackgroundColor).opacity(0.35))
                        RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
                            .strokeBorder(Theme.hairline, lineWidth: 1)
                    }

                // Reveal targets — the app names them; you move them.
                if !fix.revealTargets.isEmpty {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(fix.revealTargets.prefix(4)) { t in
                            TapButton(action: { onReveal(t.path) }) {
                                HStack(spacing: 6) {
                                    Image(systemName: "folder").font(.caption2).foregroundStyle(Theme.muted)
                                    Text(t.label).font(.caption2).foregroundStyle(Theme.ink)
                                    Text(t.detail).font(.caption2).foregroundStyle(Theme.faint)
                                    Spacer()
                                    Image(systemName: "arrow.up.right").font(.system(size: 8)).foregroundStyle(Theme.faint)
                                }
                                .contentShape(Rectangle())
                            }
                        }
                    }
                }

                HStack(spacing: 5) {
                    Image(systemName: "info.circle").font(.system(size: 9)).foregroundStyle(Theme.faint)
                    Text(fix.note)
                        .font(.caption2).foregroundStyle(Theme.faint)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
    }
}

private struct DiffLine: View {
    let sign: String
    let text: String
    let color: Color
    var body: some View {
        HStack(alignment: .top, spacing: 6) {
            Text(sign).font(.system(.caption2, design: .monospaced).weight(.bold)).foregroundStyle(color)
            Text(text)
                .font(.system(.caption2, design: .monospaced)).foregroundStyle(Theme.ink)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Adjudicated ledger (collapsed history — audit the auditor)

private struct AdjudicatedLedger: View {
    let history: [AdjudicatedLesson]
    @Binding var expanded: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            TapButton(action: { withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() } }) {
                HStack(spacing: 6) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right").font(.caption2)
                    SectionLabel("Adjudicated ledger")
                    Text("\(history.count)").font(.footnote).foregroundStyle(Theme.muted)
                    Spacer()
                }
                .contentShape(Rectangle())
            }
            if expanded {
                ForEach(history) { adj in
                    HStack(spacing: 8) {
                        Text(adj.lesson.kind.code)
                            .font(.system(.caption2, design: .monospaced)).foregroundStyle(Theme.muted)
                            .frame(width: 44, alignment: .leading)
                        Text(adj.lesson.kind.title)
                            .font(.caption).foregroundStyle(Theme.ink).lineLimit(1)
                        StatusPill(status: adj.status)
                        Spacer()
                        if let v = adj.verification {
                            Text(v).font(.caption2).foregroundStyle(Theme.faint).lineLimit(1)
                        }
                        Text(adj.lesson.detectorVersion)
                            .font(.caption2).foregroundStyle(Theme.faint)
                    }
                    .padding(.vertical, 3)
                    .overlay(alignment: .top) { Divider() }
                }
            }
        }
    }
}
