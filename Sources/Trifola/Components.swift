import SwiftUI
import TrifolaKit

// MARK: - Section header
// CodexBar-style: system body weight-medium, primary label. No uppercase, no
// tracking, no color.

struct SectionLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.body.weight(.medium))
            .foregroundStyle(Theme.ink)
    }
}

/// Sub-header hierarchy, exactly three levels (POLISH C3), all lowercase-as-written,
/// no tracking. Level 1 = `SectionLabel` (section titles). Level 2 = `ColumnLabel`
/// (sub-columns inside a section). Level 3 = `Eyebrow` (table eyebrows + column
/// captions). Any literal recreation of these fonts is drift — use these.

struct ColumnLabel: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.footnote.weight(.medium))
            .foregroundStyle(Theme.ink)
    }
}

struct Eyebrow: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text)
            .font(.caption.weight(.medium))
            .foregroundStyle(Theme.faint)
    }
}

// MARK: - Status dot
// A plain filled circle — no glow, no shadow, no pulse ring. The color IS the
// signal (CodexBar status-dot discipline). An optional 1pt ring carries a second
// variable (the model tier) — the same encoding the Fleet seat token uses, so
// every session dot in the app is the same object at every density (POLISH C10).

struct StatusDot: View {
    var color: Color = Theme.green
    var size: CGFloat = 7
    var active = true
    var ring: Color? = nil

    var body: some View {
        Circle()
            .fill(color.opacity(active ? 1 : 0.45))
            .frame(width: size, height: size)
            .overlay {
                if let ring { Circle().strokeBorder(ring.opacity(0.9), lineWidth: 1) }
            }
    }
}

// MARK: - The door light — the app's identity mark (SwiftUI path)
// The signature (POLISH II.A): a filled center + a concentric 1pt ring — the
// session dot with its tier ring, the app's own telemetry atom promoted to its
// face. One circle, one ring, nothing else. Two renderings, both honest: a filled
// dot with a rim (the live seat token, on the Floor + chips) and a haloed
// dot-in-ring (`gapped` — the lockup, matching the dock/menu-bar geometry). The
// dock icon + template menu glyph share the AppKit path in `AppBrand.markImage`.

struct SeatMark: View {
    var fill: Color
    var ring: Color
    var size: CGFloat = 7
    /// When false the center is hollow (the menu-bar "quiet" rendering has none).
    var filled: Bool = true
    var ringWidth: CGFloat = 1
    /// Gapped = a haloed dot-in-ring (the wordmark/logo rendering). Non-gapped = a
    /// filled dot with a concentric rim (the live seat token — unchanged).
    var gapped: Bool = false

    var body: some View {
        if gapped {
            ZStack {
                Circle().strokeBorder(ring, lineWidth: ringWidth)
                if filled {
                    Circle().fill(fill)
                        .frame(width: size * 0.42, height: size * 0.42)
                }
            }
            .frame(width: size, height: size)
        } else {
            Circle()
                .fill(filled ? fill : .clear)
                .frame(width: size, height: size)
                .overlay {
                    if ringWidth > 0 { Circle().strokeBorder(ring, lineWidth: ringWidth) }
                }
        }
    }
}

// MARK: - Tier badge
// Dot in the tier hue + caption text in secondary label. No capsule, no tint.

struct TierBadge: View {
    let tier: ModelTier
    var compact = false

    var body: some View {
        HStack(spacing: 5) {
            Circle().fill(tier.color).frame(width: 6, height: 6)
            Text(tier.label)
                .font(.caption)
                .foregroundStyle(Theme.muted)
        }
    }
}

// MARK: - Machine chip (Cross-Machine Fleet)
// A tiny label — not decoration — tagging which machine a session ran on: a laptop
// glyph + "Mac" for this machine, a desktop glyph + the host name for a remote
// ("workstation"). Faint for local (the implicit default), a touch more present for a
// remote so the fleet reads at a glance. Restraint: hairline capsule, caption2, no
// tint, no fill.

struct MachineChip: View {
    let machineID: String
    var compact = false

