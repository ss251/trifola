import SwiftUI
import AppKit
import TrifolaKit

/// Live transcript feed. Owns a TranscriptStore, tails the
/// session's .jsonl via DispatchSource and auto-follows the bottom unless the
/// user scrolls up (a "jump to live" pill appears).
///
/// Human narration is proportional; only commands, paths and tool output use
/// monospaced type. Colors stay monochrome except error red.
struct TranscriptView: View {
    let filePath: String
    var provider: Provider = .claude
    var tailBytes: UInt64 = 2_000_000
    var isPaused = false
    /// Deterministic events for headless visual verification. Production leaves
    /// this nil and keeps the exact tailing behavior below.
    var previewEvents: [TranscriptEvent]? = nil

    @StateObject private var store = TranscriptStore()
    @State private var pinnedToLive = true
    /// Live geometry: is the viewport within the re-pin margin of the bottom?
    /// Feeds pinning decisions but NEVER unpins by itself — content growth moves
    /// the bottom away from an unmoved viewport, and treating that as "the user
    /// scrolled up" was the bug that made every event burst detach the tail
    /// (the "jump to live" fatigue).
    @State private var atBottom = true
    /// Current scroll phase — auto-follow only scrolls when the user isn't
    /// mid-gesture, so the tail never fights a finger.
    @State private var scrollPhase: ScrollPhase = .idle

    private static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    private var events: [TranscriptEvent] { previewEvents ?? store.events }

    /// Hoisted out of `body`: a `+`-chained String expression inside the
    /// modifier chain made Swift 6.1's type-checker time out ("unable to
    /// type-check this expression in reasonable time") — 6.3 accepts it, CI's
    /// toolchain does not. Interpolation in a typed property checks instantly
    /// on both.
    private var tailingIdentity: String {
        "\(provider.rawValue)\u{1}\(filePath)\u{1}\(isPaused)"
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            feed
        }
        .background {
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .fill(Theme.cardFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.radiusCard, style: .continuous))
        .task(id: tailingIdentity) {
            guard previewEvents == nil else { return }
            guard !isPaused else {
                store.close()
                return
            }
            // Opening/tailing is progressive live content. Give the inspector's
            // ready chrome one committed draw before a fast 2 MB tail publishes
            // up to 2,500 rows and triggers a second scroll layout.
            try? await Task.sleep(for: .milliseconds(200))
            guard !Task.isCancelled else { return }
            pinnedToLive = true
            store.open(path: filePath, provider: provider, tailBytes: tailBytes)
        }
        .onDisappear {
            if previewEvents == nil { store.close() }
        }
    }

    private var header: some View {
        HStack(spacing: 6) {
            if previewEvents != nil {
                Text(provider == .codex ? "Codex rollout"
                     : provider == .grok ? "Grok session" : "Tailing")
                    .font(.caption).foregroundStyle(Theme.green)
            } else {
                switch store.state {
                case .live:
                    Text(provider == .codex ? "Codex rollout"
                         : provider == .grok ? "Grok session" : "Tailing")
                        .font(.caption).foregroundStyle(Theme.green)
                case .idle:
                    Text("Opening").font(.caption).foregroundStyle(Theme.muted)
                case .error(let why):
                    Text(why).font(.caption).foregroundStyle(Theme.red).lineLimit(1)
                }
            }
            if store.startedMidFile || store.droppedHead {
                Text("· tail of file")
                    .font(.caption2).foregroundStyle(Theme.muted)
            }
            Spacer()
            if !filePath.isEmpty {
                ArtifactPill(icon: "doc.text", name: "Transcript", help: filePath) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: filePath)])
                }
            }
            Text("\(events.count) events")
                .font(.caption2).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, Theme.codePadding)
        .padding(.vertical, Theme.rhythm)
    }

    @ViewBuilder
    private var feed: some View {
        if previewEvents != nil {
            // ImageRenderer does not realize scroll/lazy children. The bounded
            // preview keeps the production TranscriptRow hierarchy but lays it
            // out eagerly, while the live file-tail path below remains unchanged.
            VStack(alignment: .leading, spacing: 8) {
                ForEach(events) { event in
                    TranscriptRow(event: event, provider: provider)
                        .transcriptLineTransition()
                }
                Spacer(minLength: 0)
            }
            .padding(Theme.codePadding)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            liveFeed
        }
    }

    private var liveFeed: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(events) { event in
                        TranscriptRow(event: event, provider: provider)
                            .transcriptLineTransition()
                    }
                    Color.clear.frame(height: 1).id("live-bottom")
                }
                .padding(Theme.codePadding)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollIndicators(.never)
            .onScrollGeometryChange(for: Bool.self) { geo in
                geo.contentOffset.y + geo.containerSize.height >= geo.contentSize.height - 60
            } action: { _, isAtBottom in
                atBottom = isAtBottom     // geometry informs; only gestures decide
            }
            .onScrollPhaseChange { _, newPhase in
                scrollPhase = newPhase
                // The tail -f contract: pinning changes ONLY when a user gesture
                // settles. Scroll up → detached (pill appears). Scroll back to the
                // bottom → re-pinned, no pill click needed. Programmatic scrolls
                // (.animating) and content growth can never detach.
                if newPhase == .idle { pinnedToLive = atBottom }
            }
            .onChange(of: events.count) {
                guard pinnedToLive, scrollPhase == .idle || scrollPhase == .animating else { return }
                proxy.scrollTo("live-bottom", anchor: .bottom)
            }
            .onChange(of: store.state) {
                guard pinnedToLive else { return }   // a state blip must not yank a reader down
                proxy.scrollTo("live-bottom", anchor: .bottom)
            }
            .overlay(alignment: .bottom) {
                if !pinnedToLive {
                    ProminentTapButton(size: .small, action: {
                        pinnedToLive = true
                        proxy.scrollTo("live-bottom", anchor: .bottom)
                    }) {
                        Label("Jump to live", systemImage: "arrow.down.to.line")
                    }
                    .padding(.bottom, Theme.sectionGap)
                    .motionTransition(edge: .bottom)
                }
            }
            .motion(Theme.Motion.move, value: pinnedToLive)
        }
    }
}

