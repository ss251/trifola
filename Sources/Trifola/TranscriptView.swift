import SwiftUI
import TrifolaKit

/// Terminal-style live transcript feed. Owns a TranscriptStore, tails the
/// session's .jsonl via DispatchSource and auto-follows the bottom unless the
/// user scrolls up (a "jump to live" pill appears).
///
/// Log content is the one place monospaced is allowed — it's content, not
/// chrome (Console.app precedent). Colors stay monochrome except error red.
struct TranscriptView: View {
    let filePath: String
    var tailBytes: UInt64 = 2_000_000

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

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            feed
        }
        .background {
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .fill(Color(nsColor: .textBackgroundColor).opacity(0.5))
        }
        .overlay {
            RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                .strokeBorder(Theme.hairline, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .task(id: filePath) {
            pinnedToLive = true
            store.open(path: filePath, tailBytes: tailBytes)
        }
        .onDisappear { store.close() }
    }

    private var header: some View {
        HStack(spacing: 6) {
            switch store.state {
            case .live:
                SeatMark(fill: Theme.green, size: 6)
                Text("Tailing").font(.caption).foregroundStyle(Theme.muted)
            case .idle:
                SeatMark(fill: Theme.faint, size: 6, active: false)
                Text("Opening").font(.caption).foregroundStyle(Theme.muted)
            case .error(let why):
                SeatMark(fill: Theme.red, size: 6, active: false)
                Text(why).font(.caption).foregroundStyle(Theme.red).lineLimit(1)
            }
            if store.startedMidFile || store.droppedHead {
                Text("· tail of file")
                    .font(.caption2).foregroundStyle(Theme.faint)
            }
            Spacer()
            Text("\(store.events.count) events")
                .font(.caption2).foregroundStyle(Theme.faint)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
    }

    private var feed: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 8) {
                    ForEach(store.events) { ev in
                        TranscriptRow(event: ev)
                    }
                    Color.clear.frame(height: 1).id("live-bottom")
                }
                .padding(10)
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
            .onChange(of: store.events.count) {
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
                        withAnimation(.snappy(duration: 0.25)) {
                            proxy.scrollTo("live-bottom", anchor: .bottom)
                        }
                    }) {
                        Label("Jump to live", systemImage: "arrow.down.to.line")
                    }
                    .padding(.bottom, 12)
                    .motionTransition(edge: .bottom)
                }
            }
            .animation(.easeOut(duration: 0.18), value: pinnedToLive)
        }
    }
}

// MARK: - One event row
// Monochrome cascade: primary for what people typed/said, secondary for tool
// machinery, tertiary for system noise. Red only for errors.

private struct TranscriptRow: View {
    let event: TranscriptEvent

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
                .font(Self.mono(9, .semibold))
                .foregroundStyle(roleColor)
            if let ts = event.timestamp {
                Text(ts.formatted(date: .omitted, time: .standard))
                    .font(Self.mono(8))
                    .foregroundStyle(Theme.faint)
            }
        }
    }

    private var roleTag: String {
        switch event.kind {
        case .userPrompt: return "USER"
        case .assistantText: return "CLAUDE"
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
            Text(text)
                .font(Self.mono(11, .medium))
                .foregroundStyle(Theme.ink)
                .lineLimit(6)
                .textSelection(.enabled)
        case .assistantText(let text):
            Text(text)
                .font(Self.mono(11))
                .foregroundStyle(Theme.ink)
                .lineLimit(8)
                .textSelection(.enabled)
        case .thinking(let text):
            Text(text)
                .font(Self.mono(10.5))
                .italic()
                .foregroundStyle(Theme.faint)
                .lineLimit(3)
        case .toolUse(let name, let detail):
            (Text(name).font(Self.mono(11, .semibold)).foregroundStyle(Theme.ink)
             + Text(detail.isEmpty ? "" : "  \(detail)")
                .font(Self.mono(10.5)).foregroundStyle(Theme.muted))
                .lineLimit(3)
                .textSelection(.enabled)
        case .toolResult(let preview, let isError):
            Text(preview)
                .font(Self.mono(10.5))
                .foregroundStyle(isError ? Theme.red : Theme.muted)
                .lineLimit(4)
                .padding(.leading, 8)
                .overlay(alignment: .leading) {
                    Rectangle()
                        .fill(isError ? Theme.red.opacity(0.5) : Theme.hairline)
                        .frame(width: 2)
                }
        case .system(_, let text):
            Text(text)
                .font(Self.mono(10))
                .foregroundStyle(Theme.faint)
                .lineLimit(2)
        case .summary(let text):
            Text(text)
                .font(.footnote)
                .italic()
                .foregroundStyle(Theme.muted)
                .lineLimit(2)
        }
    }
}