    private var isLocal: Bool { machineID == Machine.localID }
    private var label: String { isLocal ? "Mac" : machineID }
    private var symbol: String { isLocal ? "laptopcomputer" : "desktopcomputer" }
    private var tone: Color { isLocal ? Theme.faint : Theme.muted }

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: symbol)
                .font(.caption2)
                .foregroundStyle(tone)
            if !compact {
                Text(label)
                    .font(.caption2)
                    .foregroundStyle(tone)
            }
        }
        .padding(.horizontal, compact ? 4 : 5)
        .padding(.vertical, 2)
        .background {
            Capsule().strokeBorder(Theme.hairline, lineWidth: 1)
        }
        .help(isLocal ? "This Mac" : "Mirrored read-only from \(machineID) over Tailscale")
    }
}

// MARK: - Offline indicator (calm, never a nag)
// The muted one-line status a remote surfaces when it isn't contributing:
// "workstation offline — last synced 12m ago". Absence is information; rendered calm —
// never red, never a nag (Fleet Board doctrine).

struct RemoteStatusLine: View {
    let status: RemoteStatus

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: status.isOnline ? "desktopcomputer" : "desktopcomputer.trianglebadge.exclamationmark")
                .font(.caption2)
                .foregroundStyle(status.isOnline ? Theme.muted : Theme.faint)
            Text(status.indicator)
                .font(.caption2)
                .foregroundStyle(status.isOnline ? Theme.muted : Theme.faint)
                .lineLimit(1)
        }
    }
}

// MARK: - Stat tile
// Caption label over a headline value — hierarchy from the type scale alone.
// Lives inside StatRow, which separates tiles with hairlines instead of boxes.

struct StatTile: View {
    let label: String
    let value: String
    var sub: String? = nil
    var valueColor: Color = Theme.ink
    var icon: String? = nil
    var live = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                if live { StatusDot(color: Theme.green, size: 6) }
                Text(label)
                    .font(.caption)
                    .foregroundStyle(Theme.muted)
            }
            Text(value)
                .font(.title3.weight(.semibold))
                .foregroundStyle(valueColor)
                .contentTransition(.numericText())
                .lineLimit(1)
                .minimumScaleFactor(0.6)
            if let sub {
                Text(sub)
                    .font(.caption2)
                    .foregroundStyle(Theme.faint)
                    .lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A row of stat tiles separated by 1px hairlines — the CodexBar answer to a
/// "stat card" strip.
struct StatRow<Content: View>: View {
    @ViewBuilder let content: () -> Content

    var body: some View {
        HStack(alignment: .top, spacing: Theme.sectionGap) {
            content()
        }
    }
}

// MARK: - Capsule progress bar
// The CodexBar bar: 6pt capsule, tertiary-at-22% track, flat single-color fill.

struct CapsuleBar: View {
    let fraction: Double        // 0…1
    var tint: Color = Theme.accent
    var height: CGFloat = Theme.barHeight

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Theme.progressTrack)
                if fraction > 0.004 {
                    Capsule()
                        .fill(tint)
                        .frame(width: max(height, geo.size.width * min(1, max(0, fraction))))
                }
            }
        }
        .frame(height: height)
    }
}

// MARK: - Context weight bar (the "$20 hey" gauge)

struct ContextBar: View {
    let weight: Int  // tokens resent per message
    var width: CGFloat = 72

    private var fraction: Double { min(1, Double(weight) / 400_000) }

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text(fmtTokens(weight))
                .font(.caption2)
                .foregroundStyle(Theme.muted)
            // One accent, like every other gauge — the ≈$/msg caption carries
            // the warning; a wall of red bars is decoration, not information.
            CapsuleBar(fraction: fraction, tint: Theme.accent)
                .frame(width: width)
        }
    }
}

// MARK: - Tier spend split bar
// Flat segments in the tier hues — no gradients, no shadows.

struct TierSplitBar: View {
    let stats: [TierStat]
    var height: CGFloat = Theme.barHeight

    private var total: Double { max(stats.reduce(0) { $0 + $1.cost }, 0.0001) }

    var body: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(stats) { st in
                    Capsule()
                        .fill(st.tier.color)
                        .frame(width: max(3, (geo.size.width - CGFloat(stats.count - 1) * 2) * st.cost / total))
                }
            }
        }
        .frame(height: height)
    }
}

// MARK: - Bar strip (activity histogram sparkline)

struct BarStrip: View {
    let values: [Double]   // 0…1 normalized
    var color: Color = Theme.accent
    var height: CGFloat = 34