// MARK: - One event row
// Monochrome cascade: primary for what people typed/said, secondary for tool
// machinery, tertiary for system noise. Red only for errors.

private struct TranscriptRow: View {
    let event: TranscriptEvent
    let provider: Provider

    private static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }

    var body: some View {
        HStack(alignment: .top, spacing: 9) {
            gutter
                .frame(width: 74, alignment: .trailing)
            body_
                .frame(maxWidth: .infinity, alignment: .leading)
        }
        .opacity(event.isSidechain ? 0.55 : 1)
    }

    private var gutter: some View {
        VStack(alignment: .trailing, spacing: 2) {
            Text(roleTag)
                .font(.caption2.weight(.medium))
                .foregroundStyle(roleColor)
            if let ts = event.timestamp {
                Text(ts.formatted(date: .omitted, time: .standard))
                    .font(.caption2)
                    .foregroundStyle(Theme.faint)
            }
        }
    }

    private var roleTag: String {
        switch event.kind {
        case .userPrompt: return "USER"
        case .assistantText:
            switch provider {
            case .claude: return "CLAUDE"
            case .codex: return "CODEX"
            case .grok: return "GROK"
            }
        case .thinking: return "THINK"
        case .toolUse: return "TOOL"
        case .toolResult(_, let isError): return isError ? "ERR" : "RESULT"
        case .system(let subtype, _): return subtype.uppercased()
        case .summary: return "SUMMARY"
        }
    }

    private var roleColor: Color {
        switch event.kind {
        case .userPrompt: return Theme.ink
        case .assistantText: return Theme.muted
        case .thinking: return Theme.faint
        case .toolUse: return Theme.muted
        case .toolResult(_, let isError): return isError ? Theme.red : Theme.faint
        case .system: return Theme.faint
        case .summary: return Theme.muted
        }
    }

    @ViewBuilder
    private var body_: some View {
        switch event.kind {
        case .userPrompt(let text):
            Text("“\(text)”")
                .font(.footnote)
                .foregroundStyle(Theme.muted)
                .lineLimit(6)
                .textSelection(.enabled)
        case .assistantText(let text):
            transcriptText(text, plainFont: .footnote, color: Theme.ink, lineLimit: 8)
        case .thinking(let text):
            Text(text)
                .font(.footnote)
                .italic()
                .foregroundStyle(Theme.faint)
                .lineLimit(3)
        case .toolUse(let name, let detail):
            (Text(name).font(Self.mono(11, .semibold)).foregroundStyle(Theme.ink)
             + Text(detail.isEmpty ? "" : "  \(detail)")
                .font(.caption).foregroundStyle(Theme.muted))
                .lineLimit(3)
                .textSelection(.enabled)
        case .toolResult(let preview, let isError):
            transcriptText(preview, plainFont: .caption, color: Theme.muted, lineLimit: 4)
                .padding(.leading, Theme.intraCell)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(isError ? Theme.red.opacity(0.5) : Theme.hairline)
                        .frame(width: 2)
                }
        case .system(_, let text):
            transcriptText(
                text,
                plainFont: .caption,
                color: Theme.faint,
                structuredColor: Theme.muted,
                lineLimit: 2)
        case .summary(let text):
            Text(text)
                .font(.footnote)
                .italic()
                .foregroundStyle(Theme.muted)
                .lineLimit(2)
        }
    }

    @ViewBuilder
    private func transcriptText(
        _ text: String,
        plainFont: Font,
        color: Color,
        structuredColor: Color? = nil,
        lineLimit: Int
    ) -> some View {
        switch event.textPresentation {
        case .plain:
            Text(text)
                .font(plainFont)
                .foregroundStyle(color)
                .lineLimit(lineLimit)
                .textSelection(.enabled)
        case .structured(let presentation):
            StructuredTranscriptBlock(
                rawText: text,
                presentation: presentation,
                contentColor: structuredColor ?? color)
        }
    }
}