    var body: some View {
        HStack(alignment: .bottom, spacing: 2.5) {
            ForEach(Array(values.enumerated()), id: \.offset) { _, v in
                Capsule()
                    .fill(v > 0.02 ? color.opacity(0.85) : Theme.progressTrack)
                    .frame(maxWidth: .infinity)
                    .frame(height: max(2, height * v))
            }
        }
        .frame(height: height, alignment: .bottom)
    }
}

// MARK: - Immune controls — the macOS-26 render-storm fix (do NOT regress)
// On macOS 26 Liquid Glass, a `Button` styled `.plain` or `.borderedProminent`
// — and any native `Toggle` — inside this app's scene self-oscillates SwiftUI's
// `glassEffectBackdropObserver` at ~99% CPU while the window is frontmost.
// Verified IMMUNE in this exact scene: `.bordered`, `.link`, and non-Button
// `.onTapGesture` views. These helpers are therefore the ONLY licensed
// tap/press/toggle primitives in this app. Re-introducing
// `.buttonStyle(.plain)`, `.buttonStyle(.borderedProminent)`, or `Toggle`
// brings the storm straight back (see handoffs/render-storm-fix.md).

/// The `.plain`-Button replacement: a label + tap gesture — no Button primitive,
/// so no glass control backdrop to oscillate. Accessibility still reads it as a
/// button. An optional keyboard shortcut is carried by a hidden zero-size
/// `.link`-styled Button (verified immune) so ⌘-shortcuts keep working.
struct TapButton<Label: View>: View {
    var shortcut: KeyboardShortcut? = nil
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @Environment(\.isEnabled) private var isEnabled

    init(shortcut: KeyboardShortcut? = nil,
         action: @escaping () -> Void,
         @ViewBuilder label: @escaping () -> Label) {
        self.shortcut = shortcut
        self.action = action
        self.label = label
    }

    var body: some View {
        label()
            .contentShape(Rectangle())
            .onTapGesture { if isEnabled { action() } }
            .background {
                if let shortcut {
                    Button("", action: action)
                        .buttonStyle(.link)          // verified immune
                        .keyboardShortcut(shortcut)
                        .opacity(0)
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityAddTraits(.isButton)
    }
}

extension TapButton where Label == Text {
    init(_ title: String, shortcut: KeyboardShortcut? = nil,
         action: @escaping () -> Void) {
        self.init(shortcut: shortcut, action: action) { Text(title) }
    }
}

/// The `.borderedProminent` replacement: the accent-filled capsule, white
/// label, hover brightening — drawn with shapes, no Button primitive.
struct ProminentTapButton<Label: View>: View {
    enum Size { case small, regular, large }
    var size: Size = .regular
    var tint: Color = .accentColor
    var shortcut: KeyboardShortcut? = nil
    let action: () -> Void
    @ViewBuilder let label: () -> Label
    @Environment(\.isEnabled) private var isEnabled
    @State private var hovering = false

    init(size: Size = .regular, tint: Color = .accentColor,
         shortcut: KeyboardShortcut? = nil,
         action: @escaping () -> Void,
         @ViewBuilder label: @escaping () -> Label) {
        self.size = size
        self.tint = tint
        self.shortcut = shortcut
        self.action = action
        self.label = label
    }

    private var font: Font {
        switch size {
        case .small: return .caption.weight(.medium)
        case .regular: return .body.weight(.medium)
        case .large: return .body.weight(.semibold)
        }
    }
    private var hPad: CGFloat { size == .small ? 8 : (size == .large ? 16 : 11) }
    private var vPad: CGFloat { size == .small ? 3 : (size == .large ? 8 : 5) }

    var body: some View {
        label()
            .font(font)
            .foregroundStyle(.white)
            .padding(.horizontal, hPad)
            .padding(.vertical, vPad)
            .background(Capsule().fill(tint))
            .brightness(hovering && isEnabled ? 0.06 : 0)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Capsule())
            .onTapGesture { if isEnabled { action() } }
            .onHover { h in hovering = h }
            .background {
                if let shortcut {
                    Button("", action: action)
                        .buttonStyle(.link)          // verified immune
                        .keyboardShortcut(shortcut)
                        .opacity(0)
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                }
            }
            .accessibilityAddTraits(.isButton)
    }
}

extension ProminentTapButton where Label == Text {
    init(_ title: String, size: Size = .regular, tint: Color = .accentColor,
         shortcut: KeyboardShortcut? = nil, action: @escaping () -> Void) {
        self.init(size: size, tint: tint, shortcut: shortcut, action: action) { Text(title) }
    }
}

/// The native-`Toggle` replacement (native `Toggle` has NO immune style): a
/// tappable capsule + knob drawn with shapes, matching `.switch` / `.mini`,
/// with an optional leading label like a labeled `.switch` Toggle.
struct TapToggle<L: View>: View {
    @Binding var isOn: Bool
    var mini = false
    @ViewBuilder let label: () -> L
    @Environment(\.isEnabled) private var isEnabled

    init(isOn: Binding<Bool>, mini: Bool = false,
         @ViewBuilder label: @escaping () -> L) {
        self._isOn = isOn
        self.mini = mini
        self.label = label
    }

    private var trackW: CGFloat { mini ? 26 : 38 }
    private var trackH: CGFloat { mini ? 15 : 22 }

    private var flip: () -> Void {
        { withAnimation(.easeOut(duration: 0.15)) { isOn.toggle() } }
    }

    var body: some View {
        HStack(spacing: 8) {
            label()
            ZStack(alignment: isOn ? .trailing : .leading) {
                Capsule()
                    .fill(isOn ? Color.accentColor
                               : Color(nsColor: .unemphasizedSelectedContentBackgroundColor))
                Circle()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.2), radius: 0.5, y: 0.5)
                    .padding(1.5)
            }
            .frame(width: trackW, height: trackH)
        }
        .opacity(isEnabled ? 1 : 0.5)
        .contentShape(Rectangle())
        .onTapGesture { if isEnabled { flip() } }
        .accessibilityAddTraits(.isButton)
        .accessibilityValue(isOn ? "on" : "off")
    }
}

extension TapToggle where L == EmptyView {
    init(isOn: Binding<Bool>, mini: Bool = false) {
        self.init(isOn: isOn, mini: mini) { EmptyView() }
    }
}

extension TapToggle where L == Text {
    init(_ title: String, isOn: Binding<Bool>, mini: Bool = false) {
        self.init(isOn: isOn, mini: mini) { Text(title) }
    }
}

// MARK: - Filter chip
// On: system selection color + selection text (CodexBar highlight cascade).
// Off: hairline capsule, secondary text.

struct FilterChip: View {
    let label: String
    let isOn: Bool
    let action: () -> Void

    var body: some View {
        TapButton(action: action) {
            Text(label)
                .font(.caption.weight(isOn ? .semibold : .regular))
                .foregroundStyle(isOn ? Theme.selectionText : Theme.muted)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background {
                    if isOn {
                        Capsule().fill(Theme.selectionBG)
                    } else {
                        Capsule().strokeBorder(Theme.hairline, lineWidth: 1)
                    }
                }
        }
    }
}

// MARK: - Hoverable row container
// Hover uses the system's unemphasized selection color — the native list feel.

struct HoverRow<Content: View>: View {
    var radius: CGFloat = 6
    let action: () -> Void
    @ViewBuilder let content: () -> Content
    @State private var hovering = false

    var body: some View {
        TapButton(action: action) {
            content()
        }
        .background(
            RoundedRectangle(cornerRadius: radius, style: .continuous)
                .fill(hovering
                      ? Color(nsColor: .unemphasizedSelectedContentBackgroundColor).opacity(0.6)
                      : .clear)
        )
        .onHover { h in
            withAnimation(.easeOut(duration: 0.12)) { hovering = h }
        }
    }
}

// MARK: - The evidence grammar (the app's tell) — POLISH C1 / II.B
// The app's most repeated shape and its signature: identity → rank → value →
// destination, where the click ALWAYS lands on the artifact (transcript / file /
// URL), never a detail popover of itself. The rank bar never lies about scale —
// always normalized to the table's own top value, always `Theme.rankBarWidth`,
// track always visible (the track is the denominator made visible). Every table
// earns an `Eyebrow` and a denominator caption.

/// The canonical clickable evidence row. Leading identity block, a ranking bar,
/// trailing value cell(s), an optional trailing nav glyph. HoverRow gives the
/// native selection-hover feel; no hairline (the hover wash is the boundary).
struct EvidenceRow<Leading: View, Trailing: View>: View {
    let barFraction: Double            // 0…1 against the table's top value
    var barTint: Color = Theme.accent
    var navGlyph: String? = nil
    /// Reserve the 14pt nav gutter even when this row has no glyph — sibling rows
    /// carry one and the columns must line up. The gutter stays EMPTY: an em-dash
    /// placeholder reads as "no data", not "no navigation" (UI_GRIND LDG-4).
    var reservesNavGutter: Bool = false
    let action: () -> Void             // ALWAYS lands on the artifact
    @ViewBuilder let leading: () -> Leading
    @ViewBuilder let trailing: () -> Trailing