/// Renders precomputed whole lines. Markup-only lines recede, indentation guides
/// preserve nested structure, and Raw remains one click away without reparsing.
private struct StructuredTranscriptBlock: View {
    let rawText: String
    let presentation: StructuredTranscriptPresentation
    let contentColor: Color

    @State private var showsRaw = false

    private static let guideStep: CGFloat = 11

    var body: some View {
        VStack(alignment: .leading, spacing: Theme.micro) {
            HStack(spacing: Theme.rhythm) {
                Text(presentation.format.label)
                    .font(.caption2.weight(.medium))
                    .foregroundStyle(Theme.muted)
                if presentation.didTruncate && !showsRaw {
                    Text("bounded preview")
                        .font(.caption2)
                        .foregroundStyle(Theme.faint)
                }
                Spacer(minLength: Theme.rhythm)
                TapButton(focusVisual: .capsule, pressFeedback: false, action: {
                    showsRaw.toggle()
                }) {
                    Text(showsRaw ? "Readable" : "Raw")
                        .font(.caption2.weight(.medium))
                        .foregroundStyle(Theme.muted)
                        .padding(.horizontal, Theme.rhythm)
                        .padding(.vertical, Theme.micro)
                        .background {
                            Capsule().fill(Theme.hoverFill)
                        }
                }
                .accessibilityLabel(showsRaw ? "Show readable text" : "Show raw text")
            }

            if showsRaw {
                Text(rawText)
                    .font(.system(size: 10.5, design: .monospaced))
                    .foregroundStyle(contentColor)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            } else {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(presentation.lines) { line in
                        readableLine(line)
                    }
                }
            }
        }
        .padding(Theme.rhythm)
        .frame(maxWidth: Theme.Layout.transcriptMeasure, alignment: .leading)
        .background {
            RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
                .fill(Theme.codeFill)
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radiusRow, style: .continuous)
                .strokeBorder(Theme.cardStroke, lineWidth: 1)
        }
    }

    private func readableLine(_ line: StructuredTranscriptPresentation.Line) -> some View {
        Text(line.text.isEmpty ? " " : line.text)
            .font(.system(
                size: 10.5,
                weight: line.role == .addition ? .medium : .regular,
                design: .monospaced))
            .foregroundStyle(lineColor(line.role))
            .lineLimit(4)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.leading, CGFloat(line.depth) * Self.guideStep)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(alignment: .leading) {
                HStack(spacing: Self.guideStep - 1) {
                    ForEach(0..<line.depth, id: \.self) { _ in
                        Rectangle()
                            .fill(Theme.hairline)
                            .frame(width: 1)
                    }
                }
            }
            .textSelection(.enabled)
    }

    private func lineColor(_ role: StructuredTranscriptPresentation.Line.Role) -> Color {
        switch role {
        case .markup: return Theme.faint
        case .content, .addition: return contentColor
        case .removal: return Theme.muted
        }
    }
}