    var body: some View {
        HoverRow(radius: Theme.radiusRow, action: action) {
            HStack(spacing: Theme.sectionGap) {
                leading()
                    .frame(maxWidth: .infinity, alignment: .leading)
                CapsuleBar(fraction: barFraction, tint: barTint)
                    .frame(width: Theme.rankBarWidth)
                trailing()
                if let navGlyph {
                    Image(systemName: navGlyph)
                        .font(.caption2).foregroundStyle(Theme.faint).frame(width: 14)
                } else if reservesNavGutter {
                    Color.clear.frame(width: 14, height: 1)
                }
            }
            .padding(Theme.rowInsets)
        }
    }
}

/// The caption header row required above every evidence table — the column names
/// over the fixed metrics, so the columns line up with the row cells below.
struct EvidenceColumns: View {
    let leading: String
    let columns: [(title: String, width: CGFloat, align: Alignment)]
    /// Reserve the trailing nav-glyph gutter so the header aligns with rows that
    /// carry one.
    var hasNavGlyph: Bool = false

    var body: some View {
        HStack(spacing: Theme.sectionGap) {
            Text(leading).frame(maxWidth: .infinity, alignment: .leading)
            ForEach(Array(columns.enumerated()), id: \.offset) { _, c in
                Text(c.title).frame(width: c.width, alignment: c.align)
            }
            if hasNavGlyph { Color.clear.frame(width: 14) }
        }
        .font(.caption).foregroundStyle(Theme.faint)
        .padding(.horizontal, 8)
    }
}

/// The leading identity cell — the door light (state fill + 1pt tier ring, the
/// same `SeatMark` the Floor/strip/palette wear — UI_GRIND §2.1: one atom), a
/// project name (sans, what the app says), and a caption whose disk-truth run (a
/// short session id) renders mono, the rest sans (POLISH II.C).
struct IdentityCell: View {
    let project: String
    /// The disk-truth run rendered mono (a short session / parent id). Optional.
    var id: String? = nil
    let caption: String
    var tier: ModelTier? = nil
    /// Live state when the row is backed by a live session; nil (historical /
    /// evidence rows) renders the faint stateless fill — never a tier-colored
    /// disc, which read as an alarm in the app's own dot language.
    var state: AttentionState? = nil

    var body: some View {
        HStack(spacing: 8) {
            if tier != nil || state != nil {
                SeatMark(fill: state?.color ?? Theme.faint,
                         ring: tier?.color ?? .clear,
                         size: 7,
                         ringWidth: tier == nil ? 0 : 1)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(project)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.ink)
                    .lineLimit(1)
                captionText
                    .lineLimit(1)
            }
        }
    }

    private var captionText: Text {
        if let id {
            return Text(id).font(.system(.caption2, design: .monospaced)).foregroundStyle(Theme.faint)
                + Text(" · \(caption)").font(.caption2).foregroundStyle(Theme.faint)
        }
        return Text(caption).font(.caption2).foregroundStyle(Theme.faint)
    }
}

/// A section-level empty / "nothing to report" line — one calm shape (POLISH C6:
/// screen-level empty = `EmptyState`; section-level empty = `LeanRow`).
struct LeanRow: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle")
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.green)
            Text(text)
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
        }
        .padding(.vertical, 2)
    }
}

// MARK: - Callout panel (POLISH C5) — one component, two tones, nothing else
// The ONLY licensed tinted box: fill tone@6%, border tone@30% 1pt, radius 8. Two
// tones exhaustively: `.accent` = a candidate fix you can act on; `.amber` = a
// real warning with evidence. Green "verification ok" is a plain line, not a
// panel (green already means ok without a swatch behind it).

struct CalloutPanel<Content: View>: View {
    let tone: Color
    @ViewBuilder let content: () -> Content

    var body: some View {
        content()
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background {
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .fill(tone.opacity(0.06))
                RoundedRectangle(cornerRadius: Theme.radius, style: .continuous)
                    .strokeBorder(tone.opacity(0.30), lineWidth: 1)
            }
    }
}

// MARK: - Flow layout
// Wraps its children onto as many lines as needed — used by the attention strip
// so every chip stays visible (a horizontal scroll would hide the ones that
// matter most). macOS 15's Layout protocol; no third-party dependency.

struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    var lineSpacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxW = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0, widest: CGFloat = 0
        for sv in subviews {
            let sz = sv.sizeThatFits(.unspecified)
            if x + sz.width > maxW, x > 0 {
                widest = max(widest, x - spacing)
                x = 0; y += lineH + lineSpacing; lineH = 0
            }
            x += sz.width + spacing
            lineH = max(lineH, sz.height)
        }
        widest = max(widest, x - spacing)
        return CGSize(width: maxW.isFinite ? min(maxW, widest) : max(widest, 0),
                      height: y + lineH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = 0, y: CGFloat = 0, lineH: CGFloat = 0
        for sv in subviews {
            let sz = sv.sizeThatFits(.unspecified)
            if x + sz.width > bounds.width, x > 0 {
                x = 0; y += lineH + lineSpacing; lineH = 0
            }
            sv.place(at: CGPoint(x: bounds.minX + x, y: bounds.minY + y),
                     anchor: .topLeading, proposal: ProposedViewSize(sz))
            x += sz.width + spacing
            lineH = max(lineH, sz.height)
        }
    }
}

// MARK: - Empty state

struct EmptyState: View {
    let icon: String
    let title: String
    let detail: String
    var tint: Color = Theme.faint
    var maxWidth: CGFloat = 360

    var body: some View {
        VStack(spacing: Theme.sectionGap) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .light))
                .foregroundStyle(tint)
            Text(title)
                .font(.headline)
                .foregroundStyle(Theme.ink)
            Text(detail)
                .font(.subheadline)
                .foregroundStyle(Theme.muted)
                .multilineTextAlignment(.center)
                .frame(maxWidth: maxWidth)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(40)
    }
}

// MARK: - Flag row (routing audit)

struct FlagRow: View {
    let flag: RoutingFlag

    private var color: Color {
        switch flag.level {
        case .ok: return Theme.green
        case .info: return Theme.muted
        case .warn: return Theme.amber
        }
    }
    private var icon: String {
        switch flag.level {
        case .ok: return "checkmark.circle"
        case .info: return "info.circle"
        case .warn: return "exclamationmark.triangle"
        }
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .font(.footnote.weight(.medium))
                .foregroundStyle(color)
                .frame(width: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                Text(flag.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(Theme.ink)
                Text(flag.detail)
                    .font(.footnote)
                    .foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Screen scaffold (shared page chrome)
// 20pt gutters, headline-scale title, hairline under the header.

struct ScreenScaffold<Content: View, Trailing: View>: View {
    let title: String
    let subtitle: String
    /// An earned one-word epithet worn beside the title (POLISH C4) — coined in a
    /// doc first, worn in the app second. Same treatment Fleet's "the floor" uses.
    var epithet: String? = nil
    @ViewBuilder let trailing: () -> Trailing
    @ViewBuilder let content: () -> Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.blockGap) {
                HStack(alignment: .firstTextBaseline) {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(title)
                                .font(.title2.weight(.semibold))
                                .foregroundStyle(Theme.ink)
                            if let epithet {
                                Text(epithet)
                                    .font(.caption)
                                    .foregroundStyle(Theme.faint)
                            }
                        }
                        Text(subtitle)
                            .font(.subheadline)
                            .foregroundStyle(Theme.muted)
                    }
                    Spacer()
                    trailing()
                }
                .padding(.top, 4)
                Divider()
                content()
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 28)
            .padding(.top, 14)
            .frame(maxWidth: 1240, alignment: .leading)
            .frame(maxWidth: .infinity)
        }
        .scrollIndicators(.never)
    }
}

extension ScreenScaffold where Trailing == EmptyView {
    init(title: String, subtitle: String, epithet: String? = nil,
         @ViewBuilder content: @escaping () -> Content) {
        self.init(title: title, subtitle: subtitle, epithet: epithet,
                  trailing: { EmptyView() }, content: content)
    }
}

// MARK: - Toast

struct Toast: View {
    let text: String
    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Theme.green)
            Text(text)
                .font(.footnote.weight(.medium))
                .foregroundStyle(Theme.ink)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Theme.hairline, lineWidth: 1))
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }
}
